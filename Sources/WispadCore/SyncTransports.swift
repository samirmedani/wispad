import CryptoKit
import Foundation

public typealias SyncHTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public enum SyncTransportError: Error, Equatable, Sendable {
    case invalidConfiguration
    case notFound
    case unauthorized
    case httpStatus(Int)
    case ioFailure
    /// Dossier de synchronisation absent (disque retiré, partage réseau démonté) : jamais recréé par la synchro.
    case folderUnavailable
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
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let searchRoot = cleanPrefix.isEmpty ? resolvedRoot : resolvedRoot.appendingPathComponent(cleanPrefix, isDirectory: true)
            guard fm.fileExists(atPath: searchRoot.path) else { return [] }
            guard let enumerator = fm.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else { return [] }
            let basePath = resolvedRoot.path
            var results: [String] = []
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                // Fichier évincé par iCloud Drive (`.000001.wsp.enc.icloud`) : déclenche le téléchargement local.
                if name.hasPrefix("."), name.hasSuffix(".wsp.enc.icloud") {
                    try? fm.startDownloadingUbiquitousItem(at: fileURL)
                    continue
                }
                if name.hasPrefix(".") { continue }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let full = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
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
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                let icloudPlaceholder = fileURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(fileURL.lastPathComponent).icloud")
                if fm.fileExists(atPath: icloudPlaceholder.path) {
                    try? fm.startDownloadingUbiquitousItem(at: icloudPlaceholder)
                }
                return nil
            }
            return try Data(contentsOf: fileURL)
        }
    }

    public func put(path: String, data: Data) async throws {
        let fileURL = try resolvedURL(for: path)
        let root = rootURL
        try await queue.run {
            let fm = FileManager.default
            // Le dossier choisi n'est jamais recréé ici : absent (disque retiré, partage démonté), un coffre vide prendrait
            // sa place et les envois s'y perdraient.
            var rootIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
                throw SyncTransportError.folderUnavailable
            }
            let dir = fileURL.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
            fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
            do {
                try data.write(to: tmp)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
                if fm.fileExists(atPath: fileURL.path) {
                    _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: fileURL)
                }
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
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
        let segments = relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !segments.isEmpty, !segments.contains("..") else { throw SyncTransportError.invalidConfiguration }
        return rootURL.appendingPathComponent(segments.joined(separator: "/"))
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
        var seenTokens: Set<String> = []
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
            if let next = parsed.nextToken, !next.isEmpty, seenTokens.insert(next).inserted {
                continuationToken = next
            } else {
                continuationToken = nil
            }
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

    /// Signature AWS SigV4 (path-style `https://endpoint[/basePath]/bucket/key`) compatible Cloudflare R2, B2, MinIO, S3.
    public static func signedRequest(
        method: String,
        config: S3SyncConfig,
        objectKey: String?,
        queryItems: [(String, String)],
        payload: Data,
        date: Date = Date()
    ) throws -> URLRequest {
        let baseString = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: baseString),
              let scheme = baseURL.scheme?.lowercased(),
              let rawHost = baseURL.host else {
            throw SyncTransportError.invalidConfiguration
        }
        let hostLower = rawHost.lowercased()
        let isDefaultPort = (scheme == "https" && baseURL.port == 443) || (scheme == "http" && baseURL.port == 80)
        let hostHeader: String
        if let port = baseURL.port, !isDefaultPort {
            hostHeader = "\(hostLower):\(port)"
        } else {
            hostHeader = hostLower
        }

        let bucket = config.bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let accessKey = config.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = config.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty, !accessKey.isEmpty, !secretKey.isEmpty else {
            throw SyncTransportError.invalidConfiguration
        }

        let basePathSegments = baseURL.path.split(separator: "/").map(String.init)
        let keySegments = (objectKey ?? "").split(separator: "/").map(String.init)
        let encodedPathSegments = (basePathSegments + [bucket] + keySegments).map(awsPercentEncode)
        let canonicalURI = "/" + encodedPathSegments.joined(separator: "/")

        let encodedQuery: [(String, String)] = queryItems.map { item in
            (awsPercentEncode(item.0), awsPercentEncode(item.1))
        }
        let sortedQuery = encodedQuery.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let canonicalQuery = sortedQuery.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        var urlString = "\(scheme)://\(hostHeader)\(canonicalURI)"
        if !canonicalQuery.isEmpty { urlString += "?" + canonicalQuery }
        guard let finalURL = URL(string: urlString) else { throw SyncTransportError.invalidConfiguration }

        let amzDate = formatAmzDate(date)
        let dateStamp = String(amzDate.prefix(8))
        let trimmedRegion = config.region.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = trimmedRegion.isEmpty ? "auto" : trimmedRegion
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

        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data("s3".utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

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
        let delegate = S3ListXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.keys, delegate.isTruncated ? delegate.nextToken : nil)
    }

    /// Encodage strict RFC 3986 / AWS SigV4 (uniquement ASCII `A-Za-z0-9-_.~`, octets UTF-8 en hex majuscule).
    public static func awsPercentEncode(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.utf8.count)
        for byte in input.utf8 {
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A) // A-Z
                || (byte >= 0x61 && byte <= 0x7A) // a-z
                || (byte >= 0x30 && byte <= 0x39) // 0-9
                || byte == 0x2D // -
                || byte == 0x2E // .
                || byte == 0x5F // _
                || byte == 0x7E // ~
            if isUnreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
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

private final class S3ListXMLDelegate: NSObject, XMLParserDelegate {
    var keys: [String] = []
    var isTruncated = false
    var nextToken: String?
    private var currentTag = ""
    private var buffer = ""

    private static func localName(_ elementName: String) -> String {
        if let idx = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: idx)...])
        }
        return elementName
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentTag = Self.localName(elementName)
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = Self.localName(elementName)
        if local == currentTag {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local {
            case "Key":
                if !value.isEmpty { keys.append(value) }
            case "IsTruncated":
                isTruncated = (value.lowercased() == "true")
            case "NextContinuationToken":
                if !value.isEmpty { nextToken = value }
            default:
                break
            }
        }
        currentTag = ""
        buffer = ""
    }
}

// MARK: - 3. WebDAV (Nextcloud, Synology NAS, Infomaniak kDrive, Koofr)

public struct WebDAVEntry: Equatable, Sendable {
    public var href: String
    public var isCollection: Bool

    public init(href: String, isCollection: Bool) {
        self.href = href
        self.isCollection = isCollection
    }
}

public struct WebDAVSyncTransport: SyncTransport {
    public let config: WebDAVSyncConfig
    private let transport: SyncHTTPTransport

    private static let propfindBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>
        """.utf8
    )

    public init(config: WebDAVSyncConfig, transport: @escaping SyncHTTPTransport = S3SyncTransport.defaultHTTP) {
        self.config = config
        self.transport = transport
    }

    public func list(prefix: String) async throws -> [String] {
        var results: [String] = []
        var visited: Set<String> = []
        try await collectFiles(relativePrefix: prefix, into: &results, visited: &visited, depthRemaining: 4)
        return results.sorted()
    }

    private func collectFiles(relativePrefix: String, into results: inout [String], visited: inout Set<String>, depthRemaining: Int) async throws {
        guard depthRemaining >= 0 else { return }
        let url = try buildURL(for: relativePrefix, isDirectory: true)
        let selfPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard visited.insert(selfPath).inserted else { return }

        var request = authorizedRequest(url: url, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return }
        try checkStatus(response, allowNotFound: true)

        let baseRootPath = try buildURL(for: "", isDirectory: true).path
        let cleanBase = baseRootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let entries = Self.parsePropfindEntries(data)
        for entry in entries {
            let rawPath: String
            if let parsed = URL(string: entry.href) {
                rawPath = parsed.path
            } else {
                rawPath = entry.href.removingPercentEncoding ?? entry.href
            }
            let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed == selfPath || trimmed.isEmpty { continue }

            let rel: String
            if cleanBase.isEmpty {
                rel = trimmed
            } else if trimmed.hasPrefix(cleanBase + "/") {
                rel = String(trimmed.dropFirst(cleanBase.count + 1))
            } else {
                continue
            }
            guard !rel.isEmpty else { continue }
            if entry.isCollection || rawPath.hasSuffix("/") {
                try await collectFiles(relativePrefix: rel, into: &results, visited: &visited, depthRemaining: depthRemaining - 1)
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
        let base = config.url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw SyncTransportError.invalidConfiguration }
        let prefixSegments = config.prefix.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let pathSegments = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let allParents = prefixSegments + Array(pathSegments.dropLast())

        // Crée le dossier de base lui-même s'il n'existe pas encore, puis chaque sous-dossier parent.
        try await mkcol(urlString: base + "/")
        var current = base
        for seg in allParents {
            current += "/" + S3SyncTransport.awsPercentEncode(seg)
            try await mkcol(urlString: current + "/")
        }
    }

    private func mkcol(urlString: String) async throws {
        guard let url = URL(string: urlString) else { throw SyncTransportError.invalidConfiguration }
        let request = authorizedRequest(url: url, method: "MKCOL")
        let (_, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.ioFailure }
        // 201 créé, 200/204 OK, 405 déjà existant, 301 redirection dossier déjà existant
        if (200...299).contains(http.statusCode) || http.statusCode == 405 || http.statusCode == 301 { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncTransportError.unauthorized }
        throw SyncTransportError.httpStatus(http.statusCode)
    }

    private func buildURL(for relativePath: String, isDirectory: Bool) throws -> URL {
        let base = config.url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { throw SyncTransportError.invalidConfiguration }
        let prefixSegments = config.prefix.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let relSegments = relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var full = base
        for seg in prefixSegments + relSegments {
            full += "/" + S3SyncTransport.awsPercentEncode(seg)
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
        parsePropfindEntries(data).map(\.href)
    }

    public static func parsePropfindEntries(_ data: Data) -> [WebDAVEntry] {
        let delegate = WebDAVPropfindXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }
}

private final class WebDAVPropfindXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [WebDAVEntry] = []
    private var inResponse = false
    private var inHref = false
    private var inResourceType = false
    private var currentHref = ""
    private var currentIsCollection = false

    private static func localName(_ elementName: String) -> String {
        if let idx = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: idx)...]).lowercased()
        }
        return elementName.lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = Self.localName(elementName)
        switch local {
        case "response":
            inResponse = true
            currentHref = ""
            currentIsCollection = false
        case "href" where inResponse:
            inHref = true
            currentHref = ""
        case "resourcetype" where inResponse:
            inResourceType = true
        case "collection" where inResourceType:
            currentIsCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inHref { currentHref.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = Self.localName(elementName)
        switch local {
        case "href":
            inHref = false
        case "resourcetype":
            inResourceType = false
        case "response":
            let cleaned = currentHref.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                entries.append(WebDAVEntry(href: cleaned, isCollection: currentIsCollection || cleaned.hasSuffix("/")))
            }
            inResponse = false
        default:
            break
        }
    }
}
