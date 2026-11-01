import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

private final class StyleAudio: AudioRecording, @unchecked Sendable {
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

    func stop() -> (url: URL?, duration: Double) { (url, 2) }
}

private final class StyleStream: SpeechStreaming, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    var text = ""
    func start() async throws {}
    func send(_ data: Data) {}
    func finish() async throws -> StreamFinish { StreamFinish(text: text, endingFinalized: true) }
    func cancel() {}
}

/// Sélection, app, flux, correction et collage simulés.
@MainActor
private final class StyleFixture {
    let directory: URL
    let audio = StyleAudio()
    let stream = StyleStream()
    var selection: String?
    var bundle = "com.example.fictif.editeur"
    var transformed = "Hello everyone."
    var requests: [CorrectionRequest] = []
    var inserted: [String] = []
    var model: AppModel!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-style-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var deps = AppDependencies()
        deps.copyText = { _ in }
        deps.loadKey = { "fixture-" + $0 }
        deps.saveKey = { _, _ in true }
        deps.refreshKeys = { true }
        deps.requestMicrophone = { true }
        deps.isOnline = { true }
        deps.captureContext = { [weak self] in
            let context = DictationContext()
            context.pid = 4_242
            context.bundleID = self?.bundle
            context.appName = "App fictive"
            context.selectedText = self?.selection
            return (context, Task { nil })
        }
        deps.readWindow = { _ in nil }
        deps.makeCapture = { [audio] in audio }
        deps.makeSession = { [stream] _ in stream }
        deps.transcribe = { [weak self] _, _ in self?.stream.text ?? "" }
        deps.clean = { [weak self] text, request, _, _ in
            self?.requests.append(request)
            let usage = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.00001)
            if request.commandSelection != nil { return CleanupOutcome(text: self?.transformed ?? "", usage: usage) }
            return CleanupOutcome(text: text, usage: usage)
        }
        deps.playCue = { _, _ in }
        deps.muteOutput = { _, _ in }
        deps.restoreOutput = {}
        deps.watchCorrections = { _, _, _, _ in }
        deps.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        deps.insert = { [weak self] text, _, allowed, _ in
            guard allowed() else { return .cancelled }
            self?.inserted.append(text)
            return .inserted
        }
        var settings = AppSettings()
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.structureDictation = false
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: deps)
        model.overlay.displaysPanel = false
    }

    func dictate(_ text: String) async {
        stream.text = text
        await model.coordinator.begin(.toggle)
        await model.coordinator.end()
    }

    func trace() throws -> DictationTrace {
        try #require(try model.store.recentTraces(limit: 1).first)
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite(.serialized)
struct DictationStyleAppTests {
    @Test func aCommandRewritesTheSelection() async throws {
        let f = try StyleFixture()
        defer { f.dispose() }
        f.selection = "Bonjour à tous."
        await f.dictate("Traduis en anglais.")

        #expect(f.requests.count == 1)
        #expect(f.requests.first?.commandSelection == "Bonjour à tous.")
        #expect(f.inserted == ["Hello everyone."])
        let record = try #require(f.model.history.first)
        #expect(record.rawText == "Traduis en anglais.")
        #expect(record.finalText == "Hello everyone.")
        #expect(try f.trace().selectionCommand == true)
    }

    @Test func aCommandWithoutAnswerPastesNothing() async throws {
        let f = try StyleFixture()
        defer { f.dispose() }
        f.selection = "Bonjour à tous."
        f.transformed = ""
        await f.dictate("Reformule plus poliment.")

        #expect(f.inserted.isEmpty)
        #expect(f.model.history.isEmpty)
        #expect(try f.trace().outcome == .commandFailed)
        #expect(f.model.statusBanner == "Consigne non appliquée : la sélection est inchangée.")
    }

    @Test func plainDictationOverASelectionStaysADictation() async throws {
        let f = try StyleFixture()
        defer { f.dispose() }
        f.selection = "Bonjour à tous."
        await f.dictate("Rendez-vous demain à 15 h.")
        #expect(f.requests.allSatisfy { $0.commandSelection == nil })
        #expect(f.inserted == ["Rendez-vous demain à 15 h."])
    }

    @Test func commandsCanBeTurnedOff() async throws {
        let f = try StyleFixture()
        defer { f.dispose() }
        f.model.settings.selectionCommands = false
        f.selection = "Bonjour à tous."
        await f.dictate("Traduis en anglais.")
        #expect(f.requests.allSatisfy { $0.commandSelection == nil })
        #expect(f.inserted == ["Traduis en anglais."])
    }

    @Test func everyCorrectionCarriesTheDateFormat() async throws {
        let f = try StyleFixture()
        defer { f.dispose() }
        let format = DictationDateFormat(order: .iso, clock: .twelveHour)
        f.model.settings.dateFormat = format
        await f.dictate("Rendez-vous le 3 novembre à 14 h.")
        #expect(!f.requests.isEmpty)
        #expect(f.requests.allSatisfy { $0.dateFormat == format })
    }

    @Test func theToneFollowsTheAppCategory() async throws {
        let f = try StyleFixture()
        defer { f.dispose() }
        f.model.settings.tones[UsageKind.email.rawValue] = .polished
        f.bundle = "com.apple.mail"
        await f.dictate("T'as vu le devis ?")
        #expect(f.requests.allSatisfy { $0.tone == .polished })
        f.bundle = "com.tdesktop.Telegram"
        f.requests = []
        await f.dictate("T'as vu le devis ?")
        // Messagerie sans choix de l'utilisateur : ton détendu ; un choix explicite l'emporte.
        #expect(f.requests.allSatisfy { $0.tone == .casual })
        f.model.settings.tones[UsageKind.messaging.rawValue] = .natural
        f.requests = []
        await f.dictate("T'as vu le devis ?")
        #expect(f.requests.allSatisfy { $0.tone == .natural })
    }
}
