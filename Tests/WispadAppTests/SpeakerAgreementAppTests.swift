import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

private final class AgreementTestAudio: AudioRecording, @unchecked Sendable {
    var onPCM: (@Sendable (Data) -> Void)?
    let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    private var url: URL?

    func start(directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        let silence = Data(repeating: 0, count: 16_000 * 2 * 2)
        var wav = WAVHeader.make(dataBytes: silence.count, sampleRate: 16_000)
        wav.append(silence)
        try wav.write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) { (url, 2) }
}

private final class AgreementTestStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    func start() async throws {}
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish { StreamFinish(text: "Je suis allé au marché.", endingFinalized: true) }
    func cancel() {}
}

/// Dictée complète, correction coupée : le réglage s'applique au texte collé. Micro, réseau et collage simulés.
@MainActor
@Suite(.serialized)
struct SpeakerAgreementAppTests {
    private func dictate(_ agreement: SpeakerAgreement) async throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-agreement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var pasted: [String] = []
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { $0 == ProviderID.xai.rawValue ? "fixture-xai" : nil }
        dependencies.saveKey = { _, _ in true }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        dependencies.captureContext = {
            let context = DictationContext()
            context.pid = 4_242
            return (context, Task { nil })
        }
        let audio = AgreementTestAudio()
        let stream = AgreementTestStream()
        dependencies.makeCapture = { audio }
        dependencies.makeSession = { _ in stream }
        dependencies.transcribe = { _, _ in "Je suis allé au marché." }
        dependencies.clean = { text, _, _, _ in CleanupOutcome(text: text) }
        dependencies.playCue = { _, _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { text, _, shouldProceed, _ in
            guard shouldProceed() else { return .cancelled }
            pasted.append(text)
            return .inserted
        }
        var settings = AppSettings()
        settings.cleanupEnabled = false
        settings.verifyWithFile = false
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.speakerAgreement = agreement
        let model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
        defer { model.coordinator.cancel() }
        await model.coordinator.begin(.toggle)
        await model.coordinator.end()
        return pasted
    }

    @Test func feminineIsPasted() async throws {
        #expect(try await dictate(.feminine) == ["Je suis allée au marché."])
    }

    @Test func asHeardKeepsTheTranscript() async throws {
        #expect(try await dictate(.asHeard) == ["Je suis allé au marché."])
    }
}
