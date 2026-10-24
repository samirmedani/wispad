import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

// Autorisations retirées dans Réglages Système pendant que Wispad tourne, au repos ou en pleine dictée, puis
// rendues : rien ne plante ni ne reste bloqué, la bulle dit pourquoi, et aucune relecture ne s'emballe. Tout est
// simulé : aucune vraie écoute du clavier, aucun micro, aucun collage, aucune autorisation demandée.

// MARK: - Écoute du clavier

/// macOS simulé pour l'écoute du clavier : autorisations, création des écoutes (de vrais ports Mach, sans
/// événement), coupures et réarmements.
private final class FakeTapSystem: @unchecked Sendable {
    @Guarded var permissions = KeyboardPermissions(listen: true, accessibility: true)
    /// Lectures complètes, surveillance des entrées comprise : une question au démon des autorisations de macOS.
    @Guarded var fullReads = 0
    /// macOS accepte de créer une écoute.
    @Guarded var creatable = true
    @Guarded var creations = 0
    @Guarded var enables = 0
    @Guarded var ports: [CFMachPort] = []
    @Guarded private var disabled: Set<ObjectIdentifier> = []

    var system: KeyboardTapSystem {
        var system = KeyboardTapSystem()
        system.permissions = { [self] in
            fullReads += 1
            return permissions
        }
        system.accessibilityTrusted = { [self] in permissions.accessibility }
        system.create = { [self] _ in
            creations += 1
            guard creatable else { return nil }
            var context = CFMachPortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            guard let port = CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, &context, nil) else { return nil }
            ports.append(port)
            return port
        }
        system.isEnabled = { [self] port in !disabled.contains(ObjectIdentifier(port)) }
        system.enable = { [self] port in
            enables += 1
            disabled.remove(ObjectIdentifier(port))
        }
        system.keyIsDown = { _ in false }
        return system
    }

    /// macOS coupe l'écoute (lenteur, saisie sécurisée, autorisation retirée).
    func cut(_ port: CFMachPort) {
        disabled.insert(ObjectIdentifier(port))
    }
}

/// Ce que l'écoute transmet à l'app.
private final class TapOutputs: @unchecked Sendable {
    @Guarded var delivered: [HotkeyOutput] = []
    @Guarded var lost: [KeyboardPermissions] = []
    @Guarded var unavailable = 0
}

private func makeTap(_ fake: FakeTapSystem, _ outputs: TapOutputs) -> KeyboardTap {
    KeyboardTap(
        deliver: { outputs.delivered.append($0) },
        unavailable: { outputs.unavailable += 1 },
        lost: { outputs.lost.append($0) },
        system: fake.system
    )
}

/// fn enfoncée ou relâchée, telle que l'écoute la reçoit.
private func fnEvent(down: Bool) throws -> CGEvent {
    let event = try #require(CGEvent(source: nil))
    event.type = .flagsChanged
    event.flags = down ? .maskSecondaryFn : []
    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(ChordMatcher.functionKeyCode))
    return event
}

/// L'écoute est menée sans son fil : installée, vérifiée (surveillance de 3 s) et appelée tout de suite.
struct KeyboardTapPermissionTests {
    private let all = KeyboardPermissions(listen: true, accessibility: true)
    private let noListen = KeyboardPermissions(listen: false, accessibility: true)
    private let noAccessibility = KeyboardPermissions(listen: true, accessibility: false)

    @Test func aTapCutAfterItsPermissionIsWithdrawnIsNeverRearmedAndComesBackWithIt() throws {
        let fake = FakeTapSystem()
        let outputs = TapOutputs()
        let tap = makeTap(fake, outputs)
        tap.reinstall()
        let first = try #require(fake.ports.first)
        #expect(tap.diagnosticState.listening == .enabled)
        let armed = fake.enables
        // Surveillance des entrées retirée : macOS coupe l'écoute et le signale.
        fake.permissions = noListen
        fake.cut(first)
        _ = tap.handle(.tapDisabledByUserInput, try #require(CGEvent(source: nil)))
        // Jamais réarmée (elle retiendrait les frappes de tout le Mac) : retirée, l'app est prévenue une fois.
        #expect(fake.enables == armed)
        #expect(!CFMachPortIsValid(first))
        #expect(tap.diagnosticState.listening == .unavailable)
        #expect(outputs.lost == [noListen])
        // Une heure de surveillance toutes les 3 s, autorisation toujours retirée : rien n'est réarmé ni retenté.
        for _ in 0..<1_200 { tap.checkTap() }
        #expect(fake.enables == armed)
        #expect(fake.creations == 1)
        #expect(outputs.lost.count == 1)
        #expect(outputs.unavailable == 0)
        // Autorisation rendue : l'écoute est réinstallée à la vérification suivante, sans relancer Wispad.
        fake.permissions = all
        tap.checkTap()
        #expect(fake.creations == 2)
        #expect(tap.diagnosticState.listening == .enabled)
        #expect(CFMachPortIsValid(fake.ports[1]))
        tap.checkTap()
        #expect(fake.creations == 2)
    }

    @Test func aTapStillActiveAfterInputMonitoringIsWithdrawnIsRemovedOnceMacOSCutsOrInvalidatesIt() throws {
        let fake = FakeTapSystem()
        let outputs = TapOutputs()
        let tap = makeTap(fake, outputs)
        tap.reinstall()
        let first = try #require(fake.ports.first)
        // Surveillance des entrées retirée, écoute laissée active par macOS (l'accessibilité lui suffit) : pendant
        // qu'elle retient les frappes, la surveillance ne pose pas la question lente à macOS, l'écoute continue.
        fake.permissions = noListen
        tap.checkTap()
        #expect(CFMachPortIsValid(first))
        #expect(tap.diagnosticState.listening == .enabled)
        #expect(outputs.lost.isEmpty)
        // macOS la coupe : elle est retirée à la vérification suivante, sans être réarmée.
        fake.cut(first)
        tap.checkTap()
        #expect(!CFMachPortIsValid(first))
        #expect(tap.diagnosticState.listening == .unavailable)
        #expect(outputs.lost == [noListen])
        #expect(fake.creations == 1)
        // Rendue, puis retirée encore pendant que macOS invalide l'écoute : elle n'est pas recréée sans elle.
        fake.permissions = all
        tap.checkTap()
        let second = try #require(fake.ports.last)
        #expect(fake.creations == 2)
        fake.permissions = noListen
        CFMachPortInvalidate(second)
        tap.checkTap()
        #expect(fake.creations == 2)
        #expect(tap.diagnosticState.listening == .unavailable)
        #expect(outputs.lost == [noListen, noListen])
    }

    @Test func anActiveTapIsCheckedWithoutAskingMacOSTheSlowQuestion() throws {
        let fake = FakeTapSystem()
        let outputs = TapOutputs()
        let tap = makeTap(fake, outputs)
        tap.reinstall()
        let port = try #require(fake.ports.first)
        let reads = fake.fullReads
        // Une heure de surveillance toutes les 3 s, écoute active : chaque frappe du Mac attend ce fil, aucune
        // question au démon des autorisations (une dizaine de millisecondes chacune).
        for _ in 0..<1_200 { tap.checkTap() }
        #expect(fake.fullReads == reads)
        #expect(fake.creations == 1)
        #expect(tap.diagnosticState.listening == .enabled)
        // Accessibilité retirée : vue sans lecture lente, l'écoute est refaite après une seule lecture complète.
        fake.permissions = noAccessibility
        tap.checkTap()
        #expect(!CFMachPortIsValid(port))
        #expect(fake.creations == 2)
        #expect(fake.fullReads == reads + 1)
        // Coupée par macOS, elle ne retient plus rien : la lecture complète reprend, puis elle est réarmée.
        fake.permissions = all
        let second = try #require(fake.ports.last)
        fake.cut(second)
        tap.checkTap()
        #expect(fake.fullReads == reads + 2)
        #expect(tap.diagnosticState.listening == .enabled)
        #expect(CFMachPortIsValid(second))
        #expect(outputs.lost.isEmpty)
    }

    @Test func cutsByMacOSAreStillRearmedWhileThePermissionsStay() throws {
        let fake = FakeTapSystem()
        let outputs = TapOutputs()
        let tap = makeTap(fake, outputs)
        tap.reinstall()
        let port = try #require(fake.ports.first)
        // Lenteur ou saisie sécurisée : réarmée aussitôt, comme avant.
        fake.cut(port)
        _ = tap.handle(.tapDisabledByTimeout, try #require(CGEvent(source: nil)))
        #expect(fake.enables == 2)
        #expect(tap.diagnosticState.listening == .enabled)
        #expect(tap.diagnosticState.recoveries == 1)
        // Coupée sans le dire (veille) : la surveillance la réarme.
        fake.cut(port)
        tap.checkTap()
        #expect(fake.enables == 3)
        #expect(tap.diagnosticState.recoveries == 2)
        #expect(CFMachPortIsValid(port))
        #expect(fake.creations == 1)
        #expect(outputs.lost.isEmpty)
    }

    @Test func accessibilityWithdrawnRebuildsTheTapWhenMacOSStillAllowsOne() throws {
        let fake = FakeTapSystem()
        let outputs = TapOutputs()
        let tap = makeTap(fake, outputs)
        tap.reinstall()
        let first = try #require(fake.ports.first)
        // macOS accepte encore une écoute neuve : elle remplace l'ancienne, sans rien arrêter.
        fake.permissions = noAccessibility
        tap.checkTap()
        #expect(!CFMachPortIsValid(first))
        #expect(fake.creations == 2)
        #expect(tap.diagnosticState.listening == .enabled)
        #expect(outputs.lost.isEmpty)
        // Installée sans accessibilité : la rendre puis la retirer encore ne change rien.
        fake.permissions = all
        tap.checkTap()
        fake.permissions = noAccessibility
        tap.checkTap()
        #expect(fake.creations == 2)
        #expect(CFMachPortIsValid(try #require(fake.ports.last)))
    }

    @Test func accessibilityWithdrawnRemovesTheTapWhenMacOSRefusesANewOne() throws {
        let fake = FakeTapSystem()
        let outputs = TapOutputs()
        let tap = makeTap(fake, outputs)
        tap.reinstall()
        let first = try #require(fake.ports.first)
        let armed = fake.enables
        fake.creatable = false
        fake.permissions = noAccessibility
        tap.checkTap()
        // Retirée, l'app est prévenue une fois ; jamais réarmée.
        #expect(!CFMachPortIsValid(first))
        #expect(tap.diagnosticState.listening == .unavailable)
        #expect(outputs.lost == [noAccessibility])
        // Surveillance des entrées toujours accordée : une seule tentative par vérification, comme au lancement.
        let tries = fake.creations
        for _ in 0..<10 { tap.checkTap() }
        #expect(fake.creations == tries + 10)
        #expect(fake.enables == armed)
        #expect(outputs.lost.count == 1)
        #expect(outputs.unavailable == 0)
        // Accessibilité rendue : l'écoute revient à la vérification suivante.
        fake.creatable = true
        fake.permissions = all
        tap.checkTap()
        #expect(tap.diagnosticState.listening == .enabled)
        #expect(CFMachPortIsValid(try #require(fake.ports.last)))
    }

    @Test func aGestureHeldWhenTheListeningIsWithdrawnNeverDeadensTheNextPress() throws {
        let fake = FakeTapSystem()
        let outputs = TapOutputs()
        let tap = makeTap(fake, outputs)
        tap.reinstall()
        let first = try #require(fake.ports.first)
        // fn enfoncée : l'appui est vu.
        _ = tap.handle(.flagsChanged, try fnEvent(down: true))
        #expect(outputs.delivered.filter { $0.pressedAt != nil }.count == 1)
        // Autorisation retirée (macOS coupe l'écoute), puis fn relâchée sans que rien ne soit vu, puis autorisation
        // rendue.
        fake.permissions = noListen
        fake.cut(first)
        tap.checkTap()
        #expect(outputs.lost == [noListen])
        fake.permissions = all
        tap.checkTap()
        // L'appui suivant compte : le geste en cours a été oublié avec l'écoute retirée.
        _ = tap.handle(.flagsChanged, try fnEvent(down: true))
        #expect(outputs.delivered.filter { $0.pressedAt != nil }.count == 2)
    }

    @Test func anExplicitReinstallNeverRearmsATapWhosePermissionWasWithdrawn() throws {
        let fake = FakeTapSystem()
        let outputs = TapOutputs()
        let tap = makeTap(fake, outputs)
        tap.reinstall()
        let first = try #require(fake.ports.first)
        let armed = fake.enables
        // « Autoriser » dans Réglages, avant la vérification suivante : l'écoute n'est pas réarmée sans autorisation.
        fake.permissions = noListen
        tap.reinstall()
        #expect(fake.enables == armed)
        #expect(!CFMachPortIsValid(first))
        #expect(outputs.lost == [noListen])
        #expect(outputs.unavailable == 1)
    }
}

// MARK: - Dictée en cours

/// Lectures d'autorisation bloquantes : sur leur file GCD, jamais sur un fil de Swift concurrency, que les minuteries
/// de la dictée partagent (le 14 octobre, une lecture réelle par dictée de test y figeait une dictée sur la CI).
struct PermissionReadsTests {
    @Test func blockingPermissionReadsRunOnTheirOwnQueue() async {
        let label = await PermissionReads.offMain { String(cString: __dispatch_queue_get_label(nil)) }
        #expect(label == "wispad.autorisations")
    }
}

private final class FakeAudio: AudioRecording, @unchecked Sendable {
    @Guarded var onPCM: (@Sendable (Data) -> Void)?
    @Guarded var bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    @Guarded var isRunning = false
    @Guarded var url: URL?
    /// Démarrage retenu jusqu'à sa résolution (micro lent à s'ouvrir).
    @Guarded var startGate: AsyncResult<Void>?
    @Guarded var onStarting: (@Sendable () -> Void)?

    func start(directory: URL) async throws -> URL {
        onStarting?()
        if let startGate { try await startGate.value() }
        isRunning = true
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 128).write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) {
        isRunning = false
        return (url, 2)
    }
}

private final class FakeStream: SpeechStreaming, @unchecked Sendable {
    @Guarded var onPartial: (@Sendable (String) -> Void)?
    func start() async throws {}
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish { StreamFinish(text: "Phrase de test.", endingFinalized: true) }
    func cancel() {}
}

/// Accès au micro tel que macOS le dirait, et nombre de relectures.
private final class MicrophoneAccess: @unchecked Sendable {
    @Guarded var granted = true
    @Guarded var reads = 0
}

@MainActor
private func waitFor(_ condition: () -> Bool, seconds: Double = 15) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

@MainActor
private final class DictationFixture {
    let directory: URL
    let audio = FakeAudio()
    let access = MicrophoneAccess()
    var inserted: [String] = []
    var copied: [String] = []
    var cues: [DictationCue] = []
    /// Ce que dit l'insertion ; `accessibilityRefused` : macOS refuse l'accessibilité au moment du collage.
    var status: InsertionStatus = .inserted
    var accessibilityRefused = false
    var model: AppModel!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-permissions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var deps = AppDependencies()
        deps.loadKey = { "fixture-" + $0 }
        deps.saveKey = { _, _ in true }
        deps.refreshKeys = { true }
        deps.requestMicrophone = { true }
        deps.microphoneAuthorized = { [access] in
            access.reads += 1
            return access.granted
        }
        deps.captureContext = { let context = DictationContext(); context.pid = 4242; return (context, Task { nil }) }
        deps.frontmostApp = { let context = DictationContext(); context.pid = 5151; return context }
        deps.makeCapture = { [audio] in audio }
        deps.makeSession = { _ in FakeStream() }
        deps.transcribe = { _, _ in "Phrase de test." }
        deps.clean = { text, _, _, _ in CleanupOutcome(text: text) }
        deps.copyText = { [weak self] in self?.copied.append($0) }
        deps.playCue = { [weak self] cue, _ in self?.cues.append(cue) }
        deps.muteOutput = { _, _ in }
        deps.restoreOutput = {}
        deps.watchCorrections = { _, _, _, _ in }
        deps.systemShortcuts = { [] }
        deps.insert = { [weak self] text, context, shouldProceed, _ in
            guard let self, shouldProceed() else { return .cancelled }
            if self.accessibilityRefused {
                context.accessibilityRefused = true
                return .failed
            }
            self.inserted.append(text)
            return self.status
        }
        model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: deps)
        model.overlay.displaysPanel = false
        model.coordinator.microphoneAccessInterval = 0.02
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct DictationPermissionTests {
    @Test func inputMonitoringWithdrawnDuringHandsFreeEndsTheDictationAndSaysWhy() async throws {
        let f = try DictationFixture()
        defer { f.dispose() }
        let coordinator = f.model.coordinator
        await coordinator.begin(.toggle)
        #expect(coordinator.phase == .listening(.toggle))
        // Ni le raccourci ni Échap n'atteindraient plus cette dictée : elle s'arrête, la bulle dit pourquoi.
        let withdrawn = KeyboardPermissions(listen: false, accessibility: true)
        coordinator.keyboardLost(withdrawn)
        let message = DictationCoordinator.keyboardLostMessage(withdrawn)
        #expect(message == "Surveillance des entrées retirée : dictée arrêtée")
        #expect(coordinator.phase == .failure(message))
        #expect(!coordinator.failureOffersHistory)
        #expect(!f.audio.isRunning)
        #expect(!coordinator.isMetering)
        // Ce qui a été dit avant est transcrit et collé, comme si on avait terminé.
        let pasted = await waitFor { f.inserted == ["Phrase de test."] }
        #expect(pasted)
        #expect(coordinator.phase == .failure(message))
        // Le raccourci (ou le menu) relance aussitôt une dictée ; un signal tardif au repos ne fait rien.
        coordinator.dismissFailure()
        coordinator.keyboardLost(withdrawn)
        #expect(coordinator.phase == .idle)
        await coordinator.begin(.toggle)
        #expect(coordinator.phase == .listening(.toggle))
    }

    @Test func accessibilityWithdrawnDuringAHoldEndsTheDictationAndSaysWhy() async throws {
        let f = try DictationFixture()
        defer { f.dispose() }
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        let withdrawn = KeyboardPermissions(listen: true, accessibility: false)
        coordinator.keyboardLost(withdrawn)
        #expect(coordinator.phase == .failure("Accessibilité retirée : dictée arrêtée"))
        #expect(!f.audio.isRunning)
        let pasted = await waitFor { f.inserted.count == 1 }
        #expect(pasted)
    }

    @Test func keyboardWithdrawnWhileTheMicrophoneOpensAbandonsTheDictation() async throws {
        let f = try DictationFixture()
        defer { f.dispose() }
        let gate = AsyncResult<Void>()
        let entered = AsyncResult<Void>()
        f.audio.startGate = gate
        f.audio.onStarting = { entered.resolve(.success(())) }
        let coordinator = f.model.coordinator
        let begin = Task { await coordinator.begin(.toggle) }
        try await entered.value()
        #expect(coordinator.phase == .starting)
        let withdrawn = KeyboardPermissions(listen: false, accessibility: true)
        coordinator.keyboardLost(withdrawn)
        #expect(coordinator.phase == .failure(DictationCoordinator.keyboardLostMessage(withdrawn)))
        // Le micro qui finit par s'ouvrir se referme : rien n'est enregistré, transcrit ni collé.
        gate.resolve(.success(()))
        await begin.value
        #expect(!f.audio.isRunning)
        #expect(f.inserted.isEmpty)
        let audio = try #require(f.audio.url)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func microphoneAccessWithdrawnDuringTheDictationEndsItAndSaysWhy() async throws {
        let f = try DictationFixture()
        defer { f.dispose() }
        let coordinator = f.model.coordinator
        await coordinator.begin(.toggle)
        #expect(coordinator.phase == .listening(.toggle))
        // Surveillance armée : la première lecture (hors du fil principal) a vu l'accès accordé, la suivante est faite.
        let armed = await waitFor { f.access.reads >= 2 }
        #expect(armed)
        // macOS ne coupe pas le moteur : il ne livre plus que du silence. La relecture de l'accès arrête la dictée.
        f.access.granted = false
        let stopped = await waitFor { coordinator.phase == .failure(DictationCoordinator.microphoneRevokedMessage) }
        #expect(stopped)
        #expect(DictationCoordinator.microphoneRevokedMessage == "Accès au micro retiré : dictée arrêtée")
        #expect(!coordinator.failureOffersHistory)
        #expect(!f.audio.isRunning)
        #expect(!coordinator.isMetering)
        #expect(f.cues.contains(.stop))
        // Ce qui a été dit avant le retrait est transcrit et collé.
        let pasted = await waitFor { f.inserted == ["Phrase de test."] }
        #expect(pasted)
        // Plus aucune relecture une fois la dictée arrêtée.
        let reads = f.access.reads
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(f.access.reads == reads)
    }

    @Test func microphoneAccessIsReadOnlyWhileListeningAndNeverAsked() async throws {
        let f = try DictationFixture()
        defer { f.dispose() }
        let coordinator = f.model.coordinator
        #expect(f.access.reads == 0)
        await coordinator.begin(.toggle)
        let watched = await waitFor { f.access.reads >= 3 }
        #expect(watched)
        #expect(coordinator.phase == .listening(.toggle))
        await coordinator.end()
        #expect(f.inserted == ["Phrase de test."])
        // Une lecture partie juste avant l'arrêt (hors du fil principal) peut encore se terminer : ensuite, plus rien.
        try await Task.sleep(nanoseconds: 50_000_000)
        let reads = f.access.reads
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(f.access.reads == reads)
        // Accès jamais accordé au départ (lecture refusée par macOS) : une seule lecture, hors du fil principal, puis
        // rien n'est surveillé.
        f.access.granted = false
        let before = f.access.reads
        await coordinator.begin(.toggle)
        let checked = await waitFor { f.access.reads == before + 1 }
        #expect(checked)
        let unwatched = f.access.reads
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(f.access.reads == unwatched)
        #expect(coordinator.phase == .listening(.toggle))
    }

    @Test func accessibilityRefusedAtThePasteSaysWhyAndKeepsTheText() async throws {
        let f = try DictationFixture()
        defer { f.dispose() }
        f.accessibilityRefused = true
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        // Rien n'est collé ; le texte est copié et la bulle dit quelle autorisation manque.
        let message = "Accessibilité non autorisée : le texte est prêt"
        #expect(coordinator.phase == .failure(message))
        #expect(coordinator.failureText == "Phrase de test.")
        #expect(f.copied == ["Phrase de test."])
        #expect(f.inserted.isEmpty)
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.failed.rawValue)
        // « Coller » dans la bulle (même collage que « Coller la dernière dictée ») : même raison.
        coordinator.pasteReadyText()
        let again = await waitFor { coordinator.phase == .failure(message) && f.copied.count == 2 }
        #expect(again)
        // Accessibilité rendue : le texte se colle.
        f.accessibilityRefused = false
        await coordinator.pasteLastDictation()
        #expect(f.inserted == ["Phrase de test."])
    }
}
