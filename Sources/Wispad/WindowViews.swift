import SwiftUI
import AppKit
import WispadCore

extension AppSection {
    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .usage: return "chart.bar.xaxis"
        case .dictionary: return "character.book.closed"
        case .providers: return "key.horizontal"
        case .settings: return "gearshape"
        }
    }
}

extension AppModel {
    func records(in period: StatsPeriod) -> [DictationRecord] {
        guard let start = period.startDate(now: Date()) else { return history }
        return history.filter { $0.createdAt >= start }
    }

    var missingPermissions: Bool {
        microphoneStatus != .authorized || !accessibilityTrusted || !inputMonitoringTrusted
    }
}

/// Dates et nombres des écrans : langue et région de l'utilisateur.
let appLocale = Locale.autoupdatingCurrent

// MARK: - Fenêtre

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion

    var body: some View {
        if let onboarding = model.onboarding {
            OnboardingView(controller: onboarding)
                .frame(minWidth: 820, minHeight: 540)
                .tint(Theme.brand)
        } else {
            main
        }
    }

    private var main: some View {
        HStack(spacing: 0) {
            Sidebar()
                .animation(reduceMotion ? nil : Theme.quick, value: model.selectedSection)
            Rectangle()
                .fill(Theme.cardBorder)
                .frame(width: 1)
                .ignoresSafeArea()
            ZStack {
                Theme.canvas.ignoresSafeArea()
                SectionScreen(section: model.selectedSection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottom) { BannerToast() }
        }
        .frame(minWidth: 820, minHeight: 540)
        .tint(Theme.brand)
        // Alerte de la barre latérale : relue hors du fil principal, qui dessine la fenêtre qui s'ouvre.
        .onAppear { model.refreshPermissionsInBackground() }
        .sheet(item: Binding(get: { model.updateSheet }, set: { model.updateSheet = $0 }),
               onDismiss: { model.updater.dismissFailure() }) { release in
            UpdateSheet(release: release)
                .environment(model)
                .tint(Theme.brand)
        }
    }
}

struct SectionScreen: View {
    var section: AppSection

    var body: some View {
        switch section {
        case .home: HomeView()
        case .history: HistoryView()
        case .usage: UsageView()
        case .dictionary: DictionaryView()
        case .providers: ProvidersView()
        case .settings: SettingsView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandHeader()
                .padding(.horizontal, 8)
                .padding(.top, 48)
                .padding(.bottom, 20)
            VStack(spacing: 2) {
                ForEach(AppSection.allCases) { section in
                    SidebarRow(
                        section: section,
                        selected: model.selectedSection == section,
                        alert: section == .settings && model.missingPermissions,
                        namespace: selection
                    ) {
                        model.selectedSection = section
                    }
                    .help("\(section.title) (⌘\((AppSection.allCases.firstIndex(of: section) ?? 0) + 1))")
                }
            }
            Spacer(minLength: 16)
            ProjectFooter()
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            ShortcutCard()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: Theme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct SidebarRow: View {
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @Environment(\.interactionPreviewHover) private var previewHover
    @Environment(\.isEnabled) private var isEnabled
    var section: AppSection
    var selected: Bool
    var alert: Bool
    var namespace: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    private var hovered: Bool { isEnabled && (hovering || previewHover) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .symbolVariant(selected ? .fill : .none)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.brand : Color.secondary)
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if alert {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                        .help("Une autorisation manque")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.brand.opacity(0.13))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.subtleFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(treatment: .row))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.hover, value: hovered)
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wispad").font(.system(size: 15, weight: .semibold))
                DictationStatusLine()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Par-dessus la rangée : l'état garde toute la largeur et tient sur une ligne.
        .overlay(alignment: .trailing) { AppearanceButton() }
    }
}

struct DictationStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = self.status
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .animation(Theme.quick, value: status.text)
    }

    private var status: (text: String, color: Color) {
        switch model.coordinator.phase {
        case .idle:
            if let warning = model.setupWarning { return (warning, .orange) }
            return model.relayLines().isEmpty ? (String(localized: "Prêt"), .green) : (String(localized: "Prêt · relais actif"), OverlayStyle.relay)
        case .starting: return (String(localized: "Démarrage…"), .orange)
        case .listening(let mode): return (mode == .toggle ? String(localized: "Mains libres") : String(localized: "À l'écoute"), Theme.brand)
        case .finishing: return (String(localized: "Transcription…"), .blue)
        case .failure: return (String(localized: "Erreur"), .orange)
        }
    }
}

/// Bandeau « étoile » du bas de la barre latérale : proposé tant qu'il n'a pas été cliqué, puis un bref merci.
enum StarBanner: Equatable {
    case offer
    case thanks
    case hidden

    /// Durée du « Merci ! » après le clic, avant la disparition définitive.
    static let thanksDuration: Duration = .milliseconds(1_600)

    static func state(clicked: Bool, thanking: Bool) -> StarBanner {
        if thanking { return .thanks }
        return clicked ? .hidden : .offer
    }
}

/// Bandeau étoile, puis sur une seule ligne la pastille de version (numéro, état, recherche à la main) et les liens du
/// développeur (GitHub, X), au-dessus des raccourcis. Une nouvelle version ajoute « Mettre à jour » dessous.
struct ProjectFooter: View {
    @Environment(AppModel.self) private var model
    var status = BuildStatus.shared
    @State private var thanking = false

    var body: some View {
        let banner = StarBanner.state(clicked: model.settings.githubStarClicked, thanking: thanking)
        VStack(alignment: .leading, spacing: 5) {
            if banner != .hidden {
                StarBannerButton(thanking: banner == .thanks, action: star)
                    .padding(.bottom, 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            HStack(alignment: .center, spacing: 6) {
                VersionChip(status: status)
                Spacer(minLength: 4)
                DeveloperLinks()
            }
            if case .available(let release) = status.display {
                updateControls(release)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.quick, value: status.display)
        .animation(Theme.quick, value: model.updater.phase)
        .animation(Theme.spring, value: banner)
    }

    /// Le clic suffit : la page s'ouvre, le choix est enregistré tout de suite, le merci s'efface ensuite.
    private func star() {
        guard !thanking else { return }
        NSWorkspace.shared.open(BuildFreshnessCheck.repositoryURL)
        thanking = true
        model.settings.githubStarClicked = true
        model.saveSettings()
        Task { @MainActor in
            try? await Task.sleep(for: StarBanner.thanksDuration)
            thanking = false
        }
    }

    /// Release plus récente : « Mettre à jour » sous la ligne de version ; comme l'état, il ouvre la fenêtre de mise à
    /// jour (notes de version), où l'installation se confirme. Pendant l'installation : son avancement, qui rouvre la
    /// fenêtre.
    @ViewBuilder private func updateControls(_ release: ReleaseInfo) -> some View {
        let updater = model.updater
        if let progress = updater.phase.sidebarText {
            Button {
                model.showUpdate(updater.release ?? release)
            } label: {
                HStack(spacing: 6) {
                    if case .failed = updater.phase {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(progress)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(HoverButtonStyle(treatment: .quiet))
            .transition(.opacity)
        } else {
            Button("Mettre à jour") { model.showUpdate(release) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .hoverFeedback()
                .help("Voir les notes de version, puis confirmer")
                .padding(.top, 2)
                .transition(.opacity)
        }
    }
}

/// Version et état, en une pastille sur la ligne des liens du développeur : point de couleur, numéro, état (« À jour »,
/// « → 0.3.4 » pour une nouvelle version, retard d'un build de développement), puis la recherche à la main au bout.
/// Une nouvelle version la colore et la rend cliquable (fenêtre de mise à jour). Trop étroite (grand texte), elle ne
/// garde que le point et le numéro ; l'état reste dans l'infobulle.
struct VersionChip: View {
    @Environment(AppModel.self) private var model
    var status = BuildStatus.shared

    var body: some View {
        let tint = self.tint
        HStack(spacing: 0) {
            content
            if showsCheck {
                Rectangle()
                    .fill(tint.opacity(0.25))
                    .frame(width: 1, height: 11)
                    .padding(.leading, 6)
                    .padding(.trailing, 1)
                UpdateCheckButton(status: status)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, showsCheck ? 2 : 9)
        .frame(height: 24)
        .background(Capsule().fill(tint.opacity(0.1)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .help(helpText)
        .animation(Theme.quick, value: status.display)
    }

    @ViewBuilder private var content: some View {
        switch status.display {
        case .available(let release):
            Button { model.showUpdate(release) } label: { label }
                .buttonStyle(HoverButtonStyle(treatment: .quiet, tint: Theme.brand))
        case .development(.behind):
            Button { NSWorkspace.shared.open(BuildFreshnessCheck.commitsURL) } label: { label }
                .buttonStyle(HoverButtonStyle(treatment: .quiet, tint: .orange))
        default:
            label
        }
    }

    private var label: some View {
        ViewThatFits(in: .horizontal) {
            row(full: true)
            row(full: false)
        }
    }

    private func row(full: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(verbatim: full ? versionText : (status.version ?? "—"))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            if full, let state = stateText {
                Text(state)
                    .font(.system(size: 10.5, weight: isAvailable ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isAvailable ? Theme.brand : Color.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// « 0.3.3 », ou « 0.3.3 · abc1234 » pour un build de développement.
    private var versionText: String {
        let version = status.version ?? "—"
        guard status.kind == .development, let commit = status.commit else { return version }
        return version + " · " + commit
    }

    private var stateText: String? {
        switch status.display {
        case .upToDate: return String(localized: "À jour")
        case .available(let release): return "→ " + release.version.description
        case .development(let freshness): return freshness.label
        case .unknown: return nil
        }
    }

    private var isAvailable: Bool {
        if case .available = status.display { return true }
        return false
    }

    /// La recherche à la main, sauf quand une version est déjà proposée.
    private var showsCheck: Bool { !isAvailable }

    private var tint: Color {
        switch status.display {
        case .upToDate: return .green
        case .available: return Theme.brand
        case .development(.behind): return .orange
        case .development(.upToDate): return .green
        case .development, .unknown: return .secondary
        }
    }

    private var helpText: String {
        switch status.display {
        case .available(let release): return DictationCoordinator.updateMessage(release.version)
        default: return [status.versionLine, stateText].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// Recherche de mise à jour à la main, à droite de l'état de la version : une flèche, une roue pendant la recherche,
/// puis le résultat quelques secondes. Grisée pendant la pause qui suit une recherche.
struct UpdateCheckButton: View {
    @Environment(AppModel.self) private var model
    var status = BuildStatus.shared

    var body: some View {
        Group {
            switch status.manualPhase {
            case .checking:
                ProgressView()
                    .controlSize(.mini)
                    .help("Recherche en cours…")
            case .finished(let outcome):
                Image(systemName: outcome.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(outcome.tint)
                    .help(outcome.message)
                    .accessibilityLabel(outcome.message)
            case .idle:
                Button {
                    model.checkForUpdates()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle(treatment: .icon))
                .disabled(status.coolingDown)
                .help(status.coolingDown ? String(localized: "Recherche faite à l'instant : réessaie un peu plus tard")
                                         : String(localized: "Rechercher une mise à jour"))
                .accessibilityLabel("Rechercher une mise à jour")
            }
        }
        .frame(width: 18, height: 18)
        .transition(.opacity)
        .animation(Theme.quick, value: status.manualPhase)
    }
}

private struct StarBannerButton: View {
    var thanking: Bool
    var action: () -> Void

    private static let fill = Color.adaptive(
        light: NSColor(red: 1, green: 0.84, blue: 0.2, alpha: 0.2),
        dark: NSColor(red: 1, green: 0.8, blue: 0.2, alpha: 0.14)
    )
    private static let ink = Color.adaptive(
        light: NSColor(red: 0.55, green: 0.38, blue: 0, alpha: 1),
        dark: NSColor(red: 1, green: 0.84, blue: 0.4, alpha: 1)
    )

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: thanking ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Group {
                    if thanking { Text("Merci !") } else { Text("Une étoile sur GitHub") }
                }
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(.opacity)
            }
            .foregroundStyle(Self.ink)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.fill))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(HoverButtonStyle(treatment: .quiet, tint: Self.ink))
        .help(BuildFreshnessCheck.repositoryURL.absoluteString)
    }
}

struct ShortcutCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let key = KeyLabels.describe(keyCode: model.settings.keyCode, modifiers: model.settings.modifierFlags)
        VStack(alignment: .leading, spacing: 9) {
            Text("Raccourcis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            row(keys: [key, key], label: String(localized: "Mains libres"))
            row(keys: [key], label: String(localized: "Parler (maintenu)"))
            row(keys: ["esc"], label: String(localized: "Annuler"))
            let paste = model.settings.pasteLastShortcut
            if paste.enabled {
                row(keys: [KeyLabels.describe(paste, compact: true)], label: String(localized: "Coller la dernière"))
                    .help(String(localized: "Coller la dernière dictée"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
    }

    private func row(keys: [String], label: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    KeyCap(label: key)
                }
            }
            .frame(width: 50, alignment: .leading)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Message passager en bas de la fenêtre ; disparaît seul.
struct BannerToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let banner = model.statusBanner {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                    Text(banner)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        withAnimation(Theme.spring) { model.statusBanner = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.subtleFill))
                    }
                    .buttonStyle(HoverButtonStyle(treatment: .icon))
                    .help("Fermer")
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
                .frame(maxWidth: 480)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: banner) {
                    try? await Task.sleep(for: .seconds(7))
                    guard !Task.isCancelled, model.statusBanner == banner else { return }
                    withAnimation(Theme.spring) { model.statusBanner = nil }
                }
            }
        }
        .animation(Theme.spring, value: model.statusBanner)
        .padding(.bottom, 20)
        .padding(.horizontal, 24)
    }
}
