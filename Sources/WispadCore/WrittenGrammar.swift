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

    /// Élision purement orale, devant une consonne : « m'créer » → « me créer », « j'pense » → « je pense »,
    /// « d'faire » → « de faire », « qu'tu » → « que tu ». Le français écrit n'élide que devant une voyelle ou un h
    /// muet ; ces formes viennent de la transcription mot pour mot de l'oral et gênaient même en ton détendu
    /// (3 novembre 2026). « t' » reste : il peut valoir « tu » ou « te » (« t'sais », « t'dire »), et « t'as »,
    /// « t'es » sont des formes familières écrites. Jamais devant une majuscule (« N'Golo »), ni dans une citation,
    /// du code ou une adresse.
    static func expandOralElisions(_ text: String) -> String {
        transformingUnprotected(text) { fragment in
            let source = fragment as NSString
            let result = NSMutableString(string: fragment)
            for match in oralElisionPattern.matches(in: fragment, range: NSRange(location: 0, length: source.length)).reversed() {
                let letter = source.substring(with: match.range(at: 1))
                guard let full = elidedWords[letter.lowercased()] else { continue }
                let written = letter.first?.isUppercase == true ? full.prefix(1).uppercased() + full.dropFirst() : full
                result.replaceCharacters(in: match.range, with: written + " ")
            }
            return result as String
        }
    }

    private static let elidedWords = ["j": "je", "m": "me", "s": "se", "d": "de", "l": "le", "c": "ce", "n": "ne", "qu": "que"]
    private static let oralElisionPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’])([JjMmSsDdLlCcNn]|[Qq]u)['’](?=[bcdfgjklmnpqrstvwxzç])"#
    )

    /// Formes orales que la transcription écrit mot pour mot et qu'aucun ton n'écrit ainsi : « s'te plaît » →
    /// « s'il te plaît », « s'vous plaît » → « s'il vous plaît », « y'a » → « y a » (« y'avait », « y'en a » aussi).
    /// Mesuré le 3 novembre 2026 : xAI les écrit ainsi, OpenAI en français standard ; c'était l'essentiel de l'écart.
    static func expandOralSpellings(_ text: String) -> String {
        transformingUnprotected(text) { fragment in
            let range = { (s: String) in NSRange(location: 0, length: (s as NSString).length) }
            let pleased = pleasePattern.stringByReplacingMatches(in: fragment, range: range(fragment),
                                                                 withTemplate: "$1$2il $3 plaît")
            return thereIsPattern.stringByReplacingMatches(in: pleased, range: range(pleased), withTemplate: "$1 $2")
        }
    }

    private static let pleasePattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])([Ss])(['’])(te|vous) pla[iî]t(?![\p{L}\p{N}])"#
    )
    private static let thereIsPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’])([Yy])['’](a|avait|aura|aurait|en)(?![\p{L}\p{N}'’])"#
    )

    /// Mot ou paire de mots dits deux fois de suite (bégaiement, faux départ) : « tu tu peux » → « tu peux »,
    /// « la même la même » → « la même ». Séparés par une virgule, seul un petit mot grammatical hésitant est retiré
    /// (« c'est, c'est une offre », « Il, il coûterait », « en, en local ») : une paire répétée après une virgule est
    /// souvent voulue (« si c'est demain, c'est demain », « je veux, je veux pas »). La première occurrence reste,
    /// casse comprise. Les répétitions voulues restent : verbes pronominaux (« nous nous voyons »), insistance (« non
    /// non », « très très », « vas-y, vas-y », « du tout, du tout »), mise en relief (« ça, ça sent », « elle, elle »),
    /// « c'est qui qui », « faire faire », nombres, nom propre doublé (« Bora Bora »), citations et code. Vérifié sur
    /// 4 116 dictées réelles le 3 novembre 2026.
    static func removeRepeatedWords(_ text: String) -> String {
        transformingUnprotected(text) { fragment in
            var current = fragment
            for pattern in [repeatedPairPattern, repeatedWordPattern] {
                for _ in 0..<4 {
                    let source = current as NSString
                    let result = NSMutableString(string: current)
                    var changed = false
                    for match in pattern.matches(in: current, range: NSRange(location: 0, length: source.length)).reversed() {
                        let first = source.substring(with: match.range(at: 1))
                        let whole = source.substring(with: match.range) as NSString
                        let second = whole.substring(from: whole.length - (first as NSString).length)
                        let words = first.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                        if first.contains(where: \.isNumber) || words.contains(where: intendedRepeats.contains) { continue }
                        if whole.range(of: ",").location != NSNotFound {
                            guard pattern === repeatedWordPattern,
                                  let word = words.first, hesitantWords.contains(word.replacingOccurrences(of: "’", with: "'"))
                            else { continue }
                        }
                        // Nom propre doublé (« Bora Bora ») : les deux avec une majuscule.
                        if first.first?.isUppercase == true, second.first?.isUppercase == true { continue }
                        result.replaceCharacters(in: match.range, with: first)
                        changed = true
                    }
                    current = result as String
                    if !changed { break }
                }
            }
            return current
        }
    }

    private static let repeatedWordPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’-])([\p{L}\p{N}'’-]+)(?:[ \t]*,[ \t]*|[ \t]+)\1(?![\p{L}\p{N}'’-])"#,
        options: [.caseInsensitive]
    )
    private static let repeatedPairPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’-])([\p{L}\p{N}'’-]+[ \t]+[\p{L}\p{N}'’-]+)(?:[ \t]*,[ \t]*|[ \t]+)\1(?![\p{L}\p{N}'’-])"#,
        options: [.caseInsensitive]
    )
    private static let intendedRepeats: Set<String> = [
        "nous", "vous", "elle", "elles", "lui", "eux", "si", "non", "oui", "ouais", "très", "trop", "bien", "bon",
        "vite", "encore", "doucement", "allez", "bye", "ciao", "ah", "ha", "oh", "eh", "hé", "hein", "ok", "okay",
        "hop", "bla", "toc", "tic", "tac", "coucou", "chut", "pareil", "petit", "nan", "ça", "là", "qui", "tout",
        "beaucoup", "méga", "super", "hyper", "machin", "truc", "voilà", "vas-y", "cetera", "d'accord", "d’accord",
        "plus", "faire",
    ]
    /// Petits mots qu'une hésitation répète avant une virgule (« c'est, c'est », « il, il », « le, le fader »).
    private static let hesitantWords: Set<String> = [
        "je", "tu", "il", "ils", "on", "le", "la", "les", "un", "une", "des", "de", "du", "en", "à", "au", "aux",
        "dans", "pour", "par", "sur", "avec", "et", "mais", "ou", "que", "ce", "cette", "ces", "y", "ne", "se",
        "sa", "son", "ses", "mon", "ma", "mes", "ton", "ta", "tes", "leur", "leurs", "est", "a",
        "c'est", "j'ai", "t'as", "t'es", "qu'il", "qu'on", "l'a", "n'est",
    ]

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
