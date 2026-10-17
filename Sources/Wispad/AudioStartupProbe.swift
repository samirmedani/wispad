import AppKit
import AVFoundation
import QuartzCore
import WispadCore
import os

// Outil de développement : absent de la version Release.
#if DEBUG

/// Mesure locale du premier paquet micro, sans coffre ni API. Les courts fichiers sont supprimés.
@MainActor
enum AudioStartupProbe {
    static func run() {
        let app = NSApplication.shared
        // Sans fenêtre : app d'arrière-plan, jamais au premier plan (une app « accessoire » est activée au lancement).
        app.setActivationPolicy(.prohibited)
        guard PermissionCenter.microphoneStatus() == .authorized else {
            print("audio_probe_skipped=microphone_not_authorized")
            exit(2)
        }
        Task { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-audio-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            var audio = AudioCapture()
            let playSound = CommandLine.arguments.contains("--sound")
            let freshEngine = CommandLine.arguments.contains("--fresh-engine")
            let mainTicks = OSAllocatedUnfairLock(initialState: 0)
            let ticker = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in mainTicks.withLock { $0 += 1 } }
            defer { ticker.invalidate() }
            if playSound { SoundCues.prepare() }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for attempt in 1...3 {
                    if freshEngine, attempt > 1 { audio = AudioCapture() }
                    let first = OSAllocatedUnfairLock<Double?>(initialState: nil)
                    audio.onPCM = { _ in
                        let isFirst = first.withLock { value in
                            guard value == nil else { return false }
                            value = CACurrentMediaTime()
                            return true
                        }
                        if isFirst, attempt == 1, playSound {
                            Task { @MainActor in SoundCues.play(.start) }
                        }
                    }
                    let started = CACurrentMediaTime()
                    mainTicks.withLock { $0 = 0 }
                    // Même délai qu'une dictée : un démarrage qui ne rend pas la main est signalé, la sonde ne reste
                    // pas bloquée.
                    let recorder = audio
                    let starting = Task.detached { () async -> Result<URL, Error> in
                        do {
                            return .success(try await recorder.start(directory: directory))
                        } catch {
                            return .failure(error)
                        }
                    }
                    guard let result = await DictationCoordinator.value(of: starting, within: MicrophoneStartWatch.startLimit) else {
                        recorder.abandonStart()
                        try? FileManager.default.removeItem(at: directory)
                        print("audio_probe_failed=start_timeout")
                        exit(1)
                    }
                    _ = try result.get()
                    let returned = CACurrentMediaTime()
                    let ticksDuringStart = mainTicks.withLock { $0 }
                    for _ in 0..<200 where first.withLock({ $0 }) == nil {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    let stopped = audio.stop()
                    if let url = stopped.url { try FileManager.default.removeItem(at: url) }
                    guard let received = first.withLock({ $0 }) else {
                        try? FileManager.default.removeItem(at: directory)
                        print("audio_probe_failed=no_pcm")
                        exit(1)
                    }
                    print(String(format: "audio_probe attempt=%d fresh=%d start_return_ms=%.1f first_pcm_ms=%.1f main_ticks=%d stopped=%d", attempt, freshEngine ? 1 : 0, (returned - started) * 1000, (received - started) * 1000, ticksDuringStart, audio.isRunning ? 0 : 1))
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                print("audio_probe_passed=true")
                try FileManager.default.removeItem(at: directory)
                app.terminate(nil)
            } catch {
                _ = audio.stop()
                try? FileManager.default.removeItem(at: directory)
                print("audio_probe_failed=\(type(of: error))")
                exit(1)
            }
        }
        app.run()
    }
}

#endif
