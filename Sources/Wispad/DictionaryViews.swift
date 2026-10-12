import SwiftUI
import AppKit
import WispadCore

// MARK: - Dictionnaire

struct DictionaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var term = ""
    /// Filtre par origine, éphémère : l'écran rouvre sur « Tous », pour qu'un mot filtré ne passe jamais pour perdu.
    @State private var originFilter: DictionaryFilter = .all
    @FocusState private var focused: Bool

    var body: some View {
        ScreenScroll {
            ScreenHeader(title: String(localized: "Dictionnaire"), subtitle: String(localized: "Les noms, marques et acronymes que Wispad doit reconnaître."))
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Ajouter un mot, un nom, un acronyme…", text: $term)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(add)
                Button("Ajouter", action: add)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .hoverFeedback()
                    .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 44)
            .card(radius: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.brand.opacity(focused ? 0.55 : 0), lineWidth: 1.5)
            )
            .animation(reduceMotion ? nil : Theme.quick, value: focused)
            Text("Ces termes sont envoyés comme indices au fournisseur choisi, puis relus par la correction.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            let recent = recentEntries
            // Quand tout le dictionnaire est récent, la liste complète suffit.
            if !recent.isEmpty, recent.count < model.dictionary.count {
                let shown = Array(recent.prefix(12))
                VStack(alignment: .leading, spacing: 14) {
                    CardTitle(String(localized: "Ajoutés ces 7 derniers jours"))
                    Text("Dont les mots appris de tes corrections. Un mot ajouté à tort se retire ici d'un clic.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8) {
                        ForEach(shown) { entry in
                            TermChip(entry: entry) {
                                withAnimation(reduceMotion ? nil : Theme.spring) { model.deleteTerm(entry) }
                            }
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            if model.dictionary.isEmpty {
                EmptyState(symbol: "character.book.closed", title: String(localized: "Dictionnaire vide"), message: String(localized: "Ajoute OpenAI, SwiftUI, RevenueCat ou tes propres noms."))
                    .card()
            } else {
                let filtered = model.dictionary.filter(originFilter.includes)
                VStack(alignment: .leading, spacing: 14) {
                    CardTitle(title: filtered.count == 1 ? String(localized: "1 terme") : String(localized: "\(filtered.count) termes")) {
                        PillPicker(options: DictionaryFilter.allCases, selection: $originFilter, title: { $0.label })
                    }
                    if filtered.isEmpty {
                        Text(DictionaryOriginText.emptyMessage(originFilter))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(filtered) { entry in
                                TermChip(entry: entry) {
                                    withAnimation(reduceMotion ? nil : Theme.spring) { model.deleteTerm(entry) }
                                }
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
    }

    private var recentEntries: [DictionaryEntry] {
        let since = Date().addingTimeInterval(-7 * 86_400)
        return model.dictionary.filter { $0.createdAt >= since }.sorted { $0.createdAt > $1.createdAt }
    }

    private func add() {
        let value = term
        term = ""
        withAnimation(reduceMotion ? nil : Theme.spring) { model.addTerm(value) }
    }
}

struct TermChip: View {
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @Environment(\.interactionPreviewHover) private var previewHover
    @Environment(\.isEnabled) private var isEnabled
    var entry: DictionaryEntry
    var onDelete: () -> Void
    @State private var hovering = false

    private var hovered: Bool { isEnabled && (hovering || previewHover) }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.term)
                    .font(.system(size: 12.5, weight: .medium))
                OriginBadge(origin: entry.origin)
            }
            .accessibilityElement(children: .combine)
            .help(DictionaryOriginText.detail(entry))
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovered ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(hovered ? Theme.subtleFill : .clear))
            }
            .buttonStyle(HoverButtonStyle(treatment: .icon))
            .help("Supprimer « \(entry.term) »")
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Capsule().fill(hovered ? Theme.brand.opacity(0.12) : Theme.subtleFill))
        .overlay(Capsule().strokeBorder(hovered ? Theme.brand.opacity(0.35) : .clear, lineWidth: 1))
        .scaleEffect(hovered && !reduceMotion ? 1.025 : 1)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.hover, value: hovered)
    }
}

/// Origine d'un mot, en petit dans sa puce : une personne pour « Toi », une étincelle et le juge pour un mot
/// appris, « Avant le suivi » pour un mot plus ancien que ce suivi.
struct OriginBadge: View {
    var origin: DictionaryOrigin

    var body: some View {
        HStack(spacing: 3) {
            switch origin {
            case .user:
                Image(systemName: "person.fill")
            case .learned(let judge):
                Image(systemName: "sparkles")
                Text(DictionaryOriginText.judgeName(judge))
            case .unknown:
                Text("Avant le suivi")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(origin == .unknown ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(Theme.subtleFill))
        .accessibilityElement(children: .ignore)
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
        }
    }

    static func date(_ date: Date, locale: Locale = appLocale) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(locale))
    }
}
