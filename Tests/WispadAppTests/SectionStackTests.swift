import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import WispadApp
@testable import WispadCore

/// Fluidité de la fenêtre : écrans gardés en vie, aucun réveil de tous les écrans à chaque changement de section,
/// calculs de Consommation gardés tant que les appels ne changent pas.
@MainActor
@Suite(.serialized)
struct SectionStackTests {
    private final class Woken: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        var value: Bool { lock.withLock { fired } }
        func set() { lock.withLock { fired = true } }
    }

    private final class Counter {
        var built: [AppSection] = []
    }

    private func container(_ counter: Counter) -> SectionContainer {
        SectionContainer { section in
            counter.built.append(section)
            return AnyView(Text(section.title))
        }
    }

    @Test func aVisitedSectionIsNotRebuilt() {
        let counter = Counter()
        let stack = container(counter)
        stack.show(.home)
        stack.show(.history)
        stack.show(.home)
        stack.show(.history)
        #expect(counter.built == [.home, .history])
        #expect(stack.current == .history)
        // Un seul écran dans la fenêtre : l'autre est détaché, sans être détruit.
        #expect(stack.subviews.count == 1)
        #expect(stack.builtSections == [.home, .history])
    }

    @Test func goingToAnotherAppKeepsOnlyTheShownSection() {
        let counter = Counter()
        let stack = container(counter)
        for section in [AppSection.home, .usage, .settings] { stack.show(section) }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(stack.builtSections == [.settings])
        stack.show(.usage)
        #expect(counter.built == [.home, .usage, .settings, .usage])
    }

    @Test func eachArrivalIsAnnounced() {
        var shown: [AppSection] = []
        let stack = container(Counter())
        stack.onShow = { shown.append($0) }
        stack.show(.settings)
        stack.show(.settings)
        stack.show(.usage)
        stack.show(.settings)
        #expect(shown == [.settings, .usage, .settings])
    }

    private func model() throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-section-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.loadKey = { _ in nil }
        var settings = AppSettings()
        settings.onboardingCompleted = true
        return (try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies), directory)
    }

    @Test func changingSectionDoesNotWakeTheScreensThatReadSettings() throws {
        let (model, directory) = try model()
        defer { model.coordinator.cancel(); try? FileManager.default.removeItem(at: directory) }
        let woken = Woken()
        withObservationTracking { _ = model.settings } onChange: { woken.set() }
        model.selectedSection = .history
        #expect(!woken.value)
        // Toujours retrouvée au lancement suivant.
        #expect(model.settings.lastSection == .history)
    }

    @Test func usageFiguresFollowANewCall() throws {
        let (model, directory) = try model()
        defer { model.coordinator.cancel(); try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        #expect(model.usageEvents(for: .today, now: now).isEmpty)
        #expect(model.fallbackSummary(for: .today, now: now).total == 0)
        model.recordUsage(UsageEvent(api: .xaiFile, model: "fixture", costUSD: 0.001, succeeded: true,
                                     fallback: APIFallback(fromAPI: .openAIFile, stage: .transcription, reason: .requestFailed)))
        #expect(model.usageEvents(for: .today, now: now).count == 1)
        #expect(model.fallbackSummary(for: .today, now: now).total == 1)
        #expect(model.usageSummary(for: .today, now: now).totalUSD > 0)
    }
}
