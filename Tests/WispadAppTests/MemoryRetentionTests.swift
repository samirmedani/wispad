import AppKit
import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Référence faible vers un objet suivi par le test : nil dès qu'il est libéré.
@MainActor
private final class Tracked<Object: AnyObject> {
    weak var object: Object?
    init(_ object: Object?) { self.object = object }
}

private final class RetentionAudio: AudioRecording, @unchecked Sendable {
    @Guarded var onPCM: (@Sendable (Data) -> Void)?
    let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    @Guarded var duration = 2.0
    @Guarded private var url: URL?

    func start(directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 128).write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) { (url, duration) }
}

private final class RetentionStream: SpeechStreaming, @unchecked Sendable {
    static let text = "Texte du flux, déjà affiché pendant l'écoute."
    @Guarded var onPartial: (@Sendable (String) -> Void)?
    @Guarded var onSettled: (@Sendable (String) -> Void)?
    @Guarded var started = false

    func start() async throws {
        // Texte déjà affiché : une correction part dès l'arrêt et tient la dictée jusqu'à sa fin.
        onPartial?(Self.text)
        started = true
    }

    func send(_ data: Data) {}

    func finish() async throws -> StreamFinish {
        StreamFinish(text: Self.text, endingFinalized: true)
    }

    func cancel() {}
}

/// Fausses frontières : aucun micro, réseau, clé ni collage réels. Chaque flux et chaque contexte de dictée créés
/// sont suivis par une référence faible.
@MainActor
private final class RetentionFixture {
    let directory: URL
    let audio = RetentionAudio()
    var streams: [Tracked<RetentionStream>] = []
    var contexts: [Tracked<DictationContext>] = []
    var inserted: [String] = []
    var model: AppModel!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var deps = AppDependencies()
        deps.copyText = { _ in }
        deps.loadKey = { "fixture-" + $0 }
        deps.saveKey = { _, _ in true }
        deps.refreshKeys = { true }
        deps.requestMicrophone = { true }
        deps.captureContext = { [weak self] in
            let context = DictationContext()
            context.pid = 4242
            self?.contexts.append(Tracked(context))
            return (context, Task { nil })
        }
        deps.readWindow = { _ in nil }
        deps.makeCapture = { [audio] in audio }
        deps.makeSession = { [weak self] _ in
            let stream = RetentionStream()
            self?.streams.append(Tracked(stream))
            return stream
        }
        deps.transcribe = { _, _ in RetentionStream.text }
        deps.isOnline = { true }
        deps.clean = { text, _, _, _ in CleanupOutcome(text: text) }
        deps.playCue = { _ in }
        deps.muteOutput = { _, _ in }
        deps.restoreOutput = {}
        deps.watchCorrections = { _, _, _, _ in }
        deps.insert = { [weak self] text, _, _, _ in
            self?.inserted.append(text)
            return .inserted
        }
        deps.systemShortcuts = { [] }
        model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: deps)
        model.overlay.displaysPanel = false
    }

    /// Plus rien ne retient les flux ni les contextes des dictées passées.
    var dictationsReleased: Bool {
        streams.allSatisfy { $0.object == nil } && contexts.allSatisfy { $0.object == nil }
    }

    func dispose() {
        model.coordinator.cancel()
        model.overlay.panel?.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Attend qu'une condition devienne vraie, sans bloquer le fil principal. Rend la main dès qu'elle l'est : les 15 s
/// ne servent qu'aux machines de CI chargées.
@MainActor
private func eventually(_ condition: () -> Bool, seconds: Double = 15) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

/// Wispad reste ouvert des jours : une dictée finie, annulée ou trop courte ne laisse rien derrière elle (flux en
/// direct, contexte de l'app, et tout ce que la dictée retenait), et un panneau de bulle remplacé est libéré.
@MainActor
@Suite(.serialized)
struct MemoryRetentionTests {
    @Test func finishedDictationReleasesWhatItHeld() async throws {
        let f = try RetentionFixture()
        defer { f.dispose() }
        for _ in 0..<3 {
            await f.model.coordinator.begin(.toggle)
            let streaming = await eventually { f.streams.last?.object?.started == true }
            #expect(streaming)
            await f.model.coordinator.end()
        }
        #expect(f.inserted.count == 3)
        #expect(f.model.coordinator.phase == .idle)
        #expect(f.streams.count == 3)
        let released = await eventually { f.dictationsReleased }
        #expect(released)
    }

    @Test func cancelledDictationReleasesWhatItHeld() async throws {
        let f = try RetentionFixture()
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        let streaming = await eventually { f.streams.last?.object?.started == true }
        #expect(streaming)
        f.model.coordinator.cancel()
        #expect(f.model.coordinator.phase == .idle)
        #expect(f.inserted.isEmpty)
        let released = await eventually { f.dictationsReleased }
        #expect(released)
    }

    @Test func tooShortDictationReleasesWhatItHeld() async throws {
        let f = try RetentionFixture()
        defer { f.dispose() }
        f.audio.duration = 0.1
        await f.model.coordinator.begin(.toggle)
        await f.model.coordinator.end()
        #expect(f.model.coordinator.phase == .idle)
        #expect(f.inserted.isEmpty)
        #expect(!f.contexts.isEmpty)
        let released = await eventually { f.dictationsReleased }
        #expect(released)
    }

    /// Chaque app passée en plein écran reçoit une bulle neuve : l'ancien panneau ne doit pas rester en mémoire.
    @Test func replacedBubblePanelIsReleased() async throws {
        _ = NSApplication.shared
        let f = try RetentionFixture()
        defer { f.dispose() }
        let overlay = f.model.overlay
        let stale = Tracked<NSPanel>(nil)
        autoreleasepool {
            overlay.install(model: f.model)
            stale.object = overlay.panel
        }
        let installed = stale.object != nil
        #expect(installed)
        overlay.isOnActiveSpace = { _ in false }
        let replaced = autoreleasepool { overlay.replacePanelIfOffActiveSpace() }
        #expect(replaced)
        let current = overlay.panel != nil
        #expect(current)
        let released = await eventually { stale.object == nil }
        #expect(released)
    }
}
