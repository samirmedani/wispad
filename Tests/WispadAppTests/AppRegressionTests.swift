import AppKit
import ApplicationServices
import Foundation
import os
import SwiftUI
import Testing
@testable import WispadApp
@testable import WispadCore

private final class FakeAudio: AudioRecording, @unchecked Sendable {
    var onPCM: (@Sendable (Data) -> Void)?
    var bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    var duration = 2.0
    var url: URL?
    var starts = 0
    var isRunning = false
    var emitsPCMOnStart = true
    var startGate: AsyncResult<Void>?
    var onStarting: (@Sendable () -> Void)?
    var startError: Error?
    /// Démarrages qui ont rendu la main (même abandonnés par la dictée).
    var finishedStarts = 0
    var restarts = 0
    var restartEmitsPCM = true
    var abandoned = 0
    func start(directory: URL) async throws -> URL {
        starts += 1
        onStarting?()
        if let startGate { try await startGate.value() }
        defer { finishedStarts += 1 }
        if let startError { throw startError }
        isRunning = true
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 128).write(to: url)
        self.url = url
        if emitsPCMOnStart { onPCM?(Data(repeating: 0, count: 1024)) }
        return url
    }
    func stop() -> (url: URL?, duration: Double) {
        isRunning = false
        return (url, duration)
    }
    func restart() async throws {
        restarts += 1
        if restartEmitsPCM { onPCM?(Data(repeating: 0, count: 1024)) }
    }
    func abandonStart() {
        abandoned += 1
    }
}

/// Attend qu'une condition devienne vraie (2 s au plus), sans bloquer le fil principal.
@MainActor
private func waitFor(_ condition: () -> Bool, seconds: Double = 2) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

private final class OpenedAt: @unchecked Sendable {
    var date: Date?
}

private final class FakeStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    var text = ""
    let started = AsyncResult<Void>()
    func start() async throws { started.resolve(.success(())) }
    func send(_ data: Data) {}
    var endingFinalized = true
    var coveredSeconds: Double?
    func finish() async throws -> StreamFinish {
        StreamFinish(text: text, endingFinalized: endingFinalized, coveredSeconds: coveredSeconds)
    }
    func cancel() {}
}

/// Rejoue de vrais événements xAI, sans socket : intermédiaire puis `done`, pas de segment final.
private final class UnfinalizedReplay: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    let session: LiveSpeechSession
    private let log = OutboundLog()
    private let closedDone = OSAllocatedUnfairLock(initialState: false)

    init() {
        session = LiveSpeechSession(request: SpeechRequest(
            provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture",
            language: .french, keyterms: [], prompt: ""
        ))
        session.tailFinalWaitSeconds = 0.05
        session.onOutbound = { [weak self] message in
            guard let self else { return }
            self.log.add(message)
            guard self.kind(message) == "audio.done" else { return }
            let first = self.closedDone.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            guard first else { return }
            self.session.handle(.string(#"{"type":"transcript.done","text":"Tu vois un autre truc","duration":1.1}"#))
        }
    }

    func start() async throws {
        session.handle(.string(#"{"type":"transcript.created"}"#))
    }

    func send(_ data: Data) { session.send(data) }

    func finish() async throws -> StreamFinish {
        session.handle(.string(#"{"type":"transcript.partial","text":"Tu vois un autre truc","is_final":false,"speech_final":false}"#))
        return try await session.finish()
    }

    func cancel() { session.cancel() }

    func kinds() -> [String] { log.snapshot() }

    private func kind(_ message: URLSessionWebSocketTask.Message) -> String {
        guard case .string(let text) = message,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return "" }
        return type
    }
}

/// Segment final puis `done` : le flux est fiable, le fichier ne doit pas être rappelé.
private final class FinalizedReplay: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    let session = LiveSpeechSession(request: SpeechRequest(
        provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture",
        language: .french, keyterms: [], prompt: ""
    ))

    func start() async throws {
        session.handle(.string(#"{"type":"transcript.created"}"#))
    }

    func send(_ data: Data) { session.send(data) }

    func finish() async throws -> StreamFinish {
        session.handle(.string(#"{"type":"transcript.partial","text":"Phrase finale du flux.","is_final":true,"speech_final":true,"start":0,"duration":1.8}"#))
        session.handle(.string(#"{"type":"transcript.done","text":"Phrase finale du flux.","duration":1.8}"#))
        return try await session.finish()
    }

    func cancel() { session.cancel() }
}

private final class OutboundLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String] = []

    func add(_ message: URLSessionWebSocketTask.Message) {
        let kind: String
        switch message {
        case .data(let data):
            kind = "audio:\(data.count)"
        case .string(let text):
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            kind = object?["type"] as? String ?? "text"
        @unknown default:
            kind = "other"
        }
        lock.lock()
        kinds.append(kind)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return kinds
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let audio = FakeAudio()
    let stream = FakeStream()
    var inserted = 0
    /// Textes collés, dans l'ordre.
    var insertedTexts: [String] = []
    /// Textes copiés automatiquement après un collage raté (jamais dans le vrai presse-papiers).
    var copied: [String] = []
    var transcriptions = 0
    var cues: [DictationCue] = []
    var watches: [(String, pid_t, [String], @MainActor ([CorrectionLearner.Candidate]) -> Void)] = []
    /// Mots soumis au juge, et ceux qu'il accepte (tous par défaut). Aucun appel réseau.
    var judged: [[CorrectionLearner.Candidate]] = []
    /// Coupures et rétablissements du son demandés (jamais exécutés : le vrai son du Mac n'est pas touché).
    var mutes: [OutputMuteMode] = []
    var restores = 0
    var approved: Set<String>?
    var microphoneRequests = 0
    var model: AppModel!

    init(configure: (inout AppDependencies) -> Void = { _ in }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var deps = AppDependencies()
        deps.copyText = { _ in }
        deps.loadKey = { "fixture-" + $0 }
        deps.saveKey = { _, _ in true }
        deps.refreshKeys = { true }
        deps.requestMicrophone = { [weak self] in self?.microphoneRequests += 1; return true }
        deps.captureContext = { let context = DictationContext(); context.pid = 4242; return (context, Task { nil }) }
        deps.frontmostApp = {
            let context = DictationContext()
            context.pid = 5151
            context.appName = "Éditeur de test"
            context.bundleID = "test.editeur"
            return context
        }
        deps.makeCapture = { [audio] in audio }
        deps.makeSession = { [stream] _ in stream }
        deps.transcribe = { [weak self] _, _ in self?.transcriptions += 1; return "Phrase de test." }
        deps.playCue = { [weak self] in self?.cues.append($0) }
        deps.watchCorrections = { [weak self] text, pid, known, learned in
            self?.watches.append((text, pid, known, learned))
        }
        deps.clean = { text, _, _, _ in CleanupOutcome(text: text) }
        deps.muteOutput = { [weak self] _, mode in self?.mutes.append(mode) }
        deps.restoreOutput = { [weak self] in self?.restores += 1 }
        deps.judgeTerms = { [weak self] candidates, _, _ in
            self?.judged.append(candidates)
            let kept = candidates.map(\.corrected).filter { self?.approved?.contains($0) ?? true }
            return TermJudgement(kept: kept, usages: [UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.00001)])
        }
        deps.insert = { [weak self] text, _, shouldProceed in
            guard shouldProceed() else { return .cancelled }
            self?.inserted += 1
            self?.insertedTexts.append(text)
            return .inserted
        }
        deps.modifiersReleased = {}
        deps.systemShortcuts = { [] }
        configure(&deps)
        model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: deps)
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Alpha (0…255) de l'icône de barre des menus rasterisée à l'échelle `scale`,
/// lue en (colonne, ligne comptée depuis le haut).
@MainActor
private func menuBarAlpha(listening: Bool, scale: Int) throws -> (Int, Int) -> Int {
    let size = BrandIcon.menuBarSize
    let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    BrandIcon.menuBarImage(listening: listening).draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return { x, y in Int(((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255).rounded()) }
}

@MainActor
private final class TransactionLog {
    struct Entry {
        var mode: OverlayMode
        var animated: Bool
        var disablesAnimations: Bool
    }
    var entries: [Entry] = []
}

/// Relève la transaction de chaque changement de mode de la bulle, comme la vue la reçoit.
private struct ModeProbe: View {
    var state: OverlayState
    var log: TransactionLog

    var body: some View {
        // Un Text et non Color.clear : une vue sans rien à dessiner ne reçoit pas les transactions.
        Text(String(describing: state.mode)).transaction(value: state.mode) { transaction in
            log.entries.append(.init(mode: state.mode, animated: transaction.animation != nil, disablesAnimations: transaction.disablesAnimations))
        }
    }
}

/// Le micro peut continuer à tourner alors que macOS a retiré son panneau : vérifier la fenêtre,
/// pas seulement la phase du coordinateur. Ces contrôles partagent l'écran et se suivent donc.
@Suite(.serialized)
@MainActor
struct OverlayVisibilityRegressionTests {
    @Test func listeningRestoresUnexpectedlyHiddenPanelWithoutRestartingCapture() async throws {
        _ = NSApplication.shared
        let f = try Fixture()
        let overlay = f.model.overlay
        overlay.displaysPanel = true
        overlay.install(model: f.model)
        let panel = try #require(overlay.panel)
        defer {
            f.dispose()
            panel.orderOut(nil)
        }
        let coordinator = f.model.coordinator
        await coordinator.begin(.toggle)
        #expect(coordinator.phase == .listening(.toggle))
        #expect(overlay.state.presented)
        #expect(panel.isVisible)
        #expect(!panel.isKeyWindow)
        #expect(f.audio.starts == 1)
        #expect(f.microphoneRequests == 1)

        // Simule un retrait externe du panneau, sans arrêter le micro ni changer la phase.
        panel.orderOut(nil)
        #expect(!panel.isVisible)
        let deadline = Date().addingTimeInterval(0.6)
        while !panel.isVisible, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(panel.isVisible)
        #expect(overlay.state.presented)
        #expect(coordinator.phase == .listening(.toggle))
        #expect(f.audio.isRunning)
        #expect(f.audio.starts == 1)
        #expect(f.microphoneRequests == 1)
        #expect(!panel.isKeyWindow)

        await coordinator.end()
        #expect(coordinator.phase == .idle)
        // Le retrait voulu doit rester retiré, même après le filet de 900 ms et la surveillance.
        try await Task.sleep(nanoseconds: 1_050_000_000)
        #expect(!overlay.state.presented)
        #expect(!panel.isVisible)
        #expect(!f.audio.isRunning)
        #expect(f.inserted == 1)
    }

    @Test func dictationStaysVisibleAfterReplacingAnExpiringNotice() async throws {
        _ = NSApplication.shared
        let f = try Fixture()
        let overlay = f.model.overlay
        overlay.displaysPanel = true
        overlay.install(model: f.model)
        let panel = try #require(overlay.panel)
        defer {
            f.dispose()
            panel.orderOut(nil)
        }
        let coordinator = f.model.coordinator
        coordinator.announce("Information de démonstration.", relay: false)
        #expect(overlay.state.presented)
        #expect(panel.isVisible)
        await coordinator.begin(.toggle)
        #expect(coordinator.notice == nil)
        #expect(coordinator.phase == .listening(.toggle))

        // Traverse l'ancienne disparition et l'expiration de l'annonce pendant la même écoute.
        let deadline = Date().addingTimeInterval(DictationCoordinator.noticeSeconds + 0.15)
        while Date() < deadline {
            #expect(overlay.state.presented)
            #expect(panel.isVisible)
            #expect(!panel.isKeyWindow)
            #expect(coordinator.phase == .listening(.toggle))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(f.audio.starts == 1)
        #expect(f.microphoneRequests == 1)
        coordinator.cancel()
    }
}

/// macOS ne montre pas la bulle dans une app passée en plein écran après sa première apparition :
/// seul un panneau neuf rejoint cet espace. Sans espace plein écran dans les tests, la lecture de
/// `isOnActiveSpace` est simulée. Panneaux jamais visibles : contenu masqué, fond transparent.
@Suite(.serialized)
@MainActor
struct OverlaySpaceRegressionTests {
    /// Panneaux que la simulation place hors de l'espace actif.
    @MainActor
    private final class OffSpace {
        var windows: Set<ObjectIdentifier> = []
        func contains(_ window: NSWindow) -> Bool { windows.contains(ObjectIdentifier(window)) }
        func insert(_ window: NSWindow) { windows.insert(ObjectIdentifier(window)) }
    }

    private func postSpaceChange(_ overlay: OverlayController) async throws {
        let generation = overlay.spaceGeneration
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        let deadline = Date().addingTimeInterval(1)
        while overlay.spaceGeneration == generation, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(overlay.spaceGeneration == generation + 1)
    }

    @Test func panelOffTheActiveSpaceIsReplacedOncePerSpaceKeepingItsContent() async throws {
        _ = NSApplication.shared
        let f = try Fixture()
        defer { f.dispose() }
        let overlay = f.model.overlay
        overlay.install(model: f.model)
        let original = try #require(overlay.panel)
        let content = try #require(original.contentView)
        #expect(!overlay.replacePanelIfOffActiveSpace())
        #expect(overlay.panel === original)

        overlay.isOnActiveSpace = { _ in false }
        #expect(overlay.replacePanelIfOffActiveSpace())
        let replacement = try #require(overlay.panel)
        #expect(replacement !== original)
        #expect(replacement.contentView === content)
        #expect(original.contentView !== content)
        #expect(!replacement.isVisible && !original.isVisible)
        #expect(replacement.level == original.level)
        #expect(replacement.collectionBehavior == original.collectionBehavior)
        #expect(replacement.styleMask == original.styleMask)
        #expect(replacement.frame == original.frame)
        #expect(replacement.ignoresMouseEvents)
        #expect(!replacement.hidesOnDeactivate && !replacement.canHide)
        #expect(overlay.diagnosticState.spaceReplacements == 1)

        // Même espace : pas de nouvelle tentative, même si le panneau neuf n'y est pas non plus.
        #expect(!overlay.replacePanelIfOffActiveSpace())
        #expect(overlay.panel === replacement)

        try await postSpaceChange(overlay)
        #expect(overlay.replacePanelIfOffActiveSpace())
        #expect(overlay.panel !== replacement)
        #expect(overlay.panel?.contentView === content)
        #expect(overlay.diagnosticState.spaceReplacements == 2)

        overlay.isOnActiveSpace = { _ in true }
        try await postSpaceChange(overlay)
        let current = overlay.panel
        #expect(!overlay.replacePanelIfOffActiveSpace())
        #expect(overlay.panel === current)
        #expect(overlay.diagnosticState.spaceReplacements == 2)
    }

    @Test func dictationShowsTheBubbleOnANewPanelWhenTheOldOneIsOffTheActiveSpace() async throws {
        _ = NSApplication.shared
        let f = try Fixture()
        let overlay = f.model.overlay
        overlay.displaysPanel = true
        overlay.install(model: f.model)
        let stale = try #require(overlay.panel)
        let content = try #require(stale.contentView)
        // Rien à l'écran : la fenêtre transparente, sans ombre, n'a plus que du vide à dessiner.
        content.isHidden = true
        let offSpace = OffSpace()
        offSpace.insert(stale)
        overlay.isOnActiveSpace = { !offSpace.contains($0) }
        defer {
            f.dispose()
            overlay.panel?.orderOut(nil)
            stale.orderOut(nil)
        }
        let coordinator = f.model.coordinator
        // Maintien : la bulle laisse passer la souris pendant tout le test.
        await coordinator.begin(.pushToTalk)
        #expect(coordinator.phase == .listening(.pushToTalk))
        let first = try #require(overlay.panel)
        #expect(first !== stale)
        #expect(first.isVisible)
        #expect(!stale.isVisible)
        #expect(first.contentView === content)
        #expect(first.ignoresMouseEvents)
        #expect(!first.isKeyWindow)
        #expect(overlay.state.presented)

        // Passage à une autre app en plein écran pendant que l'utilisateur parle.
        offSpace.insert(first)
        try await postSpaceChange(overlay)
        let deadline = Date().addingTimeInterval(0.6)
        while overlay.panel === first, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let second = try #require(overlay.panel)
        #expect(second !== first)
        #expect(second.isVisible)
        #expect(!first.isVisible)
        #expect(second.contentView === content)
        #expect(!second.isKeyWindow)
        #expect(coordinator.phase == .listening(.pushToTalk))
        #expect(f.audio.isRunning)
        #expect(f.audio.starts == 1)
        #expect(f.microphoneRequests == 1)

        // Un espace qui refuserait aussi le panneau neuf : une tentative, pas de remplacement en boucle.
        offSpace.insert(second)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(overlay.panel === second)
        #expect(second.isVisible)
        #expect(overlay.diagnosticState.spaceReplacements == 2)

        await coordinator.end()
        #expect(coordinator.phase == .idle)
        try await Task.sleep(nanoseconds: 1_050_000_000)
        #expect(!overlay.state.presented)
        #expect(!second.isVisible)
        #expect(!f.audio.isRunning)
        #expect(f.inserted == 1)
    }
}

@MainActor
struct AppRegressionTests {
    @Test func tooShortDictationIsDiscardedWithoutCallingTheAPI() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.audio.duration = 0.1
        await f.model.coordinator.begin(.pushToTalk)
        let url = try #require(f.audio.url)
        await f.model.coordinator.end()
        #expect(f.transcriptions == 0)
        #expect(f.inserted == 0)
        #expect(f.model.history.isEmpty)
        #expect(f.model.coordinator.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func dictationRecordsEachBilledCall() async throws {
        let f = try Fixture {
            $0.clean = { text, _, _, _ in
                let cleanup = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, tokens: TokenUsage(input: 80, output: 20), costUSD: 0.00005)
                return CleanupOutcome(text: text, usage: cleanup)
            }
        }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        // Flux en direct vide → repli fichier : les deux sont facturés, plus la correction.
        let apis = Set(f.model.usage.map(\.api))
        #expect(apis == [.xaiStreaming, .xaiFile, .deepSeekCleanup])
        let stream = try #require(f.model.usage.first { $0.api == .xaiStreaming })
        #expect(stream.audioSeconds == 2)
        #expect(abs((stream.costUSD ?? 0) - 0.20 * 2 / 3_600) < 1e-9)
        let stored = try f.model.store.usageEvents()
        #expect(stored.count == 3)
        #expect(f.model.usageSummary(for: .today).rows.count == 3)
    }

    @Test func interimThenDoneWithoutFinalUsesTheFile() async throws {
        let files = OSAllocatedUnfairLock(initialState: 0)
        let replay = UnfinalizedReplay()
        let f = try Fixture {
            $0.makeSession = { _ in replay }
            $0.transcribe = { _, _ in
                files.withLock { $0 += 1 }
                return "Phrase complète du fichier."
            }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        f.model.settings.learnCorrections = false
        f.model.settings.soundsEnabled = false
        // Vérification coupée : ce test verrouille le repli quand la fin du flux n'est pas finalisée.
        f.model.settings.verifyWithFile = false
        await f.model.coordinator.begin(.toggle)
        await f.model.coordinator.end()
        #expect(files.withLock { $0 } == 1)
        #expect(f.insertedTexts == ["Phrase complète du fichier."])
        #expect(f.model.usage.contains { $0.api == .xaiStreaming && $0.succeeded })
        #expect(f.model.usage.contains { $0.api == .xaiFile && $0.succeeded })
        let trace = try #require(try f.model.store.recentTraces(limit: 1).first)
        #expect(trace.streamFallback == .unfinalized)
        let kinds = replay.kinds()
        let finalize = try #require(kinds.firstIndex(of: "finalize"))
        let done = try #require(kinds.firstIndex(of: "audio.done"))
        let audio = try #require(kinds.firstIndex { $0.hasPrefix("audio:") })
        #expect(audio < finalize)
        #expect(finalize < done)
    }

    @Test func finalThenDoneDoesNotUseTheFile() async throws {
        let files = OSAllocatedUnfairLock(initialState: 0)
        let replay = FinalizedReplay()
        let f = try Fixture {
            $0.makeSession = { _ in replay }
            $0.transcribe = { _, _ in
                files.withLock { $0 += 1 }
                return "Phrase du fichier."
            }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        f.model.settings.learnCorrections = false
        f.model.settings.soundsEnabled = false
        // Vérification coupée : un flux finalisé ne rappelle pas le fichier.
        f.model.settings.verifyWithFile = false
        await f.model.coordinator.begin(.toggle)
        await f.model.coordinator.end()
        #expect(files.withLock { $0 } == 0)
        #expect(f.insertedTexts == ["Phrase finale du flux."])
        #expect(!f.model.usage.contains { $0.api == .xaiFile })
        let trace = try #require(try f.model.store.recentTraces(limit: 1).first)
        #expect(trace.streamFallback == nil)
    }

    @Test func shortCoverageUsesTheFileAndASmallGapDoesNot() async throws {
        let files = OSAllocatedUnfairLock(initialState: 0)
        let f = try Fixture {
            $0.transcribe = { _, _ in
                files.withLock { $0 += 1 }
                return "Phrase complète du fichier."
            }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        f.model.settings.learnCorrections = false
        // Vérification coupée : la couverture courte part au fichier, un petit trou reste au flux.
        f.model.settings.verifyWithFile = false
        f.audio.duration = 6
        f.stream.text = "Trop court."
        f.stream.endingFinalized = true
        f.stream.coveredSeconds = 1
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(files.withLock { $0 } == 1)
        #expect(f.insertedTexts == ["Phrase complète du fichier."])
        let trace = try #require(try f.model.store.recentTraces(limit: 1).first)
        #expect(trace.streamFallback == .shortCoverage)

        files.withLock { $0 = 0 }
        f.audio.duration = 4
        f.stream.text = "Phrase assez couverte."
        f.stream.endingFinalized = true
        f.stream.coveredSeconds = 2
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(files.withLock { $0 } == 0)
        #expect(f.insertedTexts.last == "Phrase assez couverte.")
    }

    @Test func failedFileTranscriptionIsCountedAsFailure() async throws {
        let f = try Fixture { $0.transcribe = { _, _ in throw URLError(.notConnectedToInternet) } }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        let file = try #require(f.model.usage.first { $0.api == .xaiFile })
        #expect(!file.succeeded)
        #expect(file.costUSD == nil)
    }

    @Test func silentVoiceProviderFallsBackToOpenAIAndSaysSo() async throws {
        let f = try Fixture {
            $0.transcribe = { _, speech in
                if speech.provider == .xai { throw URLError(.timedOut) }
                return "Phrase de secours."
            }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        // Le texte arrive quand même, transcrit par OpenAI, et la bulle le dit une fois.
        #expect(f.model.history.first?.finalText == "Phrase de secours.")
        #expect(f.model.history.first?.provider == ProviderID.openAI.rawValue)
        #expect(coordinator.relay == "OpenAI")
        #expect(coordinator.notice == "xAI ne répond pas : voix via OpenAI.")
        #expect(coordinator.noticeIsRelay)
        #expect(f.model.usage.contains { $0.api == .xaiFile && !$0.succeeded })
        #expect(f.model.usage.contains { $0.api == .openAIFile && $0.succeeded })
        // Deuxième échec : xAI est mis de côté, la dictée suivante part directement chez OpenAI, sans nouveau message.
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        #expect(f.model.health.isDown(ServiceHealth.voice(.xai)))
        await coordinator.begin(.pushToTalk)
        #expect(coordinator.relay == "OpenAI")
        coordinator.cancel()
    }

    @Test func pasteWithoutTextFieldOffersCopyWithCountdown() async throws {
        let box = CopyBox()
        let f = try Fixture {
            $0.insert = { _, _, _ in .noTarget }
            $0.copyText = { box.texts.append($0) }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        // Le texte n'est allé nulle part : il est déjà copié, la bulle le dit et propose Copier assez longtemps.
        #expect(f.model.coordinator.phase == .failure("Pas de champ où écrire : le texte est prêt"))
        #expect(f.model.coordinator.failureText == "Phrase de test.")
        #expect(box.texts == ["Phrase de test."])
        #expect(DictationCoordinator.failureSeconds >= 10)
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.noTarget.rawValue)
    }

    @Test func unconfirmedPasteDoesNotShowFailureOrDeleteRecoveryAudio() async throws {
        let f = try Fixture { $0.insert = { _, _, _ in .pasteSent } }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        f.model.settings.retention = .deleteOnSuccess
        await f.model.coordinator.begin(.pushToTalk)
        let audio = try #require(f.audio.url)
        await f.model.coordinator.end()
        // Une app qui cache son champ ne permet de conclure ni à l'échec, ni au succès confirmé.
        #expect(f.model.coordinator.phase == .idle)
        #expect(f.model.coordinator.failureText == nil)
        #expect(f.model.statusBanner == nil)
        let record = try #require(f.model.history.first)
        #expect(record.insertionStatus == InsertionStatus.pasteSent.rawValue)
        #expect(record.finalText == "Phrase de test.")
        #expect(record.audioPath == audio.path)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func speakersAreMutedWhileTalkingAndRestoredAfter() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.toggle)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(f.mutes == [.speakersOnly])
        await coordinator.end()
        #expect(f.restores == 1)
        // Annulation : le son revient aussi.
        await coordinator.begin(.toggle)
        try await Task.sleep(nanoseconds: 400_000_000)
        coordinator.cancel()
        #expect(f.mutes.count == 2)
        #expect(f.restores == 2)
        // Réglage coupé : rien n'est touché.
        f.model.settings.muteWhileDictating = false
        await coordinator.begin(.toggle)
        try await Task.sleep(nanoseconds: 400_000_000)
        coordinator.cancel()
        #expect(f.mutes.count == 2)
    }

    @Test func olderSavedSettingsGetTheMuteDefaults() throws {
        let old = Data(#"{"provider":"xai","soundsEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.muteWhileDictating)
        #expect(settings.muteMode == .speakersOnly)
    }

    @Test func mainWindowOpensOnTheActiveSpace() {
        #expect(MainWindow.openingBehavior.contains(.moveToActiveSpace))
        #expect(MainWindow.openingBehavior.contains(.fullScreenAuxiliary))
        // Fermée, réduite ou sur un autre bureau : elle vient sur le bureau actif.
        #expect(MainWindow.needsMoveToActiveSpace(isVisible: false, isOnActiveSpace: false))
        #expect(MainWindow.needsMoveToActiveSpace(isVisible: false, isOnActiveSpace: true))
        #expect(MainWindow.needsMoveToActiveSpace(isVisible: true, isOnActiveSpace: false))
        // Déjà visible ici : rien ne bouge.
        #expect(!MainWindow.needsMoveToActiveSpace(isVisible: true, isOnActiveSpace: true))
    }

    /// Régression : la fenêtre gardait `.moveToActiveSpace` et quittait sa place quand on passait au bureau ou à
    /// une autre app. Hors ouverture, elle se comporte comme une fenêtre ordinaire.
    @Test func mainWindowStaysOnItsSpaceOnceShown() {
        let f = try! Fixture()
        defer { f.dispose() }
        let window = MainWindow.make(model: f.model, offscreen: true)
        #expect(window.collectionBehavior == MainWindow.settledBehavior)
        #expect(!MainWindow.settledBehavior.contains(.moveToActiveSpace))
        #expect(!MainWindow.settledBehavior.contains(.canJoinAllSpaces))
        #expect(!MainWindow.settledBehavior.contains(.transient))
        #expect(!window.hidesOnDeactivate)
        #expect(window.level == .normal)
    }

    @Test func cleanupRelayIsRecordedAndAnnounced() async throws {
        let failed = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0, succeeded: false)
        let relayed = UsageEvent(api: .openAICleanup, model: CleanupModel.openAIFallback, tokens: TokenUsage(input: 300, output: 20), costUSD: 0.0003)
        let f = try Fixture {
            $0.clean = { text, _, _, _ in CleanupOutcome(text: text, usage: relayed, failedUsages: [failed], fallback: "OpenAI") }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(f.model.usage.contains { $0.api == .deepSeekCleanup && !$0.succeeded })
        #expect(f.model.usage.contains { $0.api == .openAICleanup && $0.succeeded })
        #expect(f.model.coordinator.relay == "OpenAI")
        #expect(f.model.coordinator.notice == "DeepSeek ne répond pas : correction via OpenAI.")
        // Après deux échecs, DeepSeek passe après le relais pour les dictées suivantes.
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(f.model.speechRequest(context: nil).cleanupPrimaryDown)
    }

    @Test func cancelledDictationStillCountsStreamedAudio() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        try await f.stream.started.value()
        f.model.coordinator.cancel()
        #expect(f.model.usage.map(\.api) == [.xaiStreaming])
        #expect(f.model.usage.first?.costUSD == nil)
    }

    @Test func cancellationBeforeStreamingStartsDoesNotInventAnAPICall() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        // Le nouveau Task n'a pas encore repris sur cet acteur : aucun handshake n'a commencé.
        f.model.coordinator.cancel()
        await Task.yield()
        #expect(f.model.usage.isEmpty)
        #expect(f.transcriptions == 0)
    }

    @Test func insertedDictationWatchesCorrectionsAndLearns() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        try f.model.store.addTerm("OpenAI")
        f.model.reload()
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        let watch = try #require(f.watches.first)
        #expect(watch.0 == "Phrase de test.")
        #expect(watch.1 == 4242)
        #expect(watch.2 == ["OpenAI"])
        watch.3([
            CorrectionLearner.Candidate(heard: "Sidance", corrected: "Seedance"),
            CorrectionLearner.Candidate(heard: "open ai", corrected: "openai")
        ])
        await f.model.learning?.value
        // Le mot déjà connu n'est même pas soumis au juge.
        #expect(f.judged == [[CorrectionLearner.Candidate(heard: "Sidance", corrected: "Seedance")]])
        #expect(f.model.dictionary.map(\.term).sorted() == ["OpenAI", "Seedance"])
        #expect(f.model.coordinator.learnedNotice == ["Seedance"])
        #expect(f.model.usage.first?.api == .deepSeekCleanup)
    }

    @Test func correctionJudgedIrrelevantIsNotLearned() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.approved = ["Seedance"]
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        let watch = try #require(f.watches.first)
        watch.3([
            CorrectionLearner.Candidate(heard: "commande", corrected: "Commande"),
            CorrectionLearner.Candidate(heard: "Sidance", corrected: "Seedance")
        ])
        await f.model.learning?.value
        #expect(f.model.dictionary.map(\.term) == ["Seedance"])
        #expect(f.model.coordinator.learnedNotice == ["Seedance"])
        f.approved = []
        watch.3([CorrectionLearner.Candidate(heard: "bonjour", corrected: "Bonjour")])
        await f.model.learning?.value
        #expect(f.model.dictionary.map(\.term) == ["Seedance"])
        // L'appel de jugement compte dans la consommation, même quand rien n'est retenu.
        #expect(f.model.usage.filter { $0.api == .deepSeekCleanup }.count == 2)
    }

    @Test func learningCanBeTurnedOff() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.settings.learnCorrections = false
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(f.watches.isEmpty)
    }

    @Test func soundCuesFollowSettings() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(f.cues == [.start, .stop])
        f.model.settings.soundsEnabled = false
        await f.model.coordinator.begin(.toggle)
        f.model.coordinator.cancel()
        #expect(f.cues == [.start, .stop])
    }

    @Test func startSoundWaitsForTheFirstAudioPacketAndPlaysOnce() async throws {
        let heard = AsyncResult<Void>()
        var cues: [DictationCue] = []
        let f = try Fixture {
            $0.playCue = { cue in
                cues.append(cue)
                if cue == .start { heard.resolve(.success(())) }
            }
        }
        defer { f.dispose() }
        f.audio.emitsPCMOnStart = false
        await f.model.coordinator.begin(.toggle)
        #expect(cues.isEmpty)
        f.audio.onPCM?(Data())
        #expect(cues.isEmpty)
        f.audio.onPCM?(Data([0, 0]))
        try await heard.value()
        f.audio.onPCM?(Data([0, 0]))
        await Task.yield()
        #expect(cues == [.start])
        let sound = try #require(NSSound(data: SoundCues.startSignalData()))
        #expect(sound.duration > 0.1 && sound.duration < 0.25)
    }

    @Test func cancelledAudioCannotPlayAStartSoundInTheNextDictation() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.audio.emitsPCMOnStart = false
        await f.model.coordinator.begin(.toggle)
        let latePacket = f.audio.onPCM
        f.model.coordinator.cancel()
        #expect(f.cues == [.cancel])
        await f.model.coordinator.begin(.toggle)
        latePacket?(Data([0, 0]))
        await Task.yield()
        #expect(f.cues == [.cancel])
    }

    @Test func cancellationDuringAudioStartupKeepsUIResponsiveAndDiscardsLateAudio() async throws {
        let entered = AsyncResult<Void>()
        let gate = AsyncResult<Void>()
        let f = try Fixture()
        defer { f.dispose() }
        f.audio.startGate = gate
        f.audio.onStarting = { entered.resolve(.success(())) }
        let begin = Task { await f.model.coordinator.begin(.toggle) }
        try await entered.value()
        #expect(f.model.coordinator.phase == .starting)
        f.model.coordinator.cancel()
        gate.resolve(.success(()))
        await begin.value
        #expect(f.model.coordinator.phase == .idle)
        #expect(!f.audio.isRunning)
        #expect(!f.cues.contains(.start))
        #expect(f.transcriptions == 0 && f.inserted == 0)
        let audio = try #require(f.audio.url)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    // MARK: Démarrage du micro (première dictée après un lancement)

    @Test func audioStartThatHangsEndsWithMessageAndNextDictationWorks() async throws {
        let gate = AsyncResult<Void>()
        let f = try Fixture()
        defer {
            gate.resolve(.success(()))
            f.dispose()
        }
        f.audio.startGate = gate
        f.model.coordinator.audioStartLimit = 0.05
        await f.model.coordinator.begin(.toggle)
        // La bulle ne reste pas figée : elle dit pourquoi, sans bouton Historique (rien n'a été enregistré).
        #expect(f.model.coordinator.phase == .failure(DictationCoordinator.microphoneStalledMessage))
        #expect(!f.model.coordinator.failureOffersHistory)
        #expect(f.model.statusBanner == DictationCoordinator.microphoneStalledMessage)
        #expect(f.audio.abandoned == 1)
        #expect(!f.cues.contains(.start))
        // Le démarrage lent finit par rendre la main : la dictée abandonnée ne reprend pas.
        f.audio.startGate = nil
        gate.resolve(.success(()))
        let finished = await waitFor { f.audio.finishedStarts == 1 }
        #expect(finished)
        #expect(f.model.coordinator.phase == .failure(DictationCoordinator.microphoneStalledMessage))
        // Un nouvel appui relance une dictée, message encore affiché ; délai réel (en CI, les tests se partagent
        // le fil principal : 50 ms ne suffiraient pas à un démarrage normal).
        f.model.coordinator.audioStartLimit = MicrophoneStartWatch.startLimit
        await f.model.coordinator.begin(.toggle)
        #expect(f.model.coordinator.phase == .listening(.toggle))
        let heard = await waitFor { f.cues.contains(.start) }
        #expect(heard)
    }

    @Test func silentMicrophoneRestartsOnceThenListensNormally() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.audio.emitsPCMOnStart = false
        f.model.coordinator.firstPacketLimit = 0.05
        await f.model.coordinator.begin(.toggle)
        #expect(f.model.coordinator.phase == .listening(.toggle))
        #expect(!f.cues.contains(.start))
        // Moteur muet au premier démarrage : relancé une fois, le son de début suit le premier vrai paquet.
        let heard = await waitFor { f.cues.contains(.start) }
        #expect(heard)
        #expect(f.audio.restarts == 1)
        #expect(f.model.coordinator.phase == .listening(.toggle))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(f.audio.restarts == 1)
        #expect(f.model.coordinator.phase == .listening(.toggle))
        await f.model.coordinator.end()
        #expect(f.inserted == 1)
    }

    @Test func microphoneThatStaysSilentEndsWithMessageAndNextDictationWorks() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.audio.emitsPCMOnStart = false
        f.audio.restartEmitsPCM = false
        f.model.coordinator.firstPacketLimit = 0.05
        await f.model.coordinator.begin(.toggle)
        let failed = await waitFor { f.model.coordinator.phase == .failure(DictationCoordinator.microphoneStalledMessage) }
        #expect(failed)
        #expect(f.audio.restarts == 1)
        #expect(!f.audio.isRunning)
        #expect(!f.cues.contains(.start))
        #expect(!f.model.coordinator.failureOffersHistory)
        #expect(f.transcriptions == 0 && f.inserted == 0)
        let audio = try #require(f.audio.url)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        // Wispad est de nouveau prêt : la dictée suivante écoute et entend.
        f.audio.emitsPCMOnStart = true
        await f.model.coordinator.begin(.toggle)
        #expect(f.model.coordinator.phase == .listening(.toggle))
        let heard = await waitFor { f.cues.contains(.start) }
        #expect(heard)
    }

    @Test func audioStartErrorIsShownInTheBubble() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.audio.startError = AudioCaptureError.noInput
        await f.model.coordinator.begin(.pushToTalk)
        let message = try #require(AudioCaptureError.noInput.errorDescription)
        #expect(f.model.coordinator.phase == .failure(message))
        #expect(f.model.statusBanner == message)
        #expect(!f.model.coordinator.failureOffersHistory)
        #expect(!f.cues.contains(.start))
    }

    @Test func releaseDuringSlowAudioStartStillEndsTheDictation() async throws {
        let entered = AsyncResult<Void>()
        let gate = AsyncResult<Void>()
        let f = try Fixture()
        defer { f.dispose() }
        f.audio.startGate = gate
        f.audio.onStarting = { entered.resolve(.success(())) }
        let coordinator = f.model.coordinator
        coordinator.enqueue { await coordinator.begin(.pushToTalk) }
        // Touche relâchée pendant le démarrage à froid : la fin attend son tour, elle n'est pas perdue.
        coordinator.enqueue { coordinator.endCapture() }
        try await entered.value()
        #expect(coordinator.phase == .starting)
        gate.resolve(.success(()))
        let pasted = await waitFor { f.inserted == 1 }
        #expect(pasted)
        #expect(coordinator.phase == .idle)
        #expect(!f.audio.isRunning)
    }

    @Test func cancellingPlaysCancelCue() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        f.model.coordinator.cancel()
        #expect(f.cues == [.start, .cancel])
    }

    @Test func overlayRendersCompactlyInEveryState() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        let coordinator = f.model.coordinator
        let state = f.model.overlay.state
        let snapshots = ProcessInfo.processInfo.environment["WISPAD_OVERLAY_SNAPSHOTS"]
        let states: [(String, DictationPhase)] = [
            ("ecoute", .listening(.pushToTalk)),
            ("mains-libres", .listening(.toggle)),
            ("finalisation", .finishing),
            ("erreur", .failure("Transcription impossible. L'audio est gardé dans l'historique.")),
            ("erreur-survol", .failure("Transcription impossible. L'audio est gardé dans l'historique."))
        ]
        coordinator.spectrum = [0.15, 0.3, 0.55, 0.8, 0.95, 1, 0.9, 0.7, 0.45, 0.25, 0.1]
        coordinator.failureText = "Phrase de test."
        state.presented = true
        var failureSize: CGSize?
        for (name, phase) in states {
            coordinator.phase = phase
            state.mode = try #require(OverlayMode(phase))
            state.isHovered = name == "erreur-survol"
            // Rendu hors écran : style de repli, le Liquid Glass n'est dessiné que dans une vraie fenêtre.
            let pill = ImageRenderer(content: OverlayCluster(mode: state.mode)
                .environment(f.model)
                .environment(\.colorScheme, .dark)
                .environment(\.overlayGlass, false))
            pill.scale = 2
            let image = try #require(pill.nsImage)
            if case .failure = phase {
                // L'erreur tient sur une ligne, dans le panneau fixe.
                #expect(image.size.width <= OverlayLayout.panelSize.width - 40)
                #expect(image.size.height <= OverlayLayout.pillHeight + 1)
                if let failureSize { #expect(image.size == failureSize) }
                failureSize = image.size
            } else {
                // Pilule discrète : ~30 pt de haut, boutons compris en mains libres.
                #expect(image.size.height <= OverlayLayout.pillHeight + 1)
                #expect(image.size.width <= 170)
            }
            // Le panneau garde la même taille dans tous les états : plus de saut de fenêtre.
            let canvas = ImageRenderer(content: OverlayBar().environment(f.model))
            let whole = try #require(canvas.nsImage)
            #expect(whole.size == OverlayLayout.panelSize)
            if let snapshots, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: snapshots).appendingPathComponent("\(name).png"))
            }
        }
        coordinator.phase = .idle
        coordinator.failureText = nil
    }

    @Test func learnedWordIsShownBrieflyAndGivesWayToDictation() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        let message = DictationCoordinator.learningMessage("Seedance")
        #expect(message == "« Seedance » ajouté au dictionnaire. Le garder ?")
        coordinator.notifyLearned(["Seedance"])
        #expect(coordinator.notice == message)
        #expect(coordinator.learningOffer == "Seedance")
        #expect(OverlayMode.resolve(phase: coordinator.phase, notice: coordinator.notice, confirmsLearning: true) == .learning(message))
        #expect(OverlayMode.learning("x").isInteractive)
        #expect(!OverlayMode.notice("x").isInteractive)
        // Une dictée qui commence remplace le message, sans le perdre.
        await coordinator.begin(.pushToTalk)
        #expect(coordinator.notice == nil)
        #expect(OverlayMode.resolve(phase: coordinator.phase, notice: coordinator.notice) == .listening)
        coordinator.notifyLearned(["OpenRouter"])
        #expect(coordinator.notice == nil)
        coordinator.cancel()
        #expect(coordinator.notice == message)
        #expect(f.model.dictionary.isEmpty)
    }

    @Test func keepingOrRefusingALearnedWord() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        f.model.learn(["Seedance", "OpenRouter"])
        #expect(f.model.dictionary.map(\.term) == ["OpenRouter", "Seedance"])
        #expect(coordinator.notice == DictationCoordinator.learningMessage("Seedance"))
        coordinator.acceptLearning()
        #expect(coordinator.notice == DictationCoordinator.learningMessage("OpenRouter"))
        #expect(f.model.dictionary.map(\.term) == ["OpenRouter", "Seedance"])
        coordinator.declineLearning()
        #expect(coordinator.notice == nil)
        #expect(f.model.dictionary.map(\.term) == ["Seedance"])
        #expect(try f.model.store.hasRefused("OpenRouter"))
        #expect(try !f.model.store.hasRefused("Seedance"))

        let path = f.model.supportURL.appendingPathComponent("wispad.sqlite").path
        let reopened = try HistoryStore(path: path)
        #expect(try reopened.hasRefused("openrouter"))
        #expect(try reopened.dictionary().map(\.term) == ["Seedance"])

        let speech = SpeechRequest(provider: .xai, liveModel: "m", fileModel: "m", apiKey: "x", language: .french, keyterms: [], prompt: "")
        f.model.considerLearning(
            [CorrectionLearner.Candidate(heard: "open router", corrected: "OpenRouter")],
            dictated: "On passe par open router.",
            speech: speech
        )
        await f.model.learning?.value
        #expect(f.judged.isEmpty)
        #expect(f.model.dictionary.map(\.term) == ["Seedance"])

        f.model.considerLearning(
            [CorrectionLearner.Candidate(heard: "cloude", corrected: "Cloudflare")],
            dictated: "Le cache est chez cloude.",
            speech: speech
        )
        await f.model.learning?.value
        #expect(f.judged.map { $0.map(\.corrected) } == [["Cloudflare"]])
        #expect(f.model.dictionary.map(\.term).sorted() == ["Cloudflare", "Seedance"])
    }

    @Test func learningOfferWaitsUntilTheDictationEnds() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        f.model.learn(["Seedance"])
        #expect(coordinator.notice == nil)
        #expect(coordinator.phase != .idle)
        #expect(f.model.dictionary.map(\.term) == ["Seedance"])
        coordinator.cancel()
        #expect(coordinator.phase == .idle)
        #expect(coordinator.notice == DictationCoordinator.learningMessage("Seedance"))
        #expect(f.model.dictionary.map(\.term) == ["Seedance"])
    }

    @Test func unansweredLearningOfferKeepsTheWord() throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        #expect(DictationCoordinator.learningSeconds == 8)
        f.model.learn(["Seedance"])
        #expect(f.model.coordinator.notice == DictationCoordinator.learningMessage("Seedance"))
        // Même geste que la minuterie de 8 s : le mot reste, le message part, rien n'est refusé.
        f.model.coordinator.dismissCurrentNotice()
        #expect(f.model.coordinator.notice == nil)
        #expect(f.model.dictionary.map(\.term) == ["Seedance"])
        #expect(try !f.model.store.hasRefused("Seedance"))
    }

    @Test func messagesFitOnOneLine() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        let snapshots = ProcessInfo.processInfo.environment["WISPAD_OVERLAY_SNAPSHOTS"]
        for (name, mode) in [("message-appris", OverlayMode.notice("Ajouté au dictionnaire : Seedance")),
                             ("message-confirmation", .learning("« Seedance » ajouté au dictionnaire. Le garder ?")),
                             ("message-erreur", .failure("Insertion impossible. Texte gardé dans l'historique.")),
                             ("message-relais", .notice("DeepSeek ne répond pas : correction via OpenAI."))] {
            let renderer = ImageRenderer(content: OverlayCluster(mode: mode)
                .environment(f.model)
                .environment(\.colorScheme, .dark)
                .environment(\.overlayGlass, false))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size.height <= OverlayLayout.pillHeight + 1)
            #expect(image.size.width <= OverlayLayout.panelSize.width - 40)
            if let snapshots, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: snapshots).appendingPathComponent("\(name).png"))
            }
        }
    }

    @Test func overlayIsBornFromABottomDot() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        let snapshots = ProcessInfo.processInfo.environment["WISPAD_OVERLAY_SNAPSHOTS"]
        f.model.coordinator.phase = .listening(.pushToTalk)
        f.model.coordinator.spectrum = Array(repeating: 0.6, count: DictationCoordinator.barCount)
        var boxes: [CGFloat: CGRect] = [:]
        for progress: CGFloat in [0.1, 0.4, 0.7, 1] {
            let renderer = ImageRenderer(content: OverlayCluster(mode: .listening)
                .modifier(OverlayBirth(progress: progress))
                .environment(f.model)
                .environment(\.colorScheme, .dark)
                .environment(\.overlayGlass, false))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            boxes[progress] = Self.opaqueBox(rep)
            if let snapshots, let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: snapshots).appendingPathComponent("naissance-\(Int(progress * 100)).png"))
            }
        }
        let dot = try #require(boxes[0.1])
        let full = try #require(boxes[1])
        // Au début, un point d'une vingtaine de points au plus, posé en bas au centre.
        #expect(dot.width <= 24)
        #expect(dot.height <= 24)
        #expect(abs(dot.midX - full.midX) <= 1)
        #expect(abs(dot.maxY - full.maxY) <= 4)
        // Puis la pilule s'étire sans à-coup jusqu'à sa largeur.
        let middle = try #require(boxes[0.4])
        let late = try #require(boxes[0.7])
        #expect(dot.width < middle.width)
        #expect(middle.width < late.width)
        #expect(late.width < full.width)
        #expect(abs(full.width - OverlayLayout.spectrumPillWidth) <= 2)
    }

    /// Cadre, en points, des pixels au moins à moitié aussi opaques que le plus opaque (le flou ne compte pas).
    private static func opaqueBox(_ rep: NSBitmapImageRep) -> CGRect {
        var alphas: [[CGFloat]] = []
        for y in 0..<rep.pixelsHigh {
            alphas.append((0..<rep.pixelsWide).map { rep.colorAt(x: $0, y: y)?.alphaComponent ?? 0 })
        }
        let threshold = (alphas.joined().max() ?? 0) * 0.5
        var box = CGRect.null
        for (y, row) in alphas.enumerated() {
            for (x, alpha) in row.enumerated() where alpha >= threshold && alpha > 0 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return CGRect(x: box.minX / scale, y: box.minY / scale, width: box.width / scale, height: box.height / scale)
    }

    @Test func overlayModeFollowsPhaseAndOnlyButtonStatesCatchTheMouse() {
        #expect(OverlayMode(.idle) == nil)
        #expect(OverlayMode(.starting) == .listening)
        #expect(OverlayMode(.listening(.pushToTalk)) == .listening)
        #expect(OverlayMode(.listening(.toggle)) == .handsFree)
        #expect(OverlayMode(.finishing) == .finishing)
        #expect(OverlayMode(.failure("x")) == .failure("x"))
        #expect(!OverlayMode.listening.isInteractive)
        #expect(!OverlayMode.finishing.isInteractive)
        #expect(OverlayMode.handsFree.isInteractive)
        #expect(OverlayMode.failure("x").isInteractive)
        #expect(OverlayMode.learning("x").isInteractive)
        #expect(!OverlayMode.notice("x").isInteractive)
    }

    @Test func overlaySitsJustAboveTheDockOrNearTheScreenEdge() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        // Dock en bas : la pilule repose 6 pt au-dessus de son bord haut.
        let withDock = NSRect(x: 0, y: 72, width: 1512, height: 877)
        #expect(OverlayLayout.pillBottom(screen: screen, visible: withDock, dockShown: true) == 78)
        let panel = OverlayLayout.panelFrame(screen: screen, visible: withDock, dockShown: true)
        #expect(panel.size == OverlayLayout.panelSize)
        #expect(panel.minY + OverlayLayout.bottomMargin == 78)
        #expect(panel.midX == withDock.midX)
        // App en plein écran : le Dock est caché mais visibleFrame lui garde sa place (minY = 59).
        // La pilule descend à 10 pt du bas au lieu de flotter 65 pt au-dessus du contenu.
        let fullScreenVisible = NSRect(x: 0, y: 59, width: 1512, height: 890)
        #expect(OverlayLayout.pillBottom(screen: screen, visible: fullScreenVisible, dockShown: false) == 10)
        #expect(OverlayLayout.panelFrame(screen: screen, visible: fullScreenVisible, dockShown: false).minY == 0)
        // Dock masqué ou sur le côté : 10 pt du bas de l'écran, que sa fenêtre soit là ou non.
        let dockOnLeft = NSRect(x: 64, y: 0, width: 1448, height: 949)
        #expect(OverlayLayout.pillBottom(screen: screen, visible: dockOnLeft, dockShown: true) == 10)
        #expect(OverlayLayout.pillBottom(screen: screen, visible: dockOnLeft, dockShown: false) == 10)
        #expect(OverlayLayout.panelFrame(screen: screen, visible: dockOnLeft, dockShown: true).minY == 0)
        // Écran secondaire placé sous le principal : mêmes règles, en coordonnées globales.
        let lower = NSRect(x: -200, y: -1080, width: 1920, height: 1080)
        let lowerVisible = NSRect(x: -200, y: -1010, width: 1920, height: 985)
        #expect(OverlayLayout.pillBottom(screen: lower, visible: lowerVisible, dockShown: true) == -1004)
        #expect(OverlayLayout.pillBottom(screen: lower, visible: lowerVisible, dockShown: false) == -1070)
    }

    @Test func dockCountsOnlyWhenItsWindowIsOnThatScreen() {
        let level = Int(CGWindowLevelForKey(.dockWindow))
        func window(pid: pid_t, layer: Int, _ bounds: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowBounds as String: bounds.dictionaryRepresentation]
        }
        let main = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let dock: Set<pid_t> = [640]
        // Bureau ordinaire : la fenêtre du Dock (niveau Dock, tout l'écran) est affichée.
        let desktop = [window(pid: 640, layer: level, CGRect(x: 0, y: 0, width: 1512, height: 982))]
        #expect(OverlayLayout.dockShown(on: main, primaryHeight: 982, windows: desktop, dockPIDs: dock))
        // Espace plein écran : elle n'est plus dans la liste des fenêtres à l'écran.
        #expect(!OverlayLayout.dockShown(on: main, primaryHeight: 982, windows: [], dockPIDs: dock))
        // Autres fenêtres du Dock (autre niveau) ou autre app au niveau du Dock : ne comptent pas.
        let others = [
            window(pid: 640, layer: 0, CGRect(x: 0, y: 900, width: 1512, height: 82)),
            window(pid: 77, layer: level, CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ]
        #expect(!OverlayLayout.dockShown(on: main, primaryHeight: 982, windows: others, dockPIDs: dock))
        // Écran secondaire sous le principal : en coordonnées CoreGraphics (y vers le bas), il commence à y = 982.
        let lower = NSRect(x: -200, y: -1080, width: 1920, height: 1080)
        let dockBelow = [window(pid: 640, layer: level, CGRect(x: -200, y: 982, width: 1920, height: 1080))]
        #expect(OverlayLayout.dockShown(on: lower, primaryHeight: 982, windows: dockBelow, dockPIDs: dock))
        #expect(!OverlayLayout.dockShown(on: main, primaryHeight: 982, windows: dockBelow, dockPIDs: dock))
    }

    @Test func overlayMorphsBetweenStatesOnceShownButIsBornInItsState() async throws {
        _ = NSApplication.shared
        let f = try Fixture()
        defer { f.dispose() }
        let overlay = f.model.overlay
        overlay.displaysPanel = false
        overlay.install(model: f.model)
        let coordinator = f.model.coordinator
        // Sonde : la transaction de chaque changement de mode, telle que la vue la reçoit.
        let log = TransactionLog()
        let probe = NSHostingView(rootView: ModeProbe(state: overlay.state, log: log))
        probe.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        func settle() async throws {
            // La vue hôte et l'observation de la phase avancent pendant que le test attend, comme dans l'app.
            try await Task.sleep(nanoseconds: 40_000_000)
            probe.layoutSubtreeIfNeeded()
        }
        try await settle()
        // Dictée précédente terminée en mains libres : la nouvelle bulle naît directement en maintien.
        overlay.state.mode = .handsFree
        try await settle()
        log.entries.removeAll()
        coordinator.phase = .starting
        overlay.show()
        try await settle()
        #expect(log.entries.last?.mode == .listening)
        #expect(log.entries.last?.disablesAnimations == true)
        // Chemin du coordinateur : phase puis show(), bulle déjà affichée → ressort, jamais de saut.
        let reachedByShow: [DictationPhase] = [
            .listening(.toggle),
            .finishing,
            .failure("Transcription impossible. L'audio est gardé dans l'historique."),
        ]
        for phase in reachedByShow {
            coordinator.phase = phase
            overlay.show()
            try await settle()
            let entry = try #require(log.entries.last)
            #expect(entry.mode == OverlayMode(phase))
            #expect(!entry.disablesAnimations)
            #expect(entry.animated)
        }
        // Sans show() (finalisation déclenchée par l'observation de la phase) : même ressort.
        coordinator.phase = .listening(.pushToTalk)
        try await settle()
        #expect(log.entries.last?.mode == .listening)
        #expect(log.entries.last?.animated == true)
        coordinator.phase = .idle
        overlay.hide()
        #expect(!overlay.isMonitoringMouse)
    }

    @Test func reducedMotionKeepsHiddenButtonsOutOfTheGlass() {
        // Mouvement réduit : ✕ et ■ ne sont là qu'en mains libres, sinon leur verre resterait dessiné.
        #expect(OverlayCluster.showsOrbs(.handsFree, reduceMotion: true))
        #expect(!OverlayCluster.showsOrbs(.listening, reduceMotion: true))
        #expect(!OverlayCluster.showsOrbs(.finishing, reduceMotion: true))
        #expect(!OverlayCluster.showsOrbs(.failure("x"), reduceMotion: true))
        // Mouvement normal : ils restent fondus sous la pilule pour pouvoir en sortir en glissant.
        #expect(OverlayCluster.showsOrbs(.listening, reduceMotion: false))
        #expect(OverlayCluster.showsOrbs(.finishing, reduceMotion: false))
        // Le changement de mode d'une bulle affichée suit le réglage : ressort ou fondu, jamais coupé.
        let morph = OverlayController.modeTransaction(appearing: false, reduceMotion: false)
        let fade = OverlayController.modeTransaction(appearing: false, reduceMotion: true)
        let birth = OverlayController.modeTransaction(appearing: true, reduceMotion: false)
        #expect(morph.animation == OverlayStyle.morph && !morph.disablesAnimations)
        #expect(fade.animation == OverlayStyle.fade && !fade.disablesAnimations)
        #expect(birth.animation == nil && birth.disablesAnimations)
    }

    @Test func overlayHitTestConvertsScreenPointsIntoThePanel() {
        // Panneau en coordonnées écran (origine en bas à gauche), pilule en coordonnées SwiftUI (en haut à gauche).
        let panel = NSRect(x: 476, y: 68, width: 560, height: 84)
        let pill = CGRect(x: 203, y: 44, width: 154, height: 30)
        // Centre de la pilule : x = 476 + 280, y = 152 - 59.
        #expect(OverlayLayout.pill(pill, in: panel, contains: NSPoint(x: 756, y: 93)))
        // Coins intérieurs.
        #expect(OverlayLayout.pill(pill, in: panel, contains: NSPoint(x: 476 + 204, y: 152 - 45)))
        #expect(OverlayLayout.pill(pill, in: panel, contains: NSPoint(x: 476 + 356, y: 152 - 73)))
        // Zone transparente du panneau, au-dessus et sur les côtés : la souris passe à travers.
        #expect(!OverlayLayout.pill(pill, in: panel, contains: NSPoint(x: 756, y: 152 - 20)))
        #expect(!OverlayLayout.pill(pill, in: panel, contains: NSPoint(x: 476 + 100, y: 93)))
        #expect(!OverlayLayout.pill(pill, in: panel, contains: NSPoint(x: 476 + 400, y: 93)))
        // Sous la pilule (marge d'ombre) et hors du panneau.
        #expect(!OverlayLayout.pill(pill, in: panel, contains: NSPoint(x: 756, y: 70)))
        #expect(!OverlayLayout.pill(pill, in: panel, contains: NSPoint(x: 756, y: 20)))
        // Pilule absente (pas encore mesurée ou retirée) : rien ne capte la souris.
        #expect(!OverlayLayout.pill(.zero, in: panel, contains: NSPoint(x: 476, y: 152)))
        // Écran à gauche du principal : coordonnées négatives.
        let left = NSRect(x: -1200, y: 300, width: 560, height: 84)
        #expect(OverlayLayout.pill(pill, in: left, contains: NSPoint(x: -1200 + 280, y: 384 - 59)))
        #expect(!OverlayLayout.pill(pill, in: left, contains: NSPoint(x: 756, y: 93)))
    }

    @Test func overlayPanelNeverTakesFocusAndKeepsOneSize() throws {
        _ = NSApplication.shared
        let f = try Fixture()
        defer { f.dispose() }
        f.model.overlay.install(model: f.model)
        let panel = try #require(f.model.overlay.panel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.ignoresMouseEvents)
        #expect(panel.frame.size == OverlayLayout.panelSize)
        #expect(!panel.isVisible)
        #expect(!f.model.overlay.isMonitoringMouse)
    }

    @Test func spectrumSmoothingIsTheSameAt60And120Hz() {
        var at60: [Float] = [0]
        var at120: [Float] = [0]
        for _ in 0..<4 { at60 = DictationCoordinator.smoothed(at60, toward: [1], elapsed: 1.0 / 60) }
        for _ in 0..<8 { at120 = DictationCoordinator.smoothed(at120, toward: [1], elapsed: 1.0 / 120) }
        #expect(abs(at60[0] - at120[0]) < 0.001)
        for _ in 0..<4 { at60 = DictationCoordinator.smoothed(at60, toward: [0], elapsed: 1.0 / 60) }
        for _ in 0..<8 { at120 = DictationCoordinator.smoothed(at120, toward: [0], elapsed: 1.0 / 120) }
        #expect(abs(at60[0] - at120[0]) < 0.001)
        // Une image très en retard (écran en veille) ne fait pas sauter la barre au-delà de sa cible.
        let late = DictationCoordinator.smoothed([0], toward: [1], elapsed: 5)
        #expect(late[0] <= 1)
    }

    @Test func spectrumRisesFastAndFallsGently() {
        var level: [Float] = [0]
        for _ in 0..<4 { level = DictationCoordinator.smoothed(level, toward: [1]) }
        // Montée : plus de 90 % en 4 images (~67 ms).
        #expect(level[0] > 0.9)
        for _ in 0..<4 { level = DictationCoordinator.smoothed(level, toward: [0]) }
        // Retombée : encore plus de la moitié après 4 images.
        #expect(level[0] > 0.5)
        var previous = level[0]
        for _ in 0..<60 {
            level = DictationCoordinator.smoothed(level, toward: [0])
            // Décroissance monotone, sans rebond.
            #expect(level[0] <= previous)
            previous = level[0]
        }
        // Silence complet en une seconde.
        #expect(level[0] == 0)
    }

    @Test func legacySettingsKeepTheirValuesWhenNewKeysAppear() throws {
        let legacy = #"{"provider":"openai","keyCode":63,"modifierFlags":8388608,"cleanupEnabled":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(settings.provider == .openAI)
        #expect(settings.keyCode == 63)
        #expect(settings.cleanupEnabled == false)
        #expect(settings.soundsEnabled)
        #expect(settings.temporaryHours == AppSettings().temporaryHours)
    }

    @Test func missingStoredKeyDoesNotOpenMicrophoneOrUseDraft() async throws {
        let f = try Fixture { $0.loadKey = { _ in nil } }
        defer { f.dispose() }
        f.model.keyDrafts["xai"] = "unsaved-fixture"
        await f.model.coordinator.begin(.pushToTalk)
        #expect(f.audio.starts == 0)
        #expect(f.microphoneRequests == 0)
        #expect(f.model.selectedSection == .providers)
    }

    @Test func apiFailurePreservesAudioAndAllowsAnotherDictation() async throws {
        let f = try Fixture { $0.transcribe = { _, _ in throw URLError(.notConnectedToInternet) } }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        let record = try #require(f.model.history.first)
        #expect(record.insertionStatus == InsertionStatus.transcriptionFailed.rawValue)
        #expect(record.finalText.isEmpty)
        let path = try #require(record.audioPath)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(f.inserted == 0)
        f.model.coordinator.cancel()
        #expect(f.model.coordinator.phase == .idle)
        #expect(FileManager.default.fileExists(atPath: path))
        await f.model.coordinator.begin(.toggle)
        #expect(f.model.coordinator.isListening)
        #expect(f.audio.starts == 2)
    }

    @Test func insertionFailureCanRestartWithoutDeletingPreviousAudio() async throws {
        let f = try Fixture { $0.insert = { _, _, _ in .failed } }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        let path = try #require(f.model.history.first?.audioPath)
        await f.model.coordinator.begin(.toggle)
        #expect(f.model.coordinator.isListening)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func editingTheKeyDuringVerificationNeverSavesTheOldValue() async throws {
        let started = AsyncResult<Void>()
        let response = AsyncResult<Int>()
        var saved: [String] = []
        let f = try Fixture {
            $0.validateKey = { _ in started.resolve(.success(())); return try await response.value() }
            $0.saveKey = { account, _ in saved.append(account); return true }
        }
        defer { f.dispose() }
        f.model.keyDrafts["xai"] = "fixture-secret"
        let task = Task { await f.model.verifyAndStoreKey("xai") }
        try await started.value()
        f.model.keyDrafts["xai"] = "fixture-secret-edited"
        response.resolve(.success(200))
        await task.value
        #expect(saved.isEmpty)
        #expect(f.model.keyDrafts["xai"] == "fixture-secret-edited")
        #expect(!f.model.verifyingKeys.contains("xai"))
    }

    @Test func verifiedKeyIsSavedUnderItsOwnAccountOnly() async throws {
        var saved: [String] = []
        var checked: [URL] = []
        let f = try Fixture {
            $0.validateKey = { request in checked.append(request.url!); return 200 }
            $0.saveKey = { account, _ in saved.append(account); return true }
        }
        defer { f.dispose() }
        f.model.keyDrafts["deepseek"] = "  fixture-secret  "
        await f.model.verifyAndStoreKey("deepseek")
        #expect(saved == ["deepseek"])
        #expect(checked.map(\.absoluteString) == ["https://api.deepseek.com/models"])
        #expect(f.model.keyDrafts["deepseek"] == nil)
        #expect(f.model.keyMessages["deepseek"]?.hasPrefix("Clé enregistrée") == true)
    }

    @Test func refusedOrUnverifiedKeysAreNeverSaved() async throws {
        var saved = 0
        var status = 401
        var offline = false
        let f = try Fixture {
            $0.validateKey = { _ in if offline { throw URLError(.notConnectedToInternet) }; return status }
            $0.saveKey = { _, _ in saved += 1; return true }
        }
        defer { f.dispose() }
        f.model.keyDrafts["openai"] = "fixture-secret"
        await f.model.verifyAndStoreKey("openai")
        #expect(f.model.keyMessages["openai"] == "Clé refusée (HTTP 401).")
        status = 500
        await f.model.verifyAndStoreKey("openai")
        #expect(f.model.keyMessages["openai"]?.contains("HTTP 500") == true)
        offline = true
        await f.model.verifyAndStoreKey("openai")
        #expect(f.model.keyMessages["openai"]?.hasPrefix("Réseau indisponible") == true)
        #expect(saved == 0)
        #expect(f.model.keyDrafts["openai"] == "fixture-secret")
    }

    @Test func missingKeyRereadsTheVaultOnceBeforeGivingUp() async throws {
        var refreshes = 0
        var vault: [String: String] = [:]
        let f = try Fixture {
            $0.loadKey = { vault[$0] }
            $0.refreshKeys = { refreshes += 1; vault["xai"] = "fixture-from-vault"; return true }
        }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        #expect(refreshes == 1)
        #expect(f.model.coordinator.isListening)
    }

    @Test func unreachableVaultIsReported() async throws {
        let f = try Fixture {
            $0.keyStore = .vault
            $0.loadKey = { _ in nil }
            $0.refreshKeys = { false }
        }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        #expect(f.audio.starts == 0)
        #expect(f.model.statusBanner?.contains("injoignable") == true)
    }

    @Test func storeFailureKeepsDraftAndReportsFailure() async throws {
        let f = try Fixture {
            $0.validateKey = { _ in 200 }
            $0.saveKey = { _, _ in false }
        }
        defer { f.dispose() }
        f.model.keyDrafts["xai"] = "fixture-secret"
        await f.model.verifyAndStoreKey("xai")
        #expect(f.model.keyDrafts["xai"] == "fixture-secret")
        #expect(f.model.keyMessages["xai"]?.contains("Impossible") == true)
    }

    @Test func vaultKeysCannotBeDeletedFromTheApp() async throws {
        var deletions = 0
        let f = try Fixture {
            $0.keyStore = .vault
            $0.deleteKey = { _ in deletions += 1; return true }
        }
        defer { f.dispose() }
        await f.model.removeKey("xai")
        #expect(deletions == 0)
        #expect(f.model.keyMessages["xai"] == "Impossible de retirer la clé.")
    }

    @Test func customersAreToldToAddTheirKey() async throws {
        let f = try Fixture {
            $0.keyStore = .file
            $0.loadKey = { _ in nil }
        }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        #expect(f.audio.starts == 0)
        #expect(f.model.statusBanner == "Ajoute ta clé xAI dans Fournisseurs.")
    }

    @Test func dictationKeepsOriginalProviderAndKeyThroughFinalization() async throws {
        var requests: [SpeechRequest] = []
        let f = try Fixture {
            $0.transcribe = { _, request in requests.append(request); return "Phrase." }
            $0.clean = { text, _, request, _ in requests.append(request); return CleanupOutcome(text: text) }
        }
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        f.model.selectProvider(.openAI)
        await f.model.coordinator.end()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.provider == .xai && $0.apiKey == "fixture-xai" })
        #expect(f.model.history.first?.provider == "xai")
    }

    @Test func cancellingPendingPermissionNeverStartsCapture() async throws {
        let started = AsyncResult<Void>()
        let permission = AsyncResult<Bool>()
        let f = try Fixture {
            $0.requestMicrophone = { started.resolve(.success(())); return (try? await permission.value()) ?? false }
        }
        defer { f.dispose() }
        let begin = Task { await f.model.coordinator.begin(.toggle) }
        try await started.value()
        f.model.coordinator.cancel()
        permission.resolve(.success(true))
        await begin.value
        #expect(f.audio.starts == 0)
        #expect(f.model.coordinator.phase == .idle)
    }

    @Test func cancellingTranscriptionDoesNotInsertOrResurrectFailure() async throws {
        let started = AsyncResult<Void>()
        let response = AsyncResult<String>()
        let f = try Fixture {
            $0.transcribe = { _, _ in started.resolve(.success(())); return try await response.value() }
        }
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        let path = try #require(f.audio.url?.path)
        let end = Task { await f.model.coordinator.end() }
        try await started.value()
        f.model.coordinator.cancel()
        response.resolve(.success("Phrase tardive."))
        await end.value
        #expect(f.inserted == 0)
        #expect(f.model.history.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(f.model.coordinator.phase == .idle)
    }

    @Test func retryUpdatesHistoryWithoutPastingIntoTheApp() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        let audio = f.directory.appendingPathComponent("retry.wav")
        try Data([0, 0]).write(to: audio)
        let record = DictationRecord(finalText: "", rawText: "", durationSeconds: 1, wordCount: 0, provider: "xai", model: "fixture", insertionStatus: InsertionStatus.transcriptionFailed.rawValue, audioPath: audio.path)
        try f.model.store.insert(record)
        f.model.reload()
        await f.model.coordinator.retranscribe(record)
        #expect(f.model.history.first?.finalText == "Phrase de test.")
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.pending.rawValue)
        #expect(f.inserted == 0)
        #expect(f.model.coordinator.phase == .idle)
    }

    @Test func successfulInsertionStoresTextAndHonorsImmediateAudioDeletion() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.settings.retention = .deleteOnSuccess
        await f.model.coordinator.begin(.pushToTalk)
        let path = try #require(f.audio.url?.path)
        await f.model.coordinator.end()
        #expect(f.inserted == 1)
        #expect(f.model.history.first?.finalText == "Phrase de test.")
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.inserted.rawValue)
        #expect(f.model.history.first?.audioPath == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(f.model.coordinator.phase == .idle)
    }

    @Test func cancellingDuringInsertionKeepsSavedTextAndAudio() async throws {
        let started = AsyncResult<Void>()
        let proceed = AsyncResult<Void>()
        var wrote = false
        let f = try Fixture {
            $0.insert = { _, _, allowed in
                started.resolve(.success(()))
                try? await proceed.value()
                guard allowed() else { return .cancelled }
                wrote = true
                return .inserted
            }
        }
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        let end = Task { await f.model.coordinator.end() }
        try await started.value()
        f.model.coordinator.cancel()
        proceed.resolve(.success(()))
        await end.value
        #expect(!wrote)
        let record = try #require(f.model.history.first)
        #expect(record.finalText == "Phrase de test.")
        #expect(record.insertionStatus == InsertionStatus.cancelled.rawValue)
        #expect(FileManager.default.fileExists(atPath: try #require(record.audioPath)))
        #expect(f.model.coordinator.phase == .idle)
    }

    @Test func retryCancellationKeepsOriginalRecordingAndBlocksOverlappingCapture() async throws {
        let started = AsyncResult<Void>()
        let result = AsyncResult<String>()
        let f = try Fixture {
            $0.transcribe = { _, _ in started.resolve(.success(())); return try await result.value() }
        }
        defer { f.dispose() }
        let audio = f.directory.appendingPathComponent("retry.wav")
        try Data([0, 0]).write(to: audio)
        let record = DictationRecord(finalText: "original", rawText: "original", durationSeconds: 1, wordCount: 1, provider: "xai", model: "fixture", insertionStatus: InsertionStatus.failed.rawValue, audioPath: audio.path)
        try f.model.store.insert(record)
        f.model.reload()
        let retry = Task { await f.model.coordinator.retranscribe(record) }
        try await started.value()
        await f.model.coordinator.begin(.toggle)
        #expect(f.audio.starts == 0)
        f.model.coordinator.cancel()
        result.resolve(.success("late"))
        await retry.value
        #expect(f.model.history.first?.finalText == "original")
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(f.model.coordinator.phase == .idle)
    }

    @Test func deniedMicrophoneReturnsToIdleWithoutRecording() async throws {
        let f = try Fixture { $0.requestMicrophone = { false } }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        #expect(f.audio.starts == 0)
        #expect(f.model.coordinator.phase == .idle)
        #expect(f.model.selectedSection == .settings)
    }

    @Test func newDictationStartsWhileThePreviousOneIsStillFinishing() async throws {
        let gate = AsyncResult<Void>()
        var calls = 0
        let f = try Fixture {
            $0.makeCapture = { FakeAudio() }
            $0.transcribe = { _, _ in
                calls += 1
                if calls == 1 {
                    try? await gate.value()
                    return "Première phrase."
                }
                return "Deuxième phrase."
            }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        let first = try #require(coordinator.endCapture())
        // La première dictée se termine encore : la suivante commence tout de suite.
        await coordinator.begin(.pushToTalk)
        #expect(coordinator.isListening)
        #expect(coordinator.finishingCount == 1)
        let second = try #require(coordinator.endCapture())
        #expect(coordinator.phase == .finishing)
        // La seconde est prête avant la première, mais attend son tour pour être collée.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.insertedTexts.isEmpty)
        gate.resolve(.success(()))
        await first.value
        await second.value
        #expect(f.insertedTexts == ["Première phrase.", "Deuxième phrase."])
        #expect(f.model.history.map(\.finalText) == ["Deuxième phrase.", "Première phrase."])
        #expect(coordinator.phase == .idle)
    }

    @Test func slowAppContextDoesNotDelayTheMicrophone() async throws {
        let field = AsyncResult<Void>()
        var nearby: String?
        let f = try Fixture {
            $0.captureContext = {
                let context = DictationContext()
                context.pid = 4242
                return (context, Task {
                    try? await field.value()
                    var snapshot = FieldSnapshot(element: AXUIElementCreateApplication(getpid()))
                    snapshot.nearbyText = "Texte autour du curseur."
                    return snapshot
                })
            }
            $0.clean = { text, request, _, _ in
                nearby = request.nearbyText
                return CleanupOutcome(text: text)
            }
        }
        defer { f.dispose() }
        let started = Date()
        let opened = OpenedAt()
        f.audio.onStarting = { opened.date = Date() }
        await f.model.coordinator.begin(.pushToTalk)
        // Le champ actif n'est toujours pas lu : le micro est pourtant ouvert et l'écoute a commencé.
        // On date l'ouverture du micro, pas le retour de begin() : il attend encore le champ
        // (150 ms au plus), et ce délai mural, fil principal occupé, dépasse parfois une seconde.
        let micOpened = try #require(opened.date).timeIntervalSince(started)
        #expect(f.audio.starts == 1)
        #expect(f.model.coordinator.isListening)
        #expect(micOpened < 1)
        field.resolve(.success(()))
        await f.model.coordinator.end()
        // Lu après coup, le champ sert quand même à la correction.
        #expect(nearby == "Texte autour du curseur.")
        #expect(f.inserted == 1)
    }

    @Test func escapeWhileListeningLeavesThePreviousDictationFinishing() async throws {
        let gate = AsyncResult<Void>()
        let f = try Fixture {
            $0.makeCapture = { FakeAudio() }
            $0.transcribe = { _, _ in
                try? await gate.value()
                return "Phrase de test."
            }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        let first = try #require(coordinator.endCapture())
        await coordinator.begin(.toggle)
        coordinator.cancel()
        // Seule la dictée qui écoutait est abandonnée.
        #expect(coordinator.phase == .finishing)
        #expect(f.cues == [.start, .stop, .start, .cancel])
        gate.resolve(.success(()))
        await first.value
        #expect(f.insertedTexts == ["Phrase de test."])
        #expect(coordinator.phase == .idle)
    }

    @Test func failureDuringTheNextDictationWaitsForTheMicrophoneToBeFree() async throws {
        let gate = AsyncResult<Void>()
        let f = try Fixture {
            $0.makeCapture = { FakeAudio() }
            $0.transcribe = { _, _ in
                try? await gate.value()
                return "Phrase de test."
            }
            $0.insert = { _, _, _ in .noTarget }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        let first = try #require(coordinator.endCapture())
        await coordinator.begin(.toggle)
        gate.resolve(.success(()))
        await first.value
        // La bulle reste à l'écoute ; le message attend la fin de cette dictée.
        #expect(coordinator.phase == .listening(.toggle))
        #expect(coordinator.failureText == nil)
        coordinator.cancel()
        #expect(coordinator.phase == .failure("Pas de champ où écrire : le texte est prêt"))
        #expect(coordinator.failureText == "Phrase de test.")
    }

    @Test func cancellingEverythingStopsAllFinishingDictations() async throws {
        let gate = AsyncResult<Void>()
        let f = try Fixture {
            $0.makeCapture = { FakeAudio() }
            $0.transcribe = { _, _ in
                try? await gate.value()
                return "Phrase de test."
            }
        }
        defer { f.dispose() }
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        let first = try #require(coordinator.endCapture())
        await coordinator.begin(.pushToTalk)
        let second = try #require(coordinator.endCapture())
        coordinator.cancel()
        gate.resolve(.success(()))
        await first.value
        await second.value
        #expect(f.inserted == 0)
        #expect(f.model.history.isEmpty)
        #expect(coordinator.phase == .idle)
    }

    @Test func statusMenuShowsStateThenTheUsefulActionThenScreens() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        func titles() -> [String] { StatusMenu.items(model: f.model, target: nil).map(\.title) }
        // Chaque entrée active appelle une méthode qui existe vraiment dans le délégué de l'app.
        let delegate = AppDelegate()
        for item in StatusMenu.items(model: f.model, target: delegate) {
            guard let action = item.action else { continue }
            #expect(delegate.responds(to: action), "\(item.title) : \(action)")
        }
        #expect(titles().first?.hasPrefix("● Prêt · double appui sur fn : mains libres") == true)
        #expect(titles().contains("Dicter (mains libres)"))
        #expect(titles().contains("Réglages…"))
        #expect(!titles().contains { $0.hasPrefix("⇄") })
        // Pendant l'écoute : terminer ou annuler.
        await f.model.coordinator.begin(.toggle)
        #expect(titles().contains("Terminer la dictée"))
        #expect(titles().contains("Annuler la dictée (Échap)"))
        f.model.coordinator.cancel()
        // Service en pause : le relais est dit, et on peut réessayer tout de suite.
        f.model.health.record(ServiceHealth.deepSeek, succeeded: false)
        f.model.health.record(ServiceHealth.deepSeek, succeeded: false)
        #expect(titles().contains("⇄ DeepSeek en pause : correction via OpenAI \(CleanupModel.openAIFallback)"))
        #expect(titles().contains("Réessayer les services maintenant"))
        // Mot appris à tort : retiré d'un clic depuis le menu.
        f.model.learn(["Seedance"])
        let remove = try #require(StatusMenu.items(model: f.model, target: nil).first { $0.title == "Retirer « Seedance » du dictionnaire" })
        #expect(remove.representedObject as? String == "Seedance")
        f.model.removeTerm(named: "Seedance")
        #expect(f.model.dictionary.isEmpty)
        #expect(!titles().contains { $0.hasPrefix("Retirer") })
    }

    @Test func macSoundComesBackBeforeTheEndOrCancelCue() async throws {
        var order: [String] = []
        let f = try Fixture {
            $0.muteOutput = { _, _ in order.append("mute") }
            $0.restoreOutput = { order.append("restore") }
            $0.playCue = { order.append("\($0)") }
        }
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        try await Task.sleep(nanoseconds: 400_000_000)
        await f.model.coordinator.end()
        #expect(order == ["start", "mute", "restore", "stop"])
        order.removeAll()
        await f.model.coordinator.begin(.toggle)
        try await Task.sleep(nanoseconds: 400_000_000)
        f.model.coordinator.cancel()
        #expect(order == ["start", "mute", "restore", "cancel"])
    }

    @Test func relayAnnouncementBelongsToTheDictationThatUsedTheRelay() async throws {
        let failed = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0, succeeded: false)
        let relayed = UsageEvent(api: .openAICleanup, model: CleanupModel.openAIFallback, costUSD: 0.0003)
        let fine = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.00005)
        var relayNext = true
        var pasteNext: InsertionStatus = .noTarget
        let f = try Fixture {
            $0.clean = { text, _, _, _ in
                defer { relayNext = false }
                return relayNext
                    ? CleanupOutcome(text: text, usage: relayed, failedUsages: [failed], fallback: "OpenAI")
                    : CleanupOutcome(text: text, usage: fine)
            }
            $0.insert = { _, _, _ in pasteNext }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        // Dictée relayée mais pas collée : rien n'est annoncé…
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        coordinator.dismissFailure()
        #expect(coordinator.notice == nil)
        // … et la dictée suivante, corrigée normalement par DeepSeek, n'hérite pas du message.
        pasteNext = .inserted
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        #expect(coordinator.notice == nil)
        // La prochaine bascule, elle, est bien annoncée.
        relayNext = true
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        #expect(coordinator.notice == "DeepSeek ne répond pas : correction via OpenAI.")
    }

    @Test func retryWaitsForTheDictationThatIsFinishing() async throws {
        let gate = AsyncResult<Void>()
        var calls = 0
        let f = try Fixture {
            $0.transcribe = { _, _ in
                calls += 1
                if calls == 1 { try? await gate.value() }
                return "Phrase de test."
            }
        }
        defer { f.dispose() }
        let audio = f.directory.appendingPathComponent("retry.wav")
        try Data([0, 0]).write(to: audio)
        let record = DictationRecord(finalText: "", rawText: "", durationSeconds: 1, wordCount: 0, provider: "xai", model: "fixture", insertionStatus: InsertionStatus.transcriptionFailed.rawValue, audioPath: audio.path)
        try f.model.store.insert(record)
        f.model.reloadHistory()
        await f.model.coordinator.begin(.pushToTalk)
        let finishing = try #require(f.model.coordinator.endCapture())
        let retry = Task { await f.model.coordinator.retranscribe(record) }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.resolve(.success(()))
        await finishing.value
        await retry.value
        #expect(f.model.history.first { $0.id == record.id }?.finalText == "Phrase de test.")
        #expect(f.model.coordinator.phase == .idle)
    }

    @Test func latencyLineHoldsTimingsButNoText() {
        let marks = LatencyMarks(pressed: 1_000)
        marks.bubble = 1_182
        marks.microphone = 1_240
        marks.stream = 1_512
        marks.released = 3_000
        marks.pasted = 4_430
        let line = LatencyLog.line(marks, mode: .pushToTalk, status: "inserted", date: Date(timeIntervalSince1970: 0))
        #expect(line.contains("appui→bulle 182 ms"))
        #expect(line.contains("appui→micro 240 ms"))
        #expect(line.contains("appui→flux 512 ms"))
        #expect(line.contains("fin→collé 1430 ms"))
        #expect(line.hasSuffix("inserted"))
        // Depuis le menu : pas d'appui, le reste compte depuis la bulle.
        let menu = LatencyMarks(pressed: nil)
        menu.bubble = 10
        menu.microphone = 60
        #expect(LatencyLog.line(menu, mode: .toggle, status: "inserted").contains("appui→bulle —"))
        #expect(LatencyLog.line(menu, mode: .toggle, status: "inserted").contains("appui→micro 50 ms"))
    }

    @Test func pasteboardRestoresLargePayloadAndDoesNotOverwriteNewCopy() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("wispad-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let payload = Data(repeating: 42, count: 2_100_000)
        board.setData(payload, forType: .png)
        let first = try #require(PasteboardTransaction(text: "dictation", pasteboard: board))
        first.restoreIfUnchanged()
        #expect(board.data(forType: .png) == payload)
        let second = try #require(PasteboardTransaction(text: "dictation", pasteboard: board))
        board.clearContents()
        board.setString("new user copy", forType: .string)
        second.restoreIfUnchanged()
        #expect(board.string(forType: .string) == "new user copy")
    }

    @Test func menuBarIconIsASharpTemplateInBothStates() throws {
        for listening in [false, true] {
            let image = BrandIcon.menuBarImage(listening: listening)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
        }
        // Bord gauche net : colonne pleine contre colonne vide, en Retina comme en @1x.
        let retina = try menuBarAlpha(listening: false, scale: 2)
        #expect(retina(2, 21) > 250 && retina(1, 21) < 5)
        let standard = try menuBarAlpha(listening: false, scale: 1)
        #expect(standard(1, 11) > 250 && standard(0, 11) < 5)
        // En écoute, la tête devient pleine et le W y est découpé.
        let listening = try menuBarAlpha(listening: true, scale: 2)
        #expect(retina(18, 14) < 5 && listening(18, 14) > 250)
        #expect(retina(18, 20) > 250 && listening(18, 20) < 5)
    }
}

/// Copies automatiques relevées par un test.
private final class CopyBox: @unchecked Sendable {
    var texts: [String] = []
}

/// Format promis par une app qui ne le fournit pas : `data(forType:)` rend nil.
private final class SilentProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

@MainActor
struct InsertionFailureTests {
    @Test func copyButtonKeepsItsActionWithATrailingClosure() {
        // Le 5 octobre, la fermeture finale se rattachait au bouton secondaire : « Copier » disparaissait.
        let line = MessageLine(symbol: "exclamationmark.circle.fill", tint: .red, message: "Échec.", duration: 10, actionTitle: "Copier") {}
        #expect(line.action != nil)
        #expect(line.secondaryAction == nil)
        let labeled = MessageLine(symbol: "checkmark.circle.fill", tint: .green, message: "Garder ?", duration: 8,
                                  actionTitle: "Oui", action: {}, secondaryTitle: "Non", secondaryAction: {})
        #expect(labeled.action != nil && labeled.secondaryAction != nil)
    }

    @Test func anUnreadableClipboardFormatDoesNotBlockThePaste() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wispad-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let provider = SilentProvider()
        let item = NSPasteboardItem()
        item.setString("copie de l'utilisateur", forType: .string)
        item.setDataProvider(provider, forTypes: [NSPasteboard.PasteboardType("com.example.fictif.promesse")])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let transaction = try #require(PasteboardTransaction(text: "Texte dicté.", pasteboard: pasteboard))
        #expect(transaction.skippedTypes == 1)
        #expect(pasteboard.string(forType: .string) == "Texte dicté.")
        // Ce qui était lisible revient après le collage.
        transaction.restoreIfUnchanged()
        #expect(pasteboard.string(forType: .string) == "copie de l'utilisateur")
    }

    @Test func aFailedPasteCopiesTheTextAndStillOffersTheButton() async throws {
        let box = CopyBox()
        let f = try Fixture {
            $0.insert = { _, _, _ in .failed }
            $0.copyText = { box.texts.append($0) }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(box.texts == ["Phrase de test."])
        #expect(f.model.coordinator.phase == .failure("Collage impossible : le texte est prêt"))
        #expect(f.model.coordinator.failureText == "Phrase de test.")
    }

    @Test func aSecureFieldIsNotCopied() async throws {
        let box = CopyBox()
        let f = try Fixture {
            $0.insert = { _, _, _ in .refusedSecure }
            $0.copyText = { box.texts.append($0) }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(box.texts.isEmpty)
        // Rien n'est copié d'office, mais la bulle propose toujours Copier.
        #expect(f.model.coordinator.phase == .failure("Champ sécurisé : le texte est prêt"))
        #expect(f.model.coordinator.failureText == "Phrase de test.")
    }

    @Test func copyConfirmsCopiedThenTheBubbleLeaves() async throws {
        let box = CopyBox()
        let f = try Fixture {
            $0.insert = { _, _, _ in .noTarget }
            $0.copyText = { box.texts.append($0) }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        coordinator.copyReadyText()
        #expect(box.texts == ["Phrase de test.", "Phrase de test."])
        #expect(coordinator.phase == .failure("Copié"))
        #expect(coordinator.failureCopied)
        #expect(coordinator.failureText == nil)
        #expect(DictationCoordinator.copiedSeconds < DictationCoordinator.failureSeconds)
        let deadline = Date().addingTimeInterval(DictationCoordinator.copiedSeconds + 1.5)
        while coordinator.phase != .idle, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(coordinator.phase == .idle)
        #expect(!coordinator.failureCopied)
    }

    @Test func escapeOrTheCrossClosesTheReadyText() async throws {
        let f = try Fixture { $0.insert = { _, _, _ in .noTarget } }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        #expect(coordinator.failureText != nil)
        // Échap (ou ✕) : la bulle part, le texte reste dans l'historique.
        coordinator.cancel()
        #expect(coordinator.phase == .idle)
        #expect(coordinator.failureText == nil)
        #expect(f.model.history.first?.finalText == "Phrase de test.")
    }

    @Test func readyTextWithItsButtonsFitsOnOneLine() async throws {
        let f = try Fixture { $0.insert = { _, _, _ in .noTarget } }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        let renderer = ImageRenderer(content: OverlayCluster(mode: .failure(DictationCoordinator.readyMessage(for: .noTarget)))
            .environment(f.model)
            .environment(\.colorScheme, .dark)
            .environment(\.overlayGlass, false))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.height <= OverlayLayout.pillHeight + 1)
        #expect(image.size.width <= OverlayLayout.panelSize.width - 40)
    }
}

/// « Coller la dernière dictée » : même collage qu'une dictée, même message sans champ.
@MainActor
struct PasteLastDictationTests {
    @Test func theShortcutPastesTheUndeliveredDictationAndUpdatesItsStatus() async throws {
        let box = CopyBox()
        var next: InsertionStatus = .noTarget
        var pasted: [String] = []
        var targets: [pid_t?] = []
        let f = try Fixture {
            $0.copyText = { box.texts.append($0) }
            $0.insert = { text, context, _ in
                pasted.append(text)
                targets.append(context.pid)
                return next
            }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.noTarget.rawValue)
        // Un champ est maintenant actif : le raccourci colle le texte au curseur de l'app au premier plan.
        next = .inserted
        await coordinator.pasteLastDictation()
        #expect(pasted == ["Phrase de test.", "Phrase de test."])
        #expect(targets == [4242, 5151])
        #expect(coordinator.phase == .idle)
        #expect(coordinator.failureText == nil)
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.inserted.rawValue)
        #expect(f.model.history.first?.targetApp == "Éditeur de test")
        #expect(f.model.history.first?.targetBundle == "test.editeur")
        #expect(box.texts == ["Phrase de test."])
    }

    @Test func aSuccessfulPasteEndsLikeADictation() async throws {
        var next: InsertionStatus = .noTarget
        let f = try Fixture {
            $0.insert = { _, _, _ in next }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        #expect(f.watches.isEmpty)
        next = .inserted
        await coordinator.pasteLastDictation()
        // Même fin qu'une dictée insérée : bref « Collé » qui part seul, champ surveillé pour l'apprentissage.
        #expect(coordinator.notice == "Collé")
        #expect(!coordinator.noticeIsInfo && !coordinator.noticeIsRelay)
        #expect(coordinator.phase == .idle)
        let watch = try #require(f.watches.first)
        #expect(f.watches.count == 1)
        #expect(watch.0 == "Phrase de test.")
        #expect(watch.1 == 5151)
    }

    @Test func aPasteLearnsNothingWhenLearningIsOff() async throws {
        var next: InsertionStatus = .noTarget
        let f = try Fixture {
            $0.insert = { _, _, _ in next }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        f.model.settings.learnCorrections = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        next = .pasteSent
        await coordinator.pasteLastDictation()
        #expect(coordinator.notice == "Collé")
        #expect(f.watches.isEmpty)
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.pasteSent.rawValue)
    }

    @Test func withoutAFieldTheShortcutCopiesAndShowsTheSameMessage() async throws {
        let box = CopyBox()
        let f = try Fixture {
            $0.insert = { _, _, _ in .noTarget }
            $0.copyText = { box.texts.append($0) }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        coordinator.dismissFailure()
        await coordinator.pasteLastDictation()
        #expect(coordinator.phase == .failure("Pas de champ où écrire : le texte est prêt"))
        #expect(coordinator.failureText == "Phrase de test.")
        #expect(coordinator.notice == nil)
        #expect(f.watches.isEmpty)
        #expect(box.texts == ["Phrase de test.", "Phrase de test."])
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.noTarget.rawValue)
        #expect(f.model.history.first?.targetApp == nil)
    }

    @Test func aDeliveredDictationIsPastedAgainWithoutLosingItsStatus() async throws {
        var results: [InsertionStatus] = [.inserted, .noTarget]
        let f = try Fixture {
            $0.insert = { _, _, _ in results.isEmpty ? .inserted : results.removeFirst() }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        await coordinator.pasteLastDictation()
        // Le nouveau collage a échoué, mais la dictée avait bien été écrite la première fois.
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.inserted.rawValue)
        #expect(coordinator.phase == .failure("Pas de champ où écrire : le texte est prêt"))
    }

    @Test func nothingToPasteSaysSoWithoutPasting() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        await f.model.coordinator.pasteLastDictation()
        #expect(f.inserted == 0)
        #expect(f.model.coordinator.notice == "Aucune dictée à coller")
        #expect(f.model.coordinator.noticeIsInfo)
    }

    @Test func theShortcutIsIgnoredWhileListening() async throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        await coordinator.begin(.toggle)
        await coordinator.pasteLastDictation()
        #expect(f.inserted == 1)
        #expect(coordinator.phase == .listening(.toggle))
        coordinator.cancel()
    }

    @Test func thePasteButtonOfTheBubblePastesTheReadyText() async throws {
        var next: InsertionStatus = .noTarget
        let f = try Fixture {
            $0.insert = { _, _, _ in next }
        }
        defer { f.dispose() }
        f.model.overlay.displaysPanel = false
        let coordinator = f.model.coordinator
        await coordinator.begin(.pushToTalk)
        await coordinator.end()
        next = .pasteSent
        coordinator.pasteReadyText()
        let deadline = Date().addingTimeInterval(2)
        while f.model.history.first?.insertionStatus != InsertionStatus.pasteSent.rawValue, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(f.model.history.first?.insertionStatus == InsertionStatus.pasteSent.rawValue)
        #expect(coordinator.phase == .idle)
    }
}

/// Enregistreur du raccourci dans Réglages, sans vrai clavier : les combinaisons arrivent comme du moniteur.
@MainActor
struct PasteShortcutRecorderTests {
    private let ctrlOpt = ModifierMask.control | ModifierMask.option

    @Test func aFreeCombinationIsSavedAndEndsTheRecording() throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.isRecordingPasteShortcut = true
        #expect(f.model.recordPasteShortcut(keyCode: 11, flags: ctrlOpt))
        #expect(f.model.settings.pasteLastShortcut == PasteShortcut(keyCode: 11, modifiers: ctrlOpt))
        #expect(!f.model.isRecordingPasteShortcut)
        #expect(f.model.pasteShortcutProblem == nil)
    }

    @Test func aTakenCombinationIsRefusedWithAClearMessage() throws {
        let f = try Fixture { $0.systemShortcuts = { [PasteShortcut(keyCode: 11, modifiers: ModifierMask.control | ModifierMask.option)] } }
        defer { f.dispose() }
        f.model.isRecordingPasteShortcut = true
        #expect(!f.model.recordPasteShortcut(keyCode: 9, flags: ModifierMask.command | ModifierMask.shift))
        #expect(f.model.pasteShortcutProblem == "⇧ ⌘ V est déjà pris : coller sans mise en forme.")
        #expect(!f.model.recordPasteShortcut(keyCode: 11, flags: ctrlOpt))
        #expect(f.model.pasteShortcutProblem == "⌃ ⌥ B est déjà pris par macOS (Réglages Système › Clavier › Raccourcis).")
        #expect(!f.model.recordPasteShortcut(keyCode: 9, flags: ctrlOpt | ModifierMask.function))
        #expect(f.model.pasteShortcutProblem == "fn est réservée à la dictée : choisis une combinaison sans fn.")
        // Toujours en enregistrement, avec le raccourci d'avant.
        #expect(f.model.isRecordingPasteShortcut)
        #expect(f.model.settings.pasteLastShortcut == .standard)
    }

    @Test func escapeCancelsAndResetOrDisableKeepTheChoice() throws {
        let f = try Fixture()
        defer { f.dispose() }
        f.model.isRecordingPasteShortcut = true
        #expect(!f.model.recordPasteShortcut(keyCode: HotkeyLogic.escapeKeyCode, flags: 0))
        #expect(!f.model.isRecordingPasteShortcut)
        #expect(f.model.settings.pasteLastShortcut == .standard)
        f.model.settings.pasteLastShortcut = PasteShortcut(keyCode: 11, modifiers: ctrlOpt)
        f.model.setPasteShortcutEnabled(false)
        #expect(f.model.settings.pasteLastShortcut == PasteShortcut(keyCode: 11, modifiers: ctrlOpt, enabled: false))
        f.model.resetPasteShortcut()
        #expect(f.model.settings.pasteLastShortcut == .standard)
    }
}
