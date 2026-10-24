import SwiftUI
import AppKit
import WispadCore

// MARK: - Profil

/// Profil : ce que tes dictées disent de toi. Chiffres clés, rythme, vocabulaire, tics, corrections, et le cerveau,
/// un nuage 3D des mots qui reviennent ensemble. Tout est calculé sur ce Mac.
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var data: ProfileData?
    @State private var selectedWord: Int?

    struct ProfileData: Equatable {
        var profile: DictationProfile
        var graph: WordGraph
    }

    private struct Key: Hashable {
        var period: StatsPeriod
        var count: Int
        var newest: String?
        var hidden: [String]
    }

    private var period: StatsPeriod { model.settings.profilePeriod }
    private var hidden: Set<String> { Set(model.settings.profileHiddenWords) }

    var body: some View {
        let records = model.records(in: period)
        let summary = StatsCalculator.summary(samples: model.samples(for: period), typingWordsPerMinute: model.settings.typingWPM)
        ScreenScroll {
            ScreenHeader(title: String(localized: "Profil"),
                         subtitle: String(localized: "Ce que tes dictées disent de toi. Calculé sur ce Mac, rien n'est envoyé.")) {
                PillPicker(selection: Binding(
                    get: { model.settings.profilePeriod },
                    set: { model.setDisplayChoice(\.profilePeriod, $0) }
                ))
            }
            if let data, data.profile.dictations > 0 {
                ProfileHeadline(profile: data.profile, savedSeconds: summary.savedSeconds)
                HStack(alignment: .top, spacing: 12) {
                    RhythmCard(profile: data.profile)
                    DaysCard(profile: data.profile)
                }
                .fixedSize(horizontal: false, vertical: true)
                BrainSection(wordGraph: data.graph, profile: data.profile, selected: $selectedWord, hide: hide)
                WordsCard(words: data.profile.topWords, hide: hide)
                HStack(alignment: .top, spacing: 12) {
                    TicsCard(tics: data.profile.tics)
                    FixesCard(fixes: data.profile.fixes)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 12) {
                    LanguagesCard(profile: data.profile)
                    AppsCard(records: records)
                }
                .fixedSize(horizontal: false, vertical: true)
                HiddenWordsFooter(words: model.settings.profileHiddenWords) { word in
                    model.setDisplayChoice(\.profileHiddenWords, model.settings.profileHiddenWords.filter { $0 != word })
                }
            } else if data != nil {
                ContentUnavailableView(String(localized: "Pas encore de dictée"),
                                       systemImage: "brain.head.profile",
                                       description: Text("Ton profil se remplit au fil de tes dictées."))
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        .task(id: Key(period: period, count: records.count, newest: records.first?.id, hidden: model.settings.profileHiddenWords)) {
            let hidden = self.hidden
            let computed = await Task.detached(priority: .userInitiated) {
                ProfileData(profile: ProfileBuilder.build(records: records, hidden: hidden),
                            graph: WordGraph.build(records: records, hidden: hidden))
            }.value
            if computed.graph.nodes.indices.contains(selectedWord ?? -1) == false { selectedWord = nil }
            data = computed
        }
    }

    private func hide(_ word: String) {
        guard !model.settings.profileHiddenWords.contains(word) else { return }
        selectedWord = nil
        model.setDisplayChoice(\.profileHiddenWords, model.settings.profileHiddenWords + [word])
    }
}

// MARK: Chiffres clés

private struct ProfileHeadline: View {
    var profile: DictationProfile
    var savedSeconds: Double

    var body: some View {
        MetricGrid {
            MetricTile(symbol: "text.word.spacing", tint: Theme.brand, title: String(localized: "Mots dictés"),
                       value: profile.words.formatted(.number.locale(appLocale)))
            MetricTile(symbol: "book.closed", tint: .orange, title: String(localized: "Soit"), value: equivalent)
            MetricTile(symbol: "bolt", tint: .green, title: String(localized: "Temps économisé"),
                       value: DurationFormat.saved(savedSeconds))
            MetricTile(symbol: "speedometer", tint: .blue, title: String(localized: "Mots / minute"),
                       value: profile.wordsPerMinute.map { "\(Int($0.rounded()))" } ?? "—")
        }
        MetricGrid {
            MetricTile(symbol: "flame", tint: .red, title: String(localized: "Série en cours"),
                       value: days(profile.currentStreak))
            MetricTile(symbol: "trophy", tint: .yellow, title: String(localized: "Meilleure série"),
                       value: days(profile.bestStreak))
            MetricTile(symbol: "calendar", tint: .purple, title: String(localized: "Jours actifs"),
                       value: "\(profile.activeDays)")
            MetricTile(symbol: "text.alignleft", tint: .teal, title: String(localized: "Plus longue dictée"),
                       value: profile.longest.map { String(localized: "\($0.words) mots") } ?? "—")
        }
    }

    /// Un roman fait environ 80 000 mots, une page environ 250.
    private var equivalent: String {
        let novels = Double(profile.words) / 80_000
        if novels >= 0.5 {
            return String(localized: "\(novels.formatted(.number.precision(.fractionLength(1)).locale(appLocale))) romans")
        }
        let pages = max(1, Int((Double(profile.words) / 250).rounded()))
        return pages == 1 ? String(localized: "1 page") : String(localized: "\(pages) pages")
    }

    private func days(_ count: Int) -> String {
        count == 1 ? String(localized: "1 jour") : String(localized: "\(count) jours")
    }
}

// MARK: Rythme

private struct RhythmCard: View {
    var profile: DictationProfile

    var body: some View {
        let peakHour = profile.byHour.indices.max { profile.byHour[$0] < profile.byHour[$1] } ?? 0
        let peakDay = profile.byWeekday.indices.max { profile.byWeekday[$0] < profile.byWeekday[$1] } ?? 0
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(String(localized: "Ton rythme"))
            Text("Surtout vers \(peakHour) h, et le \(Self.weekdays[peakDay]).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Bars(values: profile.byHour, highlight: peakHour, tint: .blue, height: 64)
            HStack {
                ForEach([0, 6, 12, 18, 23], id: \.self) { hour in
                    Text("\(hour) h").font(.system(size: 10)).foregroundStyle(.tertiary)
                    if hour != 23 { Spacer() }
                }
            }
            Bars(values: profile.byWeekday, highlight: peakDay, tint: .purple, height: 40)
            HStack(spacing: 0) {
                ForEach(Self.initials.indices, id: \.self) { index in
                    Text(Self.initials[index]).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    /// Noms et initiales des jours dans la langue du Mac, lundi d'abord.
    static var weekdays: [String] { mondayFirst(Calendar.current.standaloneWeekdaySymbols.map { $0.lowercased(with: appLocale) }) }
    static var initials: [String] { mondayFirst(Calendar.current.veryShortStandaloneWeekdaySymbols) }

    private static func mondayFirst(_ symbols: [String]) -> [String] {
        guard symbols.count == 7 else { return symbols }
        return Array(symbols[1...]) + [symbols[0]]
    }
}

private struct Bars: View {
    var values: [Int]
    var highlight: Int
    var tint: Color
    var height: CGFloat

    var body: some View {
        let maximum = CGFloat(max(1, values.max() ?? 1))
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index == highlight ? tint : tint.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, CGFloat(values[index]) / maximum * height))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: Jours

/// Mots dictés par jour sur 18 semaines, en cases comme sur GitHub. Au survol d'une case, sa date et ses mots
/// s'affichent tout de suite au-dessus de la grille, et la case est entourée.
private struct DaysCard: View {
    var profile: DictationProfile
    @State private var hovered: Int?

    var body: some View {
        let count = profile.daily.count
        let maximum = max(1, profile.daily.max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(String(localized: "Tes jours"))
            Group {
                if let hovered, profile.daily.indices.contains(hovered) {
                    let value = profile.daily[hovered]
                    HStack(spacing: 6) {
                        Text(date(for: hovered, count: count).formatted(.dateTime.weekday(.wide).day().month(.wide).locale(appLocale)))
                            .fontWeight(.semibold)
                        Text("·").foregroundStyle(.tertiary)
                        Text(value == 0 ? String(localized: "Aucune dictée") : value == 1 ? String(localized: "1 mot")
                             : String(localized: "\(value.formatted(.number.locale(appLocale))) mots"))
                            .monospacedDigit()
                            .foregroundStyle(value == 0 ? Color.secondary : Theme.brand)
                    }
                } else {
                    Text("Mots dictés par jour, sur les 18 dernières semaines. Survole une case pour voir son jour.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .frame(height: 16, alignment: .leading)
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(stride(from: 0, to: count, by: 7)), id: \.self) { start in
                    VStack(spacing: 3) {
                        ForEach(start..<min(start + 7, count), id: \.self) { index in
                            let value = profile.daily[index]
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(value == 0 ? Theme.subtleFill : Theme.brand.opacity(0.25 + 0.75 * Double(value) / Double(maximum)))
                                .overlay {
                                    if hovered == index {
                                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                                    }
                                }
                                .frame(width: 11, height: 11)
                                .contentShape(Rectangle().inset(by: -1.5))
                                .onHover { inside in
                                    if inside { hovered = index } else if hovered == index { hovered = nil }
                                }
                                .accessibilityElement()
                                .accessibilityLabel(Text(date(for: index, count: count).formatted(date: .complete, time: .omitted)))
                                .accessibilityValue(Text("\(value) mots"))
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Moins").font(.system(size: 10)).foregroundStyle(.tertiary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(level == 0 ? Theme.subtleFill : Theme.brand.opacity(0.25 + 0.75 * level))
                        .frame(width: 9, height: 9)
                }
                Text("Plus").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    /// La dernière case est aujourd'hui ; chaque case avant elle, un jour plus tôt.
    private func date(for index: Int, count: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: index - (count - 1), to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }
}

// MARK: Mots

private struct WordsCard: View {
    var words: [DictationProfile.Count]
    var hide: (String) -> Void

    var body: some View {
        let maximum = Double(max(1, words.first?.count ?? 1))
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(String(localized: "Tes mots"))
            Text("Les mots qui reviennent le plus, sans les petits mots. Clic droit pour en masquer un.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if words.isEmpty {
                Text("Pas assez de dictées pour l'instant.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(Array(words.enumerated()), id: \.element.id) { rank, word in
                        let weight = Double(word.count) / maximum
                        HStack(spacing: 5) {
                            Text(word.label)
                                .font(.system(size: 12 + 8 * weight, weight: rank < 3 ? .semibold : .medium))
                            Text("\(word.count)")
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.brand.opacity(0.06 + 0.16 * weight)))
                        .contextMenu {
                            Button(String(localized: "Masquer « \(word.label) »")) { hide(word.label) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct TicsCard: View {
    var tics: [DictationProfile.Count]

    var body: some View {
        RankedCard(title: String(localized: "Tes tics de langage"),
                   caption: String(localized: "Dits avant correction : Wispad les retire quand ils n'apportent rien."),
                   empty: String(localized: "Aucun tic repéré. Bravo."),
                   rows: tics.map { ("« \($0.label) »", $0.count) }, tint: .orange)
    }
}

private struct FixesCard: View {
    var fixes: [DictationProfile.Fix]

    var body: some View {
        RankedCard(title: String(localized: "Ce que Wispad corrige le plus"),
                   caption: String(localized: "Mot entendu, puis mot écrit après correction."),
                   empty: String(localized: "Rien de récurrent pour l'instant."),
                   rows: fixes.map { ("\($0.heard) → \($0.written)", $0.count) }, tint: .green)
    }
}

private struct RankedCard: View {
    var title: String
    var caption: String
    var empty: String
    var rows: [(String, Int)]
    var tint: Color

    var body: some View {
        let maximum = max(1, rows.first?.1 ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title)
            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(rows.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(rows[index].0).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("\(rows[index].1)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        Capsule().fill(Theme.subtleFill).overlay(alignment: .leading) {
                            Capsule().fill(tint.opacity(0.8))
                                .frame(width: max(4, proxy.size.width * CGFloat(rows[index].1) / CGFloat(maximum)))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct LanguagesCard: View {
    var profile: DictationProfile

    var body: some View {
        let total = max(1, profile.frenchDictations + profile.englishDictations)
        let french = Double(profile.frenchDictations) / Double(total)
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(String(localized: "Langues"))
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(Color.blue).frame(width: max(0, proxy.size.width * french))
                    Rectangle().fill(Color.orange)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack {
                Label(String(localized: "Français \(percent(french))"), systemImage: "circle.fill")
                    .foregroundStyle(.blue)
                Spacer()
                Label(String(localized: "Anglais \(percent(1 - french))"), systemImage: "circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.system(size: 12, weight: .medium))
            .labelStyle(DotLabelStyle())
            Text("Langue principale de chaque dictée.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(appLocale))
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title.foregroundStyle(.primary)
        }
    }
}

private struct HiddenWordsFooter: View {
    var words: [String]
    var show: (String) -> Void

    var body: some View {
        if !words.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Mots masqués :").font(.footnote).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(words, id: \.self) { word in
                        Button {
                            show(word)
                        } label: {
                            Label(word, systemImage: "eye")
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                        .help(String(localized: "Réafficher « \(word) »"))
                    }
                }
            }
        }
    }
}
