import Foundation
import Testing
@testable import WispadCore

@Suite struct ProfileTopicsAccountingTests {
    private func speech() -> SpeechRequest {
        var speech = SpeechRequest(provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "",
                                   language: .french, keyterms: [], prompt: "")
        speech.cleanupKey = "fixture-only"
        speech.cleanupRelay = .off
        return speech
    }

    private static func response(_ content: String, request: URLRequest) throws -> (Data, URLResponse) {
        let object: [String: Any] = [
            "choices": [["message": ["content": content], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 1000, "completion_tokens": 50]
        ]
        return (try JSONSerialization.data(withJSONObject: object),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    @Test func unreadablePaidResponseIsAccountedBeforeTheAnalysisThrows() async throws {
        let events = TopicTestEvents()
        var failed = false
        do {
            _ = try await TopicAnalyzer.run(
                sources: [.init(id: "fiction", date: Date(), text: "Une recette de soupe")], speech: speech(),
                portrait: false, stats: "", transport: { request in try Self.response("Texte non JSON", request: request) },
                onUsage: { await events.append($0) }, progress: { _, _ in })
        } catch { failed = true }
        let saved = await events.values
        #expect(failed)
        #expect(saved.count == 1)
        #expect(saved.first?.tokens == TokenUsage(input: 1000, output: 50))
        #expect(saved.first?.costUSD != nil)
    }

    @Test func cancellationStillAccountsTheResponseAndNeverReturnsAnAnalysis() async throws {
        let sent = AsyncResult<Void>()
        let release = AsyncResult<Void>()
        let events = TopicTestEvents()
        let speech = speech()
        let task = Task {
            try await TopicAnalyzer.run(sources: [.init(id: "fiction", date: Date(), text: "Une recette de soupe")],
                speech: speech, portrait: false, stats: "", transport: { request in
                    sent.resolve(.success(()))
                    try await release.value()
                    return try Self.response(#"{"topics":[]}"#, request: request)
                }, onUsage: { await events.append($0) }, progress: { _, _ in })
        }
        try await sent.value()
        task.cancel()
        release.resolve(.success(()))
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        let saved = await events.values
        #expect(cancelled)
        #expect(saved.count == 1)
        #expect(saved.first?.tokens.input == 1000)
    }

    @Test func failedOlderBatchRemainsUnreadAfterANewerBatchSucceeds() async throws {
        let start = Date()
        let sources = (0..<60).map { index in
            TopicSource(id: "fiction-\(index)", date: start.addingTimeInterval(Double(index)),
                        text: (index == 0 ? "lot-raté " : "lot-neutre ") + String(repeating: "soupe ", count: 130))
        }
        #expect(TopicAnalyzer.batches(sources).count == 2)
        let result = try await TopicAnalyzer.run(sources: sources, speech: speech(), portrait: false, stats: "",
            transport: { request in
                let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let messages = object["messages"] as! [[String: Any]]
                let user = messages.last!["content"] as! String
                return try Self.response(user.contains("lot-raté") ? "Texte non JSON" : #"{"topics":[]}"#, request: request)
            }, progress: { _, _ in })
        let unread = result.analysis.newSources(in: sources)
        #expect(unread.count == TopicAnalyzer.batches(sources)[0].count)
        #expect(unread.first?.id == "fiction-0")
        #expect(result.analysis.dictationCount == sources.count - unread.count)
        let events = TopicTestEvents()
        let update = try await TopicAnalyzer.run(sources: sources, speech: speech(), portrait: false, stats: "", previous: result.analysis,
            transport: { request in try Self.response(#"{"topics":[]}"#, request: request) },
            onUsage: { await events.append($0) }, progress: { _, _ in })
        #expect(await events.values.count == 1)
        #expect(update.analysis.dictationCount == 60)
        #expect(update.analysis.newSources(in: sources).isEmpty)
        #expect(update.analysis.costUSD! > result.analysis.costUSD!)
    }

    @Test func processedIDsHandleEqualDatesAndSurviveCodingAndPruning() throws {
        let date = Date()
        let original = TopicAnalysis(topics: [], analyzedAt: date, dictationCount: 2, newestDictation: date,
                                     service: "fixture", costUSD: 0, processedDictationIDs: ["a", "b"])
        let analysis = try JSONDecoder().decode(TopicAnalysis.self, from: JSONEncoder().encode(original)).pruned(keeping: ["a", "new"])
        let sources = [TopicSource(id: "a", date: date, text: "Soupe"), TopicSource(id: "new", date: date, text: "Pain")]
        #expect(analysis.dictationCount == 1)
        #expect(analysis.newSources(in: sources).map(\.id) == ["new"])
        let legacy = TopicAnalysis(topics: [], analyzedAt: date, dictationCount: 1, newestDictation: date, service: "fixture", costUSD: 0)
        let data = try JSONEncoder().encode(legacy)
        #expect(try JSONDecoder().decode(TopicAnalysis.self, from: data).processedDictationIDs == nil)
    }
}

private actor TopicTestEvents {
    private(set) var values: [UsageEvent] = []
    func append(_ event: UsageEvent) { values.append(event) }
}
