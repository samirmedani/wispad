import Foundation
import Observation
import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ProfileTopicsControllerTests {
    private func fixture() throws -> (AppModel, UserDefaults, URL, String) {
        let suite = "wispad-topic-controller-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.loadKey = { _ in "fixture-only" }
        dependencies.isOnline = { true }
        var settings = AppSettings()
        settings.profileCards.brain = true
        settings.profileTopicsEnabled = true
        settings.profileTopicsWeekly = true
        let model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
        return (model, defaults, directory, suite)
    }

    private func seed(_ defaults: UserDefaults, now: Date) throws {
        let previous = TopicAnalysis(topics: [], analyzedAt: now.addingTimeInterval(-8 * 86_400), dictationCount: 1,
                                     newestDictation: now.addingTimeInterval(-9 * 86_400), service: "fixture", costUSD: 0)
        defaults.set(try JSONEncoder().encode(previous), forKey: "profileTopicAnalysis.v1")
    }

    private func newRecord(now: Date) -> DictationRecord {
        .init(id: "fiction", createdAt: now.addingTimeInterval(-3600), finalText: "Une recette de soupe", rawText: "",
              durationSeconds: 3, wordCount: 4, provider: "fixture", model: "fixture", insertionStatus: "inserted")
    }

    private func settled(_ controller: ProfileTopicsController) async throws {
        await ProfileTopicsCompletionWaiter(controller: controller).wait()
        try Task.checkCancellation()
        #expect(!controller.isRunning)
    }

    @Test func automaticFailureIsCountedAndBacksOffAcrossRestart() async throws {
        let (model, defaults, directory, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        try seed(defaults, now: now)
        model.history = [newRecord(now: now)]
        let calls = ProfileAnalysisCalls()
        let analyze: ProfileTopicsController.Analyze = { _, _, _, _, _, onUsage, _ in
            await calls.called()
            await onUsage(UsageEvent(api: .deepSeekCleanup, model: "fixture", costUSD: 0.001))
            throw SpeechError.message("Échec fictif")
        }
        let controller = ProfileTopicsController(defaults: defaults, analyze: analyze)
        controller.runIfDue(model: model, now: now)
        try await settled(controller)
        #expect(await calls.count == 1)
        #expect(model.usage.count == 1)
        #expect(try model.store.usageEvents().count == 1)
        for minute in 1...60 { controller.runIfDue(model: model, now: now.addingTimeInterval(Double(minute) * 60)) }
        #expect(await calls.count == 1)
        let restarted = ProfileTopicsController(defaults: defaults, analyze: analyze)
        #expect(!restarted.canAttemptAutomatically(at: now.addingTimeInterval(6 * 3600 - 1)))
        restarted.runIfDue(model: model, now: now.addingTimeInterval(6 * 3600))
        try await settled(restarted)
        #expect(await calls.count == 2)
        let again = ProfileTopicsController(defaults: defaults, analyze: analyze)
        #expect(!again.canAttemptAutomatically(at: now.addingTimeInterval(30 * 3600 - 1)))
        #expect(again.canAttemptAutomatically(at: now.addingTimeInterval(30 * 3600)))
    }

    @Test func cancelledTaskKeepsItsSlotAndLateUsageWithoutRestoringForgottenAnalysis() async throws {
        let (model, defaults, directory, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        try seed(defaults, now: now)
        model.history = [newRecord(now: now)]
        let started = AsyncResult<Void>()
        let release = AsyncResult<Void>()
        let calls = ProfileAnalysisCalls()
        let controller = ProfileTopicsController(defaults: defaults, analyze: { _, _, _, _, _, onUsage, progress in
            await calls.called()
            started.resolve(.success(()))
            try await release.value()
            await onUsage(UsageEvent(id: "late-fiction", api: .deepSeekCleanup, model: "fixture", costUSD: 0.001))
            await progress(1, 1)
            return TopicAnalysis(topics: [], analyzedAt: now, dictationCount: 1, newestDictation: now,
                                 service: "fixture", costUSD: 0.001)
        })
        controller.start(model: model, portrait: false, stats: "", full: true, now: now)
        try await started.value()
        controller.forget()
        #expect(controller.isRunning)
        controller.start(model: model, portrait: false, stats: "", full: true)
        #expect(await calls.count == 1)
        release.resolve(.success(()))
        try await settled(controller)
        #expect(controller.analysis == nil)
        #expect(defaults.data(forKey: "profileTopicAnalysis.v1") == nil)
        #expect(controller.state == .idle)
        #expect(model.usage.map(\.id) == ["late-fiction"])
        #expect(try model.store.usageEvents().count == 1)
        let restarted = ProfileTopicsController(defaults: defaults)
        #expect(!restarted.canAttemptAutomatically(at: now.addingTimeInterval(60)))
    }

    @Test func manualSuccessResetsTheBackoffAndAccountsEachEventOnce() async throws {
        let (model, defaults, directory, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        try seed(defaults, now: now)
        model.history = [newRecord(now: now)]
        let failure = ProfileTopicsController(defaults: defaults, analyze: { _, _, _, _, _, _, _ in
            throw SpeechError.message("Échec fictif")
        })
        failure.start(model: model, portrait: false, stats: "", full: true, now: now)
        try await settled(failure)
        let success = ProfileTopicsController(defaults: defaults, analyze: { _, _, _, _, _, onUsage, _ in
            let event = UsageEvent(id: "paid-fiction", api: .deepSeekCleanup, model: "fixture", costUSD: 0.001)
            await onUsage(event)
            return TopicAnalysis(topics: [], analyzedAt: now, dictationCount: 1, newestDictation: now,
                                 service: "fixture", costUSD: 0.001, processedDictationIDs: ["fiction"])
        })
        #expect(!success.canAttemptAutomatically(at: now))
        success.start(model: model, portrait: false, stats: "", full: true, now: now)
        try await settled(success)
        let restarted = ProfileTopicsController(defaults: defaults)
        #expect(restarted.canAttemptAutomatically(at: now))
        #expect(restarted.analysis?.processedDictationIDs == ["fiction"])
        #expect(model.usage.map(\.id) == ["paid-fiction"])
        #expect(try model.store.usageEvents().count == 1)
    }

    @Test func cancellingTheWaitDoesNotLeaveItsContinuationSuspended() async throws {
        let (model, defaults, directory, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let started = AsyncResult<Void>()
        let release = AsyncResult<Void>()
        let controller = ProfileTopicsController(defaults: defaults, analyze: { _, _, _, _, _, _, _ in
            started.resolve(.success(()))
            try await release.value()
            return TopicAnalysis(topics: [], analyzedAt: Date(), dictationCount: 0, newestDictation: nil,
                                 service: "fixture", costUSD: 0)
        })
        controller.start(model: model, portrait: false, stats: "", full: true)
        try await started.value()
        let waiting = Task { try await settled(controller) }
        await Task.yield()
        waiting.cancel()
        var cancelled = false
        do { try await waiting.value } catch is CancellationError { cancelled = true }
        #expect(cancelled)
        #expect(controller.isRunning)
        release.resolve(.success(()))
        try await settled(controller)
    }

    /// Cerveau masqué dans Personnaliser : la mise à jour de chaque semaine ne relit rien, même due ; affiché, elle part.
    @Test func hiddenBrainSkipsTheWeeklyUpdate() async throws {
        let (model, defaults, directory, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        try seed(defaults, now: now)
        model.history = [newRecord(now: now)]
        model.settings.profileCards.brain = false
        let calls = ProfileAnalysisCalls()
        let controller = ProfileTopicsController(defaults: defaults, analyze: { _, _, _, _, _, _, _ in
            await calls.called()
            throw SpeechError.message("Échec fictif")
        })
        controller.runIfDue(model: model, now: now)
        #expect(!controller.isRunning)
        model.settings.profileCards.brain = true
        controller.runIfDue(model: model, now: now)
        try await settled(controller)
        #expect(await calls.count == 1)
    }

    /// « Sujets · IA » coupé : portrait et mise à jour de chaque semaine coupés, résultat effacé de ce Mac.
    @Test func turningTopicsOffErasesTheResult() throws {
        let (model, defaults, directory, suite) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try seed(defaults, now: Date())
        let controller = ProfileTopicsController(defaults: defaults)
        #expect(controller.analysis != nil)
        model.settings.profilePortraitEnabled = true
        controller.setEnabled(false, model: model)
        #expect(!model.settings.profileTopicsEnabled && !model.settings.profilePortraitEnabled && !model.settings.profileTopicsWeekly)
        #expect(controller.analysis == nil)
        #expect(defaults.data(forKey: "profileTopicAnalysis.v1") == nil)
    }
}

private actor ProfileAnalysisCalls {
    private(set) var count = 0
    func called() { count += 1 }
}

/// Attend la libération effective du créneau du contrôleur, même si le MainActor est chargé.
@MainActor
private final class ProfileTopicsCompletionWaiter {
    private let controller: ProfileTopicsController
    private var continuation: CheckedContinuation<Void, Never>?

    init(controller: ProfileTopicsController) { self.controller = controller }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { finish() } else { observe() }
            }
        } onCancel: {
            Task { @MainActor in self.finish() }
        }
    }

    private func observe() {
        guard continuation != nil else { return }
        let running = withObservationTracking {
            controller.isRunning
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if !running { finish() }
    }

    private func finish() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
