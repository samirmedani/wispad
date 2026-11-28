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
    public var skippedPeerBlobs: Int
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
        skippedPeerBlobs: Int = 0,
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
        self.skippedPeerBlobs = skippedPeerBlobs
        self.updatedSharedSettings = updatedSharedSettings
        self.remoteSharedSettings = remoteSharedSettings
        self.syncedAt = syncedAt
    }

    public var totalPulled: Int { pulledDictations + pulledMeetings + pulledTerms }
    public var totalPushed: Int { pushedDictations + pushedMeetings + pushedTerms }
}

/// Moteur local-first de synchronisation E2EE BYOS :
/// - chaque appareil écrit uniquement dans `devices/<deviceId>/<seq:06>.wsp.enc` (zéro conflit d'écriture) ;
/// - suit uniquement les mutations locales via `sync_outbox` (zéro boucle d'écho, zéro perte par dérive d'horloge) ;
/// - exécute toutes les lectures/écritures SQLite hors du pool coopératif Swift (`BlockingQueue`) ;
/// - isole les fichiers partiels/corrompus d'un pair sans bloquer les autres pairs ni l'envoi local.
public enum WispadSyncEngine {
    public static let manifestPath = "manifest.json"
    public static let devicesPrefix = "devices"
    public static let maxItemsPerDelta = 500
    private static let storeQueue = BlockingQueue(label: "wispad.sync.store", qos: .utility)

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
    /// `localSharedSettings` ne doit être passé (non nil) que si les réglages locaux ont réellement changé depuis le dernier push,
    /// ou avec son horodatage réel de dernière modification locale (jamais `Date()` à chaque tick).
    public static func sync(
        store: HistoryStore,
        device: DeviceIdentity,
        key: SyncKey,
        transport: any SyncTransport,
        localSharedSettings: SyncSharedSettings? = nil,
        localSharedSettingsDirty: Bool = false,
        applySharedSettings: ((SyncSharedSettings) -> Void)? = nil
    ) async throws -> SyncReport {
        _ = try await verifyOrInitialize(transport: transport, key: key)
        var report = SyncReport()

        // 1. LIST : recenser les deltas distants et le plus grand numéro déjà présent pour cet appareil (survie réinstallation).
        let allPaths = try await transport.list(prefix: devicesPrefix)
        var maxSelfRemoteSequence = 0
        var remoteDeltas: [(path: String, deviceId: String, sequence: Int)] = []
        for path in allPaths {
            guard let parsed = parseDeltaPath(path) else { continue }
            if parsed.deviceId == device.deviceId {
                maxSelfRemoteSequence = max(maxSelfRemoteSequence, parsed.sequence)
            } else {
                remoteDeltas.append((path, parsed.deviceId, parsed.sequence))
            }
        }
        remoteDeltas.sort { $0.deviceId == $1.deviceId ? $0.sequence < $1.sequence : $0.deviceId < $1.deviceId }

        // 2. PULL : lire et appliquer les nouveaux deltas de chaque pair (une transaction SQLite atomique par delta).
        var latestRemoteSettings: SyncSharedSettings?
        var appliedByDevice: [String: Int] = [:]
        var stalledPeers: Set<String> = []
        for entry in remoteDeltas {
            if stalledPeers.contains(entry.deviceId) { continue }
            let lastApplied: Int
            if let cached = appliedByDevice[entry.deviceId] {
                lastApplied = cached
            } else {
                lastApplied = try await storeQueue.run { try store.syncCursor(for: entry.deviceId) }
                appliedByDevice[entry.deviceId] = lastApplied
            }
            guard entry.sequence > lastApplied else { continue }
            guard let encrypted = try await transport.get(path: entry.path) else { continue }

            // Un fichier partiellement synchronisé par Dropbox/OneDrive ne bloque pas les autres pairs ni le push.
            let delta: SyncDelta
            do {
                let plaintext = try key.open(encrypted, relativePath: entry.path)
                delta = try JSONDecoder().decode(SyncDelta.self, from: plaintext)
            } catch {
                stalledPeers.insert(entry.deviceId)
                report.skippedPeerBlobs += 1
                continue
            }

            let counts = try await storeQueue.run {
                try store.applyRemoteDelta(delta, peerDeviceID: entry.deviceId, sequence: entry.sequence)
            }
            report.pulledDictations += counts.dictations
            report.pulledMeetings += counts.meetings
            report.pulledTerms += counts.terms

            if let remoteSettings = delta.sharedSettings {
                if latestRemoteSettings == nil || remoteSettings.updatedAt > (latestRemoteSettings?.updatedAt ?? 0) {
                    latestRemoteSettings = remoteSettings
                }
            }
            appliedByDevice[entry.deviceId] = entry.sequence
        }

        var remoteSettingsApplied = false
        if let remoteSettings = latestRemoteSettings {
            let localStamp = localSharedSettings?.updatedAt ?? 0
            if remoteSettings.updatedAt > localStamp {
                applySharedSettings?(remoteSettings)
                report.remoteSharedSettings = remoteSettings
                report.updatedSharedSettings = true
                remoteSettingsApplied = true
            }
        }

        // 3. PUSH : publier uniquement la boîte d'envoi locale (`sync_outbox`) par lots bornés (max 500 éléments).
        let (localCursor, lastPushAt) = try await storeQueue.run {
            (try store.syncCursor(for: device.deviceId), (try? store.lastSyncPushTimestamp()) ?? 0)
        }
        var nextSequence = max(localCursor, maxSelfRemoteSequence) + 1
        var pendingSettingsToPush: SyncSharedSettings? = {
            guard !remoteSettingsApplied, let local = localSharedSettings else { return nil }
            if localSharedSettingsDirty { return local }
            return local.updatedAt > lastPushAt ? local : nil
        }()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        while true {
            let batch = try await storeQueue.run {
                try store.pendingSyncBatch(localDevice: device, limit: maxItemsPerDelta)
            }
            let settingsForThisDelta = pendingSettingsToPush
            if batch.isEmpty && settingsForThisDelta == nil {
                break
            }
            let now = Date().timeIntervalSince1970
            let delta = SyncDelta(
                deviceId: device.deviceId,
                deviceName: device.deviceName,
                devicePlatform: device.platform.rawValue,
                sequence: nextSequence,
                createdAt: now,
                dictations: batch.dictations,
                meetings: batch.meetings,
                dictionary: batch.dictionary,
                refusals: batch.refusals,
                sharedSettings: settingsForThisDelta,
                apiCalls: batch.apiCalls.isEmpty ? nil : batch.apiCalls
            )
            let path = deltaPath(deviceId: device.deviceId, sequence: nextSequence)
            let json = try encoder.encode(delta)
            let encrypted = try key.seal(json, relativePath: path)
            try await transport.put(path: path, data: encrypted)

            let committedSeq = nextSequence
            try await storeQueue.run {
                try store.clearSyncOutbox(batch)
                try store.setSyncCursor(deviceID: device.deviceId, sequence: committedSeq)
                try store.setLastSyncPushTimestamp(now)
            }
            report.pushedSequence = committedSeq
            report.pushedDictations += batch.dictations.count
            report.pushedMeetings += batch.meetings.count
            report.pushedTerms += batch.dictionary.count
            pendingSettingsToPush = nil
            nextSequence += 1

            let batchSize = batch.dictations.count + batch.meetings.count + batch.dictionary.count + batch.refusals.count
                + batch.apiCalls.count
            if batchSize < maxItemsPerDelta { break }
        }

        return report
    }
}
