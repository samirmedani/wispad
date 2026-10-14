import AppKit
import AVFoundation
import Foundation
import WispadCore

/// Frontières système du premier lancement guidé : autorisations, Réglages Système, micro, relance. Les tests
/// les remplacent ; l'aperçu de développement n'en appelle aucune.
@MainActor
struct OnboardingSystem {
    struct PermissionSnapshot: Equatable {
        var microphoneGranted = false
        var microphoneDenied = false
        var accessibilityTrusted = false
        var inputMonitoringTrusted = false
    }

    /// Lecture sans aucune demande : rien ne s'affiche côté macOS.
    var permissions: @MainActor () -> PermissionSnapshot = {
        let microphone = PermissionCenter.microphoneStatus()
        return PermissionSnapshot(
            microphoneGranted: microphone == .authorized,
            microphoneDenied: microphone == .denied || microphone == .restricted,
            accessibilityTrusted: PermissionCenter.accessibilityTrusted(prompt: false),
            inputMonitoringTrusted: PermissionCenter.inputMonitoringTrusted()
        )
    }
    var requestMicrophone: @MainActor () async -> Bool = { await PermissionCenter.requestMicrophone() }
    var requestAccessibility: @MainActor () -> Void = { _ = PermissionCenter.accessibilityTrusted(prompt: true) }
    var requestInputMonitoring: @MainActor () -> Void = { PermissionCenter.requestInputMonitoring() }
    var openSettings: @MainActor (PermissionKind) -> Void = { PermissionCenter.openSettings(for: $0) }
    var openKeyboardSettings: @MainActor () -> Void = { PermissionCenter.openKeyboardSettings() }
    var relaunch: @MainActor () -> Void = { PermissionCenter.relaunch() }
    /// L'écoute du clavier de Wispad est installée et active.
    var keyboardListening: @MainActor (AppModel) -> Bool = { $0.hotkeys?.diagnosticState.listening == .enabled }
    var reinstallKeyboard: @MainActor (AppModel) -> Void = { $0.hotkeys?.installTap() }
    var inputDevices: @MainActor () -> [AudioInputDevice] = { AudioInputDevices.all() }
    var systemInput: @MainActor () -> AudioInputDevice? = { AudioInputDevices.systemDefault() }
    var makeMeter: @MainActor () -> any MicrophoneMetering = { MicrophoneMeter() }
    var fnUsage: @MainActor () -> Int? = { PermissionCenter.fnUsage() }
    var now: @MainActor () -> Date = { Date() }
}

/// État vivant du premier lancement guidé. Chaque étape lit macOS ou l'app, et sa réussite est décidée par les
/// fonctions pures de `OnboardingFlow` (WispadCore). Rien de ce qui est dit, tapé ou collé n'est journalisé.
@MainActor
@Observable
final class OnboardingController {
    unowned let model: AppModel
    @ObservationIgnored var system: OnboardingSystem
    /// Rejouée depuis Réglages : on peut la quitter, et l'étape n'est pas mémorisée pour une relance.
    let replay: Bool
    /// Aperçu de développement : états fictifs figés, aucune demande au système, aucun sondage.
    private(set) var isPreview = false
    /// Fenêtre fermée ou parcours quitté : le sondage s'arrête. La fenêtre fermée reste en mémoire avec sa vue,
    /// dont la tâche de sondage n'est pas forcément annulée par SwiftUI.
    private(set) var isSuspended = false
    /// Avance à chaque reprise : la vue relance son sondage à la réouverture, même sans avoir vu la suspension.
    private(set) var activation = 0

    private(set) var step: OnboardingStep
    /// Étapes passées avec « Plus tard ».
    private(set) var skipped: Set<OnboardingStep> = []
    /// Horloge du sondage (attentes de la touche et du collage).
    private(set) var now: Date

    // Autorisations
    private(set) var permissions: [PermissionKind: PermissionState] = [:]
    @ObservationIgnored private var requested: Set<PermissionKind> = []
    @ObservationIgnored private var inputTrustedSince: Date?

    // Micro
    private(set) var devices: [AudioInputDevice] = []
    private(set) var systemInput: AudioInputDevice?
    private(set) var detector = VoiceDetector()
    /// Dernier niveau entendu (dBFS), pour le vumètre.
    private(set) var level = SignalLevel.silence
    private(set) var meterFailed = false
    /// L'ouverture du micro du test a rendu la main.
    private(set) var meterOpened = false
    /// Ouverture du test en cours, à l'horloge : sans voix au bout de `MicrophoneCheck.silenceTimeout`, même sans
    /// aucun son reçu, l'écran dit quoi vérifier. Nil quand le test ne tourne pas.
    @ObservationIgnored private var meterStartedAt: Date?
    @ObservationIgnored private var meter: (any MicrophoneMetering)?
    @ObservationIgnored private var meterGeneration = 0

    // Touche
    private(set) var shortcutStartedAt: Date
    private(set) var fnUsage: Int?
    private var lastProbe = ShortcutProbe()

    // Essai
    /// Champ d'essai : reste en mémoire le temps de l'écran, jamais enregistré ni journalisé.
    var trialText = ""
    @ObservationIgnored private var trialBaseline = ""
    /// Dictées terminées avant le début de l'essai (ou du dernier « Réessayer ») : elles ne comptent pas.
    private var trialMark = 0
    private var trialOutcomeAt: Date?
    /// Récapitulatif de la dictée réussie ; l'essai reste réussi jusqu'à un nouvel essai.
    private(set) var trialSummary: TrialSummary?
    /// État d'essai imposé par l'aperçu de développement (aucune vraie dictée).
    private var previewTrialStatus: OnboardingStatus?
    /// Geste de dictée reçu pendant l'essai, pas encore suivi d'une écoute ni d'une issue.
    private var trialPressedAt: Date?
    /// Depuis quand la dictée ouvre le micro ou se termine, sans avancer (phase observée par le sondage).
    @ObservationIgnored private var stalledPhase: DictationPhase?
    @ObservationIgnored private var stalledSince: Date?

    struct TrialSummary: Equatable {
        var words: Int
        var seconds: Double
    }

    init(model: AppModel, step: OnboardingStep = .welcome, replay: Bool = false, system: OnboardingSystem = OnboardingSystem()) {
        self.model = model
        self.step = step
        self.replay = replay
        self.system = system
        let start = Date()
        now = start
        shortcutStartedAt = start
    }

    // MARK: - Progression

    func status(_ step: OnboardingStep) -> OnboardingStatus {
        switch step {
        case .welcome, .finish:
            return .todo
        case .permissions:
            return PermissionsCheck.status(permissions)
        case .microphone:
            return MicrophoneCheck.status(permission: permissions[.microphone] ?? .notRequested,
                                          hasInputDevice: !devices.isEmpty || systemInput != nil,
                                          meterFailed: meterFailed, detector: detector,
                                          listening: meterStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0,
                                          meterStarted: meterOpened)
        case .provider:
            return ProviderCheck.status(voice: voiceKeyCheck)
        case .shortcut:
            return ShortcutCheck.status(probe: probe, waited: now.timeIntervalSince(shortcutStartedAt),
                                        inputMonitoring: permissions[.inputMonitoring] ?? .notRequested)
        case .trial:
            if let previewTrialStatus { return previewTrialStatus }
            if trialSummary != nil, !dictating { return .succeeded }
            return liveTrialStatus
        }
    }

    var currentStatus: OnboardingStatus { status(step) }

    var canContinue: Bool { OnboardingFlow.canContinue(step, status: currentStatus) }

    func advance() {
        guard canContinue, let next = step.next else { return }
        go(to: next)
    }

    func later() {
        guard step.allowsLater, let next = step.next else { return }
        skipped.insert(step)
        go(to: next)
    }

    func back() {
        guard let previous = step.previous else { return }
        go(to: previous)
    }

    func go(to next: OnboardingStep) {
        guard next != step else { return }
        leave(step)
        step = next
        if !replay, !isPreview {
            if next == .finish {
                // Fin atteinte : autorisations et clé sont réussies, les autres étapes faites ou laissées pour plus
                // tard, et « Retour » n'est plus proposé. La configuration est faite, même si Wispad est quitté
                // avant « Terminer » : elle ne revient pas depuis Bienvenue au lancement suivant.
                model.settings.onboardingCompleted = true
                model.settings.onboardingResume = ""
            } else {
                model.settings.onboardingResume = next.rawValue
            }
            model.saveSettings()
        }
        enter(next)
    }

    /// Fin du parcours : la fenêtre principale revient, éventuellement sur Réglages.
    func finish(openSettings: Bool = false) {
        guard !isPreview else { return }
        model.completeOnboarding(openSettings: openSettings)
    }

    /// Fenêtre fermée ou parcours terminé : micro et écoute de la touche rendus, sondage arrêté.
    func suspend() {
        isSuspended = true
        leave(step)
    }

    /// Fenêtre (ré)affichée : l'étape courante reprend ses contrôles, et la vue son sondage. Une étape déjà réussie
    /// le reste : voix entendue au micro, essai réussi (les appuis du test de la touche sont déjà gardés).
    func resume() {
        isSuspended = false
        activation += 1
        enter(step, resuming: true)
    }

    /// Sondage de la vue : `tick` toutes les 0,5 s tant que la fenêtre est affichée. Il s'arrête dès la suspension
    /// (fenêtre fermée) : plus de lecture des autorisations, deux fois par seconde, derrière une fenêtre fermée.
    func poll(every interval: Duration = .milliseconds(500)) async {
        while !Task.isCancelled, !isSuspended {
            tick()
            try? await Task.sleep(for: interval)
        }
    }

    /// Sondage léger (toutes les 0,5 s pendant l'affichage) : autorisations, attentes, réussite de l'essai.
    func tick() {
        guard !isPreview else { return }
        now = system.now()
        let microphone = permissions[.microphone]
        refreshPermissions()
        followMicrophonePermission(from: microphone)
        noteStall()
        noteTrialProgress()
        // Clé enregistrée restée sans résultat (vérification écartée, clé relue) : vérifiée, jamais « Vérification… »
        // affichée sans vérification en cours.
        if step == .provider { checkStoredKeys(retryingInconclusive: false) }
    }

    /// Étape « Micro » : accès retiré dans Réglages Système pendant l'écran, le test rend le micro (il n'entendrait
    /// plus que du silence) ; accès rendu, le test repart de lui-même au lieu d'attendre une voix qu'il n'écoute pas.
    private func followMicrophonePermission(from previous: PermissionState?) {
        guard step == .microphone, !isSuspended, let previous else { return }
        let current = permissions[.microphone]
        guard current != previous else { return }
        if current == .granted {
            startMicrophoneTest()
        } else if previous == .granted {
            stopMicrophoneTest()
        }
    }

    private func enter(_ step: OnboardingStep, resuming: Bool = false) {
        guard !isPreview else { return }
        now = system.now()
        refreshPermissions()
        switch step {
        case .microphone: startMicrophoneTest(keepingVoice: resuming)
        case .provider: checkStoredKeys()
        case .shortcut: startShortcutProbe()
        case .trial:
            // Le test de la touche ne doit jamais survivre à son étape : sinon fn ne dicterait plus.
            stopShortcutProbe()
            if resuming {
                // Une dictée arrivée dans le champ pendant que la fenêtre était fermée compte aussi.
                noteTrialProgress()
            }
            if !resuming || trialSummary == nil { beginTrial() }
        case .welcome, .permissions, .finish: break
        }
    }

    private func leave(_ step: OnboardingStep) {
        guard !isPreview else { return }
        switch step {
        case .microphone: stopMicrophoneTest()
        case .shortcut: stopShortcutProbe()
        case .welcome, .permissions, .provider, .trial, .finish: break
        }
    }

    // MARK: - Autorisations

    func refreshPermissions() {
        guard !isPreview else { return }
        let snapshot = system.permissions()
        let at = system.now()
        if snapshot.inputMonitoringTrusted {
            if inputTrustedSince == nil {
                inputTrustedSince = at
                // Autorisation qui vient d'arriver : l'écoute du clavier s'installe sans attendre sa vérification.
                system.reinstallKeyboard(model)
            }
        } else {
            inputTrustedSince = nil
        }
        let settling = inputTrustedSince.map { at.timeIntervalSince($0) < 3 } ?? false
        let fresh: [PermissionKind: PermissionState] = [
            .microphone: PermissionsCheck.microphone(granted: snapshot.microphoneGranted, denied: snapshot.microphoneDenied,
                                                     requested: requested.contains(.microphone)),
            .accessibility: PermissionsCheck.accessibility(trusted: snapshot.accessibilityTrusted,
                                                           requested: requested.contains(.accessibility)),
            .inputMonitoring: PermissionsCheck.inputMonitoring(trusted: snapshot.inputMonitoringTrusted,
                                                               listening: system.keyboardListening(model),
                                                               requested: requested.contains(.inputMonitoring),
                                                               settling: settling),
        ]
        if fresh != permissions { permissions = fresh }
        if model.accessibilityTrusted != snapshot.accessibilityTrusted { model.accessibilityTrusted = snapshot.accessibilityTrusted }
        if model.inputMonitoringTrusted != snapshot.inputMonitoringTrusted { model.inputMonitoringTrusted = snapshot.inputMonitoringTrusted }
    }

    /// Demande système (première fois) ; ensuite, le bon panneau de Réglages Système.
    func request(_ kind: PermissionKind) {
        guard !isPreview else { return }
        let state = permissions[kind] ?? .notRequested
        requested.insert(kind)
        guard state == .notRequested else {
            system.openSettings(kind)
            refreshPermissions()
            return
        }
        switch kind {
        case .microphone:
            Task { [weak self] in
                guard let self else { return }
                _ = await system.requestMicrophone()
                refreshPermissions()
            }
        case .accessibility:
            system.requestAccessibility()
        case .inputMonitoring:
            system.requestInputMonitoring()
            system.reinstallKeyboard(model)
        }
        refreshPermissions()
    }

    func openSettings(_ kind: PermissionKind) {
        guard !isPreview else { return }
        requested.insert(kind)
        system.openSettings(kind)
    }

    /// Relance demandée par macOS : l'étape est gardée pour reprendre au même endroit.
    func relaunch() {
        guard !isPreview else { return }
        model.settings.onboardingResume = step.rawValue
        model.saveSettings()
        system.relaunch()
    }

    // MARK: - Micro

    var effectiveMicrophoneUID: String? {
        let saved = model.settings.microphoneUID
        return InputDeviceChoice.effectiveUID(saved: saved.isEmpty ? nil : saved, available: devices.map(\.uid))
    }

    /// Ouvre le micro choisi pour le vumètre. Seul le niveau en sort : rien n'est enregistré ni envoyé.
    /// `keepingVoice` : fenêtre rouverte, une voix déjà entendue reste acquise tant que l'accès au micro est accordé ;
    /// le vumètre repart quand même.
    func startMicrophoneTest(keepingVoice: Bool = false) {
        guard !isPreview else { return }
        stopMicrophoneTest()
        devices = system.inputDevices()
        systemInput = system.systemInput()
        if !keepingVoice || !detector.detected || permissions[.microphone] != .granted { detector = VoiceDetector() }
        level = SignalLevel.silence
        meterFailed = false
        meterOpened = false
        guard permissions[.microphone] == .granted, !devices.isEmpty || systemInput != nil else { return }
        let meter = system.makeMeter()
        self.meter = meter
        meterGeneration += 1
        let generation = meterGeneration
        meterStartedAt = system.now()
        let uid = effectiveMicrophoneUID
        Task { [weak self] in
            do {
                try await meter.start(deviceUID: uid) { [weak self] level, seconds in
                    guard let self, self.meterGeneration == generation else { return }
                    self.level = level
                    self.detector.add(level: level, seconds: seconds)
                }
                guard let self, self.meterGeneration == generation else {
                    meter.stop()
                    return
                }
                self.meterOpened = true
            } catch {
                guard let self, self.meterGeneration == generation else { return }
                self.meterFailed = true
            }
        }
    }

    func stopMicrophoneTest() {
        meterGeneration += 1
        meter?.stop()
        meter = nil
        meterStartedAt = nil
    }

    /// Autre micro : retenu pour les dictées, et le test recommence avec lui.
    func selectMicrophone(_ uid: String) {
        guard !isPreview else { return }
        model.settings.microphoneUID = uid
        model.saveSettings()
        startMicrophoneTest()
    }

    // MARK: - Fournisseur

    var voiceAccount: String { model.settings.provider.rawValue }

    var voiceKeyCheck: KeyCheck { keyCheck(voiceAccount) }

    /// Clé vérifiée, ou en cours de vérification si elle est enregistrée mais pas encore revue.
    func keyCheck(_ account: String) -> KeyCheck {
        if let check = model.keyChecks[account] { return check }
        return model.hasKey(account: account) ? .verifying : .missing
    }

    /// Les clés déjà enregistrées sont revérifiées chez leur fournisseur, sans être réécrites : celles qui n'ont pas de
    /// résultat et, sauf `retryingInconclusive` faux (sondage), celles dont la vérification n'a pas abouti (pas de
    /// réseau, réponse inattendue). Un résultat net (valide, refusée) est gardé.
    func checkStoredKeys(retryingInconclusive: Bool = true) {
        guard !isPreview else { return }
        for account in [voiceAccount, CleanupModel.deepSeekAccount, ProviderID.openAI.rawValue]
        where model.hasKey(account: account) {
            let due: Bool
            switch model.keyChecks[account] {
            case nil: due = true
            case .offline?, .unverified?: due = retryingInconclusive
            case .missing?, .verifying?, .valid?, .rejected?, .notSaved?: due = false
            }
            if due { Task { await model.recheckStoredKey(account) } }
        }
    }

    /// « Réessayer » sur un problème de clé : utile quand la clé de voix est déjà enregistrée et qu'aucune autre n'est
    /// en cours de saisie. Sans lui, il faudrait la recoller pour la vérifier de nouveau (réseau revenu, crédit ajouté).
    var retriesStoredVoiceKey: Bool {
        let draft = (model.keyDrafts[voiceAccount] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.isEmpty && model.hasKey(account: voiceAccount)
    }

    /// La clé de voix enregistrée est revérifiée chez son fournisseur, quel que soit le dernier résultat.
    func retryVoiceKey() {
        guard !isPreview else { return }
        let account = voiceAccount
        Task { await model.recheckStoredKey(account) }
    }

    // MARK: - Touche

    var probe: ShortcutProbe { model.shortcutProbe ?? lastProbe }

    var shortcutIsFn: Bool { model.settings.keyCode == ChordMatcher.functionKeyCode }

    /// Le réglage macOS « Touche fn/🌐 » mérite d'être signalé.
    var fnSettingMatters: Bool { ShortcutCheck.fnSettingMatters(shortcutIsFn: shortcutIsFn, fnUsage: fnUsage) }

    func startShortcutProbe() {
        guard !isPreview else { return }
        shortcutStartedAt = system.now()
        fnUsage = system.fnUsage()
        model.shortcutProbe = lastProbe
    }

    func stopShortcutProbe() {
        guard let current = model.shortcutProbe else { return }
        lastProbe = current
        model.shortcutProbe = nil
        // Un maintien ou un double appui a pu laisser le geste « en cours » : il repart de zéro pour l'essai.
        model.hotkeys?.sessionEnded()
    }

    func openKeyboardSettings() {
        guard !isPreview else { return }
        system.openKeyboardSettings()
    }

    // MARK: - Essai

    var dictating: Bool {
        switch model.coordinator.phase {
        case .starting, .listening, .finishing: return true
        case .idle, .failure: return false
        }
    }

    /// Dernière dictée terminée depuis le début de l'essai.
    var trialCompletion: AppModel.DictationCompletion? {
        guard let completion = model.lastCompletion, completion.serial > trialMark else { return nil }
        return completion
    }

    private var trialTextArrived: Bool {
        let text = trialText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text != trialBaseline.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var liveTrialStatus: OnboardingStatus {
        let current = now
        return TrialCheck.status(dictating: dictating, outcome: trialCompletion?.outcome, online: model.dependencies.isOnline(),
                                 textArrived: trialTextArrived,
                                 waited: trialOutcomeAt.map { current.timeIntervalSince($0) } ?? 0,
                                 stalled: stalledSince.map { max(0, current.timeIntervalSince($0)) } ?? 0,
                                 sincePress: trialPressedAt.map { max(0, current.timeIntervalSince($0)) })
    }

    func beginTrial() {
        guard !isPreview else { return }
        trialMark = model.lastCompletion?.serial ?? 0
        trialBaseline = trialText
        trialOutcomeAt = nil
        trialSummary = nil
        trialPressedAt = nil
    }

    /// Une dictée commence : le texte déjà dans le champ ne compte pas pour elle.
    func dictationStarted() {
        guard !isPreview, step == .trial else { return }
        trialBaseline = trialText
        trialMark = model.lastCompletion?.serial ?? 0
        trialOutcomeAt = nil
        trialSummary = nil
        trialPressedAt = nil
    }

    /// Le raccourci vient de demander une dictée pendant l'essai : l'attente commence, avec un délai maximal
    /// (`TrialCheck.startGrace`) au lieu d'un « Prêt » sans fin si l'écoute ne s'ouvre pas.
    func noteTrialPress() {
        guard !isPreview, step == .trial, !dictating else { return }
        dictationStarted()
        trialPressedAt = system.now()
    }

    /// Ouverture du micro ou fin de dictée qui n'avance plus : mesurée pour le délai maximal de l'essai.
    private func noteStall() {
        let phase = model.coordinator.phase
        switch phase {
        case .starting, .finishing:
            if stalledPhase != phase {
                stalledPhase = phase
                stalledSince = system.now()
            }
        case .idle, .listening, .failure:
            stalledPhase = nil
            stalledSince = nil
        }
    }

    /// La dictée vise Wispad lui-même (fenêtre de l'essai au premier plan) : son texte s'écrit directement dans
    /// le champ d'essai, sans collage système ni lecture d'accessibilité de la propre fenêtre de Wispad.
    func acceptsDictation(targetPID: pid_t?) -> Bool {
        !isPreview && step == .trial && targetPID == ProcessInfo.processInfo.processIdentifier
    }

    /// Texte final de la dictée, ajouté au champ d'essai (séparé du texte précédent par une espace).
    func receiveDictation(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let last = trialText.last, !last.isWhitespace { trialText += " " }
        trialText += text
    }

    /// Une dictée vient de se terminer, ou le champ a changé : réussite et récapitulatif.
    func noteTrialProgress() {
        guard !isPreview, step == .trial else { return }
        if trialCompletion != nil, trialOutcomeAt == nil { trialOutcomeAt = system.now() }
        guard trialSummary == nil, liveTrialStatus.isSucceeded, let completion = trialCompletion else { return }
        let record = completion.dictationID.flatMap { id in model.history.first { $0.id == id } }
        trialSummary = TrialSummary(words: record?.wordCount ?? WordCount.count(trialText),
                                    seconds: record?.durationSeconds ?? 0)
    }

    func retryTrial() {
        beginTrial()
    }
}

#if DEBUG
extension OnboardingController {
    /// États fictifs de l'aperçu hors écran (`--onboarding-step`, `--onboarding-state`) : rien n'est demandé
    /// à macOS, aucun micro ne s'ouvre, aucune touche n'est écoutée.
    enum PreviewState: String {
        case done
        case failed
        case progress
    }

    static func preview(model: AppModel, step: OnboardingStep, state: PreviewState) -> OnboardingController {
        let controller = OnboardingController(model: model, step: step)
        controller.isPreview = true
        let past = Date().addingTimeInterval(-60)
        controller.now = Date()
        let granted: [PermissionKind: PermissionState] = [.microphone: .granted, .accessibility: .granted, .inputMonitoring: .granted]
        controller.permissions = granted
        controller.devices = [AudioInputDevice(uid: "preview-builtin", name: "Micro MacBook"),
                              AudioInputDevice(uid: "preview-usb", name: "Micro USB")]
        controller.systemInput = controller.devices.first
        controller.fnUsage = 0
        model.keyChecks[ProviderID.xai.rawValue] = .valid
        switch (step, state) {
        case (.permissions, .done):
            break
        case (.permissions, .failed):
            controller.permissions[.microphone] = .denied
            controller.permissions[.inputMonitoring] = .needsRelaunch
        case (.permissions, .progress):
            controller.permissions[.accessibility] = .waiting
            controller.permissions[.inputMonitoring] = .notRequested
        case (.microphone, .done):
            for _ in 0..<20 { controller.detector.add(level: -60, seconds: 0.05) }
            for _ in 0..<20 { controller.detector.add(level: -26, seconds: 0.05) }
            controller.level = -24
        case (.microphone, .failed):
            controller.detector.add(level: -70, seconds: MicrophoneCheck.silenceTimeout)
            controller.level = -70
        case (.microphone, .progress):
            for _ in 0..<20 { controller.detector.add(level: -60, seconds: 0.05) }
            for _ in 0..<5 { controller.detector.add(level: -30, seconds: 0.05) }
            controller.level = -32
        case (.provider, .done):
            model.keyChecks[CleanupModel.deepSeekAccount] = .valid
        case (.provider, .failed):
            model.keyChecks[ProviderID.xai.rawValue] = .rejected(401)
        case (.provider, .progress):
            model.keyChecks[ProviderID.xai.rawValue] = .verifying
        case (.shortcut, .done):
            controller.lastProbe.notePress()
            controller.lastProbe.note(.startPushToTalk)
        case (.shortcut, .failed):
            controller.shortcutStartedAt = past
            controller.fnUsage = 2
        case (.shortcut, .progress):
            controller.shortcutStartedAt = Date()
        case (.trial, .done):
            controller.trialText = "Bonjour, je teste Wispad et je dicte mon premier message."
            controller.trialSummary = TrialSummary(words: 10, seconds: 4.2)
        case (.trial, .failed):
            controller.previewTrialStatus = .failed(.trial(.network))
        case (.trial, .progress):
            controller.previewTrialStatus = .inProgress
        default:
            break
        }
        return controller
    }
}
#endif
