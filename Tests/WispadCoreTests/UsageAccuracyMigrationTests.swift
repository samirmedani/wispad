import Foundation
import SQLite3
import Testing
@testable import WispadCore

struct UsageAccuracyMigrationTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func legacyStore(_ events: [UsageEvent]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-usage-migration-\(UUID().uuidString).sqlite")
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let schema = """
            CREATE TABLE api_usage (
                id TEXT PRIMARY KEY, created_at REAL NOT NULL, api TEXT NOT NULL, model TEXT NOT NULL,
                audio_seconds REAL NOT NULL, input_tokens INTEGER NOT NULL, cached_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL, cost_usd REAL, latency_ms INTEGER NOT NULL, succeeded INTEGER NOT NULL
            );
            """
        #expect(sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for event in events {
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(connection, "INSERT INTO api_usage VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, event.id, -1, transient)
            sqlite3_bind_double(statement, 2, event.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, event.api.rawValue, -1, transient)
            sqlite3_bind_text(statement, 4, event.model, -1, transient)
            sqlite3_bind_double(statement, 5, event.audioSeconds)
            sqlite3_bind_int64(statement, 6, Int64(event.tokens.input))
            sqlite3_bind_int64(statement, 7, Int64(event.tokens.cachedInput))
            sqlite3_bind_int64(statement, 8, Int64(event.tokens.output))
            if let cost = event.costUSD { sqlite3_bind_double(statement, 9, cost) }
            else { sqlite3_bind_null(statement, 9) }
            sqlite3_bind_int(statement, 10, Int32(event.latencyMs))
            sqlite3_bind_int(statement, 11, event.succeeded ? 1 : 0)
            #expect(sqlite3_step(statement) == SQLITE_DONE)
        }
        return url
    }

    @Test func oldFailuresBecomeUnknownWithoutInventedTokens() throws {
        let event = UsageEvent(id: "old-failure", api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0, succeeded: false)
        let url = try legacyStore([event])
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(path: url.path)
        let loaded = try #require(store.usageEvents().first)
        #expect(loaded.id == event.id)
        #expect(loaded.costUSD == nil)
        #expect(loaded.tokens == TokenUsage())
        #expect(!loaded.succeeded)
        #expect(UsageSummary.make(events: [loaded], period: .all).hasUnpricedCalls)
    }

    @Test func missingOldTextCountersBecomeUnknownButAudioAndKnownFailureStayPriced() throws {
        let events = [
            UsageEvent(id: "missing-text", api: .typesafeJudge, model: "jev-latest", costUSD: 0),
            UsageEvent(id: "known-audio", api: .xaiFile, model: "fixture", audioSeconds: 0, costUSD: 0),
            UsageEvent(id: "known-failure", api: .openAICleanup, model: "fixture", tokens: TokenUsage(input: 10), costUSD: 0.001, succeeded: false)
        ]
        let url = try legacyStore(events)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try HistoryStore(path: url.path).usageEvents()
        #expect(loaded.first { $0.id == "missing-text" }?.costUSD == nil)
        #expect(loaded.first { $0.id == "known-audio" }?.costUSD == 0)
        #expect(loaded.first { $0.id == "known-failure" }?.costUSD == 0.001)
    }

    @Test func holidayCostIsRepairedFromExistingCounters() throws {
        let tokens = TokenUsage(input: 1_000_000, output: 1_000_000)
        let events = [
            UsageEvent(id: "holiday", createdAt: date("2026-10-01T08:00:00Z"), api: .deepSeekCleanup, model: CleanupModel.deepSeek, tokens: tokens, costUSD: 1.50),
            UsageEvent(id: "weekday", createdAt: date("2026-09-30T08:00:00Z"), api: .deepSeekCleanup, model: CleanupModel.deepSeek, tokens: tokens, costUSD: 1.50),
            UsageEvent(id: "old-rate", createdAt: date("2026-07-01T08:00:00Z"), api: .deepSeekCleanup, model: CleanupModel.deepSeek, tokens: tokens, costUSD: 0.28)
        ]
        let url = try legacyStore(events)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try HistoryStore(path: url.path).usageEvents()
        #expect(loaded.first { $0.id == "holiday" }?.costUSD == 0.75)
        #expect(loaded.first { $0.id == "weekday" }?.costUSD == 1.50)
        #expect(loaded.first { $0.id == "old-rate" }?.costUSD == 0.28)
    }

    @Test func migrationIsIdempotentAndPreservesNewExplicitZero() throws {
        let url = try legacyStore([])
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try HistoryStore(path: url.path)
            try store.insertUsage(UsageEvent(id: "explicit-zero", api: .typesafeJudge, model: "jev-latest", costUSD: 0))
            try store.insertUsage(UsageEvent(id: "new-known-failure", api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0, succeeded: false))
        }
        let reloaded = try HistoryStore(path: url.path).usageEvents()
        #expect(reloaded.count == 2)
        #expect(reloaded.allSatisfy { $0.costUSD == 0 })
    }
}
