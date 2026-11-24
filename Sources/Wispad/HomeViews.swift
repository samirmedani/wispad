import SwiftUI
import AppKit
import WispadCore

// MARK: - Accueil (Fil continu, sans encadrements)

/// Écran d'ouverture « Fil continu » : zéro carte encadrée. En haut, une seule ligne de synthèse
/// (mots, cadence, temps gagné, coût, mini spectre et bouton Dicter), suivie d'un champ de recherche
/// minimaliste et du fil vivant de tes dictées, directement posé sur la page.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var detailRecord: DictationRecord?
    @FocusState private var searchFocused: Bool

    private var period: StatsPeriod { model.settings.homePeriod }

    var body: some View {
        let snap = model.homeSnapshot(for: period)
        let usage = model.usageSummary(for: period)
        let groups = model.historyDayGroups(query: appliedQuery, filter: nil)
        let blurred = model.settings.blurRecentDictations

        VStack(spacing: 0) {
            // Ruban supérieur de synthèse + recherche, sans aucune boîte.
            VStack(alignment: .leading, spacing: 14) {
                summaryRibbon(snap: snap, spendUSD: usage.totalUSD)
                Rectangle().fill(Theme.cardBorder).frame(height: 1)
                flatSearchBar(blurred: blurred)
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 10)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)

            if groups.isEmpty {
                EmptyState(
                    symbol: appliedQuery.isEmpty ? "waveform" : "magnifyingglass",
                    title: appliedQuery.isEmpty ? String(localized: "Aucune dictée") : String(localized: "Aucun résultat"),
                    message: appliedQuery.isEmpty
                        ? String(localized: "Maintiens la touche du raccourci et parle : ta première dictée apparaîtra ici.")
                        : String(localized: "Aucune dictée ne contient « \(appliedQuery) ».")
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.records) { record in
                                    StreamDictationRow(
                                        record: record,
                                        blurred: blurred,
                                        onCopy: { model.copy(record.finalText) },
                                        onPlay: record.audioPath != nil ? { model.play(record) } : nil,
                                        onDetails: { detailRecord = record }
                                    )
                                    if record.id != group.records.last?.id {
                                        Rectangle()
                                            .fill(Theme.cardBorder)
                                            .frame(height: 1)
                                            .padding(.leading, 56)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(group.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(group.records.count == 1
                                         ? String(localized: "1 dictée")
                                         : String(localized: "\(group.records.count) dictées"))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.top, 16)
                                .padding(.bottom, 6)
                                .background(Theme.canvas)
                            }
                        }
                        shortcutsFootnote
                            .padding(.top, 22)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { HistoryAudioDock() }
        .task(id: query) {
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(HistoryView.searchDelayMilliseconds))
                guard !Task.isCancelled else { return }
            }
            appliedQuery = query
        }
        .sheet(item: $detailRecord) { record in
            DictationDetailView(record: record)
        }
    }

    private func summaryRibbon(snap: HomeSnapshot, spendUSD: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    metricInline(value: "\(snap.summary.words)", label: String(localized: "mots"))
                    metricInline(value: snap.summary.wordsPerMinute.map { "\(Int($0.rounded()))" } ?? "—",
                                 label: String(localized: "m/min"))
                    metricInline(value: DurationFormat.saved(snap.summary.savedSeconds),
                                 label: String(localized: "gagnées"))
                    if spendUSD > 0 {
                        metricInline(value: MoneyFormat.usd(spendUSD), label: "")
                    }
                }
                Spacer(minLength: 8)
                MiniSpectrumBars(bars: snap.bars, peak: snap.peakWords)
                dictateTrigger
            }
            HStack(alignment: .center, spacing: 12) {
                PillPicker(selection: Binding(
                    get: { model.settings.homePeriod },
                    set: { model.setDisplayChoice(\.homePeriod, $0) }
                ))
                if period == .all, let span = snap.span {
                    PeriodSpanCaption(span: span)
                        .transition(.opacity)
                }
                Spacer()
            }
        }
    }

    private func metricInline(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var dictateTrigger: some View {
        let listening: Bool = if case .listening = model.coordinator.phase { true } else { false }
        return Button {
            model.toggleHandsFreeDictation()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.brand)
                    .frame(width: 6.5, height: 6.5)
                Text(listening ? String(localized: "Arrêter") : String(localized: "Dicter"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(listening ? Color.white : Color.primary)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                Capsule().fill(listening ? Theme.brand : Theme.subtleFill)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.coordinator.phase == .starting)
        .animation(reduceMotion ? nil : Theme.quick, value: listening)
        .help(listening ? String(localized: "Terminer la dictée") : String(localized: "Dicter (mains libres)"))
    }

    private func flatSearchBar(blurred: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
            TextField(String(localized: "Rechercher dans les dictées"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Effacer la recherche")
            }
            Button {
                model.settings.blurRecentDictations.toggle()
                model.saveSettings()
            } label: {
                Image(systemName: blurred ? "eye.slash" : "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(blurred ? Color.primary : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(HoverButtonStyle(treatment: .icon))
            .help(blurred ? String(localized: "Afficher le texte") : String(localized: "Flouter le texte"))
        }
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(searchFocused ? Theme.cardBorderStrong : Theme.cardBorder)
                .frame(height: 1)
        }
    }

    private var shortcutsFootnote: some View {
        let key = KeyLabels.describe(keyCode: model.settings.keyCode, modifiers: model.settings.modifierFlags)
        return HStack(spacing: 14) {
            Text("\(key) \(key) · \(String(localized: "Mains libres"))")
            Text("\(key) · \(String(localized: "Parler (maintenu)"))")
            Text("esc · \(String(localized: "Annuler"))")
            Spacer()
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
}

/// Mini spectre des 7 derniers jours dans le ruban du Fil continu : barres fines, aujourd'hui en rouge spectre.
private struct MiniSpectrumBars: View {
    var bars: [HomeSnapshot.BarPoint]
    var peak: Int

    var body: some View {
        let slice = Array(bars.suffix(7))
        let top = max(1, slice.map(\.words).max() ?? peak)
        let lastActive = slice.lastIndex(where: { $0.words > 0 }) ?? (slice.count - 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(slice.enumerated()), id: \.element.id) { index, point in
                let ratio = CGFloat(point.words) / CGFloat(top)
                let height = point.words > 0 ? max(4, 18 * ratio) : 2
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index == lastActive && point.words > 0 ? Theme.brand : Color.primary.opacity(point.words > 0 ? 0.24 : 0.08))
                    .frame(width: 3.5, height: height)
                    .help("\(point.label) : \(point.words)")
            }
        }
        .frame(height: 18, alignment: .bottom)
    }
}

/// Une entrée du Fil continu : heure en chasse fixe à gauche, texte respirant au centre, actions discrètes au survol.
private struct StreamDictationRow: View {
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var copied = false
    var record: DictationRecord
    var blurred: Bool
    var onCopy: () -> Void
    var onPlay: (() -> Void)?
    var onDetails: () -> Void

    var body: some View {
        let item = HistoryRowCache.shared.item(for: record)
        HStack(alignment: .top, spacing: 14) {
            Text(item.time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                RecentDictationText(text: item.text, blurred: blurred)
                HStack(spacing: 6) {
                    Text(item.meta)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.quaternary)
                    Text(item.status.text)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(item.status.tint)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if !item.text.isEmpty {
                    HoverIconButton(symbol: copied ? "checkmark" : "doc.on.doc",
                                    help: copied ? String(localized: "Copié") : String(localized: "Copier"),
                                    tint: copied ? .green : .secondary) {
                        onCopy()
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(1_200))
                            copied = false
                        }
                    }
                }
                if let onPlay {
                    HoverIconButton(symbol: "play.fill", help: String(localized: "Écouter l'audio"), action: onPlay)
                }
                HoverIconButton(symbol: "info.circle", help: String(localized: "Détails de la dictée"), action: onDetails)
            }
            .opacity(hovering || copied ? 1 : 0.35)
            .animation(reduceMotion ? nil : Theme.hover, value: hovering)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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

/// Utilisé par l'écran Profil pour les applications les plus dictées.
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

/// Un composant stable : seul le rayon et l'opacité changent, jamais la place de la ligne.
struct RecentDictationText: View {
    @Environment(\.interactionReduceMotion) private var reduceMotion
    var text: String
    var blurred: Bool

    var body: some View {
        let hidden = blurred && !text.isEmpty
        Text(text.isEmpty ? String(localized: "Audio à retranscrire") : text)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(text.isEmpty ? .secondary : .primary)
            .lineLimit(3)
            // Aucun rectangle ne coupe les contours diffus autour des glyphes.
            .blur(radius: hidden ? 6 : 0, opaque: false)
            .opacity(hidden ? 0.58 : 1)
            .animation(reduceMotion ? nil : Theme.privacy, value: hidden)
            .accessibilityHidden(hidden)
    }
}
