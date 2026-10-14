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

    /// Avant chaque dictée. L'accès est lu sur une file à lui (une question au démon des autorisations de macOS, une
    /// dizaine de millisecondes) : jamais sur un fil de Swift concurrency, et sans attendre une autre lecture
    /// d'autorisation (`PermissionReads`). `status` : la lecture de l'accès, remplacée dans les tests.
    static func requestMicrophone(status: @escaping @Sendable () -> AVAuthorizationStatus = { PermissionCenter.microphoneStatus() }) async -> Bool {
        let current = await BlockingQueue.run(label: "wispad.autorisations.micro", status)
        switch current {
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

/// Lectures d'autorisation hors du fil principal. Chacune bloque le temps d'une question au démon des autorisations
/// de macOS (une dizaine de millisecondes, bien plus sur une machine lente) : elles passent sur une file GCD, jamais
/// sur un fil de Swift concurrency, dont quelques-uns servent toute l'app (minuteries de la dictée comprises).
enum PermissionReads {
    private static let queue = BlockingQueue(label: "wispad.autorisations")

    static func offMain<Value: Sendable>(_ read: @escaping @Sendable () -> Value) async -> Value {
        await queue.run(read)
    }
}

/// Ordre des lectures d'autorisation affichées (Réglages, barre latérale, premier lancement guidé) : chacune prend un
/// numéro à son départ, et chaque valeur garde celui de la lecture qui l'a donnée. Une lecture partie plus tôt ne la
/// remplace jamais, même si sa réponse arrive après : une lecture hors du fil principal qui tarde n'efface pas la
/// relecture faite entre-temps après un clic.
struct PermissionReadOrder {
    enum Value: Hashable {
        case microphone
        case accessibility
        case inputMonitoring
        case launchAtLogin
    }

    private var started = 0
    private var givenBy: [Value: Int] = [:]

    /// Numéro de la lecture qui part.
    mutating func start() -> Int {
        started += 1
        return started
    }

    /// Vrai si la lecture `serial` est la plus récente à donner `value` : sa valeur est retenue.
    mutating func accepts(_ serial: Int, for value: Value) -> Bool {
        guard serial > givenBy[value, default: 0] else { return false }
        givenBy[value] = serial
        return true
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
