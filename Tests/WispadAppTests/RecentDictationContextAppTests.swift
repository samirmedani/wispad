import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

private final class RecentContextAudio: AudioRecording, @unchecked Sendable {
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

    func stop() -> (url: URL?, duration: Double) { (url, 1) }
}

private final class RecentContextStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    func start() async throws {}
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish { StreamFinish(text: "Phrase de test.", endingFinalized: true) }
    func cancel() {}
}

/// Micro, coffre et fenêtre simulés : le panneau n'est jamais affiché.
@MainActor
private final class RecentContextFixture {
    let directory: URL
    var requests: [CorrectionRequest] = []
    var liveTerms: [String] = []
    var fileTerms: [[String]] = []
    var model: AppModel!

    init(bundle: String, window: ((pid_t) async -> String?)? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-recent-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in "fixture-key" }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        dependencies.captureContext = {
            let context = DictationContext()
            context.pid = 4_242
            context.bundleID = bundle
            context.appName = "Éditeur fictif"
            return (context, Task { nil })
        }
        dependencies.readWindow = window ?? { _ in nil }
        dependencies.makeCapture = { RecentContextAudio() }
        dependencies.makeSession = { [weak self] request in
            self?.liveTerms = request.keyterms
            return RecentContextStream()
        }
        dependencies.transcribe = { [weak self] _, speech in
            self?.fileTerms.append(speech.keyterms)
            return "Phrase de test."
        }
        dependencies.clean = { [weak self] text, request, _, _ in
            self?.requests.append(request)
            return CleanupOutcome(text: text)
        }
        dependencies.playCue = { _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        dependencies.insert = { text, _, allowed, _ in
            guard allowed() else { return .cancelled }
            return .inserted
        }
        var settings = AppSettings()
        // Contexte accepté au premier lancement (désactivé par défaut pour une nouvelle installation).
        settings.useWindowContext = true
        settings.cleanupEnabled = true
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct RecentDictationContextAppTests {
    @Test func liveDictationReceivesSameAppContextAndRetryDoesNot() async throws {
        let bundle = "com.example.fictif.editeur"
        let f = try RecentContextFixture(bundle: bundle)
        defer { f.dispose() }
        let kept = "Le bac nord contient douze modules Nordmod12."
        try f.model.store.insert(DictationRecord(
            createdAt: Date().addingTimeInterval(-120),
            finalText: kept,
            rawText: kept,
            durationSeconds: 2,
            wordCount: 6,
            provider: "fixture",
            model: "fixture",
            targetApp: "Éditeur fictif",
            targetBundle: bundle,
            insertionStatus: InsertionStatus.inserted.rawValue
        ))
        try f.model.store.insert(DictationRecord(
            createdAt: Date().addingTimeInterval(-30),
            finalText: "Annulée, à ignorer.",
            rawText: "Annulée, à ignorer.",
            durationSeconds: 1,
            wordCount: 3,
            provider: "fixture",
            model: "fixture",
            targetBundle: bundle,
            insertionStatus: InsertionStatus.cancelled.rawValue
        ))
        try f.model.store.insert(DictationRecord(
            createdAt: Date().addingTimeInterval(-20),
            finalText: "Autre application.",
            rawText: "Autre application.",
            durationSeconds: 1,
            wordCount: 2,
            provider: "fixture",
            model: "fixture",
            targetBundle: "com.example.fictif.navigateur",
            insertionStatus: InsertionStatus.inserted.rawValue
        ))
        f.model.reload()
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(f.liveTerms.contains("Nordmod12"))
        #expect(f.requests.first?.previousDictations == [kept])

        let record = try #require(f.model.history.first { $0.finalText == "Phrase de test." })
        f.requests.removeAll()
        await f.model.coordinator.retranscribe(record)
        #expect(f.requests.first?.previousDictations.isEmpty == true)
        let retryTerms = try #require(f.fileTerms.last)
        #expect(!retryTerms.contains("Nordmod12"))
    }

    @Test func visibleConversationReachesTheCorrectionOnlyWhenEnabled() async throws {
        final class Calls { var pids: [pid_t] = [] }
        let calls = Calls()
        let f = try RecentContextFixture(bundle: "com.example.fictif.discussion") { pid in
            calls.pids.append(pid)
            return "On trie les barrettes DDR3 de 16 Go."
        }
        defer { f.dispose() }
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(calls.pids == [4_242])
        #expect(f.requests.last?.windowText == "On trie les barrettes DDR3 de 16 Go.")

        // Réglage coupé : la fenêtre n'est même pas lue.
        f.model.settings.useWindowContext = false
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(calls.pids == [4_242])
        #expect(f.requests.last?.windowText == nil)

        // Sans correction, rien ne part : pas de lecture non plus.
        f.model.settings.useWindowContext = true
        f.model.settings.cleanupEnabled = false
        await f.model.coordinator.begin(.pushToTalk)
        await f.model.coordinator.end()
        #expect(calls.pids == [4_242])
    }

    @Test func oldSettingsWithoutTheKeyKeepWindowContextOn() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"structureDictation": false}"#.utf8))
        #expect(decoded.useWindowContext)
        #expect(!decoded.structureDictation)
    }
}
