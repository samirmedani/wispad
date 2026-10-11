import Foundation
import WispadCore

/// Minuterie d'un message de la bulle : il part seul après sa durée, sauf pendant que le pointeur le survole.
/// La barre de la bulle lit le même décompte : elle s'arrête et repart avec la minuterie.
@MainActor
@Observable
final class MessageTimer {
    /// Décompte du message affiché ; nil sans message.
    private(set) var countdown: MessageCountdown?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var onExpire: (() -> Void)?

    /// Remplace le décompte en cours. `paused` : le pointeur est déjà sur la bulle.
    func start(seconds: Double, paused: Bool, onExpire: @escaping () -> Void) {
        cancel()
        self.onExpire = onExpire
        countdown = MessageCountdown(duration: seconds, start: Date(), paused: paused)
        schedule()
    }

    func cancel() {
        expiry?.cancel()
        expiry = nil
        onExpire = nil
        if countdown != nil { countdown = nil }
    }

    func setPaused(_ paused: Bool) {
        guard var countdown, countdown.isPaused != paused else { return }
        if paused { countdown.pause(at: Date()) } else { countdown.resume(at: Date()) }
        self.countdown = countdown
        schedule()
    }

    private func schedule() {
        expiry?.cancel()
        expiry = nil
        guard let countdown, !countdown.isPaused else { return }
        let seconds = countdown.remaining(at: Date())
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let action = self.onExpire
            self.expiry = nil
            self.onExpire = nil
            self.countdown = nil
            action?()
        }
    }
}
