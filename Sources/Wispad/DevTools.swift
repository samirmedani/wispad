import AppKit
import Foundation

// Outils de développement, compilés en Debug seulement (scripts/build.sh) : jamais dans la version Release.
#if DEBUG

enum DevTools {
    /// Lance l'outil demandé par la ligne de commande ; vrai s'il a pris la main (l'app ne démarre pas).
    static func handle(_ arguments: [String]) -> Bool {
        if arguments.contains("--window-context-probe") {
            MainActor.assumeIsolated { WindowTextProbe.runDiagnostic(arguments: arguments) }
        }
        if arguments.contains("--audio-startup-probe") {
            MainActor.assumeIsolated { AudioStartupProbe.run() }
            return true
        }
        if arguments.contains("--self-test") {
            guard visibleDiagnosticAllowed(arguments) else {
                print("Test d'insertion non lancé : une fenêtre visible nécessite --show-window et une demande explicite.")
                return true
            }
            MainActor.assumeIsolated { InsertionSelfTest.run() }
            return true
        }
        if let index = arguments.firstIndex(of: "--paste-probe"), arguments.indices.contains(index + 1),
           let pid = pid_t(arguments[index + 1]) {
            MainActor.assumeIsolated { PasteProbe.run(pid: pid) }
            return true
        }
        if arguments.contains("--bubble-probe") {
            MainActor.assumeIsolated { BubbleProbe.run(arguments: arguments) }
            return true
        }
        if arguments.contains("--bubble-gallery") {
            MainActor.assumeIsolated { BubbleGallery.run(arguments: arguments) }
            return true
        }
        if arguments.contains("--design-preview") {
            MainActor.assumeIsolated { DesignPreview.run(arguments: arguments) }
            return true
        }
        if arguments.contains("--overlay-demo") {
            guard visibleDiagnosticAllowed(arguments) else {
                print("Démo de bulle non lancée : une fenêtre visible nécessite --show-window et une demande explicite.")
                return true
            }
            MainActor.assumeIsolated { OverlayDemo.run() }
            return true
        }
        return false
    }

    /// Une fenêtre visible seulement sur demande explicite, jamais en arrière-plan ni hors écran.
    private static func visibleDiagnosticAllowed(_ arguments: [String]) -> Bool {
        arguments.contains("--show-window") && !arguments.contains("--background") && !arguments.contains("--offscreen")
    }
}

#endif
