import Foundation

/// Plateforme d'origine d'une dictée ou d'une note de réunion synchronisée.
public enum DevicePlatform: String, Codable, Equatable, Sendable, CaseIterable {
    case macos
    case ios
    case windows
}

/// Identité locale stable d'un appareil Wispad (sans donnée personnelle ni identifiant matériel Apple).
public struct DeviceIdentity: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var platform: DevicePlatform

    public init(deviceId: String, deviceName: String, platform: DevicePlatform) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
    }
}

/// Manifeste en clair au sommet du dossier/bucket BYOS : zéro texte utilisateur, sert uniquement à vérifier
/// le format et la compatibilité de clé (`vaultId`).
public struct SyncManifest: Codable, Equatable, Sendable {
    public static let expectedFormat = "wispad-sync"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var vaultId: String
    public var createdAt: Double

    public init(vaultId: String, createdAt: Double = Date().timeIntervalSince1970) {
        self.format = Self.expectedFormat
        self.version = Self.currentVersion
        self.vaultId = vaultId
        self.createdAt = createdAt
    }
}

/// Dictée synchronisée (texte et métadonnées uniquement, jamais l'audio WAV).
public struct SyncDictation: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Double
    public var updatedAt: Double
    public var deletedAt: Double?
    public var finalText: String
    public var rawText: String
    public var durationSeconds: Double
    public var wordCount: Int
    public var provider: String
    public var model: String
    public var targetApp: String?
    public var targetBundle: String?
    public var usageCategory: String?
    public var insertionStatus: String
    public var sourceDeviceId: String
    public var sourceDeviceName: String
    public var sourceDevicePlatform: String

    public init(
        id: String, createdAt: Double, updatedAt: Double, deletedAt: Double? = nil,
        finalText: String, rawText: String, durationSeconds: Double, wordCount: Int,
        provider: String, model: String, targetApp: String? = nil, targetBundle: String? = nil,
        usageCategory: String? = nil, insertionStatus: String,
        sourceDeviceId: String, sourceDeviceName: String, sourceDevicePlatform: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.finalText = finalText
        self.rawText = rawText
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.provider = provider
        self.model = model
        self.targetApp = targetApp
        self.targetBundle = targetBundle
        self.usageCategory = usageCategory
        self.insertionStatus = insertionStatus
        self.sourceDeviceId = sourceDeviceId
        self.sourceDeviceName = sourceDeviceName
        self.sourceDevicePlatform = sourceDevicePlatform
    }
}

/// Note de réunion synchronisée (style Granola : notes rapides + transcription + synthèse IA, sans audio).
public struct SyncMeeting: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Double
    public var updatedAt: Double
    public var deletedAt: Double?
    public var durationSeconds: Double
    public var userNotes: String
    public var rawTranscript: String
    public var enhancedNotes: String
    public var sourceDeviceId: String
    public var sourceDeviceName: String
    public var sourceDevicePlatform: String

    public init(
        id: String, title: String, createdAt: Double, updatedAt: Double, deletedAt: Double? = nil,
        durationSeconds: Double, userNotes: String, rawTranscript: String, enhancedNotes: String,
        sourceDeviceId: String, sourceDeviceName: String, sourceDevicePlatform: String
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.durationSeconds = durationSeconds
        self.userNotes = userNotes
        self.rawTranscript = rawTranscript
        self.enhancedNotes = enhancedNotes
        self.sourceDeviceId = sourceDeviceId
        self.sourceDeviceName = sourceDeviceName
        self.sourceDevicePlatform = sourceDevicePlatform
    }
}

public struct SyncDictionaryTerm: Codable, Equatable, Sendable {
    public var id: String
    public var term: String
    public var createdAt: Double
    public var updatedAt: Double
    public var deletedAt: Double?
    public var origin: String?
    public var judgeProvider: String?
    public var judgeModel: String?
    public var heard: String?
    public var source: String?

    public init(
        id: String, term: String, createdAt: Double, updatedAt: Double, deletedAt: Double? = nil,
        origin: String? = nil, judgeProvider: String? = nil, judgeModel: String? = nil,
        heard: String? = nil, source: String? = nil
    ) {
        self.id = id
        self.term = term
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.origin = origin
        self.judgeProvider = judgeProvider
        self.judgeModel = judgeModel
        self.heard = heard
        self.source = source
    }
}

public struct SyncRefusal: Codable, Equatable, Sendable {
    public var term: String
    public var createdAt: Double

    public init(term: String, createdAt: Double) {
        self.term = term
        self.createdAt = createdAt
    }
}

/// Sous-ensemble partagé des réglages (hors réglages propres à la machine : micro, raccourci OS, bulle, modèle local).
public struct SyncSharedSettings: Codable, Equatable, Sendable {
    public var updatedAt: Double
    /// JSON sérialisé d'un objet plat `{ "cle": valeur }` pour garder une compatibilité ascendante/descendante totale.
    public var fieldsJSON: String

    public init(updatedAt: Double, fieldsJSON: String) {
        self.updatedAt = updatedAt
        self.fieldsJSON = fieldsJSON
    }
}

/// Un lot immuable publié par un appareil dans `devices/<deviceId>/<seq>.wsp.enc`.
public struct SyncDelta: Codable, Equatable, Sendable {
    public var version: Int
    public var deviceId: String
    public var deviceName: String
    public var devicePlatform: String
    public var sequence: Int
    public var createdAt: Double
    public var dictations: [SyncDictation]
    public var meetings: [SyncMeeting]
    public var dictionary: [SyncDictionaryTerm]
    public var refusals: [SyncRefusal]
    public var sharedSettings: SyncSharedSettings?

    public init(
        version: Int = 1,
        deviceId: String,
        deviceName: String,
        devicePlatform: String,
        sequence: Int,
        createdAt: Double = Date().timeIntervalSince1970,
        dictations: [SyncDictation] = [],
        meetings: [SyncMeeting] = [],
        dictionary: [SyncDictionaryTerm] = [],
        refusals: [SyncRefusal] = [],
        sharedSettings: SyncSharedSettings? = nil
    ) {
        self.version = version
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.devicePlatform = devicePlatform
        self.sequence = sequence
        self.createdAt = createdAt
        self.dictations = dictations
        self.meetings = meetings
        self.dictionary = dictionary
        self.refusals = refusals
        self.sharedSettings = sharedSettings
    }

    public var isEmpty: Bool {
        dictations.isEmpty && meetings.isEmpty && dictionary.isEmpty && refusals.isEmpty && sharedSettings == nil
    }
}

// MARK: - Configuration BYOS & QR Code d'appairage

public enum SyncBackendKind: String, Codable, Equatable, Sendable, CaseIterable {
    case off
    case folder
    case s3
    case webdav
}

public struct S3SyncConfig: Codable, Equatable, Sendable {
    /// Ex. `https://<account_id>.r2.cloudflarestorage.com` pour Cloudflare R2.
    public var endpoint: String
    public var bucket: String
    public var region: String
    public var prefix: String
    public var accessKeyId: String
    public var secretAccessKey: String

    public init(
        endpoint: String = "",
        bucket: String = "wispad-sync",
        region: String = "auto",
        prefix: String = "wispad-sync",
        accessKeyId: String = "",
        secretAccessKey: String = ""
    ) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.prefix = prefix
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }

    /// Aide 2 clics Cloudflare R2 : construit l'URL endpoint depuis le seul identifiant de compte Cloudflare.
    public static func cloudflareR2Endpoint(accountID: String) -> String {
        let cleaned = accountID.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty else { return "" }
        if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") { return cleaned }
        if cleaned.contains(".r2.cloudflarestorage.com") { return "https://\(cleaned)" }
        return "https://\(cleaned).r2.cloudflarestorage.com"
    }

    public var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct WebDAVSyncConfig: Codable, Equatable, Sendable {
    public var url: String
    public var username: String
    public var password: String
    public var prefix: String

    public init(url: String = "", username: String = "", password: String = "", prefix: String = "") {
        self.url = url
        self.username = username
        self.password = password
        self.prefix = prefix
    }

    public var isConfigured: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Charge utile encodée dans le QR code / lien d'appairage `wispad-sync://v1?data=...` pour configurer iOS ou Windows en un geste.
public struct SyncPairingConfig: Codable, Equatable, Sendable {
    public static let scheme = "wispad-sync"

    public var version: Int
    public var syncKey: String
    public var backend: SyncBackendKind
    public var folderHint: String?
    public var s3: S3SyncConfig?
    public var webdav: WebDAVSyncConfig?

    public init(
        version: Int = 1,
        syncKey: String,
        backend: SyncBackendKind,
        folderHint: String? = nil,
        s3: S3SyncConfig? = nil,
        webdav: WebDAVSyncConfig? = nil
    ) {
        self.version = version
        self.syncKey = syncKey
        self.backend = backend
        self.folderHint = folderHint
        self.s3 = s3
        self.webdav = webdav
    }

    public func pairingURI() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(self)
        return "\(Self.scheme)://v1?data=\(SyncKey.encodeBase64URL(json))"
    }

    public static func parse(uri: String) -> SyncPairingConfig? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == Self.scheme,
              (components.host ?? "").lowercased() == "v1",
              let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value,
              let raw = SyncKey.decodeBase64URL(dataParam),
              let config = try? JSONDecoder().decode(SyncPairingConfig.self, from: raw),
              config.version == 1,
              (try? SyncKey(base64URL: config.syncKey)) != nil else {
            return nil
        }
        switch config.backend {
        case .s3 where config.s3?.isConfigured != true:
            return nil
        case .webdav where config.webdav?.isConfigured != true:
            return nil
        default:
            return config
        }
    }
}
