import AppKit
import WispadCore

// Outil de développement : absent de la version Release.
#if DEBUG

/// Banc d'insertion : une dictée complète, transcription simulée, tout le reste réel (contexte lu au départ dans l'app
/// au premier plan, collage, attente d'un champ, carte « Texte prêt »). L'app de test change elle-même de champ.
/// \u0060--insertion-bench --text "…" [--listen-ms 1200] [--settle-ms 3000]\u0060 ; une ligne \u0060BENCH\u0060 à la fin.
/// Wispad de banc ne passe jamais au premier plan ; ses réglages et son historique vivent dans un dossier temporaire.
@MainActor
enum InsertionBench {
    private final class Audio: AudioRecording, @unchecked Sendable {
        var onPCM: (@Sendable (Data) -> Void)?
        let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
        private var url: URL?

        func start(directory: URL) async throws -> URL {
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

    private final class Stream: SpeechStreaming, @unchecked Sendable {
        var onPartial: (@Sendable (String) -> Void)?
        let text: String
        init(text: String) { self.text = text }
        func start() async throws {}
        func send(_ data: Data) {}
        func finish() async throws -> StreamFinish { StreamFinish(text: text, endingFinalized: true) }
        func cancel() {}
    }

    static func run(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let text = value("--text") ?? "Banc Wispad 42."
        let listen = Double(value("--listen-ms") ?? "") ?? 1_200
        let settle = Double(value("--settle-ms") ?? "") ?? 3_000
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-bench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.loadKey = { $0 == ProviderID.xai.rawValue ? "bench" : nil }
        dependencies.saveKey = { _, _ in true }
        dependencies.refreshKeys = { true }
        dependencies.requestMicrophone = { true }
        let audio = Audio()
        let stream = Stream(text: text)
        dependencies.makeCapture = { audio }
        dependencies.makeSession = { _ in stream }
        dependencies.transcribe = { _, _ in text }
        dependencies.clean = { text, _, _, _ in CleanupOutcome(text: text) }
        dependencies.playCue = { _, _ in }
        dependencies.muteOutput = { _, _ in }
        dependencies.restoreOutput = {}
        dependencies.watchCorrections = { _, _, _, _ in }
        dependencies.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        var settings = AppSettings()
        settings.onboardingCompleted = true
        settings.cleanupEnabled = false
        settings.verifyWithFile = false
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.useWindowContext = false
        settings.language = .french
        let model: AppModel
        do {
            model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        } catch {
            print("BENCH status=setup_failed")
            exit(2)
        }
        model.overlay.install(model: model)
        Task { @MainActor in
            await model.coordinator.begin(.toggle)
            try? await Task.sleep(for: .milliseconds(Int(listen)))
            await model.coordinator.end()
            try? await Task.sleep(for: .milliseconds(Int(settle)))
            model.reloadHistory()
            let record = model.history.first
            print("BENCH status=\(record?.insertionStatus ?? "none") app=\(record?.targetApp ?? "-")")
            fflush(stdout)
            try? FileManager.default.removeItem(at: directory)
            exit(0)
        }
        app.run()
    }
}

#endif
