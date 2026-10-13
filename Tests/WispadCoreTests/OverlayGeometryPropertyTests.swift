import CoreGraphics
import Foundation
import Testing
@testable import WispadCore

/// Filet anti-régression de la place de la bulle : réglages (`OverlayPlacement`, `OverlayAnchor`) et géométrie
/// (`OverlayGeometry`), sur des écrans, des bulles et des champs tirés au hasard.
struct OverlayGeometryPropertyTests {
    static func rect(_ g: inout SeededGenerator, x: ClosedRange<Int>, y: ClosedRange<Int>, width: ClosedRange<Int>, height: ClosedRange<Int>) -> CGRect {
        CGRect(x: CGFloat(g.int(x)), y: CGFloat(g.int(y)), width: CGFloat(g.int(width)), height: CGFloat(g.int(height)))
    }

    /// Zone utile d'un écran (Dock et barre des menus retirés), parfois à gauche ou sous l'écran principal.
    static func screen(_ g: inout SeededGenerator) -> CGRect {
        rect(&g, x: -3_000...3_000, y: -1_500...1_500, width: 0...3_500, height: 0...2_200)
    }

    static func bubble(_ g: inout SeededGenerator) -> CGSize {
        CGSize(width: CGFloat(g.int(1...900)), height: CGFloat(g.int(1...320)))
    }

    static func anchor(_ g: inout SeededGenerator) -> OverlayAnchor {
        let special: [Double] = [.nan, .infinity, -.infinity, -0.0, 0, 1, -1e300, 1e300, .leastNonzeroMagnitude]
        return OverlayAnchor(x: g.chance(15) ? g.pick(special) : g.double(-1...2), y: g.chance(15) ? g.pick(special) : g.double(-1...2))
    }

    static func frame(of bottomCenter: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: bottomCenter.x - size.width / 2, y: bottomCenter.y, width: size.width, height: size.height)
    }

    // MARK: Réglages

    /// Une position reste dans l'écran, même lue d'un réglage abîmé (NaN, infini, hors de 0…1).
    @Test func anchorsAreAlwaysClamped() {
        forAll(5_000, seed: 0x4F56_4C31, { g in Self.anchor(&g) }) { anchor in
            (0...1).contains(anchor.x) && (0...1).contains(anchor.y) ? nil : "\(anchor)"
        }
    }

    /// Enregistrer puis relire les réglages de la bulle redonne les mêmes choix.
    @Test func placementRoundTripsThroughJSON() {
        forAll(500, seed: 0x4F56_4C32, { g -> OverlayPlacement in
            var placement = OverlayPlacement()
            placement.avoidsInput = g.chance(50)
            for role in OverlayRole.allCases where g.chance(60) {
                placement.setAnchor(OverlayAnchor(x: g.double(0...1), y: g.double(0...1)), for: role)
            }
            return placement
        }) { placement in
            let decoded = (try? JSONEncoder().encode(placement)).flatMap { try? JSONDecoder().decode(OverlayPlacement.self, from: $0) }
            return decoded == placement ? nil : "\(placement) relu \(String(describing: decoded))"
        }
    }

    /// Lecture tolérante : une valeur abîmée ou un rôle inconnu ne font jamais échouer la lecture des autres choix.
    @Test func damagedSettingsAreReadLeniently() {
        let values = [#"{"x": 0.2, "y": 0.8}"#, #"{"x": "a", "y": 1}"#, "null", "3", "[]", #"{"y": 0.5}"#, #"{"x": -5, "y": 9}"#]
        forAll(500, seed: 0x4F56_4C33, { g -> String in
            let roles = (OverlayRole.allCases.map(\.rawValue) + ["inconnu", "", "INFO"]).filter { _ in g.chance(50) }
            let anchors = roles.map { "\"\($0)\": \(g.pick(values))" }.joined(separator: ", ")
            let avoids = g.pick(["true", "false", "\"oui\"", "null", "1"])
            return g.chance(10) ? #"{"anchors": 3}"# : #"{"avoidsInput": \#(avoids), "anchors": {\#(anchors)}}"#
        }) { json in
            guard let decoded = try? JSONDecoder().decode(OverlayPlacement.self, from: Data(json.utf8)) else { return "\(json) illisible" }
            guard decoded.anchors.keys.allSatisfy({ OverlayRole(rawValue: $0) != nil }) else { return "\(json) : rôle inconnu gardé" }
            return decoded.anchors.values.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) } ? nil : "\(json) : position hors de l'écran"
        }
    }

    // MARK: Géométrie

    /// La bulle placée tient entière dans la zone utile, à 10 points des bords (à l'arrondi près), dès qu'elle y
    /// tient ; plus l'ancre va à droite ou en haut, plus la bulle aussi.
    @Test func placedBubbleStaysOnScreen() {
        forAll(5_000, seed: 0x4F56_4C34, { g in (screen: Self.screen(&g), size: Self.bubble(&g), anchor: Self.anchor(&g), other: Self.anchor(&g)) }) { sample in
            let point = OverlayGeometry.point(for: sample.anchor, visible: sample.screen, contentSize: sample.size)
            guard point.x.isFinite, point.y.isFinite else { return "point \(point)" }
            let gap = OverlayGeometry.edgeGap
            let fits = sample.size.width + 2 * gap <= sample.screen.width && sample.size.height + 2 * gap <= sample.screen.height
            if fits, !sample.screen.insetBy(dx: gap - 0.5, dy: gap - 0.5).contains(Self.frame(of: point, size: sample.size)) {
                return "\(Self.frame(of: point, size: sample.size)) hors de \(sample.screen)"
            }
            let other = OverlayGeometry.point(for: sample.other, visible: sample.screen, contentSize: sample.size)
            if sample.anchor.x < sample.other.x, point.x > other.x { return "x non monotone" }
            if sample.anchor.y < sample.other.y, point.y > other.y { return "y non monotone" }
            return nil
        }
    }

    /// Éviter le champ : la bulle déplacée ne le couvre plus, garde son x, reste à l'écran ; l'éviter une seconde fois
    /// ne la bouge plus.
    @Test func avoidingTheInputZoneIsSettled() {
        forAll(5_000, seed: 0x4F56_4C35, { g in
            (screen: Self.screen(&g), size: Self.bubble(&g), anchor: Self.anchor(&g),
             zone: Self.rect(&g, x: -3_000...3_000, y: -1_500...2_500, width: 0...2_000, height: 0...400))
        }) { sample in
            let start = OverlayGeometry.point(for: sample.anchor, visible: sample.screen, contentSize: sample.size)
            let moved = OverlayGeometry.avoiding(sample.zone, bottomCenter: start, contentSize: sample.size, visible: sample.screen)
            let again = OverlayGeometry.avoiding(sample.zone, bottomCenter: moved, contentSize: sample.size, visible: sample.screen)
            guard again == moved else { return "\(start) → \(moved) → \(again)" }
            guard moved != start else { return nil }
            let frame = Self.frame(of: moved, size: sample.size)
            if frame.intersects(sample.zone.insetBy(dx: -4, dy: -4)) { return "\(frame) couvre \(sample.zone)" }
            if moved.x != start.x { return "x changé : \(start) → \(moved)" }
            let gap = OverlayGeometry.edgeGap
            if frame.minY < sample.screen.minY + gap - 0.5 || frame.maxY > sample.screen.maxY - gap + 0.5 { return "\(frame) hors de \(sample.screen)" }
            return nil
        }
    }

    /// Zone à éviter : rien, ou un rectangle non vide de 248 points de haut au plus (champ, ligne du curseur ou bas de
    /// fenêtre) ; un champ de taille raisonnable est rendu tel quel.
    @Test func inputZoneIsBounded() {
        forAll(5_000, seed: 0x4F56_4C36, { g -> (field: CGRect?, caret: CGRect?, window: CGRect?) in
            let field: CGRect? = g.chance(70) ? Self.rect(&g, x: -500...2_000, y: -500...1_500, width: 0...2_000, height: 0...1_200) : nil
            let caret: CGRect? = g.chance(50) ? Self.rect(&g, x: -500...2_000, y: -500...1_500, width: 0...4, height: 0...260) : nil
            let window: CGRect? = g.chance(50) ? Self.rect(&g, x: -2_000...2_000, y: -1_000...1_000, width: 0...3_000, height: 0...2_200) : nil
            return (field, caret, window)
        }) { sample in
            guard let zone = OverlayGeometry.inputZone(field: sample.field, caret: sample.caret, window: sample.window) else { return nil }
            if zone.width <= 0 || zone.height <= 0 || zone.height > 248 { return "\(zone) pour \(sample)" }
            if let field = sample.field, field.width > 1, field.height > 1, field.height <= OverlayGeometry.maxFieldHeight, zone != field {
                return "\(field) devenu \(zone)"
            }
            return nil
        }
        #expect(OverlayGeometry.inputZone(field: .null, caret: .null, window: .null) == nil)
        #expect(OverlayGeometry.inputZone(field: nil, caret: nil, window: .zero) == nil)
    }

    /// Passer du repère de l'accessibilité à celui de macOS, puis revenir, redonne le rectangle de départ.
    @Test func flippingTwiceIsTheIdentity() {
        forAll(5_000, seed: 0x4F56_4C37, { g in
            (rect: Self.rect(&g, x: -5_000...5_000, y: -5_000...5_000, width: 0...5_000, height: 0...5_000), height: CGFloat(g.int(0...5_000)))
        }) { sample in
            let back = OverlayGeometry.flipped(OverlayGeometry.flipped(sample.rect, primaryHeight: sample.height), primaryHeight: sample.height)
            return back == sample.rect ? nil : "\(sample.rect) → \(back)"
        }
    }
}
