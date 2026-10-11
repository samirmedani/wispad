import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
private final class IntegrationAudioPlayback: HistoryAudioPlayback {
    let duration: TimeInterval = 30
    var currentTime: TimeInterval = 0
    var onCompletion: (@MainActor (Bool) -> Void)?
    var isPlaying = false
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) { self.onStop = onStop }

    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; onStop() }
}

@MainActor
private final class IntegrationAudioLog {
    weak var active: IntegrationAudioPlayback?
    var loads = 0
    var stops = 0
}

/// Fichiers fictifs et décodeur factice : aucun périphérique audio ni service externe.
@MainActor
private final class HistoryAudioIntegrationFixture {
    let directory: URL
    let log: IntegrationAudioLog
    let model: AppModel

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispad-playback-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = IntegrationAudioLog()
        self.log = log
        let player = HistoryAudioPlayer { _ in
            log.loads += 1
            let playback = IntegrationAudioPlayback { log.stops += 1 }
            log.active = playback
            return playback
        }
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in nil }
        dependencies.refreshKeys = { false }
        dependencies.requestMicrophone = { false }
        model = try AppModel(
            supportDirectory: directory,
            settings: AppSettings(),
            dependencies: dependencies,
            historyPlayer: player
        )
        model.overlay.displaysPanel = false
        model.selectedSection = .history
    }

    func record(id: String, expiresAt: Date? = nil) throws -> DictationRecord {
        let url = directory.appendingPathComponent("\(id).wav")
        // Seule l'existence du fichier est vérifiée par AppModel. Le faux backend ne le décode pas.
        try Data(repeating: 0, count: 64).write(to: url)
        let record = DictationRecord(
            id: id,
            finalText: "Dictée fictive.",
            rawText: "Dictée fictive.",
            durationSeconds: 30,
            wordCount: 2,
            provider: "fixture",
            model: "fixture",
            insertionStatus: InsertionStatus.inserted.rawValue,
            audioPath: url.path,
            audioExpiresAt: expiresAt
        )
        try model.store.insert(record)
        model.reloadHistory()
        return record
    }

    func dispose() {
        model.historyPlayer.close()
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct HistoryAudioIntegrationTests {
    @Test func leavingHistoryStopsAndReleasesPlaybackButKeepsTheRecording() throws {
        let fixture = try HistoryAudioIntegrationFixture()
        defer { fixture.dispose() }
        let record = try fixture.record(id: "selected")
        fixture.model.play(record)
        #expect(fixture.log.active?.isPlaying == true)

        fixture.model.selectedSection = .history
        #expect(fixture.model.historyPlayer.isPlaying)
        #expect(fixture.log.stops == 0)
        fixture.model.selectedSection = .usage

        #expect(!fixture.model.historyPlayer.isPlaying)
        #expect(fixture.model.historyPlayer.recordID == nil)
        #expect(fixture.log.stops == 1)
        #expect(fixture.log.active == nil)
        #expect(fixture.model.history.map(\.id) == [record.id])
        #expect(FileManager.default.fileExists(atPath: try #require(record.audioPath)))
    }

    @Test func deletingAnotherRecordKeepsPlaybackUntilItsOwnRecordIsDeleted() throws {
        let fixture = try HistoryAudioIntegrationFixture()
        defer { fixture.dispose() }
        let selected = try fixture.record(id: "selected")
        let other = try fixture.record(id: "other")
        fixture.model.play(selected)

        fixture.model.deleteHistory(other)
        #expect(fixture.model.historyPlayer.isPlaying)
        #expect(fixture.model.historyPlayer.recordID == selected.id)
        #expect(fixture.log.stops == 0)
        #expect(!FileManager.default.fileExists(atPath: try #require(other.audioPath)))

        fixture.model.deleteHistory(selected)
        #expect(fixture.model.historyPlayer.recordID == nil)
        #expect(fixture.log.stops == 1)
        #expect(fixture.log.active == nil)
        #expect(fixture.model.history.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(selected.audioPath)))
    }

    @Test func deletingAllHistoryStopsPlaybackAndRemovesTheFiles() throws {
        let fixture = try HistoryAudioIntegrationFixture()
        defer { fixture.dispose() }
        let selected = try fixture.record(id: "selected")
        let other = try fixture.record(id: "other")
        fixture.model.play(selected)

        fixture.model.deleteAllHistory()

        #expect(fixture.model.historyPlayer.recordID == nil)
        #expect(fixture.log.stops == 1)
        #expect(fixture.log.active == nil)
        #expect(fixture.model.history.isEmpty)
        #expect(try fixture.model.store.dictations().isEmpty)
        for record in [selected, other] {
            #expect(!FileManager.default.fileExists(atPath: try #require(record.audioPath)))
        }
    }

    @Test func retentionStopsAnExpiredSelectionAndKeepsItsTranscript() throws {
        let fixture = try HistoryAudioIntegrationFixture()
        defer { fixture.dispose() }
        let record = try fixture.record(id: "expired", expiresAt: Date().addingTimeInterval(-60))
        fixture.model.play(record)
        #expect(fixture.model.historyPlayer.isPlaying)

        fixture.model.purgeAudio()

        #expect(fixture.model.historyPlayer.recordID == nil)
        #expect(fixture.log.stops == 1)
        #expect(fixture.log.active == nil)
        #expect(!FileManager.default.fileExists(atPath: try #require(record.audioPath)))
        let retained = try #require(fixture.model.history.first)
        #expect(retained.id == record.id)
        #expect(retained.audioPath == nil)
        #expect(retained.finalText == record.finalText)
    }

    @Test func retentionOfAnotherFileDoesNotInterruptTheSelectedAudio() throws {
        let fixture = try HistoryAudioIntegrationFixture()
        defer { fixture.dispose() }
        let selected = try fixture.record(id: "selected")
        let expired = try fixture.record(id: "expired", expiresAt: Date().addingTimeInterval(-60))
        fixture.model.play(selected)

        fixture.model.purgeAudio()

        #expect(fixture.model.historyPlayer.isPlaying)
        #expect(fixture.model.historyPlayer.recordID == selected.id)
        #expect(fixture.log.stops == 0)
        #expect(fixture.log.active?.isPlaying == true)
        #expect(!FileManager.default.fileExists(atPath: try #require(expired.audioPath)))
        #expect(FileManager.default.fileExists(atPath: try #require(selected.audioPath)))
    }

    @Test func startingDictationClosesPlaybackAndPreventsReplayUntilTheMicIsFree() throws {
        let fixture = try HistoryAudioIntegrationFixture()
        defer { fixture.dispose() }
        let record = try fixture.record(id: "selected")
        fixture.model.play(record)

        // Tester la transition ne demande ni autorisation ni ouverture du microphone.
        fixture.model.coordinator.phase = .starting
        #expect(fixture.model.historyPlayer.recordID == nil)
        #expect(fixture.log.stops == 1)
        #expect(fixture.log.active == nil)
        fixture.model.play(record)
        #expect(fixture.log.loads == 1)
        #expect(!fixture.model.historyPlayer.isPlaying)
        #expect(fixture.model.statusBanner == "Termine la dictée avant d'écouter un audio.")

        for mode: ListenMode in [.toggle, .pushToTalk] {
            fixture.model.coordinator.phase = .listening(mode)
            fixture.model.play(record)
            #expect(fixture.log.loads == 1)
            #expect(fixture.model.historyPlayer.recordID == nil)
        }
        fixture.model.coordinator.phase = .idle
        fixture.model.play(record)
        #expect(fixture.log.loads == 2)
        #expect(fixture.model.historyPlayer.isPlaying)
    }

    @Test func reloadingAnAudioRemovedFromStorageClosesItsPlayer() throws {
        let fixture = try HistoryAudioIntegrationFixture()
        defer { fixture.dispose() }
        let record = try fixture.record(id: "selected")
        fixture.model.play(record)

        try fixture.model.store.updateAudio(id: record.id, path: nil, expiresAt: nil)
        fixture.model.reloadHistory()

        #expect(fixture.model.historyPlayer.recordID == nil)
        #expect(fixture.log.stops == 1)
        #expect(fixture.log.active == nil)
        #expect(fixture.model.history.first?.audioPath == nil)
    }

    @Test func anUnavailableAudioClosesThePreviousPlaybackWithoutLoadingItAgain() throws {
        let fixture = try HistoryAudioIntegrationFixture()
        defer { fixture.dispose() }
        let record = try fixture.record(id: "selected")
        fixture.model.play(record)
        try FileManager.default.removeItem(atPath: try #require(record.audioPath))

        fixture.model.play(record)

        #expect(fixture.log.loads == 1)
        #expect(fixture.log.stops == 1)
        #expect(fixture.log.active == nil)
        #expect(fixture.model.historyPlayer.recordID == nil)
        #expect(fixture.model.statusBanner == "L'audio n'est plus disponible.")
    }
}
