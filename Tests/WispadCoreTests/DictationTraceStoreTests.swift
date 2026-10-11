import Foundation
import SQLite3
import XCTest
@testable import WispadCore

final class DictationTraceStoreTests: XCTestCase {
    private let baseline = Date(timeIntervalSince1970: 1_791_028_800)

    func testTraceRoundTripsTimingsCallsFallbackAndUpsertAfterReopening() throws {
        try withDatabase { path in
            var store: HistoryStore? = try HistoryStore(path: path)
            let record = makeRecord(id: "dictation")
            try store!.insert(record)
            let event = UsageEvent(
                id: "call", createdAt: baseline, api: .openAIFile, model: "test-model",
                costUSD: 0, latencyMs: 831, succeeded: false,
                fallback: APIFallback(fromAPI: .xaiStreaming, stage: .transcription, reason: .requestFailed)
            )
            var trace = DictationTrace(
                id: "run", dictationID: record.id, createdAt: baseline, origin: .toggle,
                timings: DictationTimings(
                    microphoneMs: 201, firstAudioMs: 229, streamReadyMs: 302,
                    transcriptionMs: 831, correctionMs: 901, insertionMs: 109, afterReleaseMs: 1_841
                ),
                calls: [DictationAPICall(event)], outcome: .transcriptionFailed
            )
            try store!.saveTrace(trace)
            trace.outcome = .pasteSent
            trace.timings.insertionMs = 115
            try store!.saveTrace(trace)
            store = nil

            let reopened = try HistoryStore(path: path)
            XCTAssertEqual(try reopened.trace(id: trace.id), trace)
            XCTAssertEqual(try reopened.traces(dictationID: record.id), [trace])
            XCTAssertEqual(try reopened.recentTraces(), [trace])
            XCTAssertEqual(try reopened.dictations(), [record])
        }
    }

    func testRetriesStayDistinctOrderedAndUnmeasuredTimingsRemainAbsent() throws {
        try withDatabase { path in
            let store = try HistoryStore(path: path)
            try store.insert(makeRecord(id: "dictation"))
            let original = DictationTrace(
                id: "original", dictationID: "dictation", createdAt: baseline,
                origin: .hold, timings: DictationTimings(firstAudioMs: 231), outcome: .transcriptionFailed
            )
            let firstRetry = DictationTrace(
                id: "retry-1", dictationID: "dictation", createdAt: baseline.addingTimeInterval(10),
                origin: .retry, timings: DictationTimings(transcriptionMs: 450), outcome: .transcriptionFailed
            )
            let secondRetry = DictationTrace(
                id: "retry-2", dictationID: "dictation", createdAt: baseline.addingTimeInterval(20),
                origin: .retry, timings: DictationTimings(transcriptionMs: 398), outcome: .inserted
            )
            for trace in [firstRetry, original, secondRetry] { try store.saveTrace(trace) }

            XCTAssertEqual(try store.traces(dictationID: "dictation"), [secondRetry, firstRetry, original])
            XCTAssertNil(try store.trace(id: "retry-2")?.timings.microphoneMs)
            XCTAssertNil(try store.trace(id: "retry-2")?.timings.firstAudioMs)
            XCTAssertEqual(try store.recentTraces(limit: 1), [secondRetry])
            XCTAssertTrue(try store.recentTraces(limit: 0).isEmpty)
            XCTAssertTrue(try store.recentTraces(limit: -1).isEmpty)
        }
    }

    func testLegacyDatabaseMigrationIsIdempotentAndDoesNotInventOldTimings() throws {
        try withDatabase { path in
            try executeSQL(
                """
                CREATE TABLE dictations (
                    id TEXT PRIMARY KEY, created_at REAL NOT NULL, final_text TEXT NOT NULL,
                    raw_text TEXT NOT NULL, duration_seconds REAL NOT NULL, word_count INTEGER NOT NULL,
                    provider TEXT NOT NULL, model TEXT NOT NULL, target_app TEXT, target_bundle TEXT,
                    usage_category TEXT, insertion_status TEXT NOT NULL, audio_path TEXT, audio_expires_at REAL
                );
                INSERT INTO dictations VALUES ('legacy', 1700000000, 'Texte fictif.', 'texte fictif',
                    3, 2, 'xai', 'test-model', NULL, NULL, NULL, 'inserted', NULL, NULL);
                CREATE TABLE api_usage (
                    id TEXT PRIMARY KEY, created_at REAL NOT NULL, api TEXT NOT NULL, model TEXT NOT NULL,
                    audio_seconds REAL NOT NULL, input_tokens INTEGER NOT NULL, cached_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL, cost_usd REAL, latency_ms INTEGER NOT NULL, succeeded INTEGER NOT NULL
                );
                INSERT INTO api_usage VALUES ('legacy-call', 1700000000, 'openai.stt.file', 'test-model',
                    3, 0, 0, 0, 0.01, 325, 1);
                """, at: path
            )
            var migrated: HistoryStore? = try HistoryStore(path: path)
            XCTAssertEqual(try migrated!.dictations().first?.finalText, "Texte fictif.")
            XCTAssertEqual(try migrated!.usageEvents().first?.latencyMs, 325)
            XCTAssertTrue(try migrated!.traces(dictationID: "legacy").isEmpty)
            XCTAssertTrue(try migrated!.recentTraces().isEmpty)
            let retry = DictationTrace(dictationID: "legacy", createdAt: baseline, origin: .retry, outcome: .pasteSent)
            try migrated!.saveTrace(retry)
            migrated = nil

            let reopened = try HistoryStore(path: path)
            XCTAssertEqual(try reopened.traces(dictationID: "legacy"), [retry])
            XCTAssertEqual(try reopened.dictations().count, 1)
            XCTAssertEqual(try reopened.usageEvents().count, 1)
        }
    }

    func testDeletingOneDictationRemovesOnlyItsTracesAndPreservesConsumption() throws {
        try withDatabase { path in
            let store = try HistoryStore(path: path)
            try store.insert(makeRecord(id: "first"))
            try store.insert(makeRecord(id: "second"))
            try store.insertUsage(makeCall(id: "usage"))
            let original = DictationTrace(id: "first-run", dictationID: "first", origin: .hold)
            let retry = DictationTrace(id: "first-retry", dictationID: "first", origin: .retry)
            let retained = DictationTrace(id: "second-run", dictationID: "second", origin: .toggle)
            let unassociated = DictationTrace(id: "cancelled", origin: .toggle, outcome: .cancelled)
            for trace in [original, retry, retained, unassociated] { try store.saveTrace(trace) }

            try store.deleteDictation(id: "first")

            XCTAssertTrue(try store.traces(dictationID: "first").isEmpty)
            XCTAssertNil(try store.trace(id: original.id))
            XCTAssertNil(try store.trace(id: retry.id))
            XCTAssertEqual(try store.traces(dictationID: "second"), [retained])
            XCTAssertEqual(try store.trace(id: unassociated.id), unassociated)
            XCTAssertEqual(try store.usageEvents().map(\.id), ["usage"])
            XCTAssertEqual(try store.dictations().map(\.id), ["second"])
        }
    }

    func testDeletingAllDictationsRetainsOnlyUnassociatedDiagnosticsAndConsumption() throws {
        try withDatabase { path in
            let store = try HistoryStore(path: path)
            try store.insert(makeRecord(id: "dictation"))
            try store.insertUsage(makeCall(id: "usage"))
            let linked = DictationTrace(id: "linked", dictationID: "dictation", origin: .hold)
            let unassociated = DictationTrace(id: "denied", origin: .hold, outcome: .microphoneDenied)
            try store.saveTrace(linked)
            try store.saveTrace(unassociated)

            try store.deleteAllDictations()

            XCTAssertTrue(try store.dictations().isEmpty)
            XCTAssertNil(try store.trace(id: linked.id))
            XCTAssertEqual(try store.recentTraces(), [unassociated])
            XCTAssertEqual(try store.usageEvents().map(\.id), ["usage"])
        }
    }

    func testOnlyUnassociatedRunsAreBoundedAndOldInsertionsCannotEvictNewerRuns() throws {
        try withDatabase { path in
            let store = try HistoryStore(path: path)
            try store.insert(makeRecord(id: "dictation"))
            let linked = DictationTrace(
                id: "linked-old", dictationID: "dictation", createdAt: baseline.addingTimeInterval(-10), origin: .hold
            )
            try store.saveTrace(linked)
            for index in (0..<130).reversed() {
                try store.saveTrace(DictationTrace(
                    id: "run-\(index)", createdAt: baseline.addingTimeInterval(Double(index)),
                    origin: .toggle, outcome: .cancelled
                ))
            }
            let retained = try store.recentTraces(limit: 500)
            XCTAssertEqual(retained.count, 101)
            XCTAssertEqual(retained.filter { $0.dictationID == nil }.map(\.id), (30..<130).reversed().map { "run-\($0)" })
            XCTAssertEqual(try store.trace(id: linked.id), linked)
            XCTAssertNil(try store.trace(id: "run-0"))

            try store.saveTrace(DictationTrace(
                id: "very-old", createdAt: baseline.addingTimeInterval(-20), origin: .hold, outcome: .noSpeech
            ))
            XCTAssertNil(try store.trace(id: "very-old"))
            XCTAssertEqual(try store.recentTraces(limit: 500), retained)
        }
    }

    func testLateDictionaryCallsAppendOnceAndNeverResurrectDeletedTraces() throws {
        try withDatabase { path in
            let store = try HistoryStore(path: path)
            try store.insert(makeRecord(id: "dictation"))
            let initialCall = DictationAPICall(makeCall(id: "speech"))
            let dictionaryCall = DictationAPICall(makeCall(id: "dictionary", api: .typesafeJudge))
            let secondOpinion = DictationAPICall(makeCall(id: "second-opinion", api: .xaiCleanup))
            let trace = DictationTrace(id: "run", dictationID: "dictation", origin: .hold, calls: [initialCall])
            try store.saveTrace(trace)
            try store.appendTraceCalls(id: trace.id, calls: [initialCall, dictionaryCall, dictionaryCall, secondOpinion])
            try store.appendTraceCalls(id: trace.id, calls: [dictionaryCall, secondOpinion])
            XCTAssertEqual(try store.trace(id: trace.id)?.calls, [initialCall, dictionaryCall, secondOpinion])

            try store.deleteDictation(id: "dictation")
            try store.appendTraceCalls(id: trace.id, calls: [dictionaryCall])
            try store.appendTraceCalls(id: "missing", calls: [dictionaryCall])
            XCTAssertTrue(try store.recentTraces().isEmpty)
        }
    }

    func testConcurrentAppendsDoNotLoseCalls() throws {
        try withDatabase { path in
            let store = try HistoryStore(path: path)
            try store.insert(makeRecord(id: "dictation"))
            try store.saveTrace(DictationTrace(id: "run", dictationID: "dictation", origin: .toggle))
            let calls = (0..<40).map { DictationAPICall(makeCall(id: "call-\($0)", api: .typesafeJudge)) }
            DispatchQueue.concurrentPerform(iterations: calls.count) { index in
                try? store.appendTraceCalls(id: "run", calls: [calls[index], calls[index]])
            }
            XCTAssertEqual(Set(try store.trace(id: "run")!.calls.map(\.id)), Set(calls.map(\.id)))
            XCTAssertEqual(try store.trace(id: "run")!.calls.count, calls.count)
        }
    }

    func testMissingParentRejectsSaveAndKeepsPreviousTraceIntact() throws {
        try withDatabase { path in
            let store = try HistoryStore(path: path)
            let trace = DictationTrace(id: "run", origin: .hold, outcome: .captureFailed)
            try store.saveTrace(trace)
            var invalid = trace
            invalid.dictationID = "deleted-dictation"
            invalid.outcome = .inserted
            XCTAssertThrowsError(try store.saveTrace(invalid))
            XCTAssertEqual(try store.trace(id: trace.id), trace)
            XCTAssertEqual(try store.recentTraces(), [trace])
        }
    }

    func testUnreadablePayloadRaisesAGenericErrorWithoutEchoingItsContents() throws {
        try withDatabase { path in
            let store = try HistoryStore(path: path)
            try executeSQL(
                "INSERT INTO dictation_traces VALUES ('broken', NULL, 1700000000, 'contenu-fictif-confidentiel');",
                at: path
            )
            XCTAssertThrowsError(try store.recentTraces()) { error in
                XCTAssertEqual(String(describing: error), "Trace technique illisible.")
                XCTAssertFalse(String(describing: error).contains("contenu-fictif-confidentiel"))
            }
        }
    }

    private func makeRecord(id: String) -> DictationRecord {
        DictationRecord(
            id: id, createdAt: baseline, finalText: "Texte fictif.", rawText: "texte fictif",
            durationSeconds: 2, wordCount: 2, provider: "xai", model: "test-model", insertionStatus: "inserted"
        )
    }

    private func makeCall(id: String, api: UsageAPI = .xaiStreaming) -> UsageEvent {
        UsageEvent(id: id, createdAt: baseline, api: api, model: "test-model", costUSD: 0, latencyMs: 120)
    }

    private func withDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-traces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("history.sqlite").path)
    }

    private func executeSQL(_ sql: String, at path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw StoreError.message("Ouverture de la base fictive impossible.")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.message("Préparation de la base fictive impossible.")
        }
    }
}
