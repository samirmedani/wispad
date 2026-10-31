import Foundation

/// Passage où une seconde écoute du même audio, sur le Mac, a entendu d'autres mots que la transcription.
public struct LocalDivergence: Equatable, Sendable {
    /// Passage de la transcription, avec un mot de contexte de chaque côté.
    public var heard: String
    /// Même passage selon la seconde écoute.
    public var local: String

    public init(heard: String, local: String) {
        self.heard = heard
        self.local = local
    }
}

/// Seconde écoute sur le Mac (moteur de dictée d'Apple) : juste sur les mots courants et les tournures orales,
/// fragile sur les noms, termes techniques et nombres. Mesuré le 31 octobre 2026 sur 100 vraies dictées : elle
/// entend « Si t'es développeur » là où le fournisseur écrit « Faut voter développeur », mais écrit « dick » pour
/// « DeepSeek ». Seuls les passages où elle propose d'autres mots courants vont à la correction ; ceux qui touchent
/// un nom, un terme technique ou un nombre, ou qu'elle écrit avec un mot inconnu de l'orthographe, sont écartés.
public enum LocalHearing {
    /// Au-delà, la seconde écoute a décroché (autre langue, bruit) : rien n'est retenu.
    public static let maximumDivergences = 8

    public static func divergences(
        transcript: String,
        hearing: String,
        knownWord: ((String) -> Bool)?,
        isTerm: ((String) -> Bool)? = nil,
        protectedTerms: [String] = []
    ) -> [LocalDivergence] {
        let heard = tokens(transcript), local = tokens(hearing)
        guard !heard.isEmpty, !local.isEmpty else { return [] }
        let protected = Set(protectedTerms.flatMap { CorrectionLearner.words(in: $0) }.map(CorrectionLearner.key))
        var found: [LocalDivergence] = []
        for hunk in CorrectionLearner.replacements(heard.map(\.key), local.map(\.key))
        where !hunk.oldWords.isEmpty && !hunk.newWords.isEmpty {
            let mine = Array(heard[hunk.oldStart..<hunk.oldEnd])
            let theirs = Array(local[hunk.newStart..<(hunk.newStart + hunk.newWords.count)])
            let keys = (mine + theirs).map(\.key)
            if keys.allSatisfy(lightWords.contains) { continue }
            if keys.contains(where: { key in key.contains(where: \.isNumber) || numberWords.contains(key) }) { continue }
            // Terme anglais en minuscules (« repo », « unlock ») : terme technique, protégé comme un nom.
            if mine.contains(where: { $0.distinctive || protected.contains($0.key) || isTerm?($0.word) == true }) { continue }
            // Même mot à l'accord près (« fonctionnent » / « fonctionne ») : rien d'autre n'a été entendu.
            if mine.map({ stem($0.key) }) == theirs.map({ stem($0.key) }) { continue }
            // Mot inconnu de l'orthographe dans la seconde écoute : seulement si la transcription en a un aussi
            // (« computarius » / « computeruse »), sinon c'est la seconde écoute qui a décroché (« juriqueidique »).
            if let knownWord, theirs.contains(where: { !knownWord($0.word) }), mine.allSatisfy({ knownWord($0.word) }) {
                continue
            }
            found.append(LocalDivergence(heard: excerpt(transcript, heard, hunk.oldStart, hunk.oldEnd),
                                         local: excerpt(hearing, local, hunk.newStart, hunk.newStart + hunk.newWords.count)))
        }
        return found.count > maximumDivergences ? [] : found
    }

    /// Un mot écrit : sa clé de comparaison, le mot seul (pour l'orthographe) et le mot tel qu'écrit dans le texte.
    private struct Token {
        var key: String
        var word: String
        var range: Range<String.Index>
        var distinctive: Bool
    }

    /// Mots du texte, les élisions et traits d'union séparés (« t'es », « là-bas »), hésitations retirées.
    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var opensSentence = true
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            let raw = text[start..<index]
            let letters = raw.filter(\.isLetter)
            // Nom propre, marque ou terme technique : chiffre, capitale intérieure (« xAI », « GitHub ») ou capitale
            // hors début de phrase (« Cursor », « Lulu »). La seconde écoute ne les remplace jamais.
            let distinctive = raw.contains(where: \.isNumber)
                || letters.dropFirst().contains(where: \.isUppercase)
                || (!opensSentence && letters.first?.isUppercase == true)
            for part in raw.split(whereSeparator: { "'’-".contains($0) }) {
                let word = part.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                let key = CorrectionLearner.key(word)
                guard !key.isEmpty, !TranscriptEquivalence.fillers.contains(key) else { continue }
                result.append(Token(key: key, word: word, range: start..<index, distinctive: distinctive))
            }
            if let last = raw.last { opensSentence = ".!?…".contains(last) }
        }
        return result
    }

    /// Le passage avec un mot de contexte de chaque côté, tel qu'écrit.
    private static func excerpt(_ text: String, _ tokens: [Token], _ start: Int, _ end: Int) -> String {
        let first = tokens[max(0, start - 1)].range.lowerBound
        let last = tokens[min(tokens.count - 1, end)].range.upperBound
        return String(text[first..<last])
    }

    private static func stem(_ key: String) -> String {
        guard key.count > 3 else { return key }
        for ending in ["ent", "es", "e", "s", "x"] where key.hasSuffix(ending) { return String(key.dropLast(ending.count)) }
        return key
    }

    private static let lightWords: Set<String> = [
        "le", "la", "les", "l", "un", "une", "des", "du", "de", "d", "au", "aux", "ce", "cet", "cette", "ces",
        "et", "ou", "mais", "que", "qu", "qui", "a", "en", "dans", "sur", "pour", "par", "avec", "je", "j", "tu",
        "t", "il", "elle", "on", "nous", "vous", "ils", "elles", "me", "m", "te", "se", "s", "y", "ca", "c", "est",
        "ne", "n", "pas", "the", "an", "of", "to", "in", "on", "at", "for", "with", "and", "or", "but", "it", "is",
    ]

    /// Nombres en lettres, unités et symboles écrits différemment : la mise en forme les gère, pas l'écoute.
    private static let numberWords: Set<String> = [
        "zero", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix", "onze", "douze", "treize",
        "quatorze", "quinze", "seize", "vingt", "vingts", "trente", "quarante", "cinquante", "soixante", "cent",
        "cents", "mille", "million", "millions", "euro", "euros", "dollar", "dollars", "pourcent", "etc", "cetera",
        "h", "min", "minute", "minutes", "heure", "heures", "one", "two", "three", "four", "five", "ten", "hundred",
        "thousand", "percent",
    ]
}
