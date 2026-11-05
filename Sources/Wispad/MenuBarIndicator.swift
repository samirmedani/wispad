import AppKit

/// État montré par le point de l'icône de la barre des menus, comme les apps de dictée du Mac : jaune au démarrage,
/// bleu pendant la transcription, vert un instant quand le texte est arrivé, orange sur un message d'erreur.
/// En écoute, pas de point : la tête pleine en rouge suffit.
enum MenuBarIndicator: Equatable {
    case none
    case starting
    case finishing
    case delivered
    case failure

    /// Durée du point vert après un texte livré.
    static let deliveredDuration: TimeInterval = 1.6

    static func state(phase: DictationPhase, deliveredAt: Date?, now: Date) -> MenuBarIndicator {
        switch phase {
        case .starting: return .starting
        case .listening: return .none
        case .finishing: return .finishing
        case .failure: return .failure
        case .idle:
            guard let deliveredAt else { return .none }
            let elapsed = now.timeIntervalSince(deliveredAt)
            return elapsed >= 0 && elapsed < deliveredDuration ? .delivered : .none
        }
    }

    var color: NSColor? {
        switch self {
        case .none: return nil
        case .starting: return .systemYellow
        case .finishing: return .systemBlue
        case .delivered: return .systemGreen
        case .failure: return .systemOrange
        }
    }

    var accessibilityLabel: String? {
        switch self {
        case .none: return nil
        case .starting: return String(localized: "Démarrage")
        case .finishing: return String(localized: "Transcription")
        case .delivered: return String(localized: "Texte écrit")
        case .failure: return String(localized: "Erreur")
        }
    }
}

/// Point de couleur posé en bas à droite du bouton de la barre des menus. L'icône reste une image modèle : macOS la
/// colore selon la barre ; seul le point garde sa couleur.
final class StatusDotView: NSView {
    static let diameter: CGFloat = 6

    var indicator: MenuBarIndicator = .none {
        didSet {
            guard indicator != oldValue else { return }
            isHidden = indicator.color == nil
            needsDisplay = true
            superview?.setAccessibilityValue(indicator.accessibilityLabel)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func attach(to button: NSView) {
        if superview !== button { button.addSubview(self) }
        let size = Self.diameter
        let bounds = button.bounds
        // Coin bas droit de l'icône de 18 points centrée dans le bouton.
        let x = bounds.midX + 9 - size + 1
        let y = button.isFlipped ? bounds.midY + 9 - size + 1 : bounds.midY - 9 - 1
        frame = NSRect(x: x, y: y, width: size, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let color = indicator.color else { return }
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    // Le point ne capte jamais le clic : le menu s'ouvre comme avant.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
