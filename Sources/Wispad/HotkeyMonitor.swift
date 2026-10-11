import AppKit
import Foundation
import WispadCore
import os

/// Journal système du raccourci : seulement l'état de l'écoute du clavier, jamais les touches.
let hotkeyLog = Logger.wispad("raccourci")

/// Côté fil principal du raccourci : recopie les réglages vers l'écoute du clavier (KeyboardTap, sur son
/// propre fil) et transmet ses effets à la dictée.
@MainActor
final class HotkeyMonitor {
    private weak var model: AppModel?
    private var tap: KeyboardTap?
    private var clickMonitor: Any?
    /// Instant du dernier appui sur le raccourci (horloge des frappes), pour mesurer la latence.
    private(set) var lastPressAt: Int?

    var diagnosticState: KeyboardDiagnosticState {
        tap?.diagnosticState ?? KeyboardDiagnosticState()
    }

    func start(model: AppModel) {
        self.model = model
        let tap = KeyboardTap(
            deliver: { [weak self] output in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(output) } }
            },
            unavailable: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.model?.statusBanner = String(localized: "Autorise la surveillance des entrées pour le raccourci global.")
                    }
                }
            }
        )
        self.tap = tap
        refreshConfig()
        tap.start()
        // Un clic peut déplacer le curseur ou envoyer le message : le raccord avec le dernier collage n'est
        // plus sûr. Seul un compteur avance, rien n'est lu du clic.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            KeyboardTap.noteInput()
        }
    }

    /// Raccourci choisi et enregistrement en cours, lus par l'écoute du clavier.
    func refreshConfig() {
        guard let model else { return }
        let keyCode = model.settings.keyCode
        let flags = model.settings.modifierFlags
        let recording = model.isRecordingShortcut
        let shortcut = model.settings.pasteLastShortcut
        // Même combinaison que la dictée (choisie après coup comme raccourci de dictée) : la dictée passe avant.
        let clashes = keyCode == shortcut.keyCode && flags & PasteShortcut.modifierMask == shortcut.modifiers
        let paste = shortcut.enabled && !model.isRecordingPasteShortcut && !clashes ? shortcut : nil
        tap?.update { config in
            config.keyCode = keyCode
            config.modifierFlags = flags
            config.recording = recording
            config.paste = paste
        }
    }

    /// Une dictée écoute : Échap l'annule sans atteindre l'app. Elle se termine ou un message est affiché :
    /// Échap l'annule et reste à l'app. Le reste du temps, Échap appartient à l'app.
    func setDictationState(capturing: Bool, pending: Bool) {
        tap?.update {
            $0.capturing = capturing
            $0.pending = pending
        }
    }

    func installTap() {
        tap?.reinstall()
    }

    func sessionEnded() {
        tap?.endSession()
    }

    func externalToggleStarted() {
        tap?.externalToggleStarted()
    }

    func now() -> Int {
        KeyboardTap.now()
    }

    private func receive(_ output: HotkeyOutput) {
        guard let model else { return }
        // « Coller la dernière dictée » : rien d'autre dans cette sortie, ni geste ni raccourci enregistré.
        if output.pasteLast {
            let coordinator = model.coordinator
            Task { @MainActor in await coordinator.pasteLastDictation() }
            return
        }
        if let pressed = output.pressedAt { lastPressAt = pressed }
        if let keyCode = output.capturedKeyCode, let flags = output.capturedFlags {
            model.settings.keyCode = keyCode
            model.settings.modifierFlags = flags
            model.isRecordingShortcut = false
            model.saveSettings()
        }
        // Étape « Touche » du premier lancement : l'appui est seulement constaté, aucune dictée ne démarre.
        if model.shortcutReceived(output) { return }
        let coordinator = model.coordinator
        if output.cancel { coordinator.cancel() }
        let pressed = lastPressAt
        for effect in output.effects {
            switch effect {
            case .startPushToTalk:
                coordinator.enqueue { await coordinator.begin(.pushToTalk, pressedAt: pressed) }
            case .startToggle:
                coordinator.enqueue { await coordinator.begin(.toggle, pressedAt: pressed) }
            case .stopPushToTalk, .stopToggle:
                coordinator.enqueue { coordinator.endCapture() }
            }
        }
    }
}
