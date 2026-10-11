import AppKit
import WispadCore
import SwiftUI

// Outil de développement : absent de la version Release.
#if DEBUG

/// Affiche la bulle avec un spectre simulé, sans micro, sans API ni historique réel.
/// Parcourt apparition, maintien, mains libres, finalisation, erreur et disparition, avec des pauses
/// assez longues pour capturer chaque état. App accessoire, panneau non activant : jamais de focus.
@MainActor
enum OverlayDemo {
    /// Instants (secondes après le lancement) de chaque étape.
    static let steps: [(at: Double, label: String)] = [
        (0.8, "apparition + maintien"),
        (5.0, "mains libres"),
        (9.5, "finalisation"),
        (13.5, "erreur"),
        (18.0, "disparition"),
        (20.0, "mot appris"),
    ]
    static let end = 24.5

    static func run() {
        let app = NSApplication.shared
        let visibilityProbe = CommandLine.arguments.contains("--visibility-probe")
        app.setActivationPolicy(visibilityProbe ? .regular : .accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-overlay-demo-\(UUID().uuidString)")
        let model: AppModel
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: AppDependencies())
        } catch {
            print("Démo impossible : \(error.localizedDescription)")
            return
        }
        model.overlay.install(model: model)
        // `--reduce-motion` : fondus simples, sans toucher au réglage système.
        model.overlay.state.forcesReduceMotion = CommandLine.arguments.contains("--reduce-motion")
        // Message stable pour vérifier le survol et la fermeture, sans attendre le cycle de la démo.
        if CommandLine.arguments.contains("--message-preview") {
            model.coordinator.failureText = "Texte de démonstration."
            model.coordinator.phase = .failure("Aucun champ actif : copie le texte.")
            model.overlay.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                try? FileManager.default.removeItem(at: directory)
                app.terminate(nil)
            }
            app.run()
            return
        }
        // Sans audio, App Nap retarderait les minuteries de la démo et fausserait les captures.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Démo de la bulle")
        let coordinator = model.coordinator
        let voice = Voice()
        let started = Date()
        var lastTick = Date()
        let ticker = FrameTicker { elapsed in
            do {
                // Deux images sautées se voient : signale tout blocage du fil principal au-delà de 34 ms.
                let gap = Date().timeIntervalSince(lastTick)
                lastTick = Date()
                if gap > 0.034 {
                    print(String(format: "DEMO t=%.2f blocage du fil principal : %.0f ms", Date().timeIntervalSince(started), gap * 1000))
                    fflush(stdout)
                }
                guard coordinator.isListening else { return }
                coordinator.spectrum = DictationCoordinator.smoothed(coordinator.spectrum, toward: voice.next(), elapsed: elapsed)
            }
        }
        ticker.start(on: NSScreen.main)
        // Cadre de la pilule à chaque image où il change : une transition animée avance pas à pas,
        // un saut n'y laisse qu'une ligne.
        let followMouse = model.overlay.state.onPillFrameChange
        model.overlay.state.onPillFrameChange = {
            followMouse?()
            let frame = model.overlay.state.pillFrame
            print(String(format: "DEMO PILULE t=%.3f x=%.1f largeur=%.1f", Date().timeIntervalSince(started), frame.minX, frame.width))
            fflush(stdout)
        }
        print("DEMO prêt")
        fflush(stdout)
        func step(_ index: Int, _ action: @escaping @MainActor () -> Void) {
            // Minuterie sans tolérance : les étapes tombent à l'heure, les captures peuvent s'y caler.
            let timer = Timer(timeInterval: steps[index].at, repeats: false) { _ in
                MainActor.assumeIsolated {
                    print(String(format: "DEMO t=%.3f %@", Date().timeIntervalSince(started), steps[index].label))
                    fflush(stdout)
                    action()
                }
            }
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .common)
            // État de la fenêtre une fois l'animation posée, pour vérifier la souris sans cliquer.
            DispatchQueue.main.asyncAfter(deadline: .now() + steps[index].at + 1.5) {
                let overlay = model.overlay
                print(String(
                    format: "DEMO t=%.2f mode=%@ visible=%d ignoresMouse=%d moniteurs=%d panneau=%@ pilule=%@ actif=%d",
                    Date().timeIntervalSince(started), "\(overlay.state.mode)", overlay.panel?.isVisible == true ? 1 : 0,
                    overlay.panel?.ignoresMouseEvents == true ? 1 : 0, overlay.isMonitoringMouse ? 1 : 0,
                    NSStringFromRect(overlay.panel?.frame ?? .zero), NSStringFromRect(overlay.state.pillFrame), NSApp.isActive ? 1 : 0
                ))
                fflush(stdout)
            }
        }
        // Mêmes appels que le coordinateur : show() suit chaque phase qu'il affiche, la finalisation passe
        // par l'observation de la phase.
        step(0) {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            // Première lecture du Dock depuis le fil principal, comme celle du premier show() de l'app.
            var clock = Date()
            let dockShown = screen.map { OverlayController.dockShown(on: $0) } == true
            let dockRead = Date().timeIntervalSince(clock) * 1000
            clock = Date()
            coordinator.phase = .starting
            model.overlay.show()
            let elapsed = Date().timeIntervalSince(clock) * 1000
            coordinator.phase = .listening(.pushToTalk)
            model.overlay.show()
            print(String(
                format: "DEMO lecture du Dock en %.2f ms, premier show() en %.2f ms, Dock affiché=%d, écran=%@ visible=%@, bas de la pilule=%.1f",
                dockRead, elapsed, dockShown ? 1 : 0,
                NSStringFromRect(screen?.frame ?? .zero), NSStringFromRect(screen?.visibleFrame ?? .zero),
                (model.overlay.panel?.frame.minY ?? 0) + OverlayLayout.bottomMargin
            ))
            fflush(stdout)
        }
        step(1) {
            coordinator.phase = .listening(.toggle)
            model.overlay.show()
        }
        if visibilityProbe {
            // Retrait extérieur pendant une écoute inchangée : aucun micro ni appel API.
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                model.overlay.panel?.orderOut(nil)
                print("VISIBILITY retrait simulé pendant l'écoute")
                fflush(stdout)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.6) {
                let panel = model.overlay.panel
                let restored = panel?.isVisible == true && model.overlay.state.presented && coordinator.isListening
                print("VISIBILITY restaurée=\(restored) focus=\(panel?.isKeyWindow == true)")
                fflush(stdout)
            }
        }
        step(2) { coordinator.phase = .finishing }
        step(3) {
            coordinator.failureText = "Texte de démonstration."
            coordinator.phase = .failure("Insertion impossible. Texte gardé dans l'historique.")
            model.overlay.show()
        }
        step(4) {
            coordinator.phase = .idle
            coordinator.failureText = nil
            model.overlay.hide()
        }
        step(5) { coordinator.notifyLearned(["Seedance"]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + end) {
            try? FileManager.default.removeItem(at: directory)
            ProcessInfo.processInfo.endActivity(activity)
            app.terminate(nil)
        }
        app.run()
    }

    /// Voix simulée : syllabes vers 4 par seconde, bandes renouvelées vers 20 Hz comme le vrai micro.
    @MainActor
    private final class Voice {
        private var frame = 0
        private var mirrored = Array(repeating: Float(0), count: DictationCoordinator.barCount)

        func next() -> [Float] {
            frame += 1
            if frame % 3 == 0 {
                let time = Double(frame) / 60
                let syllable = max(0, sin(time * 2 * .pi * 2.2)) * (0.7 + 0.3 * sin(time * 0.9))
                let bands = (0..<SpectrumAnalyzer.bandCount).map { band in
                    Float(syllable * max(0.12, 1 - Double(band) * 0.16) * Double.random(in: 0.7...1))
                }
                mirrored = bands.reversed() + bands.dropFirst()
            }
            return mirrored
        }
    }
}

#endif
