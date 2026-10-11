import Foundation
import SQLite3
import XCTest
@testable import WispadCore

final class FallbackStatsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_028_800)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func event(
        id: String = UUID().uuidString,
        from: UsageAPI = .xaiStreaming,
        to: UsageAPI = .openAIFile,
        stage: FallbackStage = .transcription,
        reason: FallbackReason = .requestFailed,
        succeeded: Bool = true,
        at date: Date? = nil
    ) -> UsageEvent {
        UsageEvent(
            id: id, createdAt: date ?? now, api: to, model: "test-model", costUSD: 0,
            succeeded: succeeded,
            fallback: APIFallback(fromAPI: from, stage: stage, reason: reason)
        )
    }

    func testCountsOnlyExplicitCrossProviderFallbacksOnce() {
        let fallback = event(id: "one-fallback")
        let sameProvider = event(from: .xaiStreaming, to: .xaiFile)
        let ordinaryCall = UsageEvent(createdAt: now, api: .openAIFile, model: "test-model", costUSD: 0)
        let summary = FallbackSummary.make(
            events: [fallback, fallback, sameProvider, ordinaryCall], period: .all, now: now, calendar: calendar
        )
        XCTAssertEqual(summary.total, 1)
        XCTAssertEqual(summary.successes, 1)
        XCTAssertEqual(summary.failures, 0)
        XCTAssertEqual(summary.afterFailureCount, 1)
        XCTAssertEqual(summary.servicePausedCount, 0)
    }

    func testRoutesGroupProvidersAcrossAPIsButKeepStagesAndOutcomesSeparate() {
        let events = [
            event(),
            event(from: .xaiFile, to: .openAIStreaming, reason: .servicePaused, succeeded: false),
            event(from: .xaiCleanup, to: .openAICleanup, stage: .correction),
            event(from: .typesafeJudge, to: .xaiCleanup, stage: .dictionary, reason: .servicePaused),
            event(from: .deepSeekCleanup, to: .xaiCleanup, stage: .correction, succeeded: false)
        ]
        let summary = FallbackSummary.make(events: events, period: .all)
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.successes, 3)
        XCTAssertEqual(summary.failures, 2)
        XCTAssertEqual(summary.afterFailureCount, 3)
        XCTAssertEqual(summary.servicePausedCount, 2)
        XCTAssertEqual(summary.count(for: .transcription), 2)
        XCTAssertEqual(summary.count(for: .correction), 2)
        XCTAssertEqual(summary.count(for: .dictionary), 1)
        XCTAssertEqual(summary.routes.count, 4)
        let transcription = summary.routes.first!
        XCTAssertEqual(transcription.fromProvider, "xAI")
        XCTAssertEqual(transcription.toProvider, "OpenAI")
        XCTAssertEqual(transcription.stage, .transcription)
        XCTAssertEqual(transcription.total, 2)
        XCTAssertEqual(transcription.successes, 1)
        XCTAssertEqual(transcription.failures, 1)
        XCTAssertEqual(summary, FallbackSummary.make(events: Array(events.reversed()), period: .all))
        let tiedIDs = summary.routes.dropFirst().map(\.id)
        XCTAssertEqual(tiedIDs, tiedIDs.sorted())
    }

    func testPeriodsIncludeTheirBoundaryAndExcludeOlderCalls() {
        for period in [StatsPeriod.today, .days7, .days30] {
            let boundary = period.startDate(now: now, calendar: calendar)!
            let events = [event(at: boundary.addingTimeInterval(-1)), event(at: boundary), event(at: now)]
            let summary = FallbackSummary.make(events: events, period: period, now: now, calendar: calendar)
            XCTAssertEqual(summary.total, 2, "Période : \(period)")
            XCTAssertEqual(FallbackSummary.make(events: events, period: .all, now: now, calendar: calendar).total, 3)
        }
    }

    func testRecentFallbacksListTheLatestFirstWithTheirRouteReasonAndOutcome() {
        let events = (0..<7).map { index in
            event(id: "fallback-\(index)", reason: index == 6 ? .servicePaused : .requestFailed,
                  succeeded: index != 6, at: now.addingTimeInterval(Double(index) * 60))
        }
        let summary = FallbackSummary.make(events: events + [events[6]], period: .all, now: now, calendar: calendar)
        XCTAssertEqual(summary.recent.map(\.id), ["fallback-6", "fallback-5", "fallback-4", "fallback-3", "fallback-2"])
        let latest = summary.recent.first!
        XCTAssertEqual(latest.date, now.addingTimeInterval(360))
        XCTAssertEqual(latest.stage, .transcription)
        XCTAssertEqual(latest.fromProvider, "xAI")
        XCTAssertEqual(latest.toProvider, "OpenAI")
        XCTAssertEqual(latest.reason, .servicePaused)
        XCTAssertFalse(latest.succeeded)
        XCTAssertEqual(FallbackSummary.make(events: events, period: .all, recentLimit: 2).recent.map(\.id), ["fallback-6", "fallback-5"])
        // Même instant : ordre stable, indépendant de l'ordre de lecture.
        let tied = [event(id: "b"), event(id: "a")]
        XCTAssertEqual(FallbackSummary.make(events: tied, period: .all).recent.map(\.id), ["a", "b"])
    }

    func testNoFallbacksHasZeroCountsAndNoRoutes() {
        let summary = FallbackSummary.make(events: [], period: .all)
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.successes, 0)
        XCTAssertEqual(summary.failures, 0)
        XCTAssertEqual(summary.afterFailureCount, 0)
        XCTAssertEqual(summary.servicePausedCount, 0)
        XCTAssertTrue(summary.routes.isEmpty)
        XCTAssertTrue(summary.recent.isEmpty)
        for stage in FallbackStage.allCases { XCTAssertEqual(summary.count(for: stage), 0) }
    }

    func testTranscriptionFactoryRetainsFallbackMetadata() {
        let metadata = APIFallback(fromAPI: .xaiStreaming, stage: .transcription, reason: .requestFailed)
        let event = UsageEvent.transcription(
            provider: .openAI, streaming: false, model: "test-model", audioSeconds: 2, fallback: metadata
        )
        XCTAssertEqual(event.fallback, metadata)
        XCTAssertEqual(event.api, .openAIFile)
    }

    func testStoreRoundTripsSuccessfulAndFailedFallbacksWithoutInventingMetadata() throws {
        try withTemporaryDatabase { path in
            var store: HistoryStore? = try HistoryStore(path: path)
            let started = store!.fallbackTrackingStartedAt
            let calls = [
                event(),
                event(from: .deepSeekCleanup, to: .xaiCleanup, stage: .correction, reason: .servicePaused, succeeded: false),
                UsageEvent(createdAt: now, api: .xaiFile, model: "test-model", costUSD: nil)
            ]
            for call in calls { try store!.insertUsage(call) }
            store = nil
            let reopened = try HistoryStore(path: path)
            let loaded = try reopened.usageEvents()
            XCTAssertEqual(loaded.count, calls.count)
            for call in calls { XCTAssertEqual(loaded.first { $0.id == call.id }, call) }
            XCTAssertEqual(reopened.fallbackTrackingStartedAt, started)
        }
    }

    func testOldDatabaseMigrationPreservesRecordsUsageAndTrackingStartOnRepeatedOpen() throws {
        try withTemporaryDatabase { path in
            try executeSQL(
                """
                CREATE TABLE dictations (
                    id TEXT PRIMARY KEY, created_at REAL NOT NULL, final_text TEXT NOT NULL,
                    raw_text TEXT NOT NULL, duration_seconds REAL NOT NULL, word_count INTEGER NOT NULL,
                    provider TEXT NOT NULL, model TEXT NOT NULL, target_app TEXT, target_bundle TEXT,
                    usage_category TEXT, insertion_status TEXT NOT NULL, audio_path TEXT, audio_expires_at REAL
                );
                INSERT INTO dictations VALUES ('old-record', 1700000000, 'Texte de test.', 'Texte de test.',
                    3, 3, 'xai', 'test-model', NULL, NULL, NULL, 'inserted', NULL, NULL);
                CREATE TABLE api_usage (
                    id TEXT PRIMARY KEY, created_at REAL NOT NULL, api TEXT NOT NULL, model TEXT NOT NULL,
                    audio_seconds REAL NOT NULL, input_tokens INTEGER NOT NULL, cached_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL, cost_usd REAL, latency_ms INTEGER NOT NULL, succeeded INTEGER NOT NULL
                );
                INSERT INTO api_usage VALUES ('old-usage', 1700000000, 'openai.stt.file', 'test-model',
                    3, 0, 0, 0, 0.012, 325, 1);
                """, at: path
            )
            let before = Date()
            var migrated: HistoryStore? = try HistoryStore(path: path)
            let trackingStart = migrated!.fallbackTrackingStartedAt
            XCTAssertGreaterThanOrEqual(trackingStart.timeIntervalSince1970, before.timeIntervalSince1970 - 0.001)
            XCTAssertLessThanOrEqual(trackingStart, Date())
            let records = try migrated!.dictations()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.id, "old-record")
            XCTAssertEqual(records.first?.finalText, "Texte de test.")
            let oldCalls = try migrated!.usageEvents()
            XCTAssertEqual(oldCalls.count, 1)
            XCTAssertNil(oldCalls.first?.fallback)
            XCTAssertEqual(oldCalls.first?.costUSD, 0.012)
            XCTAssertEqual(oldCalls.first?.latencyMs, 325)
            XCTAssertEqual(FallbackSummary.make(events: oldCalls, period: .all).total, 0)
            let newCall = event()
            try migrated!.insertUsage(newCall)
            migrated = nil
            for _ in 0..<2 {
                let reopened = try HistoryStore(path: path)
                XCTAssertEqual(reopened.fallbackTrackingStartedAt, trackingStart)
                XCTAssertEqual(try reopened.dictations(), records)
                let calls = try reopened.usageEvents()
                XCTAssertEqual(calls.count, 2)
                XCTAssertEqual(calls.first { $0.id == "old-usage" }, oldCalls.first)
                XCTAssertEqual(calls.first { $0.id == newCall.id }, newCall)
            }
        }
    }

    func testPartialOrUnknownFallbackMetadataIsNotCounted() throws {
        try withTemporaryDatabase { path in
            var store: HistoryStore? = try HistoryStore(path: path)
            try store!.insertUsage(event(id: "incomplete"))
            try store!.insertUsage(event(id: "unknown"))
            store = nil
            try executeSQL(
                """
                UPDATE api_usage SET fallback_reason = NULL WHERE id = 'incomplete';
                UPDATE api_usage SET fallback_stage = 'future-stage' WHERE id = 'unknown';
                """, at: path
            )
            let reopened = try HistoryStore(path: path)
            let calls = try reopened.usageEvents()
            XCTAssertEqual(calls.count, 2)
            XCTAssertTrue(calls.allSatisfy { $0.fallback == nil })
            XCTAssertEqual(FallbackSummary.make(events: calls, period: .all).total, 0)
        }
    }

    private func withTemporaryDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-fallback-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("history.sqlite").path)
    }

    private func executeSQL(_ sql: String, at path: String) throws {
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
