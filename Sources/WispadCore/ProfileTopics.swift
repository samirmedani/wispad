import Foundation

/// Cerveau par sujets : une IA relit l'historique par lots et en tire les sujets concrets (projets, activités,
/// thèmes) rangés en grandes catégories. Seulement à la demande, avec la clé de correction : le coût est estimé
/// avant, et chaque appel compte dans la consommation.
public struct TopicAnalysis: Codable, Equatable, Sendable {
    public struct Topic: Codable, Equatable, Sendable {
        public var name: String
        public var category: String
        public var keywords: [String]
        /// Identifiants des dictées où le sujet revient.
        public var dictations: [String]

        public init(name: String, category: String, keywords: [String], dictations: [String]) {
            self.name = name
            self.category = category
            self.keywords = keywords
            self.dictations = dictations
        }
    }

    public var topics: [Topic]
    public var analyzedAt: Date
    /// Dictées relues, et la plus récente : celles d'après sont « nouvelles depuis l'analyse ».
    public var dictationCount: Int
    public var newestDictation: Date?
    /// « DeepSeek deepseek-flash ».
    public var service: String
    /// Coût réel des appels, nil si un tarif est inconnu.
    public var costUSD: Double?
    /// Portrait écrit, s'il a été demandé.
    public var portrait: String?

    public init(topics: [Topic], analyzedAt: Date, dictationCount: Int, newestDictation: Date?, service: String,
                costUSD: Double?, portrait: String? = nil) {
        self.topics = topics
        self.analyzedAt = analyzedAt
        self.dictationCount = dictationCount
        self.newestDictation = newestDictation
        self.service = service
        self.costUSD = costUSD
        self.portrait = portrait
    }
}

/// Une dictée telle que l'analyse la lit : son identifiant, sa date et son texte final.
public struct TopicSource: Sendable {
    public var id: String
    public var date: Date
    public var text: String

    public init(id: String, date: Date, text: String) {
        self.id = id
        self.date = date
        self.text = text
    }

    public init(_ record: DictationRecord) {
        self.init(id: record.id, date: record.createdAt, text: record.finalText)
    }
}

/// Coût prévu d'une analyse : jetons et dollars (nil si le tarif du modèle est inconnu).
public struct TopicEstimate: Equatable, Sendable {
    public init(batches: Int, tokens: TokenUsage, costUSD: Double?) {
        self.batches = batches
        self.tokens = tokens
        self.costUSD = costUSD
    }

    public var batches: Int
    public var tokens: TokenUsage
    public var costUSD: Double?
}

extension TopicAnalysis {
    /// Sans les dictées supprimées depuis l'analyse ; un sujet qui n'a plus de dictée disparaît.
    public func pruned(keeping existing: Set<String>) -> TopicAnalysis {
        var copy = self
        copy.topics = topics.compactMap { topic in
            var kept = topic
            kept.dictations = topic.dictations.filter(existing.contains)
            return kept.dictations.isEmpty ? nil : kept
        }
        return copy
    }

    /// Dictées arrivées depuis l'analyse.
    public func newSources(in sources: [TopicSource]) -> [TopicSource] {
        guard let newest = newestDictation else { return sources }
        return sources.filter { $0.date > newest }
    }

    /// Mise à jour hebdomadaire due : l'analyse a au moins une semaine et des dictées sont arrivées depuis.
    public func isDueForWeeklyUpdate(sources: [TopicSource], now: Date = Date()) -> Bool {
        now.timeIntervalSince(analyzedAt) >= TopicAnalyzer.weeklyInterval && !newSources(in: sources).isEmpty
    }
}

public enum TopicAnalyzer {
    public static let weeklyInterval: TimeInterval = 7 * 86_400

    /// Coût d'une semaine type : les dictées des 4 dernières semaines, divisées par 4.
    public static func weeklyEstimate(_ sources: [TopicSource], model: String?, portrait: Bool, now: Date = Date()) -> TopicEstimate {
        let recent = sources.filter { now.timeIntervalSince($0.date) <= 4 * weeklyInterval }
        let week = Array(recent.prefix(max(1, recent.count / 4)))
        return estimate(recent.isEmpty ? [] : week, model: model, portrait: portrait)
    }

    /// Texte relu par dictée au plus, et texte d'un lot : un lot tient dans le contexte de tout modèle de correction.
    static let maxCharactersPerDictation = 700
    static let maxCharactersPerBatch = 36_000
    /// Jetons de la consigne, et réponse attendue par lot ; environ 3,6 caractères par jeton en français.
    static let promptTokens = 650
    static let outputTokensPerBatch = 1_100
    public static let portraitTokens = TokenUsage(input: 1_400, cachedInput: 0, output: 260)

    /// Dictées non vides, de la plus ancienne à la plus récente, coupées à leur longueur relue.
    static func prepared(_ sources: [TopicSource]) -> [TopicSource] {
        sources.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.date < $1.date }
            .map { TopicSource(id: $0.id, date: $0.date, text: String($0.text.prefix(maxCharactersPerDictation))) }
    }

    /// Lots successifs, chaque dictée numérotée dans son lot (« #12 texte »).
    public static func batches(_ sources: [TopicSource]) -> [[TopicSource]] {
        var result: [[TopicSource]] = []
        var current: [TopicSource] = []
        var size = 0
        for source in prepared(sources) {
            if size + source.text.count > maxCharactersPerBatch, !current.isEmpty {
                result.append(current)
                current = []
                size = 0
            }
            current.append(source)
            size += source.text.count + 6
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func estimate(_ sources: [TopicSource], model: String?, portrait: Bool, at date: Date = Date()) -> TopicEstimate {
        let lots = batches(sources)
        let characters = lots.joined().reduce(0) { $0 + $1.text.count + 6 }
        var tokens = TokenUsage(input: Int(Double(characters) / 3.6) + promptTokens * lots.count, cachedInput: 0,
                                output: outputTokensPerBatch * lots.count)
        if portrait {
            tokens.input += portraitTokens.input
            tokens.output += portraitTokens.output
        }
        let cost = model.flatMap { Pricing.tokenCost(model: $0, tokens: tokens, at: date) }
        return TopicEstimate(batches: lots.count, tokens: tokens, costUSD: lots.isEmpty ? 0 : cost)
    }

    static let system = """
    Tu analyses des dictées vocales d'une même personne pour en tirer les sujets dont elle parle. Réponds uniquement \
    avec un objet JSON, sans texte autour : {"topics":[{"name":"…","category":"…","keywords":["…"],"dictations":[1,2]}]}.
    Un sujet est un projet, un produit, une activité ou un thème concret et nommé (« Application Wispad », « Ventes \
    en ligne », « Cuisine »), jamais un mot vide, un verbe, une formule de politesse ou un tic de langage.
    La catégorie est un domaine large et court : Code, Travail, Projets, Achats, Finances, Maison, Santé, Sport, \
    Loisirs, Voyages, Famille, Apprentissage, Communication, ou un autre nom court si aucun ne convient. Garde le même \
    nom de catégorie pour des sujets du même domaine.
    keywords : 3 à 5 mots concrets du sujet, tels qu'ils sont dits. dictations : les numéros des dictées qui en \
    parlent ; une dictée va dans 2 sujets au plus, une dictée sans sujet clair n'en a aucun.
    Au plus 15 sujets. Écris les noms dans la langue des dictées. Aucune donnée personnelle : ni nom de personne privée, \
    ni e-mail, numéro, adresse ou mot de passe.
    """

    static func user(_ batch: [TopicSource]) -> String {
        batch.enumerated().map { "#\($0.offset + 1) \($0.element.text.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
    }

    struct Reply: Decodable {
        struct Item: Decodable {
            var name: String
            var category: String?
            var keywords: [String]?
            var dictations: [Int]?
        }

        var topics: [Item]
    }

    /// Sujets d'une réponse ; les numéros renvoient aux dictées du lot. nil si la réponse n'est pas du JSON lisible.
    static func parse(_ content: String, batch: [TopicSource]) -> [TopicAnalysis.Topic]? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(content[start...end].utf8)) else { return nil }
        return reply.topics.compactMap { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let ids = (item.dictations ?? []).compactMap { batch.indices.contains($0 - 1) ? batch[$0 - 1].id : nil }
            guard !ids.isEmpty else { return nil }
            let category = item.category?.trimmingCharacters(in: .whitespacesAndNewlines)
            return TopicAnalysis.Topic(name: name, category: category?.isEmpty == false ? category! : "Divers",
                                       keywords: Array((item.keywords ?? []).prefix(5)), dictations: ids)
        }
    }

    /// Sujets de tous les lots réunis : même nom (sans casse ni accents), un seul sujet ; sa catégorie est la plus
    /// fréquente parmi ses parties, ses dictées et mots-clés sont réunis.
    public static func merge(_ topics: [TopicAnalysis.Topic]) -> [TopicAnalysis.Topic] {
        var groups: [String: [TopicAnalysis.Topic]] = [:]
        var order: [String] = []
        for topic in topics {
            let key = CorrectionLearner.key(topic.name)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(topic)
        }
        return order.compactMap { key -> TopicAnalysis.Topic? in
            guard let parts = groups[key], let first = parts.first else { return nil }
            var categories: [String: Int] = [:]
            for part in parts { categories[part.category, default: 0] += part.dictations.count }
            let category = categories.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? first.category
            var keywords: [String] = []
            for word in parts.flatMap(\.keywords) where !keywords.contains(where: { CorrectionLearner.key($0) == CorrectionLearner.key(word) }) {
                keywords.append(word)
            }
            var dictations: [String] = []
            var seen = Set<String>()
            for id in parts.flatMap(\.dictations) where seen.insert(id).inserted { dictations.append(id) }
            return TopicAnalysis.Topic(name: first.name, category: category, keywords: Array(keywords.prefix(6)), dictations: dictations)
        }
        .sorted { $0.dictations.count != $1.dictations.count ? $0.dictations.count > $1.dictations.count : $0.name < $1.name }
    }

    /// Relit l'historique : lots envoyés trois par trois au premier service de correction, puis portrait si demandé.
    /// « progress » reçoit le nombre de lots terminés. Les appels (réussis ou non) sont rendus pour la consommation.
    public static func run(
        sources: [TopicSource],
        speech: SpeechRequest,
        portrait: Bool,
        stats: String,
        previous: TopicAnalysis? = nil,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> (analysis: TopicAnalysis, usage: [UsageEvent]) {
        guard let route = TextCleaner.routes(speech).first else { throw SpeechError.message("Aucune clé de correction active") }
        // Mise à jour : seules les dictées arrivées depuis l'analyse précédente sont relues.
        let lots = batches(previous?.newSources(in: sources) ?? sources)
        let requests = TextCleaner.RequestLog()
        var found: [TopicAnalysis.Topic] = []
        var done = 0
        var failures = 0
        try await withThrowingTaskGroup(of: [TopicAnalysis.Topic]?.self) { group in
            var next = 0
            func launch() {
                guard next < lots.count else { return }
                let batch = lots[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let reply = try? await TextCleaner.send(system: system, user: user(batch), route: route, maxTokens: 2_400,
                                                            includeReasoning: true, requests: requests, requestTimeout: 120)
                    return reply.flatMap { parse($0.content, batch: batch) }
                }
            }
            for _ in 0..<min(3, lots.count) { launch() }
            while let result = try await group.next() {
                if let result { found += result } else { failures += 1 }
                done += 1
                await progress(done, lots.count)
                launch()
            }
        }
        if failures == lots.count, !lots.isEmpty { throw SpeechError.message("Le service n'a rendu aucun sujet lisible") }
        let topics = merge((previous?.topics ?? []) + found)
        var text: String?
        if portrait, !topics.isEmpty {
            let list = topics.prefix(25).map { "\($0.name) (\($0.category), \($0.dictations.count) dictées)" }.joined(separator: "\n")
            let reply = try? await TextCleaner.send(
                system: """
                Écris en 3 phrases courtes, au tutoiement, un portrait bienveillant et concret de la personne d'après \
                les sujets de ses dictées et ses chiffres : ce qui l'occupe le plus, comment se répartit son temps, un \
                trait marquant. Pas de flatterie, pas de donnée personnelle, pas de titre ni de liste. Texte brut seulement.
                """,
                user: "Chiffres :\n\(stats)\n\nSujets :\n\(list)", route: route, maxTokens: 500, includeReasoning: true,
                requests: requests, requestTimeout: 60)
            text = reply?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let usage = requests.events
        let costs = usage.map(\.costUSD)
        var cost: Double? = costs.contains(where: { $0 == nil }) ? nil : costs.compactMap { $0 }.reduce(0, +)
        if let previous { cost = cost.flatMap { now in previous.costUSD.map { $0 + now } } }
        let analysis = TopicAnalysis(
            topics: topics,
            analyzedAt: Date(),
            dictationCount: (previous?.dictationCount ?? 0) + lots.joined().count,
            newestDictation: lots.last?.last?.date ?? previous?.newestDictation,
            service: "\(route.provider) \(route.model)",
            costUSD: cost,
            portrait: text ?? (portrait ? previous?.portrait : nil)
        )
        return (analysis, usage)
    }
}

extension WordGraph {
    /// Cerveau par sujets : les grandes catégories (8 au plus) et leurs sujets principaux (6 au plus chacune). Un sujet
    /// est relié à sa catégorie, et à un autre sujet quand ils partagent au moins deux dictées.
    public static func topics(_ analysis: TopicAnalysis) -> WordGraph {
        var byCategory: [String: [TopicAnalysis.Topic]] = [:]
        for topic in analysis.topics { byCategory[topic.category, default: []].append(topic) }
        struct Category {
            var name: String
            var topics: [TopicAnalysis.Topic]
            var size: Int
        }
        var all: [Category] = []
        for (name, topics) in byCategory {
            var ids = Set<String>()
            for topic in topics { ids.formUnion(topic.dictations) }
            all.append(Category(name: name, topics: topics, size: ids.count))
        }
        all.sort { (a: Category, b: Category) -> Bool in
            if a.size != b.size { return a.size > b.size }
            return a.name < b.name
        }
        let ranked = all.prefix(8)
        var nodes: [Node] = []
        var edges: [Edge] = []
        var topicDictations: [(id: Int, dictations: Set<String>)] = []
        for (rank, category) in ranked.enumerated() {
            let categoryID = nodes.count
            var categoryIDs: [String] = []
            var seen = Set<String>()
            for topic in category.topics { for id in topic.dictations where seen.insert(id).inserted { categoryIDs.append(id) } }
            nodes.append(Node(id: categoryID, word: category.name, count: category.size, cluster: rank, x: 0, y: 0, z: 0,
                              isCategory: true, details: [], dictations: categoryIDs))
            for topic in category.topics.prefix(6) {
                let id = nodes.count
                nodes.append(Node(id: id, word: topic.name, count: topic.dictations.count, cluster: rank, x: 0, y: 0, z: 0,
                                  isCategory: false, details: topic.keywords, dictations: topic.dictations))
                edges.append(Edge(a: categoryID, b: id, weight: topic.dictations.count))
                topicDictations.append((id, Set(topic.dictations)))
            }
        }
        for i in topicDictations.indices {
            for j in topicDictations.indices where j > i {
                let shared = topicDictations[i].dictations.intersection(topicDictations[j].dictations).count
                if shared >= 2 { edges.append(Edge(a: topicDictations[i].id, b: topicDictations[j].id, weight: shared)) }
            }
        }
        guard nodes.count >= 2 else { return WordGraph(nodes: nodes, edges: edges) }
        let positions = layout(count: nodes.count, edges: edges, clusters: nodes.map(\.cluster))
        for index in nodes.indices {
            nodes[index].x = positions[index].x
            nodes[index].y = positions[index].y
            nodes[index].z = positions[index].z
        }
        return WordGraph(nodes: nodes, edges: edges)
    }
}
