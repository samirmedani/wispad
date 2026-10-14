import AppKit
import Testing
@testable import WispadApp

/// Cadence du spectre de la bulle (`FrameTicker`) quand les écrans changent. Écrans simulés : seul l'écran principal
/// réel, s'il existe, sert à vérifier le lien d'affichage.
@MainActor
struct FrameTickerTests {
    @MainActor
    private final class TickerScreens {
        var screen: NSScreen?
        var present: [UInt32] = []
    }

    /// Spectre de la bulle : son lien d'affichage suit un écran. Écran débranché, il repart sur l'écran voulu, ou sur une
    /// minuterie sans écran ; l'écran revenu, il retrouve sa cadence. Le même écran réglé autrement garde son lien.
    @Test func theSpectrumFollowsAnUnpluggedScreen() {
        _ = NSApplication.shared
        let fake = TickerScreens()
        let ticker = FrameTicker { _ in }
        ticker.displays = { [fake] in fake.present }
        ticker.start { [fake] in fake.screen }
        defer { ticker.stop() }
        #expect(ticker.displayID == nil)
        ticker.screensDidChange()
        #expect(ticker.restarts == 0)
        fake.present = [7]
        ticker.screensDidChange()
        #expect(ticker.restarts == 1)
        if let main = NSScreen.main, let id = main.displayID {
            fake.screen = main
            fake.present = [id]
            ticker.screensDidChange()
            #expect(ticker.displayID == id && ticker.restarts == 2)
            ticker.screensDidChange()
            #expect(ticker.displayID == id && ticker.restarts == 2)
            fake.screen = nil
            fake.present = []
            ticker.screensDidChange()
            #expect(ticker.displayID == nil && ticker.restarts == 3)
        }
        let restarts = ticker.restarts
        ticker.stop()
        fake.present = [9]
        ticker.screensDidChange()
        #expect(ticker.restarts == restarts && ticker.displayID == nil)
    }
}
