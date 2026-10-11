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
            summary: String(localized: "Ajoute au dictionnaire les noms que tu corriges après une dictée."),
            details: [
                String(localized: "Pendant 30 s après une dictée, si tu corriges un mot mal entendu (« Sidance » → « Seedance »), \(judge) : marques, noms et jargon oui, mots courants et fautes de frappe non."),
                String(localized: "Le mot est ajouté, puis la bulle te demande si tu le gardes."),
                String(localized: "Seuls l'extrait dicté et le mot corrigé sont envoyés ; le reste du champ n'est ni enregistré ni envoyé.")
            ]
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
}

/// Rangée de réglage au style macOS : libellé et explication courte à gauche, bouton « i » puis contrôle à droite.
struct SettingRow<Control: View>: View {
    var text: SettingText
    /// Touches d'un raccourci : son popover les montre sur un schéma du clavier.
    var keys: [ShortcutKey] = []
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if !text.details.isEmpty {
                    InfoButton(text: text, keys: keys)
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
                ShortcutKeyCaps(keys: keys, size: .medium)
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
