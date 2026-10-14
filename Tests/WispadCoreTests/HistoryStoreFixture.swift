import Foundation
import SQLite3
@testable import WispadCore

/// Bases fictives des tests de robustesse de `HistoryStore` : un dossier temporaire par test, effacé à la fin, et
/// des données inventées.
enum HistoryStoreFixture {
    static let baseline = Date(timeIntervalSince1970: 1_791_028_800)

    /// Chemin d'une base qui n'existe pas encore, dans un dossier effacé après `body`, même en cas d'échec.
    static func withDatabase<T>(_ body: (String) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory.appendingPathComponent("history.sqlite").path)
    }

    static func record(_ id: String, at offset: TimeInterval = 0) -> DictationRecord {
        let text = "Phrase fictive pour vérifier l'historique."
        return DictationRecord(
            id: id, createdAt: baseline.addingTimeInterval(offset), finalText: text, rawText: text.lowercased(),
            durationSeconds: 3, wordCount: WordCount.count(text), provider: "xai", model: "modele-fictif",
            targetApp: "Notes", targetBundle: "com.apple.Notes", insertionStatus: InsertionStatus.pending.rawValue,
            audioPath: "Audio/\(id).wav", audioExpiresAt: baseline.addingTimeInterval(offset + 86_400)
        )
    }

    static func call(_ id: String, at offset: TimeInterval = 0) -> UsageEvent {
        UsageEvent(
            id: id, createdAt: baseline.addingTimeInterval(offset), api: .deepSeekCleanup, model: "modele-fictif",
            tokens: TokenUsage(input: 900, cachedInput: 300, output: 120), costUSD: 0.0004, latencyMs: 800
        )
    }

    /// Taille d'un fichier, 0 s'il n'existe pas.
    static func size(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}

/// Connexion SQLite indépendante de `HistoryStore` : un autre Wispad ouvert sur la même base, ou un outil qui
/// l'inspecte. Aucune attente sur une base occupée : un verrou tenu ailleurs se voit tout de suite (`SQLITE_BUSY`).
final class SQLiteFile: @unchecked Sendable {
    private let handle: OpaquePointer?

    init(_ path: String) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &connection, flags, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            throw StoreError.message("Ouverture de la base fictive impossible.")
        }
        handle = connection
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Code SQLite d'une ou plusieurs instructions.
    @discardableResult
    func execute(_ sql: String) -> Int32 {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    /// Première colonne de chaque ligne, en texte ; nil si la requête échoue.
    func strings(_ sql: String) -> [String]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
            code = sqlite3_step(statement)
        }
        return code == SQLITE_DONE ? values : nil
    }

    /// Plan d'exécution, une étape par ligne (« SEARCH … USING INDEX … », « SCAN … », « USE TEMP B-TREE … ») ;
    /// nil si la requête ne se prépare pas.
    func plan(_ sql: String) -> [String]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var steps: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            steps.append(sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "")
        }
        return steps
    }
}

/// Écriture lancée sur un fil à elle, pas sur une file de GCD qu'un test voisin peut occuper toute entière
/// (`concurrentPerform`) : le test sait si elle est finie et ce qu'elle a levé.
final class BackgroundWrite: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private var failure: String?

    init(_ work: @escaping @Sendable () throws -> Void) {
        Thread.detachNewThread { [self] in
            var message: String?
            do {
                try work()
            } catch {
                message = String(describing: error)
            }
            lock.withLock {
                finished = true
                failure = message
            }
            done.signal()
        }
    }

    var isFinished: Bool { lock.withLock { finished } }

    /// Attend la fin de l'écriture : son erreur, nil si elle a réussi.
    func waitForFailure() -> String? {
        done.wait()
        return lock.withLock { failure }
    }
}

/// Erreurs relevées par plusieurs fils à la fois.
final class StoreFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func run(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            lock.withLock { messages.append(String(describing: error)) }
        }
    }

    var all: [String] { lock.withLock { messages } }
}
