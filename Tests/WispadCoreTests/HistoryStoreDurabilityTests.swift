import Foundation
import SQLite3
import Testing
@testable import WispadCore

/// Ce qui reste de la base après une écriture interrompue (erreur, Wispad tué), à chaque réouverture, et à la
/// fermeture.
struct HistoryStoreDurabilityTests {
    /// Écriture interrompue par une erreur au milieu d'une transaction (trace illisible pendant l'ajout d'un appel,
    /// dictée disparue pendant l'écriture de sa trace) : tout est annulé et la connexion ne garde aucune transaction
    /// ouverte. La dictée suivante est écrite pour de bon : visible tout de suite d'une autre connexion, qui peut
    /// écrire à son tour, et retrouvée après réouverture.
    @Test func aFailedWriteLeavesNoTransactionOpen() throws {
        try HistoryStoreFixture.withDatabase { path in
            do {
                let store = try HistoryStore(path: path)
                let other = try SQLiteFile(path)
                try store.insert(HistoryStoreFixture.record("premiere"))
                #expect(other.execute("INSERT INTO dictation_traces VALUES ('illisible', NULL, 1791028800, 'contenu-fictif');") == SQLITE_OK)
                #expect(throws: (any Error).self) {
                    try store.appendTraceCalls(id: "illisible", calls: [DictationAPICall(HistoryStoreFixture.call("appel"))])
                }
                #expect(throws: (any Error).self) {
                    try store.saveTrace(DictationTrace(id: "orpheline", dictationID: "disparue", origin: .hold))
                }
                try store.insert(HistoryStoreFixture.record("suivante", at: 60))
                #expect(other.strings("SELECT id FROM dictations ORDER BY created_at DESC;") == ["suivante", "premiere"])
                #expect(other.strings("SELECT id FROM dictation_traces;") == ["illisible"])
                #expect(other.execute("BEGIN IMMEDIATE; COMMIT;") == SQLITE_OK)
            }
            #expect(try HistoryStore(path: path).dictations().map(\.id) == ["suivante", "premiere"])
        }
    }

    /// Migration interrompue au milieu (ici, son marqueur refusé par la base, comme un disque plein à cet instant) :
    /// rien n'en reste, ni le prix effacé ni le marqueur, et la connexion ne garde aucun verrou. Au lancement suivant,
    /// elle est rejouée entière, une seule fois.
    @Test func anInterruptedMigrationLeavesNothingAndRunsAgainInFull() throws {
        try HistoryStoreFixture.withDatabase { path in
            do {
                let store = try HistoryStore(path: path)
                try store.insert(HistoryStoreFixture.record("dictee"))
                try store.insertUsage(UsageEvent(
                    id: "echec", createdAt: HistoryStoreFixture.baseline, api: .deepSeekCleanup, model: "modele-fictif",
                    costUSD: 0, succeeded: false
                ))
            }
            // Base d'avant la migration du prix des échecs : marqueur absent, échec compté gratuit.
            let file = try SQLiteFile(path)
            #expect(file.execute("""
                DELETE FROM app_metadata WHERE key = 'usage_accuracy_v1';
                CREATE TRIGGER interrompt BEFORE INSERT ON app_metadata WHEN NEW.key = 'usage_accuracy_v1'
                BEGIN SELECT RAISE(ABORT, 'migration interrompue'); END;
                """) == SQLITE_OK)

            #expect(throws: (any Error).self) { try HistoryStore(path: path) }
            #expect(file.strings("SELECT cost_usd FROM api_usage WHERE id = 'echec';") == ["0.0"])
            #expect(file.strings("SELECT key FROM app_metadata WHERE key = 'usage_accuracy_v1';") == [])
            #expect(file.execute("BEGIN IMMEDIATE; COMMIT;") == SQLITE_OK)

            #expect(file.execute("DROP TRIGGER interrompt;") == SQLITE_OK)
            let store = try HistoryStore(path: path)
            #expect(try store.usageEvents().map(\.costUSD) == [nil])
            #expect(try store.dictations().map(\.id) == ["dictee"])
            #expect(file.strings("SELECT value FROM app_metadata WHERE key = 'usage_accuracy_v1';") == ["1"])
        }
    }

    /// Wispad tué pendant qu'il écrivait une transaction dans le journal WAL : toutes ses pages y sont, sauf la dernière
    /// trame, celle qui la valide. La base se rouvre avec tout ce qui était validé avant et rien de cette transaction,
    /// intègre, et accepte la dictée suivante.
    @Test func aTransactionCutBeforeItsCommitFrameLeavesNothingBehind() throws {
        try HistoryStoreFixture.withDatabase { path in
            let left = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("laissee.sqlite").path
            let store = try HistoryStore(path: path)
            try store.insert(HistoryStoreFixture.record("validee"))
            let writer = try SQLiteFile(path)
            #expect(writer.execute("""
                BEGIN IMMEDIATE;
                INSERT INTO dictations (id, created_at, final_text, raw_text, duration_seconds, word_count, provider,
                    model, insertion_status) VALUES ('perdue', 1791028900, 'Perdue.', 'perdue', 1, 1, 'xai', 'm', 'pending');
                CREATE TABLE remplissage (x TEXT);
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 400)
                INSERT INTO remplissage SELECT hex(randomblob(1000)) FROM n;
                COMMIT;
                """) == SQLITE_OK)
            // Journal WAL : un en-tête de 32 octets, puis une trame par page écrite (la page et 24 octets d'en-tête) ;
            // la dernière valide la transaction. Copie de la base et du journal sans cette trame.
            let frame = try #require(writer.strings("PRAGMA page_size;")?.first.flatMap { Int($0) }) + 24
            let journal = try Data(contentsOf: URL(fileURLWithPath: path + "-wal"))
            #expect((journal.count - 32) % frame == 0)
            #expect(journal.count > 32 + 100 * frame)
            try FileManager.default.copyItem(atPath: path, toPath: left)
            try journal.prefix(journal.count - frame).write(to: URL(fileURLWithPath: left + "-wal"))

            let reopened = try HistoryStore(path: left)
            #expect(try reopened.dictations().map(\.id) == ["validee"])
            try reopened.insert(HistoryStoreFixture.record("suivante", at: 60))
            #expect(try reopened.dictations().map(\.id) == ["suivante", "validee"])
            let file = try SQLiteFile(left)
            #expect(file.strings("SELECT name FROM sqlite_master WHERE name = 'remplissage';") == [])
            #expect(file.strings("PRAGMA integrity_check;") == ["ok"])
        }
    }

    /// Migrations rejouées sur une base déjà migrée : rien ne change, lancement après lancement (schéma, marqueurs,
    /// données, date de début du suivi des bascules).
    @Test func reopeningAMigratedDatabaseChangesNothing() throws {
        try HistoryStoreFixture.withDatabase { path in
            let started: Date
            do {
                let store = try HistoryStore(path: path)
                started = store.fallbackTrackingStartedAt
                try store.insert(HistoryStoreFixture.record("dictee"))
                try store.saveTrace(DictationTrace(
                    id: "trace", dictationID: "dictee", createdAt: HistoryStoreFixture.baseline, origin: .hold,
                    calls: [DictationAPICall(HistoryStoreFixture.call("appel"))]
                ))
                try store.insertUsage(HistoryStoreFixture.call("appel"))
                try store.addTerm("Wispad", origin: .user)
                try store.rememberRefusal("Refusé")
            }
            let file = try SQLiteFile(path)
            let snapshot = {
                [
                    "SELECT type || ' ' || name || ' ' || coalesce(sql, '') FROM sqlite_master ORDER BY name;",
                    "SELECT key || '=' || value FROM app_metadata ORDER BY key;",
                    "SELECT id || ' ' || insertion_status || ' ' || coalesce(audio_path, '-') FROM dictations ORDER BY id;",
                    "SELECT id || ' ' || payload FROM dictation_traces ORDER BY id;",
                    "SELECT id || ' ' || coalesce(cost_usd, '-') FROM api_usage ORDER BY id;",
                    "SELECT term || ' ' || coalesce(origin, '-') FROM dictionary ORDER BY term;",
                    "SELECT term FROM learning_refusals ORDER BY term;",
                ].map { file.strings($0) ?? ["illisible"] }
            }
            let before = snapshot()
            for _ in 0..<3 {
                #expect(try HistoryStore(path: path).fallbackTrackingStartedAt == started)
            }
            #expect(snapshot() == before)
        }
    }

    /// Base laissée par une version plus récente (colonnes ajoutées en fin de table, table, index et marqueur
    /// inconnus) : cette version la lit et y écrit sans rien perdre de ce qu'elle ne connaît pas.
    @Test func aDatabaseFromANewerVersionStaysReadableAndKeepsItsExtras() throws {
        try HistoryStoreFixture.withDatabase { path in
            do {
                let store = try HistoryStore(path: path)
                try store.insert(HistoryStoreFixture.record("ancienne"))
                try store.insertUsage(HistoryStoreFixture.call("appel"))
                try store.addTerm("Wispad", origin: .user)
            }
            let newer = try SQLiteFile(path)
            #expect(newer.execute("""
                ALTER TABLE dictations ADD COLUMN future_note TEXT;
                ALTER TABLE api_usage ADD COLUMN future_region TEXT;
                ALTER TABLE dictionary ADD COLUMN future_weight REAL;
                UPDATE dictations SET future_note = 'note';
                UPDATE api_usage SET future_region = 'eu';
                UPDATE dictionary SET future_weight = 2;
                CREATE TABLE future_table (id TEXT PRIMARY KEY);
                INSERT INTO future_table VALUES ('garde');
                CREATE INDEX future_index ON dictations(provider);
                INSERT INTO app_metadata (key, value) VALUES ('future_v9', '1');
                """) == SQLITE_OK)

            let store = try HistoryStore(path: path)
            #expect(try store.dictations() == [HistoryStoreFixture.record("ancienne")])
            #expect(try store.usageEvents() == [HistoryStoreFixture.call("appel")])
            #expect(try store.dictionary().map(\.term) == ["Wispad"])
            try store.insert(HistoryStoreFixture.record("nouvelle", at: 60))
            try store.insertUsage(HistoryStoreFixture.call("second", at: 60))
            try store.addTerm("Seedance", origin: .user)
            #expect(try store.dictations().map(\.id) == ["nouvelle", "ancienne"])
            #expect(try store.usageEvents().map(\.id) == ["second", "appel"])
            #expect(try store.dictionary().map(\.term) == ["Seedance", "Wispad"])
            #expect(newer.strings("SELECT id || '=' || coalesce(future_note, '-') FROM dictations ORDER BY id;") == ["ancienne=note", "nouvelle=-"])
            #expect(newer.strings("SELECT id FROM future_table;") == ["garde"])
            #expect(newer.strings("SELECT value FROM app_metadata WHERE key = 'future_v9';") == ["1"])
            #expect(newer.strings("SELECT name FROM sqlite_master WHERE name = 'future_index';") == ["future_index"])
        }
    }

    /// Fermeture propre : libérer le `HistoryStore` ferme sa connexion, sans instruction laissée ouverte. Le journal WAL
    /// est alors reversé dans la base, qui suffit seule à tout relire.
    @Test func releasingTheStoreFoldsTheJournalIntoTheDatabase() throws {
        try HistoryStoreFixture.withDatabase { path in
            do {
                let store = try HistoryStore(path: path)
                try store.insert(HistoryStoreFixture.record("fermee"))
                try store.saveTrace(DictationTrace(id: "trace", dictationID: "fermee", origin: .hold))
                try store.insertUsage(HistoryStoreFixture.call("appel"))
                _ = try store.recentTraces()
                #expect(HistoryStoreFixture.size(path + "-wal") > 0)
            }
            #expect(HistoryStoreFixture.size(path + "-wal") == 0)
            let alone = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("seule.sqlite").path
            try FileManager.default.copyItem(atPath: path, toPath: alone)
            let copy = try HistoryStore(path: alone)
            #expect(try copy.dictations().map(\.id) == ["fermee"])
            #expect(try copy.traces(dictationID: "fermee").map(\.id) == ["trace"])
            #expect(try copy.usageEvents().map(\.id) == ["appel"])
        }
    }
}
