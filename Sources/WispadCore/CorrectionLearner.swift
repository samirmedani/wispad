import Foundation

/// Apprend les mots que l'utilisateur corrige juste après une dictée :
/// « Sidance » remplacé par « Seedance » → « Seedance » rejoint le dictionnaire.
/// Seules les retouches d'un mot mal entendu sont retenues, pas les reformulations.
public enum CorrectionLearner {
    public static let maxTermsPerDictation = 3

    /// Une retouche repérée : ce que Wispad avait écrit, et ce que l'utilisateur a mis à la place.
    public struct Candidate: Equatable, Sendable {
        public var heard: String
        public var corrected: String

        public init(heard: String, corrected: String) {
            self.heard = heard
            self.corrected = corrected
        }
    }

    /// Retouches plausibles d'un mot mal entendu. Elles passent ensuite par `TermJudge`
    /// avant d'entrer au dictionnaire : ce filtre local seul laisse passer des mots sans intérêt.
    /// - Parameters:
    ///   - inserted: texte collé par Wispad.
    ///   - before: valeur du champ juste après le collage.
    ///   - after: valeur du champ une fois l'utilisateur passé à autre chose.
    ///   - known: termes déjà dans le dictionnaire.
    public static func candidates(inserted: String, before: String, after: String, known: [String]) -> [Candidate] {
        guard before != after, let span = insertedSpan(of: inserted, in: before) else { return [] }
        let old = words(in: before)
        let new = words(in: after)
        // Champ long : diff limité à une fenêtre autour de la dictée.
        let small = old.count * new.count <= 250_000
        let oldWindow = small ? 0..<old.count : window(old, around: span, margin: 40)
        let newWindow = small ? 0..<new.count : alignedWindow(new, old: old, oldWindow: oldWindow)
        let knownKeys = Set(known.map(key))
        var learned: [Candidate] = []
        for hunk in replacements(Array(old[oldWindow]), Array(new[newWindow])) {
            let oldRange = (hunk.oldStart + oldWindow.lowerBound)..<(hunk.oldEnd + oldWindow.lowerBound)
            guard oldRange.overlaps(span) else { continue }
            guard let term = candidate(old: hunk.oldWords, new: hunk.newWords) else { continue }
            let termKey = key(term)
            guard !knownKeys.contains(termKey), !learned.contains(where: { key($0.corrected) == termKey }) else { continue }
            learned.append(Candidate(heard: hunk.oldWords.map(strip).joined(separator: " "), corrected: term))
            if learned.count == maxTermsPerDictation { break }
        }
        return learned
    }

    /// Retouche acceptée : 1 à 3 mots remplacés par 1 à 2 mots qui sonnent pareil.
    static func candidate(old: [String], new: [String]) -> String? {
        guard (1...3).contains(old.count), (1...2).contains(new.count) else { return nil }
        let oldText = old.map(strip).joined(separator: " ")
        let newText = new.map(strip).joined(separator: " ")
        guard newText.count >= 3, newText != oldText,
              newText.contains(where: \.isLetter),
              !newText.allSatisfy({ $0.isNumber || $0 == " " }) else { return nil }
        // Changer un chiffre (« DDR3 » → « DDR4 4G », « i7 » → « i9 ») modifie le contenu :
        // ce n'est jamais un mot mal entendu, et l'apprendre fausserait les dictées suivantes.
        guard oldText.filter(\.isNumber) == newText.filter(\.isNumber) else { return nil }
        let oldKey = key(oldText)
        let newKey = key(newText)
        if oldKey == newKey {
            // Seule la casse ou les accents changent : utile pour un nom propre (« openai » → « OpenAI »).
            return hasDistinctiveShape(newText) ? newText : nil
        }
        // Simple accord (« maison » → « maisons ») : une faute de grammaire, pas un mot mal entendu.
        // Une forme distinctive peut être un nom propre mal entendu (« terraforme » → « Terraform »).
        // Elle doit parvenir au juge ; celui-ci écarte les mots courants simplement capitalisés.
        if isInflection(oldKey, newKey), !hasDistinctiveShape(newText) { return nil }
        let similarity = 1 - Double(levenshtein(oldKey, newKey)) / Double(max(oldKey.count, newKey.count))
        guard similarity >= 0.45 else { return nil }
        // Un mot courant en minuscules vaut rarement d'être appris ; un terme marqué, oui.
        guard hasDistinctiveShape(newText) || newKey.count >= 6 else { return nil }
        return newText
    }

    // MARK: - Mots et diff

    struct Hunk: Equatable {
        var oldStart: Int
        var oldEnd: Int
        var oldWords: [String]
        var newWords: [String]
        /// Position de `newWords` dans le nouveau texte.
        var newStart = 0
    }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Blocs « supprimé puis ajouté » d'un diff mot à mot (plus longue sous-suite commune).
    /// `oneSided` garde aussi les mots seulement ajoutés ou seulement retirés.
    static func replacements(_ old: [String], _ new: [String], oneSided: Bool = false) -> [Hunk] {
        let n = old.count, m = new.count
        guard n > 0, m > 0, n * m <= 250_000 else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var current: Hunk?
        func flush() {
            if let hunk = current, oneSided || (!hunk.oldWords.isEmpty && !hunk.newWords.isEmpty) { hunks.append(hunk) }
            current = nil
        }
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                flush()
                i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                if current == nil { current = Hunk(oldStart: i, oldEnd: i, oldWords: [], newWords: [], newStart: j) }
                current?.newWords.append(new[j])
                j += 1
            } else {
                if current == nil { current = Hunk(oldStart: i, oldEnd: i, oldWords: [], newWords: [], newStart: j) }
                current?.oldWords.append(old[i])
                current?.oldEnd = i + 1
                i += 1
            }
        }
        flush()
        return hunks
    }

    /// Mots du champ (après collage) qui viennent de la dictée.
    public static func insertedSpan(of inserted: String, in value: String) -> Range<Int>? {
        let target = words(in: inserted)
        let all = words(in: value)
        guard !target.isEmpty, all.count >= target.count else { return nil }
        let lastStart = all.count - target.count
        for start in stride(from: lastStart, through: 0, by: -1) where Array(all[start..<(start + target.count)]) == target {
            return start..<(start + target.count)
        }
        return nil
    }

    private static func window(_ words: [String], around span: Range<Int>, margin: Int) -> Range<Int> {
        max(0, span.lowerBound - margin)..<min(words.count, span.upperBound + margin)
    }

    /// Même fenêtre dans le nouveau texte, recalée sur le préfixe inchangé.
    private static func alignedWindow(_ new: [String], old: [String], oldWindow: Range<Int>) -> Range<Int> {
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        let start = min(oldWindow.lowerBound, prefix, new.count)
        let growth = new.count - old.count
        let end = min(new.count, max(start, oldWindow.upperBound + max(0, growth) + 10))
        return start..<end
    }

    // MARK: - Ressemblance

    private static func strip(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func hasDistinctiveShape(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard let first = letters.first else { return false }
        let innerCapital = letters.dropFirst().contains(where: \.isUppercase)
        let digit = text.contains(where: \.isNumber)
        return first.isUppercase || innerCapital || digit
    }

    private static func isInflection(_ old: String, _ new: String) -> Bool {
        let (short, long) = old.count <= new.count ? (old, new) : (new, old)
        guard long.hasPrefix(short) else { return false }
        return ["s", "x", "e", "es", "ent", "er", "ez"].contains(String(long.dropFirst(short.count)))
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
