import AppKit

/// Identité « W + chat » de Wispad dans la barre des menus : une tête de chat dont la bouche
/// est un W en forme d'onde sonore. Dessinée en vectoriel pour rester nette à toutes les échelles.
enum BrandIcon {
    /// Taille de l'icône de barre des menus, en points.
    static let menuBarSize = NSSize(width: 18, height: 18)

    /// Image modèle (template) : macOS la colore selon l'apparence de la barre des menus.
    /// En écoute, la tête devient pleine avec le W découpé ; le bouton la teinte en rouge.
    static func menuBarImage(listening: Bool) -> NSImage {
        let image = NSImage(size: menuBarSize, flipped: false) { rect in
            draw(listening: listening, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = listening ? String(localized: "Wispad, dictée en cours") : String(localized: "Wispad")
        return image
    }

    /// Dessine l'icône en noir dans `rect` (grille de 18 × 18 unités mise à l'échelle).
    static func draw(listening: Bool, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / menuBarSize.width, y: rect.height / menuBarSize.height)

        // AppKit redessine l'image pour chaque échelle d'écran. Sur un écran non Retina, un trait
        // de 1,5 px serait flou : trait de 1 px, et le dessin grandit d'un rien autour du centre
        // pour que les bords extérieurs restent sur les mêmes pixels (1 et 17).
        let device = context.userSpaceToDeviceSpaceTransform
        let pixelsPerUnit = hypot(device.a, device.b)
        let stroke: CGFloat = pixelsPerUnit < 1.5 ? 1 : retinaStroke
        let grow = (9 - (1 + stroke / 2)) / (9 - (1 + retinaStroke / 2))
        context.translateBy(x: 9, y: 9)
        context.scaleBy(x: grow, y: grow)
        context.translateBy(x: -9, y: -9)
        // Épaisseurs exprimées avant l'agrandissement, pour garder 1 px pile à l'écran.
        let unit = 1 / grow
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)

        let head = headPath()
        context.setLineWidth(stroke * unit)
        if listening {
            context.addPath(head)
            context.fillPath()
        }
        context.addPath(head)
        context.strokePath()

        if listening {
            // Le W est découpé dans la tête pleine : il prend la couleur de la barre des menus.
            context.setBlendMode(.clear)
        }
        context.setLineWidth((listening ? stroke + 0.2 : stroke) * unit)
        context.addPath(wavePath())
        context.strokePath()
    }

    /// Épaisseur du trait en Retina : 3 px nets, bords du contour posés sur la grille de pixels.
    private static let retinaStroke: CGFloat = 1.5

    /// Contour de la tête et des deux oreilles. Côtés verticaux et bas plat centrés sur des
    /// quarts de point : le trait de 1,5 pt couvre des pixels @2x entiers (bords 1 et 17).
    private static func headPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 9, y: 1.75))
        path.addLine(to: CGPoint(x: 6, y: 1.75))
        path.addCurve(to: CGPoint(x: 1.75, y: 5), control1: CGPoint(x: 3.65, y: 1.75), control2: CGPoint(x: 1.75, y: 3.2))
        path.addLine(to: CGPoint(x: 1.75, y: 9.6))
        path.addLine(to: CGPoint(x: 2.9, y: 16.25))
        path.addLine(to: CGPoint(x: 7, y: 13.15))
        path.addCurve(to: CGPoint(x: 11, y: 13.15), control1: CGPoint(x: 8.3, y: 13.55), control2: CGPoint(x: 9.7, y: 13.55))
        path.addLine(to: CGPoint(x: 15.1, y: 16.25))
        path.addLine(to: CGPoint(x: 16.25, y: 9.6))
        path.addLine(to: CGPoint(x: 16.25, y: 5))
        path.addCurve(to: CGPoint(x: 12, y: 1.75), control1: CGPoint(x: 16.25, y: 3.2), control2: CGPoint(x: 14.35, y: 1.75))
        path.closeSubpath()
        return path
    }

    /// Le W : une onde en zigzag, branches extérieures plus hautes que le pic central.
    private static func wavePath() -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: 4.75, y: 9.0),
            CGPoint(x: 6.6, y: 4.75),
            CGPoint(x: 9.0, y: 7.75),
            CGPoint(x: 11.4, y: 4.75),
            CGPoint(x: 13.25, y: 9.0)
        ])
        return path
    }
}
