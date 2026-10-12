import AppKit
import SwiftUI
import WispadCore

/// Fenêtre de mise à jour : la version disponible, ses notes de version, l'installation en un clic et son avancement.
/// En cas d'échec, la raison et la page de la release.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let release: ReleaseInfo
    var status = BuildStatus.shared
    /// Lu à l'ouverture : ce qui empêche l'installation ici ; la page de la release s'ouvre alors à la place.
    @State private var obstacle: UpdateInstallObstacle? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                ReleaseNotesView(markdown: release.notes)
                    .padding(24)
            }
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 560, height: 520)
        .onAppear { obstacle = model.updater.obstacle(for: release, kind: status.kind) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(DictationCoordinator.updateMessage(release.version))
                    .font(.title2.weight(.bold))
                Text("Tu utilises la version \(status.version).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Fermer", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(HoverButtonStyle(treatment: .icon))
                .help("Fermer")
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
    }

    @ViewBuilder private var footer: some View {
        let updater = model.updater
        switch updater.phase {
        case .idle:
            idleFooter
        case .failed(let failure):
            failureFooter(failure)
        case .downloading, .verifying, .waitingForDictation, .installing, .relaunching:
            progressFooter(updater)
        }
    }

    private var idleFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let obstacle {
                Text(obstacle.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Voir sur GitHub") { NSWorkspace.shared.open(release.pageURL) }
                    .hoverFeedback()
                Spacer()
                Button("Plus tard") { dismiss() }
                    .hoverFeedback()
                Button(obstacle == nil ? String(localized: "Mettre à jour") : String(localized: "Ouvrir la page de la release")) {
                    model.installUpdate(release)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .hoverFeedback()
            }
        }
    }

    private func progressFooter(_ updater: UpdateInstaller) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(updater.phase.detailText)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(let fraction?) = updater.phase {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            Spacer(minLength: 12)
            if updater.canCancel {
                Button("Annuler") { updater.cancel() }
                    .hoverFeedback()
            }
        }
    }

    private func failureFooter(_ failure: UpdateFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Ouvrir la page de la release") { NSWorkspace.shared.open(release.pageURL) }
                    .hoverFeedback()
                Spacer()
                Button("Fermer") { dismiss() }
                    .hoverFeedback()
                Button("Réessayer") { model.installUpdate(release) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .hoverFeedback()
            }
        }
    }
}

/// Notes de version en markdown simple : titres, puces, listes numérotées, paragraphes et code, avec gras, italique,
/// liens et `code` dans la ligne. Le texte reste sélectionnable.
struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        let blocks = ReleaseNotes.blocks(markdown)
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes de version")
                .font(.headline)
            if blocks.isEmpty {
                Text("Pas de notes pour cette version.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: ReleaseNoteBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 2 ? Font.title3.weight(.semibold) : Font.headline)
                .padding(.top, 6)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(verbatim: "•")
                    .foregroundStyle(.secondary)
                Text(Self.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(verbatim: number + ".")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(Self.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(Self.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(verbatim: text)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// Gras, italique, liens et `code` dans la ligne ; le texte brut si le markdown est illisible.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

extension UpdateInstaller.Phase {
    /// Avancement, dans la fenêtre de mise à jour.
    var detailText: String {
        switch self {
        case .idle: return ""
        case .downloading(let fraction):
            guard let fraction else { return String(localized: "Téléchargement…") }
            return String(localized: "Téléchargement… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        case .verifying: return String(localized: "Vérification de la signature…")
        case .waitingForDictation: return String(localized: "Prête : installation dès la fin de la dictée en cours.")
        case .installing: return String(localized: "Installation…")
        case .relaunching: return String(localized: "Relance de Wispad…")
        case .failed(let failure): return failure.message
        }
    }

    /// Avancement en quelques mots, dans la barre latérale ; nil quand « Mettre à jour » est proposé.
    var sidebarText: String? {
        switch self {
        case .idle: return nil
        case .downloading(let fraction):
            guard let fraction else { return String(localized: "Téléchargement…") }
            return String(localized: "Téléchargement… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        case .verifying: return String(localized: "Vérification…")
        case .waitingForDictation: return String(localized: "Après la dictée…")
        case .installing: return String(localized: "Installation…")
        case .relaunching: return String(localized: "Relance…")
        case .failed: return String(localized: "Échec de la mise à jour")
        }
    }
}

extension UpdateFailure {
    /// Message clair de l'échec ; la fenêtre propose aussi la page de la release.
    var message: String {
        switch self {
        case .download:
            return String(localized: "Le téléchargement a échoué. Vérifie ta connexion, puis réessaie.")
        case .corrupted:
            return String(localized: "Le fichier téléchargé est incomplet ou modifié : rien n'a été installé.")
        case .diskImage:
            return String(localized: "Le disque de la mise à jour n'a pas pu être ouvert : rien n'a été installé.")
        case .missingApp:
            return String(localized: "Wispad est introuvable dans le disque de la mise à jour : rien n'a été installé.")
        case .notNewer:
            return String(localized: "Cette version n'est pas plus récente que la tienne : rien n'a été installé.")
        case .signature:
            return String(localized: "La signature de cette version n'est pas celle de Wispad : rien n'a été installé.")
        case .copy:
            return String(localized: "La copie de la nouvelle version a échoué : rien n'a été remplacé.")
        case .replace:
            return String(localized: "Le remplacement de l'app a échoué : ta version actuelle reste en place.")
        case .relaunch:
            return String(localized: "Wispad est à jour mais n'a pas pu se relancer : quitte-le, puis rouvre-le.")
        }
    }
}

extension UpdateInstallObstacle {
    /// Pourquoi la mise à jour passe par la page de la release.
    var note: String {
        switch self {
        case .readOnlyLocation:
            return String(localized: "Wispad ne peut pas se remplacer là où il est installé : la nouvelle version se télécharge depuis la page de la release.")
        case .developmentBuild, .noDiskImage, .unsigned:
            return String(localized: "Cette version s'installe depuis la page de la release.")
        }
    }
}
