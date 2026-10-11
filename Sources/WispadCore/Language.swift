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
        let words = text.lowercased().split { !($0.isLetter || $0 == "'" || $0 == "’") }
        for word in words {
            let token = word.replacingOccurrences(of: "’", with: "'")
            if frenchWords.contains(token) || frenchElisions.contains(where: { token.hasPrefix($0) }) { french += 1 }
            if englishWords.contains(token) { english += 1 }
        }
        return english > french ? .english : .french
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
