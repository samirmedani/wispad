import Foundation

public enum SyncEngineError: Error, Equatable, Sendable {
    case vaultMismatch(expected: String, found: String)
    case incompatibleVersion(Int)
    case unreadableManifest
}

public struct SyncReport: Equatable, Sendable {
    public var pushedSequence: Int?
    public var pushedDictations: Int
    public var pushedMeetings: Int
    public var pushedTerms: Int
    public var pulledDictations: Int
    public var pulledMeetings: Int
    public var pulledTerms: Int
    public var updatedSharedSettings: Bool
    public var remoteSharedSettings: SyncSharedSettings?
    public var syncedAt: Date

    public init(
        pushedSequence: Int? = nil,
        pushedDictations: Int = 0,
        pushedMeetings: Int = 0,
        pushedTerms: Int = 0,
        pulledDictations: Int = 0,
        pulledMeetings: Int = 0,
        pulledTerms: Int = 0,
        updatedSharedSettings: Bool = false,
        remoteSharedSettings: SyncSharedSettings? = nil,
        syncedAt: Date = Date()
    ) {
        self.pushedSequence = pushedSequence
        self.pushedDictations = pushedDictations
        self.pushedMeetings = pushedMeetings
        self.pushedTerms = pushedTerms
        self.pulledDictations = pulledDictations
        self.pulledMeetings = pulledMeetings
        self.pulledTerms = pulledTerms
        self.updatedSharedSettings = updatedSharedSettings
        self.remoteSharedSettings = remoteSharedSettings
        self.syncedAt = syncedAt
    }

    public var totalPulled: Int { pulledDictations + pulledMeetings + pulledTerms }
    public var totalPushed: Int { pushedDictations + pushedMeetings + pushedTerms }
}

/// Moteur local-first de synchronisation E2EE BYOS :
/// - chaque appareil écrit uniquement dans son dossier `devices/<deviceId>/<seq>.wsp.enc` (zéro conflit d'écriture) ;
/// - seuls le texte, le dictionnaire, les réunions et les réglages partagés transitent (quelques Ko, jamais l'audio) ;
/// - chaque dictée distante garde l'identité de son appareil d'origine (`sourceDeviceName`, `sourceDevicePlatform`).
public enum WispadSyncEngine {
    public static let manifestPath = "manifest.json"
    public static let devicesPrefix = "devices"

    public static func deltaPath(deviceId: String, sequence: Int) -> String {
        let padded = String(format: "%06d", sequence)
        return "\(devicesPrefix)/\(deviceId)/\(padded).wsp.enc"
    }

    public static func parseDeltaPath(_ path: String) -> (deviceId: String, sequence: Int)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == devicesPrefix, parts[2].hasSuffix(".wsp.enc") else { return nil }
        let stem = String(parts[2].dropLast(".wsp.enc".count))
        guard let seq = Int(stem), seq > 0 else { return nil }
        return (parts[1], seq)
    }

    /// Vérifie la connexion au stockage BYOS et valide (ou initialise) `manifest.json`.
    public static func verifyOrInitialize(transport: any SyncTransport, key: SyncKey) async throws -> SyncManifest {
        if let raw = try await transport.get(path: manifestPath) {
            guard let manifest = try? JSONDecoder().decode(SyncManifest.self, from: raw),
                  manifest.format == SyncManifest.expectedFormat else {
                throw SyncEngineError.unreadableManifest
            }
            if manifest.version > SyncManifest.currentVersion {
                throw SyncEngineError.incompatibleVersion(manifest.version)
            }
            if manifest.vaultId != key.vaultID {
                throw SyncEngineError.vaultMismatch(expected: key.vaultID, found: manifest.vaultId)
            }
            return manifest
        }
        let fresh = SyncManifest(vaultId: key.vaultID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let encoded = try encoder.encode(fresh)
        try await transport.put(path: manifestPath, data: encoded)
        return fresh
    }

    /// Exécute un cycle complet pull + push sur le stockage BYOS chiffré.
    public static func sync(
        store: HistoryStore,
        device: DeviceIdentity,
        key: SyncKey,
        transport: any SyncTransport,
        localSharedSettings: SyncSharedSettings? = nil,
        applySharedSettings: ((SyncSharedSettings) -> Void)? = nil
    ) async throws -> SyncReport {
        _ = try await verifyOrInitialize(transport: transport, key: key)
        var report = SyncReport()

        // 1. PULL : lire les nouveaux deltas de chaque autre appareil.
        let allPaths = try await transport.list(prefix: devicesPrefix)
        let remoteDeltas = allPaths
            .compactMap { path -> (path: String, deviceId: String, sequence: Int)? in
                guard let parsed = parseDeltaPath(path), parsed.deviceId != device.deviceId else { return nil }
                return (path, parsed.deviceId, parsed.sequence)
            }
            .sorted { $0.deviceId == $1.deviceId ? $0.sequence < $1.sequence : $0.deviceId < $1.deviceId }

        var latestRemoteSettings: SyncSharedSettings?
        var appliedByDevice: [String: Int] = [:]
        for entry in remoteDeltas {
            let lastApplied: Int
            if let cached = appliedByDevice[entry.deviceId] {
                lastApplied = cached
            } else {
                lastApplied = try store.syncCursor(for: entry.deviceId)
            }
            guard entry.sequence > lastApplied else { continue }
            guard let encrypted = try await transport.get(path: entry.path) else { continue }
            let plaintext = try key.open(encrypted, relativePath: entry.path)
            let delta = try JSONDecoder().decode(SyncDelta.self, from: plaintext)

            for item in delta.dictations {
                if try store.applySyncedDictation(item, localDeviceID: device.deviceId) {
                    report.pulledDictations += 1
                }
            }
            for meeting in delta.meetings {
                if try store.applySyncedMeeting(meeting) {
                    report.pulledMeetings += 1
                }
            }
            for term in delta.dictionary {
                if try store.applySyncedDictionaryTerm(term) {
                    report.pulledTerms += 1
                }
            }
            for refusal in delta.refusals {
                try store.rememberRefusal(refusal.term)
            }
            if let remoteSettings = delta.sharedSettings {
                if latestRemoteSettings == nil || remoteSettings.updatedAt > (latestRemoteSettings?.updatedAt ?? 0) {
                    latestRemoteSettings = remoteSettings
                }
            }
            try store.setSyncCursor(deviceID: entry.deviceId, sequence: entry.sequence)
            appliedByDevice[entry.deviceId] = entry.sequence
        }

        if let remoteSettings = latestRemoteSettings {
            let localStamp = localSharedSettings?.updatedAt ?? 0
            if remoteSettings.updatedAt > localStamp {
                applySharedSettings?(remoteSettings)
                report.remoteSharedSettings = remoteSettings
                report.updatedSharedSettings = true
            }
        }

        // 2. PUSH : publier les changements locaux depuis la dernière synchro (texte seul, zéro audio).
        let lastPushAt = try store.lastSyncPushTimestamp()
        let nextSequence = (try store.syncCursor(for: device.deviceId)) + 1
        let now = Date().timeIntervalSince1970

        let dictationsToPush = try store.dictationsForSync(modifiedAfter: lastPushAt, localDevice: device)
        let meetingsToPush = try store.meetingsForSync(modifiedAfter: lastPushAt, localDevice: device)
        let termsToPush = try store.dictionaryForSync(modifiedAfter: lastPushAt)
        let refusalsToPush = try store.refusalsForSync(createdAfter: lastPushAt)
        let settingsToPush: SyncSharedSettings? = {
            guard let local = localSharedSettings, local.updatedAt > lastPushAt else { return nil }
            return local
        }()

        let delta = SyncDelta(
            deviceId: device.deviceId,
            deviceName: device.deviceName,
            devicePlatform: device.platform.rawValue,
            sequence: nextSequence,
            createdAt: now,
            dictations: dictationsToPush,
            meetings: meetingsToPush,
            dictionary: termsToPush,
            refusals: refusalsToPush,
            sharedSettings: settingsToPush
        )

        if !delta.isEmpty {
            let path = deltaPath(deviceId: device.deviceId, sequence: nextSequence)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = try encoder.encode(delta)
            let encrypted = try key.seal(json, relativePath: path)
            try await transport.put(path: path, data: encrypted)
            try store.setSyncCursor(deviceID: device.deviceId, sequence: nextSequence)
            try store.setLastSyncPushTimestamp(now)
            report.pushedSequence = nextSequence
            report.pushedDictations = dictationsToPush.count
            report.pushedMeetings = meetingsToPush.count
            report.pushedTerms = termsToPush.count
        }
        report.syncedAt = Date()
        return report
    }
}
