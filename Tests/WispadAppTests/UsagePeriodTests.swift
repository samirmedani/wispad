import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Une seule vue de la consommation : tous les appels comptent, filtrés par la seule période.
@MainActor
struct UsagePeriodTests {
    private let reference = Date(timeIntervalSince1970: 1_791_028_800)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func event(id: String = UUID().uuidString, at date: Date, api: UsageAPI = .deepSeekCleanup, cost: Double? = 0.01) -> UsageEvent {
        UsageEvent(id: id, createdAt: date, api: api, model: "fixture", costUSD: cost)
    }

    @Test(arguments: StatsPeriod.allCases)
    func onlyThePeriodFiltersCalls(period: StatsPeriod) {
        let now = calendar.startOfDay(for: reference).addingTimeInterval(12 * 3_600)
        let start = period.startDate(now: now, calendar: calendar)
        let inside = [event(at: now), event(at: start ?? now.addingTimeInterval(-86_400 * 400))]
        let outside = event(at: (start ?? now).addingTimeInterval(-86_400))
        let expected = period == .all ? inside + [outside] : inside
        #expect(UsagePresentation.events(inside + [outside], for: period, now: now, calendar: calendar) == expected)
    }

    @Test func allRecordedCallsCount() throws {
        try withModel { model in
            let recent = event(at: reference, api: .xaiStreaming, cost: 0.1)
            let old = event(at: reference.addingTimeInterval(-86_400 * 90), api: .deepSeekCleanup, cost: 2)
            model.recordUsage(recent)
            // Un appel plus ancien enregistré après coup prend sa place dans l'ordre chronologique.
            model.recordUsage(old)
            let summary = model.usageSummary(for: .all)
            #expect(abs(summary.totalUSD - 2.1) < 1e-9)
            #expect(model.usageEvents(for: .all) == [recent, old])
        }
    }

    private func withModel(_ body: (AppModel) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-usage-period-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in nil }
        dependencies.refreshKeys = { false }
        dependencies.requestMicrophone = { false }
        let model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
        model.overlay.displaysPanel = false
        try body(model)
    }
}
