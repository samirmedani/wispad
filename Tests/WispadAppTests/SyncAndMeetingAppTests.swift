import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
struct SyncAndMeetingAppTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispad-app-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func historyRowItemDisplaysRemoteDeviceProvenanceAndLocalAudioNotice() {
        let localID = "mac-local-1"
        let remoteRecord = DictationRecord(
            id: "r-win-1",
            finalText: "Compte rendu envoyé depuis le PC.",
            rawText: "compte rendu envoye depuis le pc",
            durationSeconds: 3.5,
            wordCount: 6,
            provider: "xai",
            model: "grok-voice-transcribe-1.0",
            insertionStatus: "inserted",
            audioPath: nil,
            sourceDeviceID: "win-remote-2",
            sourceDeviceName: "PC Bureau",
            sourceDevicePlatform: DevicePlatform.windows.rawValue
        )
        let row = HistoryRowItem(remoteRecord, localDeviceID: localID)
        #expect(row.isRemoteDevice)
        #expect(row.sourceDeviceName == "PC Bureau")
        #expect(row.sourceDeviceSymbol == "desktopcomputer")
        #expect(!row.hasAudio)
        #expect(row.remoteAudioHelp?.contains("PC Bureau") == true)

        let localRecord = DictationRecord(
            id: "r-mac-1",
            finalText: "Dictée locale.",
            rawText: "dictee locale",
            durationSeconds: 2.0,
            wordCount: 2,
            provider: "xai",
            model: "grok-voice-transcribe-1.0",
            insertionStatus: "inserted",
            audioPath: "/tmp/local.wav",
            sourceDeviceID: localID,
            sourceDeviceName: "MacBook",
            sourceDevicePlatform: DevicePlatform.macos.rawValue
        )
        let localRow = HistoryRowItem(localRecord, localDeviceID: localID)
        #expect(!localRow.isRemoteDevice)
        #expect(localRow.hasAudio)
        #expect(localRow.remoteAudioHelp == nil)
    }

    @Test func syncControllerPairsAndSyncsDictationsAndMeetingsBetweenTwoModels() async throws {
        let dirA = try makeTempDir()
        let dirB = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
            try? FileManager.default.removeItem(at: vaultDir)
        }

        let modelA = try AppModel(supportDirectory: dirA, settings: AppSettings())
        let modelB = try AppModel(supportDirectory: dirB, settings: AppSettings())

        modelA.sync.config.deviceName = "Mac Studio"
        modelA.sync.config.backend = .folder
        modelA.sync.config.folderPath = vaultDir.path
        _ = modelA.sync.ensureSyncKey()
        modelA.sync.config.enabled = true

        let pairingURI = try #require(modelA.sync.pairingURI())
        #expect(pairingURI.hasPrefix("wispad-sync://v1?data="))
        #expect(SyncController.qrImage(from: pairingURI, dimension: 120) != nil)

        #expect(modelB.sync.applyPairingURI(pairingURI))
        modelB.sync.config.deviceName = "MacBook Air"
        modelB.sync.config.folderPath = vaultDir.path
        modelB.sync.config.enabled = true

        try modelA.store.insert(DictationRecord(
            id: "d-sync-1",
            createdAt: Date(timeIntervalSince1970: 1_800_001_000),
            finalText: "Note dictée sur le Mac Studio.",
            rawText: "note dictee sur le mac studio",
            durationSeconds: 4.0,
            wordCount: 6,
            provider: "xai",
            model: "grok-voice-transcribe-1.0",
            insertionStatus: "inserted",
            audioPath: "/tmp/studio-only.wav",
            sourceDeviceID: modelA.sync.config.deviceId,
            sourceDeviceName: "Mac Studio",
            sourceDevicePlatform: DevicePlatform.macos.rawValue
        ))
        modelA.saveMeeting(MeetingRecord(
            id: "m-sync-1",
            title: "Point architecture",
            createdAt: Date(timeIntervalSince1970: 1_800_001_100),
            updatedAt: Date(timeIntervalSince1970: 1_800_001_100),
            durationSeconds: 300,
            userNotes: "- Valider le protocole BYOS",
            rawTranscript: "On valide le protocole BYOS chiffré.",
            enhancedNotes: "## Décisions\n- Protocole BYOS validé.",
            sourceDeviceID: modelA.sync.config.deviceId,
            sourceDeviceName: "Mac Studio",
            sourceDevicePlatform: DevicePlatform.macos.rawValue
        ))

        await modelA.sync.syncNow(model: modelA)
        await modelB.sync.syncNow(model: modelB)

        let syncedDictation = try #require(modelB.history.first(where: { $0.id == "d-sync-1" }))
        #expect(syncedDictation.finalText == "Note dictée sur le Mac Studio.")
        #expect(syncedDictation.audioPath == nil)
        #expect(syncedDictation.isFromRemoteDevice(localDeviceID: modelB.sync.config.deviceId))
        #expect(syncedDictation.sourceDeviceName == "Mac Studio")

        let syncedMeeting = try #require(modelB.meetings.first(where: { $0.id == "m-sync-1" }))
        #expect(syncedMeeting.title == "Point architecture")
        #expect(syncedMeeting.enhancedNotes.contains("Protocole BYOS"))
    }
}
