import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

private final class EarlyAudio: AudioRecording, @unchecked Sendable {
    var onPCM: (@Sendable (Data) -> Void)?
    let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    private var url: URL?

    func start(directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 128).write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) { (url, 3) }
}

private final class EarlyStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    var onSettled: (@Sendable (String) -> Void)?
    var text = ""
    /// Temps que met le flux à donner son texte final après l'arrêt.
    var finishDelay: Double = 0
    var onFinish: (@MainActor () -> Void)?
    func start() async throws {}
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish {
        if finishDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(finishDelay * 1_000_000_000)) }
        if let onFinish { await onFinish() }
        return StreamFinish(text: text, endingFinalized: true)
    }
    func cancel() {}
}

/// Flux, fichier, correction et collage simulés ; la correction rend le texte en majuscules pour la reconnaître.
@MainActor
private final class EarlyFixture {
    let directory: URL
    let audio = EarlyAudio()
    let stream = EarlyStream()
    var fileText = ""
    var fileDelay: Double = 0
    var cleanDelay: Double = 0
    var completedCleans = 0
    var holdContext = false
    let contextRelease = AsyncResult<FieldSnapshot?>()
    var holdPrepared = false
    let preparedRelease = AsyncResult<Void>()
    var finishedTranscriptionAt: Date?
    var pastedAt: Date?
    var cleanTexts: [String] = []
    var inserted: [String] = []
    var model: AppModel!

    init(verifyWithFile: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-early-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { "fixture-" + $0 }
        dependencies.saveKey = { _, _ in true }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        dependencies.captureContext = { [weak self] in
            let context = DictationContext()
            context.pid = 4_242
            context.bundleID = "com.example.fictif.editeur"
            context.appName = "Éditeur fictif"
            return (context, Task { @MainActor [weak self] in
                guard let self, self.holdContext else { return nil }
                return try? await self.contextRelease.value()
            })
        }
        dependencies.readWindow = { _ in nil }
        dependencies.makeCapture = { [audio] in audio }
        dependencies.makeSession = { [stream] _ in stream }
        dependencies.transcribe = { [weak self] _, _ in
            if let delay = self?.fileDelay, delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            self?.finishedTranscriptionAt = Date()
            return self?.fileText ?? ""
        }
        dependencies.clean = { [weak self] text, _, _, enabled in
            let first = self?.cleanTexts.isEmpty == true
            self?.cleanTexts.append(text)
            if first, self?.holdPrepared == true { _ = try? await self?.preparedRelease.value() }
            guard enabled else { return CleanupOutcome(text: text) }
            if let delay = self?.cleanDelay, delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            self?.completedCleans += 1
            let usage = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.00001)
            return CleanupOutcome(text: text.uppercased(), usage: usage)
        }
        dependencies.playCue = { _, _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { [weak self] text, _, allowed, _ in
            guard allowed() else { return .cancelled }
            self?.pastedAt = Date()
            self?.inserted.append(text)
            return .inserted
        }
        var settings = AppSettings()
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.structureDictation = false
        settings.verifyWithFile = verifyWithFile
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    /// Le flux annonce une pause, puis le temps passe sans nouvelle parole.
    func pause(after text: String, waiting seconds: Double = 0.45) async {
        stream.text = text
        stream.onPartial?(text)
        stream.onSettled?(text)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func trace() throws -> DictationTrace {
        try #require(try model.store.recentTraces(limit: 1).first)
    }

    func cleanupCount() -> Int {
        model.usage.filter { $0.api == .deepSeekCleanup }.count
    }

    func dispose() {
        preparedRelease.resolve(.success(()))
        contextRelease.resolve(.success(nil))
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct EarlyCorrectionTests {
    @Test func repeatedPausesReserveOnlyOnePreparation() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileText = "Le train part demain"
        await f.model.coordinator.begin(.toggle)
        for text in ["Le train", "Le train part", "Le train part demain"] {
            await f.pause(after: text)
            // Les autres suites peuvent occuper le fil principal au-delà du délai de pause simulé.
            let deadline = Date().addingTimeInterval(15)
            while f.cleanTexts.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(f.cleanTexts == ["Le train"])
        }
        await f.model.coordinator.end()
        #expect(f.cleanTexts == ["Le train", f.fileText])
        #expect(f.inserted == [f.fileText.uppercased()])
        #expect(f.cleanupCount() == 2)
        #expect(try f.trace().earlyCorrections == 2)
        #expect(try f.trace().earlyCorrectionUsed == true)
    }

    @Test func worksWithoutFileVerificationToo() async throws {
        let f = try EarlyFixture(verifyWithFile: false)
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: "Bonjour à tous")
        await f.model.coordinator.end()

        #expect(f.cleanTexts == ["Bonjour à tous"])
        #expect(f.inserted == ["BONJOUR À TOUS"])
        #expect(try f.trace().earlyCorrectionUsed == true)
    }

    /// Pas de pause : la correction part à l'arrêt sur ce qui a été entendu, pendant que le flux finalise.
    @Test func speechThatResumesRightAwayIsCorrectedAtRelease() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileText = "Bonjour à tous"
        await f.model.coordinator.begin(.toggle)
        f.stream.onSettled?("Bonjour")
        f.stream.onPartial?("Bonjour à tous")
        f.stream.text = "Bonjour à tous"
        try? await Task.sleep(nanoseconds: 450_000_000)
        await f.model.coordinator.end()

        #expect(f.cleanTexts == ["Bonjour à tous"])
        #expect(f.inserted == ["BONJOUR À TOUS"])
        let trace = try f.trace()
        #expect(trace.earlyCorrections == 1)
        #expect(trace.earlyCorrectionUsed == true)
    }

    /// Le texte final du flux arrive tard : la correction est déjà partie, elle n'attend pas ce texte.
    @Test func correctionStartsWhileTheStreamFinalizes() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileText = "On se voit mardi"
        f.stream.finishDelay = 0.3
        var startedBeforeFinal: [String] = []
        f.stream.onFinish = { startedBeforeFinal = f.cleanTexts }
        await f.model.coordinator.begin(.pushToTalk)
        f.stream.onPartial?("On se voit mardi")
        f.stream.text = "On se voit mardi."
        try? await Task.sleep(nanoseconds: 50_000_000)
        await f.model.coordinator.end()

        #expect(startedBeforeFinal == ["On se voit mardi"])
        #expect(f.cleanTexts == ["On se voit mardi"])
        #expect(f.inserted == ["ON SE VOIT MARDI"])
        #expect(try f.trace().earlyCorrectionUsed == true)
    }

    /// Le texte final ajoute un mot : la correction de l'arrêt est comptée, une autre corrige le texte final.
    @Test func aFinalTextThatAddsWordsGetsItsOwnCorrection() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileText = "Bonjour à tous"
        await f.model.coordinator.begin(.pushToTalk)
        f.stream.onPartial?("Bonjour à")
        f.stream.text = "Bonjour à tous"
        try? await Task.sleep(nanoseconds: 50_000_000)
        await f.model.coordinator.end()

        #expect(f.cleanTexts == ["Bonjour à", "Bonjour à tous"])
        #expect(f.inserted == ["BONJOUR À TOUS"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.cleanupCount() == 2)
        #expect(try f.trace().earlyCorrectionUsed == false)
    }

    @Test func wordsAddedAfterAPauseAreIncludedInTheDefinitiveCorrection() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileText = "Bonjour à tous et merci"
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: "Bonjour à tous")
        f.stream.onPartial?("Bonjour à tous et merci")
        f.stream.text = "Bonjour à tous et merci"
        try? await Task.sleep(nanoseconds: 50_000_000)
        await f.model.coordinator.end()

        #expect(f.cleanTexts == ["Bonjour à tous", "Bonjour à tous et merci"])
        #expect(f.inserted == ["BONJOUR À TOUS ET MERCI"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.cleanupCount() == 2)
        let trace = try f.trace()
        #expect(trace.earlyCorrections == 2)
        #expect(trace.earlyCorrectionUsed == true)
    }

    @Test func cancelledPreparedDictationAccountsItsSinglePreparation() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: "Bonjour à tous")
        f.model.coordinator.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(f.inserted.isEmpty)
        #expect(f.cleanupCount() == 1)
    }

    @Test func noCorrectionIsPreparedWhenCorrectionIsOff() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.model.settings.cleanupEnabled = false
        f.fileText = "Bonjour à tous"
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: "Bonjour à tous")
        #expect(f.cleanTexts.isEmpty)
        await f.model.coordinator.end()
        #expect(f.inserted == ["Bonjour à tous"])
    }
}

@MainActor
@Suite(.serialized)
struct CorrectionBudgetTests {
    @Test func manyPausesAndThreeDifferentTranscriptsNeedAtMostThreeCorrections() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileDelay = 0.3
        f.fileText = "Le colis rouge partira samedi matin"
        await f.model.coordinator.begin(.toggle)
        for text in ["Le train", "Le train arrive", "Le train arrive demain", "Le train arrive demain matin"] {
            await f.pause(after: text)
            // Les autres suites peuvent occuper le fil principal au-delà du délai de pause simulé.
            let deadline = Date().addingTimeInterval(15)
            while f.cleanTexts.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(f.cleanTexts == ["Le train"])
        }
        f.stream.onPartial?("Le train arrive demain matin en gare")
        f.stream.text = "Le train arrive demain matin en gare puis repart"
        f.stream.finishDelay = 0.08
        try await Task.sleep(for: .milliseconds(20))
        await f.model.coordinator.end()
        #expect(f.cleanTexts == ["Le train", "Le train arrive demain matin en gare", f.fileText])
        #expect(f.inserted == [f.fileText.uppercased()])
        #expect(f.cleanupCount() == 3)
        #expect(try f.trace().earlyCorrections == 2)
    }

    @Test func finalPauseReusesACompletedCorrectionWithoutAnotherNetworkWait() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.cleanDelay = 0.45
        f.fileDelay = 0.22
        f.stream.finishDelay = 0.08
        f.fileText = "Le colis part demain matin"
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: f.fileText, waiting: 0.9)
        let prepared = Date().addingTimeInterval(3)
        while f.completedCleans == 0, Date() < prepared { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.completedCleans == 1)
        let stop = Date()
        await f.model.coordinator.end()
        let pasted = try #require(f.pastedAt)
        #expect(pasted.timeIntervalSince(stop) < 0.4)
        #expect(f.cleanTexts == [f.fileText])
        #expect(f.inserted == [f.fileText.uppercased()])
        #expect(f.cleanupCount() == 1)
    }

    @Test func repeatedSettledNotificationsDoNotPostponeTheSamePreparation() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileText = "Le colis part demain matin"
        await f.model.coordinator.begin(.toggle)
        for _ in 0..<8 {
            f.stream.text = f.fileText
            f.stream.onSettled?(f.fileText)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(f.cleanTexts == [f.fileText])
        await f.model.coordinator.end()
        #expect(f.cleanupCount() == 1)
    }

    @Test func resumedSpeechAndEarlyCancellationDoNotSendThePendingPreparation() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        f.stream.onSettled?("Le colis")
        try await Task.sleep(for: .milliseconds(100))
        f.stream.onPartial?("Le colis part demain")
        try await Task.sleep(for: .milliseconds(100))
        f.model.coordinator.cancel()
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.cleanTexts.isEmpty)
        #expect(f.inserted.isEmpty)
    }

    @Test func fileMatchingTheReleaseReusesItDespiteADifferentFinalStream() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileDelay = 0.2
        f.fileText = "Le colis rouge partira samedi matin"
        await f.model.coordinator.begin(.toggle)
        f.stream.onPartial?(f.fileText)
        f.stream.text = "Le train arrive demain matin en gare"
        try await Task.sleep(for: .milliseconds(20))
        await f.model.coordinator.end()
        #expect(f.cleanTexts == [f.fileText])
        #expect(f.inserted == [f.fileText.uppercased()])
        #expect(f.cleanupCount() == 1)
        #expect(try f.trace().earlyCorrectionUsed == true)
        #expect(try f.trace().transcriptChoice == .diverged)
    }

    @Test func fileCanReuseTheFirstPreparationWhileTheReleasePreparationIsPending() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.cleanDelay = 0.45
        f.fileDelay = 0.22
        f.fileText = "Le colis rouge partira samedi matin"
        await f.model.coordinator.begin(.toggle)
        await f.pause(after: f.fileText, waiting: 0.9)
        #expect(f.completedCleans == 1)
        f.stream.onPartial?("Le train arrive demain matin en gare")
        f.stream.text = "Le train arrive demain matin en gare"
        try await Task.sleep(for: .milliseconds(20))
        let stop = Date()
        await f.model.coordinator.end()
        #expect(try #require(f.pastedAt).timeIntervalSince(stop) < 0.4)
        #expect(f.inserted == [f.fileText.uppercased()])
        #expect(f.cleanTexts == [f.fileText, f.stream.text])
        let accounted = Date().addingTimeInterval(3)
        while f.cleanupCount() < 2, Date() < accounted { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.cleanupCount() == 2)
        #expect(try f.trace().earlyCorrectionUsed == true)
        #expect(try f.trace().earlyCorrections == 2)
    }

    @Test func cancellationWhileReadingContextNeverStartsAPaidCorrection() async throws {
        let f = try EarlyFixture(verifyWithFile: false)
        defer { f.dispose() }
        f.holdContext = true
        f.stream.finishDelay = 0.2
        await f.model.coordinator.begin(.toggle)
        f.stream.onPartial?("Le train arrive demain")
        f.stream.text = "Le train arrive demain"
        try await Task.sleep(for: .milliseconds(20))
        let end = try #require(f.model.coordinator.endCapture())
        try await Task.sleep(for: .milliseconds(30))
        f.model.coordinator.cancel()
        f.contextRelease.resolve(.success(nil))
        await end.value
        #expect(f.cleanTexts.isEmpty)
        #expect(f.inserted.isEmpty)
        #expect(f.cleanupCount() == 0)
    }

    @Test func obsoletePreparationCannotBlockTheSelectedText() async throws {
        let f = try EarlyFixture()
        defer { f.dispose() }
        f.fileDelay = 0.15
        f.fileText = "Le colis rouge partira samedi matin"
        f.holdPrepared = true
        await f.model.coordinator.begin(.toggle)
        f.stream.onPartial?("Le train arrive demain matin")
        f.stream.text = "Le train arrive demain matin en gare"
        try await Task.sleep(for: .milliseconds(20))
        let end = try #require(f.model.coordinator.endCapture())
        let deadline = Date().addingTimeInterval(2)
        while f.inserted.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.inserted == [f.fileText.uppercased()])
        #expect(f.cleanTexts.count == 2)
        // Aucun délai ajouté à la correction définitive et aucune attente de la préparation bloquée.
        let fileFinished = try #require(f.finishedTranscriptionAt)
        #expect(try #require(f.pastedAt).timeIntervalSince(fileFinished) < 0.5)
        f.preparedRelease.resolve(.success(()))
        await end.value
        let accounted = Date().addingTimeInterval(2)
        while f.cleanupCount() < 2, Date() < accounted { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.cleanupCount() == 2)
        #expect(try f.trace().calls.filter { $0.api == .deepSeekCleanup }.count == 2)
    }
}
