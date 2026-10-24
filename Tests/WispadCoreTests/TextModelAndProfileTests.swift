import Foundation
import Testing
@testable import WispadCore

@Suite struct TextModelTests {
    @Test func originalChoicesKeepTheirStoredNames() {
        #expect(CleanupChoice(rawValue: "gpt-5.6-luna") == .openAILuna)
        #expect(CleanupChoice(account: "openai", model: "gpt-5.4-mini") == .openAIMini)
        #expect(CleanupChoice(account: "xai", model: "grok-4.7").rawValue == "grok-4.7")
        #expect(CleanupChoice(rawValue: "modele-futur") == nil)
        #expect(CleanupChoice(rawValue: "inconnu/gpt-4o") == nil)
    }

    @Test func anyModelOfAKeyCanBeChosen() throws {
        let choice = CleanupChoice(account: "openai", model: "gpt-4.1-mini")
        #expect(choice.rawValue == "openai/gpt-4.1-mini")
        #expect(choice.account == "openai")
        #expect(choice.model == "gpt-4.1-mini")
        #expect(choice.providerName == "OpenAI")
        let data = try JSONEncoder().encode(choice)
        #expect(try JSONDecoder().decode(CleanupChoice.self, from: data) == choice)
        #expect(CleanupChoice(providerName: "DeepSeek", model: "deepseek-v4-pro")?.rawValue == "deepseek/deepseek-v4-pro")

        var speech = SpeechRequest(provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0",
                                   apiKey: "voice", language: .french, keyterms: [], prompt: "")
        speech.cleanupChoice = choice
        speech.chosenCleanupKey = "chosen"
        speech.cleanupRelay = .off
        let route = try #require(TextCleaner.routes(speech).first)
        #expect(route.model == "gpt-4.1-mini")
        #expect(route.api == .openAICleanup)
        #expect(route.key == "chosen")
    }

    @Test func reasoningIsOnlySentToModelsThatTakeIt() {
        #expect(TextModelCatalog.reasoningEffort(api: .openAICleanup, model: "gpt-5.4-mini") == "none")
        #expect(TextModelCatalog.reasoningEffort(api: .openAICleanup, model: "gpt-6-luna") == "none")
        #expect(TextModelCatalog.reasoningEffort(api: .openAICleanup, model: "gpt-5-mini") == "minimal")
        #expect(TextModelCatalog.reasoningEffort(api: .openAICleanup, model: "o4-mini") == "low")
        #expect(TextModelCatalog.reasoningEffort(api: .openAICleanup, model: "gpt-4.1-mini") == nil)
        #expect(TextModelCatalog.reasoningEffort(api: .xaiCleanup, model: "grok-4.7") == "low")
        #expect(TextModelCatalog.reasoningEffort(api: .xaiCleanup, model: "grok-4.20-0309-non-reasoning") == nil)
        #expect(TextModelCatalog.reasoningEffort(api: .deepSeekCleanup, model: "deepseek-flash") == nil)
    }

    @Test func listsKeepTextModelsOnly() {
        let ids = ["gpt-4.1-mini", "gpt-4.1-mini-2025-04-14", "gpt-image-2", "whisper-1", "text-embedding-3-small",
                   "gpt-realtime", "tts-1", "gpt-5-codex", "o3", "gpt-4o-mini-transcribe", "sora-2"]
        let models = TextModelCatalog.usable(ids, account: "openai").map(\.model)
        #expect(models.contains("gpt-4.1-mini"))
        #expect(models.contains("o3"))
        #expect(!models.contains("gpt-4.1-mini-2025-04-14"))
        #expect(!models.contains(where: { ["gpt-image-2", "whisper-1", "tts-1", "gpt-realtime", "gpt-5-codex", "sora-2"].contains($0) }))
        // Les modèles d'origine restent proposés même si la liste ne les nomme pas.
        #expect(models.contains("gpt-5.4-mini") && models.contains("gpt-5.6-luna"))
        #expect(TextModelCatalog.identifiers(in: Data(#"{"data":[{"id":"a"},{"id":"b"}]}"#.utf8)) == ["a", "b"])
    }

    @Test func menusPutRecommendedThenFastAndCheapFirst() {
        let models = ["o3", "gpt-4.1-nano", "gpt-4.1-mini", "gpt-5.4-mini", "mystere"].map { TextModel(account: "openai", model: $0) }
        let order = TextModelCatalog.sorted(models).map(\.model)
        #expect(order.first == "gpt-5.4-mini")
        #expect(order.firstIndex(of: "gpt-4.1-nano")! < order.firstIndex(of: "gpt-4.1-mini")!)
        #expect(order.last == "o3")
        #expect(TextModelCatalog.speed("x", measuredMilliseconds: 900) == .fast)
        #expect(TextModelCatalog.speed("gpt-5.5-pro") == .slow)
        #expect(TextModelCatalog.costPerHundred("gpt-4.1-mini") != nil)
        #expect(TextModelCatalog.costPerHundred("mystere") == nil)
        let events = [900, 1_100, 3_000].map { UsageEvent(api: .openAICleanup, model: "gpt-4.1-mini", costUSD: 0, latencyMs: $0) }
        #expect(TextModelCatalog.medianLatencies(events)["gpt-4.1-mini"] == 1_100)
    }
}

@Suite struct DictationProfileTests {
    private func record(_ final: String, raw: String? = nil, daysAgo: Double, app: String = "Notes", now: Date) -> DictationRecord {
        DictationRecord(createdAt: now.addingTimeInterval(-daysAgo * 86_400), finalText: final, rawText: raw ?? final,
                        durationSeconds: 6, wordCount: final.split(separator: " ").count, provider: "xAI", model: "m",
                        targetApp: app, insertionStatus: "inserted")
    }

    @Test func profileCountsWordsTicsFixesAndStreaks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 15))!
        let records = [
            record("Je pousse le build sur GitHub.", raw: "euh je pousse le build sur github", daysAgo: 0, now: now),
            record("Le build casse sur GitHub, demande à Claude.", raw: "du coup le build casse sur github demande à cloud", daysAgo: 1, now: now),
            record("Demande à Claude de relire.", raw: "demande à cloud de relire", daysAgo: 2, now: now),
            record("Écris à jean@exemple.fr pour 06 12 34 56 78.", daysAgo: 5, now: now),
        ]
        let profile = ProfileBuilder.build(records: records, now: now, calendar: calendar)
        #expect(profile.dictations == 4)
        #expect(profile.currentStreak == 3)
        #expect(profile.bestStreak == 3)
        #expect(profile.topWords.first.map { ["build", "github", "claude"].contains($0.label) } == true)
        #expect(!profile.topWords.contains { $0.label.contains("@") || $0.label.contains(where: \.isNumber) })
        #expect(profile.tics.contains { $0.label == "euh" } && profile.tics.contains { $0.label == "du coup" })
        #expect(profile.fixes.contains { $0.heard == "cloud" && $0.written == "claude" && $0.count == 2 })
        #expect(profile.daily.count == DictationProfile.heatmapDays)
        let hidden = ProfileBuilder.build(records: records, hidden: ["build"], now: now, calendar: calendar)
        #expect(!hidden.topWords.contains { $0.label == "build" })
    }

    @Test func brainLinksWordsSaidTogetherAndIsStable() {
        let now = Date()
        let records = (0..<12).map { index in
            index % 2 == 0
                ? record("Train pour Lyon et hôtel réservé.", daysAgo: Double(index), now: now)
                : record("Recette chocolat beurre farine.", daysAgo: Double(index), now: now)
        }
        let graph = WordGraph.build(records: records)
        let first = WordGraph.build(records: records)
        #expect(graph == first)
        let train = try! #require(graph.nodes.first { $0.word == "train" })
        let lyon = try! #require(graph.nodes.first { $0.word == "lyon" })
        let chocolat = try! #require(graph.nodes.first { $0.word == "chocolat" })
        #expect(train.cluster == lyon.cluster)
        #expect(train.cluster != chocolat.cluster)
        #expect(graph.neighbors(of: train.id).contains { $0.node.word == "lyon" })
        #expect(!graph.neighbors(of: train.id).contains { $0.node.word == "chocolat" })
    }
}
