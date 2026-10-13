import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

private final class OfflineAudio: AudioRecording, @unchecked Sendable {
    var onPCM: (@Sendable (Data) -> Void)?
    let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    private var url: URL?

    func start(directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 128).write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) { (url, 2) }
}

private final class OfflineStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    var fail = false
    func start() async throws {}
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish {
        if fail { throw URLError(.notConnectedToInternet) }
        return StreamFinish(text: "Texte du cloud.", endingFinalized: true)
    }
    func cancel() {}
}

/// Transcription dans le cloud ; la connexion est simulée. Aucun réseau, aucun vrai micro.
@MainActor
private final class OfflineFixture {
    let directory: URL
    let audio = OfflineAudio()
    let stream = OfflineStream()
    var online = false
    var sessions = 0
    var transcribed: [SpeechRequest] = []
    var cleanEnabled: [Bool] = []
    var inserted: [String] = []
    var model: AppModel!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-offline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var deps = AppDependencies()
        deps.copyText = { _ in }
        deps.loadKey = { "fixture-" + $0 }
        deps.saveKey = { _, _ in true }
        deps.refreshKeys = { true }
        deps.requestMicrophone = { true }
        deps.captureContext = { let context = DictationContext(); context.pid = 4242; return (context, Task { nil }) }
        deps.readWindow = { _ in nil }
        deps.makeCapture = { [audio] in audio }
        deps.makeSession = { [weak self] _ in
            self?.sessions += 1
            return self?.stream ?? OfflineStream()
        }
        deps.transcribe = { [weak self] _, request in
            self?.transcribed.append(request)
            if self?.online == false { throw URLError(.notConnectedToInternet) }
            return "Texte du cloud."
        }
        deps.isOnline = { [weak self] in self?.online ?? true }
        deps.clean = { [weak self] text, _, _, enabled in
            self?.cleanEnabled.append(enabled)
            return CleanupOutcome(text: text)
        }
        deps.playCue = { _ in }
        deps.muteOutput = { _, _ in }
        deps.restoreOutput = {}
        deps.watchCorrections = { _, _, _, _ in }
        deps.insert = { [weak self] text, _, _, _ in
            self?.inserted.append(text)
            return .inserted
        }
        var settings = AppSettings()
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.structureDictation = false
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: deps)
        model.overlay.displaysPanel = false
    }

    func dictate() async {
        await model.coordinator.begin(.toggle)
        await model.coordinator.end()
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct OfflineVoiceTests {
    /// Sans connexion, rien n'est transcrit ailleurs : l'audio reste dans l'historique pour Retranscrire.
    @Test func withoutConnectionTheAudioWaitsInTheHistory() async throws {
        let f = try OfflineFixture()
        defer { f.dispose() }
        f.stream.fail = true
        await f.dictate()

        #expect(f.sessions == 1)
        #expect(!f.transcribed.isEmpty)
        #expect(f.cleanEnabled.isEmpty)
        #expect(f.inserted.isEmpty)
        let record = try #require(f.model.history.first)
        #expect(record.insertionStatus == InsertionStatus.transcriptionFailed.rawValue)
        let path = try #require(record.audioPath)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func connectionBackRetranscribesTheKeptAudio() async throws {
        let f = try OfflineFixture()
        defer { f.dispose() }
        f.stream.fail = true
        await f.dictate()
        let record = try #require(f.model.history.first)

        f.online = true
        await f.model.coordinator.retranscribe(record)

        let updated = try #require(f.model.history.first(where: { $0.id == record.id }))
        #expect(updated.finalText == "Texte du cloud.")
        #expect(updated.insertionStatus == InsertionStatus.pending.rawValue)
        #expect(f.cleanEnabled == [true])
    }

    @Test func connectionMeansTheCloudAsUsual() async throws {
        let f = try OfflineFixture()
        defer { f.dispose() }
        f.online = true
        await f.dictate()

        #expect(f.sessions == 1)
        #expect(f.inserted == ["Texte du cloud."])
    }
}
