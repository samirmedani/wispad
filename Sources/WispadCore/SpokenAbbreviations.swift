import Foundation

/// Abréviation « v. » ou « v » de la mise en forme française (xAI), rendue en « vers », le mot dit.
/// Le fichier complet comme le flux peuvent abréger « vers » (« aller v. la gare », « bascule v Nova 2.4 »).
/// Seulement dans un texte français : en anglais, « v. » abrège « versus ». Jamais après un article ou un mot qui
/// désigne une lettre, une touche ou une version (« la v. 2 », « lettre v. Puis… », « touche v », « col en v »),
/// ni en majuscule (une initiale).
public enum SpokenAbbreviations {
    /// « v » ou « v. » minuscule et seul (ni dans un mot, ni collé à un point ou une apostrophe),
    /// suivi d'une espace puis d'un mot, d'un nombre ou d'un guillemet.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_.'’\-])v\.?(?=[ \u00A0\u202F]+[\p{L}\p{N}«“(])"#
    )

    private static let blockedPrevious: Set<String> = [
        // Articles et déterminants (« la v. 2 », « un v »)
        "la", "le", "les", "l", "un", "une", "ce", "cette", "ces",
        "ma", "ta", "sa", "mon", "ton", "son", "notre", "votre", "leur", "leurs",
        // Mots qui annoncent une lettre, une touche, une forme ou une version
        "lettre", "touche", "raccourci", "ctrl", "control", "contrôle", "cmd", "commande", "command",
        "pomme", "alt", "option", "shift", "maj", "col", "en", "a", "à", "de", "du", "des", "ou", "et",
        "point", "axe", "plan", "version", "niveau", "type", "classe", "série", "zone", "modèle",
        "format", "ligne", "colonne", "rang", "profil", "vitamine",
    ]

    /// Mots qui ne suivent pas « vers » (amorces coupées « le site v de Paul », énumérations « v ou w »).
    private static let blockedNext: Set<String> = [
        "de", "du", "des", "et", "ou", "à", "en", "par", "pour", "avec", "sans", "sur", "sous", "dans", "que", "qui",
    ]

    /// Débuts de phrase fréquents en français : après « v. », une majuscule sur l'un d'eux marque une nouvelle phrase
    /// (« La lettre v. Puis la suite. »), pas un nom propre complément de « vers » (« v. Lyon », « v. Nova 2.4 »).
    private static let sentenceStarters: Set<String> = [
        "puis", "mais", "donc", "ensuite", "alors", "cependant", "toutefois", "or", "car", "enfin",
        "et", "ou", "il", "elle", "on", "je", "tu", "nous", "vous", "ils", "elles",
        "ce", "ça", "c", "le", "la", "les", "un", "une", "de", "du", "des",
        "en", "dans", "pour", "sur", "avec", "sans", "si", "quand", "comme", "parce", "voici", "voilà",
    ]

    public static func restore(_ text: String) -> String {
        guard text.contains("v"), TranscriptLanguage.guess(text) == .french else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let matched = source.substring(with: match.range)
            let hasDot = matched.hasSuffix(".")
            let previous = previousWord(before: match.range.location, in: source)
            guard !blockedPrevious.contains(previous) else { continue }
            if !hasDot, previous.isEmpty { continue }
            let next = nextWord(after: NSMaxRange(match.range), in: source)
            guard !next.isEmpty else { continue }
            let nextLower = next.lowercased()
            guard !blockedNext.contains(nextLower) else { continue }
            // Un « v » isolé sans point devant une lettre seule (« a v b ») n'est pas « vers ».
            if !hasDot, next.count == 1, next.first?.isNumber != true { continue }
            // Avec un point, une majuscule sur un mot d'ouverture ouvre une nouvelle phrase.
            if hasDot, next.first?.isUppercase == true, sentenceStarters.contains(nextLower) { continue }
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

    /// Premier mot ou nombre qui suit l'abréviation, en gardant sa casse d'origine.
    private static func nextWord(after location: Int, in source: NSString) -> String {
        let length = source.length
        var start = location
        while start < length, let scalar = Unicode.Scalar(source.character(at: start)),
              CharacterSet.whitespaces.contains(scalar) || scalar == "«" || scalar == "“" || scalar == "(" {
            start += 1
        }
        var end = start
        while end < length, let scalar = Unicode.Scalar(source.character(at: end)),
              CharacterSet.alphanumerics.contains(scalar) {
            end += 1
        }
        return source.substring(with: NSRange(location: start, length: end - start))
    }
}
