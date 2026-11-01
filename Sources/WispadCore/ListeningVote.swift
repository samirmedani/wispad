import Foundation

/// Vote des trois écoutes d'une même dictée. Quand le fichier xAI diffère du flux en direct sur un passage court, et
/// que la seconde écoute du Mac (moteur d'Apple) a entendu ce passage comme le flux, deux écoutes indépendantes
/// s'accordent contre une : le passage du flux remplace celui du fichier, avant la correction. Exemple inventé :
/// « des vices dans la boîte » (fichier) contre « des vis dans la boîte » (flux et Apple) donne « des vis ». Mesuré
/// sur 45 vraies dictées d'octobre 2026 où fichier et flux divergeaient, réécoutées aussi par Whisper : 3 passages
/// tranchés, tous confirmés par Whisper, aucun à tort. Jamais pour un nom, une marque, un terme du dictionnaire ou du
/// vocabulaire technique, un terme anglais (« leak »), un nombre, une élision (« t'as » / « tu as ») ni un mot outil
/// seul : la seconde écoute y est peu fiable, ou l'écart n'est qu'une écriture. Un terme anglais du fichier surtout :
/// le flux et la seconde écoute, tous deux portés vers le français, peuvent l'entendre ensemble comme un mot français
/// (exemple inventé : « le script leak des données » entendu « ligue » par les deux), et deux écoutes contre une
/// remplaceraient alors le mot juste. Seuls les remplacements comptent : un mot ajouté ou retiré par une écoute reste.
public enum ListeningVote {
    public struct Resolution: Equatable, Sendable {
        /// Le texte du fichier, avec les passages départagés écrits comme le flux.
        public var text: String
        /// Passages remplacés.
        public var replacements: Int

        public init(text: String, replacements: Int) {
            self.text = text
            self.replacements = replacements
        }
    }

    /// Passages courts seulement : au-delà, le désaccord n'est plus un mot mal entendu.
    static let maxWordsPerSide = 3
    static let maxWords = 400

    /// `protected` : termes du dictionnaire et du vocabulaire technique, jamais remplacés. `isTerm` : terme anglais
    /// d'une dictée française (orthographe de macOS, comme pour la seconde écoute), jamais remplacé ; nil sans
    /// orthographe ou pour une dictée en anglais.
    public static func resolve(file: String, stream: String, local: String?, protected: [String],
                               isTerm: ((String) -> Bool)? = nil) -> Resolution {
        let unchanged = Resolution(text: file, replacements: 0)
        guard let local else { return unchanged }
        let fileWords = CorrectionPatch.words(in: file), streamWords = CorrectionPatch.words(in: stream)
        let localWords = CorrectionPatch.words(in: local)
        guard !fileWords.isEmpty, !streamWords.isEmpty, !localWords.isEmpty,
              max(fileWords.count, streamWords.count, localWords.count) <= maxWords else { return unchanged }
        let fileKeys = fileWords.map(\.key), streamKeys = streamWords.map(\.key), localKeys = localWords.map(\.key)
        let protectedKeys = Set(protected.flatMap { CorrectionPatch.words(in: $0).map(\.key) })
        let toLocal = matchedPositions(fileKeys, localKeys)
        var replacements: [(range: Range<String.Index>, text: String)] = []
        for hunk in CorrectionLearner.replacements(fileKeys, streamKeys) {
            let fileSpan = hunk.oldStart..<hunk.oldEnd
            let streamSpan = hunk.newStart..<(hunk.newStart + hunk.newWords.count)
            guard fileSpan.count <= maxWordsPerSide, streamSpan.count <= maxWordsPerSide else { continue }
            let keys = hunk.oldWords + hunk.newWords
            if keys.allSatisfy(LocalHearing.lightWords.contains) { continue }
            if keys.contains(where: { key in key.contains(where: \.isNumber) || LocalHearing.numberWords.contains(key) }) { continue }
            if hunk.oldWords.contains(where: protectedKeys.contains) { continue }
            if fileSpan.contains(where: { distinctive(fileWords[$0], in: file) }) { continue }
            if let isTerm, fileSpan.contains(where: { isTerm(String(file[fileWords[$0].range])) }) { continue }
            if touchesElision(fileSpan, of: fileWords, in: file) || touchesElision(streamSpan, of: streamWords, in: stream) {
                continue
            }
            guard let localSpan = span(fileSpan, in: toLocal, fileCount: fileKeys.count, localCount: localKeys.count),
                  Array(localKeys[localSpan]) == hunk.newWords else { continue }
            let target = fileWords[fileSpan.lowerBound].range.lowerBound..<fileWords[fileSpan.upperBound - 1].range.upperBound
            let source = streamWords[streamSpan.lowerBound].range.lowerBound..<streamWords[streamSpan.upperBound - 1].range.upperBound
            replacements.append((target, CorrectionPatch.matchCase(String(stream[source]), like: String(file[target]))))
        }
        guard !replacements.isEmpty else { return unchanged }
        var text = file
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            text.replaceSubrange(replacement.range, with: replacement.text)
        }
        return Resolution(text: text, replacements: replacements.count)
    }

    /// Positions communes de la plus longue sous-suite commune : mot du fichier → mot de la seconde écoute.
    static func matchedPositions(_ old: [String], _ new: [String]) -> [Int: Int] {
        let n = old.count, m = new.count
        guard n > 0, m > 0 else { return [:] }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Int: Int] = [:]
        var i = 0, j = 0
        while i < n, j < m {
            if old[i] == new[j] {
                result[i] = j
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    /// Le même passage dans la seconde écoute, entre les deux voisins qu'elle partage avec le fichier.
    private static func span(_ fileSpan: Range<Int>, in toLocal: [Int: Int], fileCount: Int, localCount: Int) -> Range<Int>? {
        let start: Int
        if fileSpan.lowerBound == 0 {
            start = 0
        } else {
            guard let left = toLocal[fileSpan.lowerBound - 1] else { return nil }
            start = left + 1
        }
        let end: Int
        if fileSpan.upperBound == fileCount {
            end = localCount
        } else {
            guard let right = toLocal[fileSpan.upperBound] else { return nil }
            end = right
        }
        guard start < end, end - start <= maxWordsPerSide else { return nil }
        return start..<end
    }

    /// Nom propre, marque ou sigle : capitale hors début de phrase, capitale intérieure (« GitHub ») ou chiffre.
    private static func distinctive(_ word: CorrectionPatch.Word, in text: String) -> Bool {
        let surface = text[word.range]
        let letters = surface.filter(\.isLetter)
        if surface.contains(where: \.isNumber) || letters.dropFirst().contains(where: \.isUppercase) { return true }
        guard letters.first?.isUppercase == true else { return false }
        var index = word.range.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if character.isWhitespace || "«\"“(".contains(character) { continue }
            return !".!?…".contains(character) && !character.isNewline
        }
        return false
    }

    /// Mot coupé par une apostrophe ou un trait d'union (« t'as », « peut-être ») : l'écart n'est qu'une écriture.
    private static func touchesElision(_ span: Range<Int>, of words: [CorrectionPatch.Word], in text: String) -> Bool {
        let joiners: Set<Character> = ["'", "’", "-"]
        for index in span {
            let range = words[index].range
            if range.upperBound < text.endIndex, joiners.contains(text[range.upperBound]) { return true }
            if range.lowerBound > text.startIndex, joiners.contains(text[text.index(before: range.lowerBound)]) { return true }
        }
        return false
    }
}
