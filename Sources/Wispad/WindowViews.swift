import SwiftUI
import AppKit
import WispadCore

extension AppSection {
    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .profile: return "brain.head.profile"
        case .usage: return "chart.bar.xaxis"
        case .dictionary: return "character.book.closed"
        case .providers: return "key.horizontal"
        case .settings: return "gearshape"
        }
    }

    /// Couleur de la pastille dans la barre latérale.
    var color: Color {
        switch self {
        case .home: return Theme.brand
        case .history: return .blue
        case .profile: return .purple
        case .usage: return .green
        case .dictionary: return .orange
        case .providers: return .indigo
        case .settings: return .gray
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
    @Environment(\.historyRowDidRender) private var historyRowDidRender
    @Environment(\.interactionPreviewHover) private var previewHover
    @Environment(\.interactionPreviewReduceMotion) private var previewReduceMotion
    @Environment(\.overlayGlass) private var overlayGlass
    @Environment(\.interactionReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let onboarding = model.onboarding {
                OnboardingView(controller: onboarding)
                    .frame(minWidth: 820, minHeight: 600)
                    .tint(Theme.accent)
            } else {
                main
            }
        }
        // Configuration ouverte : montrée aussi pendant le premier lancement guidé, où l'agent l'ouvre juste après
        // l'installation. Le guide reprend ensuite avec les réglages importés ; il n'écrit que des réglages propres à
        // l'appareil, que l'import ne touche jamais.
        .sheet(item: Binding(get: { model.pendingConfigurationImport }, set: { model.pendingConfigurationImport = $0 })) { pending in
            ConfigurationImportSheet(pending: pending)
                .environment(model)
                .tint(Theme.accent)
        }
    }

    private var main: some View {
        // Barre latérale native de macOS : sélection, matériau et largeur gérés par le système, comme dans Finder
        // ou Réglages Système. Elle reste toujours visible : l'app n'a qu'une colonne de contenu.
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: Theme.sidebarWidth)
            Divider().ignoresSafeArea()
            SectionStack(section: model.selectedSection, make: section, onShow: { [weak model] in model?.noteSectionShown($0) },
                         canWarmUp: { [weak model] in model?.coordinator.phase == .idle })
                // Jusque sous la barre de titre transparente ; chaque écran garde ses marges (zone sûre d'AppKit).
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { BannerToast() }
        }
        .frame(minWidth: 820, minHeight: 600)
        // Alerte de la barre latérale : relue hors du fil principal, qui dessine la fenêtre qui s'ouvre.
        // Le Profil se calcule aussi en arrière-plan : il s'ouvre ensuite sans attente.
        .onAppear {
            model.refreshPermissionsInBackground()
            ProfileLoader.shared.prepare(model)
        }
        .sheet(item: Binding(get: { model.updateSheet }, set: { model.updateSheet = $0 }),
               onDismiss: {
                   model.updater.dismissFailure()
                   model.updateCompletedFrom = nil
               }) { release in
            UpdateSheet(release: release)
                .environment(model)
                .tint(Theme.accent)
        }
    }
}

extension RootView {
    /// Écran d'une section, avec l'environnement de la fenêtre : chaque section vit dans sa propre vue (`SectionStack`).
    fileprivate func section(_ section: AppSection) -> AnyView {
        AnyView(SectionScreen(section: section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas.ignoresSafeArea())
            .environment(model)
            .environment(\.historyRowDidRender, historyRowDidRender)
            .environment(\.interactionPreviewHover, previewHover)
            .environment(\.interactionPreviewReduceMotion, previewReduceMotion)
            .environment(\.overlayGlass, overlayGlass))
    }
}

struct SectionScreen: View {
    var section: AppSection

    var body: some View {
        switch section {
        case .home: HomeView()
        case .history: HistoryView()
        case .profile: ProfileView()
        case .usage: UsageView()
        case .dictionary: DictionaryView()
        case .providers: ProvidersView()
        case .settings: SettingsView()
        }
    }
}

/// Groupes de la barre latérale. Réglages vit à part, en bas.
enum SidebarGroup: CaseIterable, Identifiable {
    case dictation, you, services

    var id: Self { self }

    var title: String {
        switch self {
        case .dictation: return String(localized: "Dictée")
        case .you: return String(localized: "Toi")
        case .services: return String(localized: "Services")
        }
    }

    var sections: [AppSection] {
        switch self {
        case .dictation: return [.home, .history]
        case .you: return [.profile, .dictionary]
        case .services: return [.providers, .usage]
        }
    }
}

/// Barre latérale « Épurée + chiffres » : la carte de dictée (état, micro, mots du jour, dernière dictée), les sections
/// en trois groupes avec leur chiffre du moment, puis Réglages, la dépense et le pied (étoile, version, liens).
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let digest = SidebarDigest.make(records: model.history)
        VStack(spacing: 0) {
            DictateCard(digest: digest)
                .padding(.horizontal, 12)
                .padding(.top, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(SidebarGroup.allCases) { group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.sections) { section in
                            SidebarRow(section: section, selected: section == model.selectedSection, digest: digest)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            VStack(alignment: .leading, spacing: 8) {
                SidebarRow(section: .settings, selected: model.selectedSection == .settings, digest: digest)
                SpendLine()
                    .padding(.horizontal, 10)
                ProjectFooter()
                    .padding(.horizontal, 6)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }
}

/// Rangée de section : symbole discret (couleur d'accent quand elle est ouverte), titre, chiffre du moment à droite.
/// La section ouverte a un fond doux et un trait d'accent sur le bord.
struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionPreviewHover) private var previewHover
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    var section: AppSection
    var selected: Bool
    var digest: SidebarDigest

    private var highlighted: Bool { !selected && (hovering || (previewHover && section == .history)) }
    private var shortcutIndex: Int { (AppSection.allCases.firstIndex(of: section) ?? 0) + 1 }

    var body: some View {
        Button {
            model.selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                SidebarRowDetail(section: section, digest: digest)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(selected ? (contrast == .increased ? 0.16 : 0.08)
                                                : highlighted ? (contrast == .increased ? 0.12 : 0.05) : 0))
                    .animation(reduceMotion ? nil : Theme.hover, value: highlighted)
            }
            .overlay(alignment: .leading) {
                if selected {
                    UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 2, topTrailing: 2), style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 7)
                        .offset(x: -12)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(section.title) (⌘\(shortcutIndex))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Chiffre discret au bout d'une rangée : la journée, les suggestions à valider, l'état des fournisseurs, la dépense.
/// Rien quand il n'y a rien à dire.
struct SidebarRowDetail: View {
    @Environment(AppModel.self) private var model
    var section: AppSection
    var digest: SidebarDigest

    var body: some View {
        switch section {
        case .home:
            if digest.wordsToday > 0 { meta(String(localized: "\(digest.wordsToday) mots")) }
        case .history:
            if digest.dictationsToday > 0 {
                meta(String(localized: "\(digest.dictationsToday) auj."))
                    .help(String(localized: "Dictées aujourd'hui"))
            }
        case .profile:
            if digest.streak >= 2 { meta(String(localized: "\(digest.streak) j de suite")) }
        case .dictionary:
            let pending = model.dictionaryInsights.suggestions.count
            if pending > 0 {
                Text(verbatim: "\(pending)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(Theme.accent))
                    .help(String(localized: "Suggestions à valider"))
                    .accessibilityLabel(String(localized: "\(pending) suggestions à valider"))
            } else if !model.dictionary.isEmpty {
                meta("\(model.dictionary.count)")
            }
        case .providers:
            ProvidersHealthDot()
        case .usage:
            let spent = model.usageSummary(for: .days30)
            if spent.totalUSD > 0 {
                meta(UsagePresentation.amount(spent.totalUSD, incomplete: spent.hasUnpricedCalls || model.usageLoadFailed))
                    .help(String(localized: "Dépensé ces 30 derniers jours"))
            }
        case .settings:
            if model.missingPermissions {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                    .help(String(localized: "Une autorisation manque"))
            }
        }
    }

    private func meta(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// État des fournisseurs en un point et un mot, comme la vue d'ensemble de l'écran Fournisseurs.
struct ProvidersHealthDot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.health
        let overview = ProvidersOverview.make(ProvidersSnapshot(model: model), paused: model.relayLines())
        let (text, color): (String, Color) = switch overview.tone {
        case .ready: (String(localized: "Prêt"), .green)
        case .relay: (String(localized: "Relais"), OverlayStyle.relay)
        case .attention: (String(localized: "À régler"), .orange)
        case .blocked: (String(localized: "Sans clé"), .red)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .fixedSize()
        .help(overview.title)
        .accessibilityElement(children: .combine)
    }
}

/// Carte du haut : l'app et son état, le bouton micro (dictée mains libres), les mots du jour avec les sept derniers
/// jours, et la dernière dictée (floutée, un clic la copie, la croix la masque).
struct DictateCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    var digest: SidebarDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wispad").font(.system(size: 14, weight: .semibold))
                    DictationStatusLine()
                }
                Spacer(minLength: 4)
                MicButton()
            }
            Divider().padding(.vertical, 9)
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(digest.wordsToday, format: .number)
                        .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("mots aujourd'hui")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                WeekBars(values: digest.wordsByDay)
            }
            .accessibilityElement(children: .combine)
            if let last = digest.last, last.id != model.settings.dismissedLastDictationID {
                LastDictationButton(last: last)
                    .padding(.top, 9)
            }
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.25 : 0.07), lineWidth: 1)
        }
        .animation(Theme.quick, value: digest)
    }
}

/// Bouton micro : lance une dictée mains libres comme deux appuis sur le raccourci, puis l'arrête.
struct MicButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion

    var body: some View {
        let listening: Bool = if case .listening = model.coordinator.phase { true } else { false }
        Button {
            model.toggleHandsFreeDictation()
        } label: {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.system(size: listening ? 11 : 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.brand.gradient))
                .overlay {
                    Circle().strokeBorder(Theme.brand.opacity(listening ? 0.28 : 0), lineWidth: 4)
                        .padding(-4)
                }
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(model.coordinator.phase == .starting)
        .animation(reduceMotion ? nil : Theme.spring, value: listening)
        .help(listening ? String(localized: "Terminer la dictée") : String(localized: "Dicter (mains libres)"))
        .accessibilityLabel(listening ? String(localized: "Terminer la dictée") : String(localized: "Dicter (mains libres)"))
    }
}

/// Mots des sept derniers jours en petites barres ; aujourd'hui en couleur d'accent.
struct WeekBars: View {
    var values: [Int]

    var body: some View {
        let top = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index == values.count - 1 ? Theme.accent : Theme.accent.opacity(0.35))
                    .frame(width: 6, height: max(2, 26 * CGFloat(value) / CGFloat(top)))
            }
        }
        .frame(height: 26, alignment: .bottom)
        .accessibilityLabel(String(localized: "Mots des sept derniers jours"))
        .accessibilityValue(values.map(String.init).joined(separator: ", "))
    }
}

/// Dernière dictée réussie : app et moment, puis le début du texte, flouté tant que le pointeur ne le survole pas. Un
/// clic (ou l'icône) copie le texte ; la croix masque cette dictée, la suivante s'affichera.
struct LastDictationButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var copied = false
    var last: SidebarDigest.LastDictation

    private var hidden: Bool { !hovering }

    var body: some View {
        Button(action: copy) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(caption(now: context.date))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    // Place de la croix, posée par-dessus (un bouton ne peut pas en contenir un autre).
                    Color.clear.frame(width: 16, height: 16)
                }
                Text(last.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Aucun rectangle ne coupe les contours diffus autour des glyphes.
                    .blur(radius: hidden ? 5 : 0, opaque: false)
                    .opacity(hidden ? 0.6 : 1)
                    .animation(reduceMotion ? nil : Theme.privacy, value: hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.055))
                    .animation(reduceMotion ? nil : Theme.hover, value: hovering)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(treatment: .icon))
            .padding(.top, 6)
            .padding(.trailing, 5)
            .help(String(localized: "Masquer cette dictée"))
            .accessibilityLabel(String(localized: "Masquer cette dictée"))
        }
        .onHover { hovering = $0 }
        .help(copied ? String(localized: "Copié") : String(localized: "Copier la dernière dictée"))
        .accessibilityLabel(String(localized: "Copier la dernière dictée"))
        .accessibilityValue(last.text)
    }

    private func copy() {
        model.copy(last.text)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            copied = false
        }
    }

    private func dismiss() {
        model.settings.dismissedLastDictationID = last.id
        model.saveSettings()
    }

    private func caption(now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = appLocale
        formatter.unitsStyle = .short
        let moment = now.timeIntervalSince(last.date) < 60
            ? String(localized: "à l'instant")
            : formatter.localizedString(for: last.date, relativeTo: now)
        guard let app = last.app, !app.isEmpty else { return moment }
        return app + " · " + moment
    }
}

/// Dépense des 30 derniers jours face au prix mensuel de Wispr Flow Pro, avec une jauge.
struct SpendLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.usageSummary(for: .days30)
        let reference = SubscriptionReference.all.first
        let incomplete = summary.hasUnpricedCalls || model.usageLoadFailed
        Button {
            model.selectedSection = .usage
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("30 derniers jours")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(UsagePresentation.amount(summary.totalUSD, incomplete: incomplete))
                        .fontWeight(.medium)
                }
                .font(.system(size: 11).monospacedDigit())
                .lineLimit(1)
                GeometryReader { proxy in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.green)
                                .frame(width: max(3, proxy.size.width * fraction(summary.totalUSD, reference)))
                        }
                }
                .frame(height: 4)
                if let reference {
                    Text("\(reference.name) \(reference.plan) : \(MoneyFormat.usd(reference.monthlyUSD)) par mois")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Ce que tes dictées ont coûté ces 30 derniers jours, face au prix d'un abonnement"))
    }

    private func fraction(_ spent: Double, _ reference: SubscriptionReference?) -> CGFloat {
        guard let reference, reference.monthlyUSD > 0 else { return 0 }
        return CGFloat(min(1, max(0, spent / reference.monthlyUSD)))
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
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
        }
        .help(status.text)
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
                AppearanceButton()
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
                .buttonStyle(HoverButtonStyle(treatment: .quiet, tint: Theme.accent))
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
                    .foregroundStyle(isAvailable ? Theme.accent : Color.secondary)
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
        case .available: return Theme.accent
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

    private static let ink = Color.adaptive(
        light: NSColor(red: 0.55, green: 0.38, blue: 0, alpha: 1),
        dark: NSColor(red: 1, green: 0.84, blue: 0.4, alpha: 1)
    )

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: thanking ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.ink)
                    .contentTransition(.symbolEffect(.replace))
                Group {
                    if thanking { Text("Merci !") } else { Text("Une étoile sur GitHub") }
                }
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(.opacity)
            }
            // Un lien discret, pas un bandeau : seule l'étoile garde sa couleur.
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(HoverButtonStyle(treatment: .quiet, tint: .primary))
        .help(BuildFreshnessCheck.repositoryURL.absoluteString)
    }
}

/// Raccourcis de la dictée, en bas de l'Accueil : une rangée de touches dessinées, comme la fenêtre d'enregistrement
/// de Superwhisper (« Stop ⌥ Space · Cancel esc »).
struct ShortcutCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let key = KeyLabels.describe(keyCode: model.settings.keyCode, modifiers: model.settings.modifierFlags)
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(String(localized: "Raccourcis"))
            FlowLayout(spacing: 18) {
            row(keys: [key, key], label: String(localized: "Mains libres"))
            row(keys: [key], label: String(localized: "Parler (maintenu)"))
            if model.settings.sendWithShift {
                row(keys: [key, "⇧"], label: String(localized: "Finir et envoyer"))
                    .help(String(localized: "Maj pour envoyer : le texte est collé, puis envoyé"))
            }
            row(keys: ["esc"], label: String(localized: "Annuler"))
            let paste = model.settings.pasteLastShortcut
            if paste.enabled {
                row(keys: [KeyLabels.describe(paste, compact: true)], label: String(localized: "Coller la dernière"))
                    .help(String(localized: "Coller la dernière dictée"))
            }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func row(keys: [String], label: String) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    KeyCap(label: key)
                }
            }
            Text(label)
                .font(.system(size: 12))
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
