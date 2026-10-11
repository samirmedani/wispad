import SwiftUI
import AppKit
import WispadCore
import os

// MARK: - Bulle de dictée

/// Ce que montre la bulle. Reste figé sur le dernier état pendant la disparition.
enum OverlayMode: Equatable {
    case listening
    case handsFree
    case finishing
    case failure(String)
    /// Information brève hors dictée : jamais cliquable.
    case notice(String)
    /// Mot déjà ajouté : Oui le garde, Non le retire. Mêmes clics que la bulle en mains libres.
    case learning(String)

    /// La dictée passe avant un message d'information.
    static func resolve(phase: DictationPhase, notice: String?, confirmsLearning: Bool = false) -> OverlayMode? {
        if let mode = OverlayMode(phase) { return mode }
        guard let notice else { return nil }
        return confirmsLearning ? .learning(notice) : .notice(notice)
    }

    init?(_ phase: DictationPhase) {
        switch phase {
        case .idle: return nil
        case .starting, .listening(.pushToTalk): self = .listening
        case .listening(.toggle): self = .handsFree
        case .finishing: self = .finishing
        case .failure(let message): self = .failure(message)
        }
    }

    /// Seuls les états à boutons captent la souris, et seulement sur la pilule.
    var isInteractive: Bool {
        switch self {
        case .handsFree, .failure, .learning: return true
        case .listening, .finishing, .notice: return false
        }
    }
}

@MainActor
@Observable
final class OverlayState {
    var presented = false
    var mode: OverlayMode = .listening
    var isHovered = false
    /// Mouvement réduit imposé (démo `--reduce-motion`), en plus du réglage système.
    var forcesReduceMotion = false
    /// Cadre réel de la pilule dans le panneau (origine en haut à gauche), remonté par SwiftUI.
    @ObservationIgnored var pillFrame: CGRect = .zero {
        didSet { if pillFrame != oldValue { onPillFrameChange?() } }
    }
    @ObservationIgnored var onPillFrameChange: (() -> Void)?
}

/// Géométrie de la bulle : panneau de taille fixe, pilule ancrée en bas au centre.
@MainActor
enum OverlayLayout {
    /// Assez grand pour l'état d'erreur, l'ombre et le rebond d'apparition : le panneau ne bouge plus.
    static let panelSize = CGSize(width: 560, height: 84)
    static let pillHeight: CGFloat = 30
    /// Espace transparent sous la pilule, pour l'ombre.
    static let bottomMargin: CGFloat = 10
    static let dockGap: CGFloat = 6
    static let screenGap: CGFloat = 10
    static let space = "wispad-overlay"
    static let spectrumPadding: CGFloat = 14
    /// Pilule à spectre (maintien, mains libres, finalisation) : barres et marges.
    static let spectrumPillWidth = SpectrumBars.width(count: DictationCoordinator.barCount) + 2 * spectrumPadding
    /// Au-delà de l'espacement du conteneur de verre : ✕ et ■ ne fusionnent plus avec la pilule.
    static let orbGap: CGFloat = 8
    /// Distance du centre de la pilule au centre d'un bouton sorti.
    static let orbReach = spectrumPillWidth / 2 + orbGap + pillHeight / 2
    static let handsFreeWidth = spectrumPillWidth + 2 * (orbGap + pillHeight)

    /// Bas de la pilule en coordonnées écran : juste au-dessus du Dock affiché, sinon près du bord
    /// (Dock masqué, sur le côté, ou caché par une app en plein écran).
    static func pillBottom(screen: NSRect, visible: NSRect, dockShown: Bool) -> CGFloat {
        dockShown && visible.minY > screen.minY + 0.5 ? visible.minY + dockGap : screen.minY + screenGap
    }

    static func panelFrame(screen: NSRect, visible: NSRect, dockShown: Bool) -> NSRect {
        NSRect(
            x: (visible.midX - panelSize.width / 2).rounded(),
            y: pillBottom(screen: screen, visible: visible, dockShown: dockShown) - bottomMargin,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    /// Le Dock est-il affiché sur cet écran ? Dans un espace plein écran il est caché, mais visibleFrame
    /// lui garde sa place : seule la présence de sa fenêtre à l'écran le dit.
    /// `windows` vient de CGWindowListCopyWindowInfo, origine en haut à gauche de l'écran principal.
    static func dockShown(on screen: NSRect, primaryHeight: CGFloat, windows: [[String: Any]], dockPIDs: Set<pid_t>) -> Bool {
        let level = Int(CGWindowLevelForKey(.dockWindow))
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, dockPIDs.contains(pid),
                  window[kCGWindowLayer as String] as? Int == level,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            let flipped = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
            return flipped.intersects(screen)
        }
    }

    /// Le point écran (origine en bas à gauche) tombe-t-il sur la pilule, dont le cadre est exprimé
    /// dans le panneau avec l'origine en haut à gauche, comme SwiftUI le donne ?
    static func pill(_ pill: CGRect, in panel: NSRect, contains point: NSPoint, slack: CGFloat = 2) -> Bool {
        guard !pill.isEmpty else { return false }
        let local = CGPoint(x: point.x - panel.minX, y: panel.maxY - point.y)
        return pill.insetBy(dx: -slack, dy: -slack).contains(local)
    }
}

enum OverlayStyle {
    static let red = Color(red: 1, green: 0.23, blue: 0.21)
    /// Spectre d'une dictée servie par un relais (OpenAI quand xAI ou DeepSeek ne répondent pas).
    static let relay = Color(red: 0.06, green: 0.72, blue: 0.56)
    static let green = Color(red: 0.3, green: 0.85, blue: 0.45)
    /// Verre fumé noir : verre « clear » teinté, qui reste noir sur fond clair comme sur fond sombre.
    /// La teinte fait partie du verre : elle suit ses fusions et ses morphoses.
    static let glassTint = Color.black.opacity(0.85)
    /// Repli avant macOS 26 : matériau sombre presque opaque.
    static let background = Color.black.opacity(0.86)
    /// Reflet discret sur le haut du bord, éteint à mi-hauteur pour ne pas souligner les jonctions.
    static let rim = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.32), location: 0),
            .init(color: .white.opacity(0), location: 0.45),
            .init(color: .white.opacity(0), location: 0.8),
            .init(color: .white.opacity(0.08), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Vive : la bulle doit être là dès que la dictée démarre, pas 350 ms plus tard.
    static let appear = Animation.spring(response: 0.18, dampingFraction: 0.86)
    static let disappear = Animation.spring(response: 0.32, dampingFraction: 0.92)
    static let morph = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let fade = Animation.easeInOut(duration: 0.2)
}

/// Canevas fixe du panneau ; la pilule y naît, change de forme et disparaît sans que la fenêtre bouge.
struct OverlayBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let state = model.overlay.state
        let reduceMotion = systemReduceMotion || state.forcesReduceMotion
        ZStack(alignment: .bottom) {
            Color.clear
            if state.presented {
                OverlayCluster(mode: state.mode)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: OverlayPillFrameKey.self, value: proxy.frame(in: .named(OverlayLayout.space)))
                        }
                    }
                    .transition(reduceMotion ? .opacity : .overlayBirth)
            }
        }
        // Au niveau du canevas : la position de la pilule s'anime avec sa largeur, elle reste centrée.
        .animation(reduceMotion ? OverlayStyle.fade : OverlayStyle.morph, value: state.mode)
        .padding(.bottom, OverlayLayout.bottomMargin)
        .frame(width: OverlayLayout.panelSize.width, height: OverlayLayout.panelSize.height)
        .coordinateSpace(.named(OverlayLayout.space))
        .onPreferenceChange(OverlayPillFrameKey.self) { frame in
            state.pillFrame = frame
        }
        .environment(\.colorScheme, .dark)
        .environment(\.overlayReduceMotion, reduceMotion)
    }
}

private struct OverlayPillFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// Apparition : la pilule naît d'un point de 12 pt en bas, s'étire avec un ressort et sort du flou.
/// Animable : la taille réelle est lue à chaque image, le point est le même quelle que soit la largeur.
struct OverlayBirth: ViewModifier, Animatable {
    nonisolated var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let progress = progress
        content.visualEffect { effect, proxy in
            let dot: CGFloat = 12
            let width = max(proxy.size.width, dot)
            let height = max(proxy.size.height, dot)
            let scale = CGSize(
                width: dot / width + (1 - dot / width) * progress,
                height: dot / height + (1 - dot / height) * progress
            )
            return effect
                .scaleEffect(scale, anchor: .bottom)
                .blur(radius: max(0, 1 - progress) * 6)
                .opacity(Double(min(1, max(0, progress))))
        }
    }
}

extension AnyTransition {
    static var overlayBirth: AnyTransition {
        .modifier(active: OverlayBirth(progress: 0), identity: OverlayBirth(progress: 1))
    }
}

extension EnvironmentValues {
    /// Faux pour les rendus hors écran : ImageRenderer ne dessine pas le Liquid Glass.
    @Entry var overlayGlass = true
    /// Mouvement réduit de la bulle, posé par OverlayBar (réglage système ou démo).
    @Entry var overlayReduceMotion = false
}

/// Pilule et boutons en verre fumé. Les boutons ✕ et ■ vivent sous la pilule : en mains libres ils en
/// sortent en glissant et le verre les garde soudés à elle ; ensuite ils s'y fondent de nouveau.
struct OverlayCluster: View {
    @Environment(AppModel.self) private var model
    @Environment(\.overlayReduceMotion) private var reduceMotion
    @Environment(\.overlayGlass) private var glassEnabled
    @Namespace private var glass
    var mode: OverlayMode

    /// ✕ et ■ existent-ils dans la vue ? Toujours quand ils glissent hors de la pilule ; en mouvement
    /// réduit, seulement en mains libres : dans un GlassEffectContainer, l'opacité n'efface pas le verre
    /// d'un bouton caché, que le conteneur dessine lui-même.
    static func showsOrbs(_ mode: OverlayMode, reduceMotion: Bool) -> Bool {
        mode == .handsFree || !reduceMotion
    }

    var body: some View {
        if #available(macOS 26, *), glassEnabled {
            GlassEffectContainer(spacing: OverlayLayout.orbGap - 2) { cluster(glassy: true) }
        } else {
            cluster(glassy: false).shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
    }

    private func cluster(glassy: Bool) -> some View {
        let coordinator = model.coordinator
        let handsFree = mode == .handsFree
        let reach = handsFree ? OverlayLayout.orbReach : 0
        // Sous la pilule, le verre se confond avec elle ; sans verre, le bouton caché doit s'effacer.
        let hiddenOpacity: Double = glassy ? 1 : 0
        let orbScale: CGFloat = handsFree ? 1 : 0.5
        return ZStack {
            // Mouvement réduit : les boutons paraissent en fondu à leur place, sans glisser.
            if Self.showsOrbs(mode, reduceMotion: reduceMotion) {
                OverlayOrbButton(symbol: "xmark", tint: .white.opacity(0.78), help: String(localized: "Annuler (Échap)"), glassID: "cancel", namespace: glass, revealed: handsFree) {
                    coordinator.cancel()
                }
                .scaleEffect(orbScale)
                .offset(x: -reach)
                .opacity(handsFree ? 1 : hiddenOpacity)
                .transition(.opacity)
                OverlayOrbButton(symbol: "stop.fill", tint: OverlayStyle.red, help: String(localized: "Terminer"), glassID: "stop", namespace: glass, revealed: handsFree) {
                    model.hotkeys?.sessionEnded()
                    coordinator.enqueue { coordinator.endCapture() }
                }
                .scaleEffect(orbScale)
                .offset(x: reach)
                .opacity(handsFree ? 1 : hiddenOpacity)
                .transition(.opacity)
            }
            OverlayPill(mode: mode)
                .overlayGlass(Capsule(), id: "pill", in: glass)
        }
        // La mise en page suit les boutons sortis : centrage et zone cliquable couvrent ✕ et ■.
        .frame(width: handsFree ? OverlayLayout.handsFreeWidth : nil)
    }
}

/// Contenu de la pilule : spectre, vague de finalisation ou message d'erreur, en fondu enchaîné.
struct OverlayPill: View {
    @Environment(AppModel.self) private var model
    var mode: OverlayMode

    var body: some View {
        ZStack {
            switch mode {
            case .listening, .handsFree:
                LiveSpectrum()
                    .padding(.horizontal, OverlayLayout.spectrumPadding)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            case .finishing:
                ProcessingBars()
                    .padding(.horizontal, OverlayLayout.spectrumPadding)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            case .failure(let message):
                FailurePill(message: message)
                    .id(message)
                    .transition(.opacity)
            case .notice(let message):
                let relay = model.coordinator.noticeIsRelay
                MessageLine(symbol: relay ? "arrow.triangle.branch" : "checkmark.circle.fill", tint: relay ? OverlayStyle.relay : OverlayStyle.green, message: message, duration: DictationCoordinator.noticeSeconds)
                    .id(message)
                    .transition(.opacity)
            case .learning(let message):
                MessageLine(
                    symbol: "checkmark.circle.fill",
                    tint: OverlayStyle.green,
                    message: message,
                    duration: DictationCoordinator.learningSeconds,
                    actionTitle: String(localized: "Oui"),
                    action: { model.coordinator.acceptLearning() },
                    secondaryTitle: String(localized: "Non"),
                    secondaryAction: { model.coordinator.declineLearning() }
                )
                .id(message)
                .transition(.opacity)
            }
        }
        .frame(minHeight: OverlayLayout.pillHeight)
    }
}

extension View {
    /// Liquid Glass noir sur macOS 26+, matériau sombre avant.
    func overlayGlass<S: InsettableShape>(_ shape: S, id: String, in namespace: Namespace.ID, interactive: Bool = false, rim: Bool = true) -> some View {
        modifier(OverlayGlass(shape: shape, id: id, namespace: namespace, interactive: interactive, rim: rim))
    }
}

private struct OverlayGlass<S: InsettableShape>: ViewModifier {
    @Environment(\.overlayGlass) private var glassEnabled
    @Environment(\.overlayReduceMotion) private var reduceMotion
    var shape: S
    var id: String
    var namespace: Namespace.ID
    var interactive: Bool
    var rim: Bool

    func body(content: Content) -> some View {
        // Le contenu reste dans la forme pendant qu'elle s'étire : il se dévoile au lieu de déborder.
        let clipped = content
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(OverlayStyle.rim, lineWidth: 0.7)
                    .opacity(rim ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: rim)
            )
        if #available(macOS 26, *), glassEnabled {
            clipped
                .glassEffect(.clear.tint(OverlayStyle.glassTint).interactive(interactive), in: shape)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(reduceMotion ? .materialize : .matchedGeometry)
        } else {
            clipped
                .background(shape.fill(OverlayStyle.background))
                .background(shape.fill(.ultraThinMaterial))
        }
    }
}

/// Lit le spectre lui-même : seul ce petit morceau se redessine à 60 Hz.
struct LiveSpectrum: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coordinator = model.coordinator
        let tint = coordinator.relay == nil ? OverlayStyle.red : OverlayStyle.relay
        SpectrumBars(levels: coordinator.spectrum, color: tint.opacity(coordinator.isListening ? 1 : 0.45))
    }
}

/// Spectre symétrique : graves au centre, aigus sur les bords.
struct SpectrumBars: View {
    var levels: [Float]
    var color: Color
    /// Agrandissement net (pas un `scaleEffect`, qui flouterait le dessin) : 1 dans la bulle.
    var scale: CGFloat = 1

    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2.5
    static let height: CGFloat = 16
    static let minimumHeight: CGFloat = 3

    var body: some View {
        let count = levels.count
        let barWidth = Self.barWidth * scale
        let minimumHeight = Self.minimumHeight * scale
        Canvas { context, size in
            var x: CGFloat = 0
            for level in self.levels {
                let height = minimumHeight + CGFloat(min(1, max(0, level))) * (size.height - minimumHeight)
                let bar = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2), with: .color(self.color))
                x += barWidth + Self.spacing * self.scale
            }
        }
        .frame(width: Self.width(count: count) * scale, height: Self.height * scale)
    }

    static func width(count: Int) -> CGFloat {
        CGFloat(count) * barWidth + CGFloat(max(0, count - 1)) * spacing
    }
}

/// Vague grise discrète pendant la transcription et la correction.
struct ProcessingBars: View {
    @Environment(\.overlayReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation) { timeline in
            let levels = Self.levels(at: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
            SpectrumBars(levels: levels, color: model.coordinator.relay == nil ? .white.opacity(0.55) : OverlayStyle.relay.opacity(0.8))
        }
    }

    /// Hauteurs de la vague à cet instant. Calcul découpé et typé : Xcode 26 n'arrivait pas à typer l'expression d'un bloc.
    static func levels(at time: Double, reduceMotion: Bool) -> [Float] {
        (0..<DictationCoordinator.barCount).map { (index: Int) -> Float in
            if reduceMotion {
                let wave: Double = sin(time * 2)
                return Float(0.22 + 0.08 * wave)
            }
            let phase: Double = time * 5.5 - Double(index) * 0.6
            let wave: Double = (1 + sin(phase)) / 2
            return Float(0.16 + 0.26 * wave)
        }
    }
}

/// Bouton rond en verre, soudé à la pilule en mains libres. Caché, il reste sous la pilule, inerte.
struct OverlayOrbButton: View {
    var symbol: String
    var tint: Color
    var help: String
    var glassID: String
    var namespace: Namespace.ID
    var revealed: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .opacity(revealed ? 1 : 0)
                // L'icône s'efface avant que le bouton ne repasse sur le spectre, et revient une fois sorti.
                .animation(revealed ? .easeIn(duration: 0.18).delay(0.08) : .easeOut(duration: 0.1), value: revealed)
                .frame(width: OverlayLayout.pillHeight, height: OverlayLayout.pillHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlayGlass(Circle(), id: glassID, in: namespace, interactive: revealed, rim: revealed)
        .allowsHitTesting(revealed)
        .accessibilityHidden(!revealed)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Message d'erreur sur une ligne : action utile, croix au survol et départ automatique.
struct FailurePill: View {
    @Environment(AppModel.self) private var model
    var message: String

    var body: some View {
        let coordinator = model.coordinator
        if let failure = coordinator.failureText {
            MessageLine(symbol: "exclamationmark.circle.fill", tint: OverlayStyle.red, message: message, duration: DictationCoordinator.failureSeconds, onDismiss: coordinator.dismissFailure, actionTitle: String(localized: "Copier"), action: {
                model.copy(failure)
                coordinator.dismissFailure()
            })
        } else {
            MessageLine(symbol: "exclamationmark.circle.fill", tint: OverlayStyle.red, message: message, duration: DictationCoordinator.failureSeconds, onDismiss: coordinator.dismissFailure, actionTitle: String(localized: "Historique"), action: {
                coordinator.dismissFailure()
                model.open(.history)
            })
        }
    }
}

/// Une ligne centrée, petite, avec une fine barre qui se vide de droite à gauche avant le départ du message.
struct MessageLine: View {
    @Environment(AppModel.self) private var model
    var symbol: String
    var tint: Color
    var message: String
    var duration: Double
    var onDismiss: (() -> Void)? = nil
    var actionTitle: String? = nil
    /// Action du premier bouton. Déclarée avant le bouton secondaire et toujours nommée aux appels :
    /// une fermeture en fin d'appel se rattachait sinon au bouton secondaire, et « Copier » disparaissait.
    var action: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    @State private var remaining: CGFloat = 1

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: true, vertical: false)
            if let actionTitle, let action {
                messageButton(actionTitle, action: action)
            }
            if let secondaryTitle, let secondaryAction {
                messageButton(secondaryTitle, action: secondaryAction)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // Place réservée : le message ne bouge pas quand le curseur entre ou sort.
                .opacity(model.overlay.state.isHovered ? 1 : 0)
                .allowsHitTesting(model.overlay.state.isHovered)
                .animation(OverlayStyle.fade, value: model.overlay.state.isHovered)
                .help("Fermer le message")
                .accessibilityLabel("Fermer le message")
                // VoiceOver doit pouvoir fermer le message même sans déplacer le pointeur.
                .accessibilityHidden(false)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: OverlayLayout.pillHeight)
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: max(0, proxy.size.width * remaining), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 3)
        }
        .onAppear {
            remaining = 1
            // Linéaire, sans ressort : une minuterie qui s'écoule, pas un objet qui bouge.
            withAnimation(.linear(duration: duration)) {
                remaining = 0
            }
        }
    }

    private func messageButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Bulle flottante en bas au centre de l'écran, sans jamais prendre le focus.
/// Le panneau garde une taille fixe ; seule la pilule, à l'intérieur, s'anime.
@MainActor
final class OverlayController {
    private static let log = Logger.wispad("bulle")
    let state = OverlayState()
    private(set) var panel: NSPanel?
    /// Contenu SwiftUI de la bulle, conservé quand le panneau est remplacé.
    private var content: NSView?
    private weak var model: AppModel?
    private var wanted = false
    /// Invalide les retraits en attente quand la bulle revient avant la fin de sa disparition.
    private var presentation = 0
    private var monitors: [Any] = []
    private var visibilityTask: Task<Void, Never>?
    private var visibilityRecoveries = 0
    nonisolated(unsafe) private var spaceObserver: NSObjectProtocol?
    /// Avance à chaque changement d'espace (bureau, app en plein écran).
    private(set) var spaceGeneration = 0
    /// Un seul remplacement par espace visité : pas de boucle si un espace refuse aussi le panneau neuf.
    private var replacedGeneration: Int?
    private var spaceReplacements = 0
    /// Faux dans les tests : la bulle suit les phases sans mettre de fenêtre à l'écran.
    var displaysPanel = true
    /// Lecture de `isOnActiveSpace`, remplaçable dans les tests faute d'espace plein écran.
    var isOnActiveSpace: @MainActor (NSWindow) -> Bool = { $0.isOnActiveSpace }

    var isMonitoringMouse: Bool { !monitors.isEmpty }

    /// Métadonnées de présence seulement, sans le texte d'un message ni la position à l'écran.
    var diagnosticState: OverlayDiagnosticState {
        OverlayDiagnosticState(installed: panel != nil, wanted: wanted,
                               visible: panel?.isVisible == true,
                               onActiveSpace: panel.map(isOnActiveSpace) == true,
                               recoveries: visibilityRecoveries,
                               spaceReplacements: spaceReplacements)
    }

    deinit {
        visibilityTask?.cancel()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }

    func install(model: AppModel) {
        self.model = model
        let hosting = FirstMouseHostingView(rootView: OverlayBar().environment(model))
        hosting.sizingOptions = []
        let panel = Self.makePanel()
        panel.contentView = hosting
        content = hosting
        self.panel = panel
        state.onPillFrameChange = { [weak self] in self?.updateMouse() }
        observe()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.spaceGeneration += 1
                // Changement d'espace pendant une dictée : la bulle suit sans attendre la surveillance.
                self.restoreVisibilityIfNeeded()
            }
        }
        // La toute première lecture de la liste des fenêtres coûte des dizaines de ms : faite d'avance,
        // hors du fil principal, pour ne pas retarder la première bulle.
        DispatchQueue.global(qos: .utility).async {
            _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: OverlayLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        // La bulle accompagne aussi les fenêtres d'autres apps (Stage Manager et plein écran).
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        // Pas de zoom du serveur de fenêtres à l'affichage : seule la pilule s'anime.
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        return panel
    }

    func show() {
        guard panel != nil else { return }
        let appearing = !wanted || !state.presented
        applyPhase(appearing: appearing)
        wanted = true
        presentation += 1
        if displaysPanel {
            replacePanelIfOffActiveSpace()
        }
        if let panel, !panel.isVisible, displaysPanel {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let screen {
                let frame = OverlayLayout.panelFrame(screen: screen.frame, visible: screen.visibleFrame, dockShown: Self.dockShown(on: screen))
                panel.setFrame(frame, display: false)
            }
            panel.orderFrontRegardless()
        }
        if appearing {
            withAnimation(reduceMotion ? OverlayStyle.fade : OverlayStyle.appear) {
                state.presented = true
            }
        }
        updateInteractivity()
        monitorVisibility()
    }

    func hide() {
        guard panel != nil, wanted else { return }
        wanted = false
        visibilityTask?.cancel()
        visibilityTask = nil
        presentation += 1
        let token = presentation
        updateInteractivity()
        withAnimation(reduceMotion ? OverlayStyle.fade : OverlayStyle.disappear, completionCriteria: .removed) {
            state.presented = false
        } completion: { [weak self] in
            self?.orderOut(ifStill: token)
        }
        // Filet si l'animation ne rend pas la main (écran éteint, fenêtre masquée).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.orderOut(ifStill: token)
        }
    }

    private func orderOut(ifStill token: Int) {
        guard !wanted, presentation == token else { return }
        panel?.orderOut(nil)
    }

    /// La capture ne change pas d'état pendant que l'utilisateur parle. Une fenêtre retirée par
    /// macOS doit donc revenir sans attendre la fin de la dictée, et sans prendre le focus.
    private func monitorVisibility() {
        guard displaysPanel, visibilityTask == nil else { return }
        visibilityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                self?.restoreVisibilityIfNeeded()
            }
        }
    }

    private func restoreVisibilityIfNeeded() {
        guard wanted, displaysPanel, var panel else { return }
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(panel.frame) }
        let onActiveSpace = isOnActiveSpace(panel)
        guard !panel.isVisible || !onActiveSpace || !onScreen || panel.alphaValue == 0 else { return }
        visibilityRecoveries += 1
        Self.log.notice("Restauration de la bulle : visible=\(panel.isVisible) espaceActif=\(onActiveSpace) surEcran=\(onScreen)")
        if replacePanelIfOffActiveSpace(), let replacement = self.panel {
            panel = replacement
        }
        if !onScreen, let screen = NSScreen.main {
            panel.setFrame(OverlayLayout.panelFrame(screen: screen.frame, visible: screen.visibleFrame, dockShown: Self.dockShown(on: screen)), display: false)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// macOS ne rattache une fenêtre de tous les bureaux à un espace plein écran qu'à sa toute première
    /// apparition. Une app passée en plein écran ensuite n'affiche donc jamais la bulle, même visible
    /// (journal du 4 octobre 2026 : espaceActif=false pendant toute la dictée). Ni orderFront, ni un
    /// retrait suivi d'un nouvel affichage, ni un changement de collectionBehavior ne l'y ajoutent ;
    /// un panneau neuf rejoint l'espace actif dès son premier affichage. Le contenu SwiftUI le suit.
    @discardableResult
    func replacePanelIfOffActiveSpace() -> Bool {
        guard let old = panel, let content, !isOnActiveSpace(old), replacedGeneration != spaceGeneration else { return false }
        replacedGeneration = spaceGeneration
        spaceReplacements += 1
        let replacement = Self.makePanel()
        replacement.setFrame(old.frame, display: false)
        replacement.ignoresMouseEvents = old.ignoresMouseEvents
        let wasVisible = old.isVisible
        old.orderOut(nil)
        old.contentView = NSView()
        replacement.contentView = content
        panel = replacement
        Self.log.notice("Bulle recréée pour l'espace actif")
        if wasVisible {
            replacement.orderFrontRegardless()
        }
        return true
    }

    private var reduceMotion: Bool {
        state.forcesReduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Transaction qui pose un nouveau mode. Bulle qui naît : déjà dans le bon état dès la première
    /// image, sans morphose depuis la dictée précédente. Bulle déjà là : le changement s'anime.
    static func modeTransaction(appearing: Bool, reduceMotion: Bool) -> Transaction {
        guard !appearing else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            return transaction
        }
        return Transaction(animation: reduceMotion ? OverlayStyle.fade : OverlayStyle.morph)
    }

    private func applyPhase(appearing: Bool) {
        guard let model,
              let mode = OverlayMode.resolve(phase: model.coordinator.phase, notice: model.coordinator.notice, confirmsLearning: model.coordinator.noticeConfirmsLearning),
              mode != state.mode else { return }
        withTransaction(Self.modeTransaction(appearing: appearing, reduceMotion: reduceMotion)) {
            state.mode = mode
        }
    }

    /// Lit les fenêtres à l'écran pour savoir si le Dock est affiché sur cet écran (1 à 3 ms une fois
    /// la liste préchauffée par install(), 25 à 30 ms sinon).
    static func dockShown(on screen: NSScreen) -> Bool {
        let dockPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return OverlayLayout.dockShown(on: screen.frame, primaryHeight: primaryHeight, windows: windows, dockPIDs: dockPIDs)
    }

    /// Maintien et finalisation : tout le panneau laisse passer la souris.
    /// Mains libres et erreur : seule la pilule la capte, suivie par des moniteurs de mouvement.
    private func updateInteractivity() {
        guard let panel else { return }
        if wanted && state.mode.isInteractive {
            installMonitors()
            updateMouse()
        } else {
            removeMonitors()
            state.isHovered = false
            panel.ignoresMouseEvents = true
        }
    }

    private func updateMouse() {
        guard let panel, isMonitoringMouse else { return }
        let inside = OverlayLayout.pill(state.pillFrame, in: panel.frame, contains: NSEvent.mouseLocation)
        if state.isHovered != inside { state.isHovered = inside }
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // Global : le curseur au-dessus des autres apps. Local : au-dessus de la bulle, quand elle capte la souris.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouse() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    private func refresh() {
        applyPhase(appearing: !wanted || !state.presented)
        updateInteractivity()
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.coordinator.phase
            _ = model.coordinator.notice
            _ = model.coordinator.noticeConfirmsLearning
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    /// Zone toujours active : une app accessoire, jamais au premier plan, reçoit ainsi les mouvements
    /// au-dessus de sa bulle, et le moniteur local les voit passer.
    private let mouseTracker = NSResponder()
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: mouseTracker, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
}
