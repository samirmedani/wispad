import Foundation
import SQLite3
import Testing
@testable import WispadCore

/// Traces et appels écrits avant le retrait d'une fonction : ceux qui citent une valeur disparue sont oubliés
/// une fois, les autres restent lisibles.
struct RetiredValuesMigrationTests {
    private func legacyStore(_ payloads: [(id: String, json: String)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-retired-\(UUID().uuidString).sqlite")
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let schema = """
            CREATE TABLE dictation_traces (
                id TEXT PRIMARY KEY, dictation_id TEXT, created_at REAL NOT NULL, payload TEXT NOT NULL
            );
            """
        #expect(sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, payload) in payloads.enumerated() {
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(connection, "INSERT INTO dictation_traces VALUES (?, NULL, ?, ?);", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, payload.id, -1, transient)
            sqlite3_bind_double(statement, 2, 1_790_000_000 + Double(index))
            sqlite3_bind_text(statement, 3, payload.json, -1, transient)
            #expect(sqlite3_step(statement) == SQLITE_DONE)
        }
        return url
    }

    @Test func tracesOfTheRetiredLocalModelAreForgottenAndOthersStayReadable() throws {
        let kept = DictationTrace(id: "kept", createdAt: Date(timeIntervalSince1970: 1_790_000_000), origin: .hold, outcome: .inserted)
        let keptJSON = String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)
        let retired = DictationTrace(id: "retired", createdAt: Date(timeIntervalSince1970: 1_790_000_001), origin: .toggle, outcome: .keyUnavailable)
        let retiredJSON = String(decoding: try JSONEncoder().encode(retired), as: UTF8.self)
            .replacingOccurrences(of: "\"keyUnavailable\"", with: "\"modelUnavailable\"")
        let url = try legacyStore([("kept", keptJSON), ("retired", retiredJSON)])
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try HistoryStore(path: url.path)
        #expect(try store.recentTraces() == [kept])
        #expect(try store.trace(id: "retired") == nil)
    }

    @Test func callsOfTheRetiredCorrectionServerAreForgotten() throws {
        let url = try legacyStore([])
        defer { try? FileManager.default.removeItem(at: url) }
        // Base d'avant le retrait : un appel au serveur personnalisé, sa trace, et un appel DeepSeek à garder.
        do {
            let store = try HistoryStore(path: url.path)
            try store.insertUsage(UsageEvent(id: "kept", api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.001))
            let trace = DictationTrace(id: "with-custom", createdAt: Date(timeIntervalSince1970: 1_790_000_002), origin: .hold,
                                       calls: [DictationAPICall(UsageEvent(id: "call", api: .deepSeekCleanup, model: "m", costUSD: nil))])
            try store.saveTrace(trace)
        }
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        let legacy = """
            INSERT INTO api_usage (id, created_at, api, model, audio_seconds, input_tokens, cached_tokens, output_tokens,
                cost_usd, latency_ms, succeeded) VALUES ('custom', 1790000000, 'custom.cleanup', 'modele-fictif', 0, 10, 0, 5, 0, 300, 1);
            UPDATE dictation_traces SET payload = replace(payload, '"deepseek.cleanup"', '"custom.cleanup"') WHERE id = 'with-custom';
            DELETE FROM app_metadata WHERE key = 'retired_values_v1';
            """
        #expect(sqlite3_exec(connection, legacy, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)

        let store = try HistoryStore(path: url.path)
        #expect(try store.usageEvents().map(\.id) == ["kept"])
        #expect(try store.recentTraces().isEmpty)
        var check: OpaquePointer?
        #expect(sqlite3_open(url.path, &check) == SQLITE_OK)
        defer { sqlite3_close(check) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(check, "SELECT COUNT(*) FROM api_usage WHERE api = 'custom.cleanup';", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 0)
    }
}
