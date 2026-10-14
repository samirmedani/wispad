import Foundation
import SQLite3
import XCTest
@testable import WispadApp
@testable import WispadCore

/// SONDE TEMPORAIRE, retirée avant la relecture : mesures de la base sur le Mac de la vérification GitHub (SQLite du
/// système, coût d'une écriture, lectures de 5 000 dictées, recherche et regroupement en mémoire). Elle échoue exprès
/// pour que ses mesures paraissent dans le journal de la vérification.
final class HistoryStoreProbeTests: XCTestCase {
    func testMeasurementsOnTheVerificationMac() throws {
        var notes = ["SONDE", "sqlite=\(String(cString: sqlite3_libversion()))"]
        notes.append("options=" + Self.compileOptions().joined(separator: ","))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-sonde-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        let store = try HistoryStore(path: path)
        let clock = ContinuousClock()

        let inserts = try clock.measure {
            for index in 0..<1_000 { try store.insert(Self.record(index)) }
        }
        notes.append("insert1000=\(Self.ms(inserts))")
        let usageInserts = try clock.measure {
            for index in 0..<1_000 { try store.insertUsage(Self.call(index)) }
        }
        notes.append("insertUsage1000=\(Self.ms(usageInserts))")
        let traceSaves = try clock.measure {
            for index in 0..<500 {
                try store.saveTrace(DictationTrace(id: "trace-\(index)", dictationID: "dictee-\(index)", origin: .hold))
            }
        }
        notes.append("saveTrace500=\(Self.ms(traceSaves))")

        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        defer { sqlite3_close(raw) }
        notes.append("journal=\(Self.scalar(raw, "PRAGMA journal_mode;")) synchronous=\(Self.scalar(raw, "PRAGMA synchronous;"))")
        let text = Self.text.replacingOccurrences(of: "'", with: "''")
        let bulk = """
            BEGIN;
            WITH RECURSIVE n(i) AS (SELECT 1000 UNION ALL SELECT i + 1 FROM n WHERE i < 4999)
            INSERT INTO dictations (id, created_at, final_text, raw_text, duration_seconds, word_count, provider, model,
                target_app, target_bundle, usage_category, insertion_status, audio_path, audio_expires_at)
            SELECT 'dictee-' || i, 1791028800 + i * 600, '\(text) ' || i, '\(text.lowercased()) ' || i, 20, 60, 'xai',
                'modele', 'Notes', 'com.apple.Notes', 'notes', 'inserted', 'Audio/dictee-' || i || '.wav',
                1791028800 + i * 600 + 86400 FROM n;
            WITH RECURSIVE n(i) AS (SELECT 1000 UNION ALL SELECT i + 1 FROM n WHERE i < 14999)
            INSERT INTO api_usage (id, created_at, api, model, audio_seconds, input_tokens, cached_tokens,
                output_tokens, cost_usd, latency_ms, succeeded)
            SELECT 'appel-' || i, 1791028800 + i * 200, 'deepseek.cleanup', 'deepseek-flash', 0, 900, 300, 120, 0.0004,
                800, 1 FROM n;
            COMMIT;
            """
        XCTAssertEqual(sqlite3_exec(raw, bulk, nil, nil, nil), SQLITE_OK)

        var history: [DictationRecord] = []
        notes.append("dictations5000=\(Self.ms(Self.fastest { history = (try? store.dictations()) ?? [] }))")
        XCTAssertEqual(history.count, 5_000)
        notes.append("sqliteSeul5000=\(Self.ms(Self.fastest { Self.stepAll(raw, "SELECT * FROM dictations ORDER BY created_at DESC;") }))")
        var usage: [UsageEvent] = []
        notes.append("usageEvents15000=\(Self.ms(Self.fastest { usage = (try? store.usageEvents()) ?? [] }))")
        XCTAssertEqual(usage.count, 15_000)
        notes.append("ouverture=\(Self.ms(Self.fastest { _ = try? HistoryStore(path: path) }))")
        notes.append("rechercheAbsente=\(Self.ms(Self.fastest { _ = history.filter { $0.finalText.localizedCaseInsensitiveContains("zèbre") } }))")
        notes.append("rechercheFrequente=\(Self.ms(Self.fastest { _ = history.filter { $0.finalText.localizedCaseInsensitiveContains("équipe") } }))")
        notes.append("jours=\(Self.ms(Self.fastest { _ = DayGroup.make(history) }))")
        notes.append("resume15000=\(Self.ms(Self.fastest { _ = UsageSummary.make(events: usage, period: .all) }))")
        let purge = try clock.measure {
            for record in history.prefix(2_000) { try store.updateAudio(id: record.id, path: nil, expiresAt: nil) }
        }
        notes.append("purge2000=\(Self.ms(purge))")
        let purgeTransaction = clock.measure {
            sqlite3_exec(raw, "BEGIN IMMEDIATE;", nil, nil, nil)
            var statement: OpaquePointer?
            sqlite3_prepare_v2(raw, "UPDATE dictations SET audio_path = NULL, audio_expires_at = NULL WHERE id = ?;", -1, &statement, nil)
            for record in history.dropFirst(2_000).prefix(2_000) {
                sqlite3_bind_text(statement, 1, record.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(statement)
                sqlite3_reset(statement)
            }
            sqlite3_finalize(statement)
            sqlite3_exec(raw, "COMMIT;", nil, nil, nil)
        }
        notes.append("purge2000UneTransaction=\(Self.ms(purgeTransaction))")
        let deleteAll = try clock.measure { try store.deleteAllDictations() }
        notes.append("toutSupprimer=\(Self.ms(deleteAll))")
        XCTFail(notes.joined(separator: " | "))
    }

    private static let text = "Réunion avec l'équipe produit demain matin pour revoir la feuille de route, préparer la démo du "
        + "client et répartir les tâches de la semaine ; penser à envoyer le compte rendu à toute l'équipe avant midi, "
        + "avec les chiffres de la veille et la liste des questions encore ouvertes"

    private static func record(_ index: Int) -> DictationRecord {
        DictationRecord(
            id: "dictee-\(index)", createdAt: Date(timeIntervalSince1970: 1_791_028_800 + Double(index) * 600),
            finalText: text + " \(index)", rawText: text.lowercased(), durationSeconds: 20, wordCount: 60,
            provider: "xai", model: "modele", targetApp: "Notes", targetBundle: "com.apple.Notes", usageCategory: "notes",
            insertionStatus: InsertionStatus.inserted.rawValue, audioPath: "Audio/dictee-\(index).wav",
            audioExpiresAt: Date(timeIntervalSince1970: 1_791_028_800 + Double(index) * 600 + 86_400)
        )
    }

    private static func call(_ index: Int) -> UsageEvent {
        UsageEvent(id: "appel-\(index)", createdAt: Date(timeIntervalSince1970: 1_791_028_800 + Double(index) * 200),
                   api: .deepSeekCleanup, model: "deepseek-flash", tokens: TokenUsage(input: 900, cachedInput: 300, output: 120),
                   costUSD: 0.0004, latencyMs: 800)
    }

    private static func fastest(_ work: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return (0..<3).map { _ in clock.measure(work) }.min() ?? .zero
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%.1fms", Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
    }

    private static func compileOptions() -> [String] {
        var memory: OpaquePointer?
        sqlite3_open(":memory:", &memory)
        defer { sqlite3_close(memory) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(memory, "PRAGMA compile_options;", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var options: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            options.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        let keys = ["SYNCHRONOUS", "FSYNC", "THREADSAFE", "JOURNAL_SIZE", "AUTORESET", "WAL", "MMAP", "PERSIST"]
        return options.filter { option in keys.contains { option.contains($0) } }
    }

    private static func scalar(_ connection: OpaquePointer?, _ sql: String) -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return "?" }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return "?" }
        return String(cString: value)
    }

    private static func stepAll(_ connection: OpaquePointer?, _ sql: String) {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            for column in 0..<sqlite3_column_count(statement) { _ = sqlite3_column_text(statement, column) }
        }
    }
}
