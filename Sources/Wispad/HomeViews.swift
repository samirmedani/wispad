import SwiftUI
import AppKit
import WispadCore

// MARK: - Accueil

struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var period: StatsPeriod { model.settings.homePeriod }

    var body: some View {
        let snap = model.homeSnapshot(for: period)
        ScreenScroll {
            ScreenHeader(title: greeting, subtitle: String(localized: "Ton activité de dictée en un coup d'œil.")) {
                VStack(alignment: .trailing, spacing: 5) {
                    PillPicker(selection: Binding(
                        get: { model.settings.homePeriod },
                        set: { model.setDisplayChoice(\.homePeriod, $0) }
                    ))
                    if period == .all, let span = snap.span {
                        PeriodSpanCaption(span: span)
                            .transition(.opacity)
                    }
                }
            }
            ActivityCard(snapshot: snap, period: period)
            HStack(alignment: .top, spacing: 12) {
                RecentCard()
                AppsCard(shares: snap.topApps)
            }
            .fixedSize(horizontal: false, vertical: true)
            ShortcutCard()
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

/// Panneau principal unifié façon T3 Code : compteur + barres monochromes en haut, 4 indicateurs séparés par
/// des filets fins en bas, sans aucun titre tronqué ni graphe lourd.
struct ActivityCard: View {
    var snapshot: HomeSnapshot
    var period: StatsPeriod

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mots dictés")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(snapshot.summary.words)")
                        .font(.system(size: 38, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(snapshot.summary.words)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text(snapshot.summary.sessions == 0 ? String(localized: "Aucune dictée")
                         : snapshot.summary.sessions == 1 ? String(localized: "en 1 dictée")
                         : String(localized: "en \(snapshot.summary.sessions) dictées"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                }
                .frame(width: 158, alignment: .leading)
                ActivityChart(bars: snapshot.bars, peak: snapshot.peakWords, empty: snapshot.recordsCount == 0, period: period)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 126)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

            Divider().overlay(Theme.cardBorder)

            HStack(spacing: 0) {
                kpiCell(title: String(localized: "Mots / minute"),
                        value: snapshot.summary.wordsPerMinute.map { "\(Int($0.rounded()))" } ?? "—")
                kpiDivider
                kpiCell(title: String(localized: "Temps de dictée"),
                        value: DurationFormat.audio(snapshot.summary.audioSeconds))
                kpiDivider
                kpiCell(title: String(localized: "Temps économisé"),
                        value: DurationFormat.saved(snapshot.summary.savedSeconds))
                kpiDivider
                kpiCell(title: String(localized: "Dictées"),
                        value: "\(snapshot.summary.sessions)")
            }
            .background(Theme.canvas.opacity(0.65))
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .card()
    }

    private var kpiDivider: some View {
        Rectangle()
            .fill(Theme.cardBorder)
            .frame(width: 1)
    }

    private func kpiCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

/// Histogramme monochrome léger en SwiftUI pur : rendu instantané, sans latence de mise en page Charts.
struct ActivityChart: View {
    var bars: [HomeSnapshot.BarPoint]
    var peak: Int
    var empty: Bool
    var period: StatsPeriod

    var body: some View {
        Group {
            if empty || bars.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                    Text("Aucune dictée sur cette période.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill.opacity(0.6)))
            } else {
                let top = max(1, peak)
                let labelStride = bars.count <= 8 ? 1 : max(1, Int((Double(bars.count) / 7.0).rounded(.up)))
                let lastActiveIndex = bars.lastIndex(where: { $0.words > 0 }) ?? (bars.count - 1)
                VStack(spacing: 6) {
                    GeometryReader { proxy in
                        let maxHeight = max(12, proxy.size.height - 4)
                        ZStack(alignment: .bottom) {
                            // Repère médian discret.
                            Rectangle()
                                .fill(Theme.cardBorder)
                                .frame(height: 1)
                                .offset(y: -maxHeight * 0.5)
                            HStack(alignment: .bottom, spacing: bars.count > 16 ? 3 : 7) {
                                ForEach(Array(bars.enumerated()), id: \.element.id) { index, point in
                                    let ratio = CGFloat(point.words) / CGFloat(top)
                                    let barHeight = point.words > 0 ? max(4, maxHeight * ratio) : 2
                                    let highlighted = index == lastActiveIndex && point.words > 0
                                    RoundedRectangle(cornerRadius: bars.count > 16 ? 2 : 3.5, style: .continuous)
                                        .fill(highlighted ? Color.primary : Color.primary.opacity(point.words > 0 ? 0.2 : 0.06))
                                        .frame(maxWidth: 28, minHeight: barHeight, maxHeight: barHeight)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                        .help("\(point.label) : \(point.words)")
                                }
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(Array(bars.enumerated()), id: \.element.id) { index, point in
                            if index % labelStride == 0 || index == bars.count - 1 {
                                Text(point.label)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(index == lastActiveIndex ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            } else if bars.count <= 10 {
                                Spacer(minLength: 0).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .animation(Theme.quick, value: period)
    }
}

struct AppsCard: View {
    var shares: [HomeSnapshot.AppShare]

    init(shares: [HomeSnapshot.AppShare]) {
        self.shares = shares
    }

    init(records: [DictationRecord]) {
        var counts: [String: HomeSnapshot.AppShare] = [:]
        for record in records {
            let key = record.targetBundle ?? record.targetApp ?? "?"
            if counts[key] == nil {
                counts[key] = HomeSnapshot.AppShare(
                    id: key,
                    name: record.targetApp ?? String(localized: "Application inconnue"),
                    bundleID: record.targetBundle,
                    count: 0
                )
            }
            counts[key]?.count += 1
        }
        shares = counts.values
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        let maximum = max(1, shares.first?.count ?? 1)
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(String(localized: "Applications"))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider().overlay(Theme.cardBorder)
            VStack(alignment: .leading, spacing: 11) {
                if shares.isEmpty {
                    Text("Aucune dictée sur cette période.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shares) { app in
                        HStack(spacing: 9) {
                            AppIconView(bundleID: app.bundleID, size: 18)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(app.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(app.count)")
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(Theme.subtleFill)
                                        .overlay(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.primary.opacity(0.68))
                                                .frame(width: max(4, proxy.size.width * CGFloat(app.count) / CGFloat(maximum)))
                                        }
                                }
                                .frame(height: 3)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

struct RecentCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion

    var body: some View {
        let recent = Array(model.history.prefix(3))
        let blurred = model.settings.blurRecentDictations
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(title: String(localized: "Dernières dictées")) {
                HStack(spacing: 6) {
                    Button {
                        model.settings.blurRecentDictations.toggle()
                        model.saveSettings()
                    } label: {
                        Image(systemName: blurred ? "eye.slash" : "eye")
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .animation(reduceMotion ? nil : Theme.privacy, value: blurred)
                            .frame(width: 24, height: 24)
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(blurred ? Color.primary : Color.secondary)
                    .buttonStyle(HoverButtonStyle(treatment: .icon))
                    .help(blurred ? String(localized: "Afficher le texte") : String(localized: "Flouter le texte"))
                    .accessibilityLabel(blurred ? String(localized: "Afficher les dernières dictées") : String(localized: "Flouter les dernières dictées"))
                    .accessibilityValue(blurred ? String(localized: "Texte masqué") : String(localized: "Texte visible"))
                    Button {
                        model.selectedSection = .history
                    } label: {
                        Text("Tout voir")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(HoverButtonStyle())
                    .disabled(recent.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider().overlay(Theme.cardBorder)
            VStack(alignment: .leading, spacing: 0) {
                if recent.isEmpty {
                    Text("Maintiens la touche du raccourci et parle : ta première dictée apparaîtra ici.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
                ForEach(recent) { record in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            RecentDictationText(text: record.finalText, blurred: blurred)
                            Text("\(record.createdAt.formatted(.relative(presentation: .named).locale(appLocale))) · \(record.targetApp ?? "—")")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if !record.finalText.isEmpty {
                            HoverIconButton(symbol: "doc.on.doc", help: String(localized: "Copier")) {
                                model.copy(record.finalText)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if record.id != recent.last?.id { Divider().overlay(Theme.cardBorder) }
                }
            }
        }
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
            .font(.system(size: 12))
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .lineLimit(2)
            // Aucun rectangle ne coupe les contours diffus autour des glyphes.
            .blur(radius: hidden ? 6 : 0, opaque: false)
            .opacity(hidden ? 0.58 : 1)
            .animation(reduceMotion ? nil : Theme.privacy, value: hidden)
            .padding(.vertical, 1)
            .accessibilityHidden(hidden)
    }
}
