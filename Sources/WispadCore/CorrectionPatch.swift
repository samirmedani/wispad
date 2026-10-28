import Foundation

/// Le fichier contredit le flux sur un ou deux endroits : on reporte ses mots dans la correction du flux, déjà prête
/// ou presque, au lieu d'en relancer une complète (environ 0,9 s, mesuré du 4 au 11 octobre 2026).
/// Rend nil dès que le report n'est pas sûr ; la correction complète du texte du fichier reste alors la règle : elle
/// reçoit les deux écoutes et choisit, vu la phrase. Le fichier se trompe parfois là où le flux avait juste : le
/// 28 octobre 2026, « un deuxième » est devenu « 1/2 » et « mots », « mope ».
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
    /// `knownWord` : vrai si un mot écrit existe dans la langue de la dictée, le dictionnaire ou le vocabulaire
    /// technique ; sans lui, seuls les chiffres sont vérifiés (voir `doubtful`).
    public static func apply(corrected: String, stream: String, file: String, protected: [String] = [],
                             knownWord: ((String) -> Bool)? = nil) -> String? {
        let streamWords = words(in: stream), fileWords = words(in: file)
        guard let blocks = blocks(streamWords, fileWords) else { return nil }
        let protectedKeys = Set(protected.flatMap { words(in: $0).map(\.key) })
        let correctedWords = words(in: corrected)
        var replacements: [(range: Range<String.Index>, text: String)] = []
        for block in blocks {
            guard !repeatsNeighbor(block, stream: streamWords, file: fileWords) else { return nil }
            guard !doubtful(block, streamWords: streamWords, fileWords: fileWords, stream: stream, file: file,
                            knownWord: knownWord) else { return nil }
            if block.stream.isEmpty {
                // Mot ajouté par le fichier (« je ne sais pas ») : entre les deux mêmes voisins, sans ponctuation à placer.
                guard let gap = insertionGap(at: block.stream.lowerBound, stream: streamWords, corrected: correctedWords, in: corrected),
                      let token = insertedToken(block.file, of: fileWords, in: file) else { return nil }
                replacements.append((gap, " " + token + " "))
                continue
            }
            // Élision coupée par le découpage en mots (« t'as » lu « t » puis « as ») : le report écrivait « t as »
            // (8 dictées en 28 jours). La correction complète l'écrit en entier.
            guard !endsInElision(block.file, of: fileWords, in: file),
                  !endsInElision(block.stream, of: streamWords, in: stream) else { return nil }
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

    /// Écart que la correction doit trancher, sans report : le fichier écrit en chiffres ce que le flux disait en
    /// lettres (« un deuxième » → « 1/2 », alors que la correction du flux écrit déjà les nombres au format choisi),
    /// ou met un mot inconnu à la place de mots connus (« mots » → « mope »). Un mot du fichier connu (« bagnère » →
    /// « bannière ») ou deux mots inconnus (« calotrack » → « calotrax ») se reportent comme avant. Les mots se lisent
    /// entiers, élision comprise (« t'as », « qu'il ») ; une lettre seule ne compte pas.
    static func doubtful(_ block: Block, streamWords: [Word], fileWords: [Word], stream: String, file: String,
                         knownWord: ((String) -> Bool)?) -> Bool {
        let fromFile = tokens(block.file, of: fileWords, in: file)
        guard !fromFile.isEmpty else { return false }
        let fromStream = tokens(block.stream, of: streamWords, in: stream)
        let hasDigit = { (tokens: [String]) in tokens.contains { $0.contains(where: \.isNumber) } }
        if hasDigit(fromFile), !hasDigit(fromStream) { return true }
        guard let knownWord else { return false }
        let written = { (tokens: [String]) in tokens.filter { $0.count >= 2 && !$0.contains(where: \.isNumber) && $0.contains(where: \.isLetter) } }
        let spoken = written(fromStream)
        guard !spoken.isEmpty, spoken.allSatisfy(knownWord) else { return false }
        return written(fromFile).contains { !knownWord($0) }
    }

    /// Petits mots qui changent le sens sans se confondre à l'oreille : pronoms, articles et déterminants.
    static let functionWords: Set<String> = [
        "le", "la", "les", "lui", "leur", "leurs", "un", "une", "des", "du", "il", "elle", "ils", "elles", "on", "ce", "cet",
        "cette", "ces", "son", "sa", "ses", "mon", "ma", "mes", "ton", "ta", "tes", "y", "en", "me", "te", "se", "nous", "vous",
        "he", "she", "it", "they", "him", "her", "them", "his", "its", "their",
    ]

    /// Là où les deux écoutes diffèrent d'un seul petit mot (« envoie-le » dans la Transcription, « envoie-lui » dans
    /// l'autre écoute), le texte garde l'un des deux, jamais un troisième que personne n'a entendu. Le 28 octobre 2026,
    /// la correction a « accordé » le mot de la Transcription avec un nom féminin de la phrase et écrit « envoie-la » ; la consigne,
    /// même explicite, ne l'en empêchait pas. En le changeant, elle l'a écarté : le mot de l'autre écoute prend sa place.
    /// La correction peut aussi fusionner les deux (« envoie-la-lui ») : seul le mot entendu reste. Seulement à un
    /// endroit sûr : mêmes voisins que dans la Transcription, une seule place possible, pas d'élision.
    public static func keepHeardWord(corrected: String, transcript: String, alternative: String) -> String {
        let file = words(in: transcript), stream = words(in: alternative), written = words(in: corrected)
        guard let blocks = blocks(stream, file) else { return corrected }
        var replacements: [(range: Range<String.Index>, text: String)] = []
        for block in blocks where block.stream.count == 1 && block.file.count == 1 {
            let saidLive = stream[block.stream.lowerBound], saidFile = file[block.file.lowerBound]
            guard functionWords.contains(saidLive.key), functionWords.contains(saidFile.key),
                  !endsInElision(block.stream, of: stream, in: alternative),
                  !endsInElision(block.file, of: file, in: transcript) else { continue }
            let before = block.file.lowerBound > 0 ? file[block.file.lowerBound - 1].key : nil
            let after = block.file.upperBound < file.count ? file[block.file.upperBound].key : nil
            // Place des petits mots écrits entre les mêmes voisins : un ou deux mots (« envoie-la-lui » fusionne les deux
            // écoutes en ajoutant « la », que personne n'a dit).
            var regions: [Range<Int>] = []
            for start in written.indices where before.map({ start > 0 && written[start - 1].key == $0 }) ?? (start == 0) {
                for end in (start + 1)...min(start + 2, written.count)
                where after.map({ end < written.count && written[end].key == $0 }) ?? (end == written.count) {
                    regions.append(start..<end)
                }
            }
            guard regions.count == 1, let region = regions.first else { continue }
            let keys = written[region].map(\.key)
            guard keys.allSatisfy(functionWords.contains), keys != [saidLive.key], keys != [saidFile.key],
                  !endsInElision(region, of: written, in: corrected) else { continue }
            let hasLive = keys.contains(saidLive.key), hasFile = keys.contains(saidFile.key)
            guard !(hasLive && hasFile) else { continue }
            // Le mot entendu déjà présent reste seul ; sinon celui de l'autre écoute, que la correction n'a pas écarté.
            let kept = hasFile ? String(transcript[saidFile.range]) : String(alternative[saidLive.range])
            let span = written[region.lowerBound].range.lowerBound..<written[region.upperBound - 1].range.upperBound
            replacements.append((span, matchCase(kept, like: String(corrected[written[region.lowerBound].range]))))
        }
        var result = corrected
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(replacement.range, with: replacement.text)
        }
        return result
    }

    /// Vrai si le dernier mot est suivi d'une apostrophe : le début d'une élision (« t » de « t'as »).
    static func endsInElision(_ range: Range<Int>, of words: [Word], in text: String) -> Bool {
        guard !range.isEmpty else { return false }
        let end = words[range.upperBound - 1].range.upperBound
        return end < text.endIndex && "'’".contains(text[end])
    }

    /// Mots écrits (entre espaces) qui portent ces mots, ponctuation des bords retirée : « qu » se lit « qu'il ».
    static func tokens(_ range: Range<Int>, of words: [Word], in text: String) -> [String] {
        guard !range.isEmpty else { return [] }
        var lower = words[range.lowerBound].range.lowerBound, upper = words[range.upperBound - 1].range.upperBound
        while lower > text.startIndex, !text[text.index(before: lower)].isWhitespace { lower = text.index(before: lower) }
        while upper < text.endIndex, !text[upper].isWhitespace { upper = text.index(after: upper) }
        let edges = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "/"))
        return text[lower..<upper].split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty }
    }

    /// Majuscule initiale de la correction gardée ; un mot à capitales internes (« GitHub ») reste tel quel.
    static func matchCase(_ replacement: String, like original: String) -> String {
        guard let first = replacement.first, let target = original.first, first.isLetter, target.isLetter else { return replacement }
        let rest = replacement.dropFirst().prefix { $0.isLetter }
        guard rest.allSatisfy({ !$0.isUppercase }) else { return replacement }
        return (target.isUppercase ? first.uppercased() : first.lowercased()) + replacement.dropFirst()
    }
}
