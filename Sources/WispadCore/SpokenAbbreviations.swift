import Foundation

/// Abréviation « v. » de la mise en forme française d'xAI, rendue en « vers », le mot dit. Le fichier complet l'écrit
/// pour « vers » (« aller v. la gare ») : 44 fois dans de vraies dictées d'octobre 2026, là où le flux en direct avait
/// écrit « vers » chaque fois. Ce « v. » rendait flux et fichier différents pour rien, et arrivait
/// jusque dans le texte collé quand la correction le laissait passer. Seulement dans un texte français : en anglais,
/// « v. » abrège « versus ». Ni après un article (« la v. 2 » : une version), ni en majuscule (une initiale).
public enum SpokenAbbreviations {
    /// « v. » minuscule et seul (ni dans un mot, ni collé à un point ou une apostrophe), suivi d'un mot en minuscules
    /// ou d'un nombre : une majuscule après le point ouvre une nouvelle phrase (« la lettre v. Puis… »).
    private static let versus = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_.'’\-])v\.(?=[ \u00A0\u202F]+[\p{Ll}\p{N}«“(])"#
    )
    private static let articles: Set<String> = [
        "la", "le", "les", "l", "un", "une", "ce", "cette", "ma", "ta", "sa", "mon", "ton", "son", "notre", "votre", "leur",
    ]

    public static func restore(_ text: String) -> String {
        guard text.contains("v."), TranscriptLanguage.guess(text) == .french else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in versus.matches(in: text, range: NSRange(location: 0, length: source.length))
        where !articles.contains(previousWord(before: match.range.location, in: source)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + "vers"
            cursor = NSMaxRange(match.range)
        }
        return cursor == 0 ? text : result + source.substring(from: cursor)
    }

    /// Mot qui précède, en minuscules ; vide en début de texte ou après une ponctuation.
    private static func previousWord(before location: Int, in source: NSString) -> String {
        var end = location
        while end > 0, let scalar = Unicode.Scalar(source.character(at: end - 1)), CharacterSet.whitespaces.contains(scalar) {
            end -= 1
        }
        var start = end
        while start > 0, let scalar = Unicode.Scalar(source.character(at: start - 1)), CharacterSet.letters.contains(scalar) {
            start -= 1
        }
        return source.substring(with: NSRange(location: start, length: end - start)).lowercased()
    }
}
