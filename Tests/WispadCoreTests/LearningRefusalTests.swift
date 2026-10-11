import Foundation
import SQLite3
import Testing
@testable import WispadCore

struct LearningRefusalTests {
    @Test func refusalSurvivesReopenAndDoesNotDuplicate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-refusals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        try execute(
            """
            CREATE TABLE dictionary (
                id TEXT PRIMARY KEY,
                term TEXT NOT NULL UNIQUE COLLATE NOCASE,
                created_at REAL NOT NULL
            );
            INSERT INTO dictionary VALUES ('known', 'OpenAI', 1700000000);
            CREATE TABLE dictations (
                id TEXT PRIMARY KEY, created_at REAL NOT NULL, final_text TEXT NOT NULL,
                raw_text TEXT NOT NULL, duration_seconds REAL NOT NULL, word_count INTEGER NOT NULL,
                provider TEXT NOT NULL, model TEXT NOT NULL, target_app TEXT, target_bundle TEXT,
                usage_category TEXT, insertion_status TEXT NOT NULL, audio_path TEXT, audio_expires_at REAL
            );
            INSERT INTO dictations (
                id, created_at, final_text, raw_text, duration_seconds, word_count,
                provider, model, insertion_status
            ) VALUES ('old', 1700000000, 'Texte de test.', 'Texte de test.', 1, 3, 'xai', 'm', 'inserted');
            """,
            at: path
        )

        var store: HistoryStore? = try HistoryStore(path: path)
        #expect(try store?.dictionary().map(\.term) == ["OpenAI"])
        #expect(try store?.dictations().count == 1)
        try store?.rememberRefusal("Seedance")
        try store?.rememberRefusal("seedance")
        #expect(try store?.refusedTerms() == ["Seedance"])
        #expect(try store?.hasRefused("SEEDANCE") == true)
        store = nil

        let reopened = try HistoryStore(path: path)
        #expect(try reopened.hasRefused("seedance"))
        #expect(try reopened.refusedTerms() == ["Seedance"])
        #expect(try reopened.dictionary().map(\.term) == ["OpenAI"])
        #expect(try reopened.dictations().count == 1)
        _ = try HistoryStore(path: path)
        #expect(try reopened.refusedTerms() == ["Seedance"])
    }

    private func execute(_ sql: String, at path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw StoreError.message("Création de la base de test impossible")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.message(String(cString: sqlite3_errmsg(database)))
        }
    }
}
