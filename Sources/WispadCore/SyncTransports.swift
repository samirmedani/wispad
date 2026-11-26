import CryptoKit
import Foundation

public typealias SyncHTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public enum SyncTransportError: Error, Equatable, Sendable {
    case invalidConfiguration
    case notFound
    case unauthorized
    case httpStatus(Int)
    case ioFailure
}

/// Interface minimale commune aux 3 connecteurs BYOS (Dossier synchronisé, Cloudflare R2 / S3, WebDAV).
public protocol SyncTransport: Sendable {
    func list(prefix: String) async throws -> [String]
    func get(path: String) async throws -> Data?
    func put(path: String, data: Data) async throws
    func delete(path: String) async throws
}

// MARK: - 1. Dossier synchronisé (iCloud Drive, OneDrive, Dropbox, Google Drive, Syncthing, NAS)

public struct FolderSyncTransport: SyncTransport {
    public let rootURL: URL
    private let queue = BlockingQueue(label: "wispad.sync.folder", qos: .utility)

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func list(prefix: String) async throws -> [String] {
        let root = rootURL
        let cleanPrefix = Self.normalize(prefix)
        return await queue.run {
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else { return [] }
            let searchRoot = cleanPrefix.isEmpty ? root : root.appendingPathComponent(cleanPrefix, isDirectory: true)
            guard fm.fileExists(atPath: searchRoot.path) else { return [] }
            guard let enumerator = fm.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            let basePath = root.standardizedFileURL.path
            var results: [String] = []
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let full = fileURL.standardizedFileURL.path
                guard full.hasPrefix(basePath + "/") else { continue }
                let rel = String(full.dropFirst(basePath.count + 1))
                if cleanPrefix.isEmpty || rel.hasPrefix(cleanPrefix) {
                    results.append(rel)
                }
            }
            return results.sorted()
        }
    }

    public func get(path: String) async throws -> Data? {
        let fileURL = try resolvedURL(for: path)
        return try await queue.run {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try Data(contentsOf: fileURL)
        }
    }

    public func put(path: String, data: Data) async throws {
        let fileURL = try resolvedURL(for: path)
        try await queue.run {
            let fm = FileManager.default
            let dir = fileURL.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    public func delete(path: String) async throws {
        let fileURL = try resolvedURL(for: path)
        try await queue.run {
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                try fm.removeItem(at: fileURL)
            }
        }
    }

    private func resolvedURL(for relativePath: String) throws -> URL {
        let clean = Self.normalize(relativePath)
        guard !clean.isEmpty, !clean.contains("..") else { throw SyncTransportError.invalidConfiguration }
        return rootURL.appendingPathComponent(clean)
    }

    private static func normalize(_ path: String) -> String {
        path.split(separator: "/").filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
    }
}

// MARK: - 2. S3 compatible (Cloudflare R2, Backblaze B2, MinIO, AWS S3) avec AWS SigV4 pur Swift

public struct S3SyncTransport: SyncTransport {
    public let config: S3SyncConfig
    private let transport: SyncHTTPTransport

    public init(config: S3SyncConfig, transport: @escaping SyncHTTPTransport = defaultHTTP) {
        self.config = config
        self.transport = transport
    }

    public static func defaultHTTP(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }

    public func list(prefix: String) async throws -> [String] {
        let fullPrefix = prefixed(prefix)
        var keys: [String] = []
        var continuationToken: String?
        repeat {
            var query: [(String, String)] = [("list-type", "2")]
            if !fullPrefix.isEmpty { query.append(("prefix", fullPrefix)) }
            if let token = continuationToken { query.append(("continuation-token", token)) }
            let request = try Self.signedRequest(
                method: "GET",
                config: config,
                objectKey: nil,
                queryItems: query,
                payload: Data()
            )
            let (data, response) = try await transport(request)
            try checkStatus(response, allowNotFound: false)
            let parsed = Self.parseListObjectsV2XML(data)
            for key in parsed.keys {
                keys.append(unprefixed(key))
            }
            continuationToken = parsed.nextToken
        } while continuationToken != nil
        return keys.sorted()
    }

    public func get(path: String) async throws -> Data? {
        let request = try Self.signedRequest(method: "GET", config: config, objectKey: prefixed(path), queryItems: [], payload: Data())
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try checkStatus(response, allowNotFound: true)
        return data
    }

    public func put(path: String, data: Data) async throws {
        let request = try Self.signedRequest(method: "PUT", config: config, objectKey: prefixed(path), queryItems: [], payload: data)
        let (_, response) = try await transport(request)
        try checkStatus(response, allowNotFound: false)
    }

    public func delete(path: String) async throws {
        let request = try Self.signedRequest(method: "DELETE", config: config, objectKey: prefixed(path), queryItems: [], payload: Data())
        let (_, response) = try await transport(request)
        try checkStatus(response, allowNotFound: true)
    }

    private func prefixed(_ relativePath: String) -> String {
        let p = config.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let r = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if p.isEmpty { return r }
        if r.isEmpty { return p + "/" }
        return "\(p)/\(r)"
    }

    private func unprefixed(_ key: String) -> String {
        let p = config.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !p.isEmpty, key.hasPrefix(p + "/") else { return key }
        return String(key.dropFirst(p.count + 1))
    }

    private func checkStatus(_ response: URLResponse, allowNotFound: Bool) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.ioFailure }
        if (200...299).contains(http.statusCode) { return }
        if allowNotFound && http.statusCode == 404 { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncTransportError.unauthorized }
        throw SyncTransportError.httpStatus(http.statusCode)
    }

    /// Signature AWS SigV4 (path-style `https://endpoint/bucket/key`) compatible Cloudflare R2, B2, MinIO, S3.
    public static func signedRequest(
        method: String,
        config: S3SyncConfig,
        objectKey: String?,
        queryItems: [(String, String)],
        payload: Data,
        date: Date = Date()
    ) throws -> URLRequest {
        let baseString = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: baseString), let host = baseURL.host else {
            throw SyncTransportError.invalidConfiguration
        }
        let hostHeader = baseURL.port.map { "\(host):\($0)" } ?? host
        let bucket = config.bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !bucket.isEmpty else { throw SyncTransportError.invalidConfiguration }

        let keySegments = (objectKey ?? "").split(separator: "/").map(String.init)
        let encodedPathSegments = ([bucket] + keySegments).map(awsPercentEncode)
        let canonicalURI = "/" + encodedPathSegments.joined(separator: "/")

        let encodedQuery: [(String, String)] = queryItems.map { item in
            (awsPercentEncode(item.0), awsPercentEncode(item.1))
        }
        let sortedQuery = encodedQuery.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let canonicalQuery = sortedQuery.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        var urlString = baseString + canonicalURI
        if !canonicalQuery.isEmpty { urlString += "?" + canonicalQuery }
        guard let finalURL = URL(string: urlString) else { throw SyncTransportError.invalidConfiguration }

        let amzDate = formatAmzDate(date)
        let dateStamp = String(amzDate.prefix(8))
        let region = config.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "auto" : config.region
        let payloadHash = sha256Hex(payload)

        let canonicalHeaders = "host:\(hostHeader)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let kDate = hmacSHA256(key: Data("AWS4\(config.secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data("s3".utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 Credential=\(config.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(hostHeader, forHTTPHeaderField: "Host")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if !payload.isEmpty {
            request.httpBody = payload
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public static func parseListObjectsV2XML(_ data: Data) -> (keys: [String], nextToken: String?) {
        let text = String(decoding: data, as: UTF8.self)
        let keys = extractXMLTagValues("Key", in: text)
        let isTruncated = extractXMLTagValues("IsTruncated", in: text).first?.lowercased() == "true"
        let nextToken = isTruncated ? extractXMLTagValues("NextContinuationToken", in: text).first : nil
        return (keys, nextToken)
    }

    private static func extractXMLTagValues(_ tag: String, in xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)>([^<]*)</\(tag)>") else { return [] }
        let ns = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { match in
            xmlUnescape(ns.substring(with: match.range(at: 1)))
        }
    }

    private static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func awsPercentEncode(_ input: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
    }

    private static func formatAmzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(code)
    }
}

// MARK: - 3. WebDAV (Nextcloud, Synology NAS, Infomaniak kDrive, Koofr)

public struct WebDAVSyncTransport: SyncTransport {
    public let config: WebDAVSyncConfig
    private let transport: SyncHTTPTransport

    public init(config: WebDAVSyncConfig, transport: @escaping SyncHTTPTransport = S3SyncTransport.defaultHTTP) {
        self.config = config
        self.transport = transport
    }

    public func list(prefix: String) async throws -> [String] {
        var results: [String] = []
        try await collectFiles(relativePrefix: prefix, into: &results, depthRemaining: 3)
        return results.sorted()
    }

    private func collectFiles(relativePrefix: String, into results: inout [String], depthRemaining: Int) async throws {
        guard depthRemaining >= 0 else { return }
        let url = try buildURL(for: relativePrefix, isDirectory: true)
        var request = authorizedRequest(url: url, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return }
        try checkStatus(response, allowNotFound: true)
        let baseRootPath = try buildURL(for: "", isDirectory: true).path
        let hrefs = Self.parsePropfindHrefs(data)
        let selfPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for href in hrefs {
            let decoded = href.removingPercentEncoding ?? href
            let pathOnly = URL(string: decoded)?.path ?? decoded
            let trimmed = pathOnly.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed == selfPath { continue }
            let cleanBase = baseRootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard trimmed.hasPrefix(cleanBase + "/") else { continue }
            let rel = String(trimmed.dropFirst(cleanBase.count + 1))
            if pathOnly.hasSuffix("/") {
                try await collectFiles(relativePrefix: rel, into: &results, depthRemaining: depthRemaining - 1)
            } else {
                results.append(rel)
            }
        }
    }

    public func get(path: String) async throws -> Data? {
        let url = try buildURL(for: path, isDirectory: false)
        let request = authorizedRequest(url: url, method: "GET")
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try checkStatus(response, allowNotFound: true)
        return data
    }

    public func put(path: String, data: Data) async throws {
        try await ensureParentCollections(for: path)
        let url = try buildURL(for: path, isDirectory: false)
        var request = authorizedRequest(url: url, method: "PUT")
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await transport(request)
        try checkStatus(response, allowNotFound: false)
    }

    public func delete(path: String) async throws {
        let url = try buildURL(for: path, isDirectory: false)
        let request = authorizedRequest(url: url, method: "DELETE")
        let (_, response) = try await transport(request)
        try checkStatus(response, allowNotFound: true)
    }

    private func ensureParentCollections(for path: String) async throws {
        let parts = path.split(separator: "/").map(String.init)
        var current = ""
        try await mkcol(relative: "")
        for part in parts.dropLast() {
            current = current.isEmpty ? part : "\(current)/\(part)"
            try await mkcol(relative: current)
        }
    }

    private func mkcol(relative: String) async throws {
        let url = try buildURL(for: relative, isDirectory: true)
        let request = authorizedRequest(url: url, method: "MKCOL")
        let (_, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.ioFailure }
        // 201 créé, 405 déjà existant, 301/409 déjà créé côté serveur
        if (200...299).contains(http.statusCode) || http.statusCode == 405 || http.statusCode == 301 { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncTransportError.unauthorized }
    }

    private func buildURL(for relativePath: String, isDirectory: Bool) throws -> URL {
        let base = config.url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw SyncTransportError.invalidConfiguration }
        let prefix = config.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let rel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let segments = ([prefix] + rel.split(separator: "/").map(String.init)).filter { !$0.isEmpty }
        var full = base
        for seg in segments {
            let encoded = seg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seg
            full += "/" + encoded
        }
        if isDirectory { full += "/" }
        guard let url = URL(string: full) else { throw SyncTransportError.invalidConfiguration }
        return url
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if !config.username.isEmpty || !config.password.isEmpty {
            let raw = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
            request.setValue("Basic \(raw)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func checkStatus(_ response: URLResponse, allowNotFound: Bool) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.ioFailure }
        if (200...299).contains(http.statusCode) { return }
        if allowNotFound && http.statusCode == 404 { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncTransportError.unauthorized }
        throw SyncTransportError.httpStatus(http.statusCode)
    }

    public static func parsePropfindHrefs(_ data: Data) -> [String] {
        let xml = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "<(?:[A-Za-z0-9_-]+:)?href>([^<]+)</(?:[A-Za-z0-9_-]+:)?href>", options: [.caseInsensitive]) else {
            return []
        }
        let ns = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
