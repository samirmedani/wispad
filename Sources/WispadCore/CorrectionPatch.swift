import Foundation

/// Le fichier contredit le flux sur un ou deux endroits : on reporte ses mots dans la correction du flux, déjà prête
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

    /// Un endroit où les deux écoutes diffèrent. Côté flux vide : mot ajouté par le fichier ; côté fichier vide : mot
    /// retiré. Ces deux-là sont toujours entre deux mots communs.
    struct Block {
        let stream: Range<Int>
        let file: Range<Int>
    }

    /// Vrai si les deux écoutes ne diffèrent qu'en un ou deux endroits courts.
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
            guard !repeatsNeighbor(block, stream: streamWords, file: fileWords) else { return nil }
            if block.stream.isEmpty {
                // Mot ajouté par le fichier (« je ne sais pas ») : entre les deux mêmes voisins, sans ponctuation à placer.
                guard let gap = insertionGap(at: block.stream.lowerBound, stream: streamWords, corrected: correctedWords, in: corrected),
                      let token = insertedToken(block.file, of: fileWords, in: file) else { return nil }
                replacements.append((gap, " " + token + " "))
                continue
            }
            guard !streamWords[block.stream].contains(where: { protectedKeys.contains($0.key) }),
                  let found = locate(block, stream: streamWords, corrected: correctedWords) else { return nil }
            let target = correctedWords[found.lowerBound].range.lowerBound..<correctedWords[found.upperBound - 1].range.upperBound
            if block.file.isEmpty {
                // Mot retiré par le fichier : il part avec l'espace qui le suit.
                guard let removal = removal(of: target, in: corrected) else { return nil }
                replacements.append((removal, ""))
                continue
            }
            let source = fileWords[block.file.lowerBound].range.lowerBound..<fileWords[block.file.upperBound - 1].range.upperBound
            replacements.append((target, matchCase(String(file[source]), like: String(corrected[target]))))
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
            let removed = i - gapA, added = j - gapB
            guard removed <= maxWordsPerSide, added <= maxWordsPerSide else { return false }
            if removed == 0 || added == 0 {
                // Mot ajouté ou retiré : seulement entre deux mots communs. Au bord, c'est un flux tronqué (« DDR »
                // contre « DDR4 ce bâtard ») ou une fin entendue d'un seul côté : correction complète.
                guard gapA > 0, gapB > 0, i < a.count, j < b.count else { return false }
            } else {
                // Un écart de taille dit un flux tronqué plutôt qu'un mot mal entendu.
                guard abs(removed - added) <= 1 else { return false }
            }
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

    /// Endroit des mots du flux dans la correction : l'occurrence qui garde un voisin de l'écoute, juste avant ou
    /// juste après ; s'il y en a plusieurs, la seule qui garde les deux. Un mot retiré exige ses deux voisins : si la
    /// correction a enlevé une répétition, le mot qui reste n'est plus à la place d'origine.
    static func locate(_ block: Block, stream: [Word], corrected: [Word]) -> Range<Int>? {
        let keys = stream[block.stream].map(\.key)
        guard !keys.isEmpty, corrected.count >= keys.count else { return nil }
        let before = block.stream.lowerBound > 0 ? stream[block.stream.lowerBound - 1].key : nil
        let after = block.stream.upperBound < stream.count ? stream[block.stream.upperBound].key : nil
        var occurrences: [(range: Range<Int>, neighbors: Int)] = []
        for start in 0...(corrected.count - keys.count)
        where zip(corrected[start..<start + keys.count], keys).allSatisfy({ $0.key == $1 }) {
            let end = start + keys.count
            var neighbors = 0
            if let before, start > 0, corrected[start - 1].key == before { neighbors += 1 }
            if let after, end < corrected.count, corrected[end].key == after { neighbors += 1 }
            occurrences.append((start..<end, neighbors))
        }
        // Écoutes sans aucun mot commun : une seule occurrence, sans voisin à comparer.
        if before == nil, after == nil { return occurrences.count == 1 ? occurrences[0].range : nil }
        let placed = occurrences.filter { $0.neighbors >= (block.file.isEmpty ? 2 : 1) }
        if placed.count == 1 { return placed[0].range }
        let both = placed.filter { $0.neighbors == 2 }
        return both.count == 1 ? both[0].range : nil
    }

    /// Place d'un mot ajouté dans la correction : la seule paire des deux mêmes voisins côte à côte, séparés par des
    /// espaces seulement. Une virgule ou un point entre eux : on ne saurait pas de quel côté mettre le mot.
    static func insertionGap(at index: Int, stream: [Word], corrected: [Word], in text: String) -> Range<String.Index>? {
        guard index > 0, index < stream.count, corrected.count >= 2 else { return nil }
        let before = stream[index - 1].key, after = stream[index].key
        var gap: Range<String.Index>?
        for k in 0..<(corrected.count - 1) where corrected[k].key == before && corrected[k + 1].key == after {
            guard gap == nil else { return nil }
            gap = corrected[k].range.upperBound..<corrected[k + 1].range.lowerBound
        }
        guard let gap, !gap.isEmpty, text[gap].allSatisfy({ $0 == " " }) else { return nil }
        return gap
    }

    /// Mot ajouté, tel que le fichier l'écrit : un seul mot écrit (« ne », « peut-être »), entouré d'espaces et sans
    /// ponctuation. Une élision collée au mot suivant (« l'a ») ne se place pas sûrement. Sa majuscule de début de
    /// phrase dans le fichier tombe : il arrive en milieu de phrase.
    static func insertedToken(_ range: Range<Int>, of words: [Word], in file: String) -> String? {
        let span = words[range.lowerBound].range.lowerBound..<words[range.upperBound - 1].range.upperBound
        guard span.lowerBound > file.startIndex, span.upperBound < file.endIndex,
              file[file.index(before: span.lowerBound)].isWhitespace, file[span.upperBound].isWhitespace else { return nil }
        let token = file[span]
        guard token.allSatisfy({ $0.isLetter || $0.isNumber || "'’-‐".contains($0) }), let first = token.first else { return nil }
        let previous = file[..<span.lowerBound].last { !$0.isWhitespace }
        let sentenceStart = previous.map { ".!?…".contains($0) } ?? true
        guard sentenceStart, first.isUppercase, token != "I",
              !token.dropFirst().prefix(while: \.isLetter).contains(where: \.isUppercase) else { return String(token) }
        return first.lowercased() + token.dropFirst()
    }

    /// Mot retiré : un seul mot écrit entre deux mots, séparés par de simples espaces ; il part avec l'espace qui le
    /// suit. Contre une virgule ou un point, la ponctuation resterait orpheline.
    static func removal(of target: Range<String.Index>, in text: String) -> Range<String.Index>? {
        guard target.lowerBound > text.startIndex, target.upperBound < text.endIndex,
              !text[target].contains(where: \.isWhitespace) else { return nil }
        let space = text.index(before: target.lowerBound)
        let next = text.index(after: target.upperBound)
        guard text[space] == " ", text[target.upperBound] == " ", space > text.startIndex, next < text.endIndex else { return nil }
        let left = text[text.index(before: space)], right = text[next]
        guard left.isLetter || left.isNumber, right.isLetter || right.isNumber else { return nil }
        return target.lowerBound..<next
    }

    /// Mot ajouté ou retiré qui répète son voisin (« le le », « par exemple par exemple ») : la correction enlève les
    /// répétitions ; le report ne doit ni en remettre une, ni retirer le mot qui reste.
    static func repeatsNeighbor(_ block: Block, stream: [Word], file: [Word]) -> Bool {
        let side: Range<Int>, words: [Word]
        if block.stream.isEmpty {
            side = block.file
            words = file
        } else if block.file.isEmpty {
            side = block.stream
            words = stream
        } else {
            return false
        }
        let keys = words[side].map(\.key), count = keys.count
        let before = side.lowerBound >= count ? words[(side.lowerBound - count)..<side.lowerBound].map(\.key) : nil
        let after = side.upperBound + count <= words.count ? words[side.upperBound..<(side.upperBound + count)].map(\.key) : nil
        return before == keys || after == keys
    }

    /// Majuscule initiale de la correction gardée ; un mot à capitales internes (« GitHub ») reste tel quel.
    static func matchCase(_ replacement: String, like original: String) -> String {
        guard let first = replacement.first, let target = original.first, first.isLetter, target.isLetter else { return replacement }
        let rest = replacement.dropFirst().prefix { $0.isLetter }
        guard rest.allSatisfy({ !$0.isUppercase }) else { return replacement }
        return (target.isUppercase ? first.uppercased() : first.lowercased()) + replacement.dropFirst()
    }
}
