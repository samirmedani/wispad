import SwiftUI
import AppKit
import Charts
import WispadCore

// MARK: - Consommation

/// Consommation, sur la période choisie : en tête, la dépense et ce qui s'est passé en une phrase ; puis le coût par
/// mois face aux abonnements, la dépense dans le temps et par service, les relais de secours, les soldes et le détail
/// des appels. Tout vient des appels enregistrés de la période.
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var refreshing = false

    private var period: StatsPeriod { model.settings.usagePeriod }

    var body: some View {
        let now = Date()
        let events = model.usageEvents(for: period, now: now)
        let summary = UsageSummary.make(events: events, period: .all, now: now)
        let incomplete = summary.hasUnpricedCalls || model.usageLoadFailed
        let span = model.usage.last.map { UsageSpan.make(firstUse: $0.createdAt, now: now) }
        ScreenScroll {
            ScreenHeader(title: String(localized: "Consommation"),
                         subtitle: String(localized: "Le coût de tes dictées, service par service.")) {
                VStack(alignment: .trailing, spacing: 6) {
                    PillPicker(selection: Binding(
                        get: { model.settings.usagePeriod },
                        set: { model.setDisplayChoice(\.usagePeriod, $0) }
                    ))
                    if period == .all, let span {
                        PeriodSpanCaption(span: span)
                            .transition(.opacity)
                    }
                }
            }
            if let warning = model.usageStorageWarning {
                HStack(alignment: .top, spacing: 12) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button("Réessayer") { model.retrySavingUsage() }
                        .buttonStyle(HoverButtonStyle(treatment: .quiet))
                }
                .padding(16)
                .card()
            }
            UsageOverviewCard(events: events, summary: summary, fallbacks: model.fallbackSummary(for: period, now: now),
                              period: period, incomplete: incomplete, storageIncomplete: model.usageLoadFailed)
            if let span, !events.isEmpty {
                MonthlyComparisonCard(totalUSD: summary.totalUSD, incomplete: incomplete, period: period,
                                      days: MonthlyCost.days(for: period, usedDays: span.days))
            }
            if !events.isEmpty {
                SpendChart(events: events, period: period, storageIncomplete: model.usageLoadFailed)
                UsageServicesCard(summary: summary, storageIncomplete: model.usageLoadFailed)
                FallbackStatsCard(period: period, now: now)
            }
            balances
            if !events.isEmpty {
                UsageCallsTable(events: events, now: now, period: period, incomplete: incomplete)
                    .id(period)
            }
            Text("Coûts estimés d'après les tarifs publiés de chaque modèle (au survol d'une ligne « Par service »). La facture du fournisseur fait foi.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .task {
            refreshing = true
            await model.refreshBalancesIfStale()
            refreshing = false
        }
    }

    private var balances: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: String(localized: "Soldes chez les fournisseurs")) {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Actualiser", systemImage: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(HoverButtonStyle(treatment: .quiet))
                }
            }
            BalanceLine(name: "DeepSeek") {
                Text(model.deepSeekBalance ?? (model.hasCleanupKey() ? String(localized: "Indisponible") : String(localized: "Aucune clé")))
                    .foregroundStyle(model.deepSeekBalance == nil ? .secondary : .primary)
            }
            Divider()
            BalanceLine(name: "xAI") {
                if let account = model.xaiAccount {
                    HStack(spacing: 10) {
                        if account.blocked {
                            StatusChip(text: String(localized: "Bloqué : crédit épuisé ou plafond atteint"), tint: .red)
                        } else if let billing = model.xaiBilling {
                            Text(MoneyFormat.usd(billing.remainingUSD))
                        } else {
                            StatusChip(text: String(localized: "Actif"), tint: .green)
                        }
                        Link("Facturation", destination: account.billingURL)
                            .font(.system(size: 12))
                            .hoverFeedback()
                    }
                } else {
                    Text(model.hasKey(.xai) ? String(localized: "Indisponible") : String(localized: "Aucune clé"))
                        .foregroundStyle(.secondary)
                }
            }
            if let billing = model.xaiBilling, model.xaiAccount?.blocked != true {
                XAIBillingDetail(billing: billing)
            }
            if model.xaiAccount != nil, model.xaiBilling == nil {
                Text("xAI ne donne son solde qu'à une clé de gestion. Crée-la dans la console xAI (Settings → Management Keys) et ajoute-la dans Fournisseurs, parmi les clés facultatives.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .card()
    }

    private func refresh() async {
        refreshing = true
        await model.refreshBalances()
        refreshing = false
    }
}

// MARK: - En bref

/// En tête de Consommation : la dépense de la période en grand, la part de chaque fournisseur, et ce qui s'est passé en
/// une phrase (appels réussis, échecs, relais). « ≥ » marque un minimum, expliqué juste sous le montant.
struct UsageOverviewCard: View {
    var events: [UsageEvent]
    var summary: UsageSummary
    var fallbacks: FallbackSummary
    var period: StatsPeriod
    var incomplete: Bool
    var storageIncomplete: Bool

    var body: some View {
        let shares = UsagePresentation.providerShares(summary, storageIncomplete: storageIncomplete)
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    total
                    Spacer(minLength: 32)
                    if !shares.isEmpty {
                        ProviderSplitView(shares: shares)
                            .frame(width: 380)
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    total
                    if !shares.isEmpty { ProviderSplitView(shares: shares) }
                }
            }
            if !events.isEmpty {
                Divider()
                HealthLine(health: UsagePresentation.health(events: events, fallbacks: fallbacks))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(UsagePresentation.spentTitle(period))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(UsagePresentation.amount(summary.totalUSD, incomplete: incomplete))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(UsagePresentation.callsCaption(events.count, period: period))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            if let note = UsagePresentation.minimumNote(unknownCosts: events.filter { $0.costUSD == nil }.count,
                                                        storageIncomplete: storageIncomplete) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
    }
}

/// Part de chaque fournisseur dans la dépense : une barre en couleurs, puis, pour chacun, ce qu'il a fait, son montant
/// et sa part.
struct ProviderSplitView: View {
    var shares: [UsagePresentation.ProviderShare]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SplitBar(parts: shares.map { SplitBar.Part(fraction: $0.fraction, color: ProviderTint.color($0.provider)) })
                .frame(height: 10)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(shares) { share in
                HStack(spacing: 8) {
                    Circle()
                        .fill(ProviderTint.color(share.provider))
                        .frame(width: 8, height: 8)
                    Text(share.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(share.tasks)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(share.amount)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(share.percent)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}

/// Barre découpée en parts (fractions de 0 à 1) sur un fond discret ; une part non nulle reste visible.
struct SplitBar: View {
    struct Part {
        var fraction: Double
        var color: Color
    }

    var parts: [Part]

    var body: some View {
        GeometryReader { proxy in
            let visible = parts.filter { $0.fraction > 0 }
            let gap: CGFloat = 2
            let width = max(0, proxy.size.width - gap * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: gap) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, part in
                    Rectangle()
                        .fill(part.color)
                        .frame(width: max(3, width * min(1, part.fraction)))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
        }
        .background(Theme.subtleFill)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Une phrase sur la période : tout a abouti, ou combien d'appels ont échoué et ce que le relais a rattrapé.
struct HealthLine: View {
    var health: UsagePresentation.Health

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: health.symbol)
                .foregroundStyle(health.tint)
            Text(health.message)
                .font(.system(size: 12.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Relais de secours

/// Relais de secours, sur la période : quand un service ne répond pas, Wispad envoie la même demande à un autre. La carte
/// répond à quatre questions, à partir des seuls appels enregistrés : combien de demandes le relais a sauvées, vers quel
/// service, pourquoi le service principal a lâché, et quand.
struct FallbackStatsCard: View {
    @Environment(AppModel.self) private var model
    var period: StatsPeriod
    var now = Date()

    var body: some View {
        let summary = model.fallbackSummary(for: period, now: now)
        let failures = model.failureBreakdown(for: period, now: now)
        let status = FallbackPresentation.status(summary, failures: failures)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                CardTitle(String(localized: "Relais de secours"))
                Text("Quand un service ne répond pas, Wispad envoie la même demande à un autre pour que ta dictée aboutisse.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RelayHeadline(summary: summary, status: status)
            if !summary.routes.isEmpty {
                RelaySection(title: String(localized: "Qui a pris le relais"), symbol: "arrow.triangle.branch") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summary.routes) { RelayRouteRow(route: $0) }
                    }
                }
            }
            if FailurePresentation.hasDetails(failures) {
                RelaySection(title: String(localized: "Pourquoi"), symbol: "questionmark.circle") {
                    RelayCausesView(breakdown: failures)
                }
            }
            if !summary.recent.isEmpty {
                RelaySection(title: String(localized: "Quand"), symbol: "clock",
                             trailing: FallbackPresentation.recentCaption(shown: summary.recent.count, total: summary.total)) {
                    VStack(spacing: 0) {
                        ForEach(summary.recent) { RelayEntryRow(entry: $0, now: now) }
                    }
                }
            }
            ForEach(FallbackPresentation.trackingNotes(
                relays: FallbackPresentation.trackingNoteDate(trackingStartedAt: model.store.fallbackTrackingStartedAt, period: period, now: now),
                causes: failures.providers.isEmpty ? nil
                    : FallbackPresentation.trackingNoteDate(trackingStartedAt: model.store.failureCauseTrackingStartedAt, period: period, now: now)
            ), id: \.self) { note in
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Petit titre d'une partie de la carte, avec son icône ; à droite, une précision facultative.
private struct RelaySection<Content: View>: View {
    var title: String
    var symbol: String
    var trailing: String?
    @ViewBuilder var content: Content

    init(title: String, symbol: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            content
        }
    }
}

/// Ce qui s'est passé en grand : une jauge (relais réussis en vert, en échec en orange) et deux phrases.
private struct RelayHeadline: View {
    var summary: FallbackSummary
    var status: FallbackPresentation.Status

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RelayGauge(successes: summary.successes, failures: summary.failures, status: status)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(status.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(status.tint.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

private struct RelayGauge: View {
    var successes: Int
    var failures: Int
    var status: FallbackPresentation.Status

    var body: some View {
        let total = successes + failures
        ZStack {
            if total == 0 {
                Circle().fill(status.tint.opacity(0.16))
                Image(systemName: status.level == .clear ? "checkmark" : "exclamationmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(status.tint)
            } else {
                let done = CGFloat(successes) / CGFloat(total)
                Circle().stroke(Theme.subtleFill, lineWidth: 5)
                if failures > 0 {
                    Circle()
                        .trim(from: done, to: 1)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if successes > 0 {
                    Circle()
                        .trim(from: 0, to: done)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(UsageText.count(successes))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .padding(6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Étape relayée et son icône : Voix, Correction, Dictionnaire.
struct StageLabel: View {
    var stage: FallbackStage

    var body: some View {
        Label(FallbackPresentation.stageName(stage), systemImage: FallbackPresentation.stageSymbol(stage))
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
    }
}

/// « xAI → OpenAI » en pastilles : le service qui a lâché, estompé, puis celui qui a pris le relais.
struct RouteBadges: View {
    var from: String
    var to: String

    var body: some View {
        HStack(spacing: 6) {
            ProviderBadge(provider: from)
                .opacity(0.75)
            Image(systemName: "arrow.right")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.tertiary)
            ProviderBadge(provider: to)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FallbackPresentation.route(from: from, to: to))
    }
}

private struct RelayRouteRow: View {
    var route: FallbackRouteSummary

    var body: some View {
        HStack(spacing: 10) {
            StageLabel(stage: route.stage)
                .frame(width: 118, alignment: .leading)
            RouteBadges(from: route.fromProvider, to: route.toProvider)
            Spacer(minLength: 8)
            Text(FallbackPresentation.outcome(route))
                .font(.system(size: 12))
                .foregroundStyle(route.failures > 0 ? Color.orange : Color.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .help(FallbackPresentation.meaning(route.stage))
        .accessibilityElement(children: .combine)
    }
}

private struct RelayEntryRow: View {
    var entry: FallbackEntry
    var now: Date

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if UsagePresentation.showsDate(entry.date, now: now) {
                    Text(entry.date, format: .dateTime.day().month(.abbreviated).hour().minute().locale(appLocale))
                } else {
                    Text(entry.date, format: .dateTime.hour().minute().locale(appLocale))
                }
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: 96, alignment: .leading)
            StageLabel(stage: entry.stage)
                .frame(width: 118, alignment: .leading)
            RouteBadges(from: entry.fromProvider, to: entry.toProvider)
            Spacer(minLength: 8)
            Text(entry.cause.map(FailurePresentation.label) ?? FallbackPresentation.reason(entry.reason))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.succeeded ? Color.green : Color.orange)
                .help(entry.succeeded ? String(localized: "Relais réussi") : String(localized: "Relais en échec"))
        }
        .font(.system(size: 12))
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Pourquoi le service principal a lâché : une barre par côté (ta connexion, le fournisseur, une clé refusée,
/// incertain) avec sa légende, la cause la plus fréquente en une phrase, les services mis de côté, puis le détail par
/// service à la demande. Tout fournisseur enregistré apparaît, quel qu'il soit.
private struct RelayCausesView: View {
    var breakdown: FailureBreakdown
    @State private var expanded = false

    var body: some View {
        let total = breakdown.failures
        VStack(alignment: .leading, spacing: 10) {
            if total > 0 {
                SplitBar(parts: APIFailureCause.Side.allCases.map {
                    SplitBar.Part(fraction: Double(breakdown.count($0)) / Double(total), color: FailurePresentation.tint($0))
                })
                .frame(height: 8)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(FailurePresentation.shownSides(breakdown), id: \.self) { side in
                        sideLine(side, count: breakdown.count(side))
                    }
                }
            }
            if let top = FailurePresentation.topCause(breakdown) {
                Text(top)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(FailurePresentation.pausedLines(breakdown), id: \.self) { line in
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(breakdown.providers) { provider in
                        providerLine(provider)
                    }
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Détail par service")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sideLine(_ side: APIFailureCause.Side, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(count > 0 ? FailurePresentation.tint(side) : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            Text(FailurePresentation.title(side))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
            Text(UsageText.count(count))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
            Text(FailurePresentation.explanation(side))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func providerLine(_ provider: FailureBreakdown.Provider) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(ProviderTint.color(provider.name)).frame(width: 7, height: 7)
                Text(FallbackPresentation.providerName(provider.name))
                    .font(.system(size: 12.5, weight: .semibold))
                if provider.failures > 0 {
                    Text(FailurePresentation.failures(provider.failures))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ForEach(FailurePresentation.details(provider), id: \.self) { line in
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
            }
        }
    }
}

/// Textes des causes d'échec : courts, sans jargon, sans contenu d'erreur.
enum FailurePresentation {
    static func label(_ cause: APIFailureCause) -> String {
        switch cause {
        case .offline: return String(localized: "pas d'internet sur ce Mac")
        case .timeout: return String(localized: "pas de réponse à temps")
        case .serverError: return String(localized: "panne du service")
        case .rateLimited: return String(localized: "limite ou crédit atteint")
        case .keyRejected: return String(localized: "clé refusée")
        case .refused: return String(localized: "demande refusée")
        case .badResponse: return String(localized: "réponse inutilisable")
        case .cancelled: return String(localized: "annulé")
        }
    }

    static func title(_ side: APIFailureCause.Side) -> String {
        switch side {
        case .connection: return String(localized: "Ta connexion")
        case .provider: return String(localized: "Le fournisseur")
        case .account: return String(localized: "Clé refusée")
        case .undetermined: return String(localized: "Incertain")
        }
    }

    /// Ce que veut dire chaque côté, en quelques mots.
    static func explanation(_ side: APIFailureCause.Side) -> String {
        switch side {
        case .connection: return String(localized: "ce Mac n'avait pas internet")
        case .provider: return String(localized: "panne, lenteur ou limite chez lui")
        case .account: return String(localized: "à vérifier dans Fournisseurs")
        case .undetermined: return String(localized: "pas de réponse, sans autre appel réussi autour : peut-être ta connexion")
        }
    }

    static func tint(_ side: APIFailureCause.Side) -> Color {
        switch side {
        case .connection: return .blue
        case .provider: return .orange
        case .account: return .red
        case .undetermined: return .gray
        }
    }

    /// Ta connexion et le fournisseur toujours, pour répondre à « nous ou eux » ; clé refusée et incertain s'il y en a.
    static func shownSides(_ breakdown: FailureBreakdown) -> [APIFailureCause.Side] {
        APIFailureCause.Side.allCases.filter { $0 == .connection || $0 == .provider || breakdown.count($0) > 0 }
    }

    /// Des échecs avec une cause connue, ou un service mis de côté : la partie « Pourquoi » a quelque chose à dire.
    static func hasDetails(_ breakdown: FailureBreakdown) -> Bool {
        breakdown.failures > 0 || breakdown.providers.contains { $0.paused > 0 }
    }

    static func failures(_ count: Int) -> String {
        count == 1 ? String(localized: "1 échec") : String(localized: "\(count) échecs")
    }

    /// La cause la plus fréquente, avec son service : « Le plus souvent : DeepSeek, pas de réponse à temps (3 fois). »
    /// À égalité, le service listé en premier (le plus touché), puis l'ordre des causes. nil sans échec.
    static func topCause(_ breakdown: FailureBreakdown) -> String? {
        var best: (provider: String, cause: APIFailureCause, count: Int)?
        for provider in breakdown.providers {
            for cause in APIFailureCause.allCases {
                let count = provider.causes[cause] ?? 0
                if count > (best?.count ?? 0) { best = (provider.name, cause, count) }
            }
        }
        guard let best else { return nil }
        let name = FallbackPresentation.providerName(best.provider)
        if breakdown.failures == 1 {
            return String(localized: "\(name) : \(label(best.cause)).")
        }
        return String(localized: "Le plus souvent : \(name), \(label(best.cause)) (\(FallbackPresentation.times(best.count))).")
    }

    /// Services mis de côté après des échecs répétés : le relais a répondu directement.
    static func pausedLines(_ breakdown: FailureBreakdown) -> [String] {
        breakdown.providers.filter { $0.paused > 0 }.map { provider in
            let name = FallbackPresentation.providerName(provider.name)
            return provider.paused == 1
                ? String(localized: "\(name) a été mis de côté 1 fois après des échecs répétés : le relais a répondu directement.")
                : String(localized: "\(name) a été mis de côté \(provider.paused) fois après des échecs répétés : le relais a répondu directement.")
        }
    }

    /// « pas de réponse à temps (6) · panne du service (2) », du plus fréquent au plus rare ; puis, s'il y a lieu, les
    /// délais sans preuve que la connexion marchait et les mises de côté.
    static func details(_ provider: FailureBreakdown.Provider) -> [String] {
        var lines: [String] = []
        let causes = provider.causes.filter { $0.value > 0 }
            .sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
            .map { "\(label($0.key)) (\($0.value))" }
        if !causes.isEmpty { lines.append(causes.joined(separator: " · ")) }
        if provider.undeterminedTimeouts > 0 {
            lines.append(provider.undeterminedTimeouts == 1
                ? String(localized: "1 délai sans autre appel réussi autour : ta connexion a pu être en cause.")
                : String(localized: "\(provider.undeterminedTimeouts) délais sans autre appel réussi autour : ta connexion a pu être en cause."))
        }
        if provider.paused > 0 {
            lines.append(provider.paused == 1
                ? String(localized: "Mis de côté 1 fois après des échecs répétés : le secours a répondu directement.")
                : String(localized: "Mis de côté \(provider.paused) fois après des échecs répétés : le secours a répondu directement."))
        }
        return lines
    }
}

enum ProviderTint {
    static func color(_ provider: String) -> Color {
        switch provider {
        case "xAI": return .purple
        case "DeepSeek": return .blue
        case "OpenAI": return .green
        case "TypeSafe": return .pink
        default: return .gray
        }
    }
}

struct BalanceLine<Value: View>: View {
    var name: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack {
            Text(name).font(.system(size: 13, weight: .medium))
            Spacer()
            value.font(.system(size: 13))
        }
    }
}

/// Détail du compte xAI sous son solde : autonomie, mois en cours, 30 derniers jours par clé et par service,
/// dernière recharge. Montants de la facturation xAI, pas des estimations de l'app.
struct XAIBillingDetail: View {
    var billing: XAIBilling

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let days = billing.daysLeft {
                Text(String(localized: "Environ \(days) jours de crédit au rythme des 30 derniers jours."))
                    .foregroundStyle(days < 7 ? Color.orange : Color.secondary)
            }
            Text(String(localized: "Mois en cours : \(MoneyFormat.usd(billing.cycleSpentUSD)) consommés, retirés du crédit à la facture mensuelle."))
                .foregroundStyle(.secondary)
            if !billing.recentByKey.isEmpty {
                HStack(alignment: .top, spacing: 24) {
                    shares(String(localized: "30 jours par clé API"), billing.recentByKey)
                    shares(String(localized: "30 jours par service"), billing.recentByService)
                }
            }
            if let topUp = billing.lastTopUp {
                let date = topUp.date.formatted(date: .abbreviated, time: .omitted)
                Text(topUp.automatic
                    ? String(localized: "Dernière recharge : \(MoneyFormat.usd(topUp.usd)) le \(date), automatique.")
                    : String(localized: "Dernière recharge : \(MoneyFormat.usd(topUp.usd)) le \(date), manuelle."))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shares(_ title: String, _ shares: [XAIBilling.Share]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(shares) { share in
                HStack {
                    Text(share.name)
                    Spacer(minLength: 12)
                    Text(MoneyFormat.usd(share.usd)).monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dépense dans le temps

struct SpendChart: View {
    var events: [UsageEvent]
    var period: StatsPeriod
    var storageIncomplete = false

    private struct Point: Identifiable {
        var date: Date
        var provider: String
        var cost: Double
        var id: String { "\(date.timeIntervalSince1970)-\(provider)" }
    }

    var body: some View {
        let axis = TimeAxis(period: period, earliest: events.last?.createdAt)
        let unknownCosts = events.filter { $0.costUSD == nil }.count
        var totals: [String: Point] = [:]
        for event in events {
            guard let cost = event.costUSD, let key = axis.bucket(of: event.createdAt) else { continue }
            let provider = event.api.provider
            let id = "\(key.timeIntervalSince1970)-\(provider)"
            totals[id, default: Point(date: key, provider: provider, cost: 0)].cost += cost
        }
        let points = totals.values.sorted { ($0.date, $0.provider) < ($1.date, $1.provider) }
        let providers = ["xAI", "DeepSeek", "OpenAI", "TypeSafe"].filter { name in points.contains { $0.provider == name } }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                CardTitle(title: UsagePresentation.chartTitle(axis.unit)) {
                    HStack(spacing: 12) {
                        ForEach(providers, id: \.self) { name in
                            HStack(spacing: 5) {
                                Circle().fill(ProviderTint.color(name)).frame(width: 8, height: 8)
                                Text(FallbackPresentation.providerName(name))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let note = UsagePresentation.chartNote(unknownCosts: unknownCosts, storageIncomplete: storageIncomplete) {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("Période", point.date, unit: axis.unit),
                        y: .value("Coût", point.cost)
                    )
                    .foregroundStyle(by: .value("Fournisseur", point.provider))
                    .cornerRadius(3)
                }
            }
            .chartForegroundStyleScale(["xAI": ProviderTint.color("xAI"), "DeepSeek": ProviderTint.color("DeepSeek"), "OpenAI": ProviderTint.color("OpenAI"), "TypeSafe": ProviderTint.color("TypeSafe")])
            .chartXScale(domain: (axis.starts.first ?? Date())...(axis.starts.last.flatMap { Calendar.current.date(byAdding: axis.unit, value: 1, to: $0) } ?? Date()))
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(MoneyFormat.usd(amount)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: axis.labelCount)) { _ in
                    AxisValueLabel(format: axis.labelFormat)
                }
            }
            .chartLegend(.hidden)
            .environment(\.locale, appLocale)
            .frame(height: 140)
        }
        .padding(16)
        .card()
        .animation(Theme.spring, value: period)
    }
}

// MARK: - Par service

/// Par service : chaque API utilisée sur la période, ce qu'elle a fait, son coût et sa part de la dépense.
struct UsageServicesCard: View {
    var summary: UsageSummary
    var storageIncomplete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(String(localized: "Par service"))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(summary.rows) { row in
                UsageRowView(row: row, share: summary.totalUSD > 0 ? row.costUSD / summary.totalUSD : nil,
                             storageIncomplete: storageIncomplete)
                if row.id != summary.rows.last?.id { Divider().padding(.leading, 56) }
            }
        }
        .padding(.bottom, 6)
        .card()
    }
}

struct UsageRowView: View {
    var row: UsageRow
    /// Part de la dépense de la période, de 0 à 1 ; nil quand rien n'a coûté.
    var share: Double?
    var storageIncomplete = false

    var body: some View {
        let tint = ProviderTint.color(row.api.provider)
        HStack(alignment: .center, spacing: 12) {
            IconBadge(symbol: row.api.isAudio ? "waveform" : "text.badge.checkmark", tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.api.label).font(.system(size: 13, weight: .semibold))
                Text(UsagePresentation.rowDetail(row)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let share {
                    SplitBar(parts: [SplitBar.Part(fraction: share, color: tint.opacity(0.75))])
                        .frame(maxWidth: 220)
                        .frame(height: 4)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsagePresentation.amount(row.costUSD, incomplete: storageIncomplete || row.hasUnpricedCalls))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let share {
                    Text(UsagePresentation.percent(share))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .help(row.models.compactMap { PriceText.describe(model: $0) }.joined(separator: "\n"))
    }
}

// MARK: - Textes

/// Les chiffres et la liste partagent la même période ; les coûts absents ne deviennent jamais des zéros certains.
enum UsagePresentation {
    static func events(_ events: [UsageEvent], for period: StatsPeriod, now: Date, calendar: Calendar = .current) -> [UsageEvent] {
        guard let start = period.startDate(now: now, calendar: calendar) else { return events }
        return events.filter { $0.createdAt >= start }
    }

    static func amount(_ value: Double, incomplete: Bool) -> String {
        (incomplete ? "≥ " : "") + MoneyFormat.usd(value)
    }

    static func quantities(_ event: UsageEvent) -> String {
        if event.api.isAudio { return UsageText.audio(event.audioSeconds) }
        if event.costUSD == nil, event.tokens == TokenUsage() { return String(localized: "Compteurs indisponibles") }
        return String(localized: "\(event.tokens.totalInput) → \(event.tokens.output) jetons")
    }

    static func providerAmount(_ summary: UsageSummary, providers: Set<String>, storageIncomplete: Bool = false) -> String {
        let rows = summary.rows.filter { providers.contains($0.api.provider) }
        return amount(rows.reduce(0) { $0 + $1.costUSD }, incomplete: storageIncomplete || rows.contains { $0.hasUnpricedCalls })
    }

    static func showsDate(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        !calendar.isDate(date, inSameDayAs: now)
    }

    /// « aujourd'hui », « ces 7 derniers jours », « ces 30 derniers jours », « depuis le début ».
    static func periodPhrase(_ period: StatsPeriod) -> String {
        switch period {
        case .today: return String(localized: "aujourd'hui")
        case .days7: return String(localized: "ces 7 derniers jours")
        case .days30: return String(localized: "ces 30 derniers jours")
        case .all: return String(localized: "depuis le début")
        }
    }

    /// Titre du montant de l'en-tête.
    static func spentTitle(_ period: StatsPeriod) -> String {
        switch period {
        case .today: return String(localized: "Dépensé aujourd'hui")
        case .days7: return String(localized: "Dépensé ces 7 derniers jours")
        case .days30: return String(localized: "Dépensé ces 30 derniers jours")
        case .all: return String(localized: "Dépensé depuis le début")
        }
    }

    /// « 1 appel », « 1 234 appels ».
    static func calls(_ count: Int) -> String {
        count == 1 ? String(localized: "1 appel") : String(localized: "\(UsageText.count(count)) appels")
    }

    /// Sous le montant : le nombre d'appels, ou qu'il n'y en a eu aucun.
    static func callsCaption(_ count: Int, period: StatsPeriod) -> String {
        guard count > 0 else { return String(localized: "Aucun appel \(periodPhrase(period)) : rien à payer.") }
        return String(localized: "\(calls(count)) aux services de dictée")
    }

    /// Pourquoi un montant est un minimum (« ≥ »), en une phrase ; nil s'il est complet.
    static func minimumNote(unknownCosts: Int, storageIncomplete: Bool) -> String? {
        if storageIncomplete {
            return String(localized: "≥ veut dire « au moins » : une partie de la consommation n'a pas pu être relue.")
        }
        guard unknownCosts > 0 else { return nil }
        return unknownCosts == 1
            ? String(localized: "≥ veut dire « au moins » : le coût d'un appel est inconnu.")
            : String(localized: "≥ veut dire « au moins » : le coût de \(UsageText.count(unknownCosts)) appels est inconnu.")
    }

    /// Part d'un fournisseur dans la dépense de la période.
    struct ProviderShare: Identifiable, Equatable {
        /// Nom enregistré (« xAI », « TypeSafe »…).
        var provider: String
        /// Nom affiché (Jev pour TypeSafe).
        var name: String
        /// Ce qu'il a fait : « voix », « correction », « dictionnaire ».
        var tasks: String
        var cost: Double
        /// « 0,0282 $ », « ≥ 0,00032 $ ».
        var amount: String
        /// Part de la dépense connue, de 0 à 1 (0 quand rien n'a coûté).
        var fraction: Double
        /// « 77 % », « < 1 % » ; vide quand rien n'a coûté.
        var percent: String
        var id: String { provider }
    }

    /// Un fournisseur par ligne, du plus cher au moins cher ; à coût égal, dans l'ordre des API.
    static func providerShares(_ summary: UsageSummary, storageIncomplete: Bool = false) -> [ProviderShare] {
        var order: [String] = []
        for row in summary.rows where !order.contains(row.api.provider) { order.append(row.api.provider) }
        let shares = order.map { provider -> ProviderShare in
            let rows = summary.rows.filter { $0.api.provider == provider }
            let cost = rows.reduce(0) { $0 + $1.costUSD }
            var tasks: [String] = []
            for api in UsageAPI.allCases where rows.contains(where: { $0.api == api }) {
                let task = taskName(api)
                if !tasks.contains(task) { tasks.append(task) }
            }
            let fraction = summary.totalUSD > 0 ? cost / summary.totalUSD : 0
            return ProviderShare(
                provider: provider,
                name: FallbackPresentation.providerName(provider),
                tasks: tasks.joined(separator: ", "),
                cost: cost,
                amount: providerAmount(summary, providers: [provider], storageIncomplete: storageIncomplete),
                fraction: fraction,
                percent: summary.totalUSD > 0 ? percent(fraction) : ""
            )
        }
        return shares.enumerated()
            .sorted { $0.element.cost == $1.element.cost ? $0.offset < $1.offset : $0.element.cost > $1.element.cost }
            .map(\.element)
    }

    /// Ce que fait une API, en un mot.
    static func taskName(_ api: UsageAPI) -> String {
        if api.isAudio { return String(localized: "voix") }
        return api == .typesafeJudge ? String(localized: "dictionnaire") : String(localized: "correction")
    }

    /// « 77 % » ; une part non nulle sous 1 % s'écrit « < 1 % ».
    static func percent(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.005 { return "< " + 0.01.formatted(.percent.precision(.fractionLength(0)).locale(appLocale)) }
        return fraction.formatted(.percent.precision(.fractionLength(0)).locale(appLocale))
    }

    /// « 46 appels · 8,5 min d'audio · grok-voice-transcribe-2.0 », « 46 appels · 54 274 jetons envoyés, 2 341 reçus ·
    /// 1 échec · deepseek-flash ».
    static func rowDetail(_ row: UsageRow) -> String {
        var parts = [calls(row.requests)]
        if row.api.isAudio {
            parts.append(UsageText.audio(row.audioSeconds))
        } else if row.tokens != TokenUsage() {
            parts.append(String(localized: "\(UsageText.count(row.tokens.totalInput)) jetons envoyés, \(UsageText.count(row.tokens.output)) reçus"))
        }
        if row.failures > 0 { parts.append(FailurePresentation.failures(row.failures)) }
        parts.append(row.models.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    /// Titre du graphique, d'après la durée de chaque barre.
    static func chartTitle(_ unit: Calendar.Component) -> String {
        switch unit {
        case .hour: return String(localized: "Dépense par heure")
        case .weekOfYear: return String(localized: "Dépense par semaine")
        case .month: return String(localized: "Dépense par mois")
        default: return String(localized: "Dépense par jour")
        }
    }

    /// Ce que le graphique ne montre pas : les appels au coût inconnu, ou une consommation qui n'a pas pu être relue.
    static func chartNote(unknownCosts: Int, storageIncomplete: Bool) -> String? {
        if storageIncomplete { return String(localized: "Une partie de la consommation n'a pas pu être relue.") }
        guard unknownCosts > 0 else { return nil }
        return unknownCosts == 1
            ? String(localized: "Sans l'appel au coût inconnu.")
            : String(localized: "Sans les \(UsageText.count(unknownCosts)) appels au coût inconnu.")
    }

    /// En une phrase : tout a abouti, ou combien d'appels ont échoué et ce que le relais a rattrapé.
    struct Health: Equatable {
        var level: FallbackPresentation.Level
        var message: String

        var symbol: String { FallbackPresentation.symbol(level) }
        var tint: Color { FallbackPresentation.tint(level) }
    }

    /// Une dictée annulée ou trop courte n'est pas un échec.
    static func health(events: [UsageEvent], fallbacks: FallbackSummary) -> Health {
        let failed = events.filter { !$0.succeeded && $0.failureCause != .cancelled }.count
        if failed == 0 {
            if fallbacks.total > 0 {
                return Health(level: .normal, message: fallbacks.total == 1
                    ? String(localized: "Tous les appels ont abouti, dont 1 grâce au relais.")
                    : String(localized: "Tous les appels ont abouti, dont \(fallbacks.total) grâce au relais."))
            }
            return Health(level: .clear, message: events.count == 1
                ? String(localized: "L'appel a abouti.")
                : String(localized: "Tous les appels ont abouti."))
        }
        let failures = failed == 1
            ? String(localized: "1 appel n'a pas abouti.")
            : String(localized: "\(UsageText.count(failed)) appels n'ont pas abouti.")
        let relays: String
        let level: FallbackPresentation.Level
        if fallbacks.total == 0 {
            relays = String(localized: "Aucun relais n'a pris la suite.")
            level = .watch
        } else if fallbacks.failures == 0 {
            relays = fallbacks.total == 1
                ? String(localized: "Le relais a pris la suite, avec succès.")
                : String(localized: "Le relais a pris la suite \(fallbacks.total) fois, toujours avec succès.")
            level = .normal
        } else {
            relays = String(localized: "Le relais a réussi \(fallbacks.successes) fois sur \(fallbacks.total).")
            level = .watch
        }
        return Health(level: level, message: failures + " " + relays)
    }
}

/// Textes de la carte des relais, tirés des seules données enregistrées.
enum FallbackPresentation {
    enum Level: Equatable { case clear, normal, watch }

    struct Status: Equatable {
        var level: Level
        var title: String
        var message: String

        var symbol: String { FallbackPresentation.symbol(level) }
        var tint: Color { FallbackPresentation.tint(level) }
    }

    static func symbol(_ level: Level) -> String {
        switch level {
        case .clear: return "checkmark.circle.fill"
        case .normal: return "arrow.triangle.branch"
        case .watch: return "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ level: Level) -> Color {
        switch level {
        case .clear: return .green
        case .normal: return .blue
        case .watch: return .orange
        }
    }

    /// Le plus important d'abord : un relais en échec, puis un service mis de côté ; sans relais, des échecs restés
    /// sans secours, sinon tout va bien. `failures` : les échecs de la période, pour le cas sans relais.
    static func status(_ summary: FallbackSummary, failures: FailureBreakdown? = nil) -> Status {
        if summary.total == 0 {
            let failed = failures?.failures ?? 0
            guard failed > 0 else {
                return Status(level: .clear, title: String(localized: "Aucun relais nécessaire"),
                              message: String(localized: "Tes services principaux ont toujours répondu."))
            }
            let offline = failures?.count(.connection) == failed
            return Status(
                level: .watch,
                title: failed == 1 ? String(localized: "1 appel en échec, sans relais")
                    : String(localized: "\(UsageText.count(failed)) appels en échec, sans relais"),
                message: offline
                    ? String(localized: "Ce Mac n'avait pas internet : aucun autre service ne pouvait prendre la suite.")
                    : String(localized: "Aucun autre service n'a pris la suite. Un relais se choisit dans Fournisseurs ; les causes sont ci-dessous.")
            )
        }
        let saved = summary.successes
        if summary.failures > 0 {
            return Status(
                level: .watch,
                title: saved == 0 ? String(localized: "Aucune demande sauvée sur \(summary.total)")
                    : saved == 1 ? String(localized: "1 demande sauvée sur \(summary.total)")
                    : String(localized: "\(UsageText.count(saved)) demandes sauvées sur \(UsageText.count(summary.total))"),
                message: summary.failures == 1
                    ? String(localized: "1 fois, le relais a échoué lui aussi : vérifie ta connexion et tes clés dans Fournisseurs.")
                    : String(localized: "\(summary.failures) fois, le relais a échoué lui aussi : vérifie ta connexion et tes clés dans Fournisseurs.")
            )
        }
        let title = saved == 1 ? String(localized: "1 demande sauvée par le relais")
            : String(localized: "\(UsageText.count(saved)) demandes sauvées par le relais")
        if summary.servicePausedCount > 0 {
            return Status(level: .watch, title: title,
                          message: String(localized: "Un service a échoué plusieurs fois de suite : Wispad l'a mis de côté un moment. Si ça revient souvent, vérifie sa clé ou son état."))
        }
        return Status(level: .normal, title: title,
                      message: String(localized: "Un relais de temps en temps, c'est normal. S'il revient souvent pour le même service, ce service a du mal."))
    }

    static func times(_ count: Int) -> String {
        count == 1 ? String(localized: "1 fois") : String(localized: "\(count) fois")
    }

    /// Étape relayée, en un mot.
    static func stageName(_ stage: FallbackStage) -> String {
        switch stage {
        case .transcription: return String(localized: "Voix")
        case .correction: return String(localized: "Correction")
        case .dictionary: return String(localized: "Dictionnaire")
        }
    }

    static func stageSymbol(_ stage: FallbackStage) -> String {
        switch stage {
        case .transcription: return "waveform"
        case .correction: return "text.badge.checkmark"
        case .dictionary: return "character.book.closed"
        }
    }

    static func meaning(_ stage: FallbackStage) -> String {
        switch stage {
        case .transcription: return String(localized: "Ta voix a été transcrite par l'autre fournisseur.")
        case .correction: return String(localized: "Ton texte a été corrigé par un autre service.")
        case .dictionary: return String(localized: "Un mot corrigé à la main a été vérifié par un autre service avant d'entrer dans le dictionnaire.")
        }
    }

    /// « 3 fois · tous réussis », « 5 fois · 1 en échec ».
    static func outcome(_ route: FallbackRouteSummary) -> String {
        if route.failures == 0 {
            return route.total == 1 ? String(localized: "1 fois · réussi")
                : String(localized: "\(UsageText.count(route.total)) fois · tous réussis")
        }
        return String(localized: "\(times(route.total)) · \(UsageText.count(route.failures)) en échec")
    }

    /// Au-dessus des dernières : « les 5 plus récents sur 10 » quand tous ne sont pas montrés.
    static func recentCaption(shown: Int, total: Int) -> String? {
        guard total > shown else { return nil }
        return String(localized: "les \(shown) plus récents sur \(UsageText.count(total))")
    }

    static func route(from: String, to: String) -> String {
        "\(providerName(from)) → \(providerName(to))"
    }

    static func providerName(_ provider: String) -> String {
        switch provider {
        case "TypeSafe": return "Jev"
        case "Local": return String(localized: "Modèle local")
        default: return provider
        }
    }

    /// Seules deux raisons sont enregistrées : l'appel principal n'a pas abouti (erreur, délai ou coupure,
    /// sans distinction), ou le fournisseur principal était mis de côté après des échecs répétés.
    static func reason(_ reason: FallbackReason) -> String {
        switch reason {
        case .requestFailed: return String(localized: "échec ou délai dépassé")
        case .servicePaused: return String(localized: "principal mis de côté")
        }
    }

    /// Date du début de l'enregistrement des bascules, montrée seulement si la période commence avant.
    static func trackingNoteDate(trackingStartedAt: Date, period: StatsPeriod, now: Date, calendar: Calendar = .current) -> Date? {
        guard let start = period.startDate(now: now, calendar: calendar) else { return trackingStartedAt }
        return start < trackingStartedAt ? trackingStartedAt : nil
    }

    /// Débuts du suivi rappelés en petit : un seul texte quand relais et causes ont commencé le même jour.
    static func trackingNotes(relays: Date?, causes: Date?, calendar: Calendar = .current) -> [String] {
        func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated).year().locale(appLocale)) }
        if let relays, let causes, calendar.isDate(relays, inSameDayAs: causes) {
            return [String(localized: "Relais et causes des échecs notés depuis le \(day(relays)).")]
        }
        var notes: [String] = []
        if let relays { notes.append(String(localized: "Relais notés depuis le \(day(relays)).")) }
        if let causes { notes.append(String(localized: "Causes des échecs notées depuis le \(day(causes)).")) }
        return notes
    }
}

enum UsageText {
    static func audio(_ seconds: Double) -> String {
        let value = seconds < 60 ? seconds : seconds / 60
        let number = value.formatted(.number.precision(.fractionLength(1)).locale(appLocale))
        return seconds < 60 ? String(localized: "\(number) s d'audio") : String(localized: "\(number) min d'audio")
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(appLocale))
    }
}
