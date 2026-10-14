import AVFoundation
import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

// Autorisations affichées par l'app (Réglages › Autorisations, alerte de la barre latérale) : relues à l'ouverture de la
// fenêtre ou de Réglages et au retour dans Wispad hors du fil principal, une lecture à la fois ; une réponse lente
// n'efface jamais une valeur donnée par une lecture partie après elle. macOS simulé : aucune vraie autorisation lue,
// aucune ouverture à la connexion touchée.

struct PermissionReadOrderTests {
    @Test func aReadStartedEarlierNeverReplacesAValueGivenByALaterOne() {
        var order = PermissionReadOrder()
        let slow = order.start()
        let quick = order.start()
        let quickKept = order.accepts(quick, for: .accessibility)
        let slowKept = order.accepts(slow, for: .accessibility)
        #expect(quickKept)
        #expect(!slowKept)
        // Chaque valeur suit sa propre dernière lecture : la lente reste la plus récente pour le micro, une seule fois.
        let slowMicrophone = order.accepts(slow, for: .microphone)
        let slowMicrophoneAgain = order.accepts(slow, for: .microphone)
        #expect(slowMicrophone)
        #expect(!slowMicrophoneAgain)
        let later = order.start()
        let laterAccessibility = order.accepts(later, for: .accessibility)
        let laterMicrophone = order.accepts(later, for: .microphone)
        #expect(laterAccessibility)
        #expect(laterMicrophone)
    }
}

/// macOS simulé pour les lectures de l'app : chaque lecture est comptée, avec la file et le fil où elle se fait. Une
/// réponse hors du fil principal peut être retenue (`hold`) : la lecture est faite et sa valeur prise, puis sa réponse
/// attend `release` sans retenir aucun fil, ni la file des autorisations que d'autres tests partagent.
private final class PermissionSource: @unchecked Sendable {
    static let nothingGranted = PermissionReading(microphone: .notDetermined, accessibility: false, inputMonitoring: false,
                                                  launchAtLogin: false)
    static let allGranted = PermissionReading(microphone: .authorized, accessibility: true, inputMonitoring: true,
                                              launchAtLogin: true)

    @Guarded var reading = PermissionSource.nothingGranted
    @Guarded var readsHere = 0
    @Guarded var readsOffMain = 0
    @Guarded var queues: [String] = []
    @Guarded var readsOnMainThread = 0
    /// Ouverture à la connexion telle que `SMAppService` la dirait.
    @Guarded var launchAtLogin = false
    @Guarded private var gate: AsyncResult<Void>?

    func hold() {
        gate = AsyncResult<Void>()
    }

    func release() {
        let held = gate
        gate = nil
        held?.resolve(.success(()))
    }

    /// Lecture sur place (clic, lancement).
    func readHere() -> PermissionReading {
        readsHere += 1
        return reading
    }

    /// Lecture hors du fil principal, faite comme la vraie sur la file des autorisations.
    func readOffMain() async -> PermissionReading {
        let held = gate
        let value = await PermissionReads.offMain { [self] in
            readsOffMain += 1
            queues.append(String(cString: __dispatch_queue_get_label(nil)))
            if Thread.isMainThread { readsOnMainThread += 1 }
            return reading
        }
        if let held { try? await held.value() }
        return value
    }
}

@MainActor
private final class PermissionFixture {
    let directory: URL
    let source: PermissionSource
    let model: AppModel

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-permission-reads-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = PermissionSource()
        self.source = source
        var dependencies = AppDependencies()
        dependencies.permissions = { source.readHere() }
        dependencies.permissionsOffMain = { await source.readOffMain() }
        dependencies.launchAtLogin = { source.launchAtLogin }
        dependencies.setLaunchAtLogin = { source.launchAtLogin = $0 }
        var settings = AppSettings()
        settings.onboardingCompleted = true
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    /// Premier lancement guidé rejoué sur ce modèle, dont macOS simulé accorde tout, lu sur place.
    func guide() -> OnboardingController {
        var system = OnboardingSystem()
        system.permissions = {
            OnboardingSystem.PermissionSnapshot(microphoneGranted: true, accessibilityTrusted: true, inputMonitoringTrusted: true)
        }
        system.pollPermissions = nil
        system.keyboardListening = { _ in true }
        system.reinstallKeyboard = { _ in }
        let guide = OnboardingController(model: model, step: .permissions, replay: true, system: system)
        model.onboarding = guide
        guide.resume()
        return guide
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
struct AppPermissionReadTests {
    /// Fenêtre ou Réglages qui s'ouvrent, retour dans Wispad : lecture sur la file des autorisations, jamais sur le fil
    /// principal, qui dessine l'écran (le 14 octobre, une vingtaine de millisecondes pour le micro et la surveillance des
    /// entrées).
    @Test func openingAScreenReadsThePermissionsOffTheMainThread() async throws {
        let f = try PermissionFixture()
        defer { f.dispose() }
        f.source.reading = PermissionSource.allGranted
        f.model.refreshPermissionsInBackground()
        let applied = await settles { !f.model.readingPermissions }
        #expect(applied)
        #expect(f.model.microphoneStatus == .authorized)
        #expect(f.model.accessibilityTrusted && f.model.inputMonitoringTrusted)
        #expect(f.model.settings.launchAtLogin)
        #expect(f.source.readsOffMain == 1)
        #expect(f.source.readsHere == 0)
        #expect(f.source.readsOnMainThread == 0)
        #expect(f.source.queues == ["wispad.autorisations"])
    }

    /// Clic sur une rangée de Réglages, export du diagnostic : relecture sur place, l'écran ou le rapport en dépend
    /// aussitôt.
    @Test func aClickStillReadsThePermissionsAtOnce() throws {
        let f = try PermissionFixture()
        defer { f.dispose() }
        f.source.reading = PermissionSource.allGranted
        f.model.refreshPermissions()
        #expect(f.model.microphoneStatus == .authorized)
        #expect(f.model.accessibilityTrusted && f.model.inputMonitoringTrusted)
        #expect(f.source.readsHere == 1)
        #expect(f.source.readsOffMain == 0)
    }

    /// Retour dans Wispad, fenêtre puis Réglages ouverts pendant une lecture lente : aucune autre ne part en attendant,
    /// puis une seule relecture, partie après toutes ces demandes.
    @Test func requestsDuringASlowReadAreServedByOneMoreReadOnly() async throws {
        let f = try PermissionFixture()
        defer { f.dispose() }
        f.source.hold()
        f.model.refreshPermissionsInBackground()
        let started = await settles { f.source.readsOffMain == 1 }
        #expect(started)
        for _ in 0..<5 { f.model.refreshPermissionsInBackground() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.source.readsOffMain == 1)
        f.source.reading = PermissionSource.allGranted
        f.source.release()
        let reread = await settles { f.source.readsOffMain == 2 && !f.model.readingPermissions }
        #expect(reread)
        #expect(f.model.accessibilityTrusted && f.model.inputMonitoringTrusted)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.source.readsOffMain == 2)
        #expect(f.source.readsHere == 0)
    }

    /// Réglages s'ouvre (lecture lente), puis un clic sur une rangée relit sur place : la réponse lente, partie avant le
    /// clic, arrive après et n'efface rien. Une lecture partie ensuite s'applique.
    @Test func aSlowAnswerNeverOverwritesAReadingMadeAfterAClick() async throws {
        let f = try PermissionFixture()
        defer { f.dispose() }
        f.source.hold()
        f.model.refreshPermissionsInBackground()
        let started = await settles { f.source.readsOffMain == 1 }
        #expect(started)
        f.source.reading = PermissionSource.allGranted
        f.model.refreshPermissions()
        #expect(f.model.microphoneStatus == .authorized)
        #expect(f.model.accessibilityTrusted && f.model.inputMonitoringTrusted)
        f.source.release()
        let answered = await settles { !f.model.readingPermissions }
        #expect(answered)
        #expect(f.model.microphoneStatus == .authorized)
        #expect(f.model.accessibilityTrusted && f.model.inputMonitoringTrusted)
        #expect(f.model.settings.launchAtLogin)
        f.source.reading = PermissionSource.nothingGranted
        f.model.refreshPermissionsInBackground()
        let withdrawn = await settles { !f.model.readingPermissions && !f.model.accessibilityTrusted }
        #expect(withdrawn)
        #expect(f.model.microphoneStatus == .notDetermined)
        #expect(!f.model.inputMonitoringTrusted)
    }

    /// Le premier lancement guidé lit l'accessibilité et la surveillance des entrées pendant qu'une lecture de l'app, partie
    /// avant, tarde : chaque valeur garde sa lecture la plus récente. Le micro, que seule l'app a lu, s'affiche.
    @Test func eachValueKeepsItsNewestReadingAcrossTheAppAndTheGuide() async throws {
        let f = try PermissionFixture()
        defer { f.dispose() }
        f.source.reading = PermissionReading(microphone: .authorized, accessibility: false, inputMonitoring: false,
                                             launchAtLogin: false)
        f.source.hold()
        f.model.refreshPermissionsInBackground()
        let started = await settles { f.source.readsOffMain == 1 }
        #expect(started)
        _ = f.guide()
        #expect(f.model.accessibilityTrusted && f.model.inputMonitoringTrusted)
        f.source.release()
        let answered = await settles { !f.model.readingPermissions }
        #expect(answered)
        #expect(f.model.accessibilityTrusted && f.model.inputMonitoringTrusted)
        #expect(f.model.microphoneStatus == .authorized)
    }

    /// « Ouvrir à la connexion » activé pendant qu'une lecture, partie avant, tarde : sa réponse n'éteint pas
    /// l'interrupteur ; ses autres valeurs, les plus récentes, s'affichent.
    @Test func launchAtLoginSwitchedDuringASlowReadStaysAsSwitched() async throws {
        let f = try PermissionFixture()
        defer { f.dispose() }
        f.source.reading = PermissionReading(microphone: .authorized, accessibility: true, inputMonitoring: true,
                                             launchAtLogin: false)
        f.source.hold()
        f.model.refreshPermissionsInBackground()
        let started = await settles { f.source.readsOffMain == 1 }
        #expect(started)
        f.model.setLaunchAtLogin(true)
        #expect(f.source.launchAtLogin)
        #expect(f.model.settings.launchAtLogin)
        f.source.release()
        let answered = await settles { !f.model.readingPermissions }
        #expect(answered)
        #expect(f.model.settings.launchAtLogin)
        #expect(f.model.microphoneStatus == .authorized)
        #expect(f.model.accessibilityTrusted && f.model.inputMonitoringTrusted)
    }
}
