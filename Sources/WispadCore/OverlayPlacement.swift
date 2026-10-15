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

/// Un écran tel que la bulle le voit, en coordonnées macOS : numéro d'écran de macOS (il ne change pas quand l'écran
/// change de place, de résolution ou devient l'écran principal), cadre entier et zone utile (sans Dock ni barre des
/// menus). Rien n'est supposé de ces rectangles : un cadre vide, infini, NaN ou démesuré n'est pas un écran, et une zone
/// utile illisible ou débordant du cadre est ramenée au cadre.
public struct OverlayScreen: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let visible: CGRect

    public init?(id: UInt32, frame: CGRect, visible: CGRect) {
        guard let frame = OverlayGeometry.bounded(frame, minimumSide: 1) else { return nil }
        self.id = id
        self.frame = frame
        self.visible = OverlayGeometry.bounded(visible, minimumSide: 1).flatMap { OverlayGeometry.clipped($0, to: frame) } ?? frame
    }

    /// Mêmes écrans, aux mêmes places et dimensions ? Une zone utile qui change (Dock, barre des menus) n'en fait pas
    /// d'autres écrans : les fenêtres des apps n'ont pas bougé.
    public static func sameDisplays(_ a: [OverlayScreen], _ b: [OverlayScreen]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.id == $1.id && $0.frame == $1.frame }
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
    /// Place par défaut : écart avec le haut du Dock affiché…
    public static let dockGap: CGFloat = 6
    /// … sinon avec le bas de l'écran (Dock masqué, sur le côté, ou caché par une app en plein écran).
    public static let screenGap: CGFloat = 10
    /// Aucun écran réel ne va au-delà (en points, depuis l'origine de l'écran principal) : un rectangle qui dépasse est
    /// ignoré plutôt que d'envoyer la bulle à des coordonnées démesurées.
    public static let coordinateLimit: CGFloat = 1_000_000

    /// Bas de la bulle à sa place par défaut : juste au-dessus du Dock affiché, sinon près du bord bas de l'écran.
    public static func defaultBottom(screen: CGRect, visible: CGRect, dockShown: Bool) -> CGFloat {
        dockShown && visible.minY > screen.minY + 0.5 ? visible.minY + dockGap : screen.minY + screenGap
    }

    /// Écran de la bulle : celui de la zone de saisie à éviter, sinon celui où elle est déjà affichée (retrouvé par son
    /// numéro, puis par sa place : pas de saut d'écran en cours de dictée), sinon celui du pointeur, sinon l'écran
    /// principal, sinon le premier. Toujours un écran de la liste, jamais un écran débranché ; nil s'il n'y en a aucun.
    public static func screen(among screens: [OverlayScreen], zone: CGRect?, shownOn: UInt32?, shownAt: CGPoint?,
                              pointer: CGPoint?, main: UInt32?) -> OverlayScreen? {
        func containing(_ point: CGPoint?) -> OverlayScreen? {
            guard let point else { return nil }
            return screens.first { contains($0.frame, point) }
        }
        func numbered(_ id: UInt32?) -> OverlayScreen? {
            guard let id else { return nil }
            return screens.first { $0.id == id }
        }
        let zoneCenter = zone.flatMap { bounded($0, minimumSide: 0) }.map { CGPoint(x: $0.midX, y: $0.midY) }
        return containing(zoneCenter) ?? numbered(shownOn) ?? containing(shownAt) ?? containing(pointer)
            ?? numbered(main) ?? screens.first
    }

    /// Bas-centre de la bulle sur cet écran : la position choisie, en fractions de sa zone utile, sinon au-dessus du
    /// Dock (ou près du bord bas), au centre ; puis hors de la zone de saisie, si elle est lisible. Toujours un point
    /// fini, et la bulle entière sur l'écran dès qu'elle tient dans sa zone utile.
    public static func bottomCenter(on screen: OverlayScreen, anchor: OverlayAnchor?, contentSize: CGSize,
                                    dockShown: @autoclosure () -> Bool, zone: CGRect?) -> CGPoint {
        var bottomCenter: CGPoint
        if let anchor {
            bottomCenter = point(for: anchor, visible: screen.visible, contentSize: contentSize)
        } else {
            bottomCenter = CGPoint(x: screen.visible.midX,
                                   y: defaultBottom(screen: screen.frame, visible: screen.visible, dockShown: dockShown()))
        }
        if let zone = zone.flatMap({ bounded($0, minimumSide: 0) }) {
            bottomCenter = avoiding(zone, bottomCenter: bottomCenter, contentSize: contentSize, visible: screen.visible)
        }
        return bottomCenter
    }

    /// Rectangle de la bulle dont le bas-centre est en ce point.
    public static func bubble(bottomCenter: CGPoint, contentSize: CGSize) -> CGRect {
        CGRect(x: bottomCenter.x - contentSize.width / 2, y: bottomCenter.y, width: contentSize.width, height: contentSize.height)
    }

    /// La bulle n'est-elle plus sur aucun écran (le sien débranché, par exemple) ? Sans écran, elle n'est pas perdue :
    /// il n'y a nulle part où la remettre.
    public static func isLost(_ bubble: CGRect, among screens: [OverlayScreen]) -> Bool {
        guard !screens.isEmpty else { return false }
        guard let bubble = bounded(bubble, minimumSide: 0) else { return true }
        return !screens.contains { intersects($0.frame, bubble) }
    }

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

    /// Rectangle redressé (largeur et hauteur positives), fini, dans les limites des coordonnées, de côtés au moins
    /// `minimumSide` ; sinon nil. Lu champ par champ, sans opération de CGRect, dont les cas limites (rectangle nul,
    /// infini, NaN) diffèrent d'un système à l'autre. Un rectangle déjà droit est rendu tel quel.
    static func bounded(_ rect: CGRect, minimumSide: CGFloat) -> CGRect? {
        let x = rect.origin.x, y = rect.origin.y, width = rect.size.width, height = rect.size.height
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        let minX = width < 0 ? x + width : x, minY = height < 0 ? y + height : y
        let w = abs(width), h = abs(height)
        guard minX >= -coordinateLimit, minY >= -coordinateLimit, minX + w <= coordinateLimit, minY + h <= coordinateLimit,
              w >= minimumSide, h >= minimumSide else { return nil }
        return width < 0 || height < 0 ? CGRect(x: minX, y: minY, width: w, height: h) : rect
    }

    /// Partie d'un rectangle droit dans un autre ; nil si elle a moins d'un point de côté. Déjà dedans : rendu tel quel.
    static func clipped(_ rect: CGRect, to bounds: CGRect) -> CGRect? {
        let minX = max(rect.minX, bounds.minX), minY = max(rect.minY, bounds.minY)
        let maxX = min(rect.maxX, bounds.maxX), maxY = min(rect.maxY, bounds.maxY)
        guard maxX - minX >= 1, maxY - minY >= 1 else { return nil }
        if minX == rect.minX, minY == rect.minY, maxX == rect.maxX, maxY == rect.maxY { return rect }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Point dans un rectangle droit, bords bas et gauche compris, comme `CGRect.contains`.
    static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY
    }

    /// Deux rectangles droits se recouvrent-ils (un bord commun ne suffit pas) ?
    static func intersects(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }
}
