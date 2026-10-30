import Foundation

/// Référence de comparaison, jamais un texte à insérer. Les petits mots grammaticaux nécessaires à l'écrit
/// ne sont pas des informations inventées. Seules des constructions fermées peuvent enrichir cette référence.
enum WrittenGrammar {
    /// L'autorisation ne porte que sur la grammaire reconnue : mêmes mots dans le même ordre, à un « ne/n' »
    /// près. Aucun seuil phonétique, nombre, suppression ou diff incomplet ne peut autoriser une information.
    static func matches(reference: String, corrected: String) -> Bool {
        func keys(_ text: String) -> [String]? {
            let ns = text as NSString
            let words = comparisonPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { match in
                    let token = ns.substring(with: match.range)
                    return boundaries.contains(token) ? "" : token.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                                           locale: Locale(identifier: "fr_FR"))
                }
            var result: [String] = []
            for (index, word) in words.enumerated() {
                if word == "ne" || word == "n" {
                    let following = words.dropFirst(index + 1).prefix(8)
                    // « plus » seul reste ambigu ; pas de négation ajoutée ni de particules répétées en crédit libre.
                    guard let partner = following.firstIndex(where: negativePartners.contains),
                          !words[(index + 1)..<partner].contains(where: { $0.isEmpty || $0 == "ne" || $0 == "n" })
                    else { return nil }
                } else if !word.isEmpty { result.append(word) }
            }
            return result
        }
        guard let referenceWords = keys(reference), let correctedWords = keys(corrected) else { return false }
        return referenceWords == correctedWords
    }

    private static let comparisonPattern = try! NSRegularExpression(pattern: #"[-+−]?[0-9]+(?:[.,][0-9]+)?|[\p{L}\p{N}]+|[-+−%=/<>]|[.!?;:\n]"#)
    private static let boundaries: Set<String> = [".", "!", "?", ";", ":", "\n"]
    private static let negativePartners: Set<String> = ["pas", "jamais", "rien", "personne", "aucun", "aucune", "guere", "ni"]

    static func reference(_ transcript: String) -> String {
        let ns = transcript as NSString
        let protected = protectedPattern.matches(in: transcript, range: NSRange(location: 0, length: ns.length)).map(\.range)
        let result = NSMutableString(string: transcript)
        // Traitement par fragments pour ne jamais développer une citation, du code ou une adresse.
        var start = 0
        var spans: [NSRange] = []
        for range in protected {
            if range.location > start { spans.append(NSRange(location: start, length: range.location - start)) }
            start = NSMaxRange(range)
        }
        if start < ns.length { spans.append(NSRange(location: start, length: ns.length - start)) }
        for range in spans.reversed() {
            // La fin d'une citation n'est pas un début de phrase implicite.
            var fragment = (range.location == 0 ? "" : "x") + ns.substring(with: range)
            for rule in rules {
                fragment = rule.pattern.stringByReplacingMatches(in: fragment,
                    range: NSRange(fragment.startIndex..<fragment.endIndex, in: fragment), withTemplate: rule.replacement)
            }
            result.replaceCharacters(in: range, with: range.location == 0 ? fragment : String(fragment.dropFirst()))
        }
        return result as String
    }

    // Les citations non fermées restent protégées jusqu'à la fin. Une apostrophe dans un mot n'est pas une citation.
    private static let protectedPattern = try! NSRegularExpression(
        pattern: #"```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)|`[^`\n]*(?:`|$)|«[^»]*(?:»|$)|“[^”]*(?:”|$)|‘[^’]*(?:’|$)|(?<![\p{L}\p{N}])'[^']*(?:'|$)|"[^"]*(?:"|$)|https?://\S+|\S+@\S+"#)

    private struct Rule {
        let pattern: NSRegularExpression
        let replacement: String
        init(_ pattern: String, _ replacement: String) {
            self.pattern = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            self.replacement = replacement
        }
    }

    private static let clause = #"(^|[.!?;:,\n]\s*|\b(?:et|mais|car|donc|que|puisque|sinon)\s+)"#
    private static let rules: [Rule] = [
        Rule(#"\bt['’](as|es|avais|auras|aurais|étais|seras|serais)\b"#, "tu $1"),
        Rule(#"\bj['’](sais|suis|peux|veux|dois|vais|crois|pense|vois)\b"#, "je $1"),
        Rule(clause + #"(faut|fallait|faudra|faudrait|fallut)\b"#, "$1il $2"),
        Rule(clause + #"(y\s+(?:en\s+)?(?:a|avait|aura|aurait|ait))\b"#, "$1il $2"),
    ]
}
