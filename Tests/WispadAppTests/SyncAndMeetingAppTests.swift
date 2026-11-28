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

    @Test func sharedSettingsCarryEveryPortableSettingButNotTheDeviceOnesNorNavigation() throws {
        var settings = AppSettings()
        settings.typingWPM = 55
        settings.soundsEnabled = false
        settings.appearance = .light
        settings.microphoneUID = "micro-exemple"
        settings.launchAtLogin = true
        let json = try #require(SyncController.encodeSharedSettingsJSON(from: settings))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        // Les huit clés lues par Wispad 0.9.0, au même format.
        for key in ["language", "cleanupEnabled", "structureDictation", "autoParagraphs", "selectionCommands",
                    "speakerAgreement", "tones", "typingWPM"] {
            #expect(object[key] != nil, "clé historique absente : \(key)")
        }
        #expect((object["typingWPM"] as? Double) == 55)
        #expect((object["soundsEnabled"] as? Bool) == false)
        #expect((object["appearance"] as? String) == "light")
        #expect(object["provider"] != nil)
        // Ni réglages de l'appareil, ni navigation.
        for key in AppSettings.deviceOnlyKeys.union(SyncController.navigationKeys) {
            #expect(object[key] == nil, "clé non partageable envoyée : \(key)")
        }
    }

    @Test func joiningDeviceAdoptsTheVaultSettingsInsteadOfImposingItsDefaults() async throws {
        let dirA = try makeTempDir()
        let dirB = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
            try? FileManager.default.removeItem(at: vaultDir)
        }

        var customized = AppSettings()
        customized.typingWPM = 55
        customized.soundsEnabled = false
        customized.appearance = .light
        let modelA = try AppModel(supportDirectory: dirA, settings: customized)
        let modelB = try AppModel(supportDirectory: dirB, settings: AppSettings())

        modelA.sync.config.backend = .folder
        modelA.sync.config.folderPath = vaultDir.path
        _ = modelA.sync.ensureSyncKey()
        modelA.sync.config.enabled = true

        // Premier appareil, coffre vide : ses réglages deviennent la référence et partent au passage suivant.
        await modelA.sync.syncNow(model: modelA)
        #expect(modelA.sync.config.sharedSettingsAdopted)
        await modelA.sync.syncNow(model: modelA)

        let pairingURI = try #require(modelA.sync.pairingURI())
        #expect(modelB.sync.applyPairingURI(pairingURI))
        modelB.sync.config.folderPath = vaultDir.path
        modelB.sync.config.enabled = true
        #expect(!modelB.sync.config.sharedSettingsAdopted)

        // L'appareil qui rejoint prend les réglages du coffre, au lieu d'imposer les siens par défaut.
        await modelB.sync.syncNow(model: modelB)
        #expect(modelB.settings.typingWPM == 55)
        #expect(modelB.settings.soundsEnabled == false)
        #expect(modelB.settings.appearance == .light)
        #expect(modelB.sync.config.sharedSettingsAdopted)

        // Et le premier appareil garde les siens.
        await modelA.sync.syncNow(model: modelA)
        #expect(modelA.settings.typingWPM == 55)
        #expect(modelA.settings.soundsEnabled == false)

        // Un réglage changé ensuite sur B arrive sur A.
        modelB.settings.soundsEnabled = true
        modelB.saveSettings()
        await modelB.sync.syncNow(model: modelB)
        await modelA.sync.syncNow(model: modelA)
        #expect(modelA.settings.soundsEnabled == true)
        #expect(modelA.settings.typingWPM == 55)
    }

    @Test func previousVersionConfigurationKeepsItsSettingsAuthority() throws {
        // sync-config.json d'une 0.9.0 déjà synchronisée : ses réglages ont été comparés au coffre.
        let legacy = #"{"enabled":true,"deviceId":"mac-1","sharedSettingsHash":"abc","sharedSettingsUpdatedAt":1800000000}"#
        let config = try JSONDecoder().decode(SyncLocalConfig.self, from: Data(legacy.utf8))
        #expect(config.sharedSettingsAdopted)
        let fresh = try JSONDecoder().decode(SyncLocalConfig.self, from: Data(#"{"enabled":true,"deviceId":"mac-2"}"#.utf8))
        #expect(!fresh.sharedSettingsAdopted)
    }
}
