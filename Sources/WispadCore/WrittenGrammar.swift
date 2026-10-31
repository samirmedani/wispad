import Foundation

/// Grammaire écrite bornée : la référence sert uniquement au garde-fou ; la finition des sujets impersonnels
/// est distincte et ne développe jamais les contractions ni le texte protégé.
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

    /// Référence de comparaison seulement, jamais un texte de repli ou un texte à insérer.
    static func reference(_ transcript: String) -> String {
        transformingUnprotected(transcript) { fragment in
            var result = fragment
            for rule in rules {
                result = rule.pattern.stringByReplacingMatches(in: result,
                    range: NSRange(result.startIndex..<result.endIndex, in: result), withTemplate: rule.replacement)
            }
            return result
        }
    }

    /// Finition locale d'une correction déjà retenue : seul le sujet impersonnel certain est ajouté.
    /// Un fragment isolé, une interrogation introduite par « que » ou un sujet déjà présent restent tels quels.
    static func completeImpersonalSubjects(_ text: String) -> String {
        transformingUnprotected(text) { fragment in
            let source = fragment as NSString
            let result = NSMutableString(string: fragment)
            let matches = impersonalPattern.matches(in: fragment, range: NSRange(location: 0, length: source.length))
            for match in matches.reversed() {
                let prefix = source.substring(with: match.range(at: 1))
                let verbRange = match.range(at: 2)
                let verb = source.substring(with: verbRange)
                let afterOffset = NSMaxRange(verbRange)
                let firstAfter = afterOffset < source.length
                    ? source.substring(with: source.rangeOfComposedCharacterSequence(at: afterOffset)).first : nil
                // Ni inversion (« faut-il »), ni préfixe d'un identifiant.
                if let first = firstAfter, !first.isWhitespace, !clauseEnds.contains(first) { continue }
                let hasEn = verb.range(of: #"\by\s+en\s+"#, options: [.regularExpression, .caseInsensitive]) != nil
                guard hasEn || (firstAfter?.isWhitespace == true
                    && hasImpersonalComplement(in: fragment, source: source, from: afterOffset)) else { continue }
                let sentenceStart = prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || prefix.contains(where: { ".!?\n\r".contains($0) })
                let allCaps = verb == verb.uppercased()
                let subject = allCaps ? "IL " : sentenceStart ? "Il " : "il "
                result.replaceCharacters(in: verbRange, with: subject + (allCaps ? verb : verb.lowercased()))
            }
            return result as String
        }
    }

    /// Alternative isolée par une pause de la transcription (« … si elle est payée. Ou non. ») : rattachée à la
    /// phrase qui la précède (« … si elle est payée ou non. »). Seulement « ou non » et « ou pas » seuls dans leur
    /// phrase (suivis d'une ponctuation finale ou de la fin du texte), sur la même ligne, après une phrase finie par un
    /// point ou un point d'interrogation ; une question garde son point d'interrogation et son espacement.
    static func joinAlternativeFragments(_ text: String) -> String {
        transformingUnprotected(text) { fragment in
            let source = fragment as NSString
            let result = NSMutableString(string: fragment)
            let matches = alternativePattern.matches(in: fragment, range: NSRange(location: 0, length: source.length))
            for match in matches.reversed() {
                let leading = source.substring(with: match.range(at: 1))
                let previous = source.substring(with: match.range(at: 2))
                let word = source.substring(with: match.range(at: 3))
                let trailing = match.range(at: 4).location == NSNotFound ? "" : source.substring(with: match.range(at: 4))
                let end = match.range(at: 5).location == NSNotFound ? "" : source.substring(with: match.range(at: 5))
                let question = previous == "?" || end == "?"
                let spacing = previous == "?" ? leading : trailing
                let closing = question ? spacing + "?" : end == "!" ? spacing + "!" : "."
                result.replaceCharacters(in: match.range, with: " ou " + word.lowercased() + closing)
            }
            return result as String
        }
    }

    private static let alternativePattern = try! NSRegularExpression(
        pattern: #"(?<=[\p{L}\p{N})»”])(?<!\betc)([ \u00A0\u202F]?)([.?])[ \t\u00A0]+[Oo]u[ \u00A0]+(non|pas|Non|Pas)(?:([ \u00A0\u202F]?)([.?!])(?=[ \t\u00A0]|\n|$)|$)"#)

    /// Exige un complément dans la même proposition ; « faut pas… » ou « y a une… » n'en sont pas.
    private static func hasImpersonalComplement(in text: String, source: NSString, from offset: Int) -> Bool {
        var found = false
        // Lire directement le fragment d'origine et s'arrêter au premier mot utile ou à la frontière : une longue
        // dictée sans ponctuation ne doit pas recopier puis tokeniser tout son suffixe pour chaque proposition.
        complementPattern.enumerateMatches(in: text, range: NSRange(location: offset, length: source.length - offset)) {
            match, _, stop in
            guard let match else { return }
            if match.range(at: 1).location != NSNotFound {
                // CRLF est une frontière comme LF. Une ponctuation suivie d'une marque combinante garde
                // en revanche son caractère complet, au lieu de couper sur l'un de ses points de code.
                let composed = source.substring(with: source.rangeOfComposedCharacterSequence(at: match.range.location))
                if let character = composed.first, clauseEnds.contains(character) { stop.pointee = true }
                return
            }
            let word = source.substring(with: match.range).lowercased()
            if nextClauseWords.contains(word) {
                stop.pointee = true
            } else if !incompleteComplementWords.contains(word) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static let clauseEnds: Set<Character> = Set(".!?;:,\n\r…")
    private static let complementPattern = try! NSRegularExpression(pattern: #"([.!?;:,\n\r…])|[\p{L}\p{N}]+"#)
    private static let nextClauseWords: Set<String> = ["et", "mais", "car", "donc", "sinon"]
    private static let incompleteComplementWords: Set<String> = [
        "ne", "n", "pas", "plus", "moins", "encore", "toujours", "vraiment", "assez", "bien", "mieux",
        "le", "la", "les", "l", "un", "une", "des", "du", "de", "d", "ce", "cet", "cette", "ces",
        "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre", "nos", "votre", "vos", "leur", "leurs",
        "me", "m", "te", "t", "se", "s", "lui", "en", "y", "nous", "vous", "je", "j", "tu", "il", "elle", "ils", "elles",
        "que", "qu", "qui", "si", "à", "au", "aux", "pour", "avec", "sans", "dans", "sur", "sous", "ou", "ni",
    ]
    // « que » est volontairement absent : « Que faut préparer ? » n'a pas un sujet omis à compléter ici.
    private static let impersonalPattern = try! NSRegularExpression(
        pattern: #"(^[\t ]*|[.!?;:,\n\r][\t ]*|\b(?:et|mais|car|donc|sinon)[\t ]+)(faut|fallait|faudra|faudrait|fallut|y[\t ]+(?:en[\t ]+)?(?:a|avait|aura|aurait|ait))\b"#,
        options: .caseInsensitive)

    /// Les deux usages partagent les mêmes frontières de citations, de code et d'adresses.
    private static func transformingUnprotected(_ transcript: String, transform: (String) -> String) -> String {
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
            let fragment = transform((range.location == 0 ? "" : "x") + ns.substring(with: range))
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
