import Foundation
import SQLite3
import Testing
@testable import WispadCore

/// Mot entendu, source et nouvelle écriture des entrées du dictionnaire, sur des bases inventées.
struct DictionaryStoreTests {
    private func withStore<T>(_ body: (String) throws -> T) throws -> T {
        try HistoryStoreFixture.withDatabase(body)
    }

    @Test func heardAndSourceSurviveReopen() throws {
        try withStore { path in
            let judge = DictionaryJudge(kind: .jev, provider: "TypeSafe", model: "modele-fictif")
            var store: HistoryStore? = try HistoryStore(path: path)
            try store?.addTerm("Sentry", origin: .learned(judge), heard: " sentri ", source: .repeatedFix)
            try store?.addTerm("Resend", origin: .user, heard: "", source: .suggestion)
            try store?.addTerm("Figma", origin: .user)
            store = nil
            let entries = Dictionary(uniqueKeysWithValues: try HistoryStore(path: path).dictionary().map { ($0.term, $0) })
            #expect(entries["Sentry"]?.heard == "sentri")
            #expect(entries["Sentry"]?.source == .repeatedFix)
            #expect(entries["Sentry"]?.origin == .learned(judge))
            #expect(entries["Resend"]?.heard == nil)
            #expect(entries["Resend"]?.source == .suggestion)
            #expect(entries["Figma"]?.heard == nil)
            #expect(entries["Figma"]?.source == nil)
        }
    }

    /// Base d'une version précédente : les colonnes s'ajoutent, les mots restent tels quels, sans source inventée.
    @Test func olderBasesGainTheColumnsWithoutChangingWords() throws {
        try withStore { path in
            var db: OpaquePointer?
            #expect(sqlite3_open(path, &db) == SQLITE_OK)
            let sql = """
            CREATE TABLE dictionary (
                id TEXT PRIMARY KEY, term TEXT NOT NULL UNIQUE COLLATE NOCASE, created_at REAL NOT NULL,
                origin TEXT, judge_provider TEXT, judge_model TEXT, confirmed_at REAL
            );
            INSERT INTO dictionary (id, term, created_at, origin) VALUES ('old', 'Seedance', 1700000000, 'user');
            INSERT INTO dictionary (id, term, created_at, origin, judge_provider, judge_model) VALUES ('odd', 'Grafana', 1700000001, 'model', 'DeepSeek', 'modele-fictif');
            """
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
            let store = try HistoryStore(path: path)
            let entries = try store.dictionary()
            #expect(entries.map(\.term).sorted() == ["Grafana", "Seedance"])
            #expect(entries.allSatisfy { $0.heard == nil && $0.source == nil })
            try store.addTerm("Sentry", origin: .user, heard: "sentri", source: .suggestion)
            #expect(try store.dictionary().first { $0.term == "Sentry" }?.heard == "sentri")
        }
    }

    @Test func renameKeepsTheEntryAndRefusesATakenTerm() throws {
        try withStore { path in
            let store = try HistoryStore(path: path)
            try store.addTerm("codex", origin: .user)
            try store.addTerm("Figma", origin: .unknown)
            let codex = try #require(try store.dictionary().first { $0.term == "codex" })
            #expect(try store.renameTerm(id: codex.id, to: " Codex "))
            let renamed = try #require(try store.dictionary().first { $0.id == codex.id })
            #expect(renamed.term == "Codex")
            #expect(renamed.origin == .user)
            #expect(renamed.createdAt == codex.createdAt)
            // Un terme déjà pris par une autre entrée, à la casse près, ou vide : rien ne change.
            #expect(try !store.renameTerm(id: codex.id, to: "FIGMA"))
            #expect(try !store.renameTerm(id: codex.id, to: "   "))
            #expect(try store.dictionary().map(\.term).sorted() == ["Codex", "Figma"])
        }
    }
}

