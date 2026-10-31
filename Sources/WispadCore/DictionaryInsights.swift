import Foundation

/// Ce que l'historique local dit du dictionnaire, sans réseau ni modèle : les noms que la correction répare d'une
/// dictée à l'autre, une entrée écrite autrement dans les dictées, un nom écrit de plusieurs façons, et le nombre de
/// dictées où apparaît chaque entrée. Rien n'est ajouté ici : l'écran Dictionnaire propose et l'utilisateur décide ;
/// seul l'apprentissage ajoute de lui-même un nom réparé dans plusieurs dictées, après l'avis du juge (`TermJudge`).
public enum DictionaryInsights {
    /// Un nom est proposé, puis appris, quand la correction l'a réparé dans au moins ce nombre de dictées.
    public static let repeatThreshold = 2
    /// Seules les dictées de cette période comptent pour les suggestions et l'apprentissage.
    public static let window: TimeInterval = 90 * 86_400
    public static let maxSuggestions = 20
    /// Une entrée est à réécrire quand une autre écriture domine nettement dans les dictées.
    static let respellShare = 0.75
    static let respellMinimum = 3
    /// Un nom est écrit de plusieurs façons quand chaque écriture revient dans au moins ce nombre de dictées.
    static let spellingMinimum = 2
    /// Une dictée trop réécrite (consigne sur une sélection, traduction) ne dit rien des noms mal entendus.
    static let minimumOverlap = 0.5

    // MARK: Données

    /// Une dictée de l'historique : texte transcrit et texte final, après correction.
    public struct Dictation: Equatable, Sendable {
        public var id: String
        public var date: Date
        public var raw: String
        public var final: String

        public init(id: String, date: Date, raw: String, final: String) {
            self.id = id
            self.date = date
            self.raw = raw
            self.final = final
        }

        public init(_ record: DictationRecord) {
            self.init(id: record.id, date: record.createdAt, raw: record.rawText, final: record.finalText)
        }
    }

    /// Nom réparé par la correction dans une dictée : ce que la reconnaissance avait entendu, et ce qui a été écrit.
    public struct Fix: Hashable, Sendable {
        public var heard: String
        public var written: String

        public init(heard: String, written: String) {
            self.heard = heard
            self.written = written
        }
    }

    /// Une écriture d'un nom, et le nombre de dictées où elle apparaît.
    public struct Spelling: Equatable, Sendable {
        public var text: String
        public var dictations: Int

        public init(text: String, dictations: Int) {
            self.text = text
            self.dictations = dictations
        }
    }

    /// Réparations d'un même nom (sans tenir compte de la casse ni des accents) dans les dictées récentes.
    public struct RepeatedFix: Equatable, Sendable {
        /// Écriture la plus fréquente.
        public var term: String
        /// Ce que la reconnaissance avait entendu, du plus fréquent au moins fréquent.
        public var heard: [String]
        public var dictations: Int
        public var lastSeen: Date
    }

    public struct Suggestion: Identifiable, Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// La correction a réparé ce nom dans plusieurs dictées ; `heard` : ce qui avait été entendu.
            case repeatedFix(heard: [String], dictations: Int)
            /// L'entrée `entryID`, écrite `current`, apparaît écrite comme le terme proposé dans `dictations` des
            /// `total` dictées qui la contiennent.
            case respell(entryID: String, current: String, dictations: Int, total: Int)
            /// Le même nom est écrit de plusieurs façons, la plus fréquente d'abord.
            case spellings([Spelling])
        }

        /// Terme à ajouter, ou nouvelle écriture de l'entrée.
        public var term: String
        public var reason: Reason

        public init(term: String, reason: Reason) {
            self.term = term
            self.reason = reason
        }

        public var id: String {
            switch reason {
            case .repeatedFix: return "fix:" + DictionaryInsights.key(term)
            case .respell(let entryID, _, _, _): return "respell:" + entryID
            case .spellings: return "spelling:" + DictionaryInsights.key(term)
            }
        }
    }

    public struct Report: Equatable, Sendable {
        public var suggestions: [Suggestion]
        /// Nombre de dictées où apparaît chaque entrée, par identifiant d'entrée ; absente : aucune.
        public var usage: [String: Int]

        public init(suggestions: [Suggestion] = [], usage: [String: Int] = [:]) {
            self.suggestions = suggestions
            self.usage = usage
        }
    }

    // MARK: Analyse

    /// Dictées de la fenêtre des suggestions, avec un texte final.
    public static func recent(_ dictations: [Dictation], now: Date = Date()) -> [Dictation] {
        let start = now.addingTimeInterval(-window)
        return dictations.filter { $0.date >= start && !$0.final.isEmpty }
    }

    /// Réparations de chaque dictée récente. `known` : celles déjà calculées, reprises telles quelles.
    public static func fixIndex(_ dictations: [Dictation], known: [String: [Fix]] = [:]) -> [String: [Fix]] {
        var index: [String: [Fix]] = [:]
        index.reserveCapacity(dictations.count)
        for dictation in dictations {
            index[dictation.id] = known[dictation.id] ?? fixes(raw: dictation.raw, final: dictation.final)
        }
        return index
    }

    /// Suggestions et usage du dictionnaire. Le second résultat contient les réparations de toutes les dictées
    /// récentes, à repasser en `known` la fois suivante.
    public static func analyze(_ dictations: [Dictation], dictionary: [DictionaryEntry], refused: [String],
                               now: Date = Date(), known: [String: [Fix]] = [:]) -> (report: Report, fixes: [String: [Fix]]) {
        let recentDictations = recent(dictations, now: now)
        let index = fixIndex(recentDictations, known: known)
        let exclusions = Exclusions(dictionary: dictionary, refused: refused)
        var suggestions: [Suggestion] = repeatedFixes(recentDictations, fixes: index).values
            .filter { $0.dictations >= repeatThreshold && !exclusions.excludes($0.term) }
            .sorted { ($0.dictations, $0.lastSeen, $1.term) > ($1.dictations, $1.lastSeen, $0.term) }
            .map { Suggestion(term: $0.term, reason: .repeatedFix(heard: Array($0.heard.prefix(3)), dictations: $0.dictations)) }
        let spellings = SpellingTally(recentDictations.map(\.final), dictionary: dictionary)
        suggestions += respellSuggestions(dictionary, spellings: spellings, refused: exclusions.refused)
        let taken = Set(suggestions.map { key($0.term) })
        suggestions += spellingSuggestions(spellings, exclusions: exclusions).filter { !taken.contains(key($0.term)) }
        let report = Report(suggestions: Array(suggestions.prefix(maxSuggestions)),
                            usage: usage(of: dictionary, in: dictations.map(\.final)))
        return (report, index)
    }

    /// Noms de `current` réparés dans au moins `repeatThreshold` dictées récentes en comptant celle-ci, hors noms
    /// déjà au dictionnaire, refusés ou du vocabulaire intégré. Le terme est écrit comme le plus souvent ; `heard`
    /// reste celui de cette dictée.
    public static func learnable(_ current: [Fix], currentID: String, recent: [Dictation], fixes index: [String: [Fix]],
                                 dictionary: [DictionaryEntry], refused: [String]) -> [Fix] {
        guard !current.isEmpty else { return [] }
        let others = recent.filter { $0.id != currentID }
        var tally = index
        tally[currentID] = current
        let repeated = repeatedFixes(others + [Dictation(id: currentID, date: .distantFuture, raw: "", final: "")], fixes: tally)
        let exclusions = Exclusions(dictionary: dictionary, refused: refused)
        return current.compactMap { fix in
            guard let group = repeated[key(fix.written)], group.dictations >= repeatThreshold,
                  !exclusions.excludes(group.term) else { return nil }
            return Fix(heard: fix.heard, written: group.term)
        }
    }

    /// Noms de la dictée `final` écrits de plusieurs façons dans les dictées récentes (elle comprise) : chaque écriture
    /// dans au moins `spellingMinimum` dictées, dont une graphie marquée (« TestFlight » / « Testflight »), absents du
    /// dictionnaire et jamais refusés. Pour chacun, la graphie marquée la plus fréquente et l'autre écriture la plus
    /// fréquente, à soumettre au juge. Seuls les noms écrits avec une majuscule dans cette dictée comptent, et seules
    /// les dictées qui les contiennent sont relues : l'analyse reste légère après chaque dictée.
    public static func learnableSpellings(final: String, recent: [Dictation], dictionary: [DictionaryEntry],
                                          refused: [String]) -> [Fix] {
        let words = CorrectionLearner.words(in: final)
        var names: [String: String] = [:]
        for (index, word) in words.enumerated() {
            let bare = droppingElision(CorrectionLearner.strip(word))
            guard bare.filter(\.isLetter).count >= 2, bare.contains(where: \.isUppercase) else { continue }
            let shape = Shape([String(bare)], startsSentence: startsSentence(at: index, in: words))
            guard shape.isMarked || shape.isProperNoun else { continue }
            names[fastKey(bare)] = String(bare)
        }
        guard !names.isEmpty else { return [] }
        let related = recent.map(\.final).filter { text in
            names.values.contains { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        let tally = SpellingTally(related, dictionary: dictionary)
        let exclusions = Exclusions(dictionary: dictionary, refused: refused)
        return spellingSuggestions(tally, exclusions: exclusions).compactMap { suggestion -> Fix? in
            guard names[key(suggestion.term)] != nil, case .spellings(let forms) = suggestion.reason,
                  let other = forms.first(where: { $0.text != suggestion.term }) else { return nil }
            return Fix(heard: other.text, written: suggestion.term)
        }
        .prefix(CorrectionLearner.maxTermsPerDictation)
        .map { $0 }
    }

    /// Réparations regroupées par nom ; une dictée compte une fois par nom.
    public static func repeatedFixes(_ dictations: [Dictation], fixes index: [String: [Fix]]) -> [String: RepeatedFix] {
        var written: [String: [String: Int]] = [:]
        var heard: [String: [String: Int]] = [:]
        var counts: [String: Int] = [:]
        var lastSeen: [String: Date] = [:]
        for dictation in dictations {
            var seen = Set<String>()
            for fix in index[dictation.id] ?? [] {
                let group = key(fix.written)
                guard !group.isEmpty, seen.insert(group).inserted else { continue }
                counts[group, default: 0] += 1
                written[group, default: [:]][fix.written, default: 0] += 1
                heard[group, default: [:]][fix.heard, default: 0] += 1
                lastSeen[group] = max(lastSeen[group] ?? .distantPast, dictation.date)
            }
        }
        var result: [String: RepeatedFix] = [:]
        for (group, count) in counts {
            result[group] = RepeatedFix(term: ranked(written[group] ?? [:]).first ?? group, heard: ranked(heard[group] ?? [:]),
                                        dictations: count, lastSeen: lastSeen[group] ?? .distantPast)
        }
        return result
    }

    // MARK: Réparations d'une dictée

    /// Noms mal entendus que la correction a réparés : 1 à 3 mots entendus remplacés par 1 ou 2 mots qui sonnent
    /// pareil, à graphie de nom (majuscule hors début de phrase, majuscule intérieure, sigle, lettres et chiffres),
    /// avec les mêmes chiffres. La grammaire, la ponctuation, l'élision et les mots courants ne comptent pas.
    public static func fixes(raw: String, final: String) -> [Fix] {
        let old = CorrectionLearner.words(in: raw)
        let new = CorrectionLearner.words(in: final)
        guard !old.isEmpty, !new.isEmpty, old != new else { return [] }
        let hunks = CorrectionLearner.replacements(old, new, oneSided: true)
        // Mots gardés, à la ponctuation et à la casse près : « sur » → « sur », mais aussi « mobile » → « mobile. ».
        var kept = old.count - hunks.reduce(0) { $0 + $1.oldWords.count }
        var candidates: [Piece] = []
        for hunk in hunks where !hunk.oldWords.isEmpty && !hunk.newWords.isEmpty {
            for piece in pieces(of: hunk) {
                if piece.heard.count == 1, piece.written.count == 1, key(piece.heard[0]) == key(piece.written[0]) { kept += 1 }
                candidates.append(piece)
            }
        }
        guard Double(kept) / Double(max(old.count, new.count)) >= minimumOverlap else { return [] }
        var found: [Fix] = []
        var groups = Set<String>()
        for piece in candidates {
            guard let fix = fix(heard: piece.heard, written: piece.written, at: piece.newStart, in: new),
                  groups.insert(key(fix.written)).inserted else { continue }
            found.append(fix)
        }
        return found
    }

    /// Partie d'un bloc remplacé, avec la position de ses mots écrits dans le texte final.
    struct Piece: Equatable {
        var heard: [String]
        var written: [String]
        var newStart: Int
    }

    /// Le diff compare les mots avec leur ponctuation : « voilà » et « voilà. » diffèrent. Les mots identiques à la
    /// ponctuation et à la casse près, en bord de bloc, sont donc examinés seuls (changement de casse) ; un bloc de
    /// même longueur dont chaque mot ressemble à son vis-à-vis (« Harness Cloud » → « harnais Claude ») l'est mot à mot.
    static func pieces(of hunk: CorrectionLearner.Hunk) -> [Piece] {
        var old = hunk.oldWords[...]
        var new = hunk.newWords[...]
        var start = hunk.newStart
        var pieces: [Piece] = []
        while let heard = old.first, let written = new.first, key(heard) == key(written) {
            pieces.append(Piece(heard: [heard], written: [written], newStart: start))
            old = old.dropFirst()
            new = new.dropFirst()
            start += 1
        }
        while let heard = old.last, let written = new.last, key(heard) == key(written) {
            pieces.append(Piece(heard: [heard], written: [written], newStart: start + new.count - 1))
            old = old.dropLast()
            new = new.dropLast()
        }
        guard !old.isEmpty, !new.isEmpty else { return pieces }
        if old.count == new.count, old.count > 1, zip(old, new).allSatisfy({ similar($0, $1) }) {
            for (offset, pair) in zip(old, new).enumerated() {
                pieces.append(Piece(heard: [pair.0], written: [pair.1], newStart: start + offset))
            }
        } else {
            pieces.append(Piece(heard: Array(old), written: Array(new), newStart: start))
        }
        return pieces
    }

    static func fix(heard heardWords: [String], written writtenWords: [String], at newStart: Int, in new: [String]) -> Fix? {
        // Mots sans la ponctuation qui les entoure ; un signe isolé (« - ») disparaît.
        let kept = writtenWords.indices.map { (CorrectionLearner.strip(writtenWords[$0]), newStart + $0) }.filter { !$0.0.isEmpty }
        var written = kept.map(\.0)
        var positions = kept.map(\.1)
        var heard = heardWords.map(CorrectionLearner.strip).filter { !$0.isEmpty }
        trimEdges(&written, positions: &positions)
        var heardPositions = Array(heard.indices)
        trimEdges(&heard, positions: &heardPositions)
        // Une fois les mots-outils retirés, des mots identiques peuvent border le nom (« Comme Grenoble quoi » →
        // « comme Grenoble ») : seul ce qui change compte. Une paire seule reste, pour un changement de casse.
        while heard.count + written.count > 2, let first = heard.first, let other = written.first, key(first) == key(other) {
            heard.removeFirst()
            written.removeFirst()
            positions.removeFirst()
        }
        while heard.count + written.count > 2, let last = heard.last, let other = written.last, key(last) == key(other) {
            heard.removeLast()
            written.removeLast()
            positions.removeLast()
        }
        guard (1...3).contains(heard.count), (1...2).contains(written.count) else { return nil }
        let heardText = heard.joined(separator: " ")
        let writtenText = written.joined(separator: " ")
        let heardKey = key(heardText), writtenKey = key(writtenText)
        guard heardText != writtenText, writtenKey.count >= 3, writtenText.filter(\.isLetter).count >= 2,
              writtenText.contains(where: \.isUppercase),
              heardText.filter(\.isNumber) == writtenText.filter(\.isNumber),
              !commonWords.contains(writtenKey) else { return nil }
        let shape = Shape(written, startsSentence: positions.map { startsSentence(at: $0, in: new) })
        if heardKey == writtenKey {
            // Casse, accents ou découpage seulement : utile pour une graphie marquée (« openai » → « OpenAI »,
            // « cli » → « CLI », « Photo Prism » → « PhotoPrism »), jamais pour une simple espace (« 12 h » → « 12h »).
            let recased = heardText.filter(\.isLetter) != writtenText.filter(\.isLetter)
            let rejoined = heard.count != written.count
            return shape.isMarked && (recased || rejoined) ? Fix(heard: heardText, written: writtenText) : nil
        }
        guard shape.isMarked || shape.isProperNoun else { return nil }
        // « Download » → « Downloads » : un accord, même avec une majuscule.
        if CorrectionLearner.isInflection(heardKey, writtenKey), !shape.isMarked { return nil }
        let similarity = 1 - Double(CorrectionLearner.levenshtein(heardKey, writtenKey)) / Double(max(heardKey.count, writtenKey.count))
        return similarity >= 0.45 ? Fix(heard: heardText, written: writtenText) : nil
    }

    /// Deux mots qui se ressemblent assez pour être une même réparation.
    static func similar(_ heard: String, _ written: String) -> Bool {
        let left = key(heard), right = key(written)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return 1 - Double(CorrectionLearner.levenshtein(left, right)) / Double(max(left.count, right.count)) >= 0.45
    }

    /// Retire l'élision du premier mot (« qu'Opus » → « Opus ») et, en bord, les hésitations et les mots-outils
    /// (« que Opus », « Non Codex ») : seul le nom compte.
    private static func trimEdges(_ words: inout [String], positions: inout [Int]) {
        if let first = words.first {
            words[0] = String(droppingElision(first))
        }
        while let first = words.first, first.isEmpty || edgeWords.contains(first.lowercased()) {
            words.removeFirst()
            positions.removeFirst()
            if let next = words.first { words[0] = String(droppingElision(next)) }
        }
        while let last = words.last, last.isEmpty || edgeWords.contains(last.lowercased()) {
            words.removeLast()
            positions.removeLast()
        }
    }

    /// Hésitations et mots-outils qui bordent un nom réparé sans en faire partie.
    static let edgeWords: Set<String> = [
        "euh", "heu", "hum", "hmm", "bah", "ben", "beh", "genre",
        "le", "la", "les", "l", "de", "du", "des", "d", "un", "une", "que", "qu", "qui", "au", "aux", "en", "et", "ou",
        "mais", "donc", "car", "non", "oui", "ouais", "pour", "par", "sur", "dans", "avec", "à", "a", "y", "ce", "ça",
        "c", "il", "ils", "elle", "elles", "on", "je", "j", "tu", "t", "nous", "vous", "se", "s", "sa", "son", "ses",
        "mon", "ma", "mes", "ton", "ta", "tes", "the", "an"
    ]

    /// Mots courants qu'une graphie de sigle ne rend pas intéressants.
    static let commonWords: Set<String> = ["ok", "okay", "ko", "tv", "pc", "ps", "nb", "etc", "vs", "rdv", "lol", "mdr", "ptdr"]

    /// Un mot en tête de phrase, après un tiret de liste ou un guillemet ouvrant : sa majuscule ne dit rien.
    static func startsSentence(at index: Int, in words: [String]) -> Bool {
        guard index > 0, index <= words.count else { return true }
        if index < words.count, let first = words[index].first, "«\"“‘'([".contains(first) { return true }
        let previous = words[index - 1]
        guard previous.contains(where: { $0.isLetter || $0.isNumber }), let last = previous.last else { return true }
        return ".!?…:".contains(last)
    }

    /// Graphie d'un ou deux mots, sans l'élision (« l' », « d' »…) qui les précède.
    struct Shape {
        /// Majuscule intérieure (« RevenueCat », « iPhone »), sigle d'au moins deux lettres (« CLI ») ou lettres et
        /// chiffres mêlés (« DDR4 »).
        var isMarked = false
        /// Majuscule initiale hors début de phrase (« Kbis » au milieu d'une phrase, « Meta Ads »).
        var isProperNoun = false

        /// `startsSentence` : pour chaque mot, s'il ouvre une phrase.
        init(_ words: [String], startsSentence starts: [Bool]) {
            for (position, word) in words.enumerated() {
                let letters = Array(DictionaryInsights.droppingElision(word).filter(\.isLetter))
                guard let first = letters.first else { continue }
                let hasLower = letters.contains(where: \.isLowercase)
                if letters.dropFirst().contains(where: \.isUppercase), hasLower { isMarked = true }
                if letters.count >= 2, !hasLower { isMarked = true }
                if word.contains(where: \.isNumber) { isMarked = true }
                let opensSentence = position < starts.count ? starts[position] : false
                if first.isUppercase, !opensSentence { isProperNoun = true }
            }
        }

        /// `startsSentence` : le premier mot ouvre une phrase ; les suivants, jamais.
        init(_ words: [String], startsSentence: Bool) {
            self.init(words, startsSentence: [startsSentence])
        }
    }

    /// « l'API » → « API », « d'OpenAI » → « OpenAI ».
    static func droppingElision(_ word: String) -> Substring {
        guard let apostrophe = word.firstIndex(where: { $0 == "'" || $0 == "’" }) else { return Substring(word) }
        let prefix = word[..<apostrophe].lowercased()
        guard ["l", "d", "j", "n", "s", "c", "m", "t", "qu", "jusqu", "lorsqu", "puisqu"].contains(prefix) else { return Substring(word) }
        return word[word.index(after: apostrophe)...]
    }

    // MARK: Écritures

    /// Écritures des mots de chaque dictée : nombre de dictées par écriture, regroupées par clé. Seuls comptent les
    /// mots qui ont au moins une fois une graphie de nom (ou une entrée du dictionnaire) ; un mot en début de phrase
    /// ne compte pas, sauf graphie marquée, car sa majuscule ne dit rien.
    struct SpellingTally {
        var forms: [String: [String: Int]] = [:]

        init(_ texts: [String], dictionary: [DictionaryEntry]) {
            let tokenized = texts.map { CorrectionLearner.words(in: $0) }
            var interesting = Set(dictionary.map(\.term).filter { !$0.contains(where: \.isWhitespace) }.map { DictionaryInsights.key(String(DictionaryInsights.droppingElision($0))) })
            for words in tokenized {
                for (index, word) in words.enumerated() {
                    let bare = DictionaryInsights.droppingElision(CorrectionLearner.strip(word))
                    guard bare.contains(where: \.isUppercase) else { continue }
                    let shape = Shape([String(bare)], startsSentence: DictionaryInsights.startsSentence(at: index, in: words))
                    if shape.isMarked || shape.isProperNoun { interesting.insert(DictionaryInsights.fastKey(bare)) }
                }
            }
            interesting.remove("")
            for words in tokenized {
                var seen = Set<String>()
                for (index, word) in words.enumerated() {
                    let bare = DictionaryInsights.droppingElision(CorrectionLearner.strip(word))
                    guard bare.contains(where: \.isLetter) else { continue }
                    let group = DictionaryInsights.fastKey(bare)
                    guard interesting.contains(group) else { continue }
                    if bare.first?.isUppercase == true, DictionaryInsights.startsSentence(at: index, in: words),
                       !Shape([String(bare)], startsSentence: true).isMarked { continue }
                    let spelling = String(bare)
                    if seen.insert(spelling).inserted { forms[group, default: [:]][spelling, default: 0] += 1 }
                }
            }
        }

        func spellings(of group: String) -> [Spelling] {
            (forms[group] ?? [:]).map { Spelling(text: $0.key, dictations: $0.value) }
                .sorted { $0.dictations != $1.dictations ? $0.dictations > $1.dictations : $0.text < $1.text }
        }
    }

    /// Entrée d'un seul mot écrite autrement dans la plupart des dictées où elle apparaît (« codex » → « Codex »).
    static func respellSuggestions(_ dictionary: [DictionaryEntry], spellings: SpellingTally, refused: Set<String>) -> [Suggestion] {
        dictionary.compactMap { entry in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.contains(where: \.isWhitespace), !term.contains(where: { $0 == "'" || $0 == "’" }) else { return nil }
            let forms = spellings.spellings(of: key(term))
            let total = forms.reduce(0) { $0 + $1.dictations }
            // « Ignorer » refuse la nouvelle écriture ; les refus ne gardent pas la casse.
            guard let best = forms.first, best.text != term, best.dictations >= respellMinimum, best.text.contains(where: \.isUppercase),
                  Double(best.dictations) / Double(total) >= respellShare, !refused.contains(key(term)) else { return nil }
            return Suggestion(term: best.text, reason: .respell(entryID: entry.id, current: term, dictations: best.dictations, total: total))
        }
        .sorted { lhs, rhs in
            if case .respell(_, _, let left, _) = lhs.reason, case .respell(_, _, let right, _) = rhs.reason, left != right { return left > right }
            return lhs.term < rhs.term
        }
    }

    /// Nom absent du dictionnaire écrit de plusieurs façons, dont une graphie marquée (« DeepSeek » / « Deepseek ») :
    /// la graphie marquée la plus fréquente est proposée.
    static func spellingSuggestions(_ spellings: SpellingTally, exclusions: Exclusions) -> [Suggestion] {
        spellings.forms.keys.compactMap { group -> (Suggestion, Int)? in
            let forms = spellings.spellings(of: group).filter { $0.dictations >= spellingMinimum }
            guard forms.count >= 2, let best = forms.first(where: { isNameSpelling($0.text) }),
                  !exclusions.excludes(best.text) else { return nil }
            return (Suggestion(term: best.text, reason: .spellings(Array(forms.prefix(3)))), forms.reduce(0) { $0 + $1.dictations })
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.term < $1.0.term }
        .map(\.0)
    }

    /// Graphie de nom à proposer : marquée (« DeepSeek », « CLI », « DDR4 »), avec au moins deux lettres et une majuscule.
    static func isNameSpelling(_ text: String) -> Bool {
        text.filter(\.isLetter).count >= 2 && text.contains(where: \.isUppercase) && Shape([text], startsSentence: true).isMarked
    }

    // MARK: Usage

    /// Nombre de dictées dont le texte final contient chaque entrée, en mots entiers, sans tenir compte de la casse,
    /// des accents ni de la ponctuation.
    public static func usage(of entries: [DictionaryEntry], in texts: [String]) -> [String: Int] {
        let targets = entries.map { ($0.id, normalizedWords($0.term)) }.filter { !$0.1.isEmpty }
        guard !targets.isEmpty else { return [:] }
        let phrases = targets.contains { $0.1.count > 1 }
        var counts: [String: Int] = [:]
        for text in texts where !text.isEmpty {
            let words = normalizedWords(text)
            guard !words.isEmpty else { continue }
            let set = Set(words)
            let joined = phrases ? " " + words.joined(separator: " ") + " " : ""
            for (id, target) in targets {
                let found = target.count == 1 ? set.contains(target[0]) : joined.contains(" " + target.joined(separator: " ") + " ")
                if found { counts[id, default: 0] += 1 }
            }
        }
        return counts
    }

    /// Mots d'un texte en clés : sans casse, accents ni ponctuation.
    static func normalizedWords(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldingLocale)
            .split(whereSeparator: \.isWhitespace)
            .map { String($0.filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
    }

    // MARK: Outils

    private static let foldingLocale = Locale(identifier: "fr_FR")

    /// Clé de comparaison d'un terme : sans casse, accents ni ponctuation.
    public static func key(_ text: String) -> String { CorrectionLearner.key(text) }

    /// Même clé que `key`, sans repli Unicode pour un mot ASCII : appelée pour chaque mot de l'historique.
    static func fastKey(_ word: Substring) -> String {
        if word.allSatisfy(\.isASCII) { return String(word.lowercased().filter { $0.isLetter || $0.isNumber }) }
        return key(String(word))
    }

    private static func ranked(_ counts: [String: Int]) -> [String] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Termes à ne pas proposer : déjà au dictionnaire, refusés, du vocabulaire intégré, ou mot isolé d'une expression
    /// déjà connue (« Code » quand « Claude Code » y est).
    struct Exclusions {
        let dictionary: Set<String>
        let phraseWords: Set<String>
        let refused: Set<String>
        static let vocabulary = Set(TechVocabulary.all.map(DictionaryInsights.key))

        init(dictionary entries: [DictionaryEntry], refused terms: [String]) {
            dictionary = Set(entries.map { DictionaryInsights.key($0.term) })
            phraseWords = Set(entries.filter { $0.term.contains(where: \.isWhitespace) }
                .flatMap { CorrectionLearner.words(in: $0.term) }.map(DictionaryInsights.key))
            refused = Set(terms.map(DictionaryInsights.key))
        }

        func excludes(_ term: String) -> Bool {
            let group = DictionaryInsights.key(term)
            if group.isEmpty || dictionary.contains(group) || refused.contains(group) || Self.vocabulary.contains(group) { return true }
            return !term.contains(where: \.isWhitespace) && phraseWords.contains(group)
        }
    }
}

