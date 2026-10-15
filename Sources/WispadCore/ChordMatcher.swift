import Foundation

public enum ModifierMask {
    public static let command: UInt64 = 1_048_576
    public static let shift: UInt64 = 131_072
    public static let option: UInt64 = 524_288
    public static let control: UInt64 = 262_144
    public static let function: UInt64 = 8_388_608
    public static let relevant = command | shift | option | control | function
}

public enum KeyPhase: Equatable, Sendable {
    case down
    case up
    case flags
}

public enum ChordEdge: Equatable, Sendable {
    case down
    case up
}

public struct ChordTransition: Equatable, Sendable {
    public var swallow: Bool
    public var edge: ChordEdge?
    public var chordIsDown: Bool
    public var capturedKeyCode: Int?
    public var capturedFlags: UInt64?

    public init(
        swallow: Bool,
        edge: ChordEdge?,
        chordIsDown: Bool,
        capturedKeyCode: Int? = nil,
        capturedFlags: UInt64? = nil
    ) {
        self.swallow = swallow
        self.edge = edge
        self.chordIsDown = chordIsDown
        self.capturedKeyCode = capturedKeyCode
        self.capturedFlags = capturedFlags
    }
}

public enum ChordMatcher {
    /// Code de la touche fn : configurée seule, elle sert de raccourci sans autre touche.
    public static let functionKeyCode = 63

    public static func step(
        phase: KeyPhase,
        keyCode: Int,
        flags: UInt64,
        configuredKey: Int,
        configuredFlags: UInt64,
        autorepeat: Bool,
        chordIsDown: Bool,
        recording: Bool
    ) -> ChordTransition {
        let current = flags & ModifierMask.relevant
        let required = configuredFlags & ModifierMask.relevant
        if recording {
            // Enregistrement d'un nouveau raccourci : la touche enregistrée ne démarre jamais l'accord (ni geste, ni
            // dictée), mais un accord déjà enfoncé se termine encore, relâché ou combiné à une autre touche.
            var transition = step(
                phase: phase, keyCode: keyCode, flags: flags, configuredKey: configuredKey, configuredFlags: configuredFlags,
                autorepeat: autorepeat, chordIsDown: chordIsDown, recording: false
            )
            if transition.edge == .down {
                transition.edge = nil
                transition.chordIsDown = chordIsDown
            }
            if phase == .flags, keyCode == functionKeyCode, current == 0 {
                // fn seule, enregistrée à son relâchement.
                transition.swallow = false
                transition.capturedKeyCode = functionKeyCode
                transition.capturedFlags = ModifierMask.function
            } else if phase == .down, !autorepeat {
                // Toute autre touche, avec ses modificateurs ; fn n'arrive que par ses changements de modificateur.
                transition.swallow = keyCode != functionKeyCode
                if keyCode != functionKeyCode {
                    transition.capturedKeyCode = keyCode
                    transition.capturedFlags = current
                }
            }
            return transition
        }
        if configuredKey == functionKeyCode {
            return functionAlone(phase: phase, keyCode: keyCode, current: current, chordIsDown: chordIsDown)
        }
        if phase == .flags {
            if chordIsDown, current != required {
                return ChordTransition(swallow: false, edge: .up, chordIsDown: false)
            }
            return ChordTransition(swallow: false, edge: nil, chordIsDown: chordIsDown)
        }
        guard keyCode == configuredKey else {
            return ChordTransition(swallow: false, edge: nil, chordIsDown: chordIsDown)
        }
        if phase == .down {
            if autorepeat {
                return ChordTransition(swallow: chordIsDown, edge: nil, chordIsDown: chordIsDown)
            }
            guard current == required else {
                return ChordTransition(swallow: false, edge: nil, chordIsDown: chordIsDown)
            }
            if chordIsDown {
                return ChordTransition(swallow: true, edge: nil, chordIsDown: true)
            }
            return ChordTransition(swallow: true, edge: .down, chordIsDown: true)
        }
        if phase == .up, chordIsDown {
            return ChordTransition(swallow: true, edge: .up, chordIsDown: false)
        }
        return ChordTransition(swallow: false, edge: nil, chordIsDown: chordIsDown)
    }

    /// fn seule : appui sans autre modificateur, relâché ou combiné à une autre touche = fin.
    private static func functionAlone(phase: KeyPhase, keyCode: Int, current: UInt64, chordIsDown: Bool) -> ChordTransition {
        let fnOnly = current == ModifierMask.function
        switch phase {
        case .flags where keyCode == functionKeyCode:
            // Avalé pour que macOS ne déclenche pas son action fn / 🌐 (dictée Apple, emojis).
            return ChordTransition(swallow: true, edge: fnOnly == chordIsDown ? nil : (fnOnly ? .down : .up), chordIsDown: fnOnly)
        case .flags:
            if !chordIsDown, fnOnly {
                return ChordTransition(swallow: false, edge: .down, chordIsDown: true)
            }
            if chordIsDown, !fnOnly {
                return ChordTransition(swallow: false, edge: .up, chordIsDown: false)
            }
        case .down:
            if chordIsDown, keyCode != functionKeyCode {
                return ChordTransition(swallow: false, edge: .up, chordIsDown: false)
            }
        case .up:
            break
        }
        return ChordTransition(swallow: false, edge: nil, chordIsDown: chordIsDown)
    }
}
