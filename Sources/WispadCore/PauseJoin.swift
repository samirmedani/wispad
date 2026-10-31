import Foundation

/// Jonction de deux segments finaux du flux xAI. Le serveur ponctue chaque segment comme une phrase entière : une pause
/// au milieu d'une phrase y laisse un point et une majuscule (« Il faudrait un dossier. Ou quand une facture arrive. »).
/// Mesuré sur des dictées réelles en octobre 2026 : à ces jonctions, la transcription de l'enregistrement complet
/// continue la phrase environ sept fois sur dix, le plus souvent par une virgule, et la durée de la pause ne distingue
/// pas les deux cas. Le point d'une jonction devient donc une virgule et le mot suivant reprend sa minuscule s'il est
/// courant ; la correction ponctue ensuite selon le sens. Restent tels quels : « ? », « ! », « … », une abréviation
/// (« etc. »), une initiale, un nom propre, un sigle et les points à l'intérieur d'un segment.
enum PauseJoin {
    /// `joins` : positions (UTF-16) des espaces posées entre deux segments.
    static func soften(_ text: String, joins: [Int]) -> String {
        guard !joins.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for join in Set(joins).sorted(by: >) {
            soften(result, spaceAt: join)
        }
        return result as String
    }

    private static func soften(_ text: NSMutableString, spaceAt join: Int) {
        guard join > 0, join + 1 < text.length, text.character(at: join) == 0x20 else { return }
        let previous = text.character(at: join - 1)
        if previous == 0x2E {
            guard !closesAbbreviation(text.substring(to: join)) else { return }
            text.replaceCharacters(in: NSRange(location: join - 1, length: 1), with: ",")
        } else if !(Unicode.Scalar(previous).map { CharacterSet.alphanumerics.contains($0) } ?? false) {
            // « ? », « ! », « … », guillemet, parenthèse, virgule… : la jonction garde sa ponctuation.
            return
        }
        lowercaseCommonWord(text, at: join + 1)
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

    private static func lowercaseCommonWord(_ text: NSMutableString, at start: Int) {
        let rest = text.substring(from: start)
        let word = String(rest.prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
        guard let first = word.first, first.isUppercase else { return }
        let letters = word.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return }
        let key = word.lowercased().replacingOccurrences(of: "’", with: "'")
        let elided = key.firstIndex(of: "'").map { String(key[...$0]) }
        guard commonWords.contains(key) || elided.map({ commonWords.contains($0) }) == true else { return }
        text.replaceCharacters(in: NSRange(location: start, length: String(first).utf16.count), with: String(first).lowercased())
    }

    private static let abbreviations: Set<String> = [
        "etc", "cf", "env", "mme", "mlle", "dr", "pr", "mr", "mrs", "ms", "st", "vs", "approx", "jr", "sr", "inc", "ltd"
    ]

    /// Mots outils et mots courants qui ouvrent souvent la suite d'une phrase, en français et en anglais. Un mot absent
    /// garde sa majuscule : nom propre, marque, début probable d'une vraie phrase.
    private static let commonWords: Set<String> = Set("""
        et ou où mais donc or ni car parce puisque que qui quoi quand lorsque si comme alors puis ensuite après avant \
        pendant depuis pour sans avec sur sous dans en au aux à de du des le la les un une ce cet cette ces ça cela ceci \
        je tu il elle on nous vous ils elles me te se y lui leur leurs mon ma mes ton ta tes son sa ses notre nos votre \
        vos ne pas plus moins très trop même aussi encore déjà juste enfin bref genre voilà voici bah ben euh hein \
        ouais oui non tout tous toute toutes rien quelque quelques chaque ici là maintenant comment pourquoi combien \
        est-ce faut vu sinon surtout parfois souvent toujours jamais peut-être style limite franchement vraiment bien \
        mal beaucoup peu entre vers chez contre par selon malgré voire cependant pourtant également ainsi notamment \
        tant tellement quel quelle quels quelles lequel laquelle dont chacun personne certains plusieurs autre autres \
        soit celui celle ceux celles ah oh eh bon allez attends écoute regarde tiens dis aujourd'hui \
        c' d' j' l' m' n' s' t' qu' jusqu' lorsqu' puisqu' quoiqu' \
        and or but so because that which who whom whose what when where why how if then than the a an you he she it \
        we they me him her us them my your his its our their this these those there here to of in on at for with from \
        by about as into like just also even still maybe well yeah yes no not now too very really all some any each \
        every both either neither after before while until since though although unless whether
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}
