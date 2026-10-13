import SwiftUI
import AppKit
import WispadCore

// MARK: - Dictionnaire

struct DictionaryView: View {
    @Environment(AppModel.self) private var model
    @State private var term = ""
    @State private var search = ""
    @FocusState private var focused: Bool

    private var origin: DictionaryFilter { model.settings.dictionaryOriginFilter }
    private var period: DictionaryPeriod { model.settings.dictionaryPeriod }
    private var kind: DictionaryKind { model.settings.dictionaryKind }
    private var sort: DictionarySort { model.settings.dictionarySort }
    private var sectionEntries: [DictionaryEntry] { model.dictionary.filter(kind.includes) }

    var body: some View {
        ScreenScroll {
            ScreenHeader(title: String(localized: "Dictionnaire"), subtitle: String(localized: "Les noms, marques et acronymes que Wispad doit reconnaître."))
            VStack(alignment: .leading, spacing: 16) {
                Picker("Type d'entrée", selection: Binding(
                    get: { kind }, set: { model.setDisplayChoice(\.dictionaryKind, $0) }
                )) {
                    Text("Mots (\(model.dictionary.filter(DictionaryKind.word.includes).count))").tag(DictionaryKind.word)
                    Text("Expressions et phrases (\(model.dictionary.filter(DictionaryKind.phrase.includes).count))").tag(DictionaryKind.phrase)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                addField
                dictionaryTable
            }
            .frame(maxWidth: kind == .word ? 600 : 660, alignment: .leading)
            Label("Ces termes aident ton fournisseur à mieux te comprendre.", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Ces termes sont envoyés comme indices au fournisseur choisi, puis relus par la correction.")
        }
    }

    private var addField: some View {
        HStack(alignment: kind == .phrase ? .top : .center, spacing: 10) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
                .padding(.top, kind == .phrase ? 14 : 0)
            if kind == .phrase {
                ZStack(alignment: .topLeading) {
                    if term.isEmpty {
                        Text("Ajouter une expression ou une phrase…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 5)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $term)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .accessibilityLabel("Expression ou phrase à ajouter")
                }
                .padding(.vertical, 8)
            } else {
                TextField("Ajouter un mot, un nom, un acronyme…", text: $term)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(add)
            }
            Button("Ajouter", action: add)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, kind == .phrase ? 10 : 0)
                .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .font(.system(size: 13))
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: kind == .phrase ? 100 : 46)
        .card(radius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Theme.brand.opacity(focused ? 0.55 : 0), lineWidth: 1.5))
    }

    private var dictionaryTable: some View {
        let entries = origin.matchingEntries(in: sectionEntries, period: period, search: search, sort: sort)
        return VStack(spacing: 0) {
            originFilters
                .padding(12)
            Divider()
            searchAndPeriod
                .padding(14)
            tableHeader
            if sectionEntries.isEmpty {
                EmptyState(symbol: "character.book.closed", title: kind == .word ? String(localized: "Aucun mot pour l’instant") : String(localized: "Aucune expression pour l’instant"),
                           message: String(localized: "Ajoute les termes que tu veux mieux faire reconnaître."))
            } else if entries.isEmpty {
                VStack(spacing: 10) {
                    Text("Aucune entrée ne correspond à ces filtres.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button("Réinitialiser les filtres", action: resetFilters)
                        .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        if kind == .word {
                            DictionaryRow(entry: entry) { model.deleteTerm(entry) }
                        } else {
                            DictionaryPhraseRow(entry: entry) { model.deleteTerm(entry) }
                        }
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            HStack {
                Text("\(entries.count) sur \(sectionEntries.count) entrées")
                    .foregroundStyle(.secondary)
                Spacer()
                if origin != .all || period != .all || !search.isEmpty {
                    Button("Réinitialiser les filtres", action: resetFilters)
                        .buttonStyle(.borderless)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var originFilters: some View {
        HStack(spacing: 6) {
            ForEach(DictionaryFilter.allCases, id: \.self) { filter in
                let selected = origin == filter
                let count = sectionEntries.filter(filter.includes).count
                Button { model.setDisplayChoice(\.dictionaryOriginFilter, filter) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Image(systemName: filter.symbol)
                                .font(.system(size: 11))
                                .foregroundStyle(filter.tint)
                            Text(count, format: .number)
                                .font(.system(size: 18, weight: .semibold))
                                .monospacedDigit()
                        }
                        Text(filter.label)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(selected ? filter.tint : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(selected ? filter.tint.opacity(0.12) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(selected ? filter.tint.opacity(0.35) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(filter.label), \(count) entrées")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(filter == .unknown ? String(localized: "L'origine de ces anciens mots n'a pas été enregistrée.") : filter.label)
            }
        }
    }

    private var searchAndPeriod: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(kind == .word ? String(localized: "Rechercher un mot…") : String(localized: "Rechercher une expression…"), text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Effacer la recherche")
                        .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.subtleFill))
            Picker("Date d'ajout", selection: Binding(
                get: { period }, set: { model.setDisplayChoice(\.dictionaryPeriod, $0) }
            )) {
                ForEach(DictionaryPeriod.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
            .help("Filtrer par date d'ajout")
        }
        .font(.system(size: 12))
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            sortHeader(kind == .word ? String(localized: "Mot") : String(localized: "Expression"), column: .term)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader(String(localized: "Origine"), column: .origin)
                .frame(width: DictionaryColumns.origin, alignment: .leading)
            sortHeader(String(localized: "Ajouté le"), column: .date)
                .frame(width: DictionaryColumns.date, alignment: .leading)
            Color.clear.frame(width: DictionaryColumns.action, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.subtleFill.opacity(0.7))
    }

    private func sortHeader(_ title: String, column: DictionarySort.Column) -> some View {
        let selected = sort.column == column
        return Button { model.setDisplayChoice(\.dictionarySort, sort.selecting(column)) } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: selected ? (sort.ascending ? "arrow.up" : "arrow.down") : "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(selected ? 1 : 0.4)
            }
            .foregroundStyle(selected ? Color.primary : .secondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? (sort.ascending ? String(localized: "Tri croissant") : String(localized: "Tri décroissant")) : String(localized: "Non trié"))
        .help("Cliquer pour trier, puis inverser l’ordre")
    }

    private func resetFilters() {
        search = ""
        model.setDisplayChoice(\.dictionaryOriginFilter, .all)
        model.setDisplayChoice(\.dictionaryPeriod, .all)
    }

    private func add() {
        let value = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.addTerm(value)
        term = ""
        model.setDisplayChoice(\.dictionaryKind, DictionaryKind.classify(value))
        // L'ajout doit rester visible, même si l'on consultait les mots appris ou une recherche.
        resetFilters()
    }
}

private enum DictionaryColumns {
    static let origin: CGFloat = 145
    static let date: CGFloat = 85
    static let action: CGFloat = 26
}

private extension DictionaryFilter {
    var tint: Color {
        switch self {
        case .all: return .primary
        case .addedByUser: return .blue
        case .learned: return .purple
        case .unknown: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .all: return "text.book.closed"
        case .addedByUser: return "person.fill"
        case .learned: return "sparkles"
        case .unknown: return "clock.arrow.circlepath"
        }
    }
}

private struct DictionaryRow: View {
    var entry: DictionaryEntry
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.term)
                .font(.system(size: 13, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                OriginBadge(origin: entry.origin)
                if let judge = entry.origin.judge {
                    Text(DictionaryOriginText.judgeName(judge))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: DictionaryColumns.origin, alignment: .leading)
            .help(DictionaryOriginText.detail(entry))
            Text(entry.createdAt.formatted(.dateTime.day().month(.abbreviated).year().locale(appLocale)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: DictionaryColumns.date, alignment: .leading)
                .help(DictionaryOriginText.date(entry.createdAt))
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Theme.brand : .secondary)
                    .frame(width: DictionaryColumns.action, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(treatment: .icon))
            .help("Supprimer « \(entry.term) »")
            .accessibilityLabel("Supprimer « \(entry.term) »")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 58)
        .background(hovering ? Theme.subtleFill : .clear)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

/// Les expressions ont toute la largeur ; leur contenu reste lisible, même sur plusieurs lignes.
private struct DictionaryPhraseRow: View {
    var entry: DictionaryEntry
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.term)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                OriginBadge(origin: entry.origin)
                    .help(DictionaryOriginText.detail(entry))
                if let judge = entry.origin.judge {
                    Text(DictionaryOriginText.judgeName(judge))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(entry.createdAt.formatted(.dateTime.day().month(.abbreviated).year().locale(appLocale)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button(action: onDelete) {
                    Image(systemName: "trash").frame(width: 26, height: 26)
                }
                .buttonStyle(HoverButtonStyle(treatment: .icon))
                .help("Supprimer cette expression")
                .accessibilityLabel("Supprimer cette expression")
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

private struct OriginBadge: View {
    var origin: DictionaryOrigin

    private var filter: DictionaryFilter {
        switch origin {
        case .user: return .addedByUser
        case .learned: return .learned
        case .unknown: return .unknown
        }
    }

    var body: some View {
        Label(filter.label, systemImage: filter.symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(filter.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(filter.tint.opacity(0.10)))
            .accessibilityLabel(DictionaryOriginText.summary(origin))
    }
}

/// Origine d'un mot en clair : nom court du juge, info-bulle (juge, fournisseur, modèle, dates) et VoiceOver.
enum DictionaryOriginText {
    /// Nom court du juge dans le badge : « Jev », ou le fournisseur du modèle de correction (« DeepSeek »).
    static func judgeName(_ judge: DictionaryJudge) -> String {
        judge.kind == .jev ? "Jev" : judge.provider
    }

    /// Une ligne, pour VoiceOver.
    static func summary(_ origin: DictionaryOrigin) -> String {
        switch origin {
        case .user: return String(localized: "Ajouté par toi")
        case .learned(let judge): return String(localized: "Appris automatiquement, juge : \(judgeName(judge))")
        case .unknown: return String(localized: "Avant le suivi")
        }
    }

    /// Qui a ajouté le mot et quand ; pour un mot appris, le juge avec le fournisseur et le modèle de l'appel qui a
    /// tranché, puis « Gardé par toi » s'il a été confirmé par « Oui ».
    static func detail(_ entry: DictionaryEntry, locale: Locale = appLocale) -> String {
        let added = date(entry.createdAt, locale: locale)
        switch entry.origin {
        case .user:
            return String(localized: "Ajouté par toi le \(added)")
        case .learned(let judge):
            var lines = [String(localized: "Appris automatiquement le \(added)")]
            switch judge.kind {
            case .jev:
                lines.append(String(localized: "Juge : Jev (fournisseur \(judge.provider), modèle \(judge.model))"))
            case .correctionModel:
                lines.append(String(localized: "Juge : modèle de correction (fournisseur \(judge.provider), modèle \(judge.model))"))
            }
            if let confirmed = entry.confirmedAt {
                lines.append(String(localized: "Gardé par toi le \(date(confirmed, locale: locale))"))
            }
            return lines.joined(separator: "\n")
        case .unknown:
            return [String(localized: "Avant le suivi : origine inconnue"), String(localized: "Ajouté le \(added)")].joined(separator: "\n")
        }
    }

    /// Filtre sans aucun mot, alors que le dictionnaire en a.
    static func emptyMessage(_ filter: DictionaryFilter) -> String {
        switch filter {
        case .all: return String(localized: "Dictionnaire vide")
        case .addedByUser: return String(localized: "Aucun mot ajouté par toi pour l'instant.")
        case .learned: return String(localized: "Aucun mot appris de tes corrections pour l'instant.")
        case .unknown: return String(localized: "Aucun mot sans origine enregistrée.")
        }
    }

    static func date(_ date: Date, locale: Locale = appLocale) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(locale))
    }
}
