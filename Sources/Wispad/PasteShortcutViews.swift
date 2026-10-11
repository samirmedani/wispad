import SwiftUI
import WispadCore

/// Textes de « Coller la dernière dictée » : WispadCore dit pourquoi une combinaison est refusée, l'app l'écrit.
enum PasteShortcutText {
    static func message(for problem: PasteShortcutProblem, shortcut: String) -> String {
        switch problem {
        case .modifierOnly:
            return String(localized: "Ajoute une touche aux modificateurs, par exemple ⌃⌥V.")
        case .functionKey:
            return String(localized: "fn est réservée à la dictée : choisis une combinaison sans fn.")
        case .escape:
            return String(localized: "Échap sert à annuler : choisis une autre touche.")
        case .needsModifier:
            return String(localized: "Ajoute ⌃, ⌥ ou ⌘ : seule, cette touche écrirait un caractère.")
        case .commandOnly:
            return String(localized: "⌘ avec une seule touche sert aux menus des apps : ajoute ⌃ ou ⌥.")
        case .sameAsDictation:
            return String(localized: "\(shortcut) est déjà le raccourci de dictée.")
        case .system:
            return String(localized: "\(shortcut) est déjà pris par macOS (Réglages Système › Clavier › Raccourcis).")
        case .reserved(let use):
            return String(localized: "\(shortcut) est déjà pris : \(useName(use)).")
        }
    }

    static func useName(_ use: PasteShortcutRules.Use) -> String {
        switch use {
        case .paste: return String(localized: "coller")
        case .pastePlain: return String(localized: "coller sans mise en forme")
        case .finderMove: return String(localized: "déplacer dans le Finder")
        case .copy: return String(localized: "copier")
        case .cut: return String(localized: "couper")
        case .undo: return String(localized: "annuler")
        case .selectAll: return String(localized: "tout sélectionner")
        case .quit: return String(localized: "quitter l'app")
        case .closeWindow: return String(localized: "fermer la fenêtre")
        case .hide: return String(localized: "masquer l'app")
        case .minimize: return String(localized: "réduire la fenêtre")
        case .appSwitcher: return String(localized: "changer d'app")
        case .spotlight: return "Spotlight"
        case .inputSource: return String(localized: "changer de source de saisie")
        case .emoji: return String(localized: "emojis et symboles")
        case .screenshot: return String(localized: "capture d'écran")
        case .lockScreen: return String(localized: "verrouiller l'écran")
        case .fullScreen: return String(localized: "plein écran")
        case .forceQuit: return String(localized: "forcer à quitter")
        case .dock: return String(localized: "afficher ou masquer le Dock")
        }
    }

    /// Libellé du raccourci, ou « désactivé ».
    static func label(_ shortcut: PasteShortcut) -> String {
        shortcut.enabled ? KeyLabels.describe(shortcut) : String(localized: "désactivé")
    }
}

/// Réglages › Raccourci : enregistreur de « Coller la dernière dictée ». Clic sur Modifier, puis la combinaison ;
/// Échap annule. « Par défaut » remet ⌃⌥V, l'interrupteur le désactive sans oublier la combinaison.
struct PasteShortcutRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shortcut = model.settings.pasteLastShortcut
        let recording = model.isRecordingPasteShortcut
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(text: SettingsPresentation.pasteLast) {
                HStack(spacing: 10) {
                    KeyCap(label: recording ? "…" : PasteShortcutText.label(shortcut))
                        .opacity(shortcut.enabled || recording ? 1 : 0.5)
                    Button(recording ? String(localized: "Tape la combinaison… (Échap annule)") : String(localized: "Modifier")) {
                        if recording {
                            model.stopRecordingPasteShortcut()
                        } else {
                            model.startRecordingPasteShortcut()
                        }
                    }
                    .hoverFeedback()
                    Button("Par défaut") { model.resetPasteShortcut() }
                        .disabled(shortcut == .standard && !recording)
                        .hoverFeedback()
                        .help(String(localized: "Revenir à \(KeyLabels.describe(PasteShortcut.standard))"))
                    Toggle("Activé", isOn: Binding(
                        get: { shortcut.enabled },
                        set: { model.setPasteShortcutEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(String(localized: "Activer ou désactiver ce raccourci"))
                }
            }
            if let problem = model.pasteShortcutProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { model.stopRecordingPasteShortcut() }
    }
}
