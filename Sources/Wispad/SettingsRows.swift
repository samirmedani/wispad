import SwiftUI
import WispadCore

/// Textes d'un réglage : libellé, explication d'une ligne en langage simple, et détails (fournisseurs, coûts,
/// délais, données envoyées) qui ne s'affichent que dans le popover « i » de sa rangée.
struct SettingText: Equatable {
    var title: String
    var summary: String?
    var details: [String] = []
}

/// Textes de l'écran Réglages, à part des vues pour être testés. Règle : le résumé tient sur une ligne et ne porte
/// aucun détail technique ; montants, modèles, délais et données envoyées vont dans `details`.
enum SettingsPresentation {
    // MARK: Raccourci

    static let dictationShortcut = SettingText(
        title: String(localized: "Raccourci de dictée"),
        summary: String(localized: "Maintiens pour dicter, appuie deux fois pour les mains libres."),
        details: [
            String(localized: "Maintien : la dictée dure tant que la touche est tenue."),
            String(localized: "Double appui rapide : mains libres ; un nouvel appui l'arrête."),
            String(localized: "Appui simple au repos : rien ne se passe, ni micro ni bulle."),
            String(localized: "Échap annule l'écoute en cours sans atteindre l'app."),
            String(localized: "Une nouvelle dictée peut commencer pendant que la précédente se termine.")
        ]
    )

    static let pasteLast = SettingText(
        title: String(localized: "Coller la dernière dictée"),
        summary: String(localized: "Remet au curseur une dictée qui n'a pas pu être écrite."),
        details: [
            String(localized: "Colle la dernière dictée qui n'a pas pu être écrite, sinon la dernière dictée."),
            String(localized: "Sans champ où écrire, le texte est copié et la bulle propose Copier.")
        ]
    )

    // MARK: Transcription

    static let language = SettingText(
        title: String(localized: "Langue"),
        summary: String(localized: "Langue de tes dictées ; « Automatique » la devine à chaque fois.")
    )

    static let verifyWithFile = SettingText(
        title: String(localized: "Vérifier chaque dictée sur l'enregistrement complet"),
        summary: String(localized: "Plus fiable sur la fin des phrases et les mots techniques."),
        details: [
            String(localized: "À la fin de la dictée, l'enregistrement complet est transcrit une seconde fois et comparé au texte reçu en direct."),
            String(localized: "Une transcription de plus par dictée, environ 0,0005 $."),
            String(localized: "Si cette vérification échoue ou tarde, le texte reçu en direct est gardé.")
        ]
    )

    // MARK: Correction

    /// Correction réellement faite, d'après les clés : services dans l'ordre, attente maximale, repli.
    static func cleanup(enabled: Bool, structure: Bool, steps: [String], maxSeconds: Double, hasCleanupKey: Bool) -> SettingText {
        let fallback = structure
            ? String(localized: "le texte transcrit est utilisé avec les seules commandes explicites de mise en page")
            : String(localized: "le texte transcrit est inséré tel quel")
        var details: [String]
        if !enabled {
            details = [String(localized: "Correction désactivée : \(fallback).")]
        } else if steps.isEmpty {
            details = [String(localized: "Aucune clé de correction : \(fallback).")]
        } else {
            let seconds = maxSeconds.formatted(.number.precision(.fractionLength(0...1)).locale(appLocale))
            let order = steps.count == 1
                ? String(localized: "La correction passe par \(steps[0]).")
                : String(localized: "La correction passe par \(steps[0]), puis \(steps[1]) s'il ne répond pas.")
            details = [order, String(localized: "Au-delà d'environ \(seconds) s (un peu plus pour une longue dictée), \(fallback).")]
            if !hasCleanupKey {
                details.append(String(localized: "Ajoute une clé DeepSeek pour une correction moins chère."))
            }
        }
        details.append(String(localized: "Seul le texte part chez le service de correction, jamais l'audio."))
        return SettingText(
            title: String(localized: "Corriger le texte avant insertion"),
            summary: String(localized: "Retire les hésitations et les faux départs, écrit les nombres en chiffres."),
            details: details
        )
    }

    /// `smart` : la correction est active et un service est configuré, la mise en forme se fait sans commande.
    static func structure(smart: Bool) -> SettingText {
        SettingText(
            title: String(localized: "Structurer les listes et paragraphes"),
            summary: String(localized: "Met en forme les énumérations et les changements d'idée."),
            details: [smart
                ? String(localized: "Tu peux aussi dire « première puce », « deuxième puce » ou « nouveau paragraphe ».")
                : String(localized: "Les commandes explicites « première puce », « deuxième puce » et « nouveau paragraphe » fonctionnent localement. Pour structurer une dictée naturelle, active la correction avec un fournisseur configuré.")]
        )
    }

    static let selectionCommands = SettingText(
        title: String(localized: "Réécrire la sélection sur consigne"),
        summary: String(localized: "Avec du texte sélectionné, commence par « reformule » ou « traduis »."),
        details: [
            String(localized: "Exemples : « reformule plus poliment », « traduis en anglais », « rends-le plus court »."),
            String(localized: "La sélection est réécrite par le service de correction ; s'il ne répond pas, elle reste intacte.")
        ]
    )

    static let toneTitle = String(localized: "Ton selon l'app")
    static let toneSummary = String(localized: "Change le registre (tournures familières, ponctuation), jamais les mots ni le sens.")

    // MARK: Mise en forme

    static let formattingTitle = String(localized: "Mise en forme")
    static let formattingSummary = String(localized: "Dates, heures, nombres, montants et unités écrits par la correction.")

    static let dateOrder = SettingText(
        title: String(localized: "Dates"),
        summary: String(localized: "Ordre du jour, du mois et de l'année."),
        details: [
            String(localized: "Une date dite s'écrit dans ce format quand le contexte la rend évidente : « le vingt-quatre octobre deux mille vingt-six » devient « 24/10/2026 »."),
            String(localized: "Sans année dite, la date reste sans année : « le trois novembre » devient « 03/11 ». Un jour seul, comme « mardi », reste en lettres."),
            String(localized: "Une date déjà écrite en chiffres prend aussi ce format, même si le service de correction l'a écrite autrement.")
        ]
    )

    static let dateSeparator = SettingText(
        title: String(localized: "Séparateur"),
        summary: String(localized: "Signe entre le jour, le mois et l'année.")
    )

    static let dateYear = SettingText(
        title: String(localized: "Année"),
        summary: String(localized: "Année complète, ou ses deux derniers chiffres seulement.")
    )

    static let leadingZero = SettingText(
        title: String(localized: "Zéro initial"),
        summary: String(localized: "Jour et mois toujours sur deux chiffres."),
        details: [String(localized: "Activé : « 03/11 ». Désactivé : « 3/11 ».")]
    )

    static let monthInWords = SettingText(
        title: String(localized: "Garder les dates en toutes lettres"),
        summary: String(localized: "Mois en lettres, jour et année en chiffres."),
        details: [
            String(localized: "« 24 octobre 2026 » plutôt que « 24/10/2026 », « 3 novembre » plutôt que « 03/11 »."),
            String(localized: "En anglais, l'ordre choisi décide entre « October 24, 2026 » et « 24 October 2026 ».")
        ]
    )

    static let clock = SettingText(
        title: String(localized: "Heures"),
        summary: String(localized: "Selon la langue : sur vingt-quatre heures en français, AM/PM en anglais."),
        details: [
            String(localized: "L'heure d'un rendez-vous s'écrit dans ce format : « à quatorze heures trente » devient « à 14h30 », ou « à 2:30 PM » sur 12 h."),
            String(localized: "Une durée reste une durée : « deux heures de route » devient « 2 heures de route »."),
            String(localized: "Sur 12 h, une heure déjà en chiffres sans matin ni soir (« à 9 h ») reste telle quelle : elle pourrait être l'une ou l'autre.")
        ]
    )

    static let timeStyle = SettingText(
        title: String(localized: "Écriture sur 24 h"),
        summary: String(localized: "Typographie française par défaut ; l'anglais écrit toujours avec deux-points.")
    )

    static let datePreview = SettingText(
        title: String(localized: "Aperçu"),
        summary: String(localized: "Une date, une date sans année et une heure, telles qu'elles seront écrites.")
    )

    static let numberStyle = SettingText(
        title: String(localized: "Petits nombres"),
        summary: String(localized: "En lettres quand c'est plus naturel, ou toujours en chiffres."),
        details: [
            String(localized: "Selon le contexte : « les deux premières barres », « trois fois », « attends cinq minutes », mais « 5 secondes de latence », « 16 Go », « 12 serveurs » ou « entre 8 et 12 personnes »."),
            String(localized: "En chiffres : tout nombre qui compte s'écrit en chiffres, « les 2 premières barres », « 3 fois »."),
            String(localized: "Montants, mesures, dates et heures restent toujours en chiffres.")
        ]
    )

    static let amounts = SettingText(
        title: String(localized: "Montants et unités"),
        summary: String(localized: "Avec leur symbole, ou en toutes lettres."),
        details: [
            String(localized: "Symboles : « vingt-cinq euros » devient « 25 € », « cinq kilomètres » devient « 5 km », « quinze pour cent » devient « 15 % »."),
            String(localized: "En toutes lettres : « 25 euros », « 5 kilomètres ». Le pourcentage garde toujours « % »."),
            String(localized: "Un montant ou une mesure déjà en chiffres prend aussi ce format. Années, codes postaux, références et numéros de version ne changent jamais."),
            String(localized: "Les numéros de téléphone français s'écrivent par paires : « 06 12 34 56 78 », « +33 6 12 34 56 78 ».")
        ]
    )

    static let thousands = SettingText(
        title: String(localized: "Milliers"),
        summary: String(localized: "Séparateur des grands nombres."),
        details: [
            String(localized: "Selon la langue : « 12 500 » en français, avec une espace qui ne coupe jamais le nombre en fin de ligne ; « 12,500 » en anglais."),
            String(localized: "Les fiches techniques gardent leurs chiffres collés : « 6000 MHz », « 1024 Go ».")
        ]
    )

    static let numberPreview = SettingText(
        title: String(localized: "Aperçu des nombres"),
        summary: String(localized: "Un montant, un prix, un pourcentage et une distance, tels qu'ils seront écrits.")
    )

    static func label(_ thousands: DictationNumberFormat.Thousands) -> String {
        switch thousands {
        case .byLanguage: return String(localized: "Selon la langue")
        case .space: return String(localized: "Espace")
        case .none: return String(localized: "Aucun")
        }
    }

    /// Exemples rendus par le format lui-même, comme pour les dates.
    static func preview(_ format: DictationNumberFormat, language: DictationLanguage) -> [String] {
        let french = format.samples(english: false).joined(separator: " · ")
        let english = format.samples(english: true).joined(separator: " · ")
        switch language {
        case .french: return [french]
        case .english: return [english]
        case .auto: return [String(localized: "Français : \(french)"), String(localized: "Anglais : \(english)")]
        }
    }

    static func label(_ order: DictationDateFormat.Order) -> String {
        switch order {
        case .dayMonthYear: return String(localized: "JJ/MM/AAAA")
        case .monthDayYear: return String(localized: "MM/JJ/AAAA")
        case .iso: return String(localized: "AAAA-MM-JJ (ISO)")
        }
    }

    static func label(_ separator: DictationDateFormat.Separator) -> String {
        separator == .space ? String(localized: "Espace") : separator.character
    }

    static func label(_ clock: DictationDateFormat.Clock) -> String {
        switch clock {
        case .byLanguage: return String(localized: "Selon la langue")
        case .twentyFourHour: return String(localized: "24 h")
        case .twelveHour: return String(localized: "12 h (AM/PM)")
        }
    }

    /// Exemples rendus par le format lui-même : une ligne pour la langue de dictée, deux en automatique si elles
    /// diffèrent (heures sur 12 h en anglais, noms des mois).
    static func preview(_ format: DictationDateFormat, language: DictationLanguage) -> [String] {
        let french = format.samples(english: false).joined(separator: " · ")
        let english = format.samples(english: true).joined(separator: " · ")
        switch language {
        case .french: return [french]
        case .english: return [english]
        case .auto: return french == english ? [french] : [String(localized: "Français : \(french)"), String(localized: "Anglais : \(english)")]
        }
    }

    // MARK: Confidentialité

    static let sentData = SettingText(
        title: String(localized: "Ce qui est envoyé"),
        summary: String(localized: "L'audio et un peu de contexte, à tes seuls fournisseurs."),
        details: [
            String(localized: "Wispad envoie l'audio et, si disponible, l'application active, la sélection et un court extrait autour du curseur."),
            String(localized: "L'historique et l'audio restent sur ce Mac.")
        ]
    )

    static let windowContext = SettingText(
        title: String(localized: "Comprendre le sujet grâce à la fenêtre active"),
        summary: String(localized: "La correction lit aussi la conversation visible où tu dictes."),
        details: [
            String(localized: "Elle lit la fin de la conversation visible dans la fenêtre où tu dictes (2 000 caractères au plus) et tes dernières dictées dans cette app, pour comprendre le sujet, les noms et les nombres."),
            String(localized: "Ce texte part avec la dictée chez le fournisseur de correction ; il n'est ni enregistré ni journalisé, et n'ajoute jamais un mot que tu n'as pas dit."),
            String(localized: "Demande que la correction soit active.")
        ]
    )

    static let retention = SettingText(
        title: String(localized: "Conservation de l'audio"),
        summary: String(localized: "Combien de temps l'audio des dictées reste sur ce Mac.")
    )

    // MARK: Apprentissage

    static func learning(hasTypeSafeKey: Bool) -> SettingText {
        let judge = hasTypeSafeKey
            ? String(localized: "Jev (TypeSafe) le note d'abord ; en cas de doute, le modèle de correction tranche")
            : String(localized: "le modèle de correction juge s'il mérite le dictionnaire")
        return SettingText(
            title: String(localized: "Apprendre de mes corrections"),
            summary: String(localized: "Ajoute au dictionnaire les noms que tu corriges ou que la correction répare souvent."),
            details: [
                String(localized: "Pendant 30 s après une dictée, si tu corriges un mot mal entendu (« Sidance » → « Seedance »), \(judge) : marques, noms et jargon oui, mots courants et fautes de frappe non."),
                String(localized: "Un nom que la correction répare dans deux dictées (« revenu quatre » → « RevenueCat ») passe par le même juge."),
                String(localized: "Le mot est ajouté, puis la bulle te demande si tu le gardes."),
                String(localized: "Seuls l'extrait dicté et le mot corrigé sont envoyés ; le reste du champ n'est ni enregistré ni envoyé.")
            ]
        )
    }

    // MARK: Micro

    /// `refused` : le traitement n'a pas démarré avec ce micro, les dictées passent par le micro standard.
    /// `otherMicrophone` : un autre micro que celui du système est choisi dans Wispad, sans traitement.
    static func voiceIsolation(refused: Bool = false, otherMicrophone: Bool = false) -> SettingText {
        var details = [
            String(localized: "Utilise le traitement de la voix de macOS, celui des appels FaceTime : bruit de fond et écho réduits, volume de la voix ajusté."),
            String(localized: "Pendant une dictée, Centre de contrôle › Mode micro propose aussi « Isolation de la voix », plus marquée."),
            String(localized: "Wispad le prépare au repos, sans ouvrir le micro : la dictée démarre aussi vite qu'avant."),
            String(localized: "Si ce micro ne le permet pas, Wispad reprend le micro standard.")
        ]
        if otherMicrophone {
            details.insert(String(localized: "Le micro choisi dans Wispad n'est pas celui du système : il reste en micro standard."), at: 0)
        } else if refused {
            details.insert(String(localized: "Indisponible avec ce micro : les dictées passent par le micro standard."), at: 0)
        }
        return SettingText(
            title: String(localized: "Réduire le bruit et l'écho du micro"),
            summary: String(localized: "Utile quand tu parles loin du Mac ou dans une pièce qui résonne."),
            details: details
        )
    }

    // MARK: Général

    static let mute = SettingText(
        title: String(localized: "Couper le son du Mac pendant la dictée"),
        summary: String(localized: "Le son revient dès que tu arrêtes de parler.")
    )

    static let muteMode = SettingText(
        title: String(localized: "Quand couper"),
        summary: String(localized: "« Haut-parleurs seulement » laisse le son d'un casque ou des AirPods.")
    )

    // MARK: Diagnostic

    static let diagnostics = SettingText(
        title: String(localized: "Rapport de diagnostic"),
        summary: String(localized: "Fichier local pour comprendre un problème, sans rien de dicté."),
        details: [
            String(localized: "Rapport JSON : autorisations, état du raccourci et de la bulle, durées, API utilisées et résultats des 50 dernières tentatives."),
            String(localized: "Aucun texte dicté, audio, contexte d'application ni clé. Rien n'est envoyé automatiquement.")
        ]
    )

    // MARK: Aide et retours

    static let helpTitle = String(localized: "Aide et retours")
    static let helpSummary = String(localized: "Sur GitHub : seules les versions de Wispad et de macOS sont préremplies.")

    // MARK: Bulle et messages

    static let placementTitle = String(localized: "Position")
    static let placementSummary = String(localized: "Où la bulle et ses messages apparaissent à l'écran.")

    static let bubbleStyle = SettingText(
        title: String(localized: "Style de la bulle"),
        summary: String(localized: "Pour la bulle de dictée comme pour ses messages ; le spectre garde ses couleurs.")
    )

    static let bubbleSize = SettingText(
        title: String(localized: "Taille de la bulle"),
        summary: String(localized: "Le spectre et ses boutons grandissent avec elle ; les messages gardent leur taille.")
    )

    static let glassAppearance = SettingText(
        title: String(localized: "Apparence du verre"),
        summary: String(localized: "Clair, sombre, ou comme l'app."),
        details: [
            String(localized: "Clair : voile blanc et reflets brillants, symboles foncés. Sombre : verre fumé, symboles clairs."),
            String(localized: "Sur le verre transparent, un fin halo garde le spectre et les symboles lisibles, quel que soit le fond.")
        ]
    )

    static let glassIntensity = SettingText(
        title: String(localized: "Densité du verre"),
        summary: String(localized: "Plus dense, il se lit mieux sur un fond chargé ; à zéro, le verre seul."),
        details: [
            String(localized: "Elle assombrit le verre en apparence sombre, l'éclaircit en apparence claire."),
            String(localized: "Les messages gardent un voile plus dense que la bulle de dictée : leur texte reste lisible.")
        ]
    )

    // MARK: Apparence

    static let appearanceTitle = String(localized: "Apparence")
    static let appearanceSummary = String(localized: "« Système » suit macOS. La bulle garde son style, choisi dans l'onglet Bulle.")

    static let avoidInput = SettingText(
        title: String(localized: "Ne jamais couvrir le champ de saisie"),
        summary: String(localized: "Les messages se placent au-dessus du champ où tu écris."),
        details: [
            String(localized: "Après chaque collage, Wispad repère le champ actif ; pour les apps qui ne le montrent pas (Codex, apps Electron), le bas de la fenêtre."),
            String(localized: "Ce repérage a lieu après l'envoi du texte : il ne retarde ni la bulle ni le collage."),
            String(localized: "La bulle de dictée garde sa place ; seuls les messages se décalent.")
        ]
    )
}

/// Rangée de réglage au style macOS : libellé et explication courte à gauche, bouton « i » puis contrôle à droite.
struct SettingRow<Control: View>: View {
    var text: SettingText
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if !text.details.isEmpty {
                    InfoButton(text: text)
                }
                control
            }
        } label: {
            Text(text.title)
            if let summary = text.summary {
                Text(summary)
            }
        }
    }
}

extension SettingRow where Control == EmptyView {
    init(text: SettingText) {
        self.init(text: text) { EmptyView() }
    }
}

/// Rangée d'un raccourci (dictée, « Coller la dernière dictée ») : libellé et explication à gauche ; à droite, sur
/// la même ligne et centrés verticalement, ⓘ, les touches (ou la consigne pendant l'enregistrement) puis les
/// boutons. Rien ne passe sous le libellé : faute de place, l'explication va à la ligne, puis les boutons deviennent
/// des icônes et enfin les touches ne gardent que leurs symboles. Le popover ⓘ montre les touches sur le schéma.
struct ShortcutRow<Actions: View>: View {
    var text: SettingText
    var keys: [ShortcutKey]
    /// Consigne montrée à la place des touches pendant l'enregistrement.
    var prompt: String?
    /// Info-bulle des touches, ou de la consigne pendant l'enregistrement.
    var keysHelp: String
    /// Raccourci désactivé : touches estompées.
    var dimmed: Bool
    /// Boutons à droite des touches ; `compact` : en icônes, faute de place.
    var actions: (_ compact: Bool) -> Actions

    init(text: SettingText, keys: [ShortcutKey], prompt: String? = nil, keysHelp: String, dimmed: Bool = false,
         @ViewBuilder actions: @escaping (_ compact: Bool) -> Actions) {
        self.text = text
        self.keys = keys
        self.prompt = prompt
        self.keysHelp = keysHelp
        self.dimmed = dimmed
        self.actions = actions
    }

    /// Largeur gardée par le libellé (son titre tient sur une ligne) avant que les boutons, puis les touches, se
    /// réduisent.
    static var labelWidth: CGFloat { 158 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compactButtons: false, compactKeys: false)
            row(compactButtons: true, compactKeys: false)
            row(compactButtons: true, compactKeys: true)
        }
    }

    private func row(compactButtons: Bool, compactKeys: Bool) -> some View {
        HStack(spacing: 12) {
            label
            controls(compactButtons: compactButtons, compactKeys: compactKeys)
                .fixedSize()
        }
    }

    /// Titre et explication ; l'explication passe à la ligne dans la place que laissent les contrôles.
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text.title)
            if let summary = text.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 0, idealWidth: Self.labelWidth, maxWidth: .infinity, alignment: .leading)
    }

    private func controls(compactButtons: Bool, compactKeys: Bool) -> some View {
        HStack(spacing: 7) {
            InfoButton(text: text, keys: keys)
            keyView(compact: compactKeys)
                .help(keysHelp)
            actions(compactButtons)
        }
    }

    @ViewBuilder private func keyView(compact: Bool) -> some View {
        if let prompt {
            ShortcutRecordingField(prompt: prompt)
        } else {
            ShortcutKeyCaps(keys: keys, compact: compact)
                .opacity(dimmed ? 0.45 : 1)
        }
    }
}

/// « Modifier » d'un raccourci, « Annuler » pendant son enregistrement ; en icône quand la place manque.
struct ShortcutEditButton: View {
    var recording: Bool
    var compact: Bool
    var action: () -> Void

    var body: some View {
        let title = recording ? String(localized: "Annuler") : String(localized: "Modifier")
        if compact {
            HoverIconButton(symbol: recording ? "xmark" : "pencil", help: title, action: action)
        } else {
            Button(title, action: action)
                .hoverFeedback()
        }
    }
}

/// Interrupteur de réglage : même rangée, l'interrupteur à droite.
/// `enabled` ne grise que l'interrupteur : les détails restent lisibles.
struct SettingToggle: View {
    var text: SettingText
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        SettingRow(text: text) {
            Toggle(text.title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!enabled)
        }
    }
}

/// « i » : détails d'un réglage dans un popover, à la demande.
struct InfoButton: View {
    var text: SettingText
    var keys: [ShortcutKey] = []
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(String(localized: "En savoir plus"))
        .accessibilityLabel(String(localized: "En savoir plus : \(text.title)"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            InfoPopover(text: text, keys: keys)
        }
    }
}

/// Avec les touches d'un raccourci : touches dessinées et schéma du clavier, sous le titre.
struct InfoPopover: View {
    var text: SettingText
    var keys: [ShortcutKey] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text.title)
                .font(.headline)
            if !keys.isEmpty {
                ShortcutKeyCaps(keys: keys)
                    .padding(.vertical, 2)
                MacKeyboardDiagram(highlighted: Set(keys.map(\.keyCode)), unit: 26)
                    .padding(.bottom, 4)
            }
            ForEach(text.details, id: \.self) { detail in
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: keys.isEmpty ? 340 : 430, alignment: .leading)
    }
}

/// Titre de section avec une explication d'une ligne, pour une liste de réglages qui partagent la même règle.
struct SectionTitle: View {
    var title: String
    var summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(summary)
                .font(.footnote)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}
