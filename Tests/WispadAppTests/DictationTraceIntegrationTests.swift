import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Frontières simulées : ni microphone réel, ni API, ni insertion dans une autre app.
private final class TraceTestAudio: AudioRecording, @unchecked Sendable {
    var onPCM: (@Sendable (Data) -> Void)?
    let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    var duration = 2.0
    private(set) var url: URL?

    func start(directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 128).write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) { (url, duration) }
}

private final class TraceTestStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    var text = ""
    var finishDelay: UInt64 = 0
    let ready = AsyncResult<Void>()

    func start() async throws { ready.resolve(.success(())) }
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish {
        if finishDelay > 0 { try await Task.sleep(nanoseconds: finishDelay) }
        return StreamFinish(text: text, endingFinalized: true)
    }
    func cancel() {}
}

private enum TraceInjectedError: Error, LocalizedError {
    case providerFailure
    var errorDescription: String? { "ERROR_PRIVATE_SENTINEL api-key-secret-placeholder transcript-placeholder" }
}

@MainActor
private final class TraceFixture {
    let directory: URL
    var captures: [TraceTestAudio] = []
    var streams: [TraceTestStream] = []
    var insertedTexts: [String] = []
    var fileProviders: [ProviderID] = []
    var streamText = ""
    var streamFinishDelay: UInt64 = 0
    var duration = 2.0
    var failedFileProviders: Set<ProviderID> = []
    var model: AppModel!

    init(configure: (inout AppDependencies) -> Void = { _ in }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-trace-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { "KEY_PRIVATE_SENTINEL_" + $0 }
        dependencies.saveKey = { _, _ in true }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        dependencies.captureContext = {
            let context = DictationContext()
            context.pid = 4_242
            context.appName = "CONTEXT_PRIVATE_SENTINEL"
            context.nearbyText = "CURSOR_PRIVATE_SENTINEL"
            return (context, Task { nil })
        }
        dependencies.makeCapture = { [weak self] in
            let audio = TraceTestAudio()
            audio.duration = self?.duration ?? 2
            self?.captures.append(audio)
            return audio
        }
        dependencies.makeSession = { [weak self] _ in
            let stream = TraceTestStream()
            stream.text = self?.streamText ?? ""
            stream.finishDelay = self?.streamFinishDelay ?? 0
            self?.streams.append(stream)
            return stream
        }
        dependencies.transcribe = { [weak self] _, speech in
            self?.fileProviders.append(speech.provider)
            if self?.failedFileProviders.contains(speech.provider) == true { throw TraceInjectedError.providerFailure }
            return "TRANSCRIPT_PRIVATE_SENTINEL"
        }
        dependencies.clean = { text, _, _, _ in CleanupOutcome(text: text) }
        dependencies.playCue = { _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { [weak self] text, _, allowed, _ in
            guard allowed() else { return .cancelled }
            self?.insertedTexts.append(text)
            return .inserted
        }
        configure(&dependencies)
        var settings = AppSettings()
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    func begin(_ mode: ListenMode = .toggle, pressedAt: Int? = nil) async throws {
        await model.coordinator.begin(mode, pressedAt: pressedAt)
        if let stream = streams.last { try await stream.ready.value() }
    }

    func dictate(_ mode: ListenMode = .toggle) async throws {
        try await begin(mode)
        await model.coordinator.end()
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct DictationTraceIntegrationTests {
    @Test func successfulStreamStoresExactCallsAndMeasuredStages() async throws {
        let cleanup = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.00001, latencyMs: 23)
        let f = try TraceFixture {
            $0.clean = { text, _, _, _ in
                try? await Task.sleep(nanoseconds: 25_000_000)
                return CleanupOutcome(text: text, usage: cleanup)
            }
            $0.insert = { _, _, allowed, _ in
                try? await Task.sleep(nanoseconds: 25_000_000)
                return allowed() ? .inserted : .cancelled
            }
        }
        defer { f.dispose() }
        f.streamText = "TRANSCRIPT_PRIVATE_SENTINEL"
        f.streamFinishDelay = 25_000_000
        // Vérification coupée : un flux réussi ne compte que le flux et la correction.
        f.model.settings.verifyWithFile = false
        try await f.begin(.pushToTalk, pressedAt: KeyboardTap.now() - 40)
        await f.model.coordinator.end()

        let record = try #require(f.model.history.first)
        let traces = try f.model.store.traces(dictationID: record.id)
        #expect(traces.count == 1)
        let trace = try #require(traces.first)
        #expect(trace.dictationID == record.id)
        #expect(trace.origin == .hold)
        #expect(trace.outcome == .inserted)
        #expect((try #require(trace.timings.microphoneMs)) >= 0)
        #expect((try #require(trace.timings.firstAudioMs)) >= 0)
        #expect((try #require(trace.timings.streamReadyMs)) >= 0)
        #expect((try #require(trace.timings.transcriptionMs)) >= 15)
        #expect((try #require(trace.timings.correctionMs)) >= 15)
        #expect((try #require(trace.timings.insertionMs)) >= 15)
        #expect((try #require(trace.timings.afterReleaseMs)) >= 45)
        #expect(trace.calls.map(\.api) == [.xaiStreaming, .deepSeekCleanup])
        #expect(trace.calls.allSatisfy { $0.succeeded })
        #expect(trace.calls.last?.id == cleanup.id)
        #expect(Set(trace.calls.map(\.id)) == Set(f.model.usage.map(\.id)))
        #expect(trace.calls.last?.latencyMs == 23)
        #expect(f.fileProviders.isEmpty)
        try expectPrivateFieldsAbsent(traces)
    }

    @Test func fileRetryAndCorrectionFallbackKeepEveryAttemptInOrder() async throws {
        let failed = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0, latencyMs: 34, succeeded: false)
        let correctionFallback = APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed)
        let relayed = UsageEvent(api: .openAICleanup, model: CleanupModel.openAIFallback, costUSD: 0.00002, latencyMs: 57, fallback: correctionFallback)
        let f = try TraceFixture {
            $0.clean = { text, _, _, _ in
                CleanupOutcome(text: text, usage: relayed, failedUsages: [failed], fallback: "OpenAI")
            }
        }
        defer { f.dispose() }
        try await f.dictate()

        let record = try #require(f.model.history.first)
        let trace = try #require(try f.model.store.traces(dictationID: record.id).first)
        #expect(trace.origin == .toggle)
        #expect(trace.outcome == .inserted)
        #expect(trace.calls.map(\.api) == [.xaiStreaming, .xaiFile, .deepSeekCleanup, .openAICleanup])
        #expect(trace.calls.prefix(2).allSatisfy { $0.fallback == nil })
        #expect(trace.calls.suffix(2).map(\.id) == [failed.id, relayed.id])
        #expect(trace.calls.suffix(2).map(\.succeeded) == [false, true])
        #expect(trace.calls.last?.fallback == correctionFallback)
        #expect(Set(trace.calls.map(\.id)) == Set(f.model.usage.map(\.id)))
    }

    @Test func overlappingDictationsNeverMixTheirCalls() async throws {
        let entered = AsyncResult<Void>()
        let releaseFirst = AsyncResult<Void>()
        var files = 0
        let firstCleanup = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.00001)
        let secondCleanup = UsageEvent(api: .openAICleanup, model: CleanupModel.openAIFallback, costUSD: 0.00002)
        let f = try TraceFixture {
            $0.transcribe = { _, _ in
                files += 1
                if files == 1 {
                    entered.resolve(.success(()))
                    try await releaseFirst.value()
                    return "Première phrase."
                }
                return "Deuxième phrase."
            }
            $0.clean = { text, _, _, _ in
                CleanupOutcome(text: text, usage: text == "Première phrase." ? firstCleanup : secondCleanup)
            }
        }
        defer { f.dispose() }
        try await f.begin(.pushToTalk)
        let first = try #require(f.model.coordinator.endCapture())
        try await entered.value()
        try await f.begin(.toggle)
        let second = try #require(f.model.coordinator.endCapture())
        #expect(f.model.coordinator.finishingCount == 2)
        releaseFirst.resolve(.success(()))
        await first.value
        await second.value

        #expect(f.insertedTexts == ["Première phrase.", "Deuxième phrase."])
        let firstRecord = try #require(f.model.history.first { $0.finalText == "Première phrase." })
        let secondRecord = try #require(f.model.history.first { $0.finalText == "Deuxième phrase." })
        let firstTrace = try #require(try f.model.store.traces(dictationID: firstRecord.id).first)
        let secondTrace = try #require(try f.model.store.traces(dictationID: secondRecord.id).first)
        #expect(firstTrace.id != secondTrace.id)
        #expect(firstTrace.origin == .hold && secondTrace.origin == .toggle)
        #expect(firstTrace.calls.map(\.api) == [.xaiStreaming, .xaiFile, .deepSeekCleanup])
        #expect(secondTrace.calls.map(\.api) == [.xaiStreaming, .xaiFile, .openAICleanup])
        #expect(firstTrace.calls.last?.id == firstCleanup.id)
        #expect(secondTrace.calls.last?.id == secondCleanup.id)
        let firstIDs = Set(firstTrace.calls.map(\.id))
        let secondIDs = Set(secondTrace.calls.map(\.id))
        #expect(firstIDs.isDisjoint(with: secondIDs))
        #expect(firstIDs.union(secondIDs) == Set(f.model.usage.map(\.id)))
    }

    @Test func delayedDictionaryLearningBelongsToItsOriginalRunDuringTheNextCapture() async throws {
        let judgementStarted = AsyncResult<Void>()
        let releaseJudgement = AsyncResult<Void>()
        var observedCorrection: (@MainActor ([CorrectionLearner.Candidate]) -> Void)?
        let failed = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0, succeeded: false)
        let fallback = APIFallback(fromAPI: .deepSeekCleanup, stage: .dictionary, reason: .requestFailed)
        let judged = UsageEvent(api: .typesafeJudge, model: "jev-latest", costUSD: 0.00001, fallback: fallback)
        let f = try TraceFixture {
            $0.watchCorrections = { _, _, _, callback in observedCorrection = callback }
            $0.judgeTerms = { _, _, _ in
                judgementStarted.resolve(.success(()))
                try? await releaseJudgement.value()
                return TermJudgement(kept: [], usages: [failed, judged])
            }
        }
        defer { f.dispose() }
        f.model.settings.learnCorrections = true
        f.streamText = "TRANSCRIPT_PRIVATE_SENTINEL"
        // Vérification coupée : la dictée suivante ne compte que son flux.
        f.model.settings.verifyWithFile = false
        try await f.dictate(.pushToTalk)
        let originalRecord = try #require(f.model.history.first)
        let originalTrace = try #require(try f.model.store.traces(dictationID: originalRecord.id).first)
        let correction = try #require(observedCorrection)
        correction([CorrectionLearner.Candidate(heard: "Sidance", corrected: "Seedance")])
        try await judgementStarted.value()

        // Le jugement de l'ancienne dictée répond pendant que la suivante écoute déjà.
        try await f.begin(.toggle)
        #expect(f.model.coordinator.isListening)
        releaseJudgement.resolve(.success(()))
        await f.model.learning?.value
        let appended = try #require(try f.model.store.traces(dictationID: originalRecord.id).first)
        #expect(appended.id == originalTrace.id)
        #expect(appended.calls.map(\.api) == [.xaiStreaming, .deepSeekCleanup, .typesafeJudge])
        #expect(appended.calls.suffix(2).map(\.id) == [failed.id, judged.id])
        #expect(appended.calls.last?.fallback == fallback)
        #expect(f.model.coordinator.isListening)

        await f.model.coordinator.end()
        let nextRecord = try #require(f.model.history.first { $0.id != originalRecord.id })
        let nextTrace = try #require(try f.model.store.traces(dictationID: nextRecord.id).first)
        #expect(nextTrace.calls.map(\.api) == [.xaiStreaming])
        #expect(!nextTrace.calls.contains { $0.id == failed.id || $0.id == judged.id })
        #expect(Set((appended.calls + nextTrace.calls).map(\.id)) == Set(f.model.usage.map(\.id)))
        try expectPrivateFieldsAbsent([appended, nextTrace])
    }

    @Test func failedAudioAndRetryHaveSeparateRunsForTheSameRecord() async throws {
        let f = try TraceFixture()
        defer { f.dispose() }
        f.failedFileProviders = [.xai, .openAI]
        try await f.dictate()

        let record = try #require(f.model.history.first)
        let audioPath = try #require(record.audioPath)
        #expect(FileManager.default.fileExists(atPath: audioPath))
        #expect(record.insertionStatus == InsertionStatus.transcriptionFailed.rawValue)
        let originalTrace = try #require(try f.model.store.traces(dictationID: record.id).first)
        #expect(originalTrace.outcome == .transcriptionFailed)
        #expect(originalTrace.calls.map(\.api) == [.xaiStreaming, .xaiFile, .openAIFile])
        #expect(originalTrace.calls.suffix(2).allSatisfy { !$0.succeeded })
        #expect(originalTrace.calls.last?.fallback == APIFallback(fromAPI: .xaiFile, stage: .transcription, reason: .requestFailed))

        f.failedFileProviders = []
        await f.model.coordinator.retranscribe(record)
        let traces = try f.model.store.traces(dictationID: record.id)
        #expect(traces.count == 2)
        let retry = try #require(traces.first { $0.origin == .retry })
        #expect(retry.id != originalTrace.id)
        #expect(retry.outcome == .pending)
        #expect(retry.calls.map(\.api) == [.xaiFile])
        #expect(retry.calls.first?.succeeded == true)
        #expect(retry.timings.microphoneMs == nil)
        #expect(retry.timings.firstAudioMs == nil)
        #expect(retry.timings.streamReadyMs == nil)
        #expect(retry.timings.insertionMs == nil)
        #expect(f.insertedTexts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: audioPath))
        #expect(f.model.history.first?.id == record.id)
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.pending.rawValue)
        #expect(Set(traces.flatMap(\.calls).map(\.id)) == Set(f.model.usage.map(\.id)))
        try expectPrivateFieldsAbsent(traces)
    }

    @Test func cancellationWhileListeningProducesAnUnlinkedTrace() async throws {
        let f = try TraceFixture()
        defer { f.dispose() }
        try await f.begin()
        let path = try #require(f.captures.first?.url?.path)
        f.model.coordinator.cancel()

        let traces = try f.model.store.recentTraces(limit: 50)
        #expect(traces.count == 1)
        let trace = try #require(traces.first)
        #expect(trace.outcome == .cancelled)
        #expect(trace.dictationID == nil)
        #expect(trace.calls.map(\.api) == [.xaiStreaming])
        #expect(trace.calls.map(\.id) == f.model.usage.map(\.id))
        #expect(f.model.history.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
        try expectPrivateFieldsAbsent(traces)
    }

    @Test func cancellationDuringTranscriptionKeepsLateCallInItsCancelledRun() async throws {
        let entered = AsyncResult<Void>()
        let response = AsyncResult<String>()
        let f = try TraceFixture {
            $0.transcribe = { _, _ in
                entered.resolve(.success(()))
                return try await response.value()
            }
        }
        defer { f.dispose() }
        try await f.begin()
        let end = try #require(f.model.coordinator.endCapture())
        try await entered.value()
        f.model.coordinator.cancel()
        response.resolve(.success("TRANSCRIPT_PRIVATE_SENTINEL"))
        await end.value

        let traces = try f.model.store.recentTraces(limit: 50)
        #expect(traces.count == 1)
        let trace = try #require(traces.first)
        #expect(trace.outcome == .cancelled)
        #expect(trace.dictationID == nil)
        #expect(trace.calls.map(\.api) == [.xaiStreaming, .xaiFile])
        #expect(Set(trace.calls.map(\.id)) == Set(f.model.usage.map(\.id)))
        #expect(f.model.history.isEmpty && f.insertedTexts.isEmpty)
        #expect(f.model.coordinator.phase == .idle)
        try expectPrivateFieldsAbsent(traces)
    }

    @Test func cancellationDuringInsertionLinksTheTraceToThePreservedHistoryRecord() async throws {
        let entered = AsyncResult<Void>()
        let releaseInsertion = AsyncResult<Void>()
        let f = try TraceFixture {
            $0.insert = { _, _, allowed, _ in
                entered.resolve(.success(()))
                try? await releaseInsertion.value()
                return allowed() ? .inserted : .cancelled
            }
        }
        defer { f.dispose() }
        try await f.begin()
        let end = try #require(f.model.coordinator.endCapture())
        try await entered.value()
        f.model.coordinator.cancel()
        releaseInsertion.resolve(.success(()))
        await end.value

        let record = try #require(f.model.history.first)
        #expect(record.insertionStatus == InsertionStatus.cancelled.rawValue)
        #expect(FileManager.default.fileExists(atPath: try #require(record.audioPath)))
        let traces = try f.model.store.traces(dictationID: record.id)
        #expect(traces.count == 1)
        let trace = try #require(traces.first)
        #expect(trace.dictationID == record.id && trace.outcome == .cancelled)
        #expect(trace.timings.insertionMs != nil)
        #expect(f.model.coordinator.phase == .idle)
        try expectPrivateFieldsAbsent(traces)
    }

    @Test func sentPasteKeepsItsUnconfirmedOutcomeInTheTechnicalDetail() async throws {
        let f = try TraceFixture { $0.insert = { _, _, _, _ in .pasteSent } }
        defer { f.dispose() }
        try await f.dictate()

        let record = try #require(f.model.history.first)
        #expect(record.insertionStatus == InsertionStatus.pasteSent.rawValue)
        let trace = try #require(try f.model.store.traces(dictationID: record.id).first)
        #expect(trace.outcome == .pasteSent)
        #expect(trace.timings.insertionMs != nil && trace.timings.afterReleaseMs != nil)
        #expect(record.audioPath != nil)
    }

    @Test func deniedMicrophoneIsRecordedWithoutOpeningAudioOrCallingAnAPI() async throws {
        let f = try TraceFixture { $0.requestMicrophone = { false } }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)

        let traces = try f.model.store.recentTraces(limit: 50)
        #expect(traces.count == 1)
        let trace = try #require(traces.first)
        #expect(trace.origin == .hold && trace.outcome == .microphoneDenied)
        #expect(trace.dictationID == nil)
        #expect(trace.timings.microphoneMs == nil && trace.timings.firstAudioMs == nil)
        #expect(trace.calls.isEmpty)
        #expect(f.captures.isEmpty && f.streams.isEmpty)
        #expect(f.model.history.isEmpty && f.model.usage.isEmpty)
        #expect(f.model.coordinator.phase == .idle)
        try expectPrivateFieldsAbsent(traces)
    }

    @Test func tooBriefCaptureLeavesOnlyACompletedTechnicalTrace() async throws {
        let f = try TraceFixture()
        defer { f.dispose() }
        f.duration = 0.1
        try await f.begin(.pushToTalk)
        await f.model.coordinator.end()

        let traces = try f.model.store.recentTraces(limit: 50)
        #expect(traces.count == 1)
        let trace = try #require(traces.first)
        #expect(trace.outcome == .noSpeech)
        #expect(trace.dictationID == nil)
        #expect(trace.calls.map(\.api) == [.xaiStreaming])
        #expect(f.model.history.isEmpty && f.fileProviders.isEmpty)
        #expect(f.model.coordinator.phase == .idle)
    }

    private func expectPrivateFieldsAbsent<T: Encodable>(_ traces: T) throws {
        let data = try JSONEncoder().encode(traces)
        let json = try #require(String(data: data, encoding: .utf8))
        for sentinel in ["TRANSCRIPT_PRIVATE_SENTINEL", "CONTEXT_PRIVATE_SENTINEL", "CURSOR_PRIVATE_SENTINEL", "KEY_PRIVATE_SENTINEL", "ERROR_PRIVATE_SENTINEL", "api-key-secret-placeholder"] {
            #expect(!json.contains(sentinel))
        }
    }
}
