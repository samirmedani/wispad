import AppKit
import SwiftUI
import Testing
@testable import WispadApp
@testable import WispadCore

/// Place de la bulle sur le vrai écran du Mac de test, sans afficher de fenêtre ni lire une vraie app.
@MainActor
@Suite(.serialized, .inputZoneExclusive)
struct OverlayPlacementAppTests {
    @MainActor
    private final class Box {
        let directory: URL
        let model: AppModel
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-placement-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dependencies = AppDependencies()
            dependencies.copyText = { _ in }
            dependencies.loadKey = { "fixture-" + $0 }
            dependencies.saveKey = { _, _ in true }
            dependencies.refreshKeys = { true }
            var settings = AppSettings()
            settings.onboardingCompleted = true
            model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
            model.overlay.displaysPanel = false
            model.overlay.install(model: model)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func eachModeHasItsPlace() {
        #expect(OverlayMode.listening.role == .dictation)
        #expect(OverlayMode.finishing.role == .dictation)
        #expect(OverlayMode.failure("x").role == .alerts)
        #expect(OverlayMode.notice("x").role == .info)
        #expect(OverlayMode.learning("x").role == .info)
        #expect(OverlayMode.update("x").role == .info)
    }

    @Test func aMessageOverTheInputMovesAboveItAndTheDictationBubbleStays() throws {
        let box = try Box()
        defer { InputZoneTracker.reset() }
        InputZoneTracker.reset()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, NSScreen.main != nil else { return }
        let overlay = box.model.overlay
        let notice = OverlayMode.notice("Collé")
        let base = try #require(overlay.targetFrame(for: notice))
        let pill = try #require(overlay.targetFrame(for: .listening))
        let bottom = base.minY + OverlayLayout.bottomMargin
        // Saisie juste là où la bulle s'affiche par défaut, comme le champ de Codex en bas de fenêtre.
        let zone = CGRect(x: base.midX - 300, y: bottom - 20, width: 600, height: 80)
        InputZoneTracker.note(zone, pid: pid)
        let moved = try #require(overlay.targetFrame(for: notice))
        #expect(moved.minY + OverlayLayout.bottomMargin == zone.maxY + OverlayGeometry.inputGap)
        #expect(overlay.targetFrame(for: .listening) == pill)
        // Réglage coupé : les messages restent à leur place.
        box.model.settings.overlayPlacement.avoidsInput = false
        #expect(overlay.targetFrame(for: notice) == base)
    }

    @Test func aChosenPlaceIsUsedAndStaysOnScreen() throws {
        let box = try Box()
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        box.model.settings.overlayPlacement.setAnchor(OverlayAnchor(x: 1, y: 1), for: .alerts)
        box.model.coordinator.failureText = "Phrase de test."
        defer { box.model.coordinator.failureText = nil }
        let frame = try #require(box.model.overlay.targetFrame(for: .failure("Le texte n'est pas arrivé dans le champ")))
        let visible = screen.visibleFrame
        let size = OverlayLayout.contentSize(for: .failure(""), hasReadyText: true)
        let bubble = CGRect(x: frame.midX - size.width / 2, y: frame.minY + OverlayLayout.bottomMargin, width: size.width, height: size.height)
        #expect(visible.insetBy(dx: -1, dy: -1).contains(bubble))
        #expect(bubble.maxX > visible.midX && bubble.maxY > visible.midY)
    }

    @Test func theLayoutEditorRenders() throws {
        let box = try Box()
        for (name, custom) in [("editeur-par-defaut", false), ("editeur-personnalise", true)] {
            box.model.settings.overlayPlacement.anchors = [:]
            if custom {
                box.model.settings.overlayPlacement.setAnchor(OverlayAnchor(x: 0.85, y: 0.82), for: .alerts)
                box.model.settings.overlayPlacement.setAnchor(OverlayAnchor(x: 0.5, y: 0.92), for: .info)
            }
            let content = VStack { OverlayLayoutEditor() }
                .padding(16)
                .frame(width: 620)
                .background(Color(white: 0.13))
                .environment(box.model)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width >= 1_200)
            if let folder = ProcessInfo.processInfo.environment["WISPAD_OVERLAY_SNAPSHOTS"],
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
            }
        }
    }
}
