import AppKit
import Testing
@testable import WispadApp
@testable import WispadCore

/// La bulle quand les écrans changent pendant qu'elle est affichée : écrans simulés, loin des vrais. Le panneau est mis à
/// l'écran comme pendant une dictée, mais son contenu est masqué et il reste hors de tout écran réel ; il ne prend jamais
/// le focus.
@MainActor
@Suite(.serialized)
struct OverlayScreenAppTests {
    /// Écrans, pointeur et écran principal simulés, relus par la bulle à chaque placement.
    @MainActor
    final class Displays {
        var screens: [OverlayScreen]
        var pointer: CGPoint
        var main: UInt32? = 1

        init(screens: [OverlayScreen], pointer: CGPoint) {
            self.screens = screens
            self.pointer = pointer
        }
    }

    @MainActor
    private final class Box {
        let directory: URL
        let model: AppModel
        let panel: NSPanel

        init(_ displays: Displays) throws {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-screens-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dependencies = AppDependencies()
            dependencies.copyText = { _ in }
            dependencies.loadKey = { "fixture-" + $0 }
            dependencies.saveKey = { _, _ in true }
            dependencies.refreshKeys = { true }
            var settings = AppSettings()
            settings.onboardingCompleted = true
            let model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
            let overlay = model.overlay
            overlay.displaysPanel = true
            overlay.isOnActiveSpace = { _ in true }
            overlay.screens = { [displays] in displays.screens }
            overlay.pointer = { [displays] in displays.pointer }
            overlay.mainScreen = { [displays] in displays.main }
            overlay.install(model: model)
            let panel = try #require(overlay.panel)
            // Rien à voir : panneau transparent, sans ombre, hors des vrais écrans.
            panel.contentView?.isHidden = true
            self.model = model
            self.panel = panel
        }

        /// Bulle d'une dictée en maintien, affichée comme le fait le coordinateur.
        func listen() {
            model.coordinator.phase = .listening(.pushToTalk)
            model.overlay.show()
        }

        func dispose() {
            model.coordinator.phase = .idle
            model.overlay.hide()
            panel.orderOut(nil)
            try? FileManager.default.removeItem(at: directory)
        }

        /// La bulle de dictée dans son panneau, en coordonnées écran.
        var bubble: CGRect {
            OverlayGeometry.bubble(bottomCenter: OverlayLayout.bottomCenter(of: panel.frame),
                                   contentSize: OverlayLayout.contentSize(for: .listening, hasReadyText: false))
        }
    }

    /// Écrans simulés, loin des vrais : MacBook (barre des menus de 33 points, Dock de 72) et écran externe.
    static let origin = CGPoint(x: -40_000, y: -40_000)

    static func screen(_ id: UInt32, x: CGFloat, width: CGFloat, height: CGFloat, menuBar: CGFloat, dock: CGFloat = 0) throws -> OverlayScreen {
        let frame = CGRect(x: origin.x + x, y: origin.y, width: width, height: height)
        let visible = CGRect(x: frame.minX, y: frame.minY + dock, width: width, height: height - dock - menuBar)
        return try #require(OverlayScreen(id: id, frame: frame, visible: visible))
    }

    static func builtIn(x: CGFloat = 0) throws -> OverlayScreen {
        try screen(1, x: x, width: 1512, height: 982, menuBar: 33, dock: 72)
    }

    static func external(x: CGFloat = 1512) throws -> OverlayScreen {
        try screen(2, x: x, width: 1920, height: 1080, menuBar: 25)
    }

    static func center(of screen: OverlayScreen) -> CGPoint {
        CGPoint(x: screen.frame.midX, y: screen.frame.midY)
    }

    /// Écran externe débranché pendant une dictée : la bulle passe, entière, sur le MacBook, et y reste quand l'écran
    /// revient pendant la même dictée. La dictée suivante, pointeur sur l'écran revenu, retrouve sa place choisie.
    @Test func anUnpluggedScreenIsLeftAndTheChosenPlaceComesBackWithIt() throws {
        let builtIn = try Self.builtIn(), external = try Self.external()
        let displays = Displays(screens: [builtIn, external], pointer: Self.center(of: external))
        let box = try Box(displays)
        defer { box.dispose() }
        box.model.settings.overlayPlacement.setAnchor(OverlayAnchor(x: 0.8, y: 0.6), for: .dictation)
        let placement = box.model.settings.overlayPlacement
        let overlay = box.model.overlay
        box.listen()
        #expect(box.panel.isVisible && !box.panel.isKeyWindow)
        let first = box.panel.frame
        #expect(external.frame.contains(box.bubble))

        displays.screens = [builtIn]
        overlay.screensDidChange()
        #expect(builtIn.frame.contains(box.bubble))
        #expect(box.panel.isVisible && !box.panel.isKeyWindow)

        displays.screens = [builtIn, external]
        overlay.screensDidChange()
        #expect(builtIn.frame.contains(box.bubble))

        box.model.coordinator.phase = .idle
        overlay.hide()
        box.panel.orderOut(nil)
        box.listen()
        #expect(box.panel.frame == first)
        #expect(box.model.settings.overlayPlacement == placement)
    }

    /// L'écran externe devient l'écran principal : toutes les coordonnées changent, l'ancienne position de la bulle ne
    /// tombe plus sur lui et la fenêtre active est sur le MacBook. La bulle reste sur son écran, à la même place.
    @Test func aNewMainScreenLeavesTheBubbleOnItsScreen() throws {
        let builtIn = try Self.builtIn(), external = try Self.external()
        let displays = Displays(screens: [builtIn, external], pointer: Self.center(of: external))
        let box = try Box(displays)
        defer { box.dispose() }
        box.listen()
        let offset = CGPoint(x: box.panel.frame.minX - external.frame.minX, y: box.panel.frame.minY - external.frame.minY)
        let externalMain = try Self.external(x: 0), builtInLeft = try Self.builtIn(x: -1512)
        displays.screens = [externalMain, builtInLeft]
        displays.main = 1
        box.model.overlay.screensDidChange()
        #expect(box.panel.frame.minX - externalMain.frame.minX == offset.x)
        #expect(box.panel.frame.minY - externalMain.frame.minY == offset.y)
        #expect(externalMain.frame.contains(box.bubble))
    }

    /// Autre résolution du MacBook pendant la dictée : la bulle reprend sa place par défaut, au centre au-dessus du Dock.
    @Test func aResolutionChangeRecentersTheBubble() throws {
        let builtIn = try Self.builtIn()
        let displays = Displays(screens: [builtIn], pointer: Self.center(of: builtIn))
        let box = try Box(displays)
        defer { box.dispose() }
        box.listen()
        #expect(box.panel.frame.midX == builtIn.visible.midX)
        let larger = try Self.screen(1, x: 0, width: 1800, height: 1169, menuBar: 33, dock: 72)
        displays.screens = [larger]
        box.model.overlay.screensDidChange()
        #expect(box.panel.frame.midX == larger.visible.midX)
        #expect(larger.frame.contains(box.bubble))
    }

    /// La zone de saisie est oubliée quand les écrans changent (elle est en coordonnées d'avant), pas quand seuls le Dock
    /// ou la barre des menus changent (les fenêtres n'ont pas bougé).
    @Test func theInputZoneIsForgottenOnlyWhenScreensChange() throws {
        InputZoneTracker.reset()
        defer { InputZoneTracker.reset() }
        let builtIn = try Self.builtIn(), external = try Self.external()
        let displays = Displays(screens: [builtIn, external], pointer: Self.center(of: builtIn))
        let box = try Box(displays)
        defer { box.dispose() }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let zone = CGRect(x: builtIn.frame.minX + 456, y: builtIn.frame.minY + 96, width: 600, height: 90)
        InputZoneTracker.note(zone, pid: pid)
        displays.screens = [try Self.screen(1, x: 0, width: 1512, height: 982, menuBar: 0), external]
        box.model.overlay.screensDidChange()
        #expect(InputZoneTracker.zone(frontmost: pid) == zone)
        displays.screens = [try Self.screen(1, x: 0, width: 1800, height: 1169, menuBar: 33, dock: 72), try Self.external(x: 1800)]
        box.model.overlay.screensDidChange()
        #expect(InputZoneTracker.zone(frontmost: pid) == nil)
    }

    /// Écran débranché sans que la bulle en soit avertie : la surveillance de 250 ms juge la bulle, pas son panneau
    /// transparent, qui touche encore le MacBook quand la bulle est réglée tout à gauche de l'écran externe.
    @Test func aBubbleLeftOnAVanishedScreenIsBroughtBack() async throws {
        let builtIn = try Self.builtIn(), external = try Self.external()
        let displays = Displays(screens: [builtIn, external], pointer: Self.center(of: external))
        let box = try Box(displays)
        defer { box.dispose() }
        box.model.settings.overlayPlacement.setAnchor(OverlayAnchor(x: 0, y: 0), for: .dictation)
        box.listen()
        #expect(external.frame.contains(box.bubble))
        #expect(box.panel.frame.intersects(builtIn.frame))
        let recoveries = box.model.overlay.diagnosticState.recoveries
        displays.screens = [builtIn]
        let deadline = Date().addingTimeInterval(1)
        while !builtIn.frame.contains(box.bubble), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(builtIn.frame.contains(box.bubble))
        #expect(box.model.overlay.diagnosticState.recoveries == recoveries + 1)
        #expect(box.panel.isVisible && !box.panel.isKeyWindow)
    }

    /// Sans aucun écran : pas de place à viser, rien ne plante, et la surveillance ne relance rien en boucle. L'écran
    /// revenu, la bulle y reprend sa place.
    @Test func withoutAnyScreenTheBubbleWaitsQuietly() async throws {
        let builtIn = try Self.builtIn()
        let displays = Displays(screens: [builtIn], pointer: Self.center(of: builtIn))
        let box = try Box(displays)
        defer { box.dispose() }
        box.listen()
        let frame = box.panel.frame
        displays.screens = []
        box.model.overlay.screensDidChange()
        #expect(box.model.overlay.targetFrame(for: .listening) == nil)
        #expect(box.model.overlay.targetFrame(for: .notice("Collé")) == nil)
        let recoveries = box.model.overlay.diagnosticState.recoveries
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(box.model.overlay.diagnosticState.recoveries == recoveries)
        #expect(box.panel.frame == frame && box.panel.isVisible)
        displays.screens = [builtIn]
        box.model.overlay.screensDidChange()
        #expect(builtIn.frame.contains(box.bubble))
    }

    /// La notification de macOS est suivie : la bulle relit ses écrans.
    @Test func theScreenNotificationIsFollowed() async throws {
        let builtIn = try Self.builtIn(), external = try Self.external()
        let displays = Displays(screens: [builtIn, external], pointer: Self.center(of: external))
        let box = try Box(displays)
        defer { box.dispose() }
        #expect(box.model.overlay.knownScreens == [builtIn, external])
        displays.screens = [builtIn]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApplication.shared)
        let deadline = Date().addingTimeInterval(1)
        while box.model.overlay.knownScreens != [builtIn], Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(box.model.overlay.knownScreens == [builtIn])
    }
}
