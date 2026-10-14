import Foundation
import SQLite3
import Testing
@testable import WispadCore

/// Accès à la base depuis plusieurs fils et plusieurs connexions : le fil principal (dictées, écrans), les tâches
/// détachées (détail d'une dictée, diagnostic) et un autre Wispad ouvert sur la même base.
struct HistoryStoreConcurrencyTests {
    /// `HistoryStore` est `@unchecked Sendable` : chaque accès à sa connexion passe par sa file série. Écritures
    /// (dictée, trace, appel tardif, statut, mot) et lectures mêlées depuis 8 fils : aucune erreur, rien de perdu, et
    /// la base reste intègre.
    @Test func readsAndWritesFromManyThreadsLoseNothing() throws {
        try HistoryStoreFixture.withDatabase { path in
            let store = try HistoryStore(path: path)
            let failures = StoreFailures()
            DispatchQueue.concurrentPerform(iterations: 8) { worker in
                for index in 0..<25 {
                    let id = "fil\(worker)-\(index)"
                    failures.run {
                        try store.insert(HistoryStoreFixture.record(id, at: Double(worker * 1_000 + index)))
                        try store.saveTrace(DictationTrace(id: "trace-\(id)", dictationID: id, origin: .hold))
                        try store.insertUsage(HistoryStoreFixture.call("appel-\(id)"))
                        try store.appendTraceCalls(id: "trace-\(id)", calls: [DictationAPICall(HistoryStoreFixture.call("tardif-\(id)"))])
                        try store.updateStatus(id: id, status: InsertionStatus.inserted.rawValue)
                        try store.addTerm("Terme\(worker)x\(index)", origin: .user)
                        _ = try store.dictations()
                        _ = try store.recentTraces(limit: 5)
                        _ = try store.usageEvents()
                    }
                }
            }
            #expect(failures.all.isEmpty)
            let dictations = try store.dictations()
            #expect(dictations.count == 200)
            #expect(dictations.allSatisfy { $0.insertionStatus == InsertionStatus.inserted.rawValue })
            #expect(try store.usageEvents().count == 200)
            #expect(try store.dictionary().count == 200)
            let traces = try store.recentTraces(limit: 1_000)
            #expect(traces.count == 200)
            let lateCallsKept = traces.allSatisfy { trace in trace.calls.map(\.id) == ["tardif-" + (trace.dictationID ?? "")] }
            #expect(lateCallsKept)
            let file = try SQLiteFile(path)
            #expect(file.strings("PRAGMA integrity_check;") == ["ok"])
            #expect(file.strings("PRAGMA foreign_key_check;") == [])
        }
    }

    /// Deux Wispad ouverts sur la même base (`open -n`) écrivent en même temps : le journal WAL et `busy_timeout` font
    /// attendre chaque écriture son tour. Aucune n'échoue, chaque instance voit celles de l'autre.
    @Test func twoInstancesWritingTogetherLoseNothing() throws {
        try HistoryStoreFixture.withDatabase { path in
            let first = try HistoryStore(path: path)
            let second = try HistoryStore(path: path)
            let failures = StoreFailures()
            DispatchQueue.concurrentPerform(iterations: 8) { worker in
                let store = worker.isMultiple(of: 2) ? first : second
                for index in 0..<25 {
                    let id = "instance\(worker)-\(index)"
                    failures.run {
                        try store.insert(HistoryStoreFixture.record(id, at: Double(worker * 1_000 + index)))
                        try store.saveTrace(DictationTrace(id: "trace-\(id)", dictationID: id, origin: .toggle))
                        try store.insertUsage(HistoryStoreFixture.call("appel-\(id)"))
                        try store.updateAudio(id: id, path: nil, expiresAt: nil)
                    }
                }
            }
            #expect(failures.all.isEmpty)
            #expect(try first.dictations().count == 200)
            #expect(try second.dictations().count == 200)
            #expect(try first.dictations().allSatisfy { $0.audioPath == nil && $0.audioExpiresAt == nil })
            #expect(try second.usageEvents().count == 200)
            #expect(try first.recentTraces(limit: 1_000).count == 200)
            #expect(try SQLiteFile(path).strings("PRAGMA integrity_check;") == ["ok"])
        }
    }

    /// Verrou d'écriture tenu un instant par une autre connexion : la dictée attend son tour (`busy_timeout`), sans
    /// erreur, puis s'écrit dès le verrou rendu ; l'écriture de l'autre connexion est gardée aussi.
    @Test func aDictationWaitsForABriefLockThenIsSaved() throws {
        try HistoryStoreFixture.withDatabase { path in
            let store = try HistoryStore(path: path)
            let other = try SQLiteFile(path)
            #expect(other.execute("BEGIN IMMEDIATE;") == SQLITE_OK)
            #expect(other.execute("INSERT INTO dictionary (id, term, created_at) VALUES ('autre', 'Autre', 0);") == SQLITE_OK)
            let write = BackgroundWrite { try store.insert(HistoryStoreFixture.record("attendue")) }
            Thread.sleep(forTimeInterval: 0.2)
            #expect(!write.isFinished)
            #expect(other.execute("COMMIT;") == SQLITE_OK)
            #expect(write.waitForFailure() == nil)
            #expect(try store.dictations().map(\.id) == ["attendue"])
            #expect(try store.dictionary().map(\.term) == ["Autre"])
        }
    }

    /// Une autre connexion tient le verrou d'écriture (autre Wispad, outil qui inspecte la base) : une base déjà à
    /// jour s'ouvre sans écrire, donc sans attendre ce verrou, et l'historique se lit (journal WAL : une lecture
    /// n'attend jamais une écriture). Avant, chaque lancement réécrivait ses marqueurs et nettoyait l'ancienne clé du
    /// suivi financier : il échouait après 2 s (« database is locked ») et Wispad ne démarrait pas.
    @Test func anUpToDateDatabaseOpensWhileAnotherConnectionHoldsTheWriteLock() throws {
        try HistoryStoreFixture.withDatabase { path in
            let started: Date
            do {
                let store = try HistoryStore(path: path)
                started = store.fallbackTrackingStartedAt
                try store.insert(HistoryStoreFixture.record("gardee"))
                try store.addTerm("Wispad", origin: .user)
            }
            let other = try SQLiteFile(path)
            #expect(other.execute("BEGIN IMMEDIATE;") == SQLITE_OK)
            #expect(other.execute("INSERT INTO dictionary (id, term, created_at) VALUES ('autre', 'Autre', 0);") == SQLITE_OK)

            let store = try HistoryStore(path: path)
            #expect(store.fallbackTrackingStartedAt == started)
            #expect(try store.dictations().map(\.id) == ["gardee"])
            #expect(try store.dictionary().map(\.term) == ["Wispad"])

            #expect(other.execute("COMMIT;") == SQLITE_OK)
            try store.insert(HistoryStoreFixture.record("suivante", at: 60))
            #expect(try store.dictations().map(\.id) == ["suivante", "gardee"])
            #expect(try store.dictionary().map(\.term) == ["Autre", "Wispad"])
            #expect(other.strings("PRAGMA journal_mode;") == ["wal"])
        }
    }
}
