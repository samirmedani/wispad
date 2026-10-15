import Foundation

public struct GestureConfig: Equatable, Sendable {
    public var holdMilliseconds: Int
    public var doubleTapGapMilliseconds: Int

    public init(holdMilliseconds: Int = 170, doubleTapGapMilliseconds: Int = 280) {
        self.holdMilliseconds = max(1, holdMilliseconds)
        self.doubleTapGapMilliseconds = max(1, doubleTapGapMilliseconds)
    }
}

public enum GestureEffect: Equatable, Sendable {
    case startPushToTalk
    case stopPushToTalk
    case startToggle
    case stopToggle
}

public struct GestureStep: Equatable, Sendable {
    public var effects: [GestureEffect]
    public var nextWakeMilliseconds: Int?

    public init(effects: [GestureEffect] = [], nextWakeMilliseconds: Int? = nil) {
        self.effects = effects
        self.nextWakeMilliseconds = nextWakeMilliseconds
    }
}

/// Distinguishes a single tap, a double tap and a hold. A first press cannot
/// arm the microphone before the hold threshold; a second quick press starts
/// hands-free mode immediately. A single tap produces no effect, except in
/// hands-free mode where one press ends the dictation.
public struct GestureEngine: Equatable, Sendable {
    public private(set) var config: GestureConfig
    private var phase: Phase

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
        self.phase = .idle
    }

    public var isToggleLatched: Bool {
        switch phase {
        case .startingToggle, .toggled: return true
        default: return false
        }
    }

    public var isPushing: Bool {
        if case .pushing = phase { return true }
        return false
    }

    /// Aucun geste en cours : ni appui en attente, ni maintien, ni mains libres.
    public var isIdle: Bool { phase == .idle }

    /// Premier appui encore en attente de son réveil, qui décide (maintien, simple appui, relâchement perdu).
    public var isPressPending: Bool {
        if case .firstDown = phase { return true }
        return false
    }

    /// Drops gesture state without emitting a stop. The caller already stopped.
    public mutating func forceIdle() {
        phase = .idle
    }

    /// La dictée de ce geste est finie (annulée, échouée, arrêtée par le menu ou la bulle) : le geste revient au
    /// repos. Un nouveau geste encore en attente (premier appui, intervalle) est laissé intact.
    public mutating func endSession() {
        switch phase {
        case .pushing, .startingToggle, .toggled, .stoppingToggle: phase = .idle
        case .idle, .firstDown, .gap: break
        }
    }

    /// Relâchement perdu (écoute du clavier coupée par macOS) : un maintien en cours s'arrête, mais un appui
    /// encore en attente est oublié sans rien démarrer — un appui simple ne doit jamais ouvrir le micro.
    public mutating func releaseLost(at time: Int) -> GestureStep {
        switch phase {
        case .pushing, .startingToggle, .stoppingToggle:
            return keyUp(at: time)
        case .firstDown:
            phase = .idle
            return GestureStep()
        case .idle, .gap, .toggled:
            return GestureStep()
        }
    }

    public mutating func noteExternalToggleStart() {
        phase = .toggled
    }

    public mutating func keyDown(at time: Int) -> GestureStep {
        switch phase {
        case .idle:
            phase = .firstDown(since: time)
            return wake(time + config.holdMilliseconds)
        case .gap(let releasedAt):
            if time - releasedAt <= config.doubleTapGapMilliseconds {
                // Le double appui est reconnu : ne pas attendre le deuxième relâchement.
                phase = .startingToggle
                return GestureStep(effects: [.startToggle])
            } else {
                phase = .firstDown(since: time)
            }
            return wake(time + config.holdMilliseconds)
        case .toggled:
            // Mains libres : un seul appui termine, dès l'enfoncement.
            phase = .stoppingToggle
            return GestureStep(effects: [.stopToggle])
        case .firstDown, .pushing, .startingToggle, .stoppingToggle:
            return GestureStep()
        }
    }

    public mutating func keyUp(at time: Int) -> GestureStep {
        switch phase {
        case .firstDown(let since):
            if time - since >= config.holdMilliseconds {
                phase = .idle
                return GestureStep(effects: [.startPushToTalk, .stopPushToTalk])
            }
            phase = .gap(releasedAt: time)
            return wake(time + config.doubleTapGapMilliseconds)
        case .pushing:
            phase = .idle
            return GestureStep(effects: [.stopPushToTalk])
        case .startingToggle:
            // Ce relâchement appartient au démarrage, même si le deuxième appui a été prolongé.
            phase = .toggled
            return GestureStep()
        case .stoppingToggle:
            // Le relâchement de l'appui d'arrêt ne commence pas un nouveau geste.
            phase = .idle
            return GestureStep()
        case .idle, .gap, .toggled:
            return GestureStep()
        }
    }

    /// `keyStillDown` : état physique de la touche au moment du réveil. Si elle est déjà relâchée alors que son
    /// relâchement n'a pas encore été traité, on n'ouvre pas le micro pour un simple appui : on attend ce
    /// relâchement (abandonné au bout d'une demi-seconde s'il s'est perdu).
    public mutating func tick(at time: Int, keyStillDown: Bool) -> GestureStep {
        guard !keyStillDown else { return tick(at: time) }
        switch phase {
        case .firstDown(let since):
            guard time - since >= config.holdMilliseconds else { return tick(at: time) }
            if time - since > config.holdMilliseconds + 500 {
                phase = .idle
                return GestureStep()
            }
            return wake(time + 30)
        default:
            return tick(at: time)
        }
    }

    public mutating func tick(at time: Int) -> GestureStep {
        switch phase {
        case .firstDown(let since) where time - since >= config.holdMilliseconds:
            phase = .pushing
            return GestureStep(effects: [.startPushToTalk])
        case .gap(let releasedAt) where time - releasedAt >= config.doubleTapGapMilliseconds:
            phase = .idle
            return GestureStep()
        // Réveil arrivé un peu tôt : reprogrammé, pour que le geste ne reste jamais en suspens.
        case .firstDown(let since):
            return wake(since + config.holdMilliseconds)
        case .gap(let releasedAt):
            return wake(releasedAt + config.doubleTapGapMilliseconds)
        default:
            return GestureStep()
        }
    }

    private func wake(_ time: Int) -> GestureStep {
        GestureStep(nextWakeMilliseconds: time)
    }

    private enum Phase: Equatable {
        case idle
        case firstDown(since: Int)
        case pushing
        case gap(releasedAt: Int)
        case startingToggle
        case toggled
        case stoppingToggle
    }
}
