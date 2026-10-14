import AppKit
import AVFoundation
import Foundation
import os
import WispadCore

@MainActor
@Observable
final class AppModel {
    var settings: AppSettings {
        // L'écoute du clavier, sur son propre fil, lit une copie du raccourci.
        didSet { hotkeys?.refreshConfig() }
    }
    var history: [DictationRecord] = [] {
        // Le cache des lignes ne garde ni dictée supprimée ni copie de l'historique relu.
        didSet { HistoryRowCache.shared.follow(history, previous: oldValue) }
    }
    var dictionary: [DictionaryEntry] = []
    /// Appels API, du plus récent au plus ancien.
    var usage: [UsageEvent] = []
    /// Appels déjà comptés à l'écran mais dont l'écriture SQLite doit être réessayée.
    private var pendingUsage: [String: UsageEvent] = [:]
    private(set) var usageLoadFailed = false
    var unsavedUsageCount: Int { pendingUsage.count }
    var usageStorageWarning: String? {
        if usageLoadFailed {
            return String(localized: "La consommation sauvegardée n'a pas pu être relue. Les montants affichés peuvent être incomplets.")
        }
        guard !pendingUsage.isEmpty else { return nil }
        return pendingUsage.count == 1
            ? String(localized: "1 appel compté à l'écran mais non sauvegardé. Ces données seront perdues si l'app quitte avant leur sauvegarde.")
            : String(localized: "\(pendingUsage.count) appels comptés à l'écran mais non sauvegardés. Ces données seront perdues si l'app quitte avant leur sauvegarde.")
    }
    /// Rafraîchit uniquement un détail ouvert, sans lecture supplémentaire dans la liste.
    var traceRevision = 0
    var deepSeekBalance: String?
    var xaiAccount: XAIAccountStatus?
    var xaiBalance: String?
    /// Dernière lecture des clés : sert aussi à rafraîchir l'interface quand elles changent.
    var keysLoadedAt: Date?
    /// Le coffre (ou le fichier des clés) a répondu à la dernière lecture.
    var keysReachable = true
    var statusBanner: String?
    /// Section affichée, retrouvée au lancement suivant (`AppSettings.lastSection`).
    var selectedSection: AppSection = .home {
        didSet {
            if selectedSection != .history { historyPlayer.close() }
            setDisplayChoice(\.lastSection, selectedSection)
        }
    }
    var isRecordingShortcut = false {
        didSet { hotkeys?.refreshConfig() }
    }
    /// Enregistrement de « Coller la dernière dictée » dans Réglages : le raccourci actuel est suspendu.
    var isRecordingPasteShortcut = false {
        didSet { hotkeys?.refreshConfig() }
    }
    /// Pourquoi la dernière combinaison proposée pour « Coller la dernière dictée » a été refusée.
    var pasteShortcutProblem: String?
    @ObservationIgnored private var pasteShortcutMonitor: Any?
    var microphoneStatus: AVAuthorizationStatus = .notDetermined
    var accessibilityTrusted = false
    var inputMonitoringTrusted = false
    /// Services qui viennent d'échouer : la dictée passe par leur relais pendant quelques minutes.
    var health = ServiceHealth()

    let dependencies: AppDependencies
    private let persistsSettings: Bool
    let store: HistoryStore
    let coordinator: DictationCoordinator
    let historyPlayer: HistoryAudioPlayer
    let overlay = OverlayController()
    let supportURL: URL
    weak var hotkeys: HotkeyMonitor?
    var onOpenWindow: ((AppSection) -> Void)?

    var audioDirectory: URL {
        supportURL.appendingPathComponent("Audio", isDirectory: true)
    }

    /// Dictées signalées comme mal écrites, pour le banc d'essai. Restent sur ce Mac.
    var reportsDirectory: URL {
        supportURL.appendingPathComponent("benchmarks", isDirectory: true)
            .appendingPathComponent(ErrorReportArchive.folderName, isDirectory: true)
    }

    init(supportDirectory: URL? = nil, settings initialSettings: AppSettings? = nil, dependencies: AppDependencies = AppDependencies(), historyPlayer: HistoryAudioPlayer = HistoryAudioPlayer()) throws {
        self.dependencies = dependencies
        self.historyPlayer = historyPlayer
        persistsSettings = supportDirectory == nil
        supportURL = try supportDirectory ?? AppPaths.supportDirectory()
        store = try HistoryStore(path: supportURL.appendingPathComponent(AppIdentity.databaseName).path)
        settings = initialSettings ?? AppSettings.load()
        coordinator = DictationCoordinator()
        coordinator.model = self
        selectedSection = settings.lastSection
        reload()
        purgeAudio()
        if persistsSettings { refreshPermissions() }
        if !settings.onboardingCompleted {
            onboarding = OnboardingController(model: self, step: OnboardingFlow.resumeStep(saved: settings.onboardingResume))
        }
    }

    static let storageLog = Logger.wispad("stockage")

    /// Écriture locale dont l'échec ne doit pas interrompre l'action : journalisée (sans texte, sans chemin)
    /// pour qu'un problème chez un utilisateur se voie dans le diagnostic, au lieu d'être ignorée.
    @discardableResult
    func persist(_ action: String, _ work: () throws -> Void) -> Bool {
        do {
            try work()
            return true
        } catch {
            Self.storageLog.error("échec de l'écriture locale : \(action, privacy: .public)")
            return false
        }
    }

    func saveSettings() {
        if persistsSettings { settings.save() }
    }

    /// Choix d'affichage (période, section, partie dépliée) : écrit seulement s'il change.
    func setDisplayChoice<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>, _ value: Value) {
        guard settings[keyPath: keyPath] != value else { return }
        settings[keyPath: keyPath] = value
        saveSettings()
    }

    // MARK: - Raccourci « Coller la dernière dictée »

    /// Clic sur « Modifier » : la prochaine combinaison tapée dans la fenêtre devient le raccourci. Le raccourci
    /// actuel est suspendu pendant ce temps, pour pouvoir le retaper.
    func startRecordingPasteShortcut() {
        guard !isRecordingPasteShortcut else { return }
        isRecordingShortcut = false
        pasteShortcutProblem = nil
        isRecordingPasteShortcut = true
        pasteShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = Int(event.keyCode)
            let flags = UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            MainActor.assumeIsolated { _ = self?.recordPasteShortcut(keyCode: keyCode, flags: flags) }
            // Avalée : la combinaison essayée ne déclenche rien dans la fenêtre.
            return nil
        }
    }

    func stopRecordingPasteShortcut() {
        if let monitor = pasteShortcutMonitor { NSEvent.removeMonitor(monitor) }
        pasteShortcutMonitor = nil
        if isRecordingPasteShortcut { isRecordingPasteShortcut = false }
    }

    /// Combinaison tapée pendant l'enregistrement. Échap seul annule ; une combinaison refusée laisse
    /// l'enregistrement ouvert avec la raison. Vrai si le raccourci a été enregistré.
    @discardableResult
    func recordPasteShortcut(keyCode: Int, flags: UInt64) -> Bool {
        let modifiers = flags & PasteShortcut.modifierMask
        if keyCode == HotkeyLogic.escapeKeyCode, modifiers == 0 {
            pasteShortcutProblem = nil
            stopRecordingPasteShortcut()
            return false
        }
        let candidate = PasteShortcut(keyCode: keyCode, modifiers: modifiers)
        let problem: PasteShortcutProblem?
        if flags & ModifierMask.function != 0, !PasteShortcutRules.carriesFunctionFlag(keyCode) {
            problem = .functionKey
        } else {
            problem = PasteShortcutRules.problem(
                candidate,
                system: dependencies.systemShortcuts(),
                dictation: (settings.keyCode, settings.modifierFlags)
            )
        }
        if let problem {
            pasteShortcutProblem = PasteShortcutText.message(for: problem, shortcut: KeyLabels.describe(candidate))
            return false
        }
        pasteShortcutProblem = nil
        settings.pasteLastShortcut = candidate
        saveSettings()
        stopRecordingPasteShortcut()
        return true
    }

    func resetPasteShortcut() {
        stopRecordingPasteShortcut()
        pasteShortcutProblem = nil
        settings.pasteLastShortcut = .standard
        saveSettings()
    }

    func setPasteShortcutEnabled(_ enabled: Bool) {
        stopRecordingPasteShortcut()
        pasteShortcutProblem = nil
        settings.pasteLastShortcut.enabled = enabled
        saveSettings()
    }

    /// Lecture complète, au lancement seulement : ensuite chaque écran ne relit que sa table, et la
    /// consommation est tenue à jour en mémoire par recordUsage.
    func reload() {
        reloadHistory()
        reloadDictionary()
        reloadUsage()
    }

    private func reloadUsage() {
        do {
            let stored = try store.usageEvents()
            let storedIDs = Set(stored.map(\.id))
            pendingUsage = pendingUsage.filter { !storedIDs.contains($0.key) }
            usage = (stored + Array(pendingUsage.values)).sorted { $0.createdAt > $1.createdAt }
            usageLoadFailed = false
        } catch {
            usageLoadFailed = true
        }
    }

    func reloadHistory() {
        do { history = try store.dictations() } catch { Self.storageLog.error("lecture de l'historique impossible") }
        if let id = historyPlayer.recordID, history.first(where: { $0.id == id })?.audioPath == nil {
            historyPlayer.close()
        }
    }

    func reloadDictionary() {
        do { dictionary = try store.dictionary() } catch { Self.storageLog.error("lecture du dictionnaire impossible") }
    }

    /// Jugement en cours sur des mots corrigés (exposé pour les tests).
    private(set) var learning: Task<Void, Never>?

    /// Mots corrigés juste après une dictée : le modèle de correction décide lesquels méritent le dictionnaire,
    /// pour qu'une retouche sans intérêt (mot courant, faute de frappe) n'y entre pas.
    func considerLearning(_ candidates: [CorrectionLearner.Candidate], dictated: String, speech: SpeechRequest, traceID: String? = nil) {
        guard settings.learnCorrections, !candidates.isEmpty else { return }
        let previous = learning
        learning = Task {
            await previous?.value
            guard !Task.isCancelled, settings.learnCorrections,
                  let refused = try? store.refusedTerms() else { return }
            // La file précédente a pu ajouter ou refuser un terme pendant notre attente.
            var seen = Set<String>()
            let fresh = candidates.filter { candidate in
                let term = candidate.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                return !term.isEmpty && seen.insert(term.lowercased()).inserted
                    && !dictionary.contains { $0.term.caseInsensitiveCompare(term) == .orderedSame }
                    && !refused.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
            }
            guard !fresh.isEmpty else { return }
            let judgement = await dependencies.judgeTerms(fresh, dictated, speech)
            for usage in judgement.usages { recordUsage(usage) }
            if let traceID {
                if (try? store.appendTraceCalls(id: traceID, calls: judgement.usages.map(DictationAPICall.init))) != nil {
                    traceRevision += 1
                }
            }
            guard !Task.isCancelled, settings.learnCorrections else { return }
            // Une réponse ne peut introduire un terme qui n'avait pas été proposé.
            learn(judgement.kept.filter { kept in fresh.contains { $0.corrected == kept.term } })
        }
    }

    /// Mots appris seuls depuis le lancement, du plus récent au plus ancien : le menu propose de les retirer.
    private(set) var recentlyLearned: [String] = []

    /// Mots retenus après une dictée, ajoutés au dictionnaire avec le juge qui les a retenus.
    func learn(_ terms: [LearnedTerm]) {
        guard settings.learnCorrections, let refused = try? store.refusedTerms() else { return }
        var known = Set(dictionary.map { $0.term.lowercased() })
        var added: [String] = []
        for learned in terms {
            let term = learned.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !known.contains(term.lowercased()),
                  !refused.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { continue }
            if persist("ajout au dictionnaire", { try store.addTerm(term, origin: .learned(learned.judge)) }) {
                known.insert(term.lowercased())
                added.append(term)
            }
        }
        guard !added.isEmpty else { return }
        recentlyLearned = Array((added.reversed() + recentlyLearned.filter { !added.contains($0) }).prefix(5))
        reloadDictionary()
        coordinator.notifyLearned(added)
    }

    /// Oui dans la bulle : le mot appris reste, et la confirmation est notée sans changer son origine.
    func confirmLearnedTerm(_ term: String) {
        persist("confirmation d'un mot") { try store.confirmLearnedTerm(term) }
        reloadDictionary()
    }

    /// Retire un mot par son nom (menu de la barre : mot appris à tort).
    func removeTerm(named term: String) {
        recentlyLearned.removeAll { $0 == term }
        guard let entry = dictionary.first(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        deleteTerm(entry)
    }

    /// Non dans la bulle : le mot sort du dictionnaire et ne sera plus proposé.
    func refuseLearnedTerm(_ term: String) {
        removeTerm(named: term)
        persist("refus d'un mot") { try store.rememberRefusal(term) }
    }

    /// Services mis de côté et relais pris à leur place, en clair (menu, Fournisseurs).
    func relayLines() -> [String] {
        health.downServices().map { service in
            if service == ServiceHealth.deepSeek {
                let relay = TextCleaner.plan(speechRequest(context: nil)).steps.first { !$0.hasPrefix(ServiceHealth.deepSeek) }
                return relay.map { String(localized: "DeepSeek en pause : correction via \($0)") } ?? String(localized: "DeepSeek en pause : texte inséré sans correction")
            }
            let provider = ProviderID.allCases.first { ServiceHealth.voice($0) == service }
            let name = provider?.displayName ?? service
            guard let provider else { return String(localized: "\(name) en pause") }
            let other: ProviderID = provider == .xai ? .openAI : .xai
            return hasKey(other) ? String(localized: "\(name) en pause : voix via \(other.displayName)") : String(localized: "\(name) en pause")
        }
    }

    func recordUsage(_ event: UsageEvent) {
        guard !usage.contains(where: { $0.id == event.id }) || pendingUsage[event.id] != nil else { return }
        var recorded = pendingUsage[event.id] ?? event
        do {
            try store.insertUsage(recorded)
            pendingUsage.removeValue(forKey: event.id)
        } catch {
            // Un appel peut déjà avoir été sauvegardé par un autre chemin. Sa version
            // persistée reste la référence ; tout autre échec garde l'appel en attente.
            if let stored = (try? store.usageEvents())?.first(where: { $0.id == event.id }) {
                recorded = stored
                pendingUsage.removeValue(forKey: event.id)
            } else {
                pendingUsage[event.id] = recorded
            }
        }
        usage.removeAll { $0.id == event.id }
        // Du plus récent au plus ancien, même quand deux dictées se chevauchent (un appel est daté de son début).
        usage.insert(recorded, at: usage.firstIndex { $0.createdAt <= recorded.createdAt } ?? usage.endIndex)
    }

    func retrySavingUsage() {
        for event in Array(pendingUsage.values) { recordUsage(event) }
        if usageLoadFailed { reloadUsage() }
    }

    func usageEvents(for period: StatsPeriod, now: Date = Date(), calendar: Calendar = .current) -> [UsageEvent] {
        UsagePresentation.events(usage, for: period, now: now, calendar: calendar)
    }

    func usageSummary(for period: StatsPeriod, now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        UsageSummary.make(events: usageEvents(for: period, now: now, calendar: calendar), period: .all, now: now, calendar: calendar)
    }

    func fallbackSummary(for period: StatsPeriod, now: Date = Date(), calendar: Calendar = .current) -> FallbackSummary {
        FallbackSummary.make(events: usageEvents(for: period, now: now, calendar: calendar), period: .all, now: now, calendar: calendar)
    }

    /// Relecture des clés en cours : une dictée qui attend sa clé la rejoint au lieu d'en relancer une.
    @ObservationIgnored private var keyRefresh: (token: UUID, task: Task<Void, Never>)?
    /// Attente maximale des clés par une dictée : un coffre qui ne répond plus ne retient jamais le raccourci.
    static let keyRefreshSeconds = 10.0
    /// Raccourcie par les tests.
    @ObservationIgnored var keyRefreshLimit = AppModel.keyRefreshSeconds

    /// Relit les clés (fichier de l'app, ou coffre de secrets s'il est configuré).
    func refreshKeys() async {
        await startKeyRefresh().value
    }

    /// Relecture des clés, notée en cours dès son lancement et oubliée à sa fin.
    private func startKeyRefresh() -> Task<Void, Never> {
        let token = UUID()
        let task = Task { @MainActor in
            keysReachable = await dependencies.refreshKeys()
            keysLoadedAt = Date()
            if keyRefresh?.token == token { keyRefresh = nil }
        }
        keyRefresh = (token, task)
        return task
    }

    /// Nom d'une clé dans le coffre de secrets.
    func keyLocation(for account: String) -> String {
        APIKeys.Vault.names(for: account).first ?? account
    }

    /// Enregistre une clé et rafraîchit l'interface. Faux si l'enregistrement échoue.
    @discardableResult
    func storeKey(_ account: String, _ secret: String) async -> Bool {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, await dependencies.saveKey(account, value) else { return false }
        keysLoadedAt = Date()
        return true
    }

    /// Supprime une clé de ce Mac (le coffre se gère avec son propre outil).
    @discardableResult
    func deleteKey(_ account: String) async -> Bool {
        guard dependencies.keyStore.allowsDeletion, await dependencies.deleteKey(account) else { return false }
        keysLoadedAt = Date()
        return true
    }

    func hasKey(account: String) -> Bool {
        _ = keysLoadedAt
        return !(dependencies.loadKey(account) ?? "").isEmpty
    }

    /// Dernière lecture complète des soldes : l'écran Consommation ne les relit qu'au-delà de 5 minutes, ou plus
    /// tôt si les clés ont été relues depuis.
    private(set) var balancesLoadedAt: Date?

    func refreshBalancesIfStale() async {
        if let loaded = balancesLoadedAt, Date().timeIntervalSince(loaded) < 300,
           keysLoadedAt.map({ $0 <= loaded }) ?? true { return }
        await refreshBalances()
    }

    /// Soldes réels chez les fournisseurs (appels gratuits, jamais journalisés). Une lecture interrompue (écran
    /// quitté entre-temps) ne remplace rien.
    func refreshBalances() async {
        let deepSeekKey = dependencies.loadKey(CleanupModel.deepSeekAccount) ?? ""
        let xaiKey = dependencies.loadKey(ProviderID.xai.rawValue) ?? ""
        let deepSeek = deepSeekKey.isEmpty ? nil : await BalanceProbe.deepSeek(key: deepSeekKey)
        let account = xaiKey.isEmpty ? nil : await BalanceProbe.xai(key: xaiKey)
        var prepaid: String?
        if let account, let management = dependencies.loadKey(APIKeys.xaiManagement), !management.isEmpty {
            prepaid = await BalanceProbe.xaiPrepaid(managementKey: management, teamID: account.teamID)
        }
        guard !Task.isCancelled else { return }
        deepSeekBalance = deepSeek
        xaiAccount = account
        xaiBalance = prepaid
        balancesLoadedAt = Date()
    }

    func open(_ section: AppSection) {
        selectedSection = section
        onOpenWindow?(section)
    }

    func selectProvider(_ provider: ProviderID) {
        guard provider != settings.provider else { return }
        settings.provider = provider
        saveSettings()
    }

    func apiKey() -> String? {
        dependencies.loadKey(settings.provider.rawValue)
    }

    func hasKey(_ provider: ProviderID) -> Bool {
        hasKey(account: provider.rawValue)
    }

    func hasAnyKey() -> Bool {
        ProviderID.allCases.contains { hasKey($0) }
    }

    // MARK: - Premier lancement guidé

    /// Configuration guidée affichée à la place de la fenêtre principale : au premier lancement, ou rejouée
    /// depuis Réglages. Nil une fois terminée.
    var onboarding: OnboardingController?

    /// « Revoir la configuration » (Réglages) : le parcours complet, sans rien effacer ; on peut le quitter.
    func replayOnboarding() {
        onboarding?.suspend()
        onboarding = OnboardingController(model: self, step: .welcome, replay: true)
    }

    /// Fin (ou abandon d'une configuration rejouée) : la fenêtre principale revient.
    func completeOnboarding(openSettings: Bool = false) {
        onboarding?.suspend()
        onboarding = nil
        settings.onboardingCompleted = true
        settings.onboardingResume = ""
        saveSettings()
        selectedSection = openSettings ? .settings : .home
    }

    /// Pendant l'étape « Touche » : les appuis sur le raccourci sont comptés ici et aucune dictée ne démarre.
    var shortcutProbe: ShortcutProbe?

    /// Effets du raccourci, avant la dictée. Vrai : pris par le test de l'étape « Touche », aucune dictée ne
    /// démarre. Un test resté actif hors de son étape est rendu au lieu de bloquer la dictée pour toujours.
    func shortcutReceived(_ output: HotkeyOutput) -> Bool {
        if shortcutProbe != nil {
            guard onboarding?.step == .shortcut else {
                shortcutProbe = nil
                return shortcutReceived(output)
            }
            if output.pressedAt != nil { shortcutProbe?.notePress() }
            for effect in output.effects { shortcutProbe?.note(effect) }
            return true
        }
        if output.effects.contains(where: { $0 == .startPushToTalk || $0 == .startToggle }) {
            onboarding?.noteTrialPress()
        }
        return false
    }

    /// Issue de la dernière dictée terminée (maintien ou mains libres), sans aucun texte : l'essai du premier
    /// lancement y lit la réussite ou la cause d'un échec.
    struct DictationCompletion: Equatable {
        var serial: Int
        var outcome: DictationOutcome
        var dictationID: String?
    }

    private(set) var lastCompletion: DictationCompletion?

    func noteCompletion(_ trace: DictationTrace) {
        guard trace.origin != .retry else { return }
        lastCompletion = DictationCompletion(serial: (lastCompletion?.serial ?? 0) + 1, outcome: trace.outcome, dictationID: trace.dictationID)
    }

    /// Ce qui manque pour dicter (clé d'un fournisseur), à afficher au repos ; nil si tout est prêt.
    var setupWarning: String? {
        hasAnyKey() ? nil : String(localized: "Clé API manquante")
    }

    func hasCleanupKey() -> Bool {
        hasKey(account: CleanupModel.deepSeekAccount)
    }

    // MARK: - Mises à jour

    /// Installation en un clic d'une release (téléchargement, signature, remplacement, relance).
    let updater = UpdateInstaller()
    /// Release dont la fenêtre de mise à jour est ouverte : notes de version, installation et son avancement.
    var updateSheet: ReleaseInfo?
    /// Fenêtre principale à l'écran (posé par le délégué de l'app) : la nouvelle version la rouvre après la relance.
    @ObservationIgnored var isWindowVisible: () -> Bool = { false }

    /// Version plus récente trouvée par la vérification : rappelée une seule fois par version dans la bulle, quand
    /// elle se libère après une dictée ; jamais pendant la configuration guidée.
    func noteAvailableRelease(_ release: ReleaseInfo) {
        guard onboarding == nil,
              UpdateReminder.shouldRemind(release.version, lastReminded: settings.updateRemindedVersion) else { return }
        coordinator.offerUpdate(release)
    }

    /// Le rappel vient de paraître dans la bulle : il ne reviendra plus pour cette version.
    func noteUpdateReminded(_ version: SemanticVersion) {
        setDisplayChoice(\.updateRemindedVersion, version.description)
    }

    /// Ouvre la fenêtre sur la mise à jour : notes de version et bouton d'installation.
    func showUpdate(_ release: ReleaseInfo) {
        updateSheet = release
        onOpenWindow?(selectedSection)
    }

    /// « Mettre à jour » : installation en un clic, suivie dans la fenêtre de mise à jour. Si elle ne peut pas se faire
    /// ici (dossier non modifiable, release sans disque…), la page de la release s'ouvre à la place.
    func installUpdate(_ release: ReleaseInfo) {
        let status = BuildStatus.shared
        guard let version = status.version else { return }
        let started = updater.install(
            release, kind: status.kind, installed: version,
            isIdle: { [weak self] in self?.coordinator.phase == .idle },
            relaunchArguments: { [weak self] in self?.relaunchArguments() ?? ["--updated"] },
            // Fenêtre de mise à jour fermée par son état SwiftUI : macOS refuse de quitter tant qu'elle est en feuille.
            beforeQuit: { [weak self] in self?.updateSheet = nil }
        )
        if started { updateSheet = release }
    }

    /// Arguments de la nouvelle version : elle confirme la mise à jour, et rouvre la fenêtre si elle était affichée.
    func relaunchArguments() -> [String] {
        isWindowVisible() ? ["--updated", "--section", selectedSection.rawValue] : ["--updated"]
    }

    /// Premier lancement après une mise à jour en un clic : la bulle le confirme, sans prendre le focus.
    func announceUpdated() {
        coordinator.announce(String(localized: "Wispad \(BuildStatus.shared.version ?? "—") est installé"), relay: false)
    }

    // MARK: - Clés saisies dans Fournisseurs

    /// Brouillons de clés par compte : jamais enregistrés tant qu'ils ne sont pas vérifiés.
    var keyDrafts: [String: String] = [:]
    /// Dernier message par compte (« Clé enregistrée… », « Clé refusée… »). Jamais la clé elle-même.
    var keyMessages: [String: String] = [:]
    private(set) var verifyingKeys: Set<String> = []

    /// Adresse gratuite qui confirme qu'une clé est acceptée ; nil si le compte n'en a pas.
    static func validationURL(for account: String) -> URL? {
        switch account {
        case ProviderID.xai.rawValue: return ProviderID.xai.keyValidationURL
        case ProviderID.openAI.rawValue: return ProviderID.openAI.keyValidationURL
        case CleanupModel.deepSeekAccount: return URL(string: "https://api.deepseek.com/models")
        default: return nil
        }
    }

    /// Dernière vérification de chaque clé chez son fournisseur, par compte (jamais la clé elle-même).
    var keyChecks: [String: KeyCheck] = [:]

    /// Demande gratuite qui dit si le fournisseur accepte cette clé. Un compte sans adresse de vérification
    /// est accepté tel quel.
    private func check(_ key: String, account: String) async -> KeyCheck {
        guard let url = Self.validationURL(for: account) else { return .valid }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            return KeyCheck.from(httpStatus: try await dependencies.validateKey(request))
        } catch {
            return .offline
        }
    }

    /// Vérifie la clé saisie auprès du fournisseur, puis l'enregistre sous ce compte. Une clé refusée, non
    /// vérifiée ou modifiée pendant la vérification n'est jamais enregistrée.
    func verifyAndStoreKey(_ account: String) async {
        let draft = (keyDrafts[account] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, !verifyingKeys.contains(account) else { return }
        verifyingKeys.insert(account)
        defer { verifyingKeys.remove(account) }
        keyMessages[account] = nil
        keyChecks[account] = .verifying
        func unchanged() -> Bool { (keyDrafts[account] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == draft }
        let result = await check(draft, account: account)
        guard unchanged() else {
            keyChecks[account] = nil
            return
        }
        switch result {
        case .rejected(let status):
            keyChecks[account] = result
            keyMessages[account] = String(localized: "Clé refusée (HTTP \(status)).")
            return
        case .unverified(let status):
            keyChecks[account] = result
            keyMessages[account] = String(localized: "Vérification impossible (HTTP \(status)) : clé non enregistrée.")
            return
        case .offline:
            keyChecks[account] = result
            keyMessages[account] = String(localized: "Réseau indisponible : clé non vérifiée, non enregistrée.")
            return
        case .valid, .missing, .verifying, .notSaved:
            break
        }
        guard await dependencies.saveKey(account, draft) else {
            keyChecks[account] = .notSaved
            keyMessages[account] = String(localized: "Impossible d'enregistrer la clé \(dependencies.keyStore.place).")
            return
        }
        keysLoadedAt = Date()
        keyChecks[account] = .valid
        if unchanged() { keyDrafts[account] = nil }
        keyMessages[account] = String(localized: "Clé enregistrée \(dependencies.keyStore.place).")
    }

    /// Revérifie chez le fournisseur une clé déjà enregistrée (premier lancement guidé), sans la réécrire.
    func recheckStoredKey(_ account: String) async {
        guard let key = dependencies.loadKey(account), !key.isEmpty, !verifyingKeys.contains(account) else { return }
        verifyingKeys.insert(account)
        defer { verifyingKeys.remove(account) }
        keyChecks[account] = .verifying
        let result = await check(key, account: account)
        // Clé remplacée ou retirée pendant la vérification : ce résultat ne la concerne plus.
        guard dependencies.loadKey(account) == key else {
            keyChecks[account] = nil
            return
        }
        keyChecks[account] = result
    }

    func removeKey(_ account: String) async {
        let removed = await deleteKey(account)
        if removed { keyChecks[account] = nil }
        keyMessages[account] = removed ? String(localized: "Clé supprimée de ce Mac.") : String(localized: "Impossible de retirer la clé.")
    }

    /// Textes finaux déjà livrés dans cette application. Relu dans l'historique, sans copie supplémentaire.
    /// L'utilisateur accepte d'envoyer plus de contexte : 5 dictées sur 30 minutes, 1 500 caractères.
    func recentDictationTexts(bundleID: String?, now: Date = Date()) -> [String] {
        RecentDictationContext.texts(in: history, bundleID: bundleID, now: now, limit: 5, maxAge: 30 * 60, maxCharacters: 1_500)
    }

    func speechRequest(context: DictationContext?, includeRecentDictations: Bool = false) -> SpeechRequest {
        let chosen = ProviderCatalog.liveModel(id: settings.liveModel, provider: settings.provider)
        let priorTexts = includeRecentDictations ? recentDictationTexts(bundleID: context?.bundleID) : []
        let priorTerms = priorTexts.flatMap { ContextTerms.hints(from: $0) }
        let nearbyTerms = ContextTerms.hints(from: context?.nearbyText) + ContextTerms.hints(from: context?.selectedText)
        return SpeechRequest(
            provider: settings.provider,
            liveModel: chosen.id,
            fileModel: chosen.fileModel,
            apiKey: apiKey() ?? "",
            language: settings.language,
            keyterms: RecognitionHints.keyterms(dictionary: dictionary.map(\.term), context: nearbyTerms, prior: priorTerms),
            prompt: CorrectionPrompt.recognitionPrompt(appName: context?.appName, nearby: context?.nearbyText, language: settings.language),
            cleanupKey: dependencies.loadKey(CleanupModel.deepSeekAccount),
            fallbackKey: settings.provider == .openAI ? nil : dependencies.loadKey(ProviderID.openAI.rawValue),
            cleanupPrimaryDown: health.isDown(ServiceHealth.deepSeek),
            judgeKey: dependencies.loadKey(APIKeys.typesafe)
        )
    }

    /// Ce qui empêche une dictée de partir : clé absente ou coffre injoignable.
    func voiceProblem() async -> (outcome: DictationOutcome, message: String)? {
        // Clé pas encore lue (démarrage) ou ajoutée depuis : une relecture suffit, celle en cours si elle existe.
        // Sans réponse dans `keyRefreshLimit`, le coffre est dit injoignable et la relecture continue seule.
        var reachable = keysReachable
        if (apiKey() ?? "").isEmpty {
            let refresh = keyRefresh?.task ?? startKeyRefresh()
            let answered = await DictationCoordinator.value(of: refresh, within: keyRefreshLimit) != nil
            reachable = answered && keysReachable
        }
        guard let key = apiKey(), !key.isEmpty else {
            let provider = settings.provider.displayName
            switch dependencies.keyStore {
            case .vault:
                let name = keyLocation(for: settings.provider.rawValue)
                return (.keyUnavailable, reachable
                    ? String(localized: "Aucune clé \(provider) dans le coffre (\(name)).")
                    : String(localized: "Coffre de secrets injoignable : clé \(name) indisponible."))
            case .file:
                return (.keyUnavailable, reachable
                    ? String(localized: "Ajoute ta clé \(provider) dans Fournisseurs.")
                    : String(localized: "Clés illisibles sur ce Mac : clé \(provider) indisponible."))
            }
        }
        return nil
    }

    /// Ton réglé pour la catégorie de l'app où l'on dicte.
    func tone(bundleID: String?, appName: String?) -> DictationTone {
        settings.tones[UsageClassifier.classify(bundleIdentifier: bundleID, appName: appName).rawValue] ?? .natural
    }

    /// Sélection entière à transformer, si la dictée est une consigne d'écriture et que le réglage le permet.
    func commandSelection(for transcript: String, context: DictationContext) -> String? {
        guard settings.selectionCommands, let selection = context.selectedText,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selection.count <= SelectionCommand.maxSelectionCharacters,
              SelectionCommand.isCommand(transcript) else { return nil }
        return selection
    }

    /// Correction par un fournisseur : impossible hors connexion.
    var correctionReachable: Bool {
        settings.cleanupEnabled && dependencies.isOnline()
    }

    /// Même dictée envoyée à l'autre fournisseur vocal, si sa clé est là (OpenAI quand xAI ne répond pas).
    func voiceFallback(for speech: SpeechRequest) -> SpeechRequest? {
        let other: ProviderID = speech.provider == .xai ? .openAI : .xai
        guard let key = dependencies.loadKey(other.rawValue), !key.isEmpty else { return nil }
        let chosen = ProviderCatalog.liveModel(id: other.defaultLiveModel, provider: other)
        var fallback = speech
        fallback.provider = other
        fallback.liveModel = chosen.id
        fallback.fileModel = chosen.fileModel
        fallback.apiKey = key
        return fallback
    }

    /// Relais d'une dictée dont le fournisseur de voix n'a pas répondu. Jamais hors connexion : il échouerait de
    /// même, et compterait une bascule ratée ; l'audio reste dans l'historique pour Retranscrire.
    func voiceRelay(for speech: SpeechRequest) -> SpeechRequest? {
        dependencies.isOnline() ? voiceFallback(for: speech) : nil
    }

    /// Réussite ou échec d'un service distant. Hors connexion, un échec ne dit rien du service : il n'est pas compté,
    /// sinon la dictée suivante, connexion revenue, partirait chez le relais sans raison.
    func recordHealth(_ service: String, succeeded: Bool) {
        guard succeeded || dependencies.isOnline() else { return }
        health.record(service, succeeded: succeeded)
    }

    /// Contrôle en arrière-plan des services mis de côté (appelé toutes les minutes). Hors connexion, aucun contrôle :
    /// il échouerait sans rien dire du service, et chaque essai raté s'ajouterait à Consommation.
    func checkDownServices() async {
        guard dependencies.isOnline() else { return }
        for service in health.downServices() {
            if service == ServiceHealth.deepSeek, let key = dependencies.loadKey(CleanupModel.deepSeekAccount), !key.isEmpty {
                if let usage = await dependencies.probeDeepSeek(key) {
                    recordUsage(usage)
                    recordHealth(service, succeeded: usage.succeeded)
                }
            } else if let provider = ProviderID.allCases.first(where: { ServiceHealth.voice($0) == service }),
                      let key = dependencies.loadKey(provider.rawValue), !key.isEmpty,
                      await dependencies.probeVoice(provider, key) {
                health.record(service, succeeded: true)
            }
        }
    }

    /// Enregistre chaque appel facturable et tient à jour la santé des services.
    func recordCleanup(_ outcome: CleanupOutcome) {
        for usage in outcome.failedUsages + [outcome.usage].compactMap({ $0 }) {
            recordUsage(usage)
            if usage.api == .deepSeekCleanup { recordHealth(ServiceHealth.deepSeek, succeeded: usage.succeeded) }
        }
    }

    /// Ajout à la main dans l'écran Dictionnaire : le mot est noté « ajouté par toi ».
    func addTerm(_ term: String) {
        persist("ajout au dictionnaire") { try store.addTerm(term, origin: .user) }
        reloadDictionary()
    }

    func deleteTerm(_ entry: DictionaryEntry) {
        persist("retrait du dictionnaire") { try store.deleteTerm(id: entry.id) }
        dictionary.removeAll { $0.id == entry.id }
    }

    func deleteHistory(_ record: DictationRecord) {
        if historyPlayer.recordID == record.id { historyPlayer.close() }
        if let path = record.audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        persist("suppression d'une dictée") { try store.deleteDictation(id: record.id) }
        history.removeAll { $0.id == record.id }
    }

    func deleteAllHistory() {
        historyPlayer.close()
        for record in history {
            if let path = record.audioPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        persist("suppression de l'historique") { try store.deleteAllDictations() }
        history.removeAll()
    }

    /// Note ce qui a vraiment été dit, avec ce que Wispad a entendu et écrit et une copie de l'audio.
    @discardableResult
    func reportError(_ record: DictationRecord, expected: String) -> Bool {
        let said = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return false }
        let report = ErrorReport(
            dictationID: record.id, dictatedAt: record.createdAt, expected: said,
            heard: record.rawText, written: record.finalText, alternative: record.alternativeText,
            language: settings.language.rawValue,
            provider: record.provider, model: record.model, durationSeconds: record.durationSeconds
        )
        let saved = persist("signalement d'une erreur") {
            try ErrorReportArchive.save(report, audio: record.audioPath.map { URL(fileURLWithPath: $0) }, in: reportsDirectory)
        }
        statusBanner = saved
            ? String(localized: "Erreur notée sur ce Mac. Elle servira à vérifier les prochains réglages.")
            : String(localized: "L'enregistrement local a échoué.")
        return saved
    }

    func errorReport(for record: DictationRecord) -> ErrorReport? {
        ErrorReportArchive.report(for: record.id, in: reportsDirectory)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusBanner = String(localized: "Texte copié.")
    }

    func play(_ record: DictationRecord) {
        switch coordinator.phase {
        case .starting, .listening:
            statusBanner = String(localized: "Termine la dictée avant d'écouter un audio.")
            return
        default: break
        }
        guard let path = record.audioPath, FileManager.default.fileExists(atPath: path) else {
            historyPlayer.close()
            statusBanner = String(localized: "L'audio n'est plus disponible.")
            return
        }
        do {
            try historyPlayer.play(recordID: record.id, url: URL(fileURLWithPath: path))
        } catch {
            statusBanner = String(localized: "Lecture impossible.")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled)
            settings.launchAtLogin = LoginItemController.isEnabled
            saveSettings()
        } catch {
            settings.launchAtLogin = LoginItemController.isEnabled
            statusBanner = String(localized: "Ouverture à la connexion refusée.")
        }
    }

    /// Relue aussi à chaque retour dans Wispad : seule une valeur qui change touche à l'interface.
    func refreshPermissions() {
        apply(PermissionReading.read())
    }

    /// Retour dans Wispad : les mêmes lectures, faites hors du fil principal (la plupart interrogent macOS, une
    /// dizaine de millisecondes chacune), puis appliquées. Rien ne fige la fenêtre qui revient au premier plan.
    func refreshPermissionsInBackground() {
        Task { [weak self] in
            let reading = await PermissionReads.offMain { PermissionReading.read() }
            self?.apply(reading)
        }
    }

    private func apply(_ reading: PermissionReading) {
        if microphoneStatus != reading.microphone { microphoneStatus = reading.microphone }
        if accessibilityTrusted != reading.accessibility { accessibilityTrusted = reading.accessibility }
        if inputMonitoringTrusted != reading.inputMonitoring { inputMonitoringTrusted = reading.inputMonitoring }
        if settings.launchAtLogin != reading.launchAtLogin { settings.launchAtLogin = reading.launchAtLogin }
    }

    func purgeAudio() {
        let files: [StoredAudio] = history.compactMap { record in
            guard let path = record.audioPath else { return nil }
            return StoredAudio(
                id: record.id,
                path: path,
                bytes: StoredAudio.bytes(atPath: path),
                createdAt: record.createdAt,
                expiresAt: record.audioExpiresAt
            )
        }
        let victims = RetentionPolicy.idsToDelete(
            files: files,
            now: Date(),
            maxBytes: max(1_000_000, settings.maxStorageMB * 1_048_576)
        )
        guard !victims.isEmpty else { return }
        if let id = historyPlayer.recordID, victims.contains(id) { historyPlayer.close() }
        // Audio de chaque dictée, lu une fois : chercher chaque victime dans tout l'historique était quadratique.
        let audioPaths = Dictionary(history.map { ($0.id, $0.audioPath) }, uniquingKeysWith: { first, _ in first })
        for id in victims {
            if let path = audioPaths[id] ?? nil {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        // Une seule écriture pour tous : une par audio attendait chaque fois une base occupée (2 s), sur ce fil.
        persist("purge des audios") { try store.clearAudio(ids: victims) }
        reloadHistory()
    }

    func samples(for period: StatsPeriod) -> [DictationSample] {
        let all = history.map {
            DictationSample(
                createdAt: $0.createdAt,
                wordCount: $0.wordCount,
                durationSeconds: $0.durationSeconds,
                usageCategory: $0.usageCategory
            )
        }
        return StatsCalculator.filter(samples: all, period: period, now: Date())
    }
}
