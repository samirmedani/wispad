import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import WispadCore
import ServiceManagement

enum PermissionCenter {
    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Accès au micro accordé, lu sans rien demander.
    static func microphoneAuthorized() -> Bool {
        microphoneStatus() == .authorized
    }

    static func requestMicrophone() async -> Bool {
        switch microphoneStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    static func accessibilityTrusted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func inputMonitoringTrusted() -> Bool {
        CGPreflightListenEventAccess()
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    /// Panneau de Réglages Système › Confidentialité et sécurité où se règle cette autorisation.
    static func settingsURL(for kind: PermissionKind) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)")
    }

    static func openSettings(for kind: PermissionKind) {
        guard let url = settingsURL(for: kind) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Réglages Système › Clavier (réglage « Touche fn/🌐 »).
    static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Action de la touche fn/🌐 choisie dans macOS (0 : ne rien faire) ; nil si jamais réglée.
    static func fnUsage() -> Int? {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
    }

    /// Quitte et rouvre Wispad (autorisation que macOS n'applique qu'au lancement suivant). Le chemin de l'app
    /// est passé en argument, jamais dans le texte de la commande.
    @MainActor static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Attend que cette instance soit vraiment fermée, sinon `open` ne ferait que la réactiver.
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try process.run()
        } catch {
            return
        }
        // Comme après une mise à jour : une feuille ou une fenêtre modale fait refuser la fermeture par macOS, et
        // l'aide attendrait sans fin. Wispad s'arrête alors de lui-même, après le rangement habituel.
        Task { @MainActor in
            await UpdateTools.quitForRelaunch()
            UpdateTools.forceQuit()
        }
    }
}

/// Autorisations et ouverture à la connexion, lues ensemble sans rien demander (depuis n'importe quel fil).
struct PermissionReading: Sendable {
    var microphone: AVAuthorizationStatus
    var accessibility: Bool
    var inputMonitoring: Bool
    var launchAtLogin: Bool

    static func read() -> PermissionReading {
        PermissionReading(microphone: PermissionCenter.microphoneStatus(),
                          accessibility: PermissionCenter.accessibilityTrusted(prompt: false),
                          inputMonitoring: PermissionCenter.inputMonitoringTrusted(),
                          launchAtLogin: LoginItemController.isEnabled)
    }
}

enum LoginItemController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
