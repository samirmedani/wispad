import AppKit
import CoreImage
import Foundation
import os
import WispadCore

/// Configuration locale de synchronisation BYOS E2EE, stockée dans `sync-config.json` (permissions 0600),
/// jamais dans `AppSettings` (UserDefaults) ni dans les exports de configuration.
struct SyncLocalConfig: Codable, Equatable, Sendable {
    var enabled = false
    var deviceId: String
    var deviceName: String
    var backend: SyncBackendKind = .folder
    var syncKeyBase64URL = ""
    var folderPath = ""
    var cloudflareAccountId = ""
    var useCustomS3Endpoint = false
    var s3 = S3SyncConfig()
    var webdav = WebDAVSyncConfig()
    var syncSharedSettings = true

    init(
        enabled: Bool = false,
        deviceId: String = UUID().uuidString,
        deviceName: String = Host.current().localizedName ?? "Mac",
        backend: SyncBackendKind = .folder,
        syncKeyBase64URL: String = "",
        folderPath: String = "",
        cloudflareAccountId: String = "",
        useCustomS3Endpoint: Bool = false,
        s3: S3SyncConfig = S3SyncConfig(),
        webdav: WebDAVSyncConfig = WebDAVSyncConfig(),
        syncSharedSettings: Bool = true
    ) {
        self.enabled = enabled
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.backend = backend
        self.syncKeyBase64URL = syncKeyBase64URL
        self.folderPath = folderPath
        self.cloudflareAccountId = cloudflareAccountId
        self.useCustomS3Endpoint = useCustomS3Endpoint
        self.s3 = s3
        self.webdav = webdav
        self.syncSharedSettings = syncSharedSettings
    }

    var effectiveS3Config: S3SyncConfig {
        var resolved = s3
        let account = cloudflareAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !useCustomS3Endpoint, !account.isEmpty {
            resolved.endpoint = S3SyncConfig.cloudflareR2Endpoint(accountID: account)
            if resolved.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolved.region = "auto"
            }
        }
        return resolved
    }
}

/// Raccourci d'un dossier cloud déjà installé sur ce Mac (iCloud Drive, OneDrive, Dropbox, Google Drive).
struct DetectedCloudFolder: Identifiable, Equatable {
    var id: String { path }
    var name: String
    var path: String
    var symbol: String
}

/// Sous-ensemble portable des réglages partagés entre Mac, iOS et Windows (jamais de clés API ni de réglages machine).
private struct SharedSettingsFields: Codable, Equatable {
    var language: String
    var cleanupEnabled: Bool
    var structureDictation: Bool
    var autoParagraphs: Bool
    var selectionCommands: Bool
    var speakerAgreement: String
    var tones: [String: String]
    var typingWPM: Double
}

/// Pilote la synchronisation texte seul chiffrée de bout en bout (BYOS, zéro serveur central).
@MainActor
@Observable
final class SyncController {
    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case ok
        case failed(String)
    }

    var config: SyncLocalConfig
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var lastSummary: String?
    var connectionStatus: ConnectionStatus = .idle

    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var activeSyncTask: Task<Void, Never>?
    @ObservationIgnored nonisolated private static let log = Logger.wispad("synchro")

    init(supportURL: URL, persists: Bool = true) {
        self.configURL = supportURL.appendingPathComponent("sync-config.json")
        self.persists = persists
        if persists, let data = try? Data(contentsOf: configURL),
           let loaded = try? JSONDecoder().decode(SyncLocalConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = SyncLocalConfig()
        }
    }

    var deviceIdentity: DeviceIdentity {
        let name = config.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return DeviceIdentity(
            deviceId: config.deviceId,
            deviceName: name.isEmpty ? (Host.current().localizedName ?? "Mac") : name,
            platform: .macos
        )
    }

    /// Génère une clé AES-256 aléatoire (base64url) si aucune n'est encore définie.
    @discardableResult
    func ensureSyncKey() -> SyncKey {
        if let existing = try? SyncKey(base64URL: config.syncKeyBase64URL) {
            return existing
        }
        let generated = SyncKey.generate()
        config.syncKeyBase64URL = generated.base64URL
        saveConfig()
        return generated
    }

    func regenerateSyncKey() {
        config.syncKeyBase64URL = SyncKey.generate().base64URL
        saveConfig()
    }

    func saveConfig() {
        guard persists else { return }
        let snapshot = config
        let url = configURL
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Self.log.error("écriture sync-config impossible")
            }
        }
    }

    func buildTransport() throws -> any SyncTransport {
        switch config.backend {
        case .off:
            throw SyncTransportError.invalidConfiguration
        case .folder:
            let path = config.folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { throw SyncTransportError.invalidConfiguration }
            return FolderSyncTransport(rootURL: URL(fileURLWithPath: path, isDirectory: true))
        case .s3:
            let resolved = config.effectiveS3Config
            guard resolved.isConfigured else { throw SyncTransportError.invalidConfiguration }
            return S3SyncTransport(config: resolved)
        case .webdav:
            guard config.webdav.isConfigured else { throw SyncTransportError.invalidConfiguration }
            return WebDAVSyncTransport(config: config.webdav)
        }
    }

    /// Lien d'appairage `wispad-sync://v1?data=...` pour connecter un iPhone, un PC Windows ou un autre Mac.
    func pairingURI() -> String? {
        guard let key = try? SyncKey(base64URL: config.syncKeyBase64URL) else { return nil }
        let pairing: SyncPairingConfig
        switch config.backend {
        case .off:
            return nil
        case .folder:
            let hint = URL(fileURLWithPath: config.folderPath).lastPathComponent
            pairing = SyncPairingConfig(syncKey: key.base64URL, backend: .folder, folderHint: hint.isEmpty ? "WispadSync" : hint)
        case .s3:
            let s3 = config.effectiveS3Config
            guard s3.isConfigured else { return nil }
            pairing = SyncPairingConfig(syncKey: key.base64URL, backend: .s3, s3: s3)
        case .webdav:
            guard config.webdav.isConfigured else { return nil }
            pairing = SyncPairingConfig(syncKey: key.base64URL, backend: .webdav, webdav: config.webdav)
        }
        return try? pairing.pairingURI()
    }

    /// Génère une image nette de QR code (CoreImage) sans dépendance externe.
    static func qrImage(from string: String, dimension: CGFloat = 180) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(dimension / max(1, output.extent.width)))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Importe un lien `wispad-sync://v1?data=...` collé ou ouvert par URL scheme.
    @discardableResult
    func applyPairingURI(_ raw: String) -> Bool {
        guard let pairing = SyncPairingConfig.parse(uri: raw) else {
            lastError = String(localized: "Lien d'appairage invalide ou incomplet.")
            return false
        }
        config.backend = pairing.backend
        config.syncKeyBase64URL = pairing.syncKey
        switch pairing.backend {
        case .off:
            config.enabled = false
        case .folder:
            if config.folderPath.isEmpty, let first = Self.detectedCloudFolders().first {
                config.folderPath = first.path
            }
            config.enabled = true
        case .s3:
            if let s3 = pairing.s3 {
                config.s3 = s3
                if s3.endpoint.hasSuffix(".r2.cloudflarestorage.com"),
                   let host = URL(string: s3.endpoint)?.host,
                   let account = host.split(separator: ".").first {
                    config.cloudflareAccountId = String(account)
                    config.useCustomS3Endpoint = false
                } else {
                    config.useCustomS3Endpoint = true
                }
            }
            config.enabled = true
        case .webdav:
            if let dav = pairing.webdav {
                config.webdav = dav
            }
            config.enabled = true
        }
        lastError = nil
        connectionStatus = .idle
        saveConfig()
        return true
    }

    func testConnection() async {
        connectionStatus = .testing
        do {
            let key = ensureSyncKey()
            let transport = try buildTransport()
            _ = try await WispadSyncEngine.verifyOrInitialize(transport: transport, key: key)
            connectionStatus = .ok
            lastError = nil
        } catch {
            let message = Self.describe(error)
            connectionStatus = .failed(message)
            lastError = message
        }
    }

    /// Déclenche une synchronisation différée (2 s) pour regrouper les éditions rapprochées.
    func scheduleSyncIfEnabled(model: AppModel) {
        guard config.enabled else { return }
        scheduledTask?.cancel()
        scheduledTask = Task { @MainActor [weak self, weak model] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let model, self.config.enabled else { return }
            await self.syncNow(model: model)
        }
    }

    func syncNow(model: AppModel) async {
        if let active = activeSyncTask {
            await active.value
            return
        }
        guard config.enabled else { return }
        let key = ensureSyncKey()
        let transport: any SyncTransport
        do {
            transport = try buildTransport()
        } catch {
            lastError = Self.describe(error)
            return
        }
        let device = deviceIdentity
        let store = model.store
        let sharedSettings = config.syncSharedSettings ? Self.extractSharedSettings(from: model.settings) : nil
        let shouldApplyRemoteSettings = config.syncSharedSettings

        isSyncing = true
        lastError = nil
        let task = Task { @MainActor [weak self, weak model] in
            defer {
                self?.isSyncing = false
                self?.activeSyncTask = nil
            }
            do {
                let report = try await WispadSyncEngine.sync(
                    store: store,
                    device: device,
                    key: key,
                    transport: transport,
                    localSharedSettings: sharedSettings
                )
                guard let self, let model else { return }
                if shouldApplyRemoteSettings, let remote = report.remoteSharedSettings {
                    Self.applySharedSettings(remote, to: model)
                }
                if report.totalPulled > 0 {
                    model.reloadHistory()
                    model.reloadDictionary()
                    model.reloadMeetings()
                }
                self.lastSyncedAt = report.syncedAt
                self.lastError = nil
                self.lastSummary = Self.formatReport(report)
                self.connectionStatus = .ok
            } catch {
                self?.lastError = Self.describe(error)
                Self.log.error("échec de synchronisation")
            }
        }
        activeSyncTask = task
        await task.value
    }

    /// Détecte les dossiers de synchronisation cloud courants sur macOS pour une configuration en un clic.
    static func detectedCloudFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DetectedCloudFolder] {
        let fm = FileManager.default
        let candidates: [(name: String, base: URL, symbol: String)] = [
            ("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true), "icloud"),
            ("OneDrive", home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal", isDirectory: true), "cloud"),
            ("Dropbox", home.appendingPathComponent("Library/CloudStorage/Dropbox", isDirectory: true), "shippingbox"),
            ("Google Drive", home.appendingPathComponent("Library/CloudStorage/GoogleDrive", isDirectory: true), "externaldrive.connected.to.line.below"),
        ]
        var found: [DetectedCloudFolder] = []
        for item in candidates where fm.fileExists(atPath: item.base.path) {
            let target = item.base.appendingPathComponent("WispadSync", isDirectory: true).path
            found.append(DetectedCloudFolder(name: item.name, path: target, symbol: item.symbol))
        }
        return found
    }

    static func extractSharedSettings(from settings: AppSettings) -> SyncSharedSettings? {
        let fields = SharedSettingsFields(
            language: settings.language.rawValue,
            cleanupEnabled: settings.cleanupEnabled,
            structureDictation: settings.structureDictation,
            autoParagraphs: settings.autoParagraphs,
            selectionCommands: settings.selectionCommands,
            speakerAgreement: settings.speakerAgreement.rawValue,
            tones: settings.tones.mapValues(\.rawValue),
            typingWPM: settings.typingWPM
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(fields),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return SyncSharedSettings(updatedAt: Date().timeIntervalSince1970, fieldsJSON: json)
    }

    static func applySharedSettings(_ remote: SyncSharedSettings, to model: AppModel) {
        guard let fields = try? JSONDecoder().decode(SharedSettingsFields.self, from: Data(remote.fieldsJSON.utf8)) else {
            return
        }
        var changed = false
        if let lang = DictationLanguage(rawValue: fields.language), model.settings.language != lang {
            model.settings.language = lang; changed = true
        }
        if model.settings.cleanupEnabled != fields.cleanupEnabled {
            model.settings.cleanupEnabled = fields.cleanupEnabled; changed = true
        }
        if model.settings.structureDictation != fields.structureDictation {
            model.settings.structureDictation = fields.structureDictation; changed = true
        }
        if model.settings.autoParagraphs != fields.autoParagraphs {
            model.settings.autoParagraphs = fields.autoParagraphs; changed = true
        }
        if model.settings.selectionCommands != fields.selectionCommands {
            model.settings.selectionCommands = fields.selectionCommands; changed = true
        }
        if let agr = SpeakerAgreement(rawValue: fields.speakerAgreement), model.settings.speakerAgreement != agr {
            model.settings.speakerAgreement = agr; changed = true
        }
        if (1...1_000).contains(fields.typingWPM), abs(model.settings.typingWPM - fields.typingWPM) > 0.1 {
            model.settings.typingWPM = fields.typingWPM; changed = true
        }
        var parsedTones: [String: DictationTone] = [:]
        for (k, v) in fields.tones {
            if let tone = DictationTone(rawValue: v) { parsedTones[k] = tone }
        }
        if !parsedTones.isEmpty, model.settings.tones != parsedTones {
            model.settings.tones = parsedTones; changed = true
        }
        if changed { model.saveSettings() }
    }

    private static func formatReport(_ report: SyncReport) -> String {
        if report.totalPulled == 0 && report.totalPushed == 0 {
            return String(localized: "Tout est déjà à jour.")
        }
        return String(localized: "Reçu : \(report.totalPulled) · Envoyé : \(report.totalPushed)")
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case SyncTransportError.invalidConfiguration:
            return String(localized: "Configuration incomplète : vérifie les champs requis.")
        case SyncTransportError.unauthorized:
            return String(localized: "Accès refusé : vérifie tes identifiants de stockage.")
        case SyncTransportError.httpStatus(let code):
            return String(localized: "Le serveur distant a répondu HTTP \(code).")
        case SyncEngineError.vaultMismatch:
            return String(localized: "Ce stockage contient un autre coffre Wispad (clé différente).")
        case SyncEngineError.incompatibleVersion:
            return String(localized: "Ce coffre nécessite une version plus récente de Wispad.")
        case is SyncCryptoError:
            return String(localized: "Clé de synchronisation incorrecte : déchiffrement impossible.")
        default:
            return error.localizedDescription
        }
    }
}
