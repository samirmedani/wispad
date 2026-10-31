import SwiftUI
import WispadCore

/// Suggestions tirées de l'historique, en tête de l'écran Dictionnaire : noms que la correction répare souvent,
/// entrées écrites autrement dans les dictées, noms écrits de plusieurs façons. Rien n'est ajouté sans un clic ;
/// « Tout ajouter » les accepte toutes d'un coup.
struct DictionarySuggestionsCard: View {
    @Environment(AppModel.self) private var model
    var suggestions: [DictionaryInsights.Suggestion]
    @State private var expanded = false

    private static let collapsedCount = 3

    /// Une seule suggestion de plus ne vaut pas un bouton : tout est alors affiché.
    private var collapses: Bool { suggestions.count > Self.collapsedCount + 1 }

    var body: some View {
        let shown = expanded || !collapses ? suggestions : Array(suggestions.prefix(Self.collapsedCount))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("Suggestions")
                    .font(.system(size: 13, weight: .semibold))
                Text(suggestions.count, format: .number)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                Spacer(minLength: 8)
                if suggestions.count > 1 {
                    Button {
                        withAnimation(Theme.spring) { model.acceptAllSuggestions() }
                    } label: {
                        Label("Tout ajouter", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Accepter les \(suggestions.count) suggestions")
                } else {
                    Text("D'après tes dictées")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Calculé sur ce Mac à partir de tes dictées des 90 derniers jours. Rien n'est envoyé.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ForEach(shown) { suggestion in
                DictionarySuggestionRow(
                    suggestion: suggestion,
                    onAccept: { withAnimation(Theme.spring) { model.acceptSuggestion(suggestion) } },
                    onIgnore: { withAnimation(Theme.spring) { model.ignoreSuggestion(suggestion) } }
                )
                if suggestion.id != shown.last?.id {
                    Divider().padding(.leading, 56)
                }
            }
            if collapses {
                Divider()
                Button {
                    withAnimation(Theme.spring) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text(expanded ? String(localized: "Afficher moins") : String(localized: "Afficher les \(suggestions.count - Self.collapsedCount) autres"))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct DictionarySuggestionRow: View {
    var suggestion: DictionaryInsights.Suggestion
    var onAccept: () -> Void
    var onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Text(DictionarySuggestionText.detail(suggestion))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(DictionarySuggestionText.action(suggestion), action: onAccept)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(DictionarySuggestionText.actionHelp(suggestion))
            Button(action: onIgnore) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(treatment: .icon))
            .help("Ignorer : « \(suggestion.term) » ne sera plus proposé")
            .accessibilityLabel("Ignorer « \(suggestion.term) »")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var title: some View {
        if case .respell(_, let current, _, _) = suggestion.reason {
            HStack(spacing: 6) {
                Text(current).foregroundStyle(.secondary).strikethrough(color: .secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(suggestion.term)
            }
        } else {
            Text(suggestion.term)
        }
    }

    private var symbol: String {
        switch suggestion.reason {
        case .repeatedFix: return "ear"
        case .respell: return "textformat"
        case .spellings: return "character.cursor.ibeam"
        }
    }

    private var tint: Color {
        switch suggestion.reason {
        case .repeatedFix: return .purple
        case .respell: return .orange
        case .spellings: return .teal
        }
    }
}

/// Textes d'une suggestion : raison en une ligne, bouton et info-bulle.
enum DictionarySuggestionText {
    static func detail(_ suggestion: DictionaryInsights.Suggestion) -> String {
        switch suggestion.reason {
        case .repeatedFix(let heard, let dictations):
            let forms = quoted(Array(heard.prefix(2)))
            // Même mot à la casse près : la reconnaissance l'a écrit autrement, sans le mal entendre.
            if heard.allSatisfy({ DictionaryInsights.key($0) == DictionaryInsights.key(suggestion.term) }) {
                return String(localized: "Mal écrit dans \(dictations) dictées : \(forms)")
            }
            return String(localized: "Mal entendu dans \(dictations) dictées : \(forms)")
        case .respell(_, _, let dictations, let total):
            return String(localized: "Écrit ainsi dans \(dictations) dictées sur \(total)")
        case .spellings(let spellings):
            let forms = spellings.map { String(localized: "« \($0.text) » \($0.dictations) fois") }
            return String(localized: "Écrit de plusieurs façons : \(forms.joined(separator: ", "))")
        }
    }

    static func action(_ suggestion: DictionaryInsights.Suggestion) -> String {
        if case .respell = suggestion.reason { return String(localized: "Corriger") }
        return String(localized: "Ajouter")
    }

    static func actionHelp(_ suggestion: DictionaryInsights.Suggestion) -> String {
        if case .respell(_, let current, _, _) = suggestion.reason {
            return String(localized: "Écrire « \(suggestion.term) » au lieu de « \(current) »")
        }
        return String(localized: "Ajouter « \(suggestion.term) » au dictionnaire")
    }

    private static func quoted(_ forms: [String]) -> String {
        forms.map { String(localized: "« \($0) »") }.joined(separator: ", ")
    }
}

