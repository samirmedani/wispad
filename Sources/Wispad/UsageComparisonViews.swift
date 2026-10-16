import SwiftUI
import AppKit
import WispadCore

// MARK: - Durée d'utilisation (période « Tout »)

/// « 16 jours », puis au-delà d'un mois « 1 mois et 4 jours », « 1 an, 2 mois et 3 jours ».
enum SpanText {
    static func days(_ count: Int) -> String {
        count == 1 ? String(localized: "1 jour") : String(localized: "\(count) jours")
    }

    static func duration(_ span: UsageSpan) -> String {
        if span.isUnderAMonth { return days(span.days) }
        var parts: [String] = []
        if span.years > 0 { parts.append(span.years == 1 ? String(localized: "1 an") : String(localized: "\(span.years) ans")) }
        if span.months > 0 { parts.append(span.months == 1 ? String(localized: "1 mois") : String(localized: "\(span.months) mois")) }
        if span.remainingDays > 0 { parts.append(days(span.remainingDays)) }
        return parts.formatted(.list(type: .and).locale(appLocale))
    }

    static func since(_ span: UsageSpan) -> String {
        let date = span.firstDay.formatted(.dateTime.day().month(.abbreviated).year().locale(appLocale))
        return String(localized: "Depuis le \(date) · \(duration(span))")
    }
}

/// Sous le sélecteur de période, avec « Tout » : depuis quand et combien de temps.
struct PeriodSpanCaption: View {
    var span: UsageSpan

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar")
                .font(.system(size: 10.5, weight: .medium))
            Text(SpanText.since(span))
                .lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .help(String(localized: "Du premier jour d'utilisation à aujourd'hui, les deux compris."))
    }
}

// MARK: - Coût par mois face aux abonnements

/// Taux et pays de repère du curseur de taxe.
enum TaxText {
    static func percent(_ rate: Double) -> String {
        (rate / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(appLocale))
    }

    /// Drapeau tiré du code pays (lettres régionales Unicode).
    static func flag(_ region: String) -> String {
        String(String.UnicodeScalarView(region.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }

    static func country(_ region: String) -> String {
        "\(flag(region)) \(appLocale.localizedString(forRegionCode: region) ?? region)"
    }

    static func reference(for rate: Double) -> String {
        guard let near = SalesTax.closest(to: rate) else { return String(localized: "Sans taxe") }
        if abs(near.rate - rate) < 0.05 { return String(localized: "Taxe de \(country(near.region))") }
        return String(localized: "Taxe proche de \(country(near.region)) (\(percent(near.rate)))")
    }
}

/// Consommation › Tout : la dépense ramenée à un mois, taxe comprise, face aux abonnements de dictée publics, taxés
/// de la même façon.
struct MonthlyComparisonCard: View {
    @Environment(AppModel.self) private var model
    var totalUSD: Double
    var incomplete: Bool
    var span: UsageSpan
    @State private var draftRate: Double?
    @State private var editing = false

    private var rate: Double { draftRate ?? model.settings.usageTaxRate }

    var body: some View {
        let rate = self.rate
        let monthly = MonthlyCost.withTax(MonthlyCost.perMonth(total: totalUSD, days: span.days), rate: rate)
        let references = SubscriptionReference.all
        let prices = references.map { MonthlyCost.withTax($0.monthlyUSD, rate: rate) }
        let scale = max(prices.max() ?? 1, monthly, 0.0001)
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(String(localized: "Coût par mois, face aux abonnements"))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsagePresentation.amount(monthly, incomplete: incomplete))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("par mois avec Wispad")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text(caption(rate: rate))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 9) {
                ComparisonBar(name: "Wispad", url: nil, price: monthly, scale: scale, tint: Theme.brand,
                              priceText: UsagePresentation.amount(monthly, incomplete: incomplete), ratio: nil)
                ForEach(Array(references.enumerated()), id: \.element.id) { index, reference in
                    ComparisonBar(name: "\(reference.name) \(reference.plan)", url: reference.url, price: prices[index], scale: scale,
                                  tint: Color.secondary.opacity(0.55), priceText: MoneyFormat.usd(prices[index]),
                                  ratio: ratio(prices[index], monthly))
                }
            }
            if let main = references.first {
                savings(name: "\(main.name) \(main.plan)", price: MonthlyCost.withTax(main.monthlyUSD, rate: rate), monthly: monthly)
            }
            Divider()
            taxControl(rate: rate)
            Text(footnote(references))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .animation(Theme.quick, value: rate)
    }

    private func caption(rate: Double) -> String {
        let days = SpanText.days(span.days)
        var text = rate >= 0.05
            ? String(localized: "Moyenne sur \(days) d'utilisation, taxe de \(TaxText.percent(rate)) comprise.")
            : String(localized: "Moyenne sur \(days) d'utilisation, sans taxe.")
        if span.days < 7 { text += " " + String(localized: "L'estimation s'affinera avec les jours.") }
        return text
    }

    /// « 7,8 fois plus cher », « 42 fois plus cher » : seulement quand l'écart est net, au dixième sous 10.
    private func ratio(_ price: Double, _ monthly: Double) -> String? {
        guard monthly > 0, price / monthly >= 1.1 else { return nil }
        let times = price / monthly
        let value = times.formatted(.number.precision(.fractionLength(times < 10 ? 0...1 : 0...0)).locale(appLocale))
        return String(localized: "\(value) fois plus cher")
    }

    @ViewBuilder private func savings(name: String, price: Double, monthly: Double) -> some View {
        let saved = price - monthly
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: saved > 0 ? "leaf.fill" : "info.circle")
                .foregroundStyle(saved > 0 ? Color.green : Color.secondary)
            Group {
                if saved > 0 {
                    let month = MoneyFormat.usd(saved)
                    let year = MoneyFormat.usd(saved * 12)
                    Text(incomplete ? String(localized: "Face à \(name), tu économises jusqu'à \(month) par mois, soit \(year) par an.")
                         : String(localized: "Face à \(name), tu économises environ \(month) par mois, soit \(year) par an."))
                } else {
                    Text("À ce rythme, Wispad te coûte plus cher que \(name).")
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func taxControl(rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Taxes")
                    .font(.system(size: 12.5, weight: .medium))
                Slider(value: Binding(get: { self.rate }, set: { change(SalesTax.snapped($0)) }),
                       in: SalesTax.range, onEditingChanged: editingChanged)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Taxes"))
                    .accessibilityValue(Text(TaxText.percent(rate)))
                Text(TaxText.percent(rate))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
            Text(TaxText.reference(for: rate))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }

    /// Pendant le glissement, la valeur reste locale ; elle est enregistrée au relâchement (ou aussitôt au clavier).
    private func change(_ value: Double) {
        if editing {
            draftRate = value
        } else {
            draftRate = nil
            model.setDisplayChoice(\.usageTaxRate, value)
        }
    }

    private func editingChanged(_ isEditing: Bool) {
        editing = isEditing
        if !isEditing, let value = draftRate {
            model.setDisplayChoice(\.usageTaxRate, value)
            draftRate = nil
        }
    }

    private func footnote(_ references: [SubscriptionReference]) -> String {
        let date = SubscriptionReference.checkedOn.formatted(.dateTime.day().month(.abbreviated).year().locale(appLocale))
        var text = String(localized: "Prix publiés au mois, hors taxes, relevés le \(date) ; la taxe choisie s'y ajoute, comme à tes appels d'API, eux aussi facturés hors taxes.")
        let yearly = references.compactMap { reference in
            reference.yearlyMonthlyUSD.map { "\(reference.name) \(MoneyFormat.usd($0))" }
        }
        if !yearly.isEmpty {
            text += " " + String(localized: "À l'année, par mois et hors taxes : \(yearly.formatted(.list(type: .and).locale(appLocale))).")
        }
        return text
    }
}

private struct ComparisonBar: View {
    var name: String
    var url: URL?
    var price: Double
    var scale: Double
    var tint: Color
    var priceText: String
    var ratio: String?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let url {
                    Link(name, destination: url)
                        .foregroundStyle(.primary)
                        .hoverFeedback()
                        .help(url.absoluteString)
                } else {
                    Text(name).fontWeight(.semibold)
                }
            }
            .font(.system(size: 12.5))
            .lineLimit(1)
            .frame(width: 136, alignment: .leading)
            GeometryReader { proxy in
                let width = max(3, proxy.size.width * min(1, price / scale))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.subtleFill)
                    Capsule().fill(tint).frame(width: width)
                }
            }
            .frame(height: 9)
            Text(priceText)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 82, alignment: .trailing)
            Text(ratio ?? "")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 118, alignment: .trailing)
        }
    }
}

// MARK: - Derniers appels

private enum CallColumns {
    static let time: CGFloat = 86
    static let service: CGFloat = 214
    static let duration: CGFloat = 58
    static let cost: CGFloat = 80
}

/// Textes d'une ligne d'appel : tâche, quantités (jetons en cache à part), durée, bascule et aide au survol.
enum CallText {
    static func task(_ api: UsageAPI) -> String {
        switch api {
        case .xaiStreaming, .openAIStreaming: return String(localized: "Transcription en direct")
        case .xaiFile, .openAIFile: return String(localized: "Transcription du fichier")
        case .deepSeekCleanup, .xaiCleanup, .openAICleanup: return String(localized: "Correction")
        case .typesafeJudge: return String(localized: "Dictionnaire")
        }
    }

    static func quantities(_ event: UsageEvent) -> String {
        guard !event.api.isAudio, event.tokens.cachedInput > 0 else { return UsagePresentation.quantities(event) }
        let input = UsageText.count(event.tokens.input)
        let cached = UsageText.count(event.tokens.cachedInput)
        let output = UsageText.count(event.tokens.output)
        return String(localized: "\(input) + \(cached) en cache → \(output) jetons")
    }

    static func latency(_ milliseconds: Int) -> String {
        guard milliseconds >= 1_000 else { return String(localized: "\(milliseconds) ms") }
        let seconds = (Double(milliseconds) / 1_000).formatted(.number.precision(.fractionLength(2)).locale(appLocale))
        return String(localized: "\(seconds) s")
    }

    /// Secours ou échec, en couleur sous les quantités.
    static func note(_ event: UsageEvent) -> (text: String, tint: Color)? {
        if let fallback = event.fallback {
            let from = FallbackPresentation.providerName(fallback.fromAPI.provider)
            if event.succeeded {
                return (String(localized: "Secours après \(from) · \(FallbackPresentation.reason(fallback.reason))"), .orange)
            }
            return (String(localized: "Secours en échec après \(from)"), .red)
        }
        return event.succeeded ? nil : (String(localized: "Échec"), .red)
    }

    static func help(_ event: UsageEvent) -> String {
        var lines = [event.api.label]
        if let price = PriceText.describe(model: event.model, at: event.createdAt) { lines.append(price) }
        if !event.api.isAudio, event.tokens != TokenUsage() {
            lines.append(String(localized: "Entrée : \(UsageText.count(event.tokens.input)) jetons, en cache : \(UsageText.count(event.tokens.cachedInput)), sortie : \(UsageText.count(event.tokens.output))"))
        }
        lines.append(String(localized: "Durée : \(event.latencyMs) ms"))
        return lines.joined(separator: "\n")
    }
}

/// Tableau des appels : en-têtes, fournisseur en couleur, modèle, jetons, durée, coût ; plus de lignes à la demande.
struct UsageCallsTable: View {
    var events: [UsageEvent]
    var now: Date
    @State private var limit = UsageCallsTable.pageSize

    static let pageSize = 15

    var body: some View {
        let shown = Array(events.prefix(limit))
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: String(localized: "Derniers appels")) {
                Text(String(localized: "\(UsageText.count(shown.count)) sur \(UsageText.count(events.count))"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            VStack(spacing: 2) {
                header
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, event in
                    UsageCallRow(event: event, now: now)
                        .background {
                            if index.isMultiple(of: 2) {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.subtleFill.opacity(0.7))
                            }
                        }
                }
            }
            if events.count > limit {
                Button {
                    withAnimation(Theme.quick) { limit = min(events.count, limit + 30) }
                } label: {
                    Label("Afficher plus", systemImage: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(HoverButtonStyle(treatment: .quiet))
            }
        }
        .padding(16)
        .card()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Heure").frame(width: CallColumns.time, alignment: .leading)
            Text("Service").frame(width: CallColumns.service, alignment: .leading)
            Text("Détail").frame(maxWidth: .infinity, alignment: .leading)
            Text("Durée").frame(width: CallColumns.duration, alignment: .trailing)
            Text("Coût").frame(width: CallColumns.cost, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }
}

private struct UsageCallRow: View {
    var event: UsageEvent
    var now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(event.succeeded ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    if UsagePresentation.showsDate(event.createdAt, now: now) {
                        Text(event.createdAt, format: .dateTime.day().month(.abbreviated).locale(appLocale))
                            .font(.system(size: 10))
                    }
                    Text(event.createdAt, format: .dateTime.hour().minute().second().locale(appLocale))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
            .frame(width: CallColumns.time, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ProviderBadge(provider: event.api.provider)
                    Text(CallText.task(event.api))
                        .lineLimit(1)
                }
                Text(event.model)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: CallColumns.service, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(CallText.quantities(event))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let note = CallText.note(event) {
                    Text(note.text)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(note.tint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(CallText.latency(event.latencyMs))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: CallColumns.duration, alignment: .trailing)
            Text(event.costUSD.map { MoneyFormat.usd($0) } ?? String(localized: "inconnu"))
                .monospacedDigit()
                .frame(width: CallColumns.cost, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(CallText.help(event))
    }
}

/// Nom du fournisseur dans sa couleur (Jev pour TypeSafe).
struct ProviderBadge: View {
    var provider: String

    var body: some View {
        let tint = ProviderTint.color(provider)
        Text(FallbackPresentation.providerName(provider))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

// MARK: - Développeur

/// Liens permanents vers le développeur, en bas de la barre latérale : on sait à qui appartient Wispad et où le joindre.
enum DeveloperProfile {
    static let github = URL(string: "https://github.com/samirmedani")!
    static let x = URL(string: "https://x.com/Mayuu_France")!
}

struct DeveloperLinks: View {
    var body: some View {
        HStack(spacing: 2) {
            link(image: "GitHubMark", url: DeveloperProfile.github, label: String(localized: "Le développeur sur GitHub"))
            link(image: "XMark", url: DeveloperProfile.x, label: String(localized: "Le développeur sur X"))
        }
    }

    private func link(image: String, url: URL, label: String) -> some View {
        let help = "\(label) · \(url.absoluteString)"
        return Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(treatment: .icon))
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(Text(label))
    }
}

