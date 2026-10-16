import SwiftUI
import AppKit
import Charts
import WispadCore

// MARK: - Accueil

struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var period: StatsPeriod { model.settings.homePeriod }

    var body: some View {
        let summary = StatsCalculator.summary(
            samples: model.samples(for: period),
            typingWordsPerMinute: model.settings.typingWPM
        )
        let records = model.records(in: period)
        let span = model.history.last.map { UsageSpan.make(firstUse: $0.createdAt, now: Date()) }
        ScreenScroll {
            ScreenHeader(title: greeting, subtitle: String(localized: "Ton activité de dictée en un coup d'œil.")) {
                VStack(alignment: .trailing, spacing: 6) {
                    PillPicker(selection: Binding(
                        get: { model.settings.homePeriod },
                        set: { model.setDisplayChoice(\.homePeriod, $0) }
                    ))
                    if period == .all, let span {
                        PeriodSpanCaption(span: span)
                            .transition(.opacity)
                    }
                }
            }
            ActivityCard(summary: summary, records: records, period: period)
            MetricGrid {
                MetricTile(symbol: "speedometer", tint: .blue, title: String(localized: "Mots / minute"),
                           value: summary.wordsPerMinute.map { "\(Int($0.rounded()))" } ?? "—")
                MetricTile(symbol: "waveform", tint: .purple, title: String(localized: "Temps de dictée"),
                           value: DurationFormat.audio(summary.audioSeconds))
                MetricTile(symbol: "text.bubble", tint: .orange, title: String(localized: "Dictées"),
                           value: "\(summary.sessions)")
                MetricTile(symbol: "bolt", tint: .green, title: String(localized: "Temps économisé"),
                           value: DurationFormat.saved(summary.savedSeconds))
            }
            HStack(alignment: .top, spacing: 12) {
                AppsCard(records: records)
                RecentCard()
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Le temps économisé compare la dictée à une frappe à \(Int(model.settings.typingWPM)) mots par minute.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return (5..<18).contains(hour) ? String(localized: "Bonjour") : String(localized: "Bonsoir")
    }
}

struct ActivityCard: View {
    var summary: StatsSummary
    var records: [DictationRecord]
    var period: StatsPeriod

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mots dictés")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(summary.words)")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(summary.words)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(summary.sessions == 0 ? String(localized: "Aucune dictée")
                     : summary.sessions == 1 ? String(localized: "en 1 dictée") : String(localized: "en \(summary.sessions) dictées"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
            }
            .frame(width: 150, alignment: .leading)
            ActivityChart(records: records, period: period)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 150)
        .padding(18)
        .card()
    }
}

/// Découpage temporel commun aux graphiques : heures, jours, semaines ou mois selon la période.
struct TimeAxis {
    var unit: Calendar.Component
    var starts: [Date]
    private let calendar: Calendar

    init(period: StatsPeriod, earliest: Date?, now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        let start: Date
        let end: Date
        switch period {
        case .today:
            unit = .hour
            start = calendar.startOfDay(for: now)
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        case .days7, .days30:
            unit = .day
            start = calendar.startOfDay(for: period.startDate(now: now, calendar: calendar) ?? now)
            end = now
        case .all:
            let first = earliest ?? now
            let days = calendar.dateComponents([.day], from: first, to: now).day ?? 0
            unit = days > 120 ? .month : (days > 45 ? .weekOfYear : .day)
            start = calendar.dateInterval(of: unit, for: first)?.start ?? first
            end = now
        }
        var cursor = calendar.dateInterval(of: unit, for: start)?.start ?? start
        var starts: [Date] = []
        while cursor < end, starts.count < 400 {
            starts.append(cursor)
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor) else { break }
            cursor = next
        }
        self.starts = starts
    }

    func bucket(of date: Date) -> Date? {
        calendar.dateInterval(of: unit, for: date)?.start
    }

    var labelFormat: Date.FormatStyle {
        let style: Date.FormatStyle
        switch unit {
        case .hour: style = .dateTime.hour()
        case .month: style = .dateTime.month(.abbreviated)
        default: style = starts.count <= 8 ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated)
        }
        return style.locale(appLocale)
    }

    var labelCount: Int {
        unit == .hour ? 6 : min(starts.count, 7)
    }
}

struct ActivityChart: View {
    var records: [DictationRecord]
    var period: StatsPeriod

    private struct Point: Identifiable {
        var date: Date
        var words: Int
        var id: Date { date }
    }

    var body: some View {
        let axis = TimeAxis(period: period, earliest: records.last?.createdAt)
        var totals: [Date: Int] = [:]
        for record in records {
            if let key = axis.bucket(of: record.createdAt) { totals[key, default: 0] += record.wordCount }
        }
        let points = axis.starts.map { Point(date: $0, words: totals[$0] ?? 0) }
        return Group {
            if records.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("Aucune dictée sur cette période.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtleFill.opacity(0.6)))
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Période", point.date, unit: axis.unit),
                        y: .value("Mots", point.words)
                    )
                    .foregroundStyle(Theme.brand.gradient)
                    .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: axis.labelCount)) { _ in
                        AxisValueLabel(format: axis.labelFormat)
                    }
                }
                .environment(\.locale, appLocale)
            }
        }
        .animation(Theme.spring, value: period)
    }
}

struct AppsCard: View {
    var records: [DictationRecord]

    private struct AppCount: Identifiable {
        var id: String
        var name: String
        var bundleID: String?
        var count: Int
    }

    var body: some View {
        let apps = top
        let maximum = max(1, apps.first?.count ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(String(localized: "Applications"))
            if apps.isEmpty {
                Text("Aucune dictée sur cette période.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps) { app in
                    HStack(spacing: 10) {
                        AppIconView(bundleID: app.bundleID, size: 22)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(app.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(app.count)")
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Theme.subtleFill)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(Theme.brand.opacity(0.8))
                                            .frame(width: max(4, proxy.size.width * CGFloat(app.count) / CGFloat(maximum)))
                                    }
                            }
                            .frame(height: 4)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var top: [AppCount] {
        var counts: [String: AppCount] = [:]
        for record in records {
            let key = record.targetBundle ?? record.targetApp ?? "?"
            if counts[key] == nil {
                counts[key] = AppCount(id: key, name: record.targetApp ?? String(localized: "Application inconnue"), bundleID: record.targetBundle, count: 0)
            }
            counts[key]?.count += 1
        }
        return counts.values
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
            .prefix(5)
            .map { $0 }
    }
}

struct RecentCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion

    var body: some View {
        let recent = Array(model.history.prefix(3))
        let blurred = model.settings.blurRecentDictations
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: String(localized: "Dernières dictées")) {
                Button {
                    model.settings.blurRecentDictations.toggle()
                    model.saveSettings()
                } label: {
                    Image(systemName: blurred ? "eye.slash" : "eye")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .animation(reduceMotion ? nil : Theme.privacy, value: blurred)
                        .frame(width: 26, height: 26)
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(blurred ? Theme.brand : Color.secondary)
                .buttonStyle(HoverButtonStyle(treatment: .icon))
                .help(blurred ? String(localized: "Afficher le texte") : String(localized: "Flouter le texte"))
                .accessibilityLabel(blurred ? String(localized: "Afficher les dernières dictées") : String(localized: "Flouter les dernières dictées"))
                .accessibilityValue(blurred ? String(localized: "Texte masqué") : String(localized: "Texte visible"))
                Button {
                    model.selectedSection = .history
                } label: {
                    Text("Tout voir")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.brand)
                }
                .buttonStyle(HoverButtonStyle())
                .disabled(recent.isEmpty)
            }
            if recent.isEmpty {
                Text("Maintiens la touche du raccourci et parle : ta première dictée apparaîtra ici.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(recent) { record in
                VStack(alignment: .leading, spacing: 3) {
                    RecentDictationText(text: record.finalText, blurred: blurred)
                    Text("\(record.createdAt.formatted(.relative(presentation: .named).locale(appLocale))) · \(record.targetApp ?? "—")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if record.id != recent.last?.id { Divider() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

/// Un composant stable : seul le rayon et l'opacité changent, jamais la place de la ligne.
struct RecentDictationText: View {
    @Environment(\.interactionReduceMotion) private var reduceMotion
    var text: String
    var blurred: Bool

    var body: some View {
        let hidden = blurred && !text.isEmpty
        Text(text.isEmpty ? String(localized: "Audio à retranscrire") : text)
            .font(.system(size: 12.5))
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .lineLimit(2)
            // Aucun rectangle ne coupe les contours diffus autour des glyphes.
            .blur(radius: hidden ? 6 : 0, opaque: false)
            .opacity(hidden ? 0.58 : 1)
            .animation(reduceMotion ? nil : Theme.privacy, value: hidden)
            .padding(.vertical, 2)
            .accessibilityHidden(hidden)
    }
}
