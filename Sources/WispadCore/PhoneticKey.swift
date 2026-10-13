import Foundation

/// Prononciation française approchée, pour juger si deux écritures se ressemblent à l'oreille : « j'écris » et
/// « j'ai pris », « mer » et « maire », « sot » et « seau ». Une lettre seule se lit par son nom (« C » comme
/// « c'est ») et un mot épelé (« M-E-L ») comme ses lettres dites (« aime E elle »).
/// Ce n'est pas une transcription phonétique : seulement assez proche pour reconnaître un homophone ou presque.
enum PhoneticKey {
    /// Les deux suites de mots se prononcent pareil, à une différence près pour cinq sons.
    static func soundsAlike(_ written: [String], _ heard: [String]) -> Bool {
        let written = written.filter(isWord), heard = heard.filter(isWord)
        guard !written.isEmpty, !heard.isEmpty else { return false }
        return alike(key(written), key(heard)) || spells(written, heard)
    }

    /// Un seul mot écrit, épelé (« M-E-L ») ou lu lettre à lettre (« mel »), dont les noms de lettres sonnent comme
    /// les mots entendus, parmi lesquels au moins une lettre isolée : « aime E elle », « c'est E S ».
    static func spells(_ written: [String], _ heard: [String]) -> Bool {
        let written = written.filter(isWord), heard = heard.filter(isWord)
        guard written.count == 1, heard.count >= 2, heard.contains(where: { letter($0) != nil }),
              let letters = spelledLetters(written[0]) ?? plainLetters(written[0]) else { return false }
        return alike(letters.map { encode(name($0)) }.joined(), key(heard))
    }

    /// Prononciations mises bout à bout : « j'ai pris » → « jepri ».
    static func key(_ words: [String]) -> String {
        words.map(wordKey).joined()
    }

    /// Au plus une différence pour cinq sons : « jekri » et « jepri », pas « metr » (maître) et « mer ».
    private static func alike(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return CorrectionLearner.levenshtein(a, b) * 5 <= max(a.count, b.count)
    }

    private static func isWord(_ word: String) -> Bool {
        !CorrectionLearner.key(word).isEmpty
    }

    private static func wordKey(_ word: String) -> String {
        if let letters = spelledLetters(word) { return letters.map { encode(name($0)) }.joined() }
        if let single = letter(word) { return encode(name(single)) }
        // Un trait d'union ou un point sépare deux mots dits à la suite (« peut-être ») ; l'apostrophe lie
        // l'élision à son mot (« j'ai »).
        return word.split { !($0.isLetter || $0.isNumber || apostrophes.contains($0)) }.map { encode(String($0)) }.joined()
    }

    // MARK: - Lettres

    /// Lettre seule, lue par son nom ; « y » minuscule reste le pronom.
    private static func letter(_ word: String) -> Character? {
        guard word.count == 1, let character = word.first, character.isASCII, character.isLetter, word != "y" else { return nil }
        return Character(character.lowercased())
    }

    /// Lettres jointes par des tirets : « C-E-S ».
    private static func spelledLetters(_ word: String) -> [Character]? {
        let parts = word.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ $0.count == 1 && $0.allSatisfy { $0.isASCII && $0.isLetter } }) else { return nil }
        return parts.map { Character($0.lowercased()) }
    }

    /// Mot ordinaire lu lettre à lettre (« mel » pour « aime E elle ») : de 2 à 12 lettres sans accent.
    private static func plainLetters(_ word: String) -> [Character]? {
        let letters = Array(CorrectionLearner.key(word))
        guard (2...12).contains(letters.count), letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return letters
    }

    private static func name(_ letter: Character) -> String {
        letterNames[letter] ?? String(letter)
    }

    /// Noms des lettres en français, écrits comme ils se prononcent.
    private static let letterNames: [Character: String] = [
        "a": "a", "b": "bé", "c": "cé", "d": "dé", "e": "eu", "f": "effe", "g": "gé", "h": "ache", "i": "i",
        "j": "ji", "k": "ka", "l": "elle", "m": "emme", "n": "enne", "o": "o", "p": "pé", "q": "ku", "r": "erre",
        "s": "esse", "t": "té", "u": "u", "v": "vé", "w": "doublevé", "x": "ixe", "y": "igrec", "z": "zède",
    ]

    // MARK: - Sons

    private static let apostrophes: Set<Character> = ["'", "’", "‘", "´", "ʼ"]
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "à", "â", "ä", "é", "è", "ê", "ë", "î", "ï", "ô", "ö", "ù", "û", "ü", "œ", "æ"]
    /// Voyelles qui adoucissent c et g : « ce », « gi ».
    private static let front: Set<Character> = ["e", "i", "y", "é", "è", "ê", "ë", "î", "ï"]

    /// Un mot sans tiret. Voyelles proches confondues (é, è, ai → e ; eu → E), nasales notées A (an, en),
    /// O (on), I (in, ain, un) ; ch → S ; lettres muettes de la fin retirées ; lettre doublée lue une fois.
    private static func encode(_ segment: String) -> String {
        let parts = segment.lowercased().split { apostrophes.contains($0) }
        let letters = Array(parts.joined().filter { $0.isLetter || $0.isNumber })
        // « sept » se dit comme « cette » : son p est muet, son t se prononce.
        if letters == ["s", "e", "p", "t"] { return "set" }
        let end = pronouncedEnd(letters, isEst: parts.last == "est")
        /// « mille », « ville », « tranquille » : ici « ill » se dit « il ».
        let plainIll = ["mill", "vill"].contains { letters.starts(with: Array($0)) } || String(letters).contains("tranquill")
        /// Lettre prononcée, avant les finales muettes.
        func at(_ index: Int) -> Character? { index >= 0 && index < end ? letters[index] : nil }
        /// Lettre écrite, même muette : elle décide du son de sa voisine (« place », « aime »).
        func ahead(_ index: Int) -> Character? { index >= 0 && index < letters.count ? letters[index] : nil }
        func isVowel(_ character: Character?) -> Bool { character.map(vowels.contains) ?? false }
        func isFront(_ character: Character?) -> Bool { character.map(front.contains) ?? false }
        /// n ou m qui nasalise la voyelle d'avant : suivi d'une consonne autre que n ou m, ou de rien (« faim »).
        func nasal(_ index: Int) -> Bool {
            guard let character = ahead(index), character == "n" || character == "m" else { return false }
            guard let next = ahead(index + 1) else { return true }
            return !isVowel(next) && next != "n" && next != "m"
        }
        var output: [Character] = []
        func emit(_ sound: String) {
            for character in sound where output.last != character { output.append(character) }
        }
        var index = 0
        while index < end {
            let c = letters[index], c1 = at(index + 1), c2 = at(index + 2)
            let previous: Character? = index > 0 ? letters[index - 1] : nil
            // Voyelles écrites en plusieurs lettres.
            if c == "e", c1 == "a", c2 == "u" { emit("o"); index += 3; continue }
            if c == "a", c1 == "u" { emit("o"); index += 2; continue }
            if c == "o", let next = c1, "uùû".contains(next) { emit("u"); index += 2; continue }
            if c == "o", c1 == "i", c2 == "n", nasal(index + 2) { emit("wI"); index += 3; continue }
            if c == "o", let next = c1, "iîy".contains(next) { emit("wa"); index += 2; continue }
            if c == "a" || c == "e", let next = c1, "iî".contains(next) {
                if c2 == "l" { emit(c == "a" ? "aj" : "ej"); index += at(index + 3) == "l" ? 4 : 3; continue }
                if c2 == "n" || c2 == "m", nasal(index + 2) { emit("I"); index += 3; continue }
                emit("e"); index += 2; continue
            }
            if c == "e" || c == "œ", c1 == "u" { emit("E"); index += 2; continue }
            if c == "œ" { emit("E"); index += 1; continue }
            if c == "i", c1 == "l", c2 == "l" {
                emit(plainIll ? "il" : isVowel(previous) ? "j" : "ij")
                index += 3
                continue
            }
            // Voyelle nasale : an, en, on, in, un (« ien » se dit « in »).
            if "aeoiuy".contains(c), nasal(index + 1) {
                let afterI = previous.map { "iyé".contains($0) } ?? false
                emit(c == "a" || (c == "e" && !afterI) ? "A" : (c == "o" ? "O" : "I"))
                index += 2; continue
            }
            if "aàâä".contains(c) { emit("a"); index += 1; continue }
            if "eéèêëæ".contains(c) { emit("e"); index += 1; continue }
            if "iîïy".contains(c) { emit("i"); index += 1; continue }
            if "oôö".contains(c) { emit("o"); index += 1; continue }
            if "uùûü".contains(c) { emit("y"); index += 1; continue }
            switch c {
            case "c":
                if c1 == "h" { emit("S"); index += 2 }
                else if c1 == "k" { emit("k"); index += 2 }
                else if c1 == "c", isFront(ahead(index + 2)) { emit("ks"); index += 2 }
                else { emit(isFront(ahead(index + 1)) ? "s" : "k"); index += 1 }
            case "ç":
                emit("s"); index += 1
            case "g":
                if c1 == "n" { emit("nj"); index += 2 }
                else if c1 == "u", isFront(ahead(index + 2)) { emit("g"); index += 2 }
                else if c1 == "e", let next = ahead(index + 2), "aouâô".contains(next) { emit("j"); index += 2 }
                else if c1 == "h" { emit("g"); index += 2 }
                else { emit(isFront(ahead(index + 1)) ? "j" : "g"); index += 1 }
            case "h":
                index += 1
            case "p" where c1 == "h":
                emit("f"); index += 2
            case "t" where c1 == "h":
                emit("t"); index += 2
            case "t" where c1 == "i" && c2 == "o" && at(index + 3) == "n" && previous != "s" && previous != "x":
                emit("s"); index += 1
            case "q":
                emit("k"); index += c1 == "u" ? 2 : 1
            case "s":
                if c1 == "c", c2 == "h" { emit("S"); index += 3 }
                else if c1 == "h" { emit("S"); index += 2 }
                else if c1 == "c", isFront(ahead(index + 2)) { emit("s"); index += 2 }
                else if c1 == "s" { emit("s"); index += 2 }
                else { emit(isVowel(previous) && isVowel(ahead(index + 1)) ? "z" : "s"); index += 1 }
            case "x":
                emit("ks"); index += 1
            default:
                emit(String(c)); index += 1
            }
        }
        return String(output)
    }

    /// Fin de la partie prononcée : e muet final, sinon consonne finale muette (s, x, t, d, p, z ; g après n).
    private static func pronouncedEnd(_ letters: [Character], isEst: Bool) -> Int {
        var end = letters.count
        // « est », « c'est » : le « st » ne se dit pas.
        if isEst { return max(0, end - 2) }
        if end >= 4, letters[end - 1] == "s", letters[end - 2] == "e" { return end - 2 }
        if end >= 3, letters[end - 1] == "e" { return end - 1 }
        if end >= 2, "sxtdpz".contains(letters[end - 1]), !(end == 2 && letters[1] == "s") {
            let dropped = letters[end - 1]
            end -= 1
            // « faits », « temps », « pieds »
            if "sx".contains(dropped), end >= 2, "tdp".contains(letters[end - 1]) { end -= 1 }
            // « vingt », « vingts », « doigt », « longs » : g muet devant la finale muette.
            if end >= 3, letters[end - 1] == "g", letters[end - 2] == "n" || dropped == "t" { end -= 1 }
            return end
        }
        if end >= 3, letters[end - 1] == "g", letters[end - 2] == "n" { return end - 1 }
        return end
    }
}
