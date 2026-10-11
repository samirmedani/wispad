import Foundation

/// Le fichier contredit le flux sur un ou deux mots : on reporte ces mots dans la correction du flux, déjà prête
/// ou presque, au lieu d'en relancer une complète (environ 0,9 s, mesuré du 4 au 11 octobre 2026).
/// Rend nil dès que le report n'est pas sûr ; la correction complète du texte du fichier reste alors la règle.
public enum CorrectionPatch {
    /// Au plus deux endroits, de trois mots au plus de chaque côté : au-delà, le sens a pu changer.
    static let maxBlocks = 2
    static let maxWordsPerSide = 3
    static let maxWords = 400

    struct Word {
        let range: Range<String.Index>
        let key: String
    }

    struct Block {
        /// Mots du flux remplacés, et leurs voisins dans le flux (pour retrouver le bon endroit).
        let stream: Range<Int>
        let file: Range<Int>
    }

    /// Vrai si les deux écoutes ne diffèrent que par un ou deux remplacements courts.
    public static func isCandidate(stream: String, file: String) -> Bool {
        blocks(words(in: stream), words(in: file)) != nil
    }

    /// `corrected` est la correction du flux. `protected` : termes du dictionnaire, jamais remplacés par le fichier.
    public static func apply(corrected: String, stream: String, file: String, protected: [String] = []) -> String? {
        let streamWords = words(in: stream), fileWords = words(in: file)
        guard let blocks = blocks(streamWords, fileWords) else { return nil }
        let protectedKeys = Set(protected.flatMap { words(in: $0).map(\.key) })
        let correctedWords = words(in: corrected)
        var replacements: [(range: Range<String.Index>, text: String)] = []
        for block in blocks {
            let removed = streamWords[block.stream]
            guard !removed.contains(where: { protectedKeys.contains($0.key) }) else { return nil }
            guard let found = uniqueMatch(of: removed.map(\.key), in: correctedWords),
                  hasNeighbor(block: block, at: found, stream: streamWords, corrected: correctedWords) else { return nil }
            let target = correctedWords[found.lowerBound].range.lowerBound..<correctedWords[found.upperBound - 1].range.upperBound
            let source = fileWords[block.file.lowerBound].range.lowerBound..<fileWords[block.file.upperBound - 1].range.upperBound
            let text = matchCase(String(file[source]), like: String(corrected[target]))
            replacements.append((target, text))
        }
        replacements.sort { $0.range.lowerBound > $1.range.lowerBound }
        for index in replacements.indices.dropFirst() where replacements[index].range.upperBound > replacements[index - 1].range.lowerBound {
            return nil
        }
        var result = corrected
        for replacement in replacements { result.replaceSubrange(replacement.range, with: replacement.text) }
        return result
    }

    /// Mots : suites de lettres et de chiffres. La ponctuation, les apostrophes et les tirets les séparent ;
    /// la clé ignore casse et accents, et les hésitations sont écartées.
    static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        func close(_ end: String.Index) {
            guard let begin = start else { return }
            start = nil
            let key = text[begin..<end].lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
            if !TranscriptEquivalence.fillers.contains(key) { result.append(Word(range: begin..<end, key: key)) }
        }
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else {
                close(index)
            }
            index = text.index(after: index)
        }
        close(text.endIndex)
        return result
    }

    /// Écarts entre les deux écoutes, alignées sur leur plus longue sous-suite commune.
    static func blocks(_ stream: [Word], _ file: [Word]) -> [Block]? {
        let a = stream.map(\.key), b = file.map(\.key)
        guard !a.isEmpty, !b.isEmpty, a.count <= maxWords, b.count <= maxWords else { return nil }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var blocks: [Block] = []
        var i = 0, j = 0, gapA = 0, gapB = 0
        func flush() -> Bool {
            defer { gapA = i; gapB = j }
            guard gapA < i || gapB < j else { return true }
            // Un mot ajouté ou retiré sans remplacement ne se place pas sûrement, et un écart de taille (« DDR » contre
            // « DDR4 ce bâtard ») dit un flux tronqué plutôt qu'un mot mal entendu : correction complète.
            guard gapA < i, gapB < j, i - gapA <= maxWordsPerSide, j - gapB <= maxWordsPerSide,
                  abs((i - gapA) - (j - gapB)) <= 1 else { return false }
            blocks.append(Block(stream: gapA..<i, file: gapB..<j))
            return blocks.count <= maxBlocks
        }
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                guard flush() else { return nil }
                i += 1; j += 1
                gapA = i; gapB = j
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        i = a.count; j = b.count
        guard flush(), !blocks.isEmpty else { return nil }
        return blocks
    }

    /// Seule occurrence de ces mots dans la correction ; plusieurs ou aucune : on ne sait pas où reporter.
    static func uniqueMatch(of keys: [String], in words: [Word]) -> Range<Int>? {
        guard !keys.isEmpty, words.count >= keys.count else { return nil }
        var found: Range<Int>?
        for start in 0...(words.count - keys.count) where zip(words[start..<start + keys.count], keys).allSatisfy({ $0.key == $1 }) {
            guard found == nil else { return nil }
            found = start..<start + keys.count
        }
        return found
    }

    /// Le même voisin qu'à l'écoute, juste avant ou juste après : on est bien au même endroit de la phrase.
    static func hasNeighbor(block: Block, at found: Range<Int>, stream: [Word], corrected: [Word]) -> Bool {
        let before = block.stream.lowerBound > 0 ? stream[block.stream.lowerBound - 1].key : nil
        let after = block.stream.upperBound < stream.count ? stream[block.stream.upperBound].key : nil
        if before == nil, after == nil { return true }
        if let before, found.lowerBound > 0, corrected[found.lowerBound - 1].key == before { return true }
        if let after, found.upperBound < corrected.count, corrected[found.upperBound].key == after { return true }
        return false
    }

    /// Majuscule initiale de la correction gardée ; un mot à capitales internes (« GitHub ») reste tel quel.
    static func matchCase(_ replacement: String, like original: String) -> String {
        guard let first = replacement.first, let target = original.first, first.isLetter, target.isLetter else { return replacement }
        let rest = replacement.dropFirst().prefix { $0.isLetter }
        guard rest.allSatisfy({ !$0.isUppercase }) else { return replacement }
        return (target.isUppercase ? first.uppercased() : first.lowercased()) + replacement.dropFirst()
    }
}
