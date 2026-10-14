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
    /// « Coller la dernière dictée » ; nil quand il est désactivé ou en cours d'enregistrement dans Réglages.
    public var paste: PasteShortcut?

    public init(keyCode: Int = ChordMatcher.functionKeyCode, modifierFlags: UInt64 = ModifierMask.function, recording: Bool = false, capturing: Bool = false, pending: Bool = false, paste: PasteShortcut? = nil) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.recording = recording
        self.capturing = capturing
        self.pending = pending
        self.paste = paste
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
    /// « Coller la dernière dictée » demandé.
    public var pasteLast = false

    public init() {}

    /// Rien à transmettre au fil principal.
    public var isQuiet: Bool {
        effects.isEmpty && capturedKeyCode == nil && !cancel && pressedAt == nil && !pasteLast
    }
}

/// Logique complète du raccourci, sans aucune dépendance au système : raccourci (ChordMatcher), geste
/// (GestureEngine), Échap et resynchronisation après une coupure de l'écoute par macOS. Elle tourne sur le fil
/// de l'écoute du clavier, jamais sur le fil principal, pour que le clavier du Mac n'attende jamais Wispad.
public struct HotkeyLogic: Equatable, Sendable {
    public static let escapeKeyCode = 53
    public private(set) var engine: GestureEngine
    public private(set) var chordDown = false
    /// Raccourci avec lequel l'accord a été enfoncé.
    private var chordShortcut: Shortcut?
    /// Échap avalé à l'enfoncement : sa répétition et son relâchement sont avalés aussi.
    private var escapeSwallowed = false
    /// Touche de « Coller la dernière dictée » avalée à l'enfoncement : répétition et relâchement aussi.
    private var pasteKeyDown: Int?

    public init(engine: GestureEngine = GestureEngine()) {
        self.engine = engine
    }

    public mutating func handle(_ event: KeyEvent, config: HotkeyConfig) -> HotkeyOutput {
        if event.keyCode == Self.escapeKeyCode, let output = escape(event, config: config) {
            return output
        }
        if let output = pasteShortcut(event, config: config) {
            return output
        }
        var output = HotkeyOutput()
        // Raccourci remplacé dans Réglages pendant qu'il était tenu : son relâchement ne serait plus reconnu.
        if chordDown, chordShortcut != Shortcut(config) {
            releaseChord(at: event.time, into: &output)
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
        if !chordDown {
            chordShortcut = nil
        } else if transition.edge == .down {
            chordShortcut = Shortcut(config)
        }
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
        // Relâchement jamais reçu, abandonné par le geste : la touche est levée, l'appui suivant compte.
        if chordDown, !keyStillDown, engine.isIdle {
            chordDown = false
            chordShortcut = nil
        }
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
        pasteKeyDown = nil
        if chordDown, !keyPhysicallyDown {
            releaseChord(at: time, into: &output)
        }
        return output
    }

    /// Surveillance de l'écoute restée active : elle a pu ne rien recevoir sans que macOS la coupe (saisie
    /// sécurisée, écran verrouillé, autre session, veille). Un accord que la touche réelle ne tient plus est rendu
    /// comme un relâchement perdu. Un appui en attente est laissé à son réveil, qui lit déjà la touche ; Échap et
    /// « Coller la dernière dictée » gardent leurs règles.
    public mutating func reconcile(keyPhysicallyDown: Bool, at time: Int) -> HotkeyOutput {
        var output = HotkeyOutput()
        if chordDown, !keyPhysicallyDown, !engine.isPressPending {
            releaseChord(at: time, into: &output)
        }
        return output
    }

    /// L'écoute du clavier a été retirée (autorisation retirée dans Réglages Système) : plus aucune frappe ne sera
    /// vue. Le geste en cours, Échap et « Coller la dernière dictée » avalés sont oubliés sans effet ; l'app arrête
    /// elle-même la dictée qu'ils tenaient, en disant pourquoi. Écoute rendue, le premier appui compte.
    public mutating func listeningLost() {
        engine.forceIdle()
        chordDown = false
        chordShortcut = nil
        escapeSwallowed = false
        pasteKeyDown = nil
    }

    /// Accord rendu sans son relâchement : un maintien s'arrête, un appui en attente est oublié sans rien démarrer.
    private mutating func releaseChord(at time: Int, into output: inout HotkeyOutput) {
        chordDown = false
        chordShortcut = nil
        output.merge(engine.releaseLost(at: time))
    }

    /// « Coller la dernière dictée » : touche et modificateurs exacts, une seule fois par enfoncement, jamais
    /// pendant l'enregistrement d'un raccourci. La combinaison exige ⌃, ⌥ ou ⌘ et jamais fn : le raccourci de
    /// dictée ne la voit pas, et fn enfoncé (dictée en maintien) l'empêche de se déclencher.
    private mutating func pasteShortcut(_ event: KeyEvent, config: HotkeyConfig) -> HotkeyOutput? {
        var output = HotkeyOutput()
        switch event.phase {
        case .down:
            if let held = pasteKeyDown, held == event.keyCode {
                if event.autorepeat {
                    output.swallow = true
                    return output
                }
                // Relâchement perdu : un nouvel enfoncement repart de zéro, la frappe n'est jamais avalée à tort.
                pasteKeyDown = nil
            }
            guard !config.recording, !event.autorepeat, let shortcut = config.paste,
                  shortcut.matches(keyCode: event.keyCode, flags: event.flags) else { return nil }
            pasteKeyDown = event.keyCode
            output.swallow = true
            output.pasteLast = true
            return output
        case .up:
            guard let held = pasteKeyDown, held == event.keyCode else { return nil }
            pasteKeyDown = nil
            output.swallow = true
            return output
        case .flags:
            return nil
        }
    }

    /// Échap annule la dictée qui écoute, sans atteindre l'app ; pendant la finalisation, il l'annule et reste à
    /// l'app. Jamais pendant l'enregistrement du raccourci, ni avec ⌘, ⌥, ⌃ ou ⇧ (⌘⌥Échap reste « Forcer à quitter »).
    private mutating func escape(_ event: KeyEvent, config: HotkeyConfig) -> HotkeyOutput? {
        var output = HotkeyOutput()
        switch event.phase {
        case .down:
            if escapeSwallowed {
                if event.autorepeat {
                    output.swallow = true
                    return output
                }
                // Relâchement perdu : un nouvel enfoncement repart de zéro, Échap n'est jamais avalé à tort.
                escapeSwallowed = false
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

    /// Touche et modificateurs du raccourci de dictée, comparés comme ChordMatcher les lit.
    private struct Shortcut: Equatable, Sendable {
        var keyCode: Int
        var modifierFlags: UInt64

        init(_ config: HotkeyConfig) {
            keyCode = config.keyCode
            modifierFlags = config.modifierFlags & ModifierMask.relevant
        }
    }
}

private extension HotkeyOutput {
    mutating func merge(_ step: GestureStep) {
        effects += step.effects
        wake = .reschedule(step.nextWakeMilliseconds)
    }
}
