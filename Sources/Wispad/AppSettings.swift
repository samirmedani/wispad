import Foundation
import os
import WispadCore

enum AppSection: String, CaseIterable, Identifiable, Codable {
    case home
    case history
    case usage
    case dictionary
    case providers
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return String(localized: "Accueil")
        case .history: return String(localized: "Historique")
        case .usage: return String(localized: "Consommation")
        case .dictionary: return String(localized: "Dictionnaire")
        case .providers: return String(localized: "Fournisseurs")
        case .settings: return String(localized: "Réglages")
        }
    }
}

struct AppSettings: Codable, Equatable {
    var provider: ProviderID = .xai
    var xaiModel = ProviderID.xai.defaultLiveModel
    var openAIModel = ProviderID.openAI.defaultLiveModel
    /// Nouvelle installation : langue du système ; les réglages antérieurs restent en français.
    var language: DictationLanguage = .preferred()
    var cleanupEnabled = true
    /// Chaque dictée est aussi transcrite sur l'enregistrement complet. Le flux reste le secours.
    var verifyWithFile = true
    /// Ton demandé à la correction, par catégorie d'apps (`UsageKind.rawValue`). Absent : ton de la dictée.
    var tones: [String: DictationTone] = [:]
    /// Avec du texte sélectionné, une dictée qui commence par une consigne (« reformule », « traduis ») transforme la sélection.
    var selectionCommands = true
    var structureDictation = true
    /// La correction lit aussi la conversation visible dans la fenêtre où l'on dicte. Désactivé à la première
    /// installation, proposé au premier lancement ; les réglages antérieurs le gardent actif.
    var useWindowContext = false
    /// Premier lancement guidé terminé. Les réglages antérieurs (installation existante) le passent.
    var onboardingCompleted = false
    /// Étape du premier lancement guidé à reprendre après une relance de l'app (autorisation qui l'exige).
    /// Vide : depuis le début. Une valeur inconnue repart aussi du début (`OnboardingFlow.resumeStep`).
    var onboardingResume = ""
    /// Micro choisi (identifiant CoreAudio). Vide, ou micro débranché : celui du système.
    var microphoneUID = ""
    var retention: RetentionMode = .temporary
    var temporaryHours = 24
    var maxStorageMB = 250
    var launchAtLogin = false
    var keyCode = ChordMatcher.functionKeyCode
    var modifierFlags: UInt64 = 0x800000
    var typingWPM = 40.0
    var soundsEnabled = true
    var learnCorrections = true
    /// Masque les extraits de la carte d'accueil, sans changer les dictées conservées.
    var blurRecentDictations = false
    /// Couper le son du Mac pendant qu'on parle, et quand.
    var muteWhileDictating = true
    var muteMode: OutputMuteMode = .speakersOnly
    /// Bandeau « Une étoile sur GitHub » cliqué une fois : il ne revient plus (l'étoile est invérifiable).
    var githubStarClicked = false
    /// Choix d'affichage retrouvés au lancement suivant, écrits dès qu'ils changent : période de l'Accueil, période
    /// de Consommation (indépendantes), dernière section ouverte, clés API facultatives dépliées.
    var homePeriod: StatsPeriod = .days7
    var usagePeriod: StatsPeriod = .today
    var lastSection: AppSection = .home
    var showsOptionalKeys = false

    init() {}

    /// Lecture tolérante, réglage par réglage : une mise à jour ne fait jamais perdre les autres choix.
    /// - clé absente (réglage ajouté après coup) : sa valeur par défaut ;
    /// - valeur illisible ou retirée (fournisseur, mode, modèle) : la valeur par défaut de ce seul réglage,
    ///   ou la plus proche valide (modèle retiré → modèle par défaut du même fournisseur) ;
    /// - élément illisible d'un dictionnaire : écarté, ses voisins restent ;
    /// - clé inconnue : ignorée ici, gardée dans le bloc enregistré par `save` (sauf `retiredKeys`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        func table<T: Decodable>(_ key: CodingKeys, _ fallback: [String: T]) -> [String: T] {
            (try? container.decodeIfPresent([String: Lenient<T>].self, forKey: key))?.compactMapValues(\.value) ?? fallback
        }
        func number<T: Decodable & Comparable>(_ key: CodingKeys, _ fallback: T, in range: ClosedRange<T>) -> T {
            let stored = value(key, fallback)
            return range.contains(stored) ? stored : fallback
        }
        let defaults = AppSettings()
        provider = value(.provider, defaults.provider)
        xaiModel = Self.knownLiveModel(value(.xaiModel, defaults.xaiModel), provider: .xai)
        openAIModel = Self.knownLiveModel(value(.openAIModel, defaults.openAIModel), provider: .openAI)
        language = value(.language, DictationLanguage.french)
        cleanupEnabled = value(.cleanupEnabled, defaults.cleanupEnabled)
        verifyWithFile = value(.verifyWithFile, defaults.verifyWithFile)
        tones = table(.tones, defaults.tones)
        selectionCommands = value(.selectionCommands, defaults.selectionCommands)
        structureDictation = value(.structureDictation, defaults.structureDictation)
        useWindowContext = value(.useWindowContext, true)
        onboardingCompleted = value(.onboardingCompleted, true)
        onboardingResume = value(.onboardingResume, defaults.onboardingResume)
        microphoneUID = value(.microphoneUID, defaults.microphoneUID)
        retention = value(.retention, defaults.retention)
        temporaryHours = number(.temporaryHours, defaults.temporaryHours, in: Self.temporaryHoursRange)
        maxStorageMB = number(.maxStorageMB, defaults.maxStorageMB, in: Self.maxStorageMBRange)
        launchAtLogin = value(.launchAtLogin, defaults.launchAtLogin)
        keyCode = value(.keyCode, defaults.keyCode)
        modifierFlags = value(.modifierFlags, defaults.modifierFlags)
        typingWPM = number(.typingWPM, defaults.typingWPM, in: 1...1_000)
        soundsEnabled = value(.soundsEnabled, defaults.soundsEnabled)
        learnCorrections = value(.learnCorrections, defaults.learnCorrections)
        blurRecentDictations = value(.blurRecentDictations, defaults.blurRecentDictations)
        muteWhileDictating = value(.muteWhileDictating, defaults.muteWhileDictating)
        muteMode = value(.muteMode, defaults.muteMode)
        githubStarClicked = value(.githubStarClicked, defaults.githubStarClicked)
        homePeriod = value(.homePeriod, defaults.homePeriod)
        usagePeriod = value(.usagePeriod, defaults.usagePeriod)
        lastSection = value(.lastSection, defaults.lastSection)
        showsOptionalKeys = value(.showsOptionalKeys, defaults.showsOptionalKeys)
    }

    /// Bornes des réglages de conservation, partagées avec leurs contrôles dans Réglages.
    static let temporaryHoursRange = 1...24 * 14
    static let maxStorageMBRange = 20...5_000

    /// Modèle de voix retiré du catalogue : le modèle par défaut du même fournisseur le remplace.
    private static func knownLiveModel(_ model: String, provider: ProviderID) -> String {
        ProviderCatalog.models(for: provider).contains { $0.id == model } ? model : provider.defaultLiveModel
    }

    var liveModel: String {
        get { provider == .xai ? xaiModel : openAIModel }
        set {
            if provider == .xai { xaiModel = newValue } else { openAIModel = newValue }
        }
    }

    static let defaultsKey = "wispad.settings.v1"
    /// Réglages retirés de l'app (raccourcis vocaux, transcription sur le Mac, serveur de correction compatible
    /// OpenAI) : leurs valeurs n'ont plus d'effet et sont effacées au lancement. Un choix « Sur ce Mac » repasse ainsi
    /// sur le cloud, un serveur de correction choisi sur la correction automatique.
    static let retiredKeys = ["snippets", "voiceEngine", "localModel", "offlineLocalVoice",
                              "correction", "customCorrectionURL", "customCorrectionModel"]

    /// Efface des réglages enregistrés les valeurs des réglages retirés, sans toucher aux autres. Sans réglages
    /// enregistrés ou sans valeur retirée, rien n'est réécrit.
    static func removeRetiredKeys(from defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: defaultsKey),
              var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              retiredKeys.contains(where: { stored[$0] != nil }) else { return }
        retiredKeys.forEach { stored.removeValue(forKey: $0) }
        guard let cleaned = try? JSONSerialization.data(withJSONObject: stored) else { return }
        defaults.set(cleaned, forKey: defaultsKey)
    }

    /// Bloc illisible en entier (pas un objet JSON) : mis de côté ici avant toute écriture, jamais effacé.
    static let unreadableBackupKey = "wispad.settings.v1.illisible"

    private static let log = Logger.wispad("reglages")

    /// Réglages enregistrés. Un bloc absent est une nouvelle installation ; un bloc illisible garde une copie
    /// de côté et repart des valeurs d'une installation existante (pas de premier lancement guidé).
    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let stored = defaults.object(forKey: defaultsKey) else { return AppSettings() }
        if let data = stored as? Data, let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        if defaults.object(forKey: unreadableBackupKey) == nil {
            defaults.set(stored, forKey: unreadableBackupKey)
        }
        log.error("réglages illisibles : copie mise de côté, valeurs par défaut en mémoire")
        return existingInstallDefaults
    }

    /// Valeurs d'une installation existante dont aucun réglage n'est lisible.
    static var existingInstallDefaults: AppSettings {
        (try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))) ?? AppSettings()
    }

    /// Écrit les réglages connus de cette version par-dessus le bloc existant : une clé qu'elle ne connaît pas
    /// (ajoutée par une version plus récente, ou d'un réglage retiré) reste telle quelle pour un retour en arrière.
    /// Seules les clés de `retiredKeys`, retirées volontairement, ne sont pas reprises.
    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self),
              let current = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let stored = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        var merged = (stored as? [String: Any] ?? [:]).filter { !Self.retiredKeys.contains($0.key) }
        merged.merge(current) { _, new in new }
        let output = (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])) ?? data
        defaults.set(output, forKey: Self.defaultsKey)
    }
}

/// Élément lu à part dans une liste ou un dictionnaire : illisible, il devient nil sans faire échouer ses voisins.
struct Lenient<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
