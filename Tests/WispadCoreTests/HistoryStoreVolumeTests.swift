import Foundation
import SQLite3
import Testing
@testable import WispadCore

extension HistoryStoreRobustness {
    /// 5 000 dictées (l'écran Historique en garde plus de 1 000), 15 000 appels et une trace par dictée, écrits d'un
    /// bloc par une connexion à part, puis lus par `HistoryStore` comme au lancement.
    struct HistoryStoreVolumeTests {
        private static let count = 5_000

        /// Requêtes de `HistoryStore`, à l'identique : lectures des écrans et écritures de chaque dictée. `fullRead` :
        /// la requête lit toute sa table, dans l'ordre d'un index ; les autres ne lisent que les lignes visées.
        private static let frequentQueries: [(name: String, fullRead: Bool, sql: String)] = [
            ("dictations()", true, "SELECT * FROM dictations ORDER BY created_at DESC;"),
            ("usageEvents()", true, """
                SELECT id, created_at, api, model, audio_seconds, input_tokens, cached_tokens,
                    output_tokens, cost_usd, latency_ms, succeeded,
                    fallback_from_api, fallback_stage, fallback_reason
                FROM api_usage ORDER BY created_at DESC;
                """),
            ("traces(dictationID:)", false, "SELECT payload FROM dictation_traces WHERE dictation_id = ? ORDER BY created_at DESC, id DESC;"),
            ("trace(id:)", false, "SELECT payload FROM dictation_traces WHERE id = ?;"),
            ("recentTraces(limit:)", true, "SELECT payload FROM dictation_traces ORDER BY created_at DESC, id DESC LIMIT ?;"),
            ("saveTrace (borne)", false, """
                DELETE FROM dictation_traces WHERE dictation_id IS NULL AND id NOT IN (
                    SELECT id FROM dictation_traces WHERE dictation_id IS NULL
                    ORDER BY created_at DESC, id DESC LIMIT 100
                );
                """),
            ("updateTranscript", false, "UPDATE dictations SET final_text = ?, raw_text = ?, word_count = ? WHERE id = ?;"),
            ("updateStatus", false, "UPDATE dictations SET insertion_status = ? WHERE id = ?;"),
            ("updateDelivery", false, """
                UPDATE dictations SET insertion_status = ?, target_app = COALESCE(?, target_app),
                    target_bundle = COALESCE(?, target_bundle), usage_category = COALESCE(?, usage_category)
                WHERE id = ?;
                """),
            ("updateAudio", false, "UPDATE dictations SET audio_path = ?, audio_expires_at = ? WHERE id = ?;"),
            ("deleteDictation", false, "DELETE FROM dictations WHERE id = ?;"),
            ("dictionary()", true, """
                SELECT id, term, created_at, origin, judge_provider, judge_model, confirmed_at
                FROM dictionary ORDER BY term COLLATE NOCASE;
                """),
            ("confirmLearnedTerm", false, """
                UPDATE dictionary SET confirmed_at = ?
                WHERE term = ? AND origin IN ('jev', 'model') AND confirmed_at IS NULL;
                """),
            ("deleteTerm", false, "DELETE FROM dictionary WHERE id = ?;"),
        ]

        /// Chaque requête courante passe par un index, même sur 5 000 dictées : jamais une table lue en entier ni un
        /// tri en mémoire. Supprimer une dictée, ou toutes, retrouve leurs traces par l'index (cascade de la clé
        /// étrangère).
        @Test func everyFrequentQueryUsesAnIndex() throws {
            try withLargeHistory { _, file in
                #expect(file.execute("PRAGMA foreign_keys = ON;") == SQLITE_OK)
                for query in Self.frequentQueries {
                    let plan = try #require(file.plan(query.sql))
                    #expect(Self.usesIndexes(plan, fullRead: query.fullRead), "\(query.name) : \(plan)")
                }
                // Tout supprimer parcourt les dictées (c'est le but) ; leurs traces, elles, se trouvent par l'index.
                let deleteAll = try #require(file.plan("DELETE FROM dictations;"))
                #expect(deleteAll.contains { $0.hasPrefix("SEARCH dictation_traces USING COVERING INDEX dictation_traces_dictation") })
                #expect(!deleteAll.contains { $0.hasPrefix("SCAN dictation_traces") })
            }
        }

        /// Toutes les dictées et tous les appels reviennent, de la plus récente à la plus ancienne ; supprimer une
        /// dictée retire ses traces, tout supprimer garde la consommation.
        @Test func fiveThousandDictationsComeBackCompleteAndInOrder() throws {
            try withLargeHistory { store, _ in
                let dictations = try store.dictations()
                #expect(dictations.count == Self.count)
                #expect(dictations.first?.id == "dictee-04999")
                #expect(dictations.last?.id == "dictee-00000")
                let newestFirst = zip(dictations, dictations.dropFirst()).allSatisfy { pair in pair.0.createdAt > pair.1.createdAt }
                #expect(newestFirst)
                let usage = try store.usageEvents()
                #expect(usage.count == 3 * Self.count)
                let usageNewestFirst = zip(usage, usage.dropFirst()).allSatisfy { pair in pair.0.createdAt > pair.1.createdAt }
                #expect(usageNewestFirst)
                #expect(try store.recentTraces(limit: 3).map(\.id) == ["trace-04999", "trace-04998", "trace-04997"])
                #expect(try store.traces(dictationID: "dictee-02500").map(\.id) == ["trace-02500"])

                try store.deleteDictation(id: "dictee-02500")
                #expect(try store.traces(dictationID: "dictee-02500").isEmpty)
                #expect(try store.dictations().count == Self.count - 1)
                try store.deleteAllDictations()
                #expect(try store.dictations().isEmpty)
                #expect(try store.recentTraces(limit: 10).isEmpty)
                #expect(try store.usageEvents().count == 3 * Self.count)
            }
        }

        /// Jamais de tri en mémoire (« USE TEMP B-TREE »). Une lecture complète parcourt sa table dans l'ordre d'un
        /// index ; les autres requêtes n'en parcourent aucune (SEARCH seulement). Les autres étapes restent permises,
        /// selon la version de SQLite : sous-requête matérialisée (LIST SUBQUERY), filtre de Bloom (CREATE BLOOM
        /// FILTER).
        private static func usesIndexes(_ plan: [String], fullRead: Bool) -> Bool {
            !plan.isEmpty && !plan.contains { step in
                step.contains("TEMP B-TREE") || (step.hasPrefix("SCAN ") && (!fullRead || !step.contains(" INDEX ")))
            }
        }

        private func withLargeHistory(_ body: (HistoryStore, SQLiteFile) throws -> Void) throws {
            try HistoryStoreFixture.withDatabase { path in
                _ = try HistoryStore(path: path)
                let template = String(decoding: try JSONEncoder().encode(DictationTrace(
                    id: "@TRACE@", dictationID: "@DICTEE@", createdAt: HistoryStoreFixture.baseline, origin: .hold,
                    outcome: .inserted
                )), as: UTF8.self)
                let file = try SQLiteFile(path)
                #expect(file.execute("""
                    BEGIN;
                    WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < \(Self.count - 1))
                    INSERT INTO dictations (id, created_at, final_text, raw_text, duration_seconds, word_count, provider,
                        model, target_app, target_bundle, usage_category, insertion_status, audio_path, audio_expires_at)
                    SELECT printf('dictee-%05d', i), 1791028800 + i * 600, 'Dictée fictive numéro ' || i || '.',
                        'dictée fictive numéro ' || i, 4, 4, 'xai', 'modele-fictif', 'Notes', 'com.apple.Notes', 'notes',
                        'inserted', printf('Audio/dictee-%05d.wav', i), 1791028800 + i * 600 + 86400 FROM n;
                    WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < \(Self.count - 1))
                    INSERT INTO dictation_traces (id, dictation_id, created_at, payload)
                    SELECT printf('trace-%05d', i), printf('dictee-%05d', i), 1791028800 + i * 600,
                        replace(replace('\(template)', '@TRACE@', printf('trace-%05d', i)), '@DICTEE@', printf('dictee-%05d', i))
                    FROM n;
                    WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < \(3 * Self.count - 1))
                    INSERT INTO api_usage (id, created_at, api, model, audio_seconds, input_tokens, cached_tokens,
                        output_tokens, cost_usd, latency_ms, succeeded)
                    SELECT printf('appel-%05d', i), 1791028800 + i * 200, 'deepseek.cleanup', 'modele-fictif', 0, 900, 300,
                        120, 0.0004, 800, 1 FROM n;
                    COMMIT;
                    """) == SQLITE_OK)
                try body(try HistoryStore(path: path), file)
            }
        }
    }
}
