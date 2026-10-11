import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

private final class StructureTestAudio: AudioRecording, @unchecked Sendable {
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

private final class StructureTestStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    let ready = AsyncResult<Void>()
    let transcript: String
    init(_ transcript: String) { self.transcript = transcript }
    func start() async throws { ready.resolve(.success(())) }
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish { StreamFinish(text: transcript, endingFinalized: true) }
    func cancel() {}
}

/// Toutes les frontières sont fictives : pas de micro, de coffre, de réseau ou de fenêtre.
@MainActor
private final class StructureAppFixture {
    static let transcript = "Première puce vérifier le build. Deuxième puce lancer les tests."
    static let formatted = "- Vérifier le build.\n- Lancer les tests."
    let directory: URL
    let stream = StructureTestStream(transcript)
    var requests: [CorrectionRequest] = []
    var cleanupModes: [Bool] = []
    var insertedTexts: [String] = []
    var captures = 0
    var model: AppModel!

    init(structure: Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-structure-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in "fixture-key" }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        dependencies.captureContext = {
            let context = DictationContext()
            context.pid = 4_242
            context.appName = "Notes"
            return (context, Task { nil })
        }
        dependencies.makeCapture = { [weak self] in
            self?.captures += 1
            return StructureTestAudio()
        }
        dependencies.makeSession = { [weak self] _ in self!.stream }
        dependencies.transcribe = { _, _ in Self.transcript }
        dependencies.clean = { [weak self] text, request, _, enabled in
            self?.requests.append(request)
            self?.cleanupModes.append(enabled)
            return CleanupOutcome(text: request.structureDictation ? DictationStructure.format(text) : text)
        }
        dependencies.playCue = { _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { [weak self] text, _, allowed in
            guard allowed() else { return .cancelled }
            self?.insertedTexts.append(text)
            return .inserted
        }
        var settings = AppSettings()
        settings.structureDictation = structure
        settings.cleanupEnabled = false
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.retention = .keepWithHistory
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    func dictate() async throws {
        await model.coordinator.begin(.toggle)
        try await stream.ready.value()
        await model.coordinator.end()
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct DictationStructureIntegrationTests {
    @Test func oldSettingsEnableStructuringWithoutResettingOtherChoices() throws {
        let old = Data(#"{"cleanupEnabled":false,"blurRecentDictations":true,"typingWPM":73,"companionEnabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.structureDictation)
        #expect(!settings.cleanupEnabled)
        #expect(settings.blurRecentDictations)
        #expect(settings.typingWPM == 73)
    }

    @Test(arguments: [true, false])
    func preferenceSurvivesSettingsEncoding(structure: Bool) throws {
        var settings = AppSettings()
        settings.structureDictation = structure
        settings.cleanupEnabled = false
        settings.blurRecentDictations = true
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }

    @Test(arguments: [true, false])
    func normalDictationCarriesPreferenceAndPastesTheStoredLayout(structure: Bool) async throws {
        let f = try StructureAppFixture(structure: structure)
        defer { f.dispose() }
        try await f.dictate()
        let expected = structure ? StructureAppFixture.formatted : StructureAppFixture.transcript
        let record = try #require(f.model.history.first)
        #expect(f.requests.map(\.structureDictation) == [structure])
        #expect(f.requests.first?.appName == "Notes")
        #expect(f.cleanupModes == [false])
        #expect(record.rawText == StructureAppFixture.transcript)
        #expect(record.finalText == expected)
        #expect(record.wordCount == (structure ? 6 : 10))
        #expect(f.insertedTexts == [expected])
        #expect(record.insertionStatus == InsertionStatus.inserted.rawValue)
        #expect(f.captures == 1)
        #expect(!f.model.usage.contains { $0.api == .deepSeekCleanup || $0.api == .openAICleanup })
    }

    @Test(arguments: [true, false])
    func historyRetryUsesCurrentPreferenceWithoutOpeningMicrophoneOrPasting(structure: Bool) async throws {
        let f = try StructureAppFixture(structure: !structure)
        defer { f.dispose() }
        try await f.dictate()
        let original = try #require(f.model.history.first)
        _ = try #require(original.audioPath)
        f.requests.removeAll()
        f.insertedTexts.removeAll()
        f.model.settings.structureDictation = structure
        await f.model.coordinator.retranscribe(original)
        let updated = try #require(f.model.history.first { $0.id == original.id })
        let expected = structure ? StructureAppFixture.formatted : StructureAppFixture.transcript
        #expect(f.requests.map(\.structureDictation) == [structure])
        #expect(updated.finalText == expected)
        #expect(updated.rawText == StructureAppFixture.transcript)
        #expect(updated.wordCount == (structure ? 6 : 10))
        #expect(updated.insertionStatus == InsertionStatus.pending.rawValue)
        #expect(f.captures == 1)
        #expect(f.insertedTexts.isEmpty)
    }
}
