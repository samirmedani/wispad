import AppKit
import SwiftUI
import WispadCore

/// Fenêtre de mise à jour : la version disponible et les notes de chaque version à rattraper, en rubriques claires,
/// ce que fait le clic, puis l'installation en quatre étapes. En cas d'échec, la raison et la page de la release.
/// Pour la version installée (« Nouveautés de cette version »), les mêmes notes, sans installation.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let release: ReleaseInfo
    var status = BuildStatus.shared
    /// Versions présentées, la plus récente en premier : d'abord la seule disponible, puis aussi celles sautées.
    @State private var releases: [ReleaseInfo]
    /// Lu à l'ouverture : ce qui empêche l'installation ici ; la page de la release s'ouvre alors à la place.
    @State private var obstacle: UpdateInstallObstacle? = nil
    /// Aperçu hors écran : versions fournies, rien n'est demandé à GitHub.
    private let fixedReleases: Bool

    init(release: ReleaseInfo, releases: [ReleaseInfo]? = nil) {
        self.release = release
        _releases = State(initialValue: releases ?? [release])
        fixedReleases = releases != nil
    }

    private var current: SemanticVersion? { status.version.flatMap(SemanticVersion.init) }
    /// Version déjà installée : ses nouveautés, sans bouton d'installation.
    private var installed: Bool { current.map { release.version <= $0 } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let headline = ReleaseNotes.digest(release.notes).headline {
                        Text(ReleaseText.inline(headline))
                            .font(.system(size: 17, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(releases) { item in
                        ReleaseCard(release: item, showsHeadline: item.version != release.version)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 600, height: 600)
        // Aperçu hors écran (versions fournies) : la fenêtre d'une version publiée, même depuis une version de développement.
        .onAppear { obstacle = installed || fixedReleases ? nil : model.updater.obstacle(for: release, kind: status.kind) }
        .task { await loadMissedVersions() }
    }

    /// Notes des versions sautées entre la version installée et celle-ci ; sans réponse de GitHub, celle-ci seule.
    private func loadMissedVersions() async {
        guard !fixedReleases, !installed, let current, let all = await BuildStatus.fetchReleaseHistory() else { return }
        let missed = ReleaseCheck.missed(all, after: current, upTo: release)
        guard missed.count > 1 else { return }
        withAnimation(Theme.spring) { releases = missed }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Wispad \(release.version.description)")
                    .font(.system(size: 22, weight: .bold))
                HStack(spacing: 8) {
                    StatusChip(text: installed ? String(localized: "Installée") : String(localized: "Nouvelle version"),
                               tint: installed ? .green : Theme.brand)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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

    private var subtitle: String {
        if installed {
            guard let date = release.publishedAt else { return String(localized: "Ta version actuelle") }
            return String(localized: "Publiée le \(date.formatted(.dateTime.day().month(.wide)))")
        }
        let version = status.version ?? "—"
        return releases.count > 1
            ? String(localized: "Tu as la \(version) · \(releases.count) versions à rattraper")
            : String(localized: "Tu as la \(version)")
    }

    @ViewBuilder private var footer: some View {
        let updater = model.updater
        if installed {
            HStack(spacing: 10) {
                Button("Voir sur GitHub") { NSWorkspace.shared.open(release.pageURL) }
                    .hoverFeedback()
                Spacer()
                Button("Fermer") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .hoverFeedback()
            }
        } else {
            switch updater.phase {
            case .idle:
                idleFooter
            case .failed(let failure):
                failureFooter(failure)
            case .downloading, .verifying, .waitingForDictation, .installing, .relaunching:
                progressFooter(updater)
            }
        }
    }

    private var idleFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let obstacle {
                Label(obstacle.note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label {
                    Text(installExplanation)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
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

    /// Ce que fait « Mettre à jour », en une phrase.
    private var installExplanation: String {
        if let bytes = release.diskImage?.size {
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String(localized: "En un clic : Wispad télécharge cette version (\(size)), vérifie qu'elle vient bien de son développeur, puis redémarre. Tes réglages, tes clés et ton historique restent.")
        }
        return String(localized: "En un clic : Wispad télécharge cette version, vérifie qu'elle vient bien de son développeur, puis redémarre. Tes réglages, tes clés et ton historique restent.")
    }

    private func progressFooter(_ updater: UpdateInstaller) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            UpdateSteps(current: updater.phase.step)
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


/// Une version : son numéro et sa date, son accroche (sauf pour la plus récente, dont l'accroche est en titre), puis
/// ses rubriques.
struct ReleaseCard: View {
    let release: ReleaseInfo
    var showsHeadline: Bool

    var body: some View {
        let digest = ReleaseNotes.digest(release.notes)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(verbatim: release.version.description)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.brand.opacity(0.13)))
                if let date = release.publishedAt {
                    Text(date, format: .dateTime.day().month(.wide))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if showsHeadline, let headline = digest.headline {
                Text(ReleaseText.inline(headline))
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if digest.isEmpty {
                Text("Pas de notes pour cette version.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(digest.sections.enumerated()), id: \.offset) { _, section in
                ReleaseSectionView(section: section)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.subtleFill))
    }
}

/// Une rubrique (Nouveau, Corrigé, Amélioré) : son nom en couleur, puis chaque point, titre en gras et détail dessous.
struct ReleaseSectionView: View {
    let section: ReleaseDigest.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = section.kind.title {
                Label(title, systemImage: section.kind.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(section.kind.tint)
            }
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(section.kind.tint.opacity(0.85))
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = item.title {
                            Text(ReleaseText.inline(title))
                                .font(.system(size: 13.5, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(ReleaseText.inline(item.text))
                            .font(.system(size: 13))
                            .foregroundStyle(item.title == nil ? Color.primary : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

extension ReleaseDigest.Kind {
    /// Nom de la rubrique ; nil pour les points d'avant toute rubrique.
    var title: String? {
        switch self {
        case .new: return String(localized: "Nouveau")
        case .fixed: return String(localized: "Corrigé")
        case .improved: return String(localized: "Amélioré")
        case .other(let title): return title.isEmpty ? nil : title
        }
    }

    var symbol: String {
        switch self {
        case .new: return "sparkles"
        case .fixed: return "wrench.and.screwdriver.fill"
        case .improved: return "wand.and.stars"
        case .other: return "circle.grid.2x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .new: return Theme.brand
        case .fixed: return .orange
        case .improved: return .blue
        case .other: return .secondary
        }
    }
}

/// Avancement de l'installation : téléchargement, vérification, installation, redémarrage. Les étapes faites sont
/// cochées, celle en cours porte la couleur de l'app.
struct UpdateSteps: View {
    var current: Int

    private static let titles = [String(localized: "Téléchargement"), String(localized: "Vérification"),
                                 String(localized: "Installation"), String(localized: "Redémarrage")]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Self.titles.indices, id: \.self) { index in
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(index < current ? Color.green : index == current ? Theme.brand : Theme.card)
                            .overlay(Circle().strokeBorder(index > current ? Theme.cardBorder : .clear, lineWidth: 1.5))
                            .frame(width: 22, height: 22)
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text(verbatim: String(index + 1))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(index == current ? Color.white : Color.secondary)
                        }
                    }
                    Text(Self.titles[index])
                        .font(.caption)
                        .foregroundStyle(index <= current ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(alignment: .top) {
            GeometryReader { proxy in
                let inset = proxy.size.width / 8
                let span = proxy.size.width - 2 * inset
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardBorder)
                    Capsule().fill(Color.green).frame(width: span * CGFloat(min(current, 3)) / 3)
                }
                .frame(width: span, height: 2)
                .offset(x: inset, y: 10)
            }
        }
        .animation(Theme.spring, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Étape \(current + 1) sur 4 : \(Self.titles[min(current, 3)])"))
    }
}

/// Texte des notes de version : gras, italique, liens et `code` dans la ligne ; le texte brut si le markdown est illisible.
enum ReleaseText {
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
    /// Étape de l'installation, de 0 (téléchargement) à 3 (redémarrage).
    var step: Int {
        switch self {
        case .idle, .failed, .downloading: return 0
        case .verifying: return 1
        case .waitingForDictation, .installing: return 2
        case .relaunching: return 3
        }
    }

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
        case .busy:
            return String(localized: "Un autre Wispad ouvert installe déjà une mise à jour : réessaie quand il aura fini.")
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
