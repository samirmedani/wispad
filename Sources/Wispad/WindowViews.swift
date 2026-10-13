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
        .onAppear { model.refreshPermissions() }
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

/// Bandeau étoile, version et mise à jour : discret, au-dessus des raccourcis. Pour une release, la dernière version
/// publiée ; pour un build de développement, le retard sur la branche principale.
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
            Text(verbatim: status.versionLine)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)
            switch status.display {
            case .development(let freshness):
                developmentLine(freshness)
            case .upToDate:
                line(String(localized: "À jour"), color: .green)
            case .available(let release):
                availableLines(release)
            case .unknown:
                EmptyView()
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

    /// Build compilé depuis les sources : retard sur la branche principale du dépôt public.
    @ViewBuilder private func developmentLine(_ freshness: BuildFreshness) -> some View {
        if let label = freshness.label {
            if case .behind = freshness {
                Button {
                    NSWorkspace.shared.open(BuildFreshnessCheck.commitsURL)
                } label: {
                    line(label, color: .orange)
                }
                .buttonStyle(HoverButtonStyle(treatment: .quiet))
                .help("Voir les nouveaux commits sur GitHub")
            } else {
                line(label, color: .green)
            }
        }
    }

    /// Release plus récente : « Wispad 0.1.2 est disponible », puis « Mettre à jour » ; les deux ouvrent la fenêtre de
    /// mise à jour (notes de version), où l'installation se confirme. Pendant l'installation : son avancement, qui
    /// rouvre la fenêtre.
    @ViewBuilder private func availableLines(_ release: ReleaseInfo) -> some View {
        let updater = model.updater
        Button {
            model.showUpdate(release)
        } label: {
            line(DictationCoordinator.updateMessage(release.version), color: Theme.brand)
        }
        .buttonStyle(HoverButtonStyle(treatment: .quiet))
        .help("Voir les notes de version")
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

    private func line(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .transition(.opacity)
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
