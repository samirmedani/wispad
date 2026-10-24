import Foundation
import Testing
@testable import WispadCore

@Suite struct ProfileTopicsTests {
    private func sources(_ texts: [String]) -> [TopicSource] {
        texts.enumerated().map { TopicSource(id: "d\($0.offset)", date: Date(timeIntervalSince1970: Double($0.offset) * 60), text: $0.element) }
    }

    @Test func batchesStayUnderTheirSizeAndKeepEveryDictation() {
        let long = String(repeating: "mot ", count: 400)
        let all = sources(Array(repeating: long, count: 200) + ["", "   "])
        let lots = TopicAnalyzer.batches(all)
        #expect(lots.joined().count == 200)
        #expect(lots.allSatisfy { $0.reduce(0) { $0 + $1.text.count + 6 } <= TopicAnalyzer.maxCharactersPerBatch + TopicAnalyzer.maxCharactersPerDictation + 6 })
        #expect(lots.joined().allSatisfy { $0.text.count <= TopicAnalyzer.maxCharactersPerDictation })
        let estimate = TopicAnalyzer.estimate(all, model: CleanupModel.openAIFallback, portrait: false)
        #expect(estimate.batches == lots.count)
        #expect(estimate.costUSD != nil)
        #expect(TopicAnalyzer.estimate(all, model: "inconnu", portrait: false).costUSD == nil)
        #expect(TopicAnalyzer.estimate(all, model: CleanupModel.openAIFallback, portrait: true).tokens.input > estimate.tokens.input)
    }

    @Test func replyNumbersPointToTheDictationsOfTheBatch() throws {
        let batch = sources(["Je pousse le build", "Le train pour Lyon", "Encore le build"])
        let reply = """
        Voici : ```json
        {"topics":[{"name":"Build","category":"Code","keywords":["build"],"dictations":[1,3,9]},
                   {"name":"Voyage","category":"","dictations":[2]},
                   {"name":"Vide","category":"Code","dictations":[]}]}
        ```
        """
        let topics = try #require(TopicAnalyzer.parse(reply, batch: batch))
        #expect(topics.count == 2)
        #expect(topics[0].dictations == ["d0", "d2"])
        #expect(topics[1].category == "Divers")
        #expect(TopicAnalyzer.parse("pas du JSON", batch: batch) == nil)
    }

    @Test func topicsFromSeveralBatchesMergeByName() {
        let merged = TopicAnalyzer.merge([
            .init(name: "Wispad", category: "Code", keywords: ["build"], dictations: ["a", "b"]),
            .init(name: "Cuisine", category: "Maison", keywords: [], dictations: ["c"]),
            .init(name: "wispad", category: "Projets", keywords: ["Build", "tests"], dictations: ["b", "d"]),
        ])
        #expect(merged.count == 2)
        #expect(merged[0].name == "Wispad")
        #expect(merged[0].category == "Code")
        #expect(merged[0].dictations == ["a", "b", "d"])
        #expect(merged[0].keywords == ["build", "tests"])
    }

    @Test func topicBrainHasCategoriesLinkedToTheirTopics() {
        let analysis = TopicAnalysis(topics: [
            .init(name: "Wispad", category: "Code", keywords: ["build"], dictations: ["a", "b", "c"]),
            .init(name: "Vercel", category: "Code", keywords: [], dictations: ["b", "c"]),
            .init(name: "Lyon", category: "Voyages", keywords: [], dictations: ["x"]),
        ], analyzedAt: Date(), dictationCount: 4, newestDictation: nil, service: "s", costUSD: 0)
        let graph = WordGraph.topics(analysis)
        let code = graph.nodes.first { $0.word == "Code" }
        #expect(code?.isCategory == true)
        #expect(code?.count == 3)
        let wispad = graph.nodes.first { $0.word == "Wispad" }!
        let vercel = graph.nodes.first { $0.word == "Vercel" }!
        #expect(wispad.details == ["build"])
        #expect(graph.neighbors(of: wispad.id).contains { $0.node.id == code!.id })
        #expect(graph.neighbors(of: wispad.id).contains { $0.node.id == vercel.id && $0.weight == 2 })
        #expect(graph.nodes.filter(\.isCategory).count == 2)
        #expect(WordGraph.topics(analysis) == graph)
    }
}

@Suite struct ProfileTopicsLiveTests {
    @Test func liveAnalysisWithTheTestKey() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["WISPAD_LIVE_TESTS"] == "1", let key = env["WISPAD_LIVE_DEEPSEEK_KEY"], !key.isEmpty else { return }
        let themes = ["Je pousse le build de l'application sur GitHub, les tests passent et je déploie sur Vercel.",
                      "On réserve le train pour Lyon vendredi et l'hôtel près de la gare.",
                      "Relance le client pour le devis et la facture de septembre.",
                      "La recette du gâteau au chocolat demande du beurre et des œufs.",
                      "D'accord, vas-y, passe-moi ça, on voit ça demain."]
        let all = (0..<300).map { TopicSource(id: "d\($0)", date: Date(timeIntervalSince1970: Double($0) * 600), text: themes[$0 % themes.count] + " Note \($0 / 5).") }
        var speech = SpeechRequest(provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0",
                                   apiKey: "", language: .french, keyterms: [], prompt: "")
        speech.cleanupKey = key
        speech.cleanupRelay = .off
        let estimate = TopicAnalyzer.estimate(all, model: CleanupModel.deepSeek, portrait: true)
        let start = Date()
        let result = try await TopicAnalyzer.run(sources: all, speech: speech, portrait: true, stats: "300 dictées") { _, _ in }
        let real = result.usage.reduce(TokenUsage()) { TokenUsage(input: $0.input + $1.tokens.input + $1.tokens.cachedInput, cachedInput: 0, output: $0.output + $1.tokens.output) }
        print("TOPICS-LIVE", String(format: "%.1f s", Date().timeIntervalSince(start)), "lots", estimate.batches,
              "estimé", estimate.tokens.input, estimate.tokens.output, estimate.costUSD ?? -1,
              "réel", real.input, real.output, result.analysis.costUSD ?? -1)
        for topic in result.analysis.topics { print("TOPICS-LIVE", topic.category, "|", topic.name, topic.dictations.count, topic.keywords) }
        print("TOPICS-LIVE portrait:", result.analysis.portrait ?? "-")
        #expect(!result.analysis.topics.isEmpty)
    }
}
