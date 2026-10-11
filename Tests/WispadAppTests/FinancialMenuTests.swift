import Foundation
import Testing
@testable import WispadApp
import WispadCore

@MainActor
struct FinancialMenuTests {
    @Test func menuCountsTodaysCallsAndMarksUnknownCosts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-financial-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in nil }
        let model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
        // Un appel plus ancien ne compte pas dans le total du jour.
        model.recordUsage(UsageEvent(createdAt: Date().addingTimeInterval(-86_400 * 2), api: .xaiFile, model: "fixture", costUSD: 99))
        model.recordUsage(UsageEvent(api: .xaiFile, model: "fixture", costUSD: 0.001))
        func title() throws -> String {
            try #require(StatusMenu.items(model: model, target: nil).first { $0.title.hasPrefix("Aujourd'hui :") }).title
        }
        #expect(try title().contains(MoneyFormat.usd(0.001)))
        #expect(try title().contains("estimés"))
        #expect(try !title().contains("minimum"))
        model.recordUsage(UsageEvent(api: .deepSeekCleanup, model: "fixture", costUSD: nil, succeeded: false))
        #expect(try title().contains("≥ " + MoneyFormat.usd(0.001)))
        #expect(try title().contains("minimum"))
    }
}
