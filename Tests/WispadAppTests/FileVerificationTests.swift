import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

private final class VerifyAudio: AudioRecording, @unchecked Sendable {
    var onPCM: (@Sendable (Data) -> Void)?
    let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    var duration = 2.0
    private var url: URL?

    func start(directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 128).write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) { (url, duration) }
}

private final class VerifyStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    var text = ""
    var fail = false
    var endingFinalized = true
    func start() async throws {}
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish {
        if fail { throw URLError(.networkConnectionLost) }
        return StreamFinish(text: text, endingFinalized: endingFinalized)
    }
    func cancel() {}
}

/// Micro, coffre, réseau et collage simulés. Le fichier et la correction peuvent être retenus.
@MainActor
private final class VerifyFixture {
    let directory: URL
    let audio = VerifyAudio()
    let stream = VerifyStream()
    var fileTexts: [String] = []
    var fileCalls = 0
    var fileProviders: [ProviderID] = []
    var fileTerms: [String] = []
    var liveTerms: [String] = []
    var cleanTexts: [String] = []
    var cleanRequests: [CorrectionRequest] = []
    var inserted: [String] = []
    var fileEntered = AsyncResult<Void>()
    var fileRelease = AsyncResult<String>()
    var holdFile = false
    var fileFails = false
    var cleanEntered = AsyncResult<Void>()
    var cleanRelease = AsyncResult<Void>()
    var holdClean = false
    /// Bloque seulement la première correction (celle du flux), jusqu'à `cleanRelease`.
    var holdFirstClean = false
    var model: AppModel!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-verify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { "fixture-" + $0 }
        dependencies.saveKey = { _, _ in true }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        dependencies.captureContext = {
            let context = DictationContext()
            context.pid = 4_242
            context.bundleID = "com.example.fictif.editeur"
            context.appName = "Éditeur fictif"
            return (context, Task { nil })
        }
        dependencies.readWindow = { _ in nil }
        dependencies.makeCapture = { [audio] in audio }
        dependencies.makeSession = { [weak self] speech in
            self?.liveTerms = speech.keyterms
            return self?.stream ?? VerifyStream()
        }
        dependencies.transcribe = { [weak self] _, speech in
            guard let self else { return "" }
            self.fileCalls += 1
            self.fileProviders.append(speech.provider)
            self.fileTerms = speech.keyterms
            self.fileEntered.resolve(.success(()))
            if self.holdFile {
                let text = try await self.fileRelease.value()
                self.fileTexts.append(text)
                return text
            }
            if self.fileFails { throw URLError(.timedOut) }
            let text = self.fileTexts.last ?? ""
            return text
        }
        dependencies.clean = { [weak self] text, request, _, enabled in
            let first = self?.cleanTexts.isEmpty == true
            self?.cleanTexts.append(text)
            self?.cleanRequests.append(request)
            self?.cleanEntered.resolve(.success(()))
            if self?.holdClean == true || (first && self?.holdFirstClean == true) { try? await self?.cleanRelease.value() }
            guard enabled else { return CleanupOutcome(text: text) }
            let usage = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.00001)
            return CleanupOutcome(text: text, usage: usage)
        }
        dependencies.playCue = { _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { [weak self] text, _, allowed in
            guard allowed() else { return .cancelled }
            self?.inserted.append(text)
            return .inserted
        }
        var settings = AppSettings()
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.structureDictation = false
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    func dictate() async {
        await model.coordinator.begin(.toggle)
        await model.coordinator.end()
    }

    func trace() throws -> DictationTrace {
        try #require(try model.store.recentTraces(limit: 1).first)
    }

    func dispose() {
        fileRelease.resolve(.success(""))
        cleanRelease.resolve(.success(()))
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// La fin de dictée doit revenir dans le délai. Sinon le test échoue au lieu de rester bloqué sur le fichier.
private func finish(within seconds: Double, _ task: Task<Void, Never>) async throws {
    let done = AsyncResult<Void>()
    Task { await task.value; done.resolve(.success(())) }
    Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        done.resolve(.failure(URLError(.timedOut)))
    }
    try await done.value()
}

@MainActor
@Suite(.serialized)
struct FileVerificationTests {
    @Test func equivalentNumbersKeepTheStreamAndASingleCorrection() async throws {
        let stream = "J'ai deux mille six cent soixante-six barrettes."
        let f = try VerifyFixture()
        defer { f.dispose() }
        try f.model.store.addTerm("DDR3")
        f.model.reload()
        try f.model.store.insert(DictationRecord(
            createdAt: Date().addingTimeInterval(-60),
            finalText: "Les barrettes sont en DDR3.",
            rawText: "Les barrettes sont en DDR3.",
            durationSeconds: 2,
            wordCount: 5,
            provider: "xai",
            model: "fixture",
            targetBundle: "com.example.fictif.editeur",
            insertionStatus: InsertionStatus.inserted.rawValue
        ))
        f.model.reload()
        f.stream.text = stream
        f.fileTexts = ["J'ai 2666 barrettes."]
        await f.dictate()

        let record = try #require(f.model.history.first)
        #expect(f.cleanTexts == [stream])
        #expect(f.inserted == [stream])
        #expect(record.rawText == stream)
        #expect(record.finalText == stream)
        #expect(f.fileCalls == 1)
        #expect(f.fileProviders == [.xai])
        #expect(f.liveTerms.contains("DDR3"))
        #expect(f.fileTerms.contains("DDR3"))
        #expect(f.cleanRequests.first?.dictionary.contains("DDR3") == true)
        #expect(f.cleanRequests.first?.previousDictations == ["Les barrettes sont en DDR3."])
        #expect(f.model.usage.filter { $0.api == .deepSeekCleanup }.count == 1)
        let trace = try f.trace()
        #expect(trace.transcriptSource == .stream)
        #expect(trace.transcriptChoice == .equivalent)
        #expect(trace.fileLatencyMs != nil)
        #expect(trace.streamFallback == nil)
    }

    @Test func divergentFileIsKeptAndBothCorrectionsAreBilled() async throws {
        let stream = "il écrit DDR"
        let file = "il écrit DDR4 ce bâtard."
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.stream.text = stream
        f.fileTexts = [file]
        await f.dictate()

        let record = try #require(f.model.history.first)
        #expect(f.cleanTexts == [stream, file])
        // La correction du texte retenu reçoit aussi l'écoute du flux, pour départager un mot.
        #expect(f.cleanRequests.first?.alternativeTranscript == nil)
        #expect(f.cleanRequests.last?.alternativeTranscript == stream)
        #expect(f.inserted == [file])
        #expect(record.rawText == file)
        #expect(record.finalText == file)
        // L'autre écoute reste avec la dictée, sur le Mac, pour comprendre le désaccord.
        #expect(record.alternativeText == stream)
        #expect(f.fileCalls == 1)
        #expect(f.model.usage.filter { $0.api == .deepSeekCleanup }.count == 2)
        #expect(f.model.usage.contains { $0.api == .xaiFile && $0.succeeded })
        let trace = try f.trace()
        #expect(trace.transcriptSource == .file)
        #expect(trace.transcriptChoice == .diverged)
        #expect(trace.streamWords == 3)
        #expect(trace.fileWords == 5)
        #expect(trace.divergentWords == 3)
        #expect(trace.calls.map(\.api).contains(.xaiFile))
        #expect(trace.calls.filter { $0.api == .deepSeekCleanup }.count == 2)
    }

    @Test func divergentFileIsPastedWithoutWaitingForTheDiscardedCorrection() async throws {
        let stream = "il écrit DDR"
        let file = "il écrit DDR4 ce bâtard."
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.stream.text = stream
        f.fileTexts = [file]
        f.holdFirstClean = true
        await f.model.coordinator.begin(.toggle)
        let task = try #require(f.model.coordinator.endCapture())
        // La correction du flux reste bloquée : le texte du fichier est pourtant corrigé et collé.
        let deadline = Date().addingTimeInterval(3)
        while f.inserted.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(f.inserted == [file])
        #expect(f.cleanTexts == [stream, file])
        // Libérée ensuite, elle est quand même comptée, et ajoutée à la trace de la dictée.
        f.cleanRelease.resolve(.success(()))
        try await finish(within: 2, task)
        let counted = Date().addingTimeInterval(2)
        while f.model.usage.filter({ $0.api == .deepSeekCleanup }).count < 2, Date() < counted {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(f.model.usage.filter { $0.api == .deepSeekCleanup }.count == 2)
        let traceDeadline = Date().addingTimeInterval(2)
        while (try? f.trace())?.calls.filter({ $0.api == .deepSeekCleanup }).count ?? 0 < 2, Date() < traceDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(try f.trace().calls.filter { $0.api == .deepSeekCleanup }.count == 2)
    }

    @Test func oneDivergentWordIsReportedIntoTheStreamCorrection() async throws {
        let stream = "on se voit mardi à la réunion"
        let file = "on se voit mercredi à la réunion"
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.stream.text = stream
        f.fileTexts = [file]
        await f.dictate()

        let record = try #require(f.model.history.first)
        // Une seule correction, celle du flux : le mot du fichier y est reporté.
        #expect(f.cleanTexts == [stream])
        #expect(f.inserted == [file])
        #expect(record.rawText == file)
        #expect(record.finalText == file)
        #expect(record.alternativeText == stream)
        #expect(f.model.usage.filter { $0.api == .deepSeekCleanup }.count == 1)
        let trace = try f.trace()
        #expect(trace.transcriptChoice == .diverged)
        #expect(trace.correctionPatched == true)
    }

    @Test func slowStreamCorrectionIsNotAwaitedForAReport() async throws {
        let stream = "on se voit mardi à la réunion"
        let file = "on se voit mercredi à la réunion"
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.stream.text = stream
        f.fileTexts = [file]
        f.holdFirstClean = true
        await f.model.coordinator.begin(.toggle)
        let task = try #require(f.model.coordinator.endCapture())
        // Correction du flux bloquée : au-delà de la borne, le fichier est corrigé en entier et collé.
        let deadline = Date().addingTimeInterval(3)
        while f.inserted.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(f.inserted == [file])
        #expect(f.cleanTexts == [stream, file])
        f.cleanRelease.resolve(.success(()))
        try await finish(within: 2, task)
        #expect(try f.trace().correctionPatched == nil)
    }

    @Test func fileSlowerThanTheBoundKeepsTheStream() async throws {
        let stream = "texte du flux."
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.audio.duration = 0.3
        f.stream.text = stream
        f.holdFile = true
        await f.model.coordinator.begin(.toggle)
        let end = Task { await f.model.coordinator.end() }
        try await f.fileEntered.value()
        try await finish(within: 3, end)

        #expect(f.inserted == [stream])
        #expect(f.model.history.first?.rawText == stream)
        #expect(f.cleanTexts == [stream])
        #expect(!f.model.usage.contains { $0.api == .xaiFile })
        let trace = try f.trace()
        #expect(trace.transcriptSource == .stream)
        #expect(trace.transcriptChoice == .fileTimeout)
        #expect((trace.fileLatencyMs ?? 0) >= 1_000)

        f.fileRelease.resolve(.success("texte du fichier arrivé trop tard."))
        var billed = false
        for _ in 0..<50 {
            if f.model.usage.contains(where: { $0.api == .xaiFile && $0.succeeded }) {
                billed = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(billed)
        let saved = try f.trace()
        #expect(saved.transcriptChoice == .fileTimeout)
        #expect(saved.calls.contains { $0.api == .xaiFile && $0.succeeded })
    }

    @Test func failedFileKeepsTheStreamWithoutCallingTheOtherProvider() async throws {
        let stream = "flux fiable."
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.stream.text = stream
        f.fileFails = true
        await f.dictate()

        #expect(f.inserted == [stream])
        #expect(f.model.history.first?.rawText == stream)
        #expect(f.fileCalls == 1)
        #expect(f.fileProviders == [.xai])
        #expect(f.cleanTexts == [stream])
        #expect(f.model.usage.contains { $0.api == .xaiFile && !$0.succeeded })
        #expect(!f.model.usage.contains { $0.api == .openAIFile })
        let trace = try f.trace()
        #expect(trace.transcriptSource == .stream)
        #expect(trace.transcriptChoice == .fileFailed)
    }

    @Test func emptyFileDoesNotReplaceANonEmptyStream() async throws {
        let stream = "flux bien entendu."
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.stream.text = stream
        // Réponse du fichier sans aucun mot (vide, espaces ou seule hésitation) : la dictée ne doit pas disparaître.
        f.fileTexts = [" euh "]
        await f.dictate()

        #expect(f.inserted == [stream])
        #expect(f.model.history.first?.rawText == stream)
        #expect(f.model.history.first?.alternativeText == nil)
        let trace = try f.trace()
        #expect(trace.outcome != .noSpeech)
        #expect(trace.transcriptSource == .stream)
        #expect(trace.transcriptChoice == .fileFailed)
    }

    @Test func emptyFileDoesNotReplaceAnUnfinalizedStream() async throws {
        let stream = "flux pas finalisé mais entendu."
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.model.settings.verifyWithFile = false
        f.stream.text = stream
        f.stream.endingFinalized = false
        f.fileTexts = [""]
        await f.dictate()

        #expect(f.fileCalls == 1)
        #expect(f.inserted == [stream])
        #expect(f.model.history.first?.rawText == stream)
        let trace = try f.trace()
        #expect(trace.outcome != .noSpeech)
        #expect(trace.transcriptSource == .stream)
        #expect(trace.streamFallback == .unfinalized)
    }

    @Test func emptyStreamUsesTheAlreadyLaunchedFileOnce() async throws {
        let file = "phrase complète du fichier."
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.stream.text = ""
        f.fileTexts = [file]
        await f.dictate()

        #expect(f.fileCalls == 1)
        #expect(f.fileProviders == [.xai])
        #expect(f.inserted == [file])
        #expect(f.model.history.first?.rawText == file)
        #expect(f.cleanTexts == [file])
        #expect(f.model.usage.filter { $0.api == .xaiFile }.count == 1)
        let trace = try f.trace()
        #expect(trace.transcriptSource == .file)
        #expect(trace.transcriptChoice == .streamEmpty)
        let voice = trace.calls.map(\.api).filter { $0 == .xaiStreaming || $0 == .xaiFile }
        #expect(voice == [.xaiStreaming, .xaiFile])
    }

    @Test func brokenStreamUsesTheAlreadyLaunchedFileOnce() async throws {
        let file = "phrase complète du fichier."
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.stream.fail = true
        f.fileTexts = [file]
        await f.dictate()

        #expect(f.fileCalls == 1)
        #expect(f.inserted == [file])
        #expect(f.cleanTexts == [file])
        let trace = try f.trace()
        #expect(trace.transcriptSource == .file)
        #expect(trace.transcriptChoice == .streamEmpty)
    }

    @Test func verificationOffKeepsAFinalizedStreamAndSkipsTheFile() async throws {
        let stream = "Phrase du flux."
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.model.settings.verifyWithFile = false
        f.stream.text = stream
        f.fileTexts = ["Autre phrase du fichier."]
        await f.dictate()

        #expect(f.fileCalls == 0)
        #expect(f.inserted == [stream])
        #expect(f.model.history.first?.rawText == stream)
        #expect(f.cleanTexts == [stream])
        #expect(!f.model.usage.contains { $0.api == .xaiFile })
        let trace = try f.trace()
        #expect(trace.transcriptSource == .stream)
        #expect(trace.transcriptChoice == .settingOff)
        #expect(trace.fileLatencyMs == nil)
        #expect(trace.streamFallback == nil)
    }

    @Test func escapeDuringTheWaitPastesNothingAndKeepsBilledUsage() async throws {
        let f = try VerifyFixture()
        defer { f.dispose() }
        f.audio.duration = 60
        f.stream.text = "phrase encore en cours."
        f.holdFile = true
        f.holdClean = true
        await f.model.coordinator.begin(.toggle)
        let end = Task { await f.model.coordinator.end() }
        try await f.fileEntered.value()
        try await f.cleanEntered.value()
        let began = Date()
        f.model.coordinator.cancel()
        f.fileRelease.resolve(.success("phrase du fichier."))
        f.cleanRelease.resolve(.success(()))
        await end.value

        #expect(Date().timeIntervalSince(began) < 1)
        #expect(f.inserted.isEmpty)
        #expect(f.model.history.isEmpty)
        #expect(f.model.coordinator.phase == .idle)
        #expect(f.model.usage.contains { $0.api == .xaiStreaming })
        #expect(f.model.usage.contains { $0.api == .xaiFile && $0.succeeded })
        #expect(f.model.usage.contains { $0.api == .deepSeekCleanup })
        let trace = try f.trace()
        #expect(trace.outcome == .cancelled)
        #expect(trace.dictationID == nil)
        #expect(trace.calls.contains { $0.api == .xaiFile && $0.succeeded })
        #expect(trace.calls.contains { $0.api == .deepSeekCleanup })
    }

    @Test func oldSettingsWithoutTheKeyVerifyWithTheFile() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"provider":"xai","cleanupEnabled":false}"#.utf8))
        #expect(decoded.verifyWithFile)
        #expect(!decoded.cleanupEnabled)

        var settings = AppSettings()
        settings.verifyWithFile = false
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!restored.verifyWithFile)
    }
}
