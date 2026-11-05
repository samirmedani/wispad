import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

private final class SendTestAudio: AudioRecording, @unchecked Sendable {
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

private final class SendTestStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    func start() async throws {}
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish { StreamFinish(text: "Message fictif.", endingFinalized: true) }
    func cancel() {}
}

/// Micro, réseau, clés, collage et Entrée simulés : aucune touche réelle n'est envoyée.
@MainActor
private final class SendFixture {
    let directory: URL
    var returns: [pid_t] = []
    var order: [String] = []
    var model: AppModel!

    init(status: InsertionStatus = .inserted, enabled: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-send-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        let audio = SendTestAudio()
        let stream = SendTestStream()
        dependencies.makeCapture = { audio }
        dependencies.makeSession = { _ in stream }
        dependencies.transcribe = { _, _ in "Message fictif." }
        dependencies.clean = { text, _, _, _ in CleanupOutcome(text: text) }
        dependencies.playCue = { _, _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { [weak self] _, _, shouldProceed, _ in
            guard shouldProceed() else { return .cancelled }
            self?.order.append("collage")
            return status
        }
        dependencies.pressReturn = { [weak self] pid in
            self?.returns.append(pid)
            self?.order.append("entrée")
            return true
        }
        var settings = AppSettings()
        settings.cleanupEnabled = false
        settings.verifyWithFile = false
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.sendWithShift = enabled
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    func dictate(send: Bool) async {
        await model.coordinator.begin(.toggle)
        await model.coordinator.endCapture(sendAfterPaste: send)?.value
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct ShiftToSendAppTests {
    @Test func shiftAtTheEndPressesReturnOnceAfterThePaste() async throws {
        let f = try SendFixture()
        defer { f.dispose() }
        await f.dictate(send: true)
        #expect(f.returns == [4_242])
        #expect(f.order == ["collage", "entrée"])
    }

    @Test func aPlainEndNeverPressesReturn() async throws {
        let f = try SendFixture()
        defer { f.dispose() }
        await f.dictate(send: false)
        #expect(f.order == ["collage"])
    }

    @Test func turnedOffInSettingsNeverPressesReturn() async throws {
        let f = try SendFixture(enabled: false)
        defer { f.dispose() }
        await f.dictate(send: true)
        #expect(f.returns.isEmpty)
    }

    @Test(arguments: [InsertionStatus.noTarget, .failed, .refusedSecure])
    func textThatDidNotArriveIsNeverSent(status: InsertionStatus) async throws {
        let f = try SendFixture(status: status)
        defer { f.dispose() }
        await f.dictate(send: true)
        #expect(f.returns.isEmpty)
    }

    @Test func onlyADeliveredTextWithNothingTypedSinceIsSent() {
        func sends(status: InsertionStatus = .inserted, enabled: Bool = true, typed: Int = 0,
                   selection: Bool = false, trial: Bool = false) -> Bool {
            DictationCoordinator.sendsAfterPaste(requested: true, enabled: enabled, status: status, keystrokesAtEnd: 10,
                                                 keystrokesNow: 10 + typed, selectionCommand: selection, trial: trial)
        }
        #expect(sends())
        #expect(sends(status: .pasteSent))
        #expect(!sends(typed: 1))
        #expect(!sends(enabled: false))
        #expect(!sends(selection: true))
        #expect(!sends(trial: true))
        #expect(!DictationCoordinator.sendsAfterPaste(requested: false, enabled: true, status: .inserted, keystrokesAtEnd: 0,
                                                      keystrokesNow: 0, selectionCommand: false, trial: false))
    }
}
