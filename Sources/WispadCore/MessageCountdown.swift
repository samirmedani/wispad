import Foundation

/// Décompte d'un message de la bulle, mis en pause pendant que le pointeur la survole.
/// Le temps écoulé en pause ne compte pas : à la reprise, il reste ce qui restait à l'arrêt.
public struct MessageCountdown: Equatable, Sendable {
    public let duration: Double
    /// Temps restant au dernier départ ou à la dernière pause.
    public private(set) var remainingAtMark: Double
    /// Instant du dernier départ ; nil en pause.
    public private(set) var runningSince: Date?

    public init(duration: Double, start: Date, paused: Bool = false) {
        self.duration = max(0, duration)
        remainingAtMark = self.duration
        runningSince = paused ? nil : start
    }

    public var isPaused: Bool { runningSince == nil }

    /// Secondes restantes à cet instant, jamais négatives.
    public func remaining(at date: Date) -> Double {
        guard let runningSince else { return remainingAtMark }
        return max(0, remainingAtMark - max(0, date.timeIntervalSince(runningSince)))
    }

    /// Part restante, de 1 (départ) à 0 (fin) : longueur de la barre.
    public func fraction(at date: Date) -> Double {
        duration > 0 ? remaining(at: date) / duration : 0
    }

    public mutating func pause(at date: Date) {
        guard !isPaused else { return }
        remainingAtMark = remaining(at: date)
        runningSince = nil
    }

    public mutating func resume(at date: Date) {
        guard isPaused else { return }
        runningSince = date
    }
}
