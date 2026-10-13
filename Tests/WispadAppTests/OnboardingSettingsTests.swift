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
    var relaunches = 0
    var reinstalls = 0
    /// Lectures des autorisations : chaque passage du sondage en fait une.
    var permissionReads = 0
    var fnUsage: Int?
    let meter = FakeMeter()

    var system: OnboardingSystem {
        var system = OnboardingSystem()
        system.permissions = { [unowned self] in
            self.permissionReads += 1
            return self.snapshot
        }
        system.requestMicrophone = { [unowned self] in
            self.microphoneRequests += 1
            return self.snapshot.microphoneGranted
        }
        system.requestAccessibility = { [unowned self] in self.accessibilityRequests += 1 }
        system.requestInputMonitoring = { [unowned self] in self.inputRequests += 1 }
        system.openSettings = { [unowned self] kind in self.opened.append(kind) }
        system.openKeyboardSettings = {}
        system.relaunch = { [unowned self] in self.relaunches += 1 }
        system.keyboardListening = { [unowned self] _ in self.listening }
        system.reinstallKeyboard = { [unowned self] _ in self.reinstalls += 1 }
        system.inputDevices = { return [AudioInputDevice(uid: "fixture-builtin", name: "Fixture")] }
        system.systemInput = { AudioInputDevice(uid: "fixture-builtin", name: "Fixture") }
        system.makeMeter = { [meter] in meter }
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

@MainActor
private final class GuideFixture {
    let directory: URL
    let fake = FakeSystem()
    var model: AppModel!
    var online = true
    var keys: [String: String] = [:]
    var status = 200

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
        dependencies.validateKey = { [unowned self] _ in self.status }
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

    func dispose() {
        model.onboarding?.suspend()
        try? FileManager.default.removeItem(at: directory)
    }
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
