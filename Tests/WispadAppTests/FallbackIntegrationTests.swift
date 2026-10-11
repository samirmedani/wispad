import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

enum FallbackStreamOutcome: Equatable, Sendable {
    case empty
    case text
    case startFailure
    case finishFailure
}

private final class FallbackTestAudio: AudioRecording, @unchecked Sendable {
    var onPCM: (@Sendable (Data) -> Void)?
    let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    var startGate: AsyncResult<Void>?
    var onStarting: (@Sendable () -> Void)?
    private var url: URL?

    func start(directory: URL) async throws -> URL {
        onStarting?()
        if let startGate { try await startGate.value() }
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        let silence = Data(repeating: 0, count: 16_000 * 2 * 2)
        var wav = WAVHeader.make(dataBytes: silence.count, sampleRate: 16_000)
        wav.append(silence)
        try wav.write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) { (url, 2) }
}

private final class FallbackTestStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    let outcome: FallbackStreamOutcome
    var startGate: AsyncResult<Void>?
    var onStarting: (@Sendable () -> Void)?
    var onStarted: (@Sendable () -> Void)?

    init(outcome: FallbackStreamOutcome) { self.outcome = outcome }

    func start() async throws {
        onStarting?()
        // Ce faux transport termine même après cancel(), pour simuler une réponse réseau tardive.
        if let startGate { try await startGate.value() }
        if outcome == .startFailure { throw URLError(.cannotConnectToHost) }
        onStarted?()
    }

    func send(_ data: Data) {}

    func finish() async throws -> StreamFinish {
        if outcome == .finishFailure { throw URLError(.networkConnectionLost) }
        let text = outcome == .text ? "Phrase fictive du flux." : ""
        return StreamFinish(text: text, endingFinalized: true)
    }

    func cancel() {}
}

/// Micro, réseau, clés, insertion et sons simulés ; seule la base temporaire est réellement utilisée.
@MainActor
private final class FallbackFixture {
    let directory: URL
    let audio = FallbackTestAudio()
    let stream: FallbackTestStream
    var streamedProviders: [ProviderID] = []
    var fileProviders: [ProviderID] = []
    var inserted = 0
    var model: AppModel!

    init(
        streamOutcome: FallbackStreamOutcome = .empty,
        failedFileProviders: Set<ProviderID> = [],
        hasSecondaryKey: Bool = true
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-fallback-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stream = FallbackTestStream(outcome: streamOutcome)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { account in
            if account == ProviderID.xai.rawValue { return "fixture-xai" }
            if account == ProviderID.openAI.rawValue, hasSecondaryKey { return "fixture-openai" }
            return nil
        }
        dependencies.saveKey = { _, _ in true }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        dependencies.captureContext = {
            let context = DictationContext()
            context.pid = 4_242
            return (context, Task { nil })
        }
        dependencies.makeCapture = { [audio] in audio }
        dependencies.makeSession = { [weak self, stream] speech in
            self?.streamedProviders.append(speech.provider)
            return stream
        }
        dependencies.transcribe = { [weak self] _, speech in
            self?.fileProviders.append(speech.provider)
            if failedFileProviders.contains(speech.provider) { throw URLError(.timedOut) }
            return "Phrase fictive du fichier."
        }
        dependencies.clean = { text, _, _, _ in CleanupOutcome(text: text) }
        dependencies.playCue = { _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { [weak self] _, _, shouldProceed in
            guard shouldProceed() else { return .cancelled }
            self?.inserted += 1
            return .inserted
        }
        var settings = AppSettings()
        settings.cleanupEnabled = false
        settings.verifyWithFile = false
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    var fallbacks: [UsageEvent] { model.usage.filter { $0.fallback != nil } }
    var summary: FallbackSummary { FallbackSummary.make(events: model.usage, period: .all) }

    func pausePrimary() {
        for _ in 0..<ServiceHealth.failuresBeforePause {
            model.health.record(ServiceHealth.voice(.xai), succeeded: false)
        }
    }

    func dictate() async {
        await model.coordinator.begin(.toggle)
        await model.coordinator.end()
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct FallbackIntegrationTests {
    @Test(arguments: [FallbackStreamOutcome.empty, .startFailure, .finishFailure])
    func fileRetryWithSameProviderDoesNotCountAsFallback(outcome: FallbackStreamOutcome) async throws {
        let f = try FallbackFixture(streamOutcome: outcome)
        defer { f.dispose() }
        await f.dictate()

        #expect(f.streamedProviders == [.xai])
        #expect(f.fileProviders == [.xai])
        #expect(f.inserted == 1)
        #expect(f.model.usage.contains { $0.api == .xaiFile && $0.succeeded })
        #expect(f.fallbacks.isEmpty)
        #expect(f.summary.total == 0)
    }

    @Test func failedPrimaryFileCountsSuccessfulSecondaryAndSurvivesReload() async throws {
        let f = try FallbackFixture(failedFileProviders: [.xai])
        defer { f.dispose() }
        await f.dictate()

        #expect(f.fileProviders == [.xai, .openAI])
        #expect(f.inserted == 1)
        #expect(f.fallbacks.count == 1)
        let event = try #require(f.fallbacks.first)
        #expect(event.api == .openAIFile)
        #expect(event.succeeded)
        #expect(event.fallback == APIFallback(fromAPI: .xaiFile, stage: .transcription, reason: .requestFailed))
        #expect(f.summary.total == 1 && f.summary.successes == 1 && f.summary.failures == 0)
        #expect(f.summary.afterFailureCount == 1 && f.summary.servicePausedCount == 0)

        let saved = try f.model.store.usageEvents().filter { $0.fallback != nil }
        #expect(saved.count == 1)
        #expect(saved.first?.id == event.id)
        #expect(saved.first?.fallback == event.fallback)
        f.model.reload()
        #expect(f.fallbacks.count == 1)
        #expect(f.fallbacks.first?.id == event.id)
        #expect(f.fallbacks.first?.fallback == event.fallback)
        #expect(f.summary.total == 1)
    }

    @Test func failedSecondaryStillCountsTheFallbackAttempt() async throws {
        let f = try FallbackFixture(failedFileProviders: [.xai, .openAI])
        defer { f.dispose() }
        await f.dictate()

        #expect(f.fileProviders == [.xai, .openAI])
        #expect(f.inserted == 0)
        #expect(f.fallbacks.count == 1)
        let event = try #require(f.fallbacks.first)
        #expect(event.api == .openAIFile)
        #expect(!event.succeeded)
        #expect(event.fallback == APIFallback(fromAPI: .xaiFile, stage: .transcription, reason: .requestFailed))
        #expect(f.summary.total == 1 && f.summary.successes == 0 && f.summary.failures == 1)
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.transcriptionFailed.rawValue)
    }

    @Test(arguments: [FallbackStreamOutcome.text, .empty])
    func pausedPrimaryCountsOnlyOneSwitchEvenWhenSecondaryRetriesItsFile(outcome: FallbackStreamOutcome) async throws {
        let f = try FallbackFixture(streamOutcome: outcome)
        defer { f.dispose() }
        f.pausePrimary()
        await f.dictate()

        #expect(f.streamedProviders == [.openAI])
        #expect(f.fileProviders == (outcome == .empty ? [.openAI] : []))
        #expect(f.inserted == 1)
        #expect(f.fallbacks.count == 1)
        let event = try #require(f.fallbacks.first)
        #expect(event.api == .openAIStreaming)
        #expect(event.fallback == APIFallback(fromAPI: .xaiStreaming, stage: .transcription, reason: .servicePaused))
        #expect(f.summary.total == 1)
        #expect(f.summary.afterFailureCount == 0 && f.summary.servicePausedCount == 1)
        #expect(f.model.usage.filter { $0.api == .openAIFile }.allSatisfy { $0.fallback == nil })
    }

    @Test(arguments: [false, true])
    func missingSecondaryKeyNeverCountsAnUnattemptedFallback(primaryPaused: Bool) async throws {
        let f = try FallbackFixture(failedFileProviders: [.xai], hasSecondaryKey: false)
        defer { f.dispose() }
        if primaryPaused { f.pausePrimary() }
        await f.dictate()

        #expect(f.streamedProviders == [.xai])
        #expect(f.fileProviders == [.xai])
        #expect(f.inserted == 0)
        #expect(f.fallbacks.isEmpty)
        #expect(f.summary.total == 0)
    }

    @Test func cancellationBeforeStreamCreationDoesNotCountPlannedFallback() async throws {
        let entered = AsyncResult<Void>()
        let releaseAudio = AsyncResult<Void>()
        let f = try FallbackFixture()
        defer { f.dispose() }
        f.pausePrimary()
        f.audio.startGate = releaseAudio
        f.audio.onStarting = { entered.resolve(.success(())) }
        let begin = Task { await f.model.coordinator.begin(.toggle) }
        try await entered.value()
        f.model.coordinator.cancel()
        releaseAudio.resolve(.success(()))
        await begin.value

        #expect(f.model.coordinator.phase == .idle)
        #expect(f.streamedProviders.isEmpty && f.fileProviders.isEmpty)
        #expect(f.model.usage.isEmpty)
        #expect(f.summary.total == 0)
    }

    @Test func cancellationDuringFallbackHandshakeCountsOneFailureDespiteLateStartSuccess() async throws {
        let entered = AsyncResult<Void>()
        let releaseStream = AsyncResult<Void>()
        let handshakeFinished = AsyncResult<Void>()
        let f = try FallbackFixture()
        defer {
            releaseStream.resolve(.success(()))
            f.dispose()
        }
        f.pausePrimary()
        f.stream.startGate = releaseStream
        f.stream.onStarting = { entered.resolve(.success(())) }
        f.stream.onStarted = { handshakeFinished.resolve(.success(())) }
        await f.model.coordinator.begin(.toggle)
        try await entered.value()
        f.model.coordinator.cancel()

        #expect(f.model.coordinator.phase == .idle)
        #expect(f.streamedProviders == [.openAI] && f.fileProviders.isEmpty)
        #expect(f.model.usage.count == 1 && f.fallbacks.count == 1)
        let event = try #require(f.fallbacks.first)
        #expect(event.api == .openAIStreaming)
        #expect(!event.succeeded)
        #expect(event.fallback == APIFallback(fromAPI: .xaiStreaming, stage: .transcription, reason: .servicePaused))
        #expect(f.summary.total == 1 && f.summary.failures == 1 && f.summary.successes == 0)

        // Le handshake reprend sans erreur alors que sa capture a déjà été annulée et comptabilisée.
        releaseStream.resolve(.success(()))
        try await handshakeFinished.value()
        await Task.yield()
        f.model.coordinator.cancel()
        await f.model.coordinator.end()
        #expect(f.model.usage == [event])
        #expect(f.fileProviders.isEmpty && f.inserted == 0)
        let stored = try f.model.store.usageEvents()
        #expect(stored.count == 1)
        #expect(stored.first?.id == event.id)
        #expect(stored.first?.succeeded == false)
        #expect(stored.first?.fallback == event.fallback)
    }
}
