import Foundation
import SQLite3
import Testing
@testable import WispadCore

@Suite struct CleanupRetryStoreTests {
    private let instant = Date(timeIntervalSince1970: 1_793_361_600)
    private let fallback = APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed)

    private func calls() -> [UsageEvent] {
        [UsageEvent(id: "first", createdAt: instant, api: .openAICleanup, model: "gpt-5.6-luna",
                    costUSD: 0.002, succeeded: false, fallback: fallback, failureCause: .refused),
         UsageEvent(id: "second", createdAt: instant.addingTimeInterval(1), api: .openAICleanup, model: "gpt-5.6-luna",
                    costUSD: 0.003, fallback: fallback, retryOf: "first")]
    }

    @Test func reopeningKeepsBothCostsAndOneSuccessfulRelay() throws {
        try withDatabase { path in
            let original = calls()
            var store: HistoryStore? = try HistoryStore(path: path)
            for call in original { try store!.insertUsage(call) }
            store = nil
            let loaded = try HistoryStore(path: path).usageEvents()
            #expect(loaded.sorted { $0.id < $1.id } == original)
            #expect(UsageSummary.make(events: loaded, period: .all).totalUSD == 0.005)
            let summary = FallbackSummary.make(events: loaded, period: .all)
            #expect(summary.total == 1)
            #expect(summary.successes == 1)
            #expect(summary.failures == 0)
            #expect(summary.recent.first?.id == "second")
            #expect(summary == FallbackSummary.make(events: Array(loaded.reversed()), period: .all))
        }
    }

    @Test func oldRowsMigrateWithoutInventingCompatibilityLinks() throws {
        try withDatabase { path in
            var db: OpaquePointer?
            #expect(sqlite3_open(path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            let sql = """
                CREATE TABLE api_usage (
                    id TEXT PRIMARY KEY, created_at REAL NOT NULL, api TEXT NOT NULL, model TEXT NOT NULL,
                    audio_seconds REAL NOT NULL, input_tokens INTEGER NOT NULL, cached_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL, cost_usd REAL, latency_ms INTEGER NOT NULL, succeeded INTEGER NOT NULL
                );
                INSERT INTO api_usage VALUES ('ancien', 1793361600, 'openai.cleanup', 'gpt-5.6-luna',
                    0, 100, 0, 5, 0.003, 10, 1);
                """
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
            for _ in 0..<2 {
                let loaded = try HistoryStore(path: path).usageEvents()
                #expect(loaded.count == 1)
                #expect(loaded.first?.retryOf == nil)
                #expect(loaded.first?.costUSD == 0.003)
                #expect(loaded.first?.fallback == nil)
            }
        }
    }

    @Test func traceRoundTripKeepsLinkAndOldPayloadStillDecodes() throws {
        let call = DictationAPICall(calls()[1])
        let encoded = try JSONEncoder().encode(call)
        #expect(try JSONDecoder().decode(DictationAPICall.self, from: encoded) == call)
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "retryOf")
        let oldCall = try JSONDecoder().decode(DictationAPICall.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(oldCall.retryOf == nil)
        #expect(oldCall.fallback == call.fallback)
    }

    @Test func retryOutcomeWinsWithoutMergingUnrelatedRequests() {
        var chain = calls()
        chain[1].succeeded = false
        chain.append(UsageEvent(id: "third", createdAt: instant.addingTimeInterval(2), api: .openAICleanup,
                               model: "gpt-5.6-luna", costUSD: 0.004, fallback: fallback, retryOf: "second"))
        let summary = FallbackSummary.make(events: chain, period: .all)
        #expect(summary.total == 1)
        #expect(summary.successes == 1)
        var independent = chain.last!
        independent.id = "independent"
        independent.retryOf = nil
        #expect(FallbackSummary.make(events: chain + [independent], period: .all).total == 2)
        independent.retryOf = "independent"
        #expect(FallbackSummary.make(events: [independent], period: .all).total == 1)
    }

    @Test func retryWithMissingOrUnrelatedParentStillCounts() {
        let original = calls()
        #expect(FallbackSummary.make(events: [original[1]], period: .all).successes == 1)
        var unrelated = original[0]
        unrelated.model = "gpt-4o"
        #expect(FallbackSummary.make(events: [unrelated, original[1]], period: .all).total == 2)
        var cycle = original
        cycle[0].retryOf = "second"
        cycle[1].succeeded = false
        #expect(FallbackSummary.make(events: cycle, period: .all).total == 2)
    }

    private func withDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("history.sqlite").path)
    }
}
