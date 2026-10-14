import AppKit
import QuartzCore

/// Appelle `tick` à chaque image de l'écran : 120 Hz sur un écran ProMotion, 60 Hz ailleurs.
/// Le lien d'affichage d'un écran ne suit que cet écran : débranché, il ne bat plus. Quand les écrans changent, un lien
/// sur un écran disparu est refait sur l'écran voulu, ou remplacé par une minuterie à 60 Hz s'il n'y a plus d'écran.
@MainActor
final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var fallback: Timer?
    private var lastTimestamp: CFTimeInterval?
    private let tick: @MainActor (Double) -> Void
    /// Écran voulu, relu quand les écrans changent.
    private var screen: (@MainActor () -> NSScreen?)?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    /// Écran dont le lien suit les images ; nil : minuterie de repli, ou arrêté.
    private(set) var displayID: UInt32?
    /// Relances après un changement d'écran.
    private(set) var restarts = 0
    /// Numéros des écrans branchés, lus de macOS ; remplaçable dans les tests.
    var displays: @MainActor () -> [UInt32] = { NSScreen.screens.compactMap { $0.displayID } }

    init(tick: @escaping @MainActor (Double) -> Void) {
        self.tick = tick
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Démarre sur l'écran que rend `screen` (minuterie à 60 Hz sans écran) ; il est relu quand les écrans changent.
    func start(on screen: @escaping @MainActor () -> NSScreen?) {
        stop()
        self.screen = screen
        attach(to: screen())
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
    }

    /// Écran du lien débranché : le lien est refait sur l'écran voulu. Minuterie de repli : un écran est revenu.
    /// Le même écran réglé autrement (résolution, échelle, autre écran principal) garde son lien.
    func screensDidChange() {
        guard let screen, link != nil || fallback != nil else { return }
        let present = displays()
        let stale = link != nil ? !(displayID.map { present.contains($0) } ?? false) : !present.isEmpty
        guard stale else { return }
        restarts += 1
        detach()
        attach(to: screen())
    }

    func stop() {
        detach()
        screen = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func attach(to screen: NSScreen?) {
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
        displayID = screen.displayID
    }

    private func detach() {
        link?.invalidate()
        link = nil
        fallback?.invalidate()
        fallback = nil
        lastTimestamp = nil
        displayID = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = lastTimestamp.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = link.timestamp
        tick(max(0, elapsed))
    }
}
