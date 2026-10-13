import CoreGraphics
import Foundation

/// Ce que montre la bulle, pour sa place à l'écran : chaque rôle a sa position, réglable dans Réglages.
public enum OverlayRole: String, CaseIterable, Codable, Sendable {
    /// Écoute et traitement d'une dictée (spectre).
    case dictation
    /// Texte qui n'a pas pu être écrit : Copier / Coller.
    case alerts
    /// Messages brefs : relais, mots appris, « Collé », nouvelle version.
    case info
}

/// Position choisie : centre horizontal et bas de la bulle, en fractions de la zone utile de l'écran
/// (0 : gauche ou bas, 1 : droite ou haut). Toujours bornée, même lue d'un réglage abîmé.
public struct OverlayAnchor: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try container.decode(Double.self, forKey: .x), y: try container.decode(Double.self, forKey: .y))
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }
}

/// Réglages de placement de la bulle et de ses messages.
public struct OverlayPlacement: Codable, Equatable, Sendable {
    /// Les messages se décalent pour ne pas couvrir le champ où l'on écrit.
    public var avoidsInput = true
    /// Positions personnalisées, par rôle (`OverlayRole.rawValue`). Absente : au-dessus du Dock, au centre.
    public var anchors: [String: OverlayAnchor] = [:]

    public init() {}

    /// Lecture tolérante : une valeur illisible ou un rôle inconnu laissent les autres choix intacts.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        avoidsInput = (try? container.decode(Bool.self, forKey: .avoidsInput)) ?? true
        let raw = (try? container.decode([String: Lenient<OverlayAnchor>].self, forKey: .anchors)) ?? [:]
        anchors = raw.reduce(into: [:]) { result, item in
            if OverlayRole(rawValue: item.key) != nil, let anchor = item.value.value { result[item.key] = anchor }
        }
    }

    public func anchor(for role: OverlayRole) -> OverlayAnchor? { anchors[role.rawValue] }

    public mutating func setAnchor(_ anchor: OverlayAnchor?, for role: OverlayRole) {
        anchors[role.rawValue] = anchor
    }

    private struct Lenient<Wrapped: Decodable>: Decodable {
        let value: Wrapped?
        init(from decoder: Decoder) throws { value = try? Wrapped(from: decoder) }
    }
}

/// Géométrie de la bulle, en coordonnées écran de macOS (origine en bas à gauche).
public enum OverlayGeometry {
    /// Écart entre la bulle déplacée et le champ qu'elle évite.
    public static let inputGap: CGFloat = 12
    /// Marge gardée avec les bords de la zone utile de l'écran.
    public static let edgeGap: CGFloat = 10
    /// Au-delà, l'élément actif est un document ou une page entière : seule la ligne du curseur est évitée.
    public static let maxFieldHeight: CGFloat = 240

    /// Bas-centre de la bulle pour une position choisie, contenu entièrement dans la zone utile.
    public static func point(for anchor: OverlayAnchor, visible: CGRect, contentSize: CGSize) -> CGPoint {
        let half = contentSize.width / 2
        let minX = visible.minX + edgeGap + half, maxX = visible.maxX - edgeGap - half
        let minY = visible.minY + edgeGap, maxY = visible.maxY - edgeGap - contentSize.height
        let x = maxX > minX ? minX + (maxX - minX) * anchor.x : visible.midX
        let y = maxY > minY ? minY + (maxY - minY) * anchor.y : minY
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// Zone à ne pas couvrir, d'après ce que l'app expose : le champ s'il est de taille raisonnable, sinon la ligne
    /// du curseur. Champ invisible (apps Electron comme Codex) : le bas de la fenêtre, où les apps de discussion
    /// placent leur saisie. nil : rien de fiable, la bulle reste à sa place.
    public static func inputZone(field: CGRect?, caret: CGRect?, window: CGRect?) -> CGRect? {
        if let field, field.width > 1, field.height > 1, field.height <= maxFieldHeight { return field }
        if let caret, caret.height > 1, caret.height < 200 {
            let line = caret.insetBy(dx: 0, dy: -24)
            if let field, field.width > 1 {
                return CGRect(x: field.minX, y: line.minY, width: field.width, height: line.height)
            }
            return line.insetBy(dx: -180, dy: 0)
        }
        guard field == nil, let window, window.width > 1, window.height > 1 else { return nil }
        let height = min(200, max(90, window.height * 0.22))
        return CGRect(x: window.minX, y: window.minY, width: window.width, height: height)
    }

    /// Bas-centre de la bulle décalé pour ne pas couvrir la zone : juste au-dessus, sinon juste en dessous,
    /// sinon à sa place (zone trop haute pour être évitée).
    public static func avoiding(_ zone: CGRect, bottomCenter: CGPoint, contentSize: CGSize, visible: CGRect) -> CGPoint {
        let bubble = CGRect(x: bottomCenter.x - contentSize.width / 2, y: bottomCenter.y,
                            width: contentSize.width, height: contentSize.height)
        guard bubble.intersects(zone.insetBy(dx: -4, dy: -4)) else { return bottomCenter }
        let above = zone.maxY + inputGap
        if above + contentSize.height <= visible.maxY - edgeGap { return CGPoint(x: bottomCenter.x, y: above.rounded()) }
        let below = zone.minY - inputGap - contentSize.height
        if below >= visible.minY + edgeGap { return CGPoint(x: bottomCenter.x, y: below.rounded()) }
        return bottomCenter
    }

    /// Rectangle d'accessibilité (origine en haut à gauche de l'écran principal) en coordonnées macOS.
    public static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
