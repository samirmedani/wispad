import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

struct OnboardingSettingsTests {
    @Test func freshInstallStartsWithTheGuideAndPrivateDefaults() {
        let fresh = AppSettings()
        #expect(!fresh.onboardingCompleted)
        #expect(!fresh.useWindowContext)
        #expect(fresh.onboardingResume.isEmpty)
        #expect(fresh.microphoneUID.isEmpty)
    }

    @Test func existingInstallSkipsTheGuideAndKeepsItsContext() throws {
        let saved = Data(#"{"provider":"xai","cleanupEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: saved)
        #expect(settings.onboardingCompleted)
        #expect(settings.useWindowContext)
        #expect(settings.onboardingResume.isEmpty)
        #expect(settings.microphoneUID.isEmpty)
    }

    @Test func unreadableGuideValuesFallBackAlone() throws {
        let saved = Data(#"{"provider":"openai","onboardingCompleted":false,"onboardingResume":3,"microphoneUID":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: saved)
        #expect(settings.provider == .openAI)
        #expect(!settings.onboardingCompleted)
        #expect(settings.onboardingResume.isEmpty)
        #expect(settings.microphoneUID.isEmpty)
    }

    @Test func clearedResumeStepIsReallyCleared() throws {
        let suite = "wispad-onboarding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var settings = AppSettings()
        settings.onboardingResume = OnboardingStep.permissions.rawValue
        settings.microphoneUID = "fixture-usb-mic"
        settings.save(to: defaults)
        #expect(AppSettings.load(from: defaults).onboardingResume == "permissions")
        settings.onboardingResume = ""
        settings.onboardingCompleted = true
        settings.save(to: defaults)
        let loaded = AppSettings.load(from: defaults)
        #expect(loaded.onboardingResume.isEmpty)
        #expect(loaded.microphoneUID == "fixture-usb-mic")
    }
}

// MARK: - Parcours guidé

/// Horloge et réponses de macOS simulées : aucune vraie autorisation, aucun micro, aucun réglage système.
@MainActor
private final class FakeSystem {
    var snapshot = OnboardingSystem.PermissionSnapshot()
    var listening = false
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var accessibilityRequests = 0
    var inputRequests = 0
    var microphoneRequests = 0
    var opened: [PermissionKind] = []
    var keyboardSettingsOpened = 0
    var relaunches = 0
    var reinstalls = 0
    /// Lectures des autorisations : chaque passage du sondage en fait une.
    var permissionReads = 0
    var fnUsage: Int?
    /// Micros branchés et micro du système ; vides : un Mac sans micro.
    var devices = [AudioInputDevice(uid: "fixture-builtin", name: "Fixture")]
    var systemDevice: AudioInputDevice? = AudioInputDevice(uid: "fixture-builtin", name: "Fixture")
    let meter = FakeMeter()
    /// Vumètre à ouvrir à la place du faux habituel (ouverture qui ne rend jamais la main).
    var meterInUse: (any MicrophoneMetering)?

    var system: OnboardingSystem {
        var system = OnboardingSystem()
        system.permissions = { [unowned self] in
            self.permissionReads += 1
            return self.snapshot
        }
        // Le sondage lit aussi ce macOS simulé sur place : ces tests en attendent l'effet dès le retour de `tick()`.
        // Sa lecture hors du fil principal est prouvée par `OnboardingPollTests`.
        system.pollPermissions = nil
        system.requestMicrophone = { [unowned self] in
            self.microphoneRequests += 1
            return self.snapshot.microphoneGranted
        }
        system.requestAccessibility = { [unowned self] in self.accessibilityRequests += 1 }
        system.requestInputMonitoring = { [unowned self] in self.inputRequests += 1 }
        system.openSettings = { [unowned self] kind in self.opened.append(kind) }
        system.openKeyboardSettings = { [unowned self] in self.keyboardSettingsOpened += 1 }
        system.relaunch = { [unowned self] in self.relaunches += 1 }
        system.keyboardListening = { [unowned self] _ in self.listening }
        system.reinstallKeyboard = { [unowned self] _ in self.reinstalls += 1 }
        system.inputDevices = { [unowned self] in self.devices }
        system.systemInput = { [unowned self] in self.systemDevice }
        system.makeMeter = { [unowned self] in self.meterInUse ?? self.meter }
        system.fnUsage = { [unowned self] in self.fnUsage }
        system.now = { [unowned self] in self.clock }
        return system
    }

    func grantAll() {
        snapshot = OnboardingSystem.PermissionSnapshot(microphoneGranted: true, accessibilityTrusted: true, inputMonitoringTrusted: true)
        listening = true
    }
}

private final class FakeMeter: MicrophoneMetering, @unchecked Sendable {
    @Guarded var onLevel: (@MainActor @Sendable (Double, Double) -> Void)?
    @Guarded var starts = 0
    @Guarded var stops = 0

    func start(deviceUID: String?, onLevel: @escaping @MainActor @Sendable (Double, Double) -> Void) async throws {
        starts += 1
        self.onLevel = onLevel
    }

    func stop() { stops += 1 }
}

/// Ouverture du micro qui ne rend jamais la main (périphérique bloqué), jusqu'à `release`.
private final class StuckMeter: MicrophoneMetering, @unchecked Sendable {
    private let gate = AsyncResult<Void>()
    @Guarded var starts = 0
    @Guarded var stops = 0

    func start(deviceUID: String?, onLevel: @escaping @MainActor @Sendable (Double, Double) -> Void) async throws {
        starts += 1
        try await gate.value()
    }

    func stop() { stops += 1 }

    func release() { gate.resolve(.success(())) }
}

@MainActor
private final class GuideFixture {
    let directory: URL
    let fake = FakeSystem()
    var model: AppModel!
    /// Réseau : sans lui, la vérification d'une clé échoue comme une vraie requête (et l'essai le sait).
    var online = true
    var keys: [String: String] = [:]
    var status = 200
    /// Vérifications de clé demandées au fournisseur.
    var keyRequests = 0
    /// Vérification lente : la réponse du fournisseur attend ce signal.
    var keyGate: AsyncResult<Void>?

    init(settings: AppSettings = AppSettings()) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-onboarding-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { [unowned self] account in self.keys[account] }
        dependencies.saveKey = { [unowned self] account, key in
            self.keys[account] = key
            return true
        }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { false }
        dependencies.validateKey = { [unowned self] _ in
            self.keyRequests += 1
            if let gate = self.keyGate { try await gate.value() }
            if !self.online { throw URLError(.notConnectedToInternet) }
            return self.status
        }
        dependencies.isOnline = { [unowned self] in self.online }
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    func controller(at step: OnboardingStep) -> OnboardingController {
        let controller = OnboardingController(model: model, step: step, system: fake.system)
        model.onboarding = controller
        controller.resume()
        return controller
    }

    /// Parcours dont le sondage lit `source` hors du fil principal, comme sur un vrai Mac ; les relectures qui suivent
    /// une action lisent toujours `fake`, sur place.
    func controller(at step: OnboardingStep, polling source: PollSource) -> OnboardingController {
        var system = fake.system
        system.pollPermissions = source.read
        let controller = OnboardingController(model: model, step: step, system: system)
        model.onboarding = controller
        controller.resume()
        return controller
    }

    /// Wispad quitté puis relancé : les réglages passent par leur vrai enregistrement et leur vraie relecture ; clés et
    /// autorisations restent celles de ce Mac.
    func relaunched() throws -> GuideFixture {
        let suite = "wispad-onboarding-relaunch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.settings.save(to: defaults)
        let next = try GuideFixture(settings: AppSettings.load(from: defaults))
        next.keys = keys
        next.fake.snapshot = fake.snapshot
        next.fake.listening = fake.listening
        return next
    }

    func dispose() {
        model.onboarding?.suspend()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Attend qu'une condition devienne vraie, sans bloquer le fil principal : rend la main dès qu'elle l'est, les 15 s ne
/// servent qu'aux machines de CI chargées. Jamais pour prouver une absence.
@MainActor
private func settles(_ condition: () -> Bool, seconds: Double = 15) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

@MainActor
@Suite(.serialized)
struct OnboardingControllerTests {
    @Test func firstLaunchResumesWhereARelaunchLeftIt() throws {
        var settings = AppSettings()
        settings.onboardingResume = OnboardingStep.permissions.rawValue
        let resumed = try GuideFixture(settings: settings)
        defer { resumed.dispose() }
        #expect(resumed.model.onboarding?.step == .permissions)

        var existing = AppSettings()
        existing.onboardingCompleted = true
        let configured = try GuideFixture(settings: existing)
        defer { configured.dispose() }
        #expect(configured.model.onboarding == nil)
    }

    @Test func replayCanBeLeftAndFinishingRestoresTheWindow() throws {
        var settings = AppSettings()
        settings.onboardingCompleted = true
        let f = try GuideFixture(settings: settings)
        defer { f.dispose() }
        f.model.replayOnboarding()
        #expect(f.model.onboarding?.replay == true)
        #expect(f.model.onboarding?.step == .welcome)
        f.model.completeOnboarding(openSettings: true)
        #expect(f.model.onboarding == nil)
        #expect(f.model.settings.onboardingCompleted)
        #expect(f.model.selectedSection == .settings)
    }

    @Test func permissionsAreAskedThenFollowedLive() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        let guide = f.controller(at: .permissions)
        #expect(guide.currentStatus == .todo)
        #expect(!guide.canContinue)
        guide.request(.accessibility)
        #expect(f.fake.accessibilityRequests == 1)
        #expect(guide.permissions[.accessibility] == .waiting)
        #expect(guide.currentStatus == .inProgress)
        // Deuxième clic : le panneau de Réglages Système, pas une nouvelle demande.
        guide.request(.accessibility)
        #expect(f.fake.accessibilityRequests == 1)
        #expect(f.fake.opened == [.accessibility])
        f.fake.grantAll()
        guide.tick()
        #expect(guide.currentStatus == .succeeded)
        #expect(guide.canContinue)
        guide.advance()
        #expect(guide.step == .microphone)
        #expect(f.model.settings.onboardingResume == "microphone")
    }

    @Test func deniedMicrophoneOpensItsSettingsPane() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.snapshot.microphoneDenied = true
        let guide = f.controller(at: .permissions)
        #expect(guide.currentStatus == .failed(.permission(.microphone, .denied)))
        guide.request(.microphone)
        #expect(f.fake.microphoneRequests == 0)
        #expect(f.fake.opened == [.microphone])
    }

    @Test func inputMonitoringWithoutListenerAsksForARelaunch() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.snapshot = OnboardingSystem.PermissionSnapshot(microphoneGranted: true, accessibilityTrusted: true, inputMonitoringTrusted: true)
        f.fake.listening = false
        let guide = f.controller(at: .permissions)
        #expect(f.fake.reinstalls == 1)
        #expect(guide.permissions[.inputMonitoring] == .waiting)
        f.fake.clock.addTimeInterval(4)
        guide.tick()
        #expect(guide.currentStatus == .failed(.permission(.inputMonitoring, .needsRelaunch)))
        guide.relaunch()
        #expect(f.fake.relaunches == 1)
        #expect(f.model.settings.onboardingResume == "permissions")
    }

    @Test func microphoneSucceedsOnVoiceAndIsReleasedAfterwards() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .microphone)
        // Le vumètre démarre dans une tâche : attendu jusqu'à 15 s (machine de CI chargée), rendu dès qu'il est prêt.
        let deadline = Date().addingTimeInterval(15)
        while f.fake.meter.onLevel == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let deliver = try #require(f.fake.meter.onLevel)
        for _ in 0..<20 { deliver(-62, 0.05) }
        #expect(guide.currentStatus == .inProgress)
        for _ in 0..<16 { deliver(-26, 0.05) }
        #expect(guide.currentStatus == .succeeded)
        guide.advance()
        #expect(guide.step == .provider)
        #expect(f.fake.meter.stops >= 1)
        // Le niveau d'un test arrêté n'est plus pris en compte.
        let detected = guide.detector
        deliver(-70, 1)
        #expect(guide.detector == detected)
    }

    @Test func providerNeedsAKeyTheProviderAccepts() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .provider)
        #expect(guide.currentStatus == .todo)
        f.status = 401
        f.model.keyDrafts["xai"] = "fixture-secret"
        await f.model.verifyAndStoreKey("xai")
        #expect(guide.currentStatus == .failed(.key(.rejected(401))))
        #expect(f.keys["xai"] == nil)
        f.status = 200
        await f.model.verifyAndStoreKey("xai")
        #expect(guide.currentStatus == .succeeded)
        #expect(f.keys["xai"] == "fixture-secret")
    }

    @Test func storedKeysAreCheckedAgainWithoutBeingRewritten() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.keys["xai"] = "fixture-stored"
        f.status = 403
        await f.model.recheckStoredKey("xai")
        #expect(f.model.keyChecks["xai"] == .rejected(403))
        #expect(f.keys["xai"] == "fixture-stored")
        f.status = 200
        await f.model.recheckStoredKey("xai")
        #expect(f.model.keyChecks["xai"] == .valid)
    }

    @Test func shortcutStepCountsPressesWithoutDictating() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        f.fake.fnUsage = 2
        let guide = f.controller(at: .shortcut)
        #expect(f.model.shortcutProbe != nil)
        #expect(guide.fnSettingMatters)
        f.fake.clock.addTimeInterval(ShortcutCheck.patience + 1)
        guide.tick()
        #expect(guide.currentStatus == .failed(.noKeyEvent))
        f.model.shortcutProbe?.notePress()
        #expect(guide.currentStatus == .succeeded)
        #expect(f.model.coordinator.phase == .idle)
        guide.advance()
        #expect(f.model.shortcutProbe == nil)
        #expect(guide.probe.presses == 1)
    }

    @Test func trialSucceedsWhenTheDictationLandsInTheField() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .trial)
        #expect(guide.currentStatus == .todo)
        guide.trialText = "Salut, je teste Wispad."
        guide.noteTrialProgress()
        // Du texte tapé à la main ne suffit pas.
        #expect(guide.currentStatus == .todo)
        f.model.noteCompletion(DictationTrace(origin: .hold, outcome: .inserted))
        guide.noteTrialProgress()
        #expect(guide.currentStatus == .succeeded)
        #expect(guide.trialSummary?.words == 4)
    }

    @Test func trialFailuresKeepTheirCause() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .trial)
        f.online = false
        f.model.noteCompletion(DictationTrace(origin: .toggle, outcome: .transcriptionFailed))
        guide.tick()
        #expect(guide.currentStatus == .failed(.trial(.network)))
        guide.retryTrial()
        #expect(guide.currentStatus == .todo)
        f.online = true
        f.model.noteCompletion(DictationTrace(origin: .hold, outcome: .pasteSent))
        guide.tick()
        #expect(guide.currentStatus == .inProgress)
        f.fake.clock.addTimeInterval(TrialCheck.pasteGrace + 0.5)
        guide.tick()
        #expect(guide.currentStatus == .failed(.trial(.paste)))
        // Une retranscription depuis l'historique n'est pas un essai.
        guide.retryTrial()
        f.model.noteCompletion(DictationTrace(origin: .retry, outcome: .transcriptionFailed))
        guide.tick()
        #expect(guide.currentStatus == .todo)
    }

    /// Fenêtre fermée pendant la configuration : le sondage (autorisations relues deux fois par seconde) s'arrête au
    /// lieu de continuer derrière la fenêtre fermée, que SwiftUI garde en mémoire avec sa vue ; il repart à la
    /// réouverture.
    @Test func closingTheWindowStopsThePolling() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        let guide = f.controller(at: .permissions)
        let before = f.fake.permissionReads
        let polling = Task { await guide.poll(every: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.fake.permissionReads > before)
        // Fenêtre fermée.
        guide.suspend()
        let stopped = await DictationCoordinator.value(of: polling, within: 2) != nil
        #expect(stopped)
        let reads = f.fake.permissionReads
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.fake.permissionReads == reads)
        // Réouverture : la clé de la tâche change, la vue relance le sondage.
        let activation = guide.activation
        guide.resume()
        #expect(!guide.isSuspended)
        #expect(guide.activation == activation + 1)
        polling.cancel()
    }

    // MARK: Autorisations retirées puis rendues pendant la configuration

    @Test func microphoneTestStartsByItselfWhenItsAccessComesBack() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        // Accès au micro retiré avant d'arriver à l'étape : aucun test ne peut s'ouvrir.
        f.fake.snapshot.microphoneGranted = false
        f.fake.snapshot.microphoneDenied = true
        let guide = f.controller(at: .microphone)
        #expect(guide.currentStatus == .failed(.permission(.microphone, .denied)))
        #expect(f.fake.meter.starts == 0)
        // Rendu dans Réglages Système : le test repart seul, sans attendre une voix qu'il n'écoute pas.
        f.fake.snapshot.microphoneGranted = true
        f.fake.snapshot.microphoneDenied = false
        guide.tick()
        let deadline = Date().addingTimeInterval(15)
        while f.fake.meter.onLevel == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let deliver = try #require(f.fake.meter.onLevel)
        for _ in 0..<20 { deliver(-62, 0.05) }
        for _ in 0..<16 { deliver(-26, 0.05) }
        #expect(guide.currentStatus == .succeeded)
        #expect(f.fake.meter.starts == 1)
        #expect(f.fake.microphoneRequests == 0)
    }

    @Test func microphoneTestReleasesTheMicrophoneWhenItsAccessIsWithdrawn() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .microphone)
        let deadline = Date().addingTimeInterval(15)
        while f.fake.meter.onLevel == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let deliver = try #require(f.fake.meter.onLevel)
        let stops = f.fake.meter.stops
        // Accès retiré pendant le test : macOS ne livrerait plus que du silence, le micro est rendu.
        f.fake.snapshot.microphoneGranted = false
        f.fake.snapshot.microphoneDenied = true
        guide.tick()
        #expect(f.fake.meter.stops == stops + 1)
        #expect(guide.currentStatus == .failed(.permission(.microphone, .denied)))
        // Les niveaux d'un test arrêté ne comptent plus ; d'autres relectures ne relancent rien.
        for _ in 0..<40 { deliver(-26, 0.05) }
        #expect(!guide.detector.detected)
        for _ in 0..<10 { guide.tick() }
        #expect(f.fake.meter.starts == 1)
        #expect(f.fake.meter.stops == stops + 1)
        #expect(f.fake.microphoneRequests == 0)
    }

    /// Autorisations retirées puis rendues plusieurs fois, l'écran relu à chaque passage du sondage : l'état suit,
    /// l'affichage des Réglages aussi, l'écoute du clavier est réinstallée une fois par retour, jamais à chaque
    /// relecture, et rien n'est demandé à macOS sans un clic.
    @Test func permissionsWithdrawnAndGivenBackAreFollowedWithoutAskingAgain() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .permissions)
        #expect(guide.currentStatus == .succeeded)
        let reinstalls = f.fake.reinstalls
        for _ in 0..<3 {
            f.fake.snapshot = OnboardingSystem.PermissionSnapshot()
            f.fake.listening = false
            for _ in 0..<10 { guide.tick() }
            #expect(guide.currentStatus == .todo)
            #expect(!f.model.accessibilityTrusted && !f.model.inputMonitoringTrusted)
            f.fake.grantAll()
            for _ in 0..<10 { guide.tick() }
            #expect(guide.currentStatus == .succeeded)
            #expect(f.model.accessibilityTrusted && f.model.inputMonitoringTrusted)
        }
        #expect(f.fake.reinstalls == reinstalls + 3)
        #expect(f.fake.microphoneRequests == 0)
        #expect(f.fake.accessibilityRequests == 0)
        #expect(f.fake.inputRequests == 0)
        #expect(f.fake.opened.isEmpty)
        #expect(f.fake.relaunches == 0)
    }

    @Test func laterIsOnlyOfferedWhereItMakesSense() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        let guide = f.controller(at: .provider)
        guide.later()
        #expect(guide.step == .provider)
        guide.go(to: .shortcut)
        guide.later()
        #expect(guide.step == .trial)
        #expect(guide.skipped == [.shortcut])
    }
}

// MARK: - Premier lancement sans impasse

/// Chaque étape prise comme sur un Mac neuf, avec un macOS simulé : autorisation refusée puis accordée, avec ou sans
/// relance ; Mac sans micro ou micro muet ; clé fausse, expirée, sans crédit, hors connexion ou lente ; touche que
/// Wispad ne reçoit pas ; fenêtre fermée puis rouverte ; Wispad quitté puis relancé. Aucune ne reste sans issue :
/// un problème expliqué, une action qui fait avancer (Réessayer, Réglages Système, Relancer, Plus tard), et la
/// configuration reprend là où elle en était.
@MainActor
@Suite(.serialized)
struct OnboardingDeadEndTests {
    // MARK: Autorisations

    @Test func permissionsRefusedThenGrantedInSystemSettingsCarryOn() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        // Micro refusé à la demande de macOS ; les deux autres pas encore accordées.
        f.fake.snapshot.microphoneDenied = true
        let guide = f.controller(at: .permissions)
        #expect(guide.currentStatus == .failed(.permission(.microphone, .denied)))
        #expect(!guide.canContinue)
        // Chaque ligne mène à son panneau de Réglages Système : refusée, ou déjà demandée une fois.
        guide.request(.microphone)
        #expect(f.fake.microphoneRequests == 0)
        guide.request(.accessibility)
        guide.request(.accessibility)
        guide.request(.inputMonitoring)
        guide.request(.inputMonitoring)
        #expect(f.fake.opened == [.microphone, .accessibility, .inputMonitoring])
        // Tout est accordé dans Réglages Système, sans relancer Wispad : l'écran le voit au passage suivant du sondage.
        f.fake.grantAll()
        guide.tick()
        #expect(guide.currentStatus == .succeeded)
        guide.advance()
        #expect(guide.step == .microphone)
    }

    @Test func permissionNeedingARelaunchResumesAtTheSameStep() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.snapshot = OnboardingSystem.PermissionSnapshot(microphoneGranted: true, accessibilityTrusted: true, inputMonitoringTrusted: true)
        f.fake.listening = false
        let guide = f.controller(at: .welcome)
        guide.advance()
        #expect(guide.step == .permissions)
        f.fake.clock.addTimeInterval(4)
        guide.tick()
        #expect(guide.currentStatus == .failed(.permission(.inputMonitoring, .needsRelaunch)))
        guide.relaunch()
        #expect(f.fake.relaunches == 1)
        // Relancé : macOS applique l'autorisation, l'écoute du clavier s'installe au lancement.
        f.fake.listening = true
        let next = try f.relaunched()
        defer { next.dispose() }
        let step = try #require(next.model.onboarding?.step)
        #expect(step == .permissions)
        let resumed = next.controller(at: step)
        #expect(resumed.currentStatus == .succeeded)
    }

    // MARK: Micro

    @Test func macWithoutMicrophoneCanRetryOrMoveOn() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        f.fake.devices = []
        f.fake.systemDevice = nil
        let guide = f.controller(at: .microphone)
        #expect(guide.currentStatus == .failed(.noInputDevice))
        #expect(f.fake.meter.starts == 0)
        // Micro branché ensuite : « Réessayer » relit les micros et ouvre le test.
        f.fake.devices = [AudioInputDevice(uid: "fixture-usb", name: "Fixture USB")]
        guide.startMicrophoneTest()
        #expect(guide.currentStatus == .todo)
        // Ou « Plus tard » : l'étape suivante s'ouvre et le micro rendu.
        #expect(guide.step.allowsLater)
        guide.later()
        #expect(guide.step == .provider)
        #expect(guide.skipped == [.microphone])
    }

    /// Régression : un micro ouvert qui ne livre aucun son (aucun paquet) laissait « Dis quelques mots… » sans fin,
    /// sans message ni Réessayer : le délai de 12 s ne comptait que l'audio reçu.
    @Test func microphoneGivingNoSoundEndsInAnExplainedFailure() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .microphone)
        let opened = await settles { guide.meterOpened }
        #expect(opened)
        f.fake.clock.addTimeInterval(MicrophoneCheck.silenceTimeout - 1)
        guide.tick()
        #expect(guide.currentStatus == .todo)
        f.fake.clock.addTimeInterval(1)
        guide.tick()
        #expect(guide.currentStatus == .failed(.silence))
        // « Réessayer » rouvre le micro et laisse de nouveau le temps de parler ; une voix arrive, l'étape réussit.
        guide.startMicrophoneTest()
        #expect(guide.currentStatus == .todo)
        let reopened = await settles { guide.meterOpened }
        #expect(reopened)
        let deliver = try #require(f.fake.meter.onLevel)
        for _ in 0..<20 { deliver(-62, 0.05) }
        for _ in 0..<16 { deliver(-26, 0.05) }
        #expect(guide.currentStatus == .succeeded)
    }

    /// Régression : une ouverture du micro qui ne rend jamais la main laissait aussi « Dis quelques mots… » sans fin.
    @Test func microphoneThatNeverOpensEndsInAnExplainedFailure() async throws {
        let f = try GuideFixture()
        let stuck = StuckMeter()
        defer {
            stuck.release()
            f.dispose()
        }
        f.fake.grantAll()
        f.fake.meterInUse = stuck
        let guide = f.controller(at: .microphone)
        let starting = await settles { stuck.starts == 1 }
        #expect(starting)
        f.fake.clock.addTimeInterval(MicrophoneCheck.silenceTimeout)
        guide.tick()
        #expect(guide.currentStatus == .failed(.microphoneUnavailable))
        #expect(!guide.meterOpened)
        // On avance quand même : « Plus tard » rend le micro bloqué sans l'attendre.
        guide.later()
        #expect(guide.step == .provider)
        #expect(stuck.stops == 1)
    }

    // MARK: Fournisseur

    /// Régression : une clé xAI fausse (HTTP 400) était dite « non vérifiée » avec « Réessaie dans un instant », et une
    /// clé reconnue mais refusée (HTTP 403 : compte sans crédit, plafond atteint) « à recopier ». Chaque refus dit quoi
    /// faire, la clé saisie reste dans le champ, rien n'est enregistré, et la clé acceptée passe.
    @Test func wrongExpiredOrUnfundedKeysSayWhatToDo() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .provider)
        f.model.keyDrafts["xai"] = "fixture-key"
        f.status = 400
        await f.model.verifyAndStoreKey("xai")
        #expect(guide.currentStatus == .failed(.key(.rejected(400))))
        f.status = 401
        await f.model.verifyAndStoreKey("xai")
        #expect(guide.currentStatus == .failed(.key(.rejected(401))))
        #expect(OnboardingCopy.key(.rejected(401), provider: .xai, keyStore: .file).detail.contains("Copie à nouveau la clé"))
        f.status = 403
        await f.model.verifyAndStoreKey("xai")
        #expect(guide.currentStatus == .failed(.key(.rejected(403))))
        let unfunded = OnboardingCopy.key(.rejected(403), provider: .xai, keyStore: .file).detail
        #expect(unfunded.contains("crédit épuisé"))
        #expect(!unfunded.contains("Copie à nouveau"))
        #expect(f.keys["xai"] == nil)
        #expect(f.model.keyDrafts["xai"] == "fixture-key")
        // Crédit ajouté : la même clé, vérifiée de nouveau, passe et s'enregistre.
        f.status = 200
        await f.model.verifyAndStoreKey("xai")
        #expect(guide.currentStatus == .succeeded)
        #expect(f.keys["xai"] == "fixture-key")
        guide.advance()
        #expect(guide.step == .shortcut)
    }

    /// Régression : une clé déjà enregistrée (configuration reprise après une relance), vérifiée sans réseau, restait
    /// en échec : champ vide, Vérifier inactif, aucun Réessayer, et revenir sur l'étape ne la revérifiait pas.
    @Test func storedKeyCheckedOfflineCanBeCheckedAgain() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        f.keys["xai"] = "fixture-stored"
        f.online = false
        let guide = f.controller(at: .provider)
        let checkedOffline = await settles { f.model.keyChecks["xai"] == .offline }
        #expect(checkedOffline)
        #expect(guide.currentStatus == .failed(.key(.offline)))
        #expect(guide.retriesStoredVoiceKey)
        // Réseau revenu : « Réessayer » revérifie la clé enregistrée, sans la réécrire.
        f.online = true
        guide.retryVoiceKey()
        let retried = await settles { guide.currentStatus == .succeeded }
        #expect(retried)
        #expect(f.keys["xai"] == "fixture-stored")
        // En revenant sur l'étape, une vérification restée sans réponse est refaite…
        f.model.keyChecks["xai"] = .offline
        let requests = f.keyRequests
        guide.go(to: .microphone)
        guide.go(to: .provider)
        let rechecked = await settles { f.model.keyChecks["xai"] == .valid }
        #expect(rechecked)
        #expect(f.keyRequests == requests + 1)
        // … un résultat net, lui, est gardé (laisse passer une vérification qui serait partie).
        guide.go(to: .microphone)
        guide.go(to: .provider)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.keyRequests == requests + 1)
        // Une clé en cours de saisie se vérifie avec son propre bouton : pas de Réessayer en double.
        f.model.keyDrafts["xai"] = "fixture-new"
        #expect(!guide.retriesStoredVoiceKey)
    }

    /// Régression : une clé modifiée pendant sa vérification, alors qu'une autre était déjà enregistrée, laissait
    /// « Vérification… » sans fin et Vérifier inactif, sans aucune vérification en cours.
    @Test func keyEditedWhileCheckingNeverLeavesAnEndlessCheck() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        f.keys["xai"] = "fixture-stored"
        let guide = f.controller(at: .provider)
        let checked = await settles { guide.currentStatus == .succeeded }
        #expect(checked)
        // « Remplacer la clé » : une nouvelle clé est collée, sa vérification tarde…
        let gate = AsyncResult<Void>()
        f.keyGate = gate
        f.model.keyDrafts["xai"] = "fixture-new"
        let requests = f.keyRequests
        let checking = Task { await f.model.verifyAndStoreKey("xai") }
        let sent = await settles { f.keyRequests == requests + 1 }
        #expect(sent)
        #expect(guide.currentStatus == .inProgress)
        // … et la clé est retouchée avant la réponse : ce résultat ne la concerne plus, rien n'est enregistré.
        f.model.keyDrafts["xai"] = "fixture-new-edited"
        f.keyGate = nil
        gate.resolve(.success(()))
        await checking.value
        #expect(f.keys["xai"] == "fixture-stored")
        // Le sondage revérifie la clé enregistrée au lieu de laisser « Vérification… » sans fin.
        guide.tick()
        let recovered = await settles { guide.currentStatus == .succeeded }
        #expect(recovered)
        #expect(f.model.keyDrafts["xai"] == "fixture-new-edited")
    }

    /// Clé lente à vérifier : « Vérification… » le temps de la réponse (la requête est bornée à 15 s) ; sans réponse,
    /// l'échec se dit et la même clé, restée dans le champ, se revérifie.
    @Test func slowKeyCheckEndsWithAWayToTryAgain() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .provider)
        let gate = AsyncResult<Void>()
        f.keyGate = gate
        f.model.keyDrafts["xai"] = "fixture-key"
        let checking = Task { await f.model.verifyAndStoreKey("xai") }
        let sent = await settles { f.keyRequests == 1 }
        #expect(sent)
        #expect(guide.currentStatus == .inProgress)
        gate.resolve(.failure(URLError(.timedOut)))
        await checking.value
        #expect(guide.currentStatus == .failed(.key(.offline)))
        #expect(f.model.keyDrafts["xai"] == "fixture-key")
        f.keyGate = nil
        await f.model.verifyAndStoreKey("xai")
        #expect(guide.currentStatus == .succeeded)
    }

    // MARK: Touche

    /// Touche fn réglée dans macOS sur « Changer de source d'entrée » (1) ou « Afficher les emoji » (2) : le conseil et
    /// le bouton vers Réglages Clavier sont là ; l'appui reçu suffit, sans démarrer de dictée.
    @Test(arguments: [1, 2])
    func fnKeyBoundToAnotherActionIsExplained(fnUsage: Int) throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        f.fake.fnUsage = fnUsage
        let guide = f.controller(at: .shortcut)
        #expect(guide.fnSettingMatters)
        f.fake.clock.addTimeInterval(ShortcutCheck.patience)
        guide.tick()
        #expect(guide.currentStatus == .failed(.noKeyEvent))
        let detail = OnboardingCopy.shortcutDetail(.noKeyEvent, detail: "", shortcutIsFn: guide.shortcutIsFn,
                                                   fnSettingMatters: guide.fnSettingMatters)
        #expect(detail.contains("« Ne rien faire »"))
        guide.openKeyboardSettings()
        #expect(f.fake.keyboardSettingsOpened == 1)
        f.model.shortcutProbe?.notePress()
        #expect(guide.currentStatus == .succeeded)
        #expect(f.model.coordinator.phase == .idle)
    }

    /// Régression : « Wispad ne reçoit pas la touche » conseillait de vérifier la surveillance des entrées et de relancer
    /// Wispad sans aucun bouton pour le faire, et ne disait rien d'un clavier sans touche fn.
    @Test func keyNeverReceivedOffersItsRemedies() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        f.fake.fnUsage = 0
        let guide = f.controller(at: .shortcut)
        f.fake.clock.addTimeInterval(ShortcutCheck.patience)
        guide.tick()
        #expect(guide.currentStatus == .failed(.noKeyEvent))
        let text = OnboardingCopy.issue(.noKeyEvent, provider: .xai, keyStore: .file)
        let detail = OnboardingCopy.shortcutDetail(.noKeyEvent, detail: text.detail, shortcutIsFn: true, fnSettingMatters: false)
        #expect(detail.hasPrefix(text.detail))
        #expect(detail.contains("Clavier sans touche fn"))
        #expect(!detail.contains("Ne rien faire"))
        // Les boutons de l'écran : le panneau de la surveillance des entrées, puis une relance qui reprend ici.
        guide.openSettings(.inputMonitoring)
        #expect(f.fake.opened == [.inputMonitoring])
        guide.relaunch()
        #expect(f.fake.relaunches == 1)
        let next = try f.relaunched()
        defer { next.dispose() }
        let step = try #require(next.model.onboarding?.step)
        #expect(step == .shortcut)
        let resumed = next.controller(at: step)
        #expect(next.model.shortcutProbe != nil)
        next.model.shortcutProbe?.notePress()
        #expect(resumed.currentStatus == .succeeded)
        // Ou « Plus tard » : l'essai s'ouvre, et la touche dicte de nouveau.
        resumed.later()
        #expect(resumed.step == .trial)
        #expect(next.model.shortcutProbe == nil)
    }

    /// Raccourci personnalisé que macOS ou une autre app garde pour lui (configuration rejouée depuis Réglages) : l'écran
    /// le dit au lieu d'accuser seulement la surveillance des entrées, et la configuration se poursuit ou se quitte.
    @Test func customShortcutTakenElsewhereIsExplained() throws {
        var settings = AppSettings()
        settings.onboardingCompleted = true
        settings.keyCode = 49
        settings.modifierFlags = ModifierMask.control
        let f = try GuideFixture(settings: settings)
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = OnboardingController(model: f.model, step: .shortcut, replay: true, system: f.fake.system)
        f.model.onboarding = guide
        guide.resume()
        #expect(!guide.shortcutIsFn)
        f.fake.clock.addTimeInterval(ShortcutCheck.patience)
        guide.tick()
        #expect(guide.currentStatus == .failed(.noKeyEvent))
        let detail = OnboardingCopy.shortcutDetail(.noKeyEvent, detail: "", shortcutIsFn: guide.shortcutIsFn,
                                                   fnSettingMatters: guide.fnSettingMatters)
        #expect(detail.contains("macOS ou à une autre app"))
        #expect(!detail.contains("touche fn"))
        guide.later()
        #expect(guide.step == .trial)
        // Rejouée, elle se quitte à tout moment, sans rien effacer.
        f.model.completeOnboarding()
        #expect(f.model.onboarding == nil)
        #expect(f.model.settings.keyCode == 49)
    }

    // MARK: Fenêtre fermée, Wispad quitté

    /// Régression : fenêtre fermée puis rouverte après une voix entendue, l'étape Micro repartait de zéro (« Continuer »
    /// de nouveau grisé) ; elle reste réussie et le vumètre repart. La touche gardait déjà ses appuis.
    @Test func reopeningTheWindowKeepsTheMicrophoneAndKeySteps() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .microphone)
        let opened = await settles { guide.meterOpened }
        #expect(opened)
        let deliver = try #require(f.fake.meter.onLevel)
        for _ in 0..<20 { deliver(-62, 0.05) }
        for _ in 0..<16 { deliver(-26, 0.05) }
        #expect(guide.currentStatus == .succeeded)
        let stops = f.fake.meter.stops
        guide.suspend()
        #expect(f.fake.meter.stops == stops + 1)
        guide.resume()
        #expect(guide.currentStatus == .succeeded)
        #expect(guide.canContinue)
        let reopened = await settles { guide.meterOpened }
        #expect(reopened)
        // Un autre micro choisi se teste de nouveau.
        guide.selectMicrophone("fixture-builtin")
        #expect(guide.currentStatus == .todo)
        // La touche : rendue à la dictée pendant la fermeture, ses appuis reviennent à la réouverture.
        guide.go(to: .shortcut)
        f.model.shortcutProbe?.notePress()
        guide.suspend()
        #expect(f.model.shortcutProbe == nil)
        guide.resume()
        #expect(f.model.shortcutProbe != nil)
        #expect(guide.currentStatus == .succeeded)
    }

    /// Fenêtre rouverte après un retrait de l'accès au micro : la voix entendue avant ne compte plus, l'écran dit quoi
    /// régler, comme si l'étape recommençait.
    @Test func reopeningAfterMicrophoneAccessWasWithdrawnSaysSo() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .microphone)
        let opened = await settles { guide.meterOpened }
        #expect(opened)
        let deliver = try #require(f.fake.meter.onLevel)
        for _ in 0..<20 { deliver(-62, 0.05) }
        for _ in 0..<16 { deliver(-26, 0.05) }
        #expect(guide.currentStatus == .succeeded)
        guide.suspend()
        f.fake.snapshot.microphoneGranted = false
        f.fake.snapshot.microphoneDenied = true
        guide.resume()
        #expect(guide.currentStatus == .failed(.permission(.microphone, .denied)))
        #expect(!guide.canContinue)
    }

    /// Wispad quitté au milieu puis relancé : la configuration reprend à l'étape quittée, avec le micro, le fournisseur,
    /// la clé et les réglages de correction choisis ; revenir sur l'étape Fournisseur revérifie la clé sans la réécrire.
    @Test func quittingMidwayResumesWithEveryChoiceKept() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        f.fake.devices.append(AudioInputDevice(uid: "fixture-usb", name: "Fixture USB"))
        let guide = f.controller(at: .welcome)
        guide.advance()
        guide.advance()
        #expect(guide.step == .microphone)
        guide.selectMicrophone("fixture-usb")
        guide.later()
        #expect(guide.step == .provider)
        f.model.selectProvider(.openAI)
        f.model.keyDrafts["openai"] = "fixture-openai"
        await f.model.verifyAndStoreKey("openai")
        f.model.settings.useWindowContext = true
        f.model.settings.learnCorrections = false
        f.model.saveSettings()
        guide.advance()
        #expect(guide.step == .shortcut)
        let next = try f.relaunched()
        defer { next.dispose() }
        let step = try #require(next.model.onboarding?.step)
        #expect(step == .shortcut)
        #expect(next.model.settings.microphoneUID == "fixture-usb")
        #expect(next.model.settings.provider == .openAI)
        #expect(next.model.settings.useWindowContext)
        #expect(!next.model.settings.learnCorrections)
        #expect(next.keys["openai"] == "fixture-openai")
        let resumed = next.controller(at: step)
        resumed.back()
        #expect(resumed.step == .provider)
        let rechecked = await settles { resumed.currentStatus == .succeeded }
        #expect(rechecked)
        #expect(next.keys["openai"] == "fixture-openai")
        resumed.advance()
        #expect(resumed.step == .shortcut)
    }

    /// Régression : arrivé à « Tout est prêt », Wispad quitté (ou le Mac redémarré) sans cliquer « Terminer », toute la
    /// configuration revenait depuis Bienvenue au lancement suivant.
    @Test func reachingTheEndIsDoneEvenWithoutClickingFinish() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .trial)
        guide.later()
        #expect(guide.step == .finish)
        let next = try f.relaunched()
        defer { next.dispose() }
        #expect(next.model.onboarding == nil)
        #expect(next.model.settings.onboardingCompleted)
        #expect(next.model.settings.onboardingResume.isEmpty)
        // Dans cette session, l'écran de fin reste jusqu'à « Terminer ».
        #expect(f.model.onboarding === guide)
        guide.finish()
        #expect(f.model.onboarding == nil)
    }

    /// Deuxième lancement après « Terminer » : le parcours ne revient pas, ni au lancement d'après.
    @Test func finishedGuideNeverComesBack() throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        f.fake.grantAll()
        let guide = f.controller(at: .finish)
        guide.finish()
        #expect(f.model.onboarding == nil)
        let second = try f.relaunched()
        defer { second.dispose() }
        #expect(second.model.onboarding == nil)
        let third = try second.relaunched()
        defer { third.dispose() }
        #expect(third.model.onboarding == nil)
        #expect(third.model.settings.onboardingCompleted)
    }
}

// MARK: - Sondage hors du fil principal

/// macOS simulé pour le sondage, lu comme le vrai sur la file des autorisations : chaque lecture est comptée avec
/// la file et le fil où elle se fait. Une réponse peut être retenue (`hold`) : la lecture est faite et sa valeur prise,
/// puis sa réponse attend `release` sans retenir aucun fil, ni la file des autorisations que d'autres tests partagent.
private final class PollSource: @unchecked Sendable {
    @Guarded var snapshot = OnboardingSystem.PermissionSnapshot()
    @Guarded var reads = 0
    @Guarded var queues: [String] = []
    @Guarded var readsOnMainThread = 0
    @Guarded private var gate: AsyncResult<Void>?

    func hold() {
        gate = AsyncResult<Void>()
    }

    func release() {
        let held = gate
        gate = nil
        held?.resolve(.success(()))
    }

    var read: @Sendable () async -> OnboardingSystem.PermissionSnapshot {
        { [self] in
            let held = gate
            let snapshot = await PermissionReads.offMain { [self] in
                reads += 1
                queues.append(String(cString: __dispatch_queue_get_label(nil)))
                if Thread.isMainThread { readsOnMainThread += 1 }
                return self.snapshot
            }
            if let held { try? await held.value() }
            return snapshot
        }
    }
}

/// Le sondage du premier lancement (deux fois par seconde pendant tout l'affichage) lit les autorisations sur la file
/// des autorisations, jamais sur le fil principal : mesuré le 14 octobre, le micro et la surveillance des entrées y
/// prenaient une vingtaine de millisecondes à chaque passage, assez pour faire sauter des images à la bulle de
/// l'accueil et au vumètre. Une lecture à la fois, même lente ; une réponse plus ancienne qu'une lecture déjà appliquée
/// (relecture après un clic) ne l'efface pas ; ses effets (écoute du clavier, état affiché, micro du test) gardent leur
/// ordre.
@MainActor
@Suite(.serialized)
struct OnboardingPollTests {
    @Test func pollingReadsThePermissionsOffTheMainThread() async throws {
        // Sur un vrai Mac, le sondage a sa lecture hors du fil principal.
        let mac = OnboardingSystem()
        #expect(mac.pollPermissions != nil)
        let f = try GuideFixture()
        defer { f.dispose() }
        let source = PollSource()
        let guide = f.controller(at: .permissions, polling: source)
        // L'arrivée sur l'étape relit sur place, une fois ; le sondage, jamais.
        let readsHere = f.fake.permissionReads
        let polling = Task { await guide.poll(every: .milliseconds(5)) }
        let polled = await settles { source.reads >= 5 }
        #expect(polled)
        guide.suspend()
        let stopped = await DictationCoordinator.value(of: polling, within: 2) != nil
        #expect(stopped)
        #expect(f.fake.permissionReads == readsHere)
        #expect(source.readsOnMainThread == 0)
        #expect(source.queues.allSatisfy { $0 == "wispad.autorisations" })
    }

    @Test func aSlowPollReadIsNeverStacked() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        let source = PollSource()
        let guide = f.controller(at: .permissions, polling: source)
        // Démon des autorisations occupé : la réponse de la première lecture tarde.
        source.hold()
        guide.tick()
        let started = await settles { source.reads == 1 }
        #expect(started)
        #expect(guide.pollingPermissions)
        // Vingt passages du sondage, puis le vrai sondage pendant 0,1 s : aucune autre lecture ne part en attendant.
        for _ in 0..<20 { guide.tick() }
        let polling = Task { await guide.poll(every: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        polling.cancel()
        let stopped = await DictationCoordinator.value(of: polling, within: 2) != nil
        #expect(stopped)
        #expect(source.reads == 1)
        // La réponse arrive : le passage suivant relit, une fois.
        source.release()
        let answered = await settles { !guide.pollingPermissions }
        #expect(answered)
        #expect(source.reads == 1)
        guide.tick()
        let next = await settles { source.reads == 2 && !guide.pollingPermissions }
        #expect(next)
        #expect(source.reads == 2)
    }

    /// Une lecture partie avant un clic sur « Autoriser » répond après la relecture faite sur place : plus ancienne,
    /// elle est écartée, et l'écran ne revient pas en arrière.
    @Test func aLatePollAnswerNeverOverwritesTheReadingMadeAfterAClick() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        let source = PollSource()
        // Micro et surveillance des entrées accordés, accessibilité pas encore.
        f.fake.grantAll()
        f.fake.snapshot.accessibilityTrusted = false
        source.snapshot = f.fake.snapshot
        let guide = f.controller(at: .permissions, polling: source)
        #expect(guide.permissions[.accessibility] == .notRequested)
        // Le sondage lit l'état d'avant le clic ; sa réponse tarde.
        source.hold()
        guide.tick()
        let started = await settles { source.reads == 1 }
        #expect(started)
        // « Autoriser » : macOS accorde l'accessibilité, la relecture sur place l'affiche aussitôt.
        f.fake.snapshot.accessibilityTrusted = true
        source.snapshot = f.fake.snapshot
        guide.request(.accessibility)
        #expect(f.fake.accessibilityRequests == 1)
        #expect(guide.currentStatus == .succeeded)
        #expect(f.model.accessibilityTrusted)
        // La réponse partie avant le clic arrive : écartée.
        source.release()
        let answered = await settles { !guide.pollingPermissions }
        #expect(answered)
        #expect(guide.permissions[.accessibility] == .granted)
        #expect(guide.currentStatus == .succeeded)
        #expect(f.model.accessibilityTrusted)
        // Une lecture partie après le clic s'applique, elle : accessibilité retirée ensuite, le sondage le montre.
        source.snapshot.accessibilityTrusted = false
        guide.tick()
        let withdrawn = await settles { guide.permissions[.accessibility] == .waiting }
        #expect(withdrawn)
        #expect(!f.model.accessibilityTrusted)
    }

    /// Fenêtre fermée pendant qu'une lecture du sondage est en route : sa réponse ne change rien (l'état n'est plus relu
    /// jusqu'à la réouverture) et n'ouvre pas le micro ; rouverte, l'étape relit sur place et repart.
    @Test func aPollAnswerArrivingAfterTheWindowClosedChangesNothing() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        let source = PollSource()
        f.fake.grantAll()
        f.fake.snapshot.microphoneGranted = false
        f.fake.snapshot.microphoneDenied = true
        source.snapshot = f.fake.snapshot
        let guide = f.controller(at: .microphone, polling: source)
        #expect(guide.currentStatus == .failed(.permission(.microphone, .denied)))
        // Accès rendu dans Réglages Système : le sondage le lit, sa réponse tarde, la fenêtre se ferme entre-temps.
        source.snapshot.microphoneGranted = true
        source.snapshot.microphoneDenied = false
        source.hold()
        guide.tick()
        let started = await settles { source.reads == 1 }
        #expect(started)
        guide.suspend()
        source.release()
        let answered = await settles { !guide.pollingPermissions }
        #expect(answered)
        #expect(guide.permissions[.microphone] == .denied)
        #expect(f.fake.meter.starts == 0)
        // Rouverte : relue sur place, le test du micro repart.
        f.fake.snapshot = source.snapshot
        guide.resume()
        #expect(guide.permissions[.microphone] == .granted)
        let reopened = await settles { f.fake.meter.starts == 1 }
        #expect(reopened)
    }

    /// Étape Micro : l'accès lu par le sondage, hors du fil principal, est suivi comme avant. Retiré, le micro du test
    /// est rendu ; rendu, le test repart seul, sans rien demander à macOS.
    @Test func theMicrophoneStepFollowsTheAccessReadByThePoll() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        let source = PollSource()
        f.fake.grantAll()
        source.snapshot = f.fake.snapshot
        let guide = f.controller(at: .microphone, polling: source)
        let opened = await settles { guide.meterOpened }
        #expect(opened)
        let stops = f.fake.meter.stops
        source.snapshot.microphoneGranted = false
        source.snapshot.microphoneDenied = true
        guide.tick()
        let released = await settles { f.fake.meter.stops == stops + 1 }
        #expect(released)
        #expect(guide.currentStatus == .failed(.permission(.microphone, .denied)))
        source.snapshot.microphoneGranted = true
        source.snapshot.microphoneDenied = false
        guide.tick()
        let restarted = await settles { f.fake.meter.starts == 2 }
        #expect(restarted)
        #expect(f.fake.microphoneRequests == 0)
    }

    /// Surveillance des entrées accordée dans Réglages Système, lue par le sondage : l'écoute du clavier est réinstallée
    /// une fois, à la première lecture qui la voit, jamais à chaque passage.
    @Test func inputMonitoringReadByThePollReinstallsTheKeyboardOnce() async throws {
        let f = try GuideFixture()
        defer { f.dispose() }
        let source = PollSource()
        let guide = f.controller(at: .permissions, polling: source)
        let reinstalls = f.fake.reinstalls
        source.snapshot.inputMonitoringTrusted = true
        f.fake.listening = true
        for _ in 0..<5 {
            guide.tick()
            let answered = await settles { !guide.pollingPermissions }
            #expect(answered)
        }
        #expect(f.fake.reinstalls == reinstalls + 1)
        #expect(guide.permissions[.inputMonitoring] == .granted)
        #expect(f.model.inputMonitoringTrusted)
        #expect(f.fake.inputRequests == 0)
    }
}

/// Le vumètre du premier lancement : son arrêt n'attend jamais un démarrage du micro resté bloqué. Réessayer, Continuer,
/// Plus tard et la fermeture de la fenêtre l'appellent sur le fil principal, qu'il figerait.
struct MicrophoneMeterTests {
    @Test func stoppingNeverWaitsForAStuckStart() {
        let queue = DispatchQueue(label: "wispad-tests.vumetre")
        let meter = MicrophoneMeter(queue: queue)
        let stuck = DispatchSemaphore(value: 0)
        // Démarrage du micro qui ne rend pas la main : il tient la file du vumètre.
        queue.async { stuck.wait() }
        let stopped = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            meter.stop()
            stopped.signal()
        }
        let returned = stopped.wait(timeout: .now() + 2) == .success
        stuck.signal()
        #expect(returned)
    }
}
