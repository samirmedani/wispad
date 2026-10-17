import Foundation
import Testing
@testable import WispadCore

/// D'où vient un échec : lu dans l'erreur reçue, puis départagé avec les appels voisins pour les délais.
struct FailureStatsTests {
    private let now = Date(timeIntervalSince1970: 1_791_028_800)

    private func failed(_ api: UsageAPI, _ cause: APIFailureCause?, at offset: TimeInterval = 0) -> UsageEvent {
        UsageEvent(createdAt: now.addingTimeInterval(offset), api: api, model: "fixture", costUSD: nil,
                   succeeded: false, failureCause: cause)
    }

    private func success(_ api: UsageAPI, at offset: TimeInterval = 0, fallback: APIFallback? = nil) -> UsageEvent {
        UsageEvent(createdAt: now.addingTimeInterval(offset), api: api, model: "fixture", costUSD: 0, fallback: fallback)
    }

    @Test func httpStatusesNameTheCause() {
        #expect(APIFailureCause.status(401) == .keyRejected)
        #expect(APIFailureCause.status(402) == .keyRejected)
        #expect(APIFailureCause.status(403) == .keyRejected)
        #expect(APIFailureCause.status(408) == .timeout)
        #expect(APIFailureCause.status(429) == .rateLimited)
        #expect(APIFailureCause.status(503) == .serverError)
        #expect(APIFailureCause.status(404) == .refused)
    }

    @Test func networkErrorsOfThisMacAreTheConnection() {
        #expect(APIFailureCause.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(APIFailureCause.classify(URLError(.networkConnectionLost)) == .offline)
        #expect(APIFailureCause.classify(URLError(.cannotFindHost)) == .offline)
        #expect(APIFailureCause.classify(URLError(.timedOut)) == .timeout)
        #expect(APIFailureCause.classify(URLError(.cannotConnectToHost)) == .serverError)
        #expect(APIFailureCause.classify(URLError(.cancelled)) == .cancelled)
        #expect(APIFailureCause.classify(CancellationError()) == .cancelled)
        #expect(APIFailureCause.classify(SpeechError.failure(.rateLimited, "x")) == .rateLimited)
        #expect(APIFailureCause.classify(SpeechError.message("x")) == .badResponse)
        #expect(SpeechError.failure(.timeout, "Correction trop lente").localizedDescription == "Correction trop lente")
    }

    @Test func breakdownSeparatesConnectionProviderAndKeys() {
        let events = [
            failed(.deepSeekCleanup, .timeout),
            success(.openAICleanup, at: 3, fallback: APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed)),
            failed(.deepSeekCleanup, .serverError, at: -600),
            failed(.xaiStreaming, .offline, at: -1_200),
            failed(.openAICleanup, .keyRejected, at: -1_800),
            // Délai sans aucun appel réussi dans la minute : la connexion a pu être en cause.
            failed(.deepSeekCleanup, .timeout, at: -7_200),
            // Annulé par Wispad, ou appel d'avant le suivi : hors du décompte.
            failed(.xaiStreaming, .cancelled, at: -60),
            failed(.xaiFile, nil, at: -60),
            success(.openAICleanup, at: -3_000, fallback: APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .servicePaused)),
        ]
        let breakdown = FailureBreakdown.make(events: events, period: .all, now: now)
        #expect(breakdown.failures == 5)
        #expect(breakdown.count(.provider) == 2)
        #expect(breakdown.count(.connection) == 1)
        #expect(breakdown.count(.account) == 1)
        #expect(breakdown.count(.undetermined) == 1)
        let deepSeek = breakdown.providers.first { $0.name == "DeepSeek" }
        #expect(deepSeek?.name == "DeepSeek")
        #expect(deepSeek?.causes == [.timeout: 2, .serverError: 1])
        #expect(deepSeek?.undeterminedTimeouts == 1)
        #expect(deepSeek?.paused == 1)
        #expect(breakdown.providers.map(\.name).sorted() == ["DeepSeek", "OpenAI", "xAI"])
    }

    @Test func periodLimitsTheBreakdown() {
        let calendar = Calendar(identifier: .gregorian)
        let events = [failed(.deepSeekCleanup, .serverError), failed(.deepSeekCleanup, .serverError, at: -40 * 86_400)]
        #expect(FailureBreakdown.make(events: events, period: .days7, now: now, calendar: calendar).failures == 1)
        #expect(FailureBreakdown.make(events: events, period: .all, now: now, calendar: calendar).failures == 2)
    }

    @Test func eachFallbackShowsWhyItsPrimaryFailed() {
        let relay = APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed)
        let events = [
            failed(.deepSeekCleanup, .rateLimited, at: -2.5),
            success(.openAICleanup, fallback: relay),
            // Échec trop ancien pour être celui que ce secours remplace.
            failed(.xaiFile, .offline, at: -600),
            success(.openAIFile, at: -300, fallback: APIFallback(fromAPI: .xaiFile, stage: .transcription, reason: .requestFailed)),
        ]
        let recent = FallbackSummary.make(events: events, period: .all, now: now).recent
        #expect(recent.map(\.cause) == [.rateLimited, nil])
    }

    @Test func storeKeepsTheCauseAndReadsOlderRowsWithout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-causes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(path: directory.appendingPathComponent("test.sqlite").path)
        try store.insertUsage(failed(.deepSeekCleanup, .serverError))
        try store.insertUsage(failed(.xaiFile, nil, at: -10))
        try store.insertUsage(success(.openAICleanup, at: -20))
        let stored = try store.usageEvents()
        #expect(stored.map(\.failureCause) == [.serverError, nil, nil])
    }
}
