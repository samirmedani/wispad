import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
private final class HistoryRenderLog {
    var ids = Set<String>()
}

/// Toutes les données sont fictives et restent en mémoire ou dans un dossier temporaire.
@MainActor
@Suite(.serialized)
struct HistoryPerformanceTests {
    @Test func initialHistoryRenderingStaysBoundedWhenOneDayGrows() async throws {
        // Un millier de dictées dans UNE journée : ce cas dévoile une pile journalière
        // non paresseuse même quand son conteneur global est un LazyVStack.
        let usualCount = try await renderedRowCount(total: 91)
        let largeCount = try await renderedRowCount(total: 1_000)

        #expect(usualCount > 0)
        #expect(usualCount < 40)
        #expect(largeCount > 0)
        #expect(largeCount < 40)
        #expect(abs(largeCount - usualCount) <= 8)
    }

    @Test func daySectionsKeepEveryRecordAndItsOrderAcrossMidnight() throws {
        let calendar = Calendar.current
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2)))
        let previousDay = try #require(calendar.date(byAdding: .day, value: -1, to: day))
        let records = [
            record(id: "newest", at: day.addingTimeInterval(60)),
            record(id: "midnight", at: day),
            record(id: "before-midnight", at: day.addingTimeInterval(-1)),
            record(id: "previous-midnight", at: previousDay),
        ]

        let groups = DayGroup.make(records)

        #expect(groups.map(\.day) == [day, previousDay])
        #expect(groups.map { $0.records.map(\.id) } == [
            ["newest", "midnight"], ["before-midnight", "previous-midnight"],
        ])
        #expect(groups.flatMap(\.records) == records)
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test func removingLastRecordOfADayDropsOnlyThatSection() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let older = try #require(calendar.date(byAdding: .day, value: -3, to: today))
        let records = [
            record(id: "today", at: today.addingTimeInterval(60)),
            record(id: "yesterday", at: yesterday.addingTimeInterval(60)),
            record(id: "older", at: older.addingTimeInterval(60)),
        ]
        let before = DayGroup.make(records)
        let after = DayGroup.make(records.filter { $0.id != "yesterday" })

        #expect(after.map(\.id) == [before[0].id, before[2].id])
        #expect(after.flatMap(\.records).map(\.id) == ["today", "older"])
        #expect(DayGroup.make([]).isEmpty)
    }

    private func record(id: String, at date: Date) -> DictationRecord {
        DictationRecord(
            id: id,
            createdAt: date,
            finalText: "Phrase fictive pour vérifier l'historique.",
            rawText: "Phrase fictive pour vérifier l'historique.",
            durationSeconds: 3,
            wordCount: 6,
            provider: "fixture",
            model: "fixture",
            insertionStatus: InsertionStatus.inserted.rawValue
        )
    }

    private func renderedRowCount(total: Int) async throws -> Int {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispad-history-render-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in nil }
        dependencies.refreshKeys = { false }
        dependencies.requestMicrophone = { false }
        let model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
        model.overlay.displaysPanel = false
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        model.history = (0..<total).map { index in
            record(id: "fixture-\(index)", at: noon.addingTimeInterval(-Double(index)))
        }
        let log = HistoryRenderLog()
        let host = NSHostingView(rootView: HistoryView()
            .environment(model)
            .environment(\.historyRowDidRender, { log.ids.insert($0) }))
        let window = OffscreenWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 980, height: 660),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        // La fenêtre n'est jamais présentée. On laisse passer les mises à jour SwiftUI,
        // sans mesurer de durée : seule la quantité de travail est l'invariant testé.
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        host.layoutSubtreeIfNeeded()
        return log.ids.count
    }
}
