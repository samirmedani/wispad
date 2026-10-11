import Foundation

/// Mini-requêtes envoyées en arrière-plan aux services en panne, pour savoir quand ils répondent de nouveau
/// sans faire attendre une vraie dictée.
public enum HealthProbe {
    /// DeepSeek : une complétion d'un seul jeton. nil si annulée avant l'envoi.
    public static func deepSeek(key: String) async -> UsageEvent? {
        await deepSeek(key: key, transport: TextCleaner.httpTransport)
    }

    static func deepSeek(key: String, transport: @escaping TextCleaner.HTTPTransport) async -> UsageEvent? {
        let route = TextCleaner.Route(
            api: .deepSeekCleanup, model: CleanupModel.deepSeek,
            url: URL(string: "https://api.deepseek.com/chat/completions")!, key: key, provider: "DeepSeek", isFallback: false
        )
        let requests = TextCleaner.RequestLog()
        _ = try? await TextCleaner.withTimeout(seconds: 5) {
            // Un jeton suffit à vérifier que le service répond : sa troncature volontaire n'est pas une panne.
            try await TextCleaner.send(system: "Réponds OK.", user: "OK", route: route, maxTokens: 1, includeReasoning: false, allowTruncated: true,
                                       transport: transport, requests: requests)
        }
        return requests.events.first
    }

    /// Fournisseur vocal : liste des modèles (gratuite). true si le service répond avec la clé.
    public static func voice(_ provider: ProviderID, key: String) async -> Bool {
        var request = URLRequest(url: provider.keyValidationURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
