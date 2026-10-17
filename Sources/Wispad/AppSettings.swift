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
    /// Format des dates et des heures écrites par la correction (Réglages › Mise en forme), lu champ par champ.
    /// Heures en « 14h30 » par défaut : « 14 h 30 », la typographie stricte, reste au choix.
    var dateFormat = DictationDateFormat(timeStyle: .compact)
    /// Montants, pourcentages, unités et milliers (Réglages › Mise en forme), lu champ par champ.
    var numberFormat = DictationNumberFormat()
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
    /// Réduire le bruit et l'écho du micro (traitement de la voix de macOS). Désactivé par défaut : il retarde le
    /// premier démarrage du micro d'environ une seconde.
    var voiceIsolation = false
    var retention: RetentionMode = .temporary
    var temporaryHours = 24
    var maxStorageMB = 250
    var launchAtLogin = false
    var keyCode = ChordMatcher.functionKeyCode
    var modifierFlags: UInt64 = 0x800000
    /// Raccourci global « Coller la dernière dictée » (⌃⌥V par défaut), désactivable dans Réglages.
    var pasteLastShortcut = PasteShortcut.standard
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
    /// Dernière version rappelée par la bulle (« 0.1.2 ») : une nouvelle version n'est rappelée qu'une fois.
    var updateRemindedVersion = ""
    /// Choix d'affichage retrouvés au lancement suivant, écrits dès qu'ils changent : période de l'Accueil, période
    /// de Consommation (indépendantes), dernière section ouverte, clés API facultatives et filtres du dictionnaire.
    var homePeriod: StatsPeriod = .days7
    var usagePeriod: StatsPeriod = .today
    /// Taxe ajoutée aux prix comparés dans Consommation › Tout, en pourcentage (20 % par défaut, la TVA française).
    var usageTaxRate = SalesTax.defaultRate
    var lastSection: AppSection = .home
    var showsOptionalKeys = false
    var dictionaryOriginFilter: DictionaryFilter = .all
    var dictionaryPeriod: DictionaryPeriod = .all
    var dictionaryKind: DictionaryKind = .word
    var dictionarySort: DictionarySort = .newest
    /// Place de la bulle et de ses messages, et décalage hors du champ de saisie (Réglages › Bulle et messages).
    var overlayPlacement = OverlayPlacement()
    /// Apparence de l'app (Réglages › Apparence, ou le bouton de la barre latérale) : celle de macOS par défaut.
    var appearance: AppAppearance = .system

    init() {}

    /// Lecture tolérante, réglage par réglage : une mise à jour ne fait jamais perdre les autres choix.
    /// - clé absente (réglage ajouté après coup) : sa valeur par défaut ;
    /// - valeur illisible ou retirée (fournisseur, mode, modèle) : la valeur par défaut de ce seul réglage,
    ///   ou la plus proche valide (modèle retiré → modèle par défaut du même fournisseur) ; tant que ce réglage ne
    ///   change pas, `save` garde la valeur enregistrée telle quelle ;
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
        dateFormat = value(.dateFormat, defaults.dateFormat)
        numberFormat = value(.numberFormat, defaults.numberFormat)
        useWindowContext = value(.useWindowContext, true)
        onboardingCompleted = value(.onboardingCompleted, true)
        onboardingResume = value(.onboardingResume, defaults.onboardingResume)
        microphoneUID = value(.microphoneUID, defaults.microphoneUID)
        voiceIsolation = value(.voiceIsolation, defaults.voiceIsolation)
        retention = value(.retention, defaults.retention)
        temporaryHours = number(.temporaryHours, defaults.temporaryHours, in: Self.temporaryHoursRange)
        maxStorageMB = number(.maxStorageMB, defaults.maxStorageMB, in: Self.maxStorageMBRange)
        launchAtLogin = value(.launchAtLogin, defaults.launchAtLogin)
        keyCode = value(.keyCode, defaults.keyCode)
        modifierFlags = value(.modifierFlags, defaults.modifierFlags)
        // Absent (version précédente) ou invalide : ⌃⌥V, en gardant le choix activé ou désactivé s'il est lisible.
        pasteLastShortcut = PasteShortcut.restored(try? container.decodeIfPresent(PasteShortcut.self, forKey: .pasteLastShortcut))
        typingWPM = number(.typingWPM, defaults.typingWPM, in: 1...1_000)
        soundsEnabled = value(.soundsEnabled, defaults.soundsEnabled)
        learnCorrections = value(.learnCorrections, defaults.learnCorrections)
        blurRecentDictations = value(.blurRecentDictations, defaults.blurRecentDictations)
        muteWhileDictating = value(.muteWhileDictating, defaults.muteWhileDictating)
        muteMode = value(.muteMode, defaults.muteMode)
        githubStarClicked = value(.githubStarClicked, defaults.githubStarClicked)
        updateRemindedVersion = value(.updateRemindedVersion, defaults.updateRemindedVersion)
        homePeriod = value(.homePeriod, defaults.homePeriod)
        usagePeriod = value(.usagePeriod, defaults.usagePeriod)
        usageTaxRate = number(.usageTaxRate, defaults.usageTaxRate, in: SalesTax.range)
        lastSection = value(.lastSection, defaults.lastSection)
        showsOptionalKeys = value(.showsOptionalKeys, defaults.showsOptionalKeys)
        dictionaryOriginFilter = value(.dictionaryOriginFilter, defaults.dictionaryOriginFilter)
        dictionaryPeriod = value(.dictionaryPeriod, defaults.dictionaryPeriod)
        dictionaryKind = value(.dictionaryKind, defaults.dictionaryKind)
        dictionarySort = value(.dictionarySort, defaults.dictionarySort)
        overlayPlacement = value(.overlayPlacement, defaults.overlayPlacement)
        appearance = value(.appearance, defaults.appearance)
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

    /// Bloc abîmé (tronqué, invalide, pas un objet JSON) : mis de côté ici avant toute écriture, jamais effacé.
    static let unreadableBackupKey = "wispad.settings.v1.illisible"

    private static let log = Logger.wispad("reglages")

    /// Réglages enregistrés. Un bloc absent est une nouvelle installation. Un bloc abîmé (tronqué, octet invalide) est
    /// mis de côté avant d'être réécrit ; ses réglages encore entiers restent, les autres prennent les valeurs d'une
    /// installation existante (pas de premier lancement guidé).
    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let stored = defaults.object(forKey: defaultsKey) else { return AppSettings() }
        if let data = stored as? Data, let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        return decoded(storedBlock(in: defaults) ?? [:]) ?? existingInstallDefaults
    }

    /// Valeurs d'une installation existante dont aucun réglage n'est lisible.
    static var existingInstallDefaults: AppSettings {
        (try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))) ?? AppSettings()
    }

    /// Écrit les réglages par-dessus le bloc existant, sans rien perdre de ce que cette version ne lit pas (retour en
    /// arrière) :
    /// - un réglage inchangé depuis la lecture garde sa valeur enregistrée telle quelle, même illisible ici (fournisseur,
    ///   modèle ou mode d'une version plus récente) ; un réglage composé changé garde les champs qu'elle ne connaît pas ;
    /// - une clé qu'elle ne connaît pas (ajoutée par une version plus récente, ou d'un réglage retiré) reste telle
    ///   quelle ; seules les clés de `retiredKeys`, retirées volontairement, ne sont pas reprises.
    /// Relu par cette version, le bloc écrit rend toujours exactement ces réglages.
    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self),
              let current = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let stored = Self.storedBlock(in: defaults) ?? [:]
        let read = Self.decoded(stored).map(Self.encoded) ?? [:]
        var merged = stored.filter { !Self.retiredKeys.contains($0.key) }
        for (key, value) in current {
            merged[key] = StoredJSON.merged(stored: stored[key], read: read[key], current: value)
        }
        // Un réglage que cette version relirait autrement qu'en mémoire (champs liés, comme la touche et les
        // modificateurs d'un raccourci) est écrit tel quel.
        let reread = Self.decoded(merged).map(Self.encoded) ?? [:]
        for (key, value) in current where !(reread[key].map { StoredJSON.same($0, value) } ?? false) {
            merged[key] = value
        }
        let output = (try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])) ?? data
        defaults.set(output, forKey: Self.defaultsKey)
    }

    /// Bloc enregistré, lu aussi loin qu'il est intact ; nil sans bloc. Un bloc abîmé est d'abord copié sous
    /// `unreadableBackupKey`, une seule fois, jamais effacé.
    private static func storedBlock(in defaults: UserDefaults) -> [String: Any]? {
        guard let stored = defaults.object(forKey: defaultsKey) else { return nil }
        let block = (stored as? Data).flatMap(StoredJSON.object(from:))
        if block?.intact != true {
            if defaults.object(forKey: unreadableBackupKey) == nil {
                defaults.set(stored, forKey: unreadableBackupKey)
            }
            log.error("réglages abîmés : copie mise de côté, réglages lisibles gardés")
        }
        return block?.object ?? [:]
    }

    /// Réglages lus d'un objet JSON, un par un ; une clé absente prend la valeur d'une installation existante.
    private static func decoded(_ object: [String: Any]) -> AppSettings? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    /// Réglages tels qu'ils s'écrivent, clé par clé.
    private static func encoded(_ settings: AppSettings) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(settings) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Élément lu à part dans une liste ou un dictionnaire : illisible, il devient nil sans faire échouer ses voisins.
struct Lenient<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
