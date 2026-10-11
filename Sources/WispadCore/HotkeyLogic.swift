import Foundation

/// Frappe vue par l'écoute du clavier, horodatée au moment où elle a eu lieu (ms depuis le démarrage).
public struct KeyEvent: Equatable, Sendable {
    public var phase: KeyPhase
    public var keyCode: Int
    public var flags: UInt64
    public var autorepeat: Bool
    public var time: Int

    public init(phase: KeyPhase, keyCode: Int, flags: UInt64, autorepeat: Bool = false, time: Int) {
        self.phase = phase
        self.keyCode = keyCode
        self.flags = flags
        self.autorepeat = autorepeat
        self.time = time
    }
}

/// Réglages lus par l'écoute du clavier, recopiés depuis le fil principal.
public struct HotkeyConfig: Equatable, Sendable {
    public var keyCode: Int
    public var modifierFlags: UInt64
    public var recording: Bool
    /// Une dictée écoute (préparation ou écoute) : Échap l'annule sans partir dans l'app.
    public var capturing: Bool
    /// Une dictée se termine ou un message d'erreur est affiché : Échap l'annule aussi, mais reste à l'app,
    /// où l'utilisateur a pu reprendre la main.
    public var pending: Bool

    public init(keyCode: Int = ChordMatcher.functionKeyCode, modifierFlags: UInt64 = ModifierMask.function, recording: Bool = false, capturing: Bool = false, pending: Bool = false) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.recording = recording
        self.capturing = capturing
        self.pending = pending
    }
}

/// Ce que l'écoute du clavier doit faire d'une frappe ou d'un réveil.
public struct HotkeyOutput: Equatable, Sendable {
    public enum Wake: Equatable, Sendable {
        /// Ne pas toucher au réveil prévu.
        case keep
        /// Annuler le réveil prévu et, si une heure est donnée, en prévoir un nouveau (ms depuis le démarrage).
        case reschedule(Int?)
    }

    /// Avaler la frappe : elle n'atteint pas l'app au premier plan.
    public var swallow = false
    public var effects: [GestureEffect] = []
    public var wake: Wake = .keep
    /// Raccourci enregistré pendant « Modifier le raccourci ».
    public var capturedKeyCode: Int?
    public var capturedFlags: UInt64?
    /// Échap pendant l'écoute : annuler la dictée.
    public var cancel = false
    /// Instant de l'appui sur le raccourci, pour mesurer la latence.
    public var pressedAt: Int?

    public init() {}

    /// Rien à transmettre au fil principal.
    public var isQuiet: Bool {
        effects.isEmpty && capturedKeyCode == nil && !cancel && pressedAt == nil
    }
}

/// Logique complète du raccourci, sans aucune dépendance au système : raccourci (ChordMatcher), geste
/// (GestureEngine), Échap et resynchronisation après une coupure de l'écoute par macOS. Elle tourne sur le fil
/// de l'écoute du clavier, jamais sur le fil principal, pour que le clavier du Mac n'attende jamais Wispad.
public struct HotkeyLogic: Equatable, Sendable {
    public static let escapeKeyCode = 53
    public private(set) var engine: GestureEngine
    public private(set) var chordDown = false
    /// Échap avalé à l'enfoncement : sa répétition et son relâchement sont avalés aussi.
    private var escapeSwallowed = false

    public init(engine: GestureEngine = GestureEngine()) {
        self.engine = engine
    }

    public mutating func handle(_ event: KeyEvent, config: HotkeyConfig) -> HotkeyOutput {
        if event.keyCode == Self.escapeKeyCode, let output = escape(event, config: config) {
            return output
        }
        let transition = ChordMatcher.step(
            phase: event.phase,
            keyCode: event.keyCode,
            flags: event.flags,
            configuredKey: config.keyCode,
            configuredFlags: config.modifierFlags,
            autorepeat: event.autorepeat,
            chordIsDown: chordDown,
            recording: config.recording
        )
        chordDown = transition.chordIsDown
        var output = HotkeyOutput()
        output.swallow = transition.swallow
        output.capturedKeyCode = transition.capturedKeyCode
        output.capturedFlags = transition.capturedFlags
        switch transition.edge {
        case .down:
            output.pressedAt = event.time
            output.merge(engine.keyDown(at: event.time))
        case .up:
            output.merge(engine.keyUp(at: event.time))
        case nil:
            break
        }
        return output
    }

    /// Réveil prévu par le geste (seuil de maintien, fin de l'intervalle du double appui).
    public mutating func tick(at time: Int, keyStillDown: Bool) -> HotkeyOutput {
        var output = HotkeyOutput()
        output.merge(engine.tick(at: time, keyStillDown: keyStillDown))
        return output
    }

    /// La dictée de ce geste est terminée autrement que par le geste lui-même.
    public mutating func endSession() {
        engine.endSession()
    }

    public mutating func externalToggleStarted() {
        engine.noteExternalToggleStart()
    }

    /// Après une coupure de l'écoute par macOS, des frappes ont pu se perdre : on recale l'état sur la touche réelle.
    /// Un relâchement perdu est rejoué, pour qu'une dictée en maintien ne reste pas ouverte.
    public mutating func resync(keyPhysicallyDown: Bool, at time: Int) -> HotkeyOutput {
        var output = HotkeyOutput()
        escapeSwallowed = false
        if chordDown, !keyPhysicallyDown {
            chordDown = false
            output.merge(engine.releaseLost(at: time))
        }
        return output
    }

    /// Échap annule la dictée qui écoute, sans atteindre l'app ; pendant la finalisation, il l'annule et reste à
    /// l'app. Jamais pendant l'enregistrement du raccourci, ni avec ⌘, ⌥, ⌃ ou ⇧ (⌘⌥Échap reste « Forcer à quitter »).
    private mutating func escape(_ event: KeyEvent, config: HotkeyConfig) -> HotkeyOutput? {
        var output = HotkeyOutput()
        switch event.phase {
        case .down:
            if escapeSwallowed {
                output.swallow = true
                return output
            }
            let modifiers = event.flags & (ModifierMask.command | ModifierMask.option | ModifierMask.control | ModifierMask.shift)
            guard config.capturing || config.pending, !config.recording, !event.autorepeat, modifiers == 0 else { return nil }
            output.cancel = true
            if config.capturing {
                escapeSwallowed = true
                output.swallow = true
            }
            return output
        case .up:
            guard escapeSwallowed else { return nil }
            escapeSwallowed = false
            output.swallow = true
            return output
        case .flags:
            return nil
        }
    }
}

private extension HotkeyOutput {
    mutating func merge(_ step: GestureStep) {
        effects += step.effects
        wake = .reschedule(step.nextWakeMilliseconds)
    }
}
