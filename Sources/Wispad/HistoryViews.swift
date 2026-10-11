import SwiftUI
import AppKit
import WispadCore

// MARK: - Historique

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var query = ""
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
            }
            .padding(.horizontal, 32)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            if groups.isEmpty {
                EmptyState(
                    symbol: query.isEmpty ? "text.quote" : "magnifyingglass",
                    title: query.isEmpty ? String(localized: "Aucune dictée") : String(localized: "Aucun résultat"),
                    message: query.isEmpty ? String(localized: "Les transcriptions restent ici, même si l'insertion échoue.") : String(localized: "Aucune dictée ne contient « \(query) ».")
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
                                    HistoryRow(record: record, onDetails: { detailRecord = record })
                                        .modifier(HistoryCardRow(
                                            first: record.id == group.records.first?.id,
                                            last: record.id == group.records.last?.id
                                        ))
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
        .sheet(item: $detailRecord) { record in
            DictationDetailView(record: record)
        }
        .confirmationDialog("Supprimer tout l'historique ?", isPresented: $pendingDeleteAll) {
            Button("Supprimer", role: .destructive) {
                withAnimation(reduceMotion ? nil : Theme.spring) { model.deleteAllHistory() }
            }
        }
    }

    private var subtitle: String {
        let count = model.history.count
        switch count {
        case 0: return String(localized: "Tes dictées restent sur ce Mac.")
        case 1: return String(localized: "1 dictée conservée sur ce Mac.")
        default: return String(localized: "\(count) dictées conservées sur ce Mac.")
        }
    }

    private var filtered: [DictationRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.history }
        return model.history.filter { $0.finalText.localizedCaseInsensitiveContains(needle) }
    }
}

/// Une carte journalière continue, sans conteneur qui force le rendu des lignes hors écran.
private struct HistoryCardRow: ViewModifier {
    var first: Bool
    var last: Bool

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: first ? Theme.radius : 0,
            bottomLeadingRadius: last ? Theme.radius : 0,
            bottomTrailingRadius: last ? Theme.radius : 0,
            topTrailingRadius: first ? Theme.radius : 0,
            style: .continuous
        )
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Theme.card))
            .clipShape(shape)
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
    var id: Date { day }

    var title: String {
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
    var onDetails: (() -> Void)? = nil
    @State private var hovering = false
    @State private var expanded = false
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private static let collapsedLines = 4

    private var hovered: Bool { isEnabled && (hovering || previewHover) }

    /// Un texte court sur une seule ligne logique ne dépasse jamais quatre lignes : pas de mesure à faire.
    private var mayOverflow: Bool {
        record.finalText.count > 160 || record.finalText.contains("\n")
    }

    /// Le bouton n'apparaît que si la limite coupe vraiment le texte à la largeur actuelle.
    private var canExpand: Bool {
        expanded || (mayOverflow && fullHeight > shownHeight + 1)
    }

    var body: some View {
        let _ = didRender?(record.id)
        let selected = model.historyPlayer.recordID == record.id
        HStack(alignment: .top, spacing: 14) {
            Text(record.createdAt, format: .dateTime.hour().minute())
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // « 19:03 » comme « 12:03 PM » : une seule ligne, colonne alignée d'une ligne à l'autre.
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: Self.timeColumnWidth, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 7) {
                if record.finalText.isEmpty {
                    Text("Audio à retranscrire")
                        .font(.system(size: 13))
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    Text(record.finalText)
                        .font(.system(size: 13))
                        .lineLimit(expanded ? nil : Self.collapsedLines)
                        .textSelection(.enabled)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                        .background(alignment: .topLeading) {
                            if mayOverflow && !expanded {
                                // Même texte sans limite, à la même largeur, jamais affiché.
                                Text(record.finalText)
                                    .font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .hidden()
                                    .accessibilityHidden(true)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                            }
                        }
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
                    AppIconView(bundleID: record.targetBundle, size: 14)
                    Text("\(record.targetApp ?? "—") · \(record.wordCount) mots · \(record.providerLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("\(record.providerLabel) · \(record.model)")
                    let status = HistoryStatus(record.insertionStatus)
                    StatusChip(text: status.text, tint: status.tint)
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
                    if !record.finalText.isEmpty {
                        HoverIconButton(symbol: "doc.on.doc", help: String(localized: "Copier")) { model.copy(record.finalText) }
                    }
                    if record.audioPath != nil {
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
        .background(hovered ? Theme.subtleFill.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.hover, value: hovered)
    }
}

struct HistoryStatus {
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
