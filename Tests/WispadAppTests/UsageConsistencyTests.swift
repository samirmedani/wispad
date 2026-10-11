import Foundation
import SQLite3
import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
struct UsageConsistencyTests {
    private let now = Date(timeIntervalSince1970: 1_790_942_400)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func event(id: String = UUID().uuidString, at date: Date? = nil, api: UsageAPI = .deepSeekCleanup, cost: Double? = 0.01) -> UsageEvent {
        UsageEvent(id: id, createdAt: date ?? now, api: api, model: "fixture", costUSD: cost)
    }

    @Test func recentCallsAndTotalShareTheSelectedPeriod() {
        let today = [event(at: now), event(at: calendar.startOfDay(for: now))]
        let older = (1...20).map { event(at: calendar.startOfDay(for: now).addingTimeInterval(-Double($0))) }
        let all = today + older
        let displayed = UsagePresentation.events(all, for: .today, now: now, calendar: calendar)
        let summary = UsageSummary.make(events: all, period: .today, now: now, calendar: calendar)

        #expect(Array(displayed.prefix(15)) == today)
        #expect(summary.rows.reduce(0) { $0 + $1.requests } == displayed.count)
        #expect(abs(summary.totalUSD - displayed.reduce(0) { $0 + ($1.costUSD ?? 0) }) < 1e-9)
        #expect(UsagePresentation.events(all, for: .all, now: now, calendar: calendar) == all)
    }

    @Test(arguments: [StatsPeriod.days7, .days30])
    func recentCallsRespectTheRollingPeriodBoundary(period: StatsPeriod) {
        let start = period.startDate(now: now, calendar: calendar)!
        let boundary = event(at: start)
        let events = [event(at: start.addingTimeInterval(-1)), boundary]
        #expect(UsagePresentation.events(events, for: period, now: now, calendar: calendar) == [boundary])
    }

    @Test func olderCallsShowTheirDateRatherThanOnlyTheirTime() {
        #expect(!UsagePresentation.showsDate(now, now: now, calendar: calendar))
        #expect(!UsagePresentation.showsDate(calendar.startOfDay(for: now), now: now, calendar: calendar))
        #expect(UsagePresentation.showsDate(calendar.startOfDay(for: now).addingTimeInterval(-1), now: now, calendar: calendar))
    }

    @Test func unknownCostsAreMarkedOnlyForAffectedProviders() {
        let calls = [
            event(api: .xaiStreaming, cost: 0.02),
            event(api: .deepSeekCleanup, cost: nil),
            event(api: .openAICleanup, cost: 0.03),
            event(api: .typesafeJudge, cost: nil)
        ]
        let summary = UsageSummary.make(events: calls, period: .all)
        #expect(UsagePresentation.amount(summary.totalUSD, incomplete: summary.hasUnpricedCalls).hasPrefix("≥ "))
        #expect(UsagePresentation.providerAmount(summary, providers: ["xAI"]) == MoneyFormat.usd(0.02))
        #expect(UsagePresentation.providerAmount(summary, providers: ["DeepSeek"]) == "≥ " + MoneyFormat.usd(0))
        #expect(UsagePresentation.providerAmount(summary, providers: ["OpenAI", "TypeSafe"]) == "≥ " + MoneyFormat.usd(0.03))
    }

    @Test func missingStorageMarksKnownCostsAsMinimums() {
        let summary = UsageSummary.make(events: [event(cost: 0.5)], period: .all)
        #expect(UsagePresentation.providerAmount(summary, providers: ["DeepSeek"]) == MoneyFormat.usd(0.5))
        #expect(UsagePresentation.providerAmount(summary, providers: ["DeepSeek"], storageIncomplete: true).hasPrefix("≥ "))
    }

    @Test func missingTokenCountersAreNotDisplayedAsKnownZeros() {
        #expect(UsagePresentation.quantities(event(cost: nil)) == "Compteurs indisponibles")
        #expect(UsagePresentation.quantities(event(cost: 0)) == "0 → 0 jetons")
        var knownCounters = event(cost: nil)
        knownCounters.tokens = TokenUsage(input: 10, cachedInput: 2, output: 3)
        #expect(UsagePresentation.quantities(knownCounters) == "12 → 3 jetons")
        var audio = event(api: .xaiStreaming, cost: nil)
        audio.audioSeconds = 12
        #expect(UsagePresentation.quantities(audio) == UsageText.audio(12))
    }

    @Test func recordingTheSameCallTwiceDoesNotIncreaseAnyTotal() throws {
        try withModel { model, _ in
            let first = event(id: "same-call")
            let older = event(id: "older", at: now.addingTimeInterval(-10))
            model.recordUsage(first)
            model.recordUsage(older)
            model.recordUsage(first)

            let saved = try model.store.usageEvents()
            #expect(model.usage == [first, older])
            #expect(saved.count == 2)
            #expect(model.unsavedUsageCount == 0)
            #expect(model.usageStorageWarning == nil)
            #expect(abs(model.usageSummary(for: .all).totalUSD - 0.02) < 1e-9)
            model.reload()
            #expect(model.usage == [first, older])
        }
    }

    @Test func existingSavedIDKeepsItsOriginalAmountWithoutAFalseSaveFailure() throws {
        try withModel { model, _ in
            let stored = event(id: "already-saved", cost: 0.01)
            try model.store.insertUsage(stored)
            model.recordUsage(event(id: stored.id, cost: 99))

            let saved = try model.store.usageEvents()
            #expect(model.usage == [stored])
            #expect(saved == [stored])
            #expect(model.unsavedUsageCount == 0)
            #expect(model.usageStorageWarning == nil)
        }
    }

    @Test func failedSaveIsVisibleSurvivesReloadAndCanBeRetriedWithoutDoubleCounting() throws {
        try withModel { model, path in
            try executeSQL(
                "CREATE TRIGGER reject_usage BEFORE INSERT ON api_usage BEGIN SELECT RAISE(FAIL, 'fixture rejection'); END;",
                path: path
            )
            let call = event(id: "pending")
            model.recordUsage(call)
            model.recordUsage(call)

            let beforeRetry = try model.store.usageEvents()
            #expect(model.usage == [call])
            #expect(model.unsavedUsageCount == 1)
            #expect(model.usageStorageWarning?.contains("non sauvegardé") == true)
            #expect(beforeRetry.isEmpty)
            model.reload()
            #expect(model.usage == [call])
            #expect(model.unsavedUsageCount == 1)

            try executeSQL("DROP TRIGGER reject_usage;", path: path)
            model.retrySavingUsage()
            model.retrySavingUsage()
            let afterRetry = try model.store.usageEvents()
            #expect(model.usage == [call])
            #expect(afterRetry == [call])
            #expect(model.unsavedUsageCount == 0)
            #expect(model.usageStorageWarning == nil)
        }
    }

    @Test func failedReadSignalsIncompleteTotalsUntilTheStoreRecovers() throws {
        try withModel { model, path in
            let call = event()
            model.recordUsage(call)
            try executeSQL("ALTER TABLE api_usage RENAME TO unavailable_usage;", path: path)
            model.reload()

            #expect(model.usage == [call])
            #expect(model.usageLoadFailed)
            #expect(model.usageStorageWarning?.contains("incomplets") == true)

            try executeSQL("ALTER TABLE unavailable_usage RENAME TO api_usage;", path: path)
            model.retrySavingUsage()
            #expect(model.usage == [call])
            #expect(!model.usageLoadFailed)
            #expect(model.usageStorageWarning == nil)
        }
    }

    private func withModel(_ body: (AppModel, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-usage-consistency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in nil }
        dependencies.refreshKeys = { false }
        dependencies.requestMicrophone = { false }
        let model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
        model.overlay.displaysPanel = false
        try body(model, directory.appendingPathComponent("wispad.sqlite").path)
    }

    private func executeSQL(_ sql: String, path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw StoreError.message("Ouverture de la base fictive impossible")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.message("Mutation de la base fictive impossible")
        }
    }
}
