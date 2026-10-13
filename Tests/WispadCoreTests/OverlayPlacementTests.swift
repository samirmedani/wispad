import CoreGraphics
import Foundation
import Testing
@testable import WispadCore

struct OverlayPlacementTests {
    private let visible = CGRect(x: 0, y: 80, width: 1512, height: 870)

    @Test func settingsAreReadLeniently() throws {
        let decoded = try JSONDecoder().decode(OverlayPlacement.self, from: Data(#"""
        {"avoidsInput": false, "anchors": {"alerts": {"x": 1.4, "y": -2}, "inconnu": {"x": 0.1, "y": 0.1}, "info": "abîmé"}}
        """#.utf8))
        #expect(decoded.avoidsInput == false)
        #expect(decoded.anchor(for: .alerts) == OverlayAnchor(x: 1, y: 0))
        #expect(decoded.anchor(for: .info) == nil)
        #expect(decoded.anchors.count == 1)
        let empty = try JSONDecoder().decode(OverlayPlacement.self, from: Data("{}".utf8))
        #expect(empty == OverlayPlacement())
        #expect(empty.avoidsInput)
    }

    @Test func anchorsKeepTheWholeBubbleOnScreen() {
        let size = CGSize(width: 420, height: 122)
        let low = OverlayGeometry.point(for: OverlayAnchor(x: 0, y: 0), visible: visible, contentSize: size)
        #expect(low == CGPoint(x: 220, y: 90))
        let high = OverlayGeometry.point(for: OverlayAnchor(x: 1, y: 1), visible: visible, contentSize: size)
        #expect(high.x + size.width / 2 <= visible.maxX - OverlayGeometry.edgeGap)
        #expect(high.y + size.height <= visible.maxY - OverlayGeometry.edgeGap)
    }

    @Test func aKnownFieldIsAvoidedFromAbove() {
        // Saisie en bas de fenêtre, juste là où la bulle s'affiche par défaut.
        let field = CGRect(x: 456, y: 96, width: 600, height: 90)
        let zone = OverlayGeometry.inputZone(field: field, caret: nil, window: nil)
        #expect(zone == field)
        let moved = OverlayGeometry.avoiding(field, bottomCenter: CGPoint(x: 756, y: 86), contentSize: CGSize(width: 420, height: 122), visible: visible)
        #expect(moved == CGPoint(x: 756, y: field.maxY + OverlayGeometry.inputGap))
    }

    @Test func aBubbleAwayFromTheFieldDoesNotMove() {
        let field = CGRect(x: 456, y: 600, width: 600, height: 60)
        let start = CGPoint(x: 756, y: 86)
        #expect(OverlayGeometry.avoiding(field, bottomCenter: start, contentSize: CGSize(width: 420, height: 122), visible: visible) == start)
    }

    @Test func aFieldAtTheTopSendsTheBubbleBelowIt() {
        let field = CGRect(x: 456, y: 860, width: 600, height: 60)
        let start = CGPoint(x: 756, y: 850)
        let moved = OverlayGeometry.avoiding(field, bottomCenter: start, contentSize: CGSize(width: 470, height: 30), visible: visible)
        #expect(moved.y + 30 <= field.minY)
    }

    @Test func aDocumentOnlyProtectsTheCursorLine() {
        let document = CGRect(x: 200, y: 100, width: 900, height: 700)
        let caret = CGRect(x: 400, y: 300, width: 2, height: 18)
        let zone = OverlayGeometry.inputZone(field: document, caret: caret, window: nil)
        #expect(zone?.minX == document.minX && zone?.width == document.width)
        #expect(zone?.minY == caret.minY - 24 && zone?.height == caret.height + 48)
        #expect(OverlayGeometry.inputZone(field: document, caret: nil, window: CGRect(x: 0, y: 0, width: 1512, height: 950)) == nil)
    }

    /// Codex et les apps Electron ne montrent pas leur champ : le bas de la fenêtre est réservé.
    @Test func anHiddenFieldReservesTheBottomOfTheWindow() throws {
        let window = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let zone = try #require(OverlayGeometry.inputZone(field: nil, caret: nil, window: window))
        #expect(zone.minY == 0 && zone.height == 200 && zone.width == window.width)
        #expect(OverlayGeometry.inputZone(field: nil, caret: nil, window: nil) == nil)
    }

    @Test func accessibilityRectanglesAreFlipped() {
        let flipped = OverlayGeometry.flipped(CGRect(x: 0, y: 33, width: 1512, height: 949), primaryHeight: 982)
        #expect(flipped == CGRect(x: 0, y: 0, width: 1512, height: 949))
    }
}
