import SwiftUI
import AppKit
import WispadCore

// MARK: - Historique

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var query = ""
    /// Recherche appliquée : suit la saisie après une courte pause, pour ne pas refiltrer à chaque touche.
    @State private var appliedQuery = ""
    @State private var pendingDeleteAll = false
    @State private var detailRecord: DictationRecord?

    var body: some View {
        let groups = DayGroup.make(filtered)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: String(localized: "Historique"), subtitle: subtitle) {
                    Button(role: .destructive) {
                        pendingDeleteAll = true
                    } label: {
                        Label("Tout supprimer", systemImage: "trash")
                    }
                    .hoverFeedback(tint: .red)
                    .disabled(model.history.isEmpty)
                }
                SearchField(text: $query, prompt: String(localized: "Rechercher dans les dictées"))
                if let filter = model.historyFilter {
                    HStack(spacing: 8) {
                        Image(systemName: "brain.head.profile").foregroundStyle(Theme.brand)
                        Text("Dictées de « \(filter.title) »").fontWeight(.medium)
                        Text(filter.dictations.count == 1 ? String(localized: "1 dictée") : String(localized: "\(filter.dictations.count) dictées"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.historyFilter = nil
                        } label: {
                            Label(String(localized: "Toutes les dictées"), systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.brand.opacity(0.1)))
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            if groups.isEmpty {
                EmptyState(
                    symbol: appliedQuery.isEmpty ? "text.quote" : "magnifyingglass",
                    title: appliedQuery.isEmpty ? String(localized: "Aucune dictée") : String(localized: "Aucun résultat"),
                    message: appliedQuery.isEmpty ? String(localized: "Les transcriptions restent ici, même si l'insertion échoue.") : String(localized: "Aucune dictée ne contient « \(appliedQuery) ».")
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                // Chaque ligne est un enfant de la pile paresseuse : une journée
                                // chargée ne doit pas faire construire toutes ses dictées d'un coup.
                                ForEach(group.records) { record in
                                    let first = record.id == group.records.first?.id
                                    let last = record.id == group.records.last?.id
                                    HistoryRow(record: record, first: first, last: last, onDetails: { detailRecord = record })
                                        .modifier(HistoryCardRow(first: first, last: last))
                                }
                            } header: {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.top, 8)
                                    .background(Theme.canvas)
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { HistoryAudioDock() }
        .task(id: query) {
            // Effacer la recherche s'applique tout de suite ; une saisie attend la fin de la frappe.
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(Self.searchDelayMilliseconds))
                guard !Task.isCancelled else { return }
            }
            appliedQuery = query
        }
        .sheet(item: $detailRecord) { record in
            DictationDetailView(record: record)
        }
        .confirmationDialog("Supprimer tout l'historique ?", isPresented: $pendingDeleteAll) {
            Button("Supprimer", role: .destructive) {
                withAnimation(reduceMotion ? nil : Theme.spring) { model.deleteAllHistory() }
            }
        }
    }

    static let searchDelayMilliseconds = 150

    private var subtitle: String {
        let count = model.history.count
        switch count {
        case 0: return String(localized: "Tes dictées restent sur ce Mac.")
        case 1: return String(localized: "1 dictée conservée sur ce Mac.")
        default: return String(localized: "\(count) dictées conservées sur ce Mac.")
        }
    }

    private var filtered: [DictationRecord] {
        let needle = appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = model.historyFilter.map { filter in model.history.filter { filter.dictations.contains($0.id) } } ?? model.history
        guard !needle.isEmpty else { return scoped }
        // Ce qui a été entendu compte aussi : une correction partie à côté ne cache pas la dictée.
        return scoped.filter { $0.matches(search: needle) }
    }
}

/// Forme d'une ligne dans sa carte journalière : seuls les coins de la première et de la dernière sont arrondis.
enum HistoryCardShape {
    static func make(first: Bool, last: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: first ? Theme.radius : 0,
            bottomLeadingRadius: last ? Theme.radius : 0,
            bottomTrailingRadius: last ? Theme.radius : 0,
            topTrailingRadius: first ? Theme.radius : 0,
            style: .continuous
        )
    }
}

/// Une carte journalière continue, sans conteneur qui force le rendu des lignes hors écran.
/// Pas de masque sur la ligne entière : le fond de carte et le fond de survol portent déjà sa forme,
/// et un masque par ligne obligerait à recomposer chaque ligne à chaque image du défilement.
private struct HistoryCardRow: ViewModifier {
    var first: Bool
    var last: Bool

    private var shape: UnevenRoundedRectangle { HistoryCardShape.make(first: first, last: last) }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Theme.card))
            .overlay {
                // Seuls les bords externes de la journée sont visibles.
                shape.strokeBorder(Theme.cardBorder, lineWidth: 1)
                    .padding(.top, first ? 0 : -2)
                    .padding(.bottom, last ? 0 : -2)
                    .clipped()
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if !last { Divider().padding(.leading, 70) }
            }
            .padding(.bottom, last ? 10 : 0)
    }
}

struct DayGroup: Identifiable {
    var day: Date
    var records: [DictationRecord]
    /// Calculé une fois au regroupement, pas à chaque passage de l'en-tête épinglé.
    var title: String
    var id: Date { day }

    init(day: Date, records: [DictationRecord]) {
        self.day = day
        self.records = records
        title = Self.title(for: day)
    }

    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Aujourd'hui") }
        if calendar.isDateInYesterday(day) { return String(localized: "Hier") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        let style: Date.FormatStyle = sameYear
            ? .dateTime.weekday(.wide).day().month(.wide)
            : .dateTime.day().month(.wide).year()
        return day.formatted(style.locale(appLocale)).capitalizedFirst
    }

    /// Regroupe des dictées déjà triées de la plus récente à la plus ancienne.
    static func make(_ records: [DictationRecord]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            if groups.last?.day == day {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append(DayGroup(day: day, records: [record]))
            }
        }
        return groups
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct HistoryRow: View {
    /// Heures sur 12 h (« 12:03 PM ») plus larges que sur 24 h (« 19:03 »).
    static let timeColumnWidth: CGFloat = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: appLocale) ?? ""
        return format.contains("a") ? 62 : 40
    }()

    @Environment(AppModel.self) private var model
    @Environment(\.historyRowDidRender) private var didRender
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @Environment(\.interactionPreviewHover) private var previewHover
    @Environment(\.isEnabled) private var isEnabled
    var record: DictationRecord
    /// Place dans la carte du jour : le fond de survol suit ses coins arrondis.
    var first = true
    var last = true
    var onDetails: (() -> Void)? = nil
    @State private var hovering = false
    @State private var expanded = false
    @State private var textWidth: CGFloat = 0
    /// Dernière mesure de cette ligne : la changer redessine la ligne, qui relit alors le cache.
    @State private var lastMeasure: HistoryRowCache.Overflow?

    private static let collapsedLines = 4

    private var hovered: Bool { isEnabled && (hovering || previewHover) }

    var body: some View {
        let _ = didRender?(record.id)
        let cache = HistoryRowCache.shared
        let item = cache.item(for: record)
        let selected = model.historyPlayer.recordID == record.id
        // Un texte court sur une seule ligne logique ne dépasse jamais quatre lignes : pas de mesure à faire.
        // Sinon, la troncature mesurée une fois à cette largeur est réutilisée ; la mesure cachée n'existe
        // que tant qu'aucun résultat n'est connu.
        let overflows = item.mayOverflow
            ? cache.overflows(id: item.id, text: item.text, width: textWidth)
                ?? lastMeasure?.overflows(text: item.text, width: textWidth)
            : false
        let measuring = item.mayOverflow && !expanded && overflows == nil
        // Le bouton n'apparaît que si la limite coupe vraiment le texte à la largeur actuelle.
        let canExpand = expanded || overflows == true
        HStack(alignment: .top, spacing: 14) {
            Text(item.time)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // « 19:03 » comme « 12:03 PM » : une seule ligne, colonne alignée d'une ligne à l'autre.
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: Self.timeColumnWidth, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 7) {
                if item.text.isEmpty {
                    Text("Audio à retranscrire")
                        .font(.system(size: 13))
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.text)
                        .font(.system(size: 13))
                        .lineLimit(expanded ? nil : Self.collapsedLines)
                        .textSelection(.enabled)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                        .background(alignment: .topLeading) {
                            if measuring {
                                // Même texte sans limite, à la même largeur, jamais affiché.
                                Text(item.text)
                                    .font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .hidden()
                                    .accessibilityHidden(true)
                                    .onGeometryChange(for: HistoryTextMeasure.self) { proxy in
                                        HistoryTextMeasure(
                                            full: proxy.size,
                                            shown: proxy.bounds(of: .named(historyRowTextSpace))?.size ?? .zero
                                        )
                                    } action: { measure in
                                        guard measure.shown.width > 0 else { return }
                                        let result = HistoryRowCache.Overflow(
                                            text: item.text, width: measure.shown.width, overflows: measure.overflows
                                        )
                                        cache.store(result, id: item.id)
                                        // La ligne relit le résultat et retire la mesure cachée.
                                        lastMeasure = result
                                    }
                            }
                        }
                        .coordinateSpace(.named(historyRowTextSpace))
                    if canExpand {
                        Button(expanded ? String(localized: "Réduire") : String(localized: "Afficher tout")) {
                            withAnimation(reduceMotion ? nil : Theme.spring) { expanded.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.brand)
                        .accessibilityIdentifier("dictation-expand-\(record.id)")
                    }
                }
                HStack(spacing: 8) {
                    AppIconView(bundleID: item.targetBundle, size: 14)
                    Text(item.meta)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(Text(item.metaHelp))
                    StatusChip(text: item.status.text, tint: item.status.tint)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if let onDetails {
                    HoverIconButton(symbol: "info.circle", help: String(localized: "Détails de la dictée"), action: onDetails)
                        .accessibilityLabel("Détails de la dictée")
                        .accessibilityIdentifier("dictation-details-\(record.id)")
                }
                HStack(spacing: 2) {
                    if !item.text.isEmpty {
                        HoverIconButton(symbol: "doc.on.doc", help: String(localized: "Copier")) { model.copy(record.finalText) }
                    }
                    if item.hasAudio {
                        HoverIconButton(symbol: "arrow.clockwise", help: String(localized: "Retranscrire")) {
                            Task { await model.coordinator.retranscribe(record) }
                        }
                        HoverIconButton(
                            symbol: selected && model.historyPlayer.isPlaying ? "pause.fill" : "play.fill",
                            help: selected && model.historyPlayer.isPlaying ? String(localized: "Mettre en pause") : String(localized: "Écouter"),
                            tint: selected ? Theme.brand : .secondary
                        ) { model.play(record) }
                        .accessibilityLabel(selected && model.historyPlayer.isPlaying ? String(localized: "Mettre en pause") : String(localized: "Écouter l'audio"))
                    }
                    HoverIconButton(symbol: "trash", help: String(localized: "Supprimer"), tint: .red) {
                        withAnimation(reduceMotion ? nil : Theme.spring) { model.deleteHistory(record) }
                    }
                }
                .opacity(hovered || selected ? 1 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(HistoryCardShape.make(first: first, last: last).fill(hovered ? Theme.subtleFill.opacity(0.5) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.hover, value: hovered)
    }
}

/// Espace de coordonnées du texte affiché : la mesure cachée y lit sa taille dans la même passe.
private let historyRowTextSpace = "history-row-text"

/// Une mesure de texte : taille sans limite de lignes et taille affichée, lues dans la même passe.
struct HistoryTextMeasure: Equatable {
    var full: CGSize
    var shown: CGSize

    /// Une marge d'un point évite un faux « Afficher tout » dû aux arrondis.
    var overflows: Bool { full.height > shown.height + 1 }
}

struct HistoryStatus: Equatable {
    var text: String
    var tint: Color

    init(_ raw: String) {
        switch raw {
        case InsertionStatus.inserted.rawValue: (text, tint) = (String(localized: "Inséré"), .green)
        case InsertionStatus.pasteSent.rawValue: (text, tint) = (String(localized: "Collage envoyé"), .blue)
        case InsertionStatus.pending.rawValue: (text, tint) = (String(localized: "Prêt à copier"), .secondary)
        case InsertionStatus.transcriptionFailed.rawValue: (text, tint) = (String(localized: "À retranscrire"), .orange)
        case InsertionStatus.cancelled.rawValue: (text, tint) = (String(localized: "Annulé"), .secondary)
        case InsertionStatus.failed.rawValue: (text, tint) = (String(localized: "Insertion échouée"), .red)
        case InsertionStatus.noTarget.rawValue: (text, tint) = (String(localized: "Aucun champ actif"), .orange)
        case InsertionStatus.refusedSecure.rawValue: (text, tint) = (String(localized: "Champ sécurisé"), .orange)
        default: (text, tint) = (raw, .secondary)
        }
    }
}

struct SearchField: View {
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @Binding var text: String
    var prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(HoverButtonStyle(treatment: .icon))
                .help("Effacer la recherche")
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Theme.brand.opacity(0.55) : Theme.cardBorder, lineWidth: focused ? 1.5 : 1)
        )
        .animation(reduceMotion ? nil : Theme.quick, value: focused)
    }
}
