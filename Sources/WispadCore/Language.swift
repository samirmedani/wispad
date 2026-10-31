import Foundation

public enum DictationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case french = "fr"
    case english = "en"
    case auto

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .french: return "Français"
        case .english: return "English"
        case .auto: return "Automatique"
        }
    }

    public var xaiCode: String? {
        switch self {
        case .french: return "fr"
        case .english: return "en"
        case .auto: return nil
        }
    }

    /// Langue de dictée d'une nouvelle installation : celle du système, français ou anglais.
    public static func preferred(_ languages: [String] = Locale.preferredLanguages) -> DictationLanguage {
        languages.first?.lowercased().hasPrefix("fr") == true ? .french : .english
    }

    public var openAICodes: [String] {
        switch self {
        case .french: return ["fr"]
        case .english: return ["en"]
        case .auto: return ["fr", "en"]
        }
    }
}

/// Langue d'une transcription, quand la dictée est réglée en automatique : français ou anglais,
/// d'après les mots outils les plus fréquents. Une égalité garde le français (franglais technique).
public enum TranscriptLanguage {
    public static func guess(_ text: String) -> DictationLanguage {
        var french = 0
        var english = 0
        for token in words(text.lowercased()) {
            // Une élision (« j' », « qu' ») a toujours une apostrophe : sans elle, inutile de chercher.
            let elided = token.utf8.contains(UInt8(ascii: "'")) && frenchElisions.contains(where: { token.hasPrefix($0) })
            if frenchWords.contains(token) || elided { french += 1 }
            if englishWords.contains(token) { english += 1 }
        }
        return english > french ? .english : .french
    }

    /// Mots d'un texte en minuscules : lettres et apostrophes, « ’ » écrite « ' ». Un texte latin (chaque caractère
    /// d'un seul scalaire) se découpe scalaire par scalaire, plus vite, avec le même résultat.
    static func words(_ lower: String) -> [String] {
        guard lower.unicodeScalars.allSatisfy(\.formsCharacterAlone) else {
            return lower.split { !($0.isLetter || $0 == "'" || $0 == "’") }.map { word in
                word.contains("’") ? word.replacingOccurrences(of: "’", with: "'") : String(word)
            }
        }
        let scalars = lower.unicodeScalars
        var result: [String] = []
        func append(_ range: Range<String.UnicodeScalarView.Index>) {
            let word = scalars[range]
            result.append(word.contains("\u{2019}") ? String(String.UnicodeScalarView(word.map { $0 == "\u{2019}" ? "'" : $0 }))
                                                    : String(word))
        }
        var start: String.UnicodeScalarView.Index?
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let inWord = switch scalar.value {
            case 0x61...0x7A, 0x41...0x5A, 0x27, 0x2019: true
            case 0..<0x80: false
            default: scalar.properties.isAlphabetic
            }
            if inWord {
                if start == nil { start = index }
            } else if let begin = start {
                append(begin..<index)
                start = nil
            }
            index = scalars.index(after: index)
        }
        if let begin = start { append(begin..<scalars.endIndex) }
        return result
    }

    private static let frenchWords: Set<String> = [
        "le", "la", "les", "des", "du", "une", "est", "et", "je", "tu", "il", "elle", "nous", "vous", "ils",
        "elles", "que", "qui", "pas", "pour", "dans", "sur", "avec", "mais", "ce", "cette", "mon", "ton",
        "son", "ça", "oui", "non", "très", "plus", "aussi", "comme", "faut", "fait", "va", "suis", "sont",
        "ai", "avons", "être", "avoir", "alors", "donc", "parce", "quoi", "où", "leur", "chez", "sans",
    ]
    private static let frenchElisions = ["j'", "c'", "l'", "d'", "qu'", "n'", "s'", "m'", "t'"]
    private static let englishWords: Set<String> = [
        "the", "and", "is", "are", "to", "of", "that", "it", "for", "you", "with", "this", "i", "we",
        "they", "be", "was", "were", "have", "has", "not", "but", "or", "my", "your", "what", "can",
        "will", "just", "so", "do", "don't", "it's", "i'm", "there", "their", "would", "should", "about",
        "from", "at", "he", "she", "if", "because", "where", "which", "our", "been", "into",
    ]
}
