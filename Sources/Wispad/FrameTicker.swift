import AppKit
import QuartzCore

/// Appelle `tick` à chaque image de l'écran : 120 Hz sur un écran ProMotion, 60 Hz ailleurs.
@MainActor
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var fallback: Timer?
    private var lastTimestamp: CFTimeInterval?
    private let tick: @MainActor (Double) -> Void

    init(tick: @escaping @MainActor (Double) -> Void) {
        self.tick = tick
    }

    func start(on screen: NSScreen?) {
        stop()
        guard let screen else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(1.0 / 60) }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallback = timer
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        let maximum = Float(max(60, screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        fallback?.invalidate()
        fallback = nil
        lastTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = lastTimestamp.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = link.timestamp
        tick(max(0, elapsed))
    }
}
