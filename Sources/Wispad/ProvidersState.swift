import SwiftUI
import WispadCore

// MARK: - Choix

/// Choix faits dans Fournisseurs : sélecteur de modèle, réglages avancés et boutons de la vue d'ensemble. Ce sont les
/// règles de l'écran depuis l'origine : un modèle dont la clé n'est pas active ne se choisit pas ; prendre pour la voix
/// le fournisseur du relais fait de l'ancien modèle de voix le relais (`selectProvider`) ; prendre pour la correction
/// le modèle du relais remet le relais sur « Aucun relais ».
extension AppModel {
    /// Voix : fournisseur et modèle, si la clé de ce fournisseur est active.
    func chooseVoice(_ provider: ProviderID, model id: String) {
        guard hasKey(provider) else { return }
        selectProvider(provider)
        settings.liveModel = id
        saveSettings()
    }

    /// Modèle de voix gardé pour ce fournisseur : celui qu'il reprend quand on revient à lui.
    func liveModel(for provider: ProviderID) -> String {
        provider == .xai ? settings.xaiModel : settings.openAIModel
    }

    /// Relais de la voix affiché : le choix enregistré ; tant qu'il n'y en a pas, le recommandé de l'autre fournisseur
    /// s'il a une clé active ; « Aucun relais » sinon.
    var displayedVoiceRelay: String {
        if let chosen = chosenVoiceRelay { return chosen.id }
        let other = settings.provider.other
        if settings.voiceRelay == AppSettings.voiceRelayOff || !hasKey(other) { return AppSettings.voiceRelayOff }
        return other.defaultLiveModel
    }

    /// Relais de la voix : un modèle de l'autre fournisseur, si sa clé est active, ou `AppSettings.voiceRelayOff`.
    func chooseVoiceRelay(_ choice: String) {
        guard choice == AppSettings.voiceRelayOff || hasKey(settings.provider.other) else { return }
        settings.voiceRelay = choice
        saveSettings()
    }

    /// Correction : « Automatique », ou un modèle dont la clé est active.
    func chooseCleanup(_ choice: CleanupChoice) {
        guard choice.account.map({ hasKey(account: $0) }) ?? true else { return }
        settings.cleanupChoice = choice
        if settings.cleanupRelay == choice { settings.cleanupRelay = .off }
        saveSettings()
    }

    /// Relais de la correction : « Aucun relais », ou un modèle dont la clé est active.
    func chooseCleanupRelay(_ choice: CleanupChoice) {
        guard choice == .off || (choice.account.map { hasKey(account: $0) } ?? false) else { return }
        settings.cleanupRelay = choice
        saveSettings()
    }

    /// Juge des mots appris : Jev allume la clé TypeSafe, qui ne sert qu'à lui ; « Comme la correction » la coupe.
    func chooseJudge(jev: Bool) {
        guard hasStoredKey(account: APIKeys.typesafe) else { return }
        setKeyEnabled(APIKeys.typesafe, jev)
    }

    /// Interrupteurs de Fournisseurs, les mêmes que dans Réglages.
    func setSetting(_ keyPath: WritableKeyPath<AppSettings, Bool>, _ value: Bool) {
        settings[keyPath: keyPath] = value
        saveSettings()
    }
}

// MARK: - Noms et prix

/// Nom d'un compte de clé dans Fournisseurs : « xAI », « OpenAI », « DeepSeek », « TypeSafe », « Modèle local ».
enum ProviderName {
    static func of(_ account: String) -> String {
        account == CleanupModel.localAccount ? String(localized: "Modèle local") : APIKeys.title(account)
    }
}

extension CleanupService {
    /// Compte de la clé qui sert ce service ; nil pour un fournisseur inconnu.
    var account: String? {
        CleanupChoice.accounts.first { CleanupChoice.providerName(account: $0) == provider }
    }

    /// « DeepSeek Flash », ou « OpenAI gpt-4.1-mini » pour un modèle sans nom lisible.
    var readable: String { CleanupModelText.label(provider: provider, model: model) }
}

/// Textes d'un modèle de correction : nom lisible, rapidité et prix.
enum CleanupModelText {
    /// Les modèles d'origine ont un nom lisible ; les autres gardent leur identifiant chez le fournisseur.
    static func name(_ model: String) -> String {
        switch model {
        case CleanupModel.deepSeek: return "DeepSeek Flash"
        case CleanupModel.openAIFallback: return "GPT-5.4 mini"
        case "gpt-5.6-luna": return "GPT-5.6 Luna"
        case "grok-4.7": return "Grok 4.7"
        default: return model
        }
    }

    /// « DeepSeek Flash » pour un modèle d'origine, « OpenAI gpt-4.1-mini » pour les autres.
    static func label(provider: String, model: String) -> String {
        let readable = name(model)
        return readable == model ? "\(provider) \(model)" : readable
    }

    /// « ≈ 0,05 $ / 100 dictées », « Gratuit, sur ce Mac » ou « Prix inconnu ».
    static func price(_ model: String, account: String) -> String {
        if account == CleanupModel.localAccount { return String(localized: "Gratuit, sur ce Mac") }
        guard let cost = TextModelCatalog.costPerHundred(model) else { return String(localized: "Prix inconnu") }
        return String(localized: "≈ \(MoneyFormat.price(cost)) / 100 dictées")
    }

    /// « ≈ 0,92 s chez toi », mesuré sur tes corrections, sinon « Rapide », « Moyen » ou « Lent » d'après son nom.
    static func speed(_ model: String, measured: Int?) -> String {
        if let measured { return String(localized: "≈ \(CallText.latency(measured)) chez toi") }
        switch TextModelCatalog.speed(model) {
        case .fast: return String(localized: "Rapide")
        case .balanced: return String(localized: "Moyen")
        case .slow: return String(localized: "Lent")
        }
    }
}

/// Ce que montre un bouton de modèle : pastille du fournisseur, nom, précision, et ce qui l'empêche de servir.
struct ModelSummary: Equatable {
    /// Compte de la pastille ; nil sans fournisseur (correction coupée, aucun relais).
    var account: String?
    var title: String
    var caption: String
    var warning: String?
}

// MARK: - État de l'écran

/// Une clé qui manque ou qui est coupée alors qu'un choix en a besoin. Une même clé ne fait qu'un avertissement, même
/// quand elle sert à plusieurs étapes.
struct KeyGap: Equatable, Identifiable {
    enum Role: Equatable {
        case voice, voiceRelay, correction, correctionRelay
    }

    var account: String
    /// Vrai : la clé est enregistrée, mais coupée. Faux : aucune clé.
    var stored: Bool
    var roles: [Role]

    var id: String { account }

    /// « Clé OpenAI coupée » ou « Aucune clé OpenAI ».
    var title: String {
        let name = ProviderName.of(account)
        return stored ? String(localized: "Clé \(name) coupée") : String(localized: "Aucune clé \(name)")
    }

    /// « Nécessaire pour le relais de la voix et le relais de la correction. »
    var detail: String {
        let uses = roles.map { role -> String in
            switch role {
            case .voice: return String(localized: "la voix")
            case .voiceRelay: return String(localized: "le relais de la voix")
            case .correction: return String(localized: "la correction choisie")
            case .correctionRelay: return String(localized: "le relais de la correction")
            }
        }
        return String(localized: "Nécessaire pour \(uses.formatted(.list(type: .and).locale(appLocale))).")
    }
}

/// L'écran Fournisseurs en valeurs, lues une fois par affichage : choix enregistrés, clés, et services que les dictées
/// prennent vraiment. Les vues reçoivent ces valeurs ; aucune ne relit le modèle pour les recalculer.
struct ProvidersSnapshot: Equatable {
    var keysReachable: Bool
    var keyStore: KeyStoreKind
    /// Clés lues sur un serveur ou dans un gestionnaire : on n'en ajoute pas depuis Wispad.
    var readOnlyKeys: Bool
    /// Comptes dont la clé est enregistrée (coupée ou non), et ceux dont la clé sert. Le modèle local en fait partie
    /// quand son adresse est réglée.
    var stored: Set<String>
    var active: Set<String>
    var voice: SpeechModel
    /// Relais de la voix affiché (nil : aucun relais), et celui choisi à la main, même sans clé.
    var voiceRelay: SpeechModel?
    var chosenVoiceRelay: SpeechModel?
    var verifyWithFile: Bool
    var cleanupEnabled: Bool
    var cleanupChoice: CleanupChoice
    var cleanupRelay: CleanupChoice
    var displayedCleanupRelay: CleanupChoice
    /// Services de correction qu'une dictée essaie maintenant, dans l'ordre, panne en cours comprise.
    var services: [CleanupService]
    /// Premier service hors panne : le relais ne peut pas le doubler.
    var primary: CleanupService?
    /// Service que « Automatique » prendrait.
    var automatic: CleanupService?
    /// Modèle de correction, ou relais, choisi sans clé active.
    var chosenCleanupKeyMissing: Bool
    var relayCleanupKeyMissing: Bool
    var learnCorrections: Bool

    @MainActor
    init(model: AppModel) {
        let settings = model.settings
        let speech = model.speechRequest(context: nil)
        var calm = speech
        calm.cleanupPrimaryDown = false
        var automaticRequest = calm
        automaticRequest.cleanupChoice = .automatic
        let accounts = APIKeys.accounts + [CleanupModel.localAccount]
        keysReachable = model.keysReachable
        keyStore = model.dependencies.keyStore
        readOnlyKeys = model.usesRemoteKeySource
        stored = Set(accounts.filter { model.hasStoredKey(account: $0) })
        active = Set(accounts.filter { model.hasKey(account: $0) })
        voice = ProviderCatalog.liveModel(id: settings.liveModel, provider: settings.provider)
        let relay = model.displayedVoiceRelay
        voiceRelay = relay == AppSettings.voiceRelayOff ? nil : ProviderCatalog.model(id: relay, provider: settings.provider.other)
        chosenVoiceRelay = model.chosenVoiceRelay
        verifyWithFile = settings.verifyWithFile
        cleanupEnabled = settings.cleanupEnabled
        cleanupChoice = settings.cleanupChoice
        cleanupRelay = settings.cleanupRelay
        displayedCleanupRelay = model.displayedCleanupRelay
        services = TextCleaner.services(speech)
        primary = TextCleaner.services(calm).first
        automatic = TextCleaner.services(automaticRequest).first
        chosenCleanupKeyMissing = settings.cleanupChoice.providerName != nil && speech.chosenCleanupKey == nil
        relayCleanupKeyMissing = settings.cleanupRelay.providerName != nil && speech.relayCleanupKey == nil
        learnCorrections = settings.learnCorrections
    }

    var voiceReady: Bool { active.contains(voice.provider.rawValue) }

    /// Au moins une clé enregistrée (le modèle local n'en est pas une).
    var hasAnyKey: Bool { !stored.isDisjoint(with: APIKeys.accounts) }

    var jevActive: Bool { active.contains(APIKeys.typesafe) }
    var jevStored: Bool { stored.contains(APIKeys.typesafe) }

    /// Clés qui manquent ou sont coupées alors qu'un choix en a besoin, une par clé, dans l'ordre d'une dictée.
    var gaps: [KeyGap] {
        var gaps: [KeyGap] = []
        func add(_ account: String, _ role: KeyGap.Role) {
            if let index = gaps.firstIndex(where: { $0.account == account }) {
                if !gaps[index].roles.contains(role) { gaps[index].roles.append(role) }
            } else {
                gaps.append(KeyGap(account: account, stored: stored.contains(account), roles: [role]))
            }
        }
        if !voiceReady { add(voice.provider.rawValue, .voice) }
        if let relay = chosenVoiceRelay, !active.contains(relay.provider.rawValue) { add(relay.provider.rawValue, .voiceRelay) }
        if cleanupEnabled, chosenCleanupKeyMissing, let account = cleanupChoice.account { add(account, .correction) }
        if cleanupEnabled, relayCleanupKeyMissing, let account = cleanupRelay.account { add(account, .correctionRelay) }
        return gaps
    }

    /// Un relais attend sa clé : les réglages avancés le signalent même repliés.
    var advancedNeedsAttention: Bool {
        gaps.contains { $0.roles.contains(.voiceRelay) || $0.roles.contains(.correctionRelay) }
    }

    /// « Clé xAI coupée » ou « Aucune clé xAI » ; nil si la clé sert.
    func keyWarning(_ account: String) -> String? {
        guard !active.contains(account) else { return nil }
        if account == CleanupModel.localAccount {
            return stored.contains(account) ? String(localized: "Modèle local coupé") : String(localized: "Modèle local non réglé")
        }
        let name = ProviderName.of(account)
        return stored.contains(account) ? String(localized: "Clé \(name) coupée") : String(localized: "Aucune clé \(name)")
    }

    // MARK: Boutons de modèle

    var voiceSummary: ModelSummary {
        ModelSummary(account: voice.provider.rawValue, title: voice.displayName,
                     caption: String(localized: "\(voice.provider.displayName) · \(MoneyFormat.price(voice.streamingUSDPerHour))/h"),
                     warning: keyWarning(voice.provider.rawValue))
    }

    var correctionSummary: ModelSummary {
        guard cleanupEnabled else {
            return ModelSummary(account: nil, title: String(localized: "Coupée"),
                                caption: String(localized: "Texte collé tel que transcrit"))
        }
        if cleanupChoice == .automatic {
            guard let first = services.first else {
                return ModelSummary(account: nil, title: String(localized: "Automatique"),
                                    caption: String(localized: "Aucun modèle disponible"),
                                    warning: String(localized: "Aucune clé pour corriger"))
            }
            return ModelSummary(account: first.account, title: String(localized: "Automatique"), caption: first.readable)
        }
        guard let account = cleanupChoice.account, let id = cleanupChoice.model else {
            return ModelSummary(account: nil, title: String(localized: "Automatique"), caption: "")
        }
        return ModelSummary(account: account, title: CleanupModelText.name(id),
                            caption: "\(ProviderName.of(account)) · \(CleanupModelText.price(id, account: account))",
                            warning: chosenCleanupKeyMissing ? keyWarning(account) : nil)
    }

    var voiceRelaySummary: ModelSummary {
        guard let relay = voiceRelay else {
            return ModelSummary(account: nil, title: String(localized: "Aucun relais"), caption: String(localized: "Rien ne prend la main"))
        }
        return ModelSummary(account: relay.provider.rawValue, title: relay.displayName,
                            caption: String(localized: "\(relay.provider.displayName) · \(MoneyFormat.price(relay.streamingUSDPerHour))/h"),
                            warning: keyWarning(relay.provider.rawValue))
    }

    var correctionRelaySummary: ModelSummary {
        guard let account = displayedCleanupRelay.account, let id = displayedCleanupRelay.model else {
            return ModelSummary(account: nil, title: String(localized: "Aucun relais"), caption: String(localized: "Rien ne prend la main"))
        }
        return ModelSummary(account: account, title: CleanupModelText.name(id),
                            caption: "\(ProviderName.of(account)) · \(CleanupModelText.price(id, account: account))",
                            warning: relayCleanupKeyMissing ? keyWarning(account) : nil)
    }

    // MARK: Lignes des réglages avancés

    /// Ce que fait la vérification sur l'enregistrement complet, avec le modèle et son prix.
    var verificationSummary: String {
        guard verifyWithFile else { return String(localized: "Coupée : seul le texte reçu en direct compte.") }
        guard voiceReady else { return String(localized: "Suit la voix, qui n'a pas de clé active.") }
        return String(localized: "Même fournisseur que la voix : \(voice.provider.displayName) \(voice.fileDisplayName) · \(MoneyFormat.price(voice.batchUSDPerHour))/h")
    }

    /// Qui décide qu'un mot corrigé entre au dictionnaire, maintenant.
    var learningSummary: String {
        guard learnCorrections else { return String(localized: "Coupé : aucun mot n'est appris de tes corrections.") }
        if jevActive {
            return services.first.map { String(localized: "Jev note chaque mot ; en cas de doute, \($0.readable) tranche.") }
                ?? String(localized: "Jev note chaque mot, seul : aucun modèle de correction actif.")
        }
        guard let first = services.first else { return String(localized: "Aucun modèle actif : aucun mot n'est appris.") }
        return String(localized: "Maintenant : \(first.readable), comme la correction.")
    }

    /// « Ta voix passe par xAI, DeepSeek corrige le texte. »
    var readySentence: String {
        let voiceName = voice.provider.displayName
        guard cleanupEnabled, let first = services.first else {
            return String(localized: "Ta voix passe par \(voiceName), sans correction.")
        }
        if first.account == CleanupModel.localAccount {
            return String(localized: "Ta voix passe par \(voiceName), le modèle local de ton Mac corrige le texte.")
        }
        return String(localized: "Ta voix passe par \(voiceName), \(first.provider) corrige le texte.")
    }
}

// MARK: - Vue d'ensemble

/// En tête de Fournisseurs : ce qui marche, ce qui manque, et le bouton qui règle. Les alertes qui ont la même cause
/// n'en font qu'une : sans aucune clé, un seul message ; une clé coupée qui sert à trois étapes, une seule ligne.
struct ProvidersOverview: Equatable {
    enum Tone: Equatable {
        /// Tout sert comme choisi.
        case ready
        /// Un service est en pause : son relais prend la main.
        case relay
        /// On dicte, mais un choix ne sert pas.
        case attention
        /// Pas de dictée possible.
        case blocked
    }

    enum Action: Hashable {
        /// Relire les clés (coffre injoignable, source en lecture seule).
        case reload
        /// Ouvrir la saisie d'une clé, pour ce fournisseur s'il est connu.
        case addKey(String?)
        /// Rallumer une clé coupée.
        case enableKey(String)
        /// Dicter avec l'autre fournisseur, dont la clé est prête.
        case useVoice(ProviderID)
        /// Contrôler tout de suite les services en pause.
        case retryServices
        /// Ouvrir le sélecteur de ce choix.
        case choose(ModelPickerKind)
    }

    var tone: Tone
    var title: String
    var detail: String
    /// Le premier bouton est l'action principale.
    var actions: [Action]
    /// Autres clés à régler, une ligne chacune.
    var rows: [KeyGap] = []
    /// Services en pause, quand le titre parle d'autre chose.
    var paused: [String] = []

    static func make(_ snapshot: ProvidersSnapshot, paused: [String]) -> ProvidersOverview {
        if !snapshot.keysReachable {
            return ProvidersOverview(
                tone: .blocked,
                title: snapshot.keyStore == .vault ? String(localized: "Coffre de secrets injoignable") : String(localized: "Clés illisibles sur ce Mac"),
                detail: String(localized: "Wispad ne peut pas lire tes clés pour l'instant. Réessaie dans un moment."),
                actions: [.reload])
        }
        if !snapshot.hasAnyKey {
            return ProvidersOverview(
                tone: .blocked,
                title: String(localized: "Ajoute une clé pour dicter"),
                detail: snapshot.readOnlyKeys
                    ? String(localized: "Ajoute une clé xAI ou OpenAI dans ta source de clés, puis recharge.")
                    : String(localized: "Une clé xAI ou OpenAI suffit pour commencer."),
                actions: [snapshot.readOnlyKeys ? .reload : .addKey(nil)])
        }
        let gaps = snapshot.gaps
        if !snapshot.voiceReady {
            return voiceBlocked(snapshot, gaps: gaps, paused: paused)
        }
        if gaps.count == 1, let gap = gaps.first {
            return single(gap, snapshot, paused: paused)
        }
        if gaps.count > 1 {
            return ProvidersOverview(
                tone: .attention,
                title: String(localized: "\(gaps.count) réglages attendent une clé"),
                detail: String(localized: "Tu peux dicter. Ces choix ne servent pas tant que leur clé manque ou est coupée."),
                actions: [], rows: gaps, paused: paused)
        }
        if !paused.isEmpty {
            return ProvidersOverview(
                tone: .relay,
                title: paused.count == 1 ? String(localized: "Un service est en pause") : String(localized: "\(paused.count) services sont en pause"),
                detail: paused.joined(separator: "\n"),
                actions: [.retryServices])
        }
        return ProvidersOverview(tone: .ready, title: String(localized: "Tout est prêt"), detail: snapshot.readySentence, actions: [])
    }

    /// La voix n'a pas de clé active : rien d'autre ne compte avant.
    private static func voiceBlocked(_ snapshot: ProvidersSnapshot, gaps: [KeyGap], paused: [String]) -> ProvidersOverview {
        let provider = snapshot.voice.provider
        let name = provider.displayName
        let other = provider.other
        let off = snapshot.stored.contains(provider.rawValue)
        let alternative = snapshot.active.contains(other.rawValue)
        let detail: String
        switch (off, alternative) {
        case (true, true): detail = String(localized: "Rallume-la, ou dicte avec \(other.displayName), dont la clé est prête.")
        case (true, false): detail = String(localized: "Rallume-la pour dicter.")
        case (false, true): detail = String(localized: "Ajoute-la, ou dicte avec \(other.displayName), dont la clé est prête.")
        case (false, false): detail = String(localized: "Une clé \(name) ou \(other.displayName) suffit pour dicter.")
        }
        let fix: Action = off ? .enableKey(provider.rawValue) : snapshot.readOnlyKeys ? .reload : .addKey(provider.rawValue)
        return ProvidersOverview(
            tone: .blocked,
            title: off ? String(localized: "Ta clé \(name) est coupée") : String(localized: "Ajoute ta clé \(name) pour dicter"),
            detail: detail,
            actions: [fix] + (alternative ? [.useVoice(other)] : []),
            rows: gaps.filter { $0.account != provider.rawValue },
            paused: paused)
    }

    /// Une seule clé à régler : le titre dit ce qui ne sert pas, le détail pourquoi et quoi faire.
    private static func single(_ gap: KeyGap, _ snapshot: ProvidersSnapshot, paused: [String]) -> ProvidersOverview {
        let name = ProviderName.of(gap.account)
        let fix: Action = gap.stored ? .enableKey(gap.account) : snapshot.readOnlyKeys ? .reload : .addKey(gap.account)
        if gap.roles.contains(.correction) {
            let instead = snapshot.services.first?.readable ?? ""
            return ProvidersOverview(
                tone: .attention,
                title: String(localized: "La correction ne passe pas par \(name)"),
                detail: gap.stored
                    ? String(localized: "Sa clé est coupée : \(instead) corrige en attendant.")
                    : String(localized: "Sa clé manque : \(instead) corrige en attendant."),
                actions: [fix, .choose(.correction)], paused: paused)
        }
        if gap.roles == [.voiceRelay] {
            let voice = snapshot.voice.provider.displayName
            return ProvidersOverview(
                tone: .attention,
                title: String(localized: "Le relais de la voix ne servira pas"),
                detail: gap.stored
                    ? String(localized: "La clé \(name) est coupée : si \(voice) ne répond pas, rien ne prend la main.")
                    : String(localized: "Aucune clé \(name) : si \(voice) ne répond pas, rien ne prend la main."),
                actions: [fix, .choose(.voiceRelay)], paused: paused)
        }
        if gap.roles == [.correctionRelay] {
            let primary = snapshot.primary?.provider ?? ""
            return ProvidersOverview(
                tone: .attention,
                title: String(localized: "Le relais de la correction ne servira pas"),
                detail: gap.stored
                    ? String(localized: "La clé \(name) est coupée : si \(primary) ne répond pas, le texte est collé sans correction.")
                    : String(localized: "Aucune clé \(name) : si \(primary) ne répond pas, le texte est collé sans correction."),
                actions: [fix, .choose(.correctionRelay)], paused: paused)
        }
        return ProvidersOverview(
            tone: .attention,
            title: String(localized: "Les relais ne serviront pas"),
            detail: gap.stored
                ? String(localized: "La clé \(name) est coupée : en cas de panne, rien ne prend la main.")
                : String(localized: "Aucune clé \(name) : en cas de panne, rien ne prend la main."),
            actions: [fix], paused: paused)
    }
}
