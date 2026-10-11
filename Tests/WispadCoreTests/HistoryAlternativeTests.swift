import Foundation
import SQLite3
import Testing
@testable import WispadCore

struct HistoryAlternativeTests {
    @Test func theOtherListeningIsKeptWithTheDictation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-alt-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try HistoryStore(path: path)
        try store.insert(DictationRecord(finalText: "Et si tu commences ?", rawText: "Et si tu commences ?", durationSeconds: 2,
                                         wordCount: 4, provider: "xai", model: "fixture", insertionStatus: "inserted",
                                         alternativeText: "Et si je commence."))
        try store.insert(DictationRecord(finalText: "Bonjour.", rawText: "Bonjour.", durationSeconds: 1, wordCount: 1,
                                         provider: "xai", model: "fixture", insertionStatus: "inserted"))
        let records = try store.dictations()
        #expect(records.map(\.alternativeText).sorted { ($0 ?? "") < ($1 ?? "") } == [nil, "Et si je commence."])
    }

    @Test func anOlderDatabaseGainsTheColumn() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-alt-old-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let old = """
        CREATE TABLE dictations (id TEXT PRIMARY KEY, created_at REAL NOT NULL, final_text TEXT NOT NULL, raw_text TEXT NOT NULL,
        duration_seconds REAL NOT NULL, word_count INTEGER NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, target_app TEXT,
        target_bundle TEXT, usage_category TEXT, insertion_status TEXT NOT NULL, audio_path TEXT, audio_expires_at REAL);
        INSERT INTO dictations VALUES ('A', 1, 'Texte.', 'Texte.', 1, 1, 'xai', 'fixture', NULL, NULL, NULL, 'inserted', NULL, NULL);
        """
        #expect(sqlite3_exec(db, old, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = try HistoryStore(path: path)
        let records = try store.dictations()
        #expect(records.count == 1)
        #expect(records.first?.finalText == "Texte.")
        #expect(records.first?.alternativeText == nil)
    }
}
