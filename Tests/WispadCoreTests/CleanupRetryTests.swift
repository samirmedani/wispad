import Foundation
import Testing
@testable import WispadCore

private actor CleanupRetryStub {
    private let statuses: [Int]
    private(set) var bodies: [Data] = []
    private(set) var timeouts: [TimeInterval] = []

    init(_ statuses: [Int]) { self.statuses = statuses }

    func request(_ request: URLRequest) throws -> (Data, URLResponse) {
        let index = bodies.count
        bodies.append(request.httpBody ?? Data())
        timeouts.append(request.timeoutInterval)
        guard statuses.indices.contains(index) else { throw URLError(.badServerResponse) }
        let object: [String: Any] = [
            "choices": [["message": ["content": "La boîte est prête."], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 5]
        ]
        return (try JSONSerialization.data(withJSONObject: object),
                HTTPURLResponse(url: request.url!, statusCode: statuses[index], httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct CleanupRetryTests {
    private func route(_ api: UsageAPI, _ model: String) -> TextCleaner.Route {
        TextCleaner.Route(api: api, model: model, url: URL(string: "https://example.invalid/completions")!,
                          key: "fixture-only", provider: api.provider, isFallback: true)
    }

    @Test(arguments: [
        (UsageAPI.deepSeekCleanup, CleanupModel.deepSeek),
        (.localCleanup, "modele-fictif"),
        (.openAICleanup, "gpt-4o"),
        (.xaiCleanup, "grok-4.7-non-reasoning")
    ])
    func rejectedRequestWithoutRemovableParameterIsNotSentAgain(api: UsageAPI, model: String) async throws {
        let stub = CleanupRetryStub([400, 200])
        let log = TextCleaner.RequestLog()
        do {
            _ = try await TextCleaner.send(system: "Corrige la phrase fictive.", user: "La boîte est prête.",
                route: route(api, model), maxTokens: 80, includeReasoning: true,
                transport: { try await stub.request($0) }, requests: log)
            Issue.record("La première réponse HTTP 400 doit être rendue à l'appelant.")
        } catch {}
        #expect(await stub.bodies.count == 1)
        #expect(log.events.count == 1)
        #expect(log.events.first?.succeeded == false)
        #expect(log.events.first?.failureCause == .refused)
        // Des compteurs rendus même sur un refus ne disparaissent pas.
        #expect(log.events.first?.tokens == TokenUsage(input: 100, output: 5))
    }

    @Test(arguments: [(UsageAPI.openAICleanup, "gpt-5.6-luna"), (.xaiCleanup, "grok-4.7"), (.openAICleanup, "o4-mini")])
    func compatibilityRetryChangesBodyAndKeepsBothRelayUsages(api: UsageAPI, model: String) async throws {
        let stub = CleanupRetryStub([400, 200])
        let log = TextCleaner.RequestLog()
        let fallback = APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed)
        _ = try await TextCleaner.send(system: "Corrige la phrase fictive.", user: "La boîte est prête.",
            route: route(api, model), maxTokens: 80, includeReasoning: true,
            transport: { try await stub.request($0) }, requests: log, fallback: fallback, requestTimeout: 17)
        let bodies = await stub.bodies
        #expect(bodies.count == 2)
        let first = try #require(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        let second = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        #expect(first["reasoning_effort"] as? String == TextModelCatalog.reasoningEffort(api: api, model: model))
        #expect(second["reasoning_effort"] == nil)
        var withoutEffort = first
        withoutEffort.removeValue(forKey: "reasoning_effort")
        #expect(NSDictionary(dictionary: withoutEffort) == NSDictionary(dictionary: second))
        #expect(await stub.timeouts == [17, 17])
        #expect(log.events.map(\.succeeded) == [false, true])
        #expect(log.events.map(\.fallback) == [fallback, fallback])
        #expect(log.events[0].retryOf == nil)
        #expect(log.events[1].retryOf == log.events[0].id)
        #expect(log.events.allSatisfy { $0.tokens == TokenUsage(input: 100, output: 5) && $0.costUSD != nil })
        #expect(Set(log.events.map(\.id)).count == 2)
    }

    @Test func secondParameterRejectionIsNotRetriedAgain() async {
        let stub = CleanupRetryStub([400, 400, 200])
        let log = TextCleaner.RequestLog()
        let fallback = APIFallback(fromAPI: .deepSeekCleanup, stage: .dictionary, reason: .servicePaused)
        do {
            _ = try await TextCleaner.send(system: "Phrase fictive.", user: "La boîte est prête.",
                route: route(.openAICleanup, "gpt-5.6-luna"), maxTokens: 80, includeReasoning: true,
                transport: { try await stub.request($0) }, requests: log, fallback: fallback)
            Issue.record("Le second refus doit arrêter les essais de compatibilité.")
        } catch {}
        #expect(await stub.bodies.count == 2)
        #expect(log.events.map(\.succeeded) == [false, false])
        #expect(log.events.map(\.fallback) == [fallback, fallback])
        #expect(log.events[1].retryOf == log.events[0].id)
        let summary = FallbackSummary.make(events: log.events, period: .all)
        #expect(summary.total == 1)
        #expect(summary.failures == 1)
    }

    @Test func disabledReasoningFlagNeverAddsCompatibilityRetry() async {
        let stub = CleanupRetryStub([400, 200])
        let log = TextCleaner.RequestLog()
        _ = try? await TextCleaner.send(system: "Phrase fictive.", user: "La boîte est prête.",
            route: route(.openAICleanup, "gpt-5.6-luna"), maxTokens: 80, includeReasoning: false,
            transport: { try await stub.request($0) }, requests: log)
        #expect(await stub.bodies.count == 1)
        #expect(log.events.count == 1)
    }
}
