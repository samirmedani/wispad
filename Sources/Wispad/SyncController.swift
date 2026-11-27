import AppKit
import CoreImage
import CryptoKit
import Foundation
import SystemConfiguration
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
    var sharedSettingsHash = ""
    var sharedSettingsUpdatedAt: Double = 0
    var sharedSettingsDirty = false

    static func defaultDeviceName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "Mac" : host
    }

    init(
        enabled: Bool = false,
        deviceId: String = UUID().uuidString,
        deviceName: String = SyncLocalConfig.defaultDeviceName(),
        backend: SyncBackendKind = .folder,
        syncKeyBase64URL: String = "",
        folderPath: String = "",
        cloudflareAccountId: String = "",
        useCustomS3Endpoint: Bool = false,
        s3: S3SyncConfig = S3SyncConfig(),
        webdav: WebDAVSyncConfig = WebDAVSyncConfig(),
        syncSharedSettings: Bool = true,
        sharedSettingsHash: String = "",
        sharedSettingsUpdatedAt: Double = 0,
        sharedSettingsDirty: Bool = false
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
        self.sharedSettingsHash = sharedSettingsHash
        self.sharedSettingsUpdatedAt = sharedSettingsUpdatedAt
        self.sharedSettingsDirty = sharedSettingsDirty
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? UUID().uuidString
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? SyncLocalConfig.defaultDeviceName()
        backend = try c.decodeIfPresent(SyncBackendKind.self, forKey: .backend) ?? .folder
        syncKeyBase64URL = try c.decodeIfPresent(String.self, forKey: .syncKeyBase64URL) ?? ""
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath) ?? ""
        cloudflareAccountId = try c.decodeIfPresent(String.self, forKey: .cloudflareAccountId) ?? ""
        useCustomS3Endpoint = try c.decodeIfPresent(Bool.self, forKey: .useCustomS3Endpoint) ?? false
        s3 = try c.decodeIfPresent(S3SyncConfig.self, forKey: .s3) ?? S3SyncConfig()
        webdav = try c.decodeIfPresent(WebDAVSyncConfig.self, forKey: .webdav) ?? WebDAVSyncConfig()
        syncSharedSettings = try c.decodeIfPresent(Bool.self, forKey: .syncSharedSettings) ?? true
        sharedSettingsHash = try c.decodeIfPresent(String.self, forKey: .sharedSettingsHash) ?? ""
        sharedSettingsUpdatedAt = try c.decodeIfPresent(Double.self, forKey: .sharedSettingsUpdatedAt) ?? 0
        sharedSettingsDirty = try c.decodeIfPresent(Bool.self, forKey: .sharedSettingsDirty) ?? false
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

    var isStorageConfigured: Bool {
        switch backend {
        case .off: return false
        case .folder: return !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .s3: return effectiveS3Config.isConfigured
        case .webdav: return webdav.isConfigured
        }
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
/// Champs optionnels pour tolérer une évolution de schéma ou un pair d'une autre plateforme.
private struct SharedSettingsFields: Codable, Equatable {
    var language: String?
    var cleanupEnabled: Bool?
    var structureDictation: Bool?
    var autoParagraphs: Bool?
    var selectionCommands: Bool?
    var speakerAgreement: String?
    var tones: [String: String]?
    var typingWPM: Double?
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

    /// Import d'un lien `wispad-sync://` ouvert depuis l'extérieur : toujours confirmé par l'utilisateur avant application.
    var pendingPairingURI: String?
    var pendingPairingSummary: String?

    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var activeSyncTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResync = false
    @ObservationIgnored private var applyingRemoteSettings = false
    nonisolated private static let configQueue = BlockingQueue(label: "wispad.sync-config", qos: .utility)
    nonisolated private static let log = Logger.wispad("synchro")

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
            deviceName: name.isEmpty ? SyncLocalConfig.defaultDeviceName() : name,
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

    /// Sauvegarde atomique sérialisée en permissions 0600 dès la création du fichier temporaire (zéro fenêtre 0644).
    func saveConfig() {
        guard persists else { return }
        let snapshot = config
        let url = configURL
        Task.detached(priority: .utility) {
            await Self.configQueue.run {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(snapshot)
                    let fm = FileManager.default
                    let dir = url.deletingLastPathComponent()
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let staged = dir.appendingPathComponent(".sync-config-\(UUID().uuidString).json")
                    guard fm.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    do {
                        if fm.fileExists(atPath: url.path) {
                            _ = try fm.replaceItemAt(url, withItemAt: staged)
                        } else {
                            try fm.moveItem(at: staged, to: url)
                        }
                        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    } catch {
                        try? fm.removeItem(at: staged)
                        throw error
                    }
                } catch {
                    Self.log.error("écriture sync-config impossible")
                }
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
            let path = config.folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            let hint = URL(fileURLWithPath: path).lastPathComponent
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

    /// Copie le lien d'appairage en marquant le presse-papiers comme confidentiel et transitoire
    /// (ignoré par les gestionnaires d'historique de presse-papiers).
    func copyPairingURI(_ uri: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(uri, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
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

    /// Prépare l'import d'un lien `wispad-sync://` ouvert depuis l'extérieur et demande confirmation.
    func stagePairingImport(_ raw: String) {
        guard let pairing = SyncPairingConfig.parse(uri: raw) else {
            lastError = String(localized: "Lien d'appairage invalide ou incomplet.")
            return
        }
        pendingPairingURI = raw
        switch pairing.backend {
        case .folder:
            let hint = pairing.folderHint ?? "WispadSync"
            pendingPairingSummary = String(localized: "Dossier local ou cloud (« \(hint) »)")
        case .s3:
            let host = pairing.s3.flatMap { URL(string: $0.endpoint)?.host } ?? "S3"
            let bucket = pairing.s3?.bucket ?? ""
            pendingPairingSummary = String(localized: "Stockage S3/R2 : \(host) (bucket \(bucket))")
        case .webdav:
            let host = pairing.webdav.flatMap { URL(string: $0.url)?.host } ?? "WebDAV"
            pendingPairingSummary = String(localized: "Serveur WebDAV : \(host)")
        case .off:
            pendingPairingSummary = String(localized: "Désactivation de la synchronisation")
        }
    }

    func confirmPendingPairing(model: AppModel) {
        guard let raw = pendingPairingURI else { return }
        pendingPairingURI = nil
        pendingPairingSummary = nil
        if applyPairingURI(raw) {
            model.statusBanner = String(localized: "Synchronisation configurée : synchronisation lancée.")
            if config.enabled {
                Task { await syncNow(model: model) }
            }
        }
    }

    func cancelPendingPairing() {
        pendingPairingURI = nil
        pendingPairingSummary = nil
    }

    /// Importe un lien `wispad-sync://v1?data=...` collé ou confirmé par l'utilisateur.
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
            // Ne pas activer si aucun dossier n'a encore été choisi.
            config.enabled = !config.folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .s3:
            if let s3 = pairing.s3 {
                config.s3 = s3
                if let host = URL(string: s3.endpoint)?.host?.lowercased(),
                   host.hasSuffix(".r2.cloudflarestorage.com"),
                   let account = host.split(separator: ".").first {
                    config.cloudflareAccountId = String(account)
                    config.useCustomS3Endpoint = false
                } else {
                    config.useCustomS3Endpoint = true
                }
            }
            config.enabled = config.effectiveS3Config.isConfigured
        case .webdav:
            if let dav = pairing.webdav {
                config.webdav = dav
            }
            config.enabled = config.webdav.isConfigured
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

    /// Vérifie si les réglages d'écriture partagés ont réellement changé localement.
    /// Évite d'écrire un delta à chaque minute ou de boucler après réception d'un réglage distant.
    @discardableResult
    func noteSettingsChanged(_ settings: AppSettings) -> Bool {
        guard !applyingRemoteSettings else { return false }
        guard let json = Self.encodeSharedSettingsJSON(from: settings) else { return false }
        let digest = Self.sha256Hex(json)
        if config.sharedSettingsHash.isEmpty {
            config.sharedSettingsHash = digest
            if config.sharedSettingsUpdatedAt == 0 {
                config.sharedSettingsUpdatedAt = Date().timeIntervalSince1970
            }
            saveConfig()
            return false
        }
        guard digest != config.sharedSettingsHash else { return false }
        config.sharedSettingsHash = digest
        config.sharedSettingsUpdatedAt = Date().timeIntervalSince1970
        config.sharedSettingsDirty = true
        saveConfig()
        return true
    }

    /// Déclenche une synchronisation différée (2 s) pour regrouper les éditions rapprochées.
    func scheduleSyncIfEnabled(model: AppModel) {
        guard config.enabled, config.isStorageConfigured else { return }
        scheduledTask?.cancel()
        scheduledTask = Task { @MainActor [weak self, weak model] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let model, self.config.enabled else { return }
            await self.syncNow(model: model, automatic: true)
        }
    }

    func syncNow(model: AppModel, automatic: Bool = false) async {
        if let active = activeSyncTask {
            pendingResync = true
            await active.value
            return
        }
        guard config.enabled else { return }
        // Hors ligne en synchro automatique : inutile de lancer S3/WebDAV. Le mode dossier local fonctionne hors ligne.
        if automatic, config.backend != .folder, !model.dependencies.isOnline() {
            return
        }
        let key = ensureSyncKey()
        let transport: any SyncTransport
        do {
            transport = try buildTransport()
        } catch {
            if !automatic { lastError = Self.describe(error) }
            return
        }
        let device = deviceIdentity
        let store = model.store
        let shouldSyncSettings = config.syncSharedSettings
        let localShared: SyncSharedSettings? = {
            guard shouldSyncSettings, let json = Self.encodeSharedSettingsJSON(from: model.settings) else { return nil }
            let digest = Self.sha256Hex(json)
            if config.sharedSettingsHash != digest {
                config.sharedSettingsHash = digest
                if config.sharedSettingsUpdatedAt == 0 {
                    config.sharedSettingsUpdatedAt = Date().timeIntervalSince1970
                }
            }
            return SyncSharedSettings(updatedAt: config.sharedSettingsUpdatedAt, fieldsJSON: json)
        }()
        let dirtySettings = shouldSyncSettings && config.sharedSettingsDirty

        isSyncing = true
        if !automatic { lastError = nil }
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
                    localSharedSettings: localShared,
                    localSharedSettingsDirty: dirtySettings
                )
                guard let self, let model else { return }
                if shouldSyncSettings, let remote = report.remoteSharedSettings {
                    self.applySharedSettings(remote, to: model)
                } else if dirtySettings && report.pushedSequence != nil {
                    self.config.sharedSettingsDirty = false
                    self.saveConfig()
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
        if pendingResync {
            pendingResync = false
            await syncNow(model: model, automatic: automatic)
        }
    }

    /// Détecte les dossiers de synchronisation cloud courants sur macOS pour une configuration en un clic.
    static func detectedCloudFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DetectedCloudFolder] {
        let fm = FileManager.default
        var found: [DetectedCloudFolder] = []
        var seenPaths: Set<String> = []

        func appendCandidate(name: String, base: URL, symbol: String) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else { return }
            let target = base.appendingPathComponent("WispadSync", isDirectory: true).path
            if seenPaths.insert(target).inserted {
                found.append(DetectedCloudFolder(name: name, path: target, symbol: symbol))
            }
        }

        // iCloud Drive
        appendCandidate(
            name: "iCloud Drive",
            base: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true),
            symbol: "icloud"
        )

        // CloudStorage dynamique (OneDrive-*, Dropbox*, GoogleDrive-*)
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                if name.hasPrefix("OneDrive") {
                    appendCandidate(name: "OneDrive", base: item, symbol: "cloud")
                } else if name.hasPrefix("Dropbox") {
                    appendCandidate(name: "Dropbox", base: item, symbol: "shippingbox")
                } else if name.hasPrefix("GoogleDrive") {
                    let myDriveEn = item.appendingPathComponent("My Drive", isDirectory: true)
                    let myDriveFr = item.appendingPathComponent("Mon Drive", isDirectory: true)
                    let base = fm.fileExists(atPath: myDriveEn.path) ? myDriveEn : (fm.fileExists(atPath: myDriveFr.path) ? myDriveFr : item)
                    appendCandidate(name: "Google Drive", base: base, symbol: "externaldrive.connected.to.line.below")
                }
            }
        }
        return found
    }

    static func encodeSharedSettingsJSON(from settings: AppSettings) -> String? {
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
        guard let data = try? encoder.encode(fields) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func extractSharedSettings(from settings: AppSettings, updatedAt: Double = Date().timeIntervalSince1970) -> SyncSharedSettings? {
        guard let json = encodeSharedSettingsJSON(from: settings) else { return nil }
        return SyncSharedSettings(updatedAt: updatedAt, fieldsJSON: json)
    }

    func applySharedSettings(_ remote: SyncSharedSettings, to model: AppModel) {
        guard let fields = try? JSONDecoder().decode(SharedSettingsFields.self, from: Data(remote.fieldsJSON.utf8)) else {
            return
        }
        applyingRemoteSettings = true
        defer { applyingRemoteSettings = false }

        var changed = false
        if let rawLang = fields.language, let lang = DictationLanguage(rawValue: rawLang), model.settings.language != lang {
            model.settings.language = lang; changed = true
        }
        if let cleanup = fields.cleanupEnabled, model.settings.cleanupEnabled != cleanup {
            model.settings.cleanupEnabled = cleanup; changed = true
        }
        if let structure = fields.structureDictation, model.settings.structureDictation != structure {
            model.settings.structureDictation = structure; changed = true
        }
        if let paragraphs = fields.autoParagraphs, model.settings.autoParagraphs != paragraphs {
            model.settings.autoParagraphs = paragraphs; changed = true
        }
        if let commands = fields.selectionCommands, model.settings.selectionCommands != commands {
            model.settings.selectionCommands = commands; changed = true
        }
        if let rawAgr = fields.speakerAgreement, let agr = SpeakerAgreement(rawValue: rawAgr), model.settings.speakerAgreement != agr {
            model.settings.speakerAgreement = agr; changed = true
        }
        if let wpm = fields.typingWPM, (1...1_000).contains(wpm), abs(model.settings.typingWPM - wpm) > 0.1 {
            model.settings.typingWPM = wpm; changed = true
        }
        if let rawTones = fields.tones {
            var parsedTones: [String: DictationTone] = [:]
            for (k, v) in rawTones {
                if let tone = DictationTone(rawValue: v) { parsedTones[k] = tone }
            }
            if model.settings.tones != parsedTones {
                model.settings.tones = parsedTones; changed = true
            }
        }
        if changed { model.saveSettings() }

        // Synchronise l'empreinte et l'horodatage locaux pour éviter toute boucle d'écho.
        if let json = Self.encodeSharedSettingsJSON(from: model.settings) {
            config.sharedSettingsHash = Self.sha256Hex(json)
        }
        config.sharedSettingsUpdatedAt = max(config.sharedSettingsUpdatedAt, remote.updatedAt)
        config.sharedSettingsDirty = false
        saveConfig()
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func formatReport(_ report: SyncReport) -> String {
        if report.totalPulled == 0 && report.totalPushed == 0 {
            return report.skippedPeerBlobs > 0
                ? String(localized: "À jour (\(report.skippedPeerBlobs) fichier(s) en attente).")
                : String(localized: "Tout est déjà à jour.")
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
        case SyncEngineError.unreadableManifest:
            return String(localized: "Le manifeste distant est illisible ou endommagé.")
        case is SyncCryptoError:
            return String(localized: "Clé de synchronisation incorrecte : déchiffrement impossible.")
        default:
            return error.localizedDescription
        }
    }
}
