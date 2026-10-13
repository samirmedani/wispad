import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

// Essai du premier lancement : la touche est rendue à la dictée après l'étape « Touche », une dictée faite dans la
// fenêtre de Wispad s'écrit dans le champ d'essai, et aucune attente n'est infinie. Ni micro, ni API, ni collage réels.

private final class TrialAudio: AudioRecording, @unchecked Sendable {
    var onPCM: (@Sendable (Data) -> Void)?
    let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    private(set) var url: URL?

    func start(directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 128).write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) { (url, 2) }
}

private final class TrialStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    let text: String
    let ready = AsyncResult<Void>()

    init(text: String) { self.text = text }

    func start() async throws { ready.resolve(.success(())) }
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish { StreamFinish(text: text, endingFinalized: true) }
    func cancel() {}
}

/// Phrase « dictée » par les fixtures.
private let spoken = "Salut, je teste Wispad."

@MainActor
private final class TrialFixture {
    let directory: URL
    /// App au premier plan au début de la dictée : Wispad lui-même par défaut, comme dans l'essai.
    var targetPID: pid_t = ProcessInfo.processInfo.processIdentifier
    var pasted: [String] = []
    var streams: [TrialStream] = []
    var clock = Date(timeIntervalSince1970: 2_000_000)
    var model: AppModel!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-trial-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { "fixture-key-" + $0 }
        dependencies.saveKey = { _, _ in true }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        dependencies.isOnline = { true }
        dependencies.captureContext = { [unowned self] in
            let context = DictationContext()
            context.pid = self.targetPID
            context.appName = "Fixture"
            return (context, Task { nil })
        }
        dependencies.makeCapture = { TrialAudio() }
        dependencies.makeSession = { [unowned self] _ in
            let stream = TrialStream(text: spoken)
            self.streams.append(stream)
            return stream
        }
        dependencies.transcribe = { _, _ in spoken }
        dependencies.clean = { text, _, _, _ in CleanupOutcome(text: text) }
        dependencies.playCue = { _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { [unowned self] text, _, allowed, _ in
            guard allowed() else { return .cancelled }
            self.pasted.append(text)
            return .inserted
        }
        var settings = AppSettings()
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    /// Parcours affiché à cette étape, avec un macOS simulé : tout est autorisé, l'écoute du clavier est active.
    func guide(at step: OnboardingStep) -> OnboardingController {
        var system = OnboardingSystem()
        system.permissions = {
            OnboardingSystem.PermissionSnapshot(microphoneGranted: true, accessibilityTrusted: true, inputMonitoringTrusted: true)
        }
        system.keyboardListening = { _ in true }
        system.reinstallKeyboard = { _ in }
        system.fnUsage = { 0 }
        system.now = { [unowned self] in self.clock }
        let controller = OnboardingController(model: model, step: step, system: system)
        model.onboarding = controller
        controller.resume()
        return controller
    }

    func dictate() async throws {
        await model.coordinator.begin(.toggle)
        if let stream = streams.last { try await stream.ready.value() }
        await model.coordinator.end()
    }

    func dispose() {
        model.coordinator.cancel()
        model.onboarding?.suspend()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func gesture(_ effects: [GestureEffect], pressedAt: Int? = 1) -> HotkeyOutput {
    var output = HotkeyOutput()
    output.pressedAt = pressedAt
    output.effects = effects
    return output
}

@MainActor
@Suite(.serialized)
struct OnboardingTrialTests {
    /// Régression : dans l'essai, Wispad est l'app au premier plan. Le texte doit arriver dans le champ d'essai
    /// lui-même, pas partir dans un collage système vers sa propre fenêtre.
    @Test func dictationInWispadsOwnWindowLandsInTheTrialField() async throws {
        let f = try TrialFixture()
        defer { f.dispose() }
        let guide = f.guide(at: .trial)
        #expect(guide.currentStatus == .todo)
        try await f.dictate()
        #expect(f.pasted.isEmpty)
        #expect(guide.trialText == spoken)
        guide.noteTrialProgress()
        #expect(guide.currentStatus == .succeeded)
        #expect(guide.trialSummary?.words == 4)
        // Une deuxième dictée s'ajoute après la première, séparée par une espace.
        guide.retryTrial()
        try await f.dictate()
        #expect(guide.trialText == spoken + " " + spoken)
    }

    @Test func dictationInAnotherAppStillUsesTheNormalPaste() async throws {
        let f = try TrialFixture()
        defer { f.dispose() }
        f.targetPID = 4_242
        let guide = f.guide(at: .trial)
        try await f.dictate()
        #expect(f.pasted == [spoken])
        #expect(guide.trialText.isEmpty)
    }

    /// Régression : un test de la touche resté actif hors de l'étape « Touche » avalait chaque geste, et l'essai
    /// restait sur « Prêt » sans qu'aucune dictée ne démarre.
    @Test func theShortcutIsGivenBackToDictationForTheTrial() throws {
        let f = try TrialFixture()
        defer { f.dispose() }
        f.model.shortcutProbe = ShortcutProbe()
        let guide = f.guide(at: .trial)
        #expect(f.model.shortcutProbe == nil)
        // Même un test réinstallé par erreur ne garde pas la touche hors de son étape.
        f.model.shortcutProbe = ShortcutProbe()
        #expect(!f.model.shortcutReceived(gesture([.startPushToTalk])))
        #expect(f.model.shortcutProbe == nil)
        #expect(guide.step == .trial)
    }

    @Test func theShortcutStepStillKeepsItsPresses() throws {
        let f = try TrialFixture()
        defer { f.dispose() }
        let guide = f.guide(at: .shortcut)
        #expect(f.model.shortcutReceived(gesture([.startToggle])))
        #expect(guide.probe.presses == 1)
        #expect(guide.probe.sawHandsFree)
        guide.advance()
        #expect(guide.step == .trial)
        #expect(f.model.shortcutProbe == nil)
        #expect(!f.model.shortcutReceived(gesture([.startPushToTalk])))
    }

    @Test func aGestureWithoutListeningEndsInAPreciseFailure() throws {
        let f = try TrialFixture()
        defer { f.dispose() }
        let guide = f.guide(at: .trial)
        // Le geste est reçu, mais aucune dictée ne démarre (rien n'est mis en file ici).
        #expect(!f.model.shortcutReceived(gesture([.startPushToTalk])))
        #expect(guide.currentStatus == .inProgress)
        f.clock.addTimeInterval(TrialCheck.startGrace + 0.5)
        guide.tick()
        #expect(guide.currentStatus == .failed(.trial(.notStarted)))
        guide.retryTrial()
        #expect(guide.currentStatus == .todo)
        // Un appui simple (sans geste de dictée) ne lance aucune attente.
        #expect(!f.model.shortcutReceived(gesture([])))
        f.clock.addTimeInterval(TrialCheck.startGrace + 0.5)
        guide.tick()
        #expect(guide.currentStatus == .todo)
    }
}
