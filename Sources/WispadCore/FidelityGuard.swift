import Foundation

/// Garde-fou appliqué au texte rendu par le modèle de correction : il ne garde que des retouches fidèles
/// à ce qui a été dit. Le modèle ne doit ni recopier le contexte, ni traduire un mot, ni inventer une marque.
public enum FidelityGuard {
    /// Texte à coller : la correction si elle est fidèle, sinon la transcription, retouchée au besoin.
    public static func check(
        transcript: String,
        corrected: String,
        context: String? = nil,
        dictionary: [String] = [],
        previousDictations: [String] = [],
        alternative: String? = nil
    ) -> String {
        let heard = locatedWords(in: transcript).map(\.text)
        // Autre écoute du même audio : un mot repris de là a été entendu, ce n'est ni une invention ni une traduction.
        let alsoHeard = alternative.map { locatedWords(in: $0).map(\.text) } ?? []
        let written = locatedWords(in: corrected).map(\.text)
        guard !heard.isEmpty, !written.isEmpty else { return corrected.isEmpty ? transcript : corrected }
        // Une correction enlève des hésitations et ajoute de la ponctuation : elle n'allonge pas le texte.
        if written.count > heard.count + max(4, heard.count / 4) { return transcript }
        if copiesContext(written: written, heard: heard, context: context, additional: previousDictations) { return transcript }
        let repaired = restoreTranslatedWords(
            heard: heard,
            written: written,
            corrected: corrected,
            dictionary: dictionary,
            context: context,
            previousDictations: previousDictations,
            alsoHeard: alsoHeard
        )
        let restored = restoreUnspokenReferences(heard: heard, corrected: repaired, alsoHeard: alsoHeard)
        let spoken = heard.filter { !CorrectionLearner.key($0).isEmpty }.count
        if spoken <= shortDictationWords, changesShortDictation(heard: heard, corrected: restored, alsoHeard: alsoHeard) {
            return transcript
        }
        return restored
    }

    /// Une dictée de trois mots au plus n'offre aucun contexte au modèle : il ne peut qu'y deviner.
    static let shortDictationWords = 3

    /// Sur une dictée courte, seules restent la ponctuation, les majuscules, les hésitations retirées, un « ne »
    /// rétabli et les corrections d'écoute qui sonnent comme le mot entendu (« cloud » → « Claude »).
    /// Un mot qui ne lui ressemble pas (« Était sérieux » → « Sois sérieux ») ou un mot ajouté fait garder la transcription.
    static func changesShortDictation(heard: [String], corrected: String, alsoHeard: [String] = []) -> Bool {
        func keys(_ words: [String]) -> [String] { words.map { CorrectionLearner.key(strip($0)) }.filter { !$0.isEmpty } }
        let otherKeys = Set(keys(alsoHeard))
        for hunk in CorrectionLearner.replacements(keys(locatedWords(in: corrected).map(\.text)), keys(heard), oneSided: true) {
            // Mots retirés (hésitations) : rien d'inventé.
            if hunk.oldWords.isEmpty { continue }
            if hunk.oldWords.allSatisfy(otherKeys.contains) { continue }
            // Les chiffres ont leurs propres contrôles (références, nombres prononcés).
            if (hunk.oldWords + hunk.newWords).contains(where: { $0.contains(where: \.isNumber) }) { continue }
            if hunk.newWords.isEmpty {
                if hunk.oldWords.allSatisfy(restoredNegation.contains) { continue }
                return true
            }
            if soundsAlike(hunk.oldWords.joined(), hunk.newWords.joined()) < 0.45 { return true }
        }
        return false
    }

    /// Le « ne » de la négation, que l'oral omet et que l'écrit rétablit (« je sais pas » → « je ne sais pas »).
    private static let restoredNegation: Set<String> = ["ne", "n"]

    /// Référence qui commence par des lettres et porte des chiffres (DDR4, i9, P95, RTX4090) : ses chiffres
    /// doivent avoir été prononcés. Sinon le modèle l'a complétée ou ajoutée d'après ce qu'il a déjà vu
    /// (« il écrit DDR » → « DDR4 »), et l'on remet les mots entendus. Le contexte ne justifie jamais un chiffre.
    static func restoreUnspokenReferences(heard: [String], corrected: String, alsoHeard: [String] = []) -> String {
        let words = locatedWords(in: corrected)
        let written = words.map(\.text)
        guard written.contains(where: isLetterLedReference) else { return corrected }
        let spoken = spokenReferenceKeys(heard).union(spokenReferenceKeys(alsoHeard))
        func unspoken(_ index: Int, heardHere: [String]) -> Bool {
            let word = written[index]
            guard isLetterLedReference(word) else { return false }
            let key = CorrectionLearner.key(strip(word))
            return !spoken.contains(key) && !renders(key, from: heardHere)
        }
        let text = corrected as NSString
        var edits: [(range: NSRange, replacement: String)] = []
        var covered = IndexSet()
        for hunk in CorrectionLearner.replacements(written.map(strip), heard.map(strip)) where hunk.oldEnd > hunk.oldStart {
            covered.insert(integersIn: hunk.oldStart..<hunk.oldEnd)
            guard (hunk.oldStart..<hunk.oldEnd).contains(where: { unspoken($0, heardHere: hunk.newWords) }) else { continue }
            let first = words[hunk.oldStart]
            let last = words[hunk.oldEnd - 1]
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            guard !text.substring(with: range).contains(where: \.isNewline) else { continue }
            let restored = hunk.newWords.map(strip).filter { !$0.isEmpty }
            edits.append((range, punctuationPrefix(first.text) + restored.joined(separator: " ") + punctuationSuffix(last.text)))
        }
        // Référence ajoutée sans rien d'entendu à sa place : le diff ne la montre pas, on la retire seule,
        // avec l'espace qui la précède, en gardant sa ponctuation finale.
        for index in written.indices where !covered.contains(index) && unspoken(index, heardHere: []) {
            var range = words[index].range
            if range.location > 0, text.substring(with: NSRange(location: range.location - 1, length: 1)) == " " {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            edits.append((range, punctuationSuffix(written[index])))
        }
        let output = NSMutableString(string: corrected)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            output.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return output as String
    }

    /// Lettres d'abord, puis au moins un chiffre ; ni adresse ni chemin.
    private static func isLetterLedReference(_ word: String) -> Bool {
        let trimmed = strip(word)
        guard let first = trimmed.first(where: { $0.isLetter || $0.isNumber }), first.isLetter,
              trimmed.contains(where: \.isNumber),
              !trimmed.contains("@"), !trimmed.contains("/") else { return false }
        return true
    }

    /// Clés des mots entendus, de leurs morceaux (« i9-9700K ») et de deux mots voisins collés (« DDR 4 »).
    private static func spokenReferenceKeys(_ heard: [String]) -> Set<String> {
        var keys = Set<String>()
        let stripped = heard.map(strip)
        for (index, word) in stripped.enumerated() {
            keys.insert(CorrectionLearner.key(word))
            for piece in referenceAtoms(word) { keys.insert(piece) }
            if index + 1 < stripped.count { keys.insert(CorrectionLearner.key(word + stripped[index + 1])) }
        }
        keys.remove("")
        return keys
    }

    /// La référence se lit dans quelques mots entendus voisins (« DDR quatre » → DDR4, « P quatre-vingt-quinze » → P95).
    private static func renders(_ key: String, from heard: [String]) -> Bool {
        let atoms = heard.flatMap(referenceAtoms)
        guard !atoms.isEmpty else { return false }
        for start in atoms.indices {
            for end in (start + 1)...min(atoms.count, start + 8) {
                let window = Array(atoms[start..<end])
                if renderReference(window, abbreviate: false) == key || renderReference(window, abbreviate: true) == key { return true }
                // Une marque qui commence par un nombre anglais (« one plus » → OnePlus) se lit aussi telle quelle.
                if window.joined() == key { return true }
            }
        }
        return false
    }

    /// Huit mots de suite repris du texte voisin ou d'une dictée précédente, absents de la dictée :
    /// le modèle a recopié le contexte.
    static func copiesContext(written: [String], heard: [String], context: String?, additional: [String] = []) -> Bool {
        let sources = [context].compactMap { $0?.isEmpty == false ? $0 : nil } + additional.filter { !$0.isEmpty }
        return sources.contains { copiesOneContext(written: written, heard: heard, context: $0) }
    }

    private static func copiesOneContext(written: [String], heard: [String], context: String) -> Bool {
        guard !context.isEmpty else { return false }
        let around = locatedWords(in: context).map { CorrectionLearner.key($0.text) }
        let said = Set(heard.map(CorrectionLearner.key))
        let keys = written.map(CorrectionLearner.key)
        let span = 8
        guard keys.count >= span, around.count >= span else { return false }
        let windows = Set((0...(around.count - span)).map { around[$0..<($0 + span)].joined(separator: " ") })
        for start in 0...(keys.count - span) {
            let slice = keys[start..<(start + span)]
            if windows.contains(slice.joined(separator: " ")), slice.contains(where: { !said.contains($0) }) { return true }
        }
        return false
    }

    /// Un mot remplacé par un terme du vocabulaire technique qui ne lui ressemble pas à l'oreille
    /// (« outils » → « tools »), ou l'inverse (« tool » → « outil »), est une traduction : on remet le mot entendu.
    /// Les vraies corrections d'écoute se ressemblent (« versel » → « Vercel », « fixe » → « fix »).
    /// Une marque ou une référence absente de tout contexte, et qui ne sonne pas comme les mots remplacés,
    /// est une invention : on remet aussi les mots entendus. Un nombre dicté écrit en chiffres ne l'est pas.
    static func restoreTranslatedWords(
        heard: [String],
        written: [String],
        corrected: String,
        dictionary: [String] = [],
        context: String? = nil,
        previousDictations: [String] = [],
        alsoHeard: [String] = []
    ) -> String {
        // La ponctuation ajoutée à un mot voisin ne doit pas le faire entrer dans le
        // bloc d'une traduction (« outil. Ensuite, » contre « tool. Ensuite »).
        // Le diff conserve les mots, leur casse et leurs accents ; seul l'habillage est ignoré.
        let hunks = CorrectionLearner.replacements(written.map(strip), heard.map(strip))
        guard !hunks.isEmpty else { return corrected }
        let words = locatedWords(in: corrected)
        guard words.count == written.count else { return corrected }
        let known = groundingKeys(transcript: heard.joined(separator: " "), dictionary: dictionary, context: context, previous: previousDictations)
        let otherKeys = Set(alsoHeard.map { CorrectionLearner.key(strip($0)) }).subtracting([""])
        let output = NSMutableString(string: corrected)
        for hunk in hunks.reversed() {
            // Tous les mots écrits viennent de l'autre écoute du même audio : rien à remettre.
            if !otherKeys.isEmpty, hunk.oldWords.allSatisfy({ otherKeys.contains(CorrectionLearner.key(strip($0))) || CorrectionLearner.key(strip($0)).isEmpty }) { continue }
            let fromModel = hunk.oldWords.map(strip).joined(separator: " ")
            let fromSpeech = hunk.newWords.map(strip).joined(separator: " ")
            let similarity = soundsAlike(fromModel, fromSpeech)
            let spoken = isSpokenReference(corrected: fromModel, heard: hunk.newWords)
            let vocabularyTranslation = (1...3).contains(hunk.oldWords.count)
                && (1...3).contains(hunk.newWords.count)
                && (isVocabulary(fromModel) || isVocabulary(fromSpeech))
                && similarity < 0.45
                && !spoken
            let coined = !spoken && similarity < 0.45 && hasUngroundedCoinage(hunk, written: written, known: known)
            guard vocabularyTranslation || coined else { continue }
            let restored = hunk.newWords.map(strip)
            if hunk.oldWords.count == restored.count {
                // Les plages restent celles du texte d'origine : ni indentation, ni retours,
                // ni marqueurs de liste ne sont reconstruits à partir des mots du diff.
                for index in hunk.oldWords.indices.reversed() {
                    let word = words[hunk.oldStart + index]
                    // La réparation d'une traduction n'est pas une réparation des chiffres :
                    // notamment, strip ne doit jamais retirer le signe d'une valeur négative.
                    guard !word.text.contains(where: \.isNumber), !hunk.newWords[index].contains(where: \.isNumber) else { continue }
                    output.replaceCharacters(in: word.range, with: wrapped(restored[index], like: word.text))
                }
            } else {
                guard !hunk.oldWords.contains(where: { $0.contains(where: \.isNumber) }),
                      !hunk.newWords.contains(where: { $0.contains(where: \.isNumber) }) else { continue }
                let first = words[hunk.oldStart]
                let last = words[hunk.oldEnd - 1]
                let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
                let block = (corrected as NSString).substring(with: range)
                // Un bloc de tailles différentes qui franchit une ligne peut joindre deux items.
                // Ce diff n'identifie pas une traduction de façon assez précise pour la réparer.
                guard !block.contains(where: \.isNewline) else { continue }
                let leading = punctuationPrefix(first.text)
                let trailing = punctuationSuffix(last.text)
                output.replaceCharacters(in: range, with: leading + restored.joined(separator: " ") + trailing)
            }
        }
        return output as String
    }

    private struct LocatedWord {
        var text: String
        var range: NSRange
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\S+"#)
    private static let listMarkerPattern = try! NSRegularExpression(pattern: #"^[\t \x{00A0}\x{202F}]*(?:[-*•]|[0-9]+[.)])[\t \x{00A0}\x{202F}]+(?=\S)"#)

    /// Seuls les marqueurs isolés en début de ligne sont de la présentation.
    /// « -12 », « 3.14 », un tiret dans une phrase et le contenu d'un bloc de code restent des mots.
    private static func locatedWords(in text: String) -> [LocatedWord] {
        let ns = text as NSString
        var markers: [NSRange] = []
        var fence: Character?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, range, _, _ in
            guard let line else { return }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let currentFence: Character? = trimmed.hasPrefix("```") ? "`" : trimmed.hasPrefix("~~~") ? "~" : nil
            if let currentFence {
                if fence == nil { fence = currentFence }
                else if fence == currentFence { fence = nil }
                return
            }
            guard fence == nil,
                  let match = listMarkerPattern.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) else { return }
            let lineRange = NSRange(range, in: text)
            markers.append(NSRange(location: lineRange.location + match.range.location, length: match.range.length))
        }
        var markerIndex = 0
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            while markerIndex < markers.count, NSMaxRange(markers[markerIndex]) <= match.range.location { markerIndex += 1 }
            if markerIndex < markers.count {
                let marker = markers[markerIndex]
                if match.range.location >= marker.location, NSMaxRange(match.range) <= NSMaxRange(marker) { return nil }
            }
            return LocatedWord(text: ns.substring(with: match.range), range: match.range)
        }
    }

    private static func wrapped(_ restored: String, like word: String) -> String {
        punctuationPrefix(word) + restored + punctuationSuffix(word)
    }

    private static func punctuationPrefix(_ word: String) -> String {
        String(String.UnicodeScalarView(word.unicodeScalars.prefix { CharacterSet.punctuationCharacters.contains($0) }))
    }

    private static func punctuationSuffix(_ word: String) -> String {
        String(String.UnicodeScalarView(word.unicodeScalars.reversed().prefix { CharacterSet.punctuationCharacters.contains($0) }.reversed()))
    }

    /// 1 = mêmes clés, 0 = rien en commun. Même mesure que l'apprentissage : seuil 0,45.
    private static func soundsAlike(_ corrected: String, _ heard: String) -> Double {
        let a = CorrectionLearner.key(corrected), b = CorrectionLearner.key(heard)
        return 1 - Double(CorrectionLearner.levenshtein(a, b)) / Double(max(a.count, b.count, 1))
    }

    private static func groundingKeys(transcript: String, dictionary: [String], context: String?, previous: [String]) -> Set<String> {
        var keys = Set<String>()
        func absorb(_ text: String) {
            for word in CorrectionLearner.words(in: text) {
                let key = CorrectionLearner.key(strip(word))
                if key.count >= 2 { keys.insert(key) }
            }
        }
        // Le texte voisin et les dictées précédentes aident le modèle à orthographier un mot entendu,
        // mais n'autorisent pas un nom qui ne ressemble pas à ce qui a été dit (« c'est giga » → G.Skill).
        absorb(transcript)
        // Mots entendus séparément puis liés à l'écrit : « envoie le » → « Envoie-le », « c'est à dire » → « c'est-à-dire ».
        let heard = CorrectionLearner.words(in: transcript).map { CorrectionLearner.key(strip($0)) }.filter { !$0.isEmpty }
        for index in heard.indices {
            if index + 1 < heard.count { keys.insert(heard[index] + heard[index + 1]) }
            if index + 2 < heard.count { keys.insert(heard[index] + heard[index + 1] + heard[index + 2]) }
        }
        for term in dictionary { absorb(term) }
        for term in TechVocabulary.all { absorb(term) }
        return keys
    }

    /// Majuscule hors début de phrase, casse mixte, point ou tiret interne, ou lettres et chiffres.
    private static func looksCoined(_ word: String, sentenceStart: Bool) -> Bool {
        let trimmed = strip(word)
        guard trimmed.count >= 2, trimmed.contains(where: \.isLetter) else { return false }
        if trimmed.contains(where: \.isNumber) { return true }
        let inner = trimmed.dropFirst().dropLast()
        if inner.contains(where: { $0 == "." || $0 == "_" || $0 == "-" }) { return true }
        if trimmed.dropFirst().contains(where: \.isUppercase) { return true }
        if !sentenceStart, trimmed.first?.isUppercase == true { return true }
        return false
    }

    private static func isSentenceStart(_ index: Int, words: [String]) -> Bool {
        guard index > 0, index <= words.count else { return true }
        return words[index - 1].contains { ".!?".contains($0) }
    }

    private static func hasUngroundedCoinage(_ hunk: CorrectionLearner.Hunk, written: [String], known: Set<String>) -> Bool {
        guard (1...3).contains(hunk.oldWords.count), (1...12).contains(hunk.newWords.count) else { return false }
        for offset in hunk.oldWords.indices {
            let absolute = hunk.oldStart + offset
            let raw = absolute < written.count ? written[absolute] : hunk.oldWords[offset]
            guard looksCoined(raw, sentenceStart: isSentenceStart(absolute, words: written)) else { continue }
            if !known.contains(CorrectionLearner.key(strip(raw))) { return true }
        }
        return false
    }

    /// Nombres et unités prononcés (français ou anglais), réécrits en chiffres ou en sigle (2666 MHz, 9950X3D).
    private static func isSpokenReference(corrected: String, heard: [String]) -> Bool {
        let target = CorrectionLearner.key(corrected)
        guard !target.isEmpty else { return false }
        guard target.contains(where: \.isNumber) || unitAbbreviations.values.contains(target) else { return false }
        let atoms = heard.flatMap(referenceAtoms)
        guard !atoms.isEmpty else { return false }
        return renderReference(atoms, abbreviate: false) == target || renderReference(atoms, abbreviate: true) == target
    }

    private static func referenceAtoms(_ word: String) -> [String] {
        word.split(whereSeparator: { $0 == "-" || $0 == "‐" || $0 == "—" || $0 == "'" || $0 == "’" || $0 == "´" })
            .compactMap { piece in
                let key = CorrectionLearner.key(String(piece))
                return key.isEmpty ? nil : key
            }
    }

    private static let unitAbbreviations: [String: String] = [
        "megahertz": "mhz", "megaherz": "mhz", "gigahertz": "ghz", "kilohertz": "khz",
        "giga": "go", "gigas": "go", "gigaoctet": "go", "gigaoctets": "go",
        "megaoctet": "mo", "megaoctets": "mo", "mega": "mo", "megas": "mo",
        "tera": "to", "teras": "to", "teraoctet": "to", "teraoctets": "to",
        "kilo": "ko", "kilos": "ko", "kilooctet": "ko", "kilooctets": "ko",
        "gigabyte": "gb", "gigabytes": "gb", "gig": "gb", "gigs": "gb",
        "megabyte": "mb", "megabytes": "mb", "terabyte": "tb", "terabytes": "tb",
        "kilobyte": "kb", "kilobytes": "kb",
    ]

    private static func renderReference(_ atoms: [String], abbreviate: Bool) -> String {
        var result = ""
        var index = 0
        while index < atoms.count {
            if let (value, next) = SpokenNumbers.parse(atoms, from: index), next > index {
                result += String(value)
                index = next
                continue
            }
            let token = atoms[index]
            if abbreviate, let short = unitAbbreviations[token] {
                result += short
            } else {
                result += token
            }
            index += 1
        }
        return result
    }

    private static let vocabulary: Set<String> = Set(TechVocabulary.all.flatMap { CorrectionLearner.words(in: $0) }.map(CorrectionLearner.key))
        .union(["outil", "outils", "parametres", "parametre", "reglages", "requete", "requetes", "latence", "debit", "deploiement", "erreurs"])

    private static func isVocabulary(_ text: String) -> Bool {
        CorrectionLearner.words(in: text).contains { vocabulary.contains(CorrectionLearner.key($0)) }
    }

    private static func strip(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
    }
}
