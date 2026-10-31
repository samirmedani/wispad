import Foundation

/// Jonction de deux segments finaux du flux xAI. Le serveur ponctue chaque segment comme une phrase entière : une pause
/// au milieu d'une phrase y laisse un point et une majuscule devant un petit morceau qui ne tient pas seul
/// (« Je cherche un dossier. Ou pas. », « Regarde le fichier. Sans le modifier. »).
///
/// Seul ce cas est recollé : le segment suivant compte au plus `fragmentWords` mots et commence par un mot de liaison
/// (« ou », « et », « sans », « pour », « que »…). Le point devient une virgule et le mot reprend sa minuscule ; la
/// correction ponctue ensuite selon le sens. Une jonction entre deux propositions plus longues garde son point : sur
/// des dictées réelles (octobre 2026), les changer toutes en virgules donnait autant de phrases collées par des
/// virgules que de morceaux évités, et la correction ponctue déjà ces jonctions-là selon le sens. Restent aussi tels
/// quels : « ? », « ! », « … », une abréviation (« etc. »), une initiale, les points à l'intérieur d'un segment, une
/// question qui commence par « que », « qui », « quand » ou « où ».
enum PauseJoin {
    static let fragmentWords = 5

    /// `joins` : positions (UTF-16) des espaces posées entre deux segments ; chaque segment va jusqu'à la jonction
    /// suivante ou jusqu'à la fin du texte.
    static func soften(_ text: String, joins: [Int]) -> String {
        guard !joins.isEmpty else { return text }
        let result = NSMutableString(string: text)
        let ordered = Set(joins).sorted()
        for index in ordered.indices.reversed() {
            let end = index + 1 < ordered.count ? ordered[index + 1] : result.length
            soften(result, spaceAt: ordered[index], segmentEnd: end)
        }
        return result as String
    }

    private static func soften(_ text: NSMutableString, spaceAt join: Int, segmentEnd: Int) {
        guard join > 0, join + 1 < segmentEnd, segmentEnd <= text.length, text.character(at: join) == 0x20 else { return }
        let next = text.substring(with: NSRange(location: join + 1, length: segmentEnd - join - 1))
        guard isContinuationFragment(next) else { return }
        let previous = text.character(at: join - 1)
        if previous == 0x2E {
            guard !closesAbbreviation(text.substring(to: join)) else { return }
            text.replaceCharacters(in: NSRange(location: join - 1, length: 1), with: ",")
        } else if !(Unicode.Scalar(previous).map { CharacterSet.alphanumerics.contains($0) } ?? false) {
            // « ? », « ! », « … », guillemet, parenthèse, virgule… : la jonction garde sa ponctuation.
            return
        }
        let first = (next as NSString).substring(to: (next as NSString).rangeOfComposedCharacterSequence(at: 0).length)
        text.replaceCharacters(in: NSRange(location: join + 1, length: first.utf16.count), with: first.lowercased())
    }

    /// Petit morceau qui continue la phrase précédente : quelques mots, ouverts par un mot de liaison.
    static func isContinuationFragment(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard (1...fragmentWords).contains(words.count), let firstWord = words.first else { return false }
        let word = String(firstWord.prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
        guard let initial = word.first, initial.isLetter else { return false }
        let letters = word.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return false }
        let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
        let elided = key.firstIndex(of: "'").map { String(key[...$0]) }
        let opener = continuationWords.contains(key) ? key : elided.flatMap { continuationWords.contains($0) ? $0 : nil }
        guard let opener else { return false }
        // « Que faire ? », « Qu'est-ce que… », « Quand est-ce… », « Où ça ? » : une vraie question.
        if interrogativeOpeners.contains(opener), trimmed.hasSuffix("?") || key.hasPrefix("qu'est") { return false }
        return true
    }

    /// Le point final appartient à une abréviation, une initiale ou des points de suspension.
    private static func closesAbbreviation(_ before: String) -> Bool {
        if before.hasSuffix("..") { return true }
        let body = before.dropLast()
        let token = String(body.reversed().prefix { !$0.isWhitespace }.reversed())
            .drop { !$0.isLetter && !$0.isNumber }
        if token.isEmpty || token.contains(".") { return true }
        if token.count == 1, token.first?.isUppercase == true { return true }
        return abbreviations.contains(token.lowercased())
    }

    private static let abbreviations: Set<String> = [
        "etc", "cf", "env", "mme", "mlle", "dr", "pr", "mr", "mrs", "ms", "st", "vs", "approx", "jr", "sr", "inc", "ltd"
    ]

    private static let interrogativeOpeners: Set<String> = ["que", "qu'", "qui", "quand", "où", "where", "when", "who"]

    /// Mots de liaison qui ouvrent la suite d'une phrase : conjonctions, relatifs, prépositions, en français et en
    /// anglais. Un pronom sujet, un verbe ou un nom ne s'y trouvent pas : ils ouvrent plus souvent une vraie phrase.
    private static let continuationWords: Set<String> = Set("""
        et ou où mais donc car ni sans pour avec comme que qu' qui quand lorsque lorsqu' dont parce puisque puisqu' \
        sauf selon de d' du des à au aux en dans sur sous par chez vers entre contre malgré voire jusqu' jusque si \
        même plutôt sinon surtout notamment depuis pendant tandis \
        and or but nor because which who whom whose where when if than with without for of to in on at from by about \
        unless until while whereas
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}
