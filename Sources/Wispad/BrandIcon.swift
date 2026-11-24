import AppKit

/// Identité « Spectre Pur » de Wispad dans la barre des menus : sept barres verticales
/// asymétriques, dessinées en vectoriel et alignées sur la grille de pixels (@1x et @2x).
enum BrandIcon {
    /// Taille de l'icône de barre des menus, en points.
    static let menuBarSize = NSSize(width: 18, height: 18)

    /// Image modèle (template) : macOS la colore selon l'apparence de la barre des menus.
    /// En écoute, une pilule pleine porte le spectre découpé ; le bouton la teinte en rouge.
    static func menuBarImage(listening: Bool) -> NSImage {
        let image = NSImage(size: menuBarSize, flipped: false) { rect in
            draw(listening: listening, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = listening ? String(localized: "Wispad, dictée en cours") : String(localized: "Wispad")
        return image
    }

    /// Hauteurs relatives des sept barres (cadence asymétrique de l'icône Spectre Pur).
    private static let heights: [CGFloat] = [0.24, 0.48, 0.88, 0.64, 1.0, 0.38, 0.22]

    /// Dessine l'icône en noir dans `rect` (grille de 18 × 18 unités mise à l'échelle).
    static func draw(listening: Bool, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / menuBarSize.width, y: rect.height / menuBarSize.height)

        let device = context.userSpaceToDeviceSpaceTransform
        let pixelsPerUnit = hypot(device.a, device.b)
        let retina = pixelsPerUnit >= 1.5

        context.setFillColor(NSColor.black.cgColor)

        if listening {
            // Pilule pleine : en écoute, la barre des menus la teinte en rouge comme la bulle.
            let pill = retina ? CGRect(x: 0.5, y: 3.0, width: 17.0, height: 12.0)
                              : CGRect(x: 1.0, y: 3.0, width: 16.0, height: 12.0)
            let path = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
            context.addPath(path)
            context.fillPath()
            context.setBlendMode(.clear)
        }

        let maxBarHeight: CGFloat = listening ? 8.0 : 12.0
        let barWidth: CGFloat = retina ? (listening ? 1.0 : 1.5) : 1.0
        // Positions alignées sur les pixels : en @2x, pas de 2,5 pt (5 px) ; en @1x, pas de 2 pt (2 px).
        let originsX: [CGFloat] = retina
            ? (listening ? [3.0, 5.0, 7.0, 9.0, 11.0, 13.0, 15.0].map { $0 - barWidth / 2 }
                         : [1.0, 3.5, 6.0, 8.5, 11.0, 13.5, 16.0])
            : [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0]

        for (index, ratio) in heights.enumerated() {
            let rawHeight = max(barWidth, maxBarHeight * ratio)
            let snappedHeight = retina ? (rawHeight * 2).rounded() / 2 : rawHeight.rounded()
            let y = retina ? ((9.0 - snappedHeight / 2) * 2).rounded() / 2 : (9.0 - snappedHeight / 2).rounded()
            let bar = CGRect(x: originsX[index], y: y, width: barWidth, height: snappedHeight)
            let radius = barWidth / 2
            context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
    }
}
