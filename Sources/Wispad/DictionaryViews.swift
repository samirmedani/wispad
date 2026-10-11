import SwiftUI
import AppKit
import WispadCore

// MARK: - Dictionnaire

struct DictionaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var term = ""
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
                            TermChip(term: entry.term) {
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
                VStack(alignment: .leading, spacing: 14) {
                    CardTitle(model.dictionary.count == 1 ? String(localized: "1 terme") : String(localized: "\(model.dictionary.count) termes"))
                    FlowLayout(spacing: 8) {
                        ForEach(model.dictionary) { entry in
                            TermChip(term: entry.term) {
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
    var term: String
    var onDelete: () -> Void
    @State private var hovering = false

    private var hovered: Bool { isEnabled && (hovering || previewHover) }

    var body: some View {
        HStack(spacing: 6) {
            Text(term)
                .font(.system(size: 12.5, weight: .medium))
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovered ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(hovered ? Theme.subtleFill : .clear))
            }
            .buttonStyle(HoverButtonStyle(treatment: .icon))
            .help("Supprimer « \(term) »")
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
