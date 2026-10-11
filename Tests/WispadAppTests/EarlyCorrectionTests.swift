import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

private final class EarlyAudio: AudioRecording, @unchecked Sendable {
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

    func stop() -> (url: URL?, duration: Double) { (url, 3) }
}

private final class EarlyStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    var onSettled: (@Sendable (String) -> Void)?
    var text = ""
    func start() async throws {}
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish { StreamFinish(text: text, endingFinalized: true) }
    func cancel() {}
}

/// Flux, fichier, correction et collage simulés ; la correction rend le texte en majuscules pour la reconnaître.
@MainActor
private final class EarlyFixture {
    let directory: URL
    let audio = EarlyAudio()
    let stream = EarlyStream()
    var fileText = ""
    var cleanTexts: [String] = []
    var inserted: [String] = []
    var model: AppModel!

    init(verifyWithFile: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-early-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { "fixture-" + $0 }
        dependencies.saveKey = { _, _ in true }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        dependencies.captureContext = {
            let context = DictationContext()
            context.pid = 4_242
            context.bundleID = "com.example.fictif.editeur"
            context.appName = "Éditeur fictif"
            return (context, Task { nil })
        }
        dependencies.readWindow = { _ in nil }
        dependencies.makeCapture = { [audio] in audio }
        dependencies.makeSession = { [stream] _ in stream }
        dependencies.transcribe = { [weak self] _, _ in self?.fileText ?? "" }
        dependencies.clean = { [weak self] text, _, _, enabled in
            self?.cleanTexts.append(text)
            guard enabled else { return CleanupOutcome(text: text) }
            let usage = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.00001)
            return CleanupOutcome(text: text.uppercased(), usage: usage)
        }
        dependencies.playCue = { _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { [weak self] text, _, allowed in
            guard allowed() else { return .cancelled }
            self?.inserted.append(text)
            return .inserted
        }
        var settings = AppSettings()
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.structureDictation = false
        settings.verifyWithFile = verifyWithFile
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    /// Le flux annonce une pause, puis le temps passe sans nouvelle parole.
    func pause(after text: String, waiting seconds: Double = 0.45) async {
        stream.text = text
        stream.onPartial?(text)
        stream.onSettled?(text)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func trace() throws -> DictationTrace {
        try #require(try model.store.recentTraces(limit: 1).first)
    }

    func cleanupCount() -> Int {
        model.usage.filter { $0.api == .deepSeekCleanup }.count
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct EarlyCorrectionTests {
    @Test func correctionPreparedAtThePauseIsPastedWithoutASecondCall() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileText = "Bonjour à tous"
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: "Bonjour à tous")
        // La correction part après 0,25 s de pause ; d'autres tests occupent parfois le fil principal plus longtemps.
        let deadline = Date().addingTimeInterval(2)
        while f.cleanTexts.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(f.cleanTexts == ["Bonjour à tous"])
        await f.model.coordinator.end()

        #expect(f.cleanTexts == ["Bonjour à tous"])
        #expect(f.inserted == ["BONJOUR À TOUS"])
        #expect(f.cleanupCount() == 1)
        let trace = try f.trace()
        #expect(trace.earlyCorrections == 1)
        #expect(trace.earlyCorrectionUsed == true)
        #expect(trace.transcriptChoice == .equivalent)
    }

    @Test func worksWithoutFileVerificationToo() async throws {
        let f = try EarlyFixture(verifyWithFile: false)
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: "Bonjour à tous")
        await f.model.coordinator.end()

        #expect(f.cleanTexts == ["Bonjour à tous"])
        #expect(f.inserted == ["BONJOUR À TOUS"])
        #expect(try f.trace().earlyCorrectionUsed == true)
    }

    @Test func speechThatResumesRightAwayPreparesNothing() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileText = "Bonjour à tous"
        await f.model.coordinator.begin(.toggle)
        f.stream.onSettled?("Bonjour")
        f.stream.onPartial?("Bonjour à tous")
        f.stream.text = "Bonjour à tous"
        try? await Task.sleep(nanoseconds: 450_000_000)
        await f.model.coordinator.end()

        #expect(f.cleanTexts == ["Bonjour à tous"])
        #expect(f.inserted == ["BONJOUR À TOUS"])
        #expect(try f.trace().earlyCorrections == nil)
    }

    @Test func wordsAddedAfterThePauseGetTheirOwnCorrectionAndBothAreBilled() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileText = "Bonjour à tous et merci"
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: "Bonjour à tous")
        f.stream.onPartial?("Bonjour à tous et merci")
        f.stream.text = "Bonjour à tous et merci"
        await f.model.coordinator.end()

        #expect(f.cleanTexts == ["Bonjour à tous", "Bonjour à tous et merci"])
        #expect(f.inserted == ["BONJOUR À TOUS ET MERCI"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.cleanupCount() == 2)
        let trace = try f.trace()
        #expect(trace.earlyCorrections == 1)
        #expect(trace.earlyCorrectionUsed == false)
    }

    @Test func cancelledDictationBillsThePreparedCorrectionAndPastesNothing() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: "Bonjour à tous")
        f.model.coordinator.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.inserted.isEmpty)
        #expect(f.cleanupCount() == 1)
    }

    @Test func noCorrectionIsPreparedWhenCorrectionIsOff() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.model.settings.cleanupEnabled = false
        f.fileText = "Bonjour à tous"
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: "Bonjour à tous")
        #expect(f.cleanTexts.isEmpty)
        await f.model.coordinator.end()
        #expect(f.inserted == ["Bonjour à tous"])
    }
}
