import Foundation

/// Un modèle de texte d'une clé API : il peut corriger les dictées ou servir de relais.
public struct TextModel: Hashable, Codable, Sendable, Identifiable {
    /// Rapidité attendue d'une correction : mesurée sur tes dictées quand le modèle a déjà servi, sinon devinée sur son nom.
    public enum Speed: Int, Codable, Sendable, Comparable, CaseIterable {
        case fast
        case balanced
        case slow

        public static func < (lhs: Speed, rhs: Speed) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Compte de la clé : « deepseek », « openai », « xai ».
    public var account: String
    /// Identifiant du modèle chez le fournisseur.
    public var model: String

    public init(account: String, model: String) {
        self.account = account
        self.model = model
    }

    public var id: String { choice.rawValue }
    public var choice: CleanupChoice { CleanupChoice(account: account, model: model) }
    /// Un des modèles d'origine de Wispad, réglés et testés sur la correction.
    public var isRecommended: Bool { CleanupChoice.models.contains(choice) }
}

/// Modèles de texte des clés : ceux qui servent à corriger, leur rapidité et leur coût estimé.
public enum TextModelCatalog {
    /// Une correction typique : la consigne, la dictée et son contexte en entrée, la dictée corrigée en sortie.
    public static let typicalTokens = TokenUsage(input: 1_800, cachedInput: 0, output: 150)

    /// Modèles proposés tant que la liste du fournisseur n'a pas été lue : les modèles d'origine.
    public static func defaults(account: String) -> [TextModel] {
        CleanupChoice.models.compactMap { choice in
            guard choice.account == account, let model = choice.model else { return nil }
            return TextModel(account: account, model: model)
        }
    }

    /// Adresse de la liste des modèles d'un compte.
    public static func listURL(account: String) -> URL? {
        switch account {
        case CleanupModel.deepSeekAccount: return URL(string: "https://api.deepseek.com/models")
        case ProviderID.openAI.rawValue: return URL(string: "https://api.openai.com/v1/models")
        case ProviderID.xai.rawValue: return URL(string: "https://api.x.ai/v1/models")
        default: return nil
        }
    }

    /// Identifiants lus dans la réponse de « /models » (format OpenAI : { "data": [{ "id": … }] }).
    public static func identifiers(in data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }
    }

    /// Fragments d'un modèle qui ne rend pas de texte de chat, ou qui ne convient pas à une correction rapide :
    /// voix, images, vidéo, embeddings, modération, recherche, agents et code.
    static let excludedFragments = [
        "embed", "tts", "whisper", "transcri", "audio", "realtime", "live", "image", "imagine", "video", "sora",
        "dall-e", "moderation", "search", "research", "babbage", "davinci", "instruct", "codex", "diarize",
        "translate", "multi-agent", "grok-build", "computer-use", "chat-latest", "jev"
    ]

    public static func isTextModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        return !excludedFragments.contains { lower.contains($0) }
    }

    /// Modèles de texte d'un compte, sans les versions datées quand le modèle existe aussi sans date
    /// (« gpt-4.1-mini-2025-04-14 » à côté de « gpt-4.1-mini »). Les modèles d'origine restent toujours.
    public static func usable(_ identifiers: [String], account: String) -> [TextModel] {
        let text = Set(identifiers.filter(isTextModel))
        var kept = text.filter { id in
            guard let base = undated(id) else { return true }
            return !text.contains(base)
        }
        kept.formUnion(defaults(account: account).map(\.model))
        return kept.sorted().map { TextModel(account: account, model: $0) }
    }

    /// Nom sans sa date finale (« -2025-04-14 »), ou nil s'il n'en porte pas.
    static func undated(_ id: String) -> String? {
        guard let range = id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) else { return nil }
        return String(id[..<range.lowerBound])
    }

    /// Rapidité : la latence médiane mesurée chez toi s'il y en a une, sinon le nom du modèle.
    public static func speed(_ model: String, measuredMilliseconds: Int? = nil) -> TextModel.Speed {
        if let measured = measuredMilliseconds {
            return measured < 1_300 ? .fast : measured < 2_800 ? .balanced : .slow
        }
        let lower = model.lowercased()
        if ["pro", "max", "astra", "opus"].contains(where: { lower.hasSuffix("-" + $0) || lower.contains("-" + $0 + "-") })
            || lower.range(of: #"^o[13](-|$)"#, options: .regularExpression) != nil
            || (lower.contains("reasoning") && !lower.contains("non-reasoning")) {
            return .slow
        }
        if ["nano", "mini", "flash", "luna", "lite", "fast", "non-reasoning", "turbo"].contains(where: lower.contains) {
            return .fast
        }
        return .balanced
    }

    /// Adresse de la liste des modèles d'un compte, avec la « clé » de ce compte (l'adresse du serveur pour le local).
    public static func listURL(account: String, key: String) -> URL? {
        if account == CleanupModel.localAccount { return TextCleaner.localBase(key)?.appendingPathComponent("models") }
        return listURL(account: account)
    }

    /// Coût estimé de 100 corrections typiques, en dollars ; nil si le tarif du modèle est inconnu.
    public static func costPerHundred(_ model: String, tokens: TokenUsage = typicalTokens, at date: Date = Date()) -> Double? {
        Pricing.tokenCost(model: model, tokens: tokens, at: date).map { $0 * 100 }
    }

    /// Ordre des menus : modèles d'origine d'abord, puis du plus rapide au plus lent, du moins cher au plus cher
    /// (tarif inconnu en dernier), puis par nom.
    public static func sorted(_ models: [TextModel], latencies: [String: Int] = [:], at date: Date = Date()) -> [TextModel] {
        models.sorted { a, b in
            if a.isRecommended != b.isRecommended { return a.isRecommended }
            let sa = speed(a.model, measuredMilliseconds: latencies[a.model])
            let sb = speed(b.model, measuredMilliseconds: latencies[b.model])
            if sa != sb { return sa < sb }
            let ca = costPerHundred(a.model, at: date), cb = costPerHundred(b.model, at: date)
            switch (ca, cb) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.model.localizedStandardCompare(b.model) == .orderedAscending
            }
        }
    }

    /// Latence médiane des corrections réussies, par modèle, en millisecondes.
    public static func medianLatencies(_ events: [UsageEvent]) -> [String: Int] {
        let cleanup: Set<UsageAPI> = [.deepSeekCleanup, .openAICleanup, .xaiCleanup]
        var byModel: [String: [Int]] = [:]
        for event in events where cleanup.contains(event.api) && event.succeeded && event.latencyMs > 0 {
            byModel[event.model, default: []].append(event.latencyMs)
        }
        return byModel.mapValues { values in
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
    }

    /// Réglage de raisonnement accepté par le modèle, pour une correction sans réflexion ; nil s'il n'en prend pas
    /// (l'envoyer ferait refuser la requête, puis la refaire).
    public static func reasoningEffort(api: UsageAPI, model: String) -> String? {
        let lower = model.lowercased()
        switch api {
        case .deepSeekCleanup, .localCleanup:
            return nil
        case .xaiCleanup:
            return lower.contains("non-reasoning") ? nil : "low"
        default:
            if lower.range(of: #"^o\d"#, options: .regularExpression) != nil { return "low" }
            guard lower.hasPrefix("gpt-") else { return lower.hasPrefix("chatgpt") ? nil : "none" }
            let version = lower.dropFirst(4).prefix { $0.isNumber || $0 == "." }.split(separator: ".")
            guard let major = version.first.flatMap({ Int($0) }) else { return nil }
            let minor = version.dropFirst().first.flatMap { Int($0) } ?? 0
            if major < 5 { return nil }
            if major == 5 && minor == 0 { return "minimal" }
            return "none"
        }
    }
}
