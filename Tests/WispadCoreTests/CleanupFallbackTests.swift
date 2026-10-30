import Foundation
import Testing
@testable import WispadCore

private actor CleanupHTTPStub {
    enum Step: Sendable {
        case reply(status: Int = 200, tokens: Bool = true)
        case payload(String, status: Int = 200)
        case failure
        case suspended(AsyncResult<Void>)
    }

    private var steps: [Step]
    private let content: String
    private(set) var hosts: [String] = []

    init(_ steps: [Step], content: String = "Phrase de test.") {
        self.steps = steps
        self.content = content
    }

    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        hosts.append(request.url?.host ?? "")
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case .failure:
            throw URLError(.timedOut)
        case .suspended(let started):
            started.resolve(.success(()))
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw URLError(.timedOut)
        case .payload(let body, let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        case .reply(let status, let tokens):
            var object: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
            if tokens { object["usage"] = ["prompt_tokens": 10, "completion_tokens": 5] }
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }
}

struct CleanupFallbackTests {
    private static func speech(deepSeek: Bool = true, openAI: Bool = true, paused: Bool = false, jev: Bool = false) -> SpeechRequest {
        SpeechRequest(provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture-xai",
                      language: .french, keyterms: [], prompt: "", cleanupKey: deepSeek ? "fixture-ds" : nil,
                      fallbackKey: openAI ? "fixture-oa" : nil, cleanupPrimaryDown: paused, judgeKey: jev ? "fixture-jev" : nil)
    }

    private static func clean(_ stub: CleanupHTTPStub, speech: SpeechRequest = speech(), enabled: Bool = true) async -> CleanupOutcome {
        await TextCleaner.clean(transcript: "Phrase de test.", request: CorrectionRequest(transcript: "Phrase de test."),
                                speech: speech, enabled: enabled, transport: { try await stub.request($0) })
    }

    private static let candidates = [CorrectionLearner.Candidate(heard: "Openaille", corrected: "OpenAI")]

    private static func judge(_ stub: CleanupHTTPStub, speech: SpeechRequest = speech(), scores: [Double]? = nil) async -> TermJudgement {
        await TermJudge.judge(candidates, dictated: "Openaille", speech: speech, scoreRequest: { _, _, _ in
            (scores, UsageEvent(api: .typesafeJudge, model: "fixture-jev", costUSD: 0, succeeded: scores != nil))
        }, transport: { try await stub.request($0) })
    }

    @Test func primarySuccessIsNotFallback() async throws {
        let stub = CleanupHTTPStub([.reply()])
        let result = await Self.clean(stub)
        let usage = try #require(result.usage)
        #expect(usage.api == .deepSeekCleanup)
        #expect(usage.succeeded)
        #expect(usage.fallback == nil)
        #expect(result.failedUsages.isEmpty)
        #expect(await stub.hosts == ["api.deepseek.com"])
    }

    @Test func successfulReplyWithoutTokensHasUnknownCost() async throws {
        let stub = CleanupHTTPStub([.reply(tokens: false)])
        let usage = try #require(await Self.clean(stub).usage)
        #expect(usage.succeeded)
        #expect(usage.costUSD == nil)
        #expect(usage.fallback == nil)
    }

    @Test func failedPrimaryThenSuccessfulRelayTracksActualTransition() async throws {
        let stub = CleanupHTTPStub([.failure, .reply()])
        let result = await Self.clean(stub)
        let usage = try #require(result.usage)
        #expect(result.failedUsages.map(\.api) == [.deepSeekCleanup])
        #expect(result.failedUsages[0].fallback == nil)
        #expect(usage.api == .openAICleanup)
        #expect(usage.succeeded)
        #expect(usage.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed))
        #expect(result.fallback == "OpenAI")
    }

    @Test func unsuccessfulRelayStillCountsAttempt() async throws {
        let stub = CleanupHTTPStub([.failure, .failure])
        let result = await Self.clean(stub)
        let usage = try #require(result.usage)
        #expect(!usage.succeeded)
        #expect(usage.costUSD == nil)
        #expect(result.failedUsages.allSatisfy { $0.costUSD == nil })
        #expect(usage.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed))
        #expect(result.fallback == nil)
        #expect(result.text == "Phrase de test.")
    }

    @Test func pausedPrimaryRoutesDirectlyToRelay() async throws {
        let stub = CleanupHTTPStub([.reply()])
        let usage = try #require(await Self.clean(stub, speech: Self.speech(paused: true)).usage)
        #expect(usage.api == .openAICleanup)
        #expect(usage.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .servicePaused))
        #expect(await stub.hosts == ["api.openai.com"])
    }

    @Test func pausedRelayFailureThenOriginalServiceTracksBothTransitions() async throws {
        let stub = CleanupHTTPStub([.failure, .reply()])
        let result = await Self.clean(stub, speech: Self.speech(paused: true))
        #expect(result.failedUsages.first?.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .servicePaused))
        #expect(result.usage?.api == .deepSeekCleanup)
        #expect(result.usage?.fallback == APIFallback(fromAPI: .openAICleanup, stage: .correction, reason: .requestFailed))
    }

    @Test func missingPrimaryKeyDoesNotInventFallback() async {
        let stub = CleanupHTTPStub([.reply()])
        let result = await Self.clean(stub, speech: Self.speech(deepSeek: false, paused: true))
        #expect(result.usage?.api == .openAICleanup)
        #expect(result.usage?.fallback == nil)
        #expect(result.fallback == nil)
    }

    @Test func xaiRelayIsTrackedWhenOpenAIKeyIsAbsent() async {
        let stub = CleanupHTTPStub([.failure, .reply()])
        let result = await Self.clean(stub, speech: Self.speech(openAI: false))
        #expect(result.usage?.api == .xaiCleanup)
        #expect(result.usage?.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed))
    }

    @Test func sameProviderParameterRetryDoesNotCountFallback() async {
        let stub = CleanupHTTPStub([.reply(status: 400, tokens: false), .reply()])
        let result = await Self.clean(stub, speech: Self.speech(deepSeek: false, openAI: false))
        #expect(result.usage?.succeeded == true)
        #expect(result.usage?.fallback == nil)
        #expect(result.failedUsages.count == 1)
        #expect(result.failedUsages[0].api == .xaiCleanup)
        #expect(!result.failedUsages[0].succeeded)
        #expect(result.failedUsages[0].fallback == nil)
        #expect(result.failedUsages[0].costUSD == nil)
        #expect(result.failedUsages[0].id != result.usage?.id)
        #expect(await stub.hosts == ["api.x.ai", "api.x.ai"])
    }

    @Test func disabledCleanupMakesNoCalls() async {
        let stub = CleanupHTTPStub([])
        let result = await Self.clean(stub, enabled: false)
        #expect(result.usage == nil)
        #expect(await stub.hosts.isEmpty)
    }

    @Test func cancellationBeforeCleanupMakesNoCalls() async throws {
        let stub = CleanupHTTPStub([])
        let gate = AsyncResult<Void>()
        let task = Task {
            try await gate.value()
            return await Self.clean(stub)
        }
        task.cancel()
        gate.resolve(.success(()))
        let result = try await task.value
        #expect(result.usage == nil)
        #expect(await stub.hosts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingPrimaryDoesNotLaunchRelay() async throws {
        let started = AsyncResult<Void>()
        let stub = CleanupHTTPStub([.suspended(started), .reply()])
        let task = Task { await Self.clean(stub) }
        try await started.value()
        task.cancel()
        let result = await task.value
        #expect(result.usage?.api == .deepSeekCleanup)
        #expect(result.usage?.fallback == nil)
        #expect(result.usage?.costUSD == nil)
        // Dictée annulée : pas un échec du fournisseur.
        #expect(result.usage?.failureCause == .cancelled)
        #expect(await stub.hosts == ["api.deepseek.com"])
    }

    @Test func failedCallsKeepTheCauseReadInTheError() async {
        let outage = await Self.clean(CleanupHTTPStub([.reply(status: 503), .reply()]))
        #expect(outage.failedUsages.map(\.failureCause) == [.serverError])
        #expect(outage.usage?.failureCause == nil)
        let key = await Self.clean(CleanupHTTPStub([.reply(status: 401), .reply()]))
        #expect(key.failedUsages.map(\.failureCause) == [.keyRejected])
        let slow = await Self.clean(CleanupHTTPStub([.failure, .reply()]))
        #expect(slow.failedUsages.map(\.failureCause) == [.timeout])
    }

    /// Wispad coupe un service trop lent : l'appel coupé compte comme « pas de réponse à temps », pas comme annulé.
    @Test(.timeLimit(.minutes(1))) func wispadDeadlineCountsAsTimeout() async {
        let stub = CleanupHTTPStub([.suspended(AsyncResult<Void>()), .reply()])
        let result = await Self.clean(stub)
        #expect(result.failedUsages.map(\.failureCause) == [.timeout])
        #expect(result.usage?.api == .openAICleanup)
        #expect(result.usage?.succeeded == true)
    }

    @Test(.timeLimit(.minutes(1))) func relayStartedBeforeCancellationRemainsCounted() async throws {
        let started = AsyncResult<Void>()
        let stub = CleanupHTTPStub([.failure, .suspended(started)])
        let task = Task { await Self.clean(stub) }
        try await started.value()
        task.cancel()
        let result = await task.value
        #expect(result.usage?.api == .openAICleanup)
        #expect(result.usage?.costUSD == nil)
        #expect(result.usage?.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed))
        #expect(await stub.hosts == ["api.deepseek.com", "api.openai.com"])
    }

    @Test func dictionaryPrimaryFailureHasOwnStage() async {
        let stub = CleanupHTTPStub([.failure, .reply()], content: #"{"garder":["OpenAI"]}"#)
        let result = await Self.judge(stub)
        #expect(result.kept.map(\.term) == ["OpenAI"])
        #expect(result.usages.last?.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .dictionary, reason: .requestFailed))
    }

    @Test func dictionaryJevFailureTracksJevToFirstModel() async {
        let stub = CleanupHTTPStub([.reply()], content: #"{"garder":["OpenAI"]}"#)
        let result = await Self.judge(stub, speech: Self.speech(jev: true))
        #expect(result.usages.map(\.api) == [.typesafeJudge, .deepSeekCleanup])
        #expect(result.usages.last?.fallback == APIFallback(fromAPI: .typesafeJudge, stage: .dictionary, reason: .requestFailed))
    }

    @Test func dictionaryEachRelayTracksImmediatelyPreviousAPI() async {
        let stub = CleanupHTTPStub([.failure, .reply()], content: #"{"garder":["OpenAI"]}"#)
        let result = await Self.judge(stub, speech: Self.speech(jev: true))
        #expect(result.usages.map(\.api) == [.typesafeJudge, .deepSeekCleanup, .openAICleanup])
        #expect(result.usages[1].fallback == APIFallback(fromAPI: .typesafeJudge, stage: .dictionary, reason: .requestFailed))
        #expect(result.usages[2].fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .dictionary, reason: .requestFailed))
    }

    @Test func dictionarySecondOpinionIsNotJevFallback() async {
        let stub = CleanupHTTPStub([.reply(tokens: false)], content: #"{"garder":["OpenAI"]}"#)
        let result = await Self.judge(stub, speech: Self.speech(jev: true), scores: [0.6])
        #expect(result.kept.map(\.term) == ["OpenAI"])
        #expect(result.usages.map(\.api) == [.typesafeJudge, .deepSeekCleanup])
        #expect(result.usages.allSatisfy { $0.fallback == nil })
        #expect(result.usages.last?.succeeded == true)
        #expect(result.usages.last?.costUSD == nil)
    }

    @Test func dictionaryPausedServiceStillCountsDuringSecondOpinion() async {
        let stub = CleanupHTTPStub([.reply()], content: #"{"garder":["OpenAI"]}"#)
        let result = await Self.judge(stub, speech: Self.speech(paused: true, jev: true), scores: [0.6])
        #expect(result.usages.last?.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .dictionary, reason: .servicePaused))
    }

    @Test func dictionaryJevFailureTakesPrecedenceOverPausedService() async {
        let stub = CleanupHTTPStub([.reply()], content: #"{"garder":["OpenAI"]}"#)
        let result = await Self.judge(stub, speech: Self.speech(paused: true, jev: true))
        #expect(result.usages.last?.api == .openAICleanup)
        #expect(result.usages.last?.fallback == APIFallback(fromAPI: .typesafeJudge, stage: .dictionary, reason: .requestFailed))
    }

    @Test func dictionaryMissingJevIsNotFailure() async {
        let stub = CleanupHTTPStub([.reply()], content: #"{"garder":["OpenAI"]}"#)
        let result = await Self.judge(stub)
        #expect(result.usages.count == 1)
        #expect(result.usages[0].fallback == nil)
    }

    @Test func truncatedCorrectionPreservesBilledTokensBeforeFallback() async throws {
        let payload = #"{"choices":[{"message":{"content":"Phrase incomplète"},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"prompt_cache_hit_tokens":3}}"#
        let stub = CleanupHTTPStub([.payload(payload), .reply()])
        let result = await Self.clean(stub)
        let failed = try #require(result.failedUsages.first)
        #expect(result.failedUsages.count == 1)
        #expect(!failed.succeeded)
        #expect(failed.tokens == TokenUsage(input: 7, cachedInput: 3, output: 5))
        #expect(try #require(failed.costUSD) > 0)
        #expect(result.usage?.api == .openAICleanup)
        #expect(result.usage?.succeeded == true)
        #expect(await stub.hosts == ["api.deepseek.com", "api.openai.com"])
    }

    @Test func unusableCorrectionStillPreservesReturnedUsage() async throws {
        let payload = #"{"choices":[{"message":{"refusal":"fixture"}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#
        let stub = CleanupHTTPStub([.payload(payload), .reply()])
        let result = await Self.clean(stub)
        let failed = try #require(result.failedUsages.first)
        #expect(!failed.succeeded)
        #expect(failed.tokens == TokenUsage(input: 10, output: 5))
        #expect(try #require(failed.costUSD) > 0)
    }

    @Test func malformedJSONHasUnknownCost() async throws {
        let stub = CleanupHTTPStub([.payload("invalid-json"), .reply()])
        let result = await Self.clean(stub)
        let failed = try #require(result.failedUsages.first)
        #expect(!failed.succeeded)
        #expect(failed.costUSD == nil)
    }

    @Test func relayParameterRetryCountsRequestsButOnlyOneSwitch() async throws {
        let stub = CleanupHTTPStub([.failure, .reply(status: 400, tokens: false), .reply()])
        let result = await Self.clean(stub)
        let last = try #require(result.usage)
        let calls = result.failedUsages + [last]
        #expect(calls.map(\.api) == [.deepSeekCleanup, .openAICleanup, .openAICleanup])
        #expect(calls.map(\.succeeded) == [false, false, true])
        #expect(calls[0].fallback == nil)
        #expect(calls[1].fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed))
        #expect(calls[2].fallback == calls[1].fallback)
        #expect(calls[2].retryOf == calls[1].id)
        #expect(Set(calls.map(\.id)).count == 3)
        #expect(FallbackSummary.make(events: calls, period: .all).total == 1)
        #expect(FallbackSummary.make(events: calls, period: .all).successes == 1)
        #expect(FallbackSummary.make(events: calls, period: .all).failures == 0)
        #expect(result.fallback == "OpenAI")
    }

    @Test func failedParameterRetryRetainsBothUnknownCalls() async throws {
        let stub = CleanupHTTPStub([.reply(status: 400, tokens: false), .failure])
        let result = await Self.clean(stub, speech: Self.speech(deepSeek: false, openAI: false))
        let last = try #require(result.usage)
        let calls = result.failedUsages + [last]
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { !$0.succeeded && $0.costUSD == nil && $0.fallback == nil })
        #expect(Set(calls.map(\.id)).count == 2)
    }

    @Test func dictionaryCountsBothParameterRetryRequests() async {
        let stub = CleanupHTTPStub([.reply(status: 400, tokens: false), .reply()], content: #"{"garder":["OpenAI"]}"#)
        let result = await Self.judge(stub, speech: Self.speech(deepSeek: false, openAI: false))
        #expect(result.usages.count == 2)
        #expect(result.usages.map(\.succeeded) == [false, true])
        #expect(result.usages.allSatisfy { $0.fallback == nil })
        #expect(result.kept.map(\.term) == ["OpenAI"])
    }

    @Test func dictionaryTruncationPreservesUsageWhenRelayIsUsed() async throws {
        let payload = #"{"choices":[{"message":{"content":"{"},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#
        let stub = CleanupHTTPStub([.payload(payload), .reply()], content: #"{"garder":["OpenAI"]}"#)
        let result = await Self.judge(stub)
        let failed = try #require(result.usages.first)
        #expect(!failed.succeeded)
        #expect(failed.tokens == TokenUsage(input: 10, output: 5))
        #expect(try #require(failed.costUSD) > 0)
        #expect(result.usages.last?.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .dictionary, reason: .requestFailed))
        #expect(result.kept.map(\.term) == ["OpenAI"])
    }

    @Test func healthProbeMissingTokensHasUnknownCost() async throws {
        let stub = CleanupHTTPStub([.reply(tokens: false)])
        let usage = try #require(await HealthProbe.deepSeek(key: "fixture", transport: { try await stub.request($0) }))
        #expect(usage.succeeded)
        #expect(usage.costUSD == nil)
        #expect(usage.fallback == nil)
    }

    @Test(arguments: [true, false])
    func healthProbeTruncationConfirmsRecoveryAndPreservesCostCertainty(hasUsage: Bool) async throws {
        let payload = hasUsage
            ? #"{"choices":[{"message":{"content":"O"},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":1}}"#
            : #"{"choices":[{"message":{"content":"O"},"finish_reason":"length"}]}"#
        let stub = CleanupHTTPStub([.payload(payload)])
        let usage = try #require(await HealthProbe.deepSeek(key: "fixture", transport: { try await stub.request($0) }))
        #expect(usage.succeeded)
        if hasUsage {
            #expect(usage.tokens == TokenUsage(input: 10, output: 1))
            #expect(try #require(usage.costUSD) > 0)
        } else {
            #expect(usage.costUSD == nil)
        }
        #expect(await stub.hosts == ["api.deepseek.com"])
    }

    @Test func healthProbeStillRejectsHTTPErrors() async throws {
        let stub = CleanupHTTPStub([.reply(status: 503, tokens: false)])
        let usage = try #require(await HealthProbe.deepSeek(key: "fixture", transport: { try await stub.request($0) }))
        #expect(!usage.succeeded)
        #expect(usage.costUSD == nil)
        #expect(await stub.hosts == ["api.deepseek.com"])
    }

    @Test func healthProbeStillRejectsInvalidBodyAndPreservesUsage() async throws {
        let stub = CleanupHTTPStub([.payload(#"{"usage":{"prompt_tokens":10,"completion_tokens":1}}"#)])
        let usage = try #require(await HealthProbe.deepSeek(key: "fixture", transport: { try await stub.request($0) }))
        #expect(!usage.succeeded)
        #expect(usage.tokens == TokenUsage(input: 10, output: 1))
        #expect(try #require(usage.costUSD) > 0)
        #expect(await stub.hosts == ["api.deepseek.com"])
    }

    @Test func healthProbeCancelledBeforeSendCreatesNoUsage() async throws {
        let stub = CleanupHTTPStub([])
        let gate = AsyncResult<Void>()
        let task = Task {
            try await gate.value()
            return await HealthProbe.deepSeek(key: "fixture", transport: { try await stub.request($0) })
        }
        task.cancel()
        gate.resolve(.success(()))
        #expect(try await task.value == nil)
        #expect(await stub.hosts.isEmpty)
    }
}

struct SelectionTransformTests {
    private static let speech = SpeechRequest(provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture-xai",
                                              language: .french, keyterms: [], prompt: "", cleanupKey: "fixture-ds", fallbackKey: "fixture-oa")

    private static func request() -> CorrectionRequest {
        var request = CorrectionRequest(transcript: "Traduis en anglais.")
        request.commandSelection = "Bonjour à tous, merci pour hier."
        return request
    }

    @Test func aRewriteIsKeptEvenThoughItSharesNoWordWithTheCommand() async throws {
        let stub = CleanupHTTPStub([.reply()], content: "Hello everyone, thanks for yesterday.")
        let result = await TextCleaner.clean(transcript: "Traduis en anglais.", request: Self.request(), speech: Self.speech,
                                             enabled: true, transport: { try await stub.request($0) })
        #expect(result.text == "Hello everyone, thanks for yesterday.")
        #expect(result.usage?.api == .deepSeekCleanup)
    }

    @Test func noAnswerMeansNothingToPaste() async {
        let stub = CleanupHTTPStub([.failure, .failure])
        let result = await TextCleaner.clean(transcript: "Traduis en anglais.", request: Self.request(), speech: Self.speech,
                                             enabled: true, transport: { try await stub.request($0) })
        #expect(result.text.isEmpty)
        let offline = await TextCleaner.clean(transcript: "Traduis en anglais.", request: Self.request(), speech: Self.speech,
                                              enabled: false, transport: { try await stub.request($0) })
        #expect(offline.text.isEmpty)
    }
}
