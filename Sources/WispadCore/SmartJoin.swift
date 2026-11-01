import Foundation

/// Raccord d'une dictée avec le texte déjà présent avant le curseur : deux dictées de suite ne doivent pas
/// se coller (« phrase.Deuxième »). Une espace s'ajoute au besoin, et la casse du premier mot suit l'endroit où la
/// dictée arrive (`fit`) ; jamais un mot n'est ajouté.
public enum SmartJoin {
    /// Caractères après lesquels on colle sans espace : ouverture, apostrophe, trait, barre, retour à la ligne.
    private static let attachAfter: Set<Character> = ["(", "[", "{", "«", "“", "\"", "'", "’", "‘", "/", "\\", "-", "–", "—", "@", "#", "_"]
    /// Caractères qui se collent au texte précédent quand la dictée commence par eux.
    private static let attachBefore: Set<Character> = [",", ".", "…", ")", "]", "}", "»", "”", "'", "’"]

    /// - Parameter before: texte juste avant le point d'insertion (quelques caractères suffisent),
    ///   nil s'il est inconnu (champ illisible) : dans le doute, on ne touche à rien.
    public static func adjust(_ text: String, before: String?) -> String {
        guard let first = text.first, let previous = before?.last else { return text }
        if previous.isWhitespace || previous.isNewline || first.isWhitespace { return text }
        if attachAfter.contains(previous) || attachBefore.contains(first) { return text }
        return " " + text
    }

    /// Texte juste avant le curseur.
    /// - Parameters:
    ///   - read: lu par l'accessibilité au moment du collage ; nil si l'app ne l'expose pas.
    ///   - previous: dernier collage de Wispad dans ce même champ, sans aucune frappe depuis.
    ///   - previousConfirmed: ce collage a été constaté dans le champ, l'accessibilité y est donc à jour.
    public static func textBefore(read: String?, previous: String?, previousConfirmed: Bool) -> String? {
        guard let previous, !previous.isEmpty else { return read }
        guard let read else { return previous }
        // Collage constaté : si la lecture ne le montre plus avant le curseur, c'est que le curseur a bougé.
        if previousConfirmed { return read }
        // Collage pas encore visible (apps Electron qui mettent leur valeur à jour en différé) : on sait
        // pourtant ce qui précède le curseur, puisque Wispad vient de l'y coller.
        let tail = String(previous.suffix(min(16, read.count)))
        return !tail.isEmpty && read.hasSuffix(tail) ? read : previous
    }

    /// Où la dictée arrive, d'après le texte juste avant le curseur.
    public enum Position: Equatable, Sendable {
        /// Texte avant le curseur inconnu (champ illisible) : rien n'est touché.
        case unknown
        /// Début du champ, d'une ligne, ou après « . », « ! », « ? », « … » (guillemet ou parenthèse fermants compris).
        case sentenceStart
        /// Juste après un guillemet ou une parenthèse ouvrants : la casse de la correction est gardée.
        case quoteStart
        /// Au milieu d'une phrase : après un mot, un nombre, « , », « : », « ; » ou un tiret.
        case continuation
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["»", "”", "\"", "'", "’", ")", "]", "}", " ", "\u{00A0}", "\u{202F}"]
    private static let openers: Set<Character> = ["(", "[", "{", "«", "“", "\"", "‘"]

    public static func position(before: String?) -> Position {
        guard let before else { return .unknown }
        var tail = Substring(before)
        while let last = tail.last, last == " " || last == "\t" || last == "\u{00A0}" || last == "\u{202F}" { tail.removeLast() }
        guard let last = tail.last else { return .sentenceStart }
        if last.isNewline { return .sentenceStart }
        var closed = tail
        while let character = closed.last, closers.contains(character) { closed.removeLast() }
        if let character = closed.last, terminators.contains(character) { return .sentenceStart }
        if openers.contains(last) { return .quoteStart }
        return .continuation
    }

    /// Premiers mots courants dont la casse suit la phrase : jamais un nom propre, un sigle ni une marque. Un mot hors
    /// de cette liste garde la casse choisie par la correction, qui connaît le contexte.
    static let commonStarts: Set<String> = [
        "je", "j", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "le", "la", "les", "l", "un", "une", "des",
        "du", "de", "d", "et", "ou", "mais", "donc", "car", "ni", "or", "que", "qu", "qui", "quoi", "quand", "si", "s",
        "ce", "c", "ça", "cela", "ceci", "cette", "ces", "cet", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses",
        "notre", "nos", "votre", "vos", "leur", "leurs", "en", "y", "à", "au", "aux", "dans", "sur", "sous", "avec",
        "sans", "pour", "par", "puis", "alors", "ensuite", "aussi", "même", "très", "plus", "moins", "pas", "ne", "n",
        "comme", "parce", "après", "avant", "demain", "hier", "aujourd", "maintenant", "bon", "enfin", "oui", "non",
        "voilà", "voici", "peut", "faut", "tout", "tous", "toute", "toutes", "sinon", "surtout", "juste",
        "the", "a", "an", "and", "but", "so", "then", "it", "we", "you", "they", "he", "she", "this", "that",
        "these", "those", "my", "your", "our", "their", "to", "in", "at", "for", "with", "of", "if", "when",
        "because", "also", "just", "maybe", "now", "there", "here", "which", "who", "what",
    ]

    /// La dictée accordée à l'endroit où elle arrive : premier mot courant en minuscule au milieu d'une phrase, en
    /// majuscule en début de phrase ; sans point final quand la phrase continue juste après le curseur (`after` commence
    /// par une minuscule). Les autres premiers mots (noms propres, sigles, termes) gardent la casse de la correction.
    public static func fit(_ text: String, before: String?, after: String? = nil) -> String {
        switch position(before: before) {
        case .continuation:
            let lowered = recase(text, upper: false)
            if let next = after?.first(where: { !$0.isWhitespace }), next.isLetter, next.isLowercase {
                return droppingFinalPeriod(lowered)
            }
            return lowered
        case .sentenceStart:
            return recase(text, upper: true)
        case .quoteStart, .unknown:
            return text
        }
    }

    /// Premier mot de la dictée, s'il est courant : « J'ai » donne « J », « Demain » donne « Demain ».
    static func firstCommonWord(_ text: String) -> String.Index? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }), text[start].isLetter else { return nil }
        let word = String(text[start...].prefix { $0.isLetter })
        // Seule l'initiale peut changer : « API », « iOS » ou « McDonald » ne sont jamais des mots courants.
        guard word.dropFirst().allSatisfy(\.isLowercase), commonStarts.contains(word.lowercased()) else { return nil }
        // Une lettre seule n'est prise qu'élidée (« J'ai ») ou pour « à », « a » et « y » : « I » anglais reste.
        if word.count == 1 {
            let next = text[text.index(after: start)...].first
            let elided = next == "'" || next == "’"
            guard elided || ["a", "à", "y"].contains(word.lowercased()) else { return nil }
        }
        return start
    }

    static func recase(_ text: String, upper: Bool) -> String {
        guard let start = firstCommonWord(text) else { return text }
        let first = String(text[start])
        let changed = upper ? first.uppercased() : first.lowercased()
        guard changed != first else { return text }
        return text.replacingCharacters(in: start...start, with: changed)
    }

    /// Un seul point final retiré ; « … », « ... », « ? » et « ! » restent.
    static func droppingFinalPeriod(_ text: String) -> String {
        var trimmed = text
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix(".."), trimmed.count > 1 else { return text }
        trimmed.removeLast()
        return trimmed
    }

    /// La dictée précédente de Wispad, juste avant le curseur, finit par un point que la nouvelle prolonge : la
    /// correction l'a commencée par un mot courant en minuscule (« Je voulais te dire que. » puis « demain on se voit »).
    /// Ce point est alors retiré avant de coller, et la dictée continue la phrase.
    public static func continuesPreviousPaste(_ text: String, before: String?, previous: String?) -> Bool {
        // La lecture du champ ne rend que la fin du texte avant le curseur : la fin du collage précédent suffit.
        guard let before, let previous, previous.hasSuffix("."), !previous.hasSuffix(".."),
              before.hasSuffix(String(previous.suffix(min(16, before.count)))), let start = firstCommonWord(text) else { return false }
        return text[start].isLowercase
    }
}
