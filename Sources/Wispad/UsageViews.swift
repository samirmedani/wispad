import SwiftUI
import AppKit
import Charts
import WispadCore

// MARK: - Consommation

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var refreshing = false

    private var period: StatsPeriod { model.settings.usagePeriod }

    var body: some View {
        let now = Date()
        let events = model.usageEvents(for: period, now: now)
        let summary = UsageSummary.make(events: events, period: .all, now: now)
        let incomplete = summary.hasUnpricedCalls || model.usageLoadFailed
        ScreenScroll {
            ScreenHeader(title: String(localized: "Consommation"), subtitle: String(localized: "Coûts des API et recours aux relais.")) {
                PillPicker(selection: Binding(
                    get: { model.settings.usagePeriod },
                    set: { model.setDisplayChoice(\.usagePeriod, $0) }
                ))
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
            MetricGrid {
                MetricTile(symbol: "dollarsign", tint: Theme.brand,
                           title: incomplete ? String(localized: "Total (minimum)") : String(localized: "Total estimé"),
                           value: UsagePresentation.amount(summary.totalUSD, incomplete: incomplete))
                MetricTile(symbol: "waveform", tint: ProviderTint.color("xAI"), title: "xAI",
                           value: UsagePresentation.providerAmount(summary, providers: ["xAI"], storageIncomplete: model.usageLoadFailed))
                MetricTile(symbol: "text.badge.checkmark", tint: ProviderTint.color("DeepSeek"), title: "DeepSeek",
                           value: UsagePresentation.providerAmount(summary, providers: ["DeepSeek"], storageIncomplete: model.usageLoadFailed))
                MetricTile(symbol: "arrow.triangle.branch", tint: ProviderTint.color("OpenAI"), title: String(localized: "OpenAI et Jev"),
                           value: UsagePresentation.providerAmount(summary, providers: ["OpenAI", "TypeSafe"], storageIncomplete: model.usageLoadFailed))
            }
            if summary.hasUnpricedCalls {
                Text("Les montants précédés de ≥ sont des minimums : le coût de certains appels est inconnu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            FallbackStatsCard(period: period)
            if summary.rows.isEmpty {
                EmptyState(symbol: "chart.bar", title: String(localized: "Aucun appel API"), message: String(localized: "Aucun appel enregistré sur cette période."))
                    .card()
            } else {
                SpendChart(events: events, period: period, storageIncomplete: model.usageLoadFailed)
                VStack(alignment: .leading, spacing: 4) {
                    CardTitle(String(localized: "Par API"))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    ForEach(summary.rows) { row in
                        UsageRowView(row: row)
                        if row.id != summary.rows.last?.id { Divider().padding(.leading, 56) }
                    }
                }
                .padding(.bottom, 6)
                .card()
            }
            balances
            if !events.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(String(localized: "Derniers appels"))
                    VStack(spacing: 0) {
                        ForEach(events.prefix(15)) { event in
                            UsageEventLine(event: event, now: now)
                        }
                    }
                }
                .padding(16)
                .card()
            }
            Text("Coûts estimés d'après les tarifs publiés de chaque modèle (au survol d'une ligne « Par API »). La facture du fournisseur fait foi.")
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
                        } else if let balance = model.xaiBalance {
                            Text(balance)
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
            if model.xaiAccount != nil, model.xaiBalance == nil {
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

/// Bascules vers un fournisseur de secours, lues dans les appels enregistrés, jamais déduites du nom du fournisseur final.
struct FallbackStatsCard: View {
    @Environment(AppModel.self) private var model
    var period: StatsPeriod

    var body: some View {
        let now = Date()
        let summary = model.fallbackSummary(for: period, now: now)
        let status = FallbackPresentation.status(summary)
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: String(localized: "Bascules vers un fournisseur de secours")) {
                if summary.total > 0 {
                    Text(FallbackPresentation.count(summary.total))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Quand ton fournisseur principal échoue, ne répond pas à temps ou a été mis de côté après des échecs, Wispad envoie la même demande à un autre fournisseur pour que ta dictée aboutisse.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                Text(status.message)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if summary.total > 0 {
                Divider()
                ForEach(FallbackStage.allCases.filter { summary.count(for: $0) > 0 }, id: \.rawValue) { stage in
                    stageLine(stage, summary: summary)
                }
                Divider()
                Text("Dernières bascules")
                    .font(.system(size: 12, weight: .semibold))
                VStack(spacing: 0) {
                    ForEach(summary.recent) { entry in
                        entryLine(entry, now: now)
                    }
                }
            }
            if let start = FallbackPresentation.trackingNoteDate(trackingStartedAt: model.store.fallbackTrackingStartedAt, period: period, now: now) {
                Text("Bascules enregistrées depuis le \(start.formatted(.dateTime.day().month(.abbreviated).year().locale(appLocale))).")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func stageLine(_ stage: FallbackStage, summary: FallbackSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(stage.label).font(.system(size: 12.5, weight: .semibold))
                Text(FallbackPresentation.times(summary.count(for: stage)))
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                Text(FallbackPresentation.routes(summary, stage: stage))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Text(FallbackPresentation.meaning(stage))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func entryLine(_ entry: FallbackEntry, now: Date) -> some View {
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
            Text(entry.stage.label)
                .frame(width: 92, alignment: .leading)
            Text(FallbackPresentation.route(from: entry.fromProvider, to: entry.toProvider))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(FallbackPresentation.reason(entry.reason))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(entry.succeeded ? String(localized: "secours réussi") : String(localized: "secours en échec"))
                .foregroundStyle(entry.succeeded ? Color.green : Color.orange)
                .frame(minWidth: 100, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 4)
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
            CardTitle(title: unknownCosts > 0 || storageIncomplete ? String(localized: "Dépense connue (minimum)") : String(localized: "Dépense estimée")) {
                HStack(spacing: 12) {
                    ForEach(providers, id: \.self) { name in
                        HStack(spacing: 5) {
                            Circle().fill(ProviderTint.color(name)).frame(width: 7, height: 7)
                            Text(name).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if unknownCosts > 0 {
                Text(unknownCosts == 1 ? String(localized: "1 appel au coût inconnu non inclus dans le graphique.")
                     : String(localized: "\(unknownCosts) appels au coût inconnu non inclus dans le graphique."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

struct UsageRowView: View {
    var row: UsageRow

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(symbol: row.api.isAudio ? "waveform" : "text.badge.checkmark", tint: ProviderTint.color(row.api.provider), size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.api.label).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(UsagePresentation.amount(row.costUSD, incomplete: row.hasUnpricedCalls))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .help(row.models.compactMap { PriceText.describe(model: $0) }.joined(separator: "\n"))
    }

    private var detail: String {
        var parts = [row.requests == 1 ? String(localized: "1 appel") : String(localized: "\(row.requests) appels")]
        if row.api.isAudio {
            parts.append(UsageText.audio(row.audioSeconds))
        } else {
            parts.append(String(localized: "\(UsageText.count(row.tokens.totalInput)) jetons en entrée"))
            parts.append(String(localized: "\(UsageText.count(row.tokens.output)) en sortie"))
        }
        if row.failures > 0 { parts.append(row.failures == 1 ? String(localized: "1 échec") : String(localized: "\(row.failures) échecs")) }
        parts.append(row.models.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }
}

struct UsageEventLine: View {
    var event: UsageEvent
    var now: Date = Date()

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(event.succeeded ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                if UsagePresentation.showsDate(event.createdAt, now: now) {
                    Text(event.createdAt, format: .dateTime.day().month(.abbreviated).year().locale(appLocale))
                        .font(.system(size: 10))
                }
                Text(event.createdAt, format: .dateTime.hour().minute().second())
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .frame(width: 78, alignment: .leading)
            Text(event.api.label)
                .lineLimit(1)
            Text(UsagePresentation.quantities(event))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(event.latencyMs) ms")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(event.costUSD.map { MoneyFormat.usd($0) } ?? String(localized: "coût inconnu"))
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 5)
    }
}

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
}

/// Textes de la carte des bascules, tirés des seules données enregistrées.
enum FallbackPresentation {
    enum Level: Equatable { case clear, normal, watch }

    struct Status: Equatable {
        var level: Level
        var message: String

        var symbol: String {
            switch level {
            case .clear: return "checkmark.circle.fill"
            case .normal: return "arrow.triangle.branch"
            case .watch: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch level {
            case .clear: return .green
            case .normal: return .secondary
            case .watch: return .orange
            }
        }
    }

    /// Le plus important d'abord : un secours en échec, puis un fournisseur mis de côté, sinon tout va bien.
    static func status(_ summary: FallbackSummary) -> Status {
        if summary.total == 0 {
            return Status(level: .clear, message: String(localized: "Aucune bascule : tes fournisseurs principaux ont toujours répondu."))
        }
        if summary.failures > 0 {
            return Status(level: .watch, message: summary.failures == 1
                ? String(localized: "Le fournisseur de secours a lui aussi échoué 1 fois. Vérifie ta connexion et tes clés dans Fournisseurs.")
                : String(localized: "Le fournisseur de secours a lui aussi échoué \(summary.failures) fois. Vérifie ta connexion et tes clés dans Fournisseurs."))
        }
        if summary.servicePausedCount > 0 {
            return Status(level: .watch, message: String(localized: "Le secours a toujours pris le relais, mais un fournisseur principal a échoué plusieurs fois de suite et a été mis de côté un moment. Si cela revient souvent, vérifie sa clé ou son état."))
        }
        return Status(level: .normal, message: String(localized: "Le secours a pris le relais à chaque fois. Une bascule de temps en temps est normale ; des bascules fréquentes sur une même étape signalent un fournisseur en difficulté."))
    }

    static func count(_ total: Int) -> String {
        total == 1 ? String(localized: "1 bascule") : String(localized: "\(total) bascules")
    }

    static func times(_ count: Int) -> String {
        count == 1 ? String(localized: "1 fois") : String(localized: "\(count) fois")
    }

    static func meaning(_ stage: FallbackStage) -> String {
        switch stage {
        case .transcription: return String(localized: "Ta voix a été transcrite par l'autre fournisseur.")
        case .correction: return String(localized: "Ton texte a été corrigé par un autre service.")
        case .dictionary: return String(localized: "Un mot corrigé à la main a été vérifié par un autre service avant d'entrer dans le dictionnaire.")
        }
    }

    /// « xAI → OpenAI », ou chaque sens avec son nombre quand l'étape en a plusieurs.
    static func routes(_ summary: FallbackSummary, stage: FallbackStage) -> String {
        let routes = summary.routes.filter { $0.stage == stage }
        if routes.count == 1, let only = routes.first { return route(from: only.fromProvider, to: only.toProvider) }
        return routes.map { "\(route(from: $0.fromProvider, to: $0.toProvider)) (\($0.total))" }.joined(separator: ", ")
    }

    static func route(from: String, to: String) -> String {
        "\(providerName(from)) → \(providerName(to))"
    }

    static func providerName(_ provider: String) -> String {
        provider == "TypeSafe" ? "Jev" : provider
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
