import Foundation

/// Reconnaît le fournisseur d'une clé API à sa forme, sans aucun appel réseau, et la masque pour l'affichage.
/// La vérification chez le fournisseur reste la seule preuve : une clé n'est jamais envoyée à un autre pour essayer.
public enum APIKeyFormat {
    public enum Guess: Equatable, Sendable {
        /// Fournisseur sûr : le compte de la clé dans l'app.
        case account(String)
        /// Clé xAI (« xai-… ») : clé d'API ou clé de gestion, que la vérification chez xAI départage.
        case xai
        /// Clé d'un service que Wispad n'utilise pas (son nom).
        case unsupported(String)
        /// Forme sans signe distinctif (TypeSafe) : le fournisseur se choisit à la main.
        case unknown
    }

    /// Collée avec « Bearer », des guillemets ou des espaces autour : la clé seule.
    public static func normalize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotes: Set<Character> = ["\"", "'", "`", "“", "”", "‘", "’", "«", "»"]
        while let first = key.first, quotes.contains(first) { key.removeFirst() }
        while let last = key.last, quotes.contains(last) { key.removeLast() }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// xAI : « xai- ». DeepSeek : « sk- » suivi de 32 caractères hexadécimaux. OpenAI : toute autre clé « sk- »
    /// (« sk-proj- », « sk-svcacct- », anciennes clés). Quelques services courants non pris en charge sont nommés.
    public static func guess(_ raw: String) -> Guess {
        let key = normalize(raw)
        guard key.count >= 16, !key.contains(where: \.isWhitespace) else { return .unknown }
        if key.lowercased().hasPrefix("xai-") { return .xai }
        if let service = unsupported.first(where: { key.hasPrefix($0.prefix) })?.service { return .unsupported(service) }
        guard key.hasPrefix("sk-") else { return .unknown }
        let body = key.dropFirst(3)
        if body.count == 32, body.allSatisfy(\.isHexDigit) { return .account(CleanupModel.deepSeekAccount) }
        return .account(ProviderID.openAI.rawValue)
    }

    static let unsupported: [(prefix: String, service: String)] = [
        ("sk-ant-", "Anthropic"), ("sk-or-", "OpenRouter"), ("gsk_", "Groq"), ("AIza", "Google"), ("hf_", "Hugging Face"),
    ]

    /// « xai-••••3f9a » : le début connu, qui n'a rien de secret, et les quatre derniers caractères. Une clé très
    /// courte ne montre rien.
    public static func masked(_ raw: String) -> String {
        let key = normalize(raw)
        guard key.count >= 12 else { return "••••" }
        let prefix = visiblePrefixes.first { key.hasPrefix($0) } ?? ""
        return prefix + "••••" + key.suffix(4)
    }

    static let visiblePrefixes = ["sk-proj-", "sk-svcacct-", "sk-admin-", "xai-", "sk-"]
}
