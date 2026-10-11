import Foundation
import SQLite3
import Testing
@testable import WispadCore

/// L'ancienne date de début du suivi financier disparaît au lancement, sans toucher aux données.
struct FinancialTrackingCleanupTests {
    private let start = Date(timeIntervalSince1970: 1_791_028_800.25)

    @Test func obsoleteKeyIsRemovedAndDataIsKept() throws {
        try withDatabase { path in
            let events = (0..<3).map { index in
                UsageEvent(id: "fixture-call-\(index)", createdAt: start.addingTimeInterval(Double(index)), api: .openAIFile,
                           model: "fixture-model", audioSeconds: 3, costUSD: index == 2 ? nil : 0.01,
                           latencyMs: 450, succeeded: index != 2)
            }
            let dictation = DictationRecord(id: "fixture-dictation", createdAt: start,
                                            finalText: "Texte fictif.", rawText: "texte fictif",
                                            durationSeconds: 3, wordCount: 2, provider: "openai",
                                            model: "fixture-model", insertionStatus: "inserted")
            var fallbackDate: Date!
            do {
                let previous = try HistoryStore(path: path)
                fallbackDate = previous.fallbackTrackingStartedAt
                for event in events { try previous.insertUsage(event) }
                try previous.insert(dictation)
                try previous.addTerm("mot-fictif")
            }
            // Base d'une version précédente : la date de début du suivi financier y figure encore.
            try execute("INSERT INTO app_metadata VALUES ('financial_tracking_started_at', '\(start.timeIntervalSince1970)');", at: path)
            try execute("INSERT INTO app_metadata VALUES ('unrelated_marker', 'preserved');", at: path)
            let migrated = try HistoryStore(path: path)
            #expect(try metadata("financial_tracking_started_at", at: path).isEmpty)
            #expect(migrated.fallbackTrackingStartedAt == fallbackDate)
            #expect(try migrated.usageEvents().sorted { $0.id < $1.id } == events)
            #expect(try migrated.dictations() == [dictation])
            #expect(try migrated.dictionary().map(\.term) == ["mot-fictif"])
            #expect(try metadata("usage_accuracy_v1", at: path) == ["1"])
            #expect(try metadata("unrelated_marker", at: path) == ["preserved"])
        }
    }

    @Test(arguments: ["garbage", "0", "-1", "nan"])
    func invalidObsoleteValueIsRemovedWithoutError(_ value: String) throws {
        try withDatabase { path in
            try execute("CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);", at: path)
            try execute("INSERT INTO app_metadata VALUES ('financial_tracking_started_at', '\(value)');", at: path)
            _ = try HistoryStore(path: path)
            #expect(try metadata("financial_tracking_started_at", at: path).isEmpty)
        }
    }

    @Test func missingKeyOpensWithoutError() throws {
        try withDatabase { path in
            _ = try HistoryStore(path: path)
            _ = try HistoryStore(path: path)
            #expect(try metadata("financial_tracking_started_at", at: path).isEmpty)
        }
    }

    private func withDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-financial-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("history.sqlite").path)
    }

    private func withConnection<T>(at path: String, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var connection: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK else {
            sqlite3_close(connection)
            throw StoreError.message("Ouverture de la base fictive impossible.")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 2_000)
        return try body(connection)
    }

    private func execute(_ sql: String, at path: String) throws {
        try withConnection(at: path) { connection in
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
                throw StoreError.message("Écriture de la base fictive impossible.")
            }
        }
    }

    private func metadata(_ key: String, at path: String) throws -> [String] {
        try withConnection(at: path) { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "SELECT value FROM app_metadata WHERE key = ?;", -1, &statement, nil) == SQLITE_OK else {
                throw StoreError.message("Lecture du marqueur fictif impossible.")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            var values: [String] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                if let value = sqlite3_column_text(statement, 0) { values.append(String(cString: value)) }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw StoreError.message("Lecture du marqueur fictif incomplète.") }
            return values
        }
    }
}
