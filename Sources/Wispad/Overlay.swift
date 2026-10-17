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
    /// Information brève hors dictée : seule sa ✕, au survol, est cliquable.
    case notice(String)
    /// Mot déjà ajouté : Oui le garde, Non le retire. Mêmes clics que la bulle en mains libres.
    case learning(String)
    /// Nouvelle version de Wispad : Voir ouvre les notes de version, Ne plus me rappeler ferme le rappel.
    case update(String)

    /// La dictée passe avant un message d'information.
    static func resolve(phase: DictationPhase, notice: String?, confirmsLearning: Bool = false, offersUpdate: Bool = false) -> OverlayMode? {
        if let mode = OverlayMode(phase) { return mode }
        guard let notice else { return nil }
        if offersUpdate { return .update(notice) }
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
        case .handsFree, .failure, .notice, .learning, .update: return true
        case .listening, .finishing: return false
        }
    }

    var isLearning: Bool {
        if case .learning = self { return true }
        return false
    }

    /// Message à décompte : ✕ au survol, décompte en pause sous le pointeur. Jamais la bulle d'enregistrement.
    var isMessage: Bool {
        switch self {
        case .failure, .notice, .learning, .update: return true
        case .listening, .handsFree, .finishing: return false
        }
    }

    /// Place à l'écran : celle de la dictée, des alertes de collage ou des messages brefs.
    var role: OverlayRole {
        switch self {
        case .listening, .handsFree, .finishing: return .dictation
        case .failure: return .alerts
        case .notice, .learning, .update: return .info
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
    static let panelSize = CGSize(width: 560, height: 176)
    static let pillHeight: CGFloat = 30
    /// Message sur une ligne : pastille de 26 pt dans 42 pt de haut ; deux lignes de texte au plus.
    static let messageHeight: CGFloat = 42
    static let messageBadge: CGFloat = 26
    /// Largeur maximale d'un message : un texte long passe à la ligne avant le bord du panneau et son ombre.
    static let messageMaxWidth: CGFloat = 520
    /// Cartes : texte prêt à copier, mots appris.
    static let cardWidth: CGFloat = 392
    /// Espace transparent sous la pilule, pour l'ombre.
    static let bottomMargin: CGFloat = 10
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
        OverlayGeometry.defaultBottom(screen: screen, visible: visible, dockShown: dockShown)
    }

    static func panelFrame(screen: NSRect, visible: NSRect, dockShown: Bool) -> NSRect {
        NSRect(
            x: (visible.midX - panelSize.width / 2).rounded(),
            y: pillBottom(screen: screen, visible: visible, dockShown: dockShown) - bottomMargin,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    /// Panneau dont la bulle a son bas-centre en ce point.
    static func panelFrame(bottomCenter: CGPoint) -> NSRect {
        NSRect(x: (bottomCenter.x - panelSize.width / 2).rounded(), y: (bottomCenter.y - bottomMargin).rounded(),
               width: panelSize.width, height: panelSize.height)
    }

    /// Bas-centre de la bulle dans ce panneau.
    static func bottomCenter(of panel: NSRect) -> CGPoint {
        CGPoint(x: panel.midX, y: panel.minY + bottomMargin)
    }

    /// Taille maximale de ce que montre la bulle dans ce mode, pour la garder à l'écran et hors du champ.
    static func contentSize(for mode: OverlayMode, hasReadyText: Bool) -> CGSize {
        switch mode {
        case .listening, .finishing: return CGSize(width: spectrumPillWidth, height: pillHeight)
        case .handsFree: return CGSize(width: handsFreeWidth, height: pillHeight)
        case .failure: return hasReadyText ? CGSize(width: cardWidth, height: 128) : CGSize(width: messageMaxWidth, height: 52)
        // Mots appris sur deux lignes compris.
        case .learning: return CGSize(width: cardWidth, height: 156)
        case .notice, .update: return CGSize(width: messageMaxWidth, height: 52)
        }
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
    /// Nouvelle version disponible.
    static let update = Color(red: 0.38, green: 0.66, blue: 1)
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

/// Textes de la bulle : des messages brefs, jamais terminés par un point, quelle que soit leur source (erreur de
/// macOS comprise). Les points de suspension restent.
enum OverlayText {
    static func display(_ message: String) -> String {
        guard message.hasSuffix("."), !message.hasSuffix("...") else { return message }
        return String(message.dropLast())
    }
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
        let style = model.settings.bubbleStyle
        ZStack {
            if mode.isMessage {
                // Messages : leur propre fond (noir profond ou verre), sans le contour de la bulle de dictée.
                MessageBubble(mode: mode)
                    .transition(Self.swap)
            } else {
                // Verre fumé noir, ou verre transparent clair ou sombre comme l'app.
                dictation
                    .modifier(BubbleScheme(style: style))
                    .transition(Self.swap)
            }
        }
        .environment(\.bubbleStyle, style)
        .environment(\.bubbleGlass, model.settings.bubbleGlass)
    }

    /// De la bulle de dictée à un message, et retour : fondu avec un léger rebond depuis le bas.
    private static var swap: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
    }

    @ViewBuilder private var dictation: some View {
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
                OverlayOrbButton(symbol: "xmark", tint: model.settings.bubbleStyle == .glass ? Color.primary.opacity(0.75) : .white.opacity(0.78),
                                 help: String(localized: "Annuler (Échap)"), glassID: "cancel", namespace: glass, revealed: handsFree) {
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
                .overlayGlass(RoundedRectangle(cornerRadius: 15, style: .continuous), id: "pill", in: glass)
        }
        // La mise en page suit les boutons sortis : centrage et zone cliquable couvrent ✕ et ■.
        .frame(width: handsFree ? OverlayLayout.handsFreeWidth : nil)
    }
}

/// Contenu de la bulle de dictée : spectre ou vague de finalisation, en fondu enchaîné. Les messages ont leur bulle.
struct OverlayPill: View {
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
            case .failure, .notice, .learning, .update:
                EmptyView()
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
    @Environment(\.bubbleStyle) private var style
    @Environment(\.bubbleGlass) private var glassSettings
    @Environment(\.colorScheme) private var scheme
    var shape: S
    var id: String
    var namespace: Namespace.ID
    var interactive: Bool
    var rim: Bool

    func body(content: Content) -> some View {
        // Verre transparent : ses propres reflets, sans le liseré du verre fumé.
        let clear = style == .glass
        // Le contenu reste dans la forme pendant qu'elle s'étire : il se dévoile au lieu de déborder.
        let clipped = content
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(OverlayStyle.rim, lineWidth: 0.7)
                    .opacity(rim && !clear ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: rim)
            )
        if #available(macOS 26, *), glassEnabled {
            clipped
                .glassEffect((clear ? glassSettings.glass(for: scheme) : Glass.clear.tint(OverlayStyle.glassTint)).interactive(interactive), in: shape)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(reduceMotion ? .materialize : .matchedGeometry)
        } else if clear {
            clipped
                .background(shape.fill(glassSettings.tint(for: scheme) ?? .clear))
                .background(shape.fill(glassSettings.variant == .clear ? Material.ultraThinMaterial : Material.regularMaterial))
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
    @Environment(\.bubbleStyle) private var style
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation) { timeline in
            let levels = Self.levels(at: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
            let idle = style == .glass ? Color.primary.opacity(0.5) : Color.white.opacity(0.55)
            SpectrumBars(levels: levels, color: model.coordinator.relay == nil ? idle : OverlayStyle.relay.opacity(0.8))
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

// MARK: - Messages

/// Genre d'un message : son icône et sa couleur.
enum MessageKind {
    case success, info, relay, error, update, ready, learning

    var symbol: String {
        switch self {
        case .success: return "checkmark"
        case .info: return "info"
        case .relay: return "arrow.triangle.branch"
        case .error: return "exclamationmark"
        case .update: return "arrow.down"
        case .ready: return "doc.on.clipboard"
        case .learning: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .success: return OverlayStyle.green
        case .info: return Color(nsColor: .systemGray)
        case .relay: return OverlayStyle.relay
        case .error: return OverlayStyle.red
        case .update: return OverlayStyle.update
        case .ready: return Color(red: 1, green: 0.62, blue: 0.16)
        case .learning: return Color(red: 0.72, green: 0.49, blue: 1)
        }
    }
}

/// Bouton d'un message : un titre, une action, le premier plan pour l'action à ne pas manquer.
struct MessageAction {
    var title: String
    var prominent = false
    var help: String?
    var perform: () -> Void
}

extension EnvironmentValues {
    /// Style de la bulle et verre du style Verre, posés par OverlayCluster depuis Réglages › Bulle.
    @Entry var bubbleStyle = BubbleStyle.black
    @Entry var bubbleGlass = BubbleGlass()
}

/// Couleurs d'un message : blanc sur le noir profond, couleurs de macOS sur le verre (clair ou sombre).
struct MessagePalette {
    let primary: Color
    let secondary: Color
    let tertiary: Color
    /// Fond d'un bouton secondaire et de la ✕.
    let control: Color
    let prominent: Color
    let onProminent: Color

    init(_ style: BubbleStyle) {
        switch style {
        case .black:
            primary = .white.opacity(0.95)
            secondary = .white.opacity(0.62)
            tertiary = .white.opacity(0.42)
            control = .white.opacity(0.13)
            prominent = .white
            onProminent = .black.opacity(0.9)
        case .glass:
            primary = .primary
            secondary = .secondary
            tertiary = Color(nsColor: .tertiaryLabelColor)
            control = .primary.opacity(0.09)
            prominent = .primary
            onProminent = Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// Messages de la bulle : une ligne (erreur, confirmation, relais, nouvelle version) ou une carte (texte prêt à
/// copier, mots appris), dans le style choisi.
struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    var mode: OverlayMode

    var body: some View {
        let style = model.settings.bubbleStyle
        MessageWidth(maxWidth: OverlayLayout.messageMaxWidth) {
            content
        }
        .environment(\.bubbleStyle, style)
        .modifier(BubbleScheme(style: style))
    }

    @ViewBuilder private var content: some View {
        let coordinator = model.coordinator
        switch mode {
        case .failure(let message):
            failure(message)
                .id(message)
                .transition(.opacity)
        case .notice(let message):
            MessageLine(kind: coordinator.noticeIsRelay ? .relay : coordinator.noticeIsInfo ? .info : .success,
                        message: message, countdown: coordinator.noticeTimer.countdown, onDismiss: coordinator.closeMessage)
                .id(message)
                .transition(.opacity)
        case .learning(let message):
            learning(fallback: message)
                .id(message)
                .transition(.opacity)
        case .update(let message):
            MessageLine(kind: .update, message: message, countdown: coordinator.noticeTimer.countdown,
                        onDismiss: coordinator.closeMessage, actions: [
                            MessageAction(title: String(localized: "Voir")) { coordinator.openUpdateOffer() },
                            MessageAction(title: String(localized: "Ne plus me rappeler")) { coordinator.declineUpdateOffer() },
                        ])
                .id(message)
                .transition(.opacity)
        case .listening, .handsFree, .finishing:
            EmptyView()
        }
    }

    /// Texte prêt à copier en carte ; « Copié » après Copier ; erreur sur une ligne, avec Historique si la dictée y est.
    @ViewBuilder private func failure(_ message: String) -> some View {
        let coordinator = model.coordinator
        let countdown = coordinator.failureTimer.countdown
        if coordinator.failureCopied {
            MessageLine(kind: .success, message: message, countdown: countdown, onDismiss: coordinator.closeMessage)
        } else if coordinator.failureText != nil {
            MessageCard(kind: .ready, title: String(localized: "Texte prêt à copier"),
                        message: coordinator.failureDetail ?? message, countdown: countdown,
                        onDismiss: coordinator.closeMessage, actions: [
                            MessageAction(title: String(localized: "Coller")) { coordinator.pasteReadyText() },
                            MessageAction(title: String(localized: "Copier"), prominent: true) { coordinator.copyReadyText() },
                        ])
        } else if !coordinator.failureOffersHistory {
            MessageLine(kind: .error, message: message, countdown: countdown, onDismiss: coordinator.closeMessage)
        } else {
            MessageLine(kind: .error, message: message, countdown: countdown, onDismiss: coordinator.closeMessage, actions: [
                MessageAction(title: String(localized: "Historique")) {
                    coordinator.dismissFailure()
                    model.open(.history)
                },
            ])
        }
    }

    /// Ajouts groupés au dictionnaire : les mots d'abord, puis Voir ou Annuler l'ajout.
    private func learning(fallback: String) -> some View {
        let coordinator = model.coordinator
        let terms = coordinator.learningOfferedTerms
        let title = terms.count > 1 ? String(localized: "\(terms.count) ajouts au dictionnaire") : String(localized: "Ajout au dictionnaire")
        return MessageCard(
            kind: .learning, title: title, message: terms.isEmpty ? fallback : terms.joined(separator: " · "),
            footnote: String(localized: "Appris de tes corrections"), emphasizesMessage: true,
            countdown: coordinator.noticeTimer.countdown, onDismiss: coordinator.closeMessage, actions: [
                MessageAction(title: String(localized: "Voir")) {
                    if let term = terms.first {
                        model.setDisplayChoice(\.dictionaryKind, DictionaryKind.classify(term))
                    }
                    model.setDisplayChoice(\.dictionaryOriginFilter, .learned)
                    model.setDisplayChoice(\.dictionaryPeriod, .all)
                    coordinator.acceptLearning()
                    model.open(.dictionary)
                },
                MessageAction(title: String(localized: "Annuler l'ajout"),
                              help: String(localized: "Retirer ces ajouts et ne plus les apprendre automatiquement")) {
                    coordinator.declineLearning()
                },
            ]
        )
    }
}

/// Le noir profond et le verre fumé sont toujours sombres ; le verre transparent suit l'apparence du panneau, donc
/// celle de l'app.
struct BubbleScheme: ViewModifier {
    var style: BubbleStyle

    @ViewBuilder func body(content: Content) -> some View {
        if style == .black {
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}

/// Propose au plus `maxWidth` à son contenu et prend sa taille : un message long passe à la ligne avant le bord du
/// panneau, un message court garde sa largeur (la zone cliquable de la bulle reste celle du message).
private struct MessageWidth: Layout {
    var maxWidth: CGFloat

    private func proposal(for proposal: ProposedViewSize, in width: CGFloat? = nil) -> ProposedViewSize {
        let offered = width ?? proposal.width ?? maxWidth
        return ProposedViewSize(width: min(offered, maxWidth), height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(self.proposal(for: proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: self.proposal(for: proposal, in: bounds.width))
    }
}

/// Fond d'un message, sans contour : noir profond avec un reflet doux et une ombre, ou Liquid Glass transparent
/// (macOS 26 ; matériau translucide avant).
private struct MessageSurface<S: Shape>: ViewModifier {
    @Environment(\.bubbleStyle) private var style
    @Environment(\.bubbleGlass) private var glassSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.overlayGlass) private var glassEnabled
    var shape: S

    @ViewBuilder func body(content: Content) -> some View {
        switch style {
        case .black:
            content.background {
                shape.fill(Color.black)
                    .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0)],
                                                       startPoint: .top, endPoint: .center)))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
        case .glass:
            if #available(macOS 26, *), glassEnabled {
                content.glassEffect(glassSettings.glass(for: scheme), in: shape)
            } else {
                content.background {
                    shape.fill(glassSettings.variant == .clear ? Material.ultraThinMaterial : Material.regularMaterial)
                        .overlay(shape.fill(glassSettings.tint(for: scheme) ?? .clear))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                }
            }
        }
    }
}

/// Pastille teintée ; son anneau se vide avec le décompte, à l'arrêt sous le pointeur. Sur une ligne, elle devient
/// la ✕ au survol.
struct CountdownBadge: View {
    @Environment(\.bubbleStyle) private var style
    var kind: MessageKind
    var size: CGFloat
    var countdown: MessageCountdown?
    var closing = false

    var body: some View {
        let palette = MessagePalette(style)
        ZStack {
            Circle().inset(by: size * 0.135).fill(closing ? palette.control : kind.tint.opacity(0.2))
            Image(systemName: closing ? "xmark" : kind.symbol)
                .font(.system(size: size * (closing ? 0.3 : 0.36), weight: .bold))
                .foregroundStyle(closing ? palette.primary : kind.tint)
            Circle().inset(by: 1).stroke(kind.tint.opacity(0.16), lineWidth: 2)
            // Seul l'anneau se redessine à chaque image ; figé quand le décompte est en pause.
            TimelineView(.animation(minimumInterval: nil, paused: countdown?.isPaused ?? true)) { timeline in
                Circle().inset(by: 1)
                    .trim(from: 0, to: CGFloat(countdown?.fraction(at: timeline.date) ?? 0))
                    .stroke(kind.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .animation(OverlayStyle.fade, value: closing)
    }
}

/// Une ligne : pastille à décompte, texte de 13 points (deux lignes au plus), boutons. Au survol, la pastille devient
/// la ✕ et le décompte s'arrête ; rien ne bouge.
struct MessageLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.bubbleStyle) private var style
    var kind: MessageKind
    var message: String
    var countdown: MessageCountdown?
    var onDismiss: (() -> Void)?
    var actions: [MessageAction] = []

    var body: some View {
        let closable = model.overlay.state.isHovered && onDismiss != nil
        HStack(spacing: 10) {
            Button { onDismiss?() } label: {
                CountdownBadge(kind: kind, size: OverlayLayout.messageBadge, countdown: countdown, closing: closable)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(closable)
            .help(closable ? String(localized: "Fermer le message") : "")
            .accessibilityLabel("Fermer le message")
            // VoiceOver peut fermer le message sans déplacer le pointeur.
            .accessibilityHidden(onDismiss == nil)
            Text(OverlayText.display(message))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MessagePalette(style).primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(actions.indices, id: \.self) { index in
                MessageButton(action: actions[index], height: 26, fontSize: 12)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, actions.isEmpty ? 16 : 8)
        .padding(.vertical, 8)
        .frame(minHeight: OverlayLayout.messageHeight)
        .modifier(MessageSurface(shape: RoundedRectangle(cornerRadius: OverlayLayout.messageHeight / 2, style: .continuous)))
    }
}

/// Une carte : titre et raison (ou mots appris en premier), boutons sur leur ligne, ✕ en haut à droite au survol.
struct MessageCard: View {
    @Environment(\.bubbleStyle) private var style
    var kind: MessageKind
    var title: String
    var message: String
    var footnote: String?
    /// Mots appris : les mots, en grand, passent devant le titre.
    var emphasizesMessage = false
    var countdown: MessageCountdown?
    var onDismiss: () -> Void
    var actions: [MessageAction]

    var body: some View {
        let palette = MessagePalette(style)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                CountdownBadge(kind: kind, size: 36, countdown: countdown)
                VStack(alignment: .leading, spacing: 3) {
                    if emphasizesMessage {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(kind.tint)
                        Text(OverlayText.display(message))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.primary)
                        Text(OverlayText.display(message))
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let footnote {
                        Text(footnote)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.tertiary)
                            .padding(.top, 2)
                    }
                }
                .padding(.top, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                MessageCloseButton(onDismiss: onDismiss)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(actions.indices, id: \.self) { index in
                    MessageButton(action: actions[index], height: 30, fontSize: 13)
                }
            }
        }
        .padding(16)
        .frame(width: OverlayLayout.cardWidth)
        .modifier(MessageSurface(shape: RoundedRectangle(cornerRadius: 26, style: .continuous)))
    }
}

/// ✕ d'une carte : place gardée, visible et cliquable seulement sous le pointeur.
private struct MessageCloseButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.bubbleStyle) private var style
    var onDismiss: () -> Void

    var body: some View {
        let hovered = model.overlay.state.isHovered
        let palette = MessagePalette(style)
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(palette.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(palette.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 1 : 0)
        .allowsHitTesting(hovered)
        .animation(OverlayStyle.fade, value: hovered)
        .help("Fermer le message")
        .accessibilityLabel("Fermer le message")
    }
}

/// Bouton en capsule : plein pour l'action principale (Copier), voilé pour les autres.
private struct MessageButton: View {
    @Environment(\.bubbleStyle) private var style
    var action: MessageAction
    var height: CGFloat
    var fontSize: CGFloat

    var body: some View {
        let palette = MessagePalette(style)
        let button = Button(action: action.perform) {
            Text(action.title)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(action.prominent ? palette.onProminent : palette.primary)
                .padding(.horizontal, height * 0.45)
                .frame(height: height)
                .background(Capsule().fill(action.prominent ? palette.prominent : palette.control))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(action.title)
        if let help = action.help {
            button.help(help)
        } else {
            button
        }
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
    /// Écrans, pointeur et écran principal lus de macOS ; remplaçables dans les tests pour brancher, débrancher ou
    /// régler autrement des écrans simulés.
    var screens: @MainActor () -> [OverlayScreen] = { NSScreen.screens.compactMap { OverlayScreen($0) } }
    var pointer: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    var mainScreen: @MainActor () -> UInt32? = { NSScreen.main?.displayID }
    /// Écrans lus au dernier changement : seul un écran branché, débranché, déplacé ou redimensionné déplace la bulle.
    private(set) var knownScreens: [OverlayScreen] = []
    /// Numéro de l'écran où la bulle a été placée : elle y reste tant qu'elle est affichée, même quand les coordonnées
    /// de tous les écrans changent (autre écran principal, autre résolution d'un voisin).
    private var placedScreen: UInt32?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    /// Aperçu demandé depuis Réglages : le message bref s'affiche à la place de ce rôle.
    var previewRole: OverlayRole?

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
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func install(model: AppModel) {
        self.model = model
        let hosting = FirstMouseHostingView(rootView: OverlayBar().environment(model))
        hosting.sizingOptions = []
        let panel = Self.makePanel(appearance: panelAppearance)
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
        knownScreens = screens()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
        // La toute première lecture de la liste des fenêtres coûte des dizaines de ms : faite d'avance,
        // hors du fil principal, pour ne pas retarder la première bulle.
        DispatchQueue.global(qos: .utility).async {
            _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        }
    }

    /// Sombre pour le noir profond ; pour le verre, celle de l'app, qui le rend clair ou sombre comme elle (bulle de
    /// dictée comprise).
    private var panelAppearance: NSAppearance? {
        model?.settings.bubbleStyle == .glass ? nil : NSAppearance(named: .darkAqua)
    }

    /// Réglages › Bulle et messages : le nouveau style vaut tout de suite, message affiché compris.
    func bubbleStyleChanged() {
        panel?.appearance = panelAppearance
    }

    private static func makePanel(appearance: NSAppearance?) -> NSPanel {
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
        panel.appearance = appearance
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
            if let next = target(for: state.mode) {
                panel.setFrame(next.frame, display: false)
                placedScreen = next.screen
            }
            panel.orderFrontRegardless()
        } else {
            moveToTarget()
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
        // La bulle elle-même, pas le panneau transparent qui l'entoure : il peut encore toucher un écran voisin quand la
        // bulle était sur un écran débranché. Sans aucun écran, rien à restaurer.
        let onScreen = !OverlayGeometry.isLost(bubbleFrame(in: panel), among: screens())
        let onActiveSpace = isOnActiveSpace(panel)
        guard !panel.isVisible || !onActiveSpace || !onScreen || panel.alphaValue == 0 else { return }
        visibilityRecoveries += 1
        Self.log.notice("Restauration de la bulle : visible=\(panel.isVisible) espaceActif=\(onActiveSpace) surEcran=\(onScreen)")
        if replacePanelIfOffActiveSpace(), let replacement = self.panel {
            panel = replacement
        }
        if !onScreen, let next = target(for: state.mode) {
            panel.setFrame(next.frame, display: false)
            placedScreen = next.screen
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Cadre de la bulle (taille la plus grande de ce mode) dans ce panneau, en coordonnées écran.
    private func bubbleFrame(in panel: NSPanel) -> CGRect {
        let size = OverlayLayout.contentSize(for: state.mode, hasReadyText: model?.coordinator.failureText != nil)
        return OverlayGeometry.bubble(bottomCenter: OverlayLayout.bottomCenter(of: panel.frame), contentSize: size)
    }

    /// Écran branché ou débranché, autre résolution, autre échelle, autre écran principal : macOS ne déplace pas un
    /// panneau sans barre de titre. La bulle affichée reprend aussitôt sa place sur son écran s'il est toujours là,
    /// sinon sur celui du pointeur ; la zone de saisie, lue dans les coordonnées d'avant, est oubliée. Un Dock ou une
    /// barre des menus qui changent ne déplacent rien : la bulle reste entière sur son écran.
    func screensDidChange() {
        let current = screens()
        let changed = !OverlayScreen.sameDisplays(current, knownScreens)
        knownScreens = current
        guard changed else { return }
        InputZoneTracker.reset()
        guard wanted, displaysPanel, let panel, panel.isVisible, let next = target(for: state.mode) else { return }
        placedScreen = next.screen
        if panel.frame != next.frame {
            panel.setFrame(next.frame, display: false)
        }
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
        let replacement = Self.makePanel(appearance: panelAppearance)
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

    /// Cadre du panneau pour ce mode : position choisie dans Réglages (sinon au-dessus du Dock, au centre), puis,
    /// pour les messages, décalage hors de la zone de saisie lue au dernier collage dans l'app au premier plan.
    func targetFrame(for mode: OverlayMode) -> NSRect? {
        target(for: mode)?.frame
    }

    /// Cadre du panneau pour ce mode et numéro de l'écran qui l'accueille : celui de la saisie, sinon celui où la bulle
    /// est déjà (pas de saut d'écran en cours de dictée), sinon celui de la souris (`OverlayGeometry.screen`). nil sans
    /// écran : la bulle reste où elle est.
    private func target(for mode: OverlayMode) -> (frame: NSRect, screen: UInt32)? {
        guard let model else { return nil }
        let placement = model.settings.overlayPlacement
        let role = mode.isMessage ? (previewRole ?? mode.role) : mode.role
        let size = OverlayLayout.contentSize(for: mode, hasReadyText: model.coordinator.failureText != nil)
        let zone = mode.isMessage && placement.avoidsInput && previewRole == nil
            ? InputZoneTracker.zone(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier) : nil
        let shown = panel.flatMap { $0.isVisible ? $0 : nil }
        guard let screen = OverlayGeometry.screen(
            among: screens(), zone: zone, shownOn: shown == nil ? nil : placedScreen,
            shownAt: shown.map { OverlayLayout.bottomCenter(of: $0.frame) }, pointer: pointer(), main: mainScreen()
        ) else { return nil }
        let bottomCenter = OverlayGeometry.bottomCenter(on: screen, anchor: placement.anchor(for: role), contentSize: size,
                                                        dockShown: Self.dockShown(onFrame: screen.frame), zone: zone)
        return (OverlayLayout.panelFrame(bottomCenter: bottomCenter), screen.id)
    }

    /// Bulle déjà affichée dont le mode change de place (fin de dictée → alerte) : elle glisse vers sa nouvelle place.
    func moveToTarget() {
        guard displaysPanel, wanted, let panel, panel.isVisible, let next = target(for: state.mode) else { return }
        placedScreen = next.screen
        let frame = next.frame
        guard abs(frame.minX - panel.frame.minX) > 1 || abs(frame.minY - panel.frame.minY) > 1 else { return }
        if reduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
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
              let mode = OverlayMode.resolve(phase: model.coordinator.phase, notice: model.coordinator.notice,
                                             confirmsLearning: model.coordinator.noticeConfirmsLearning,
                                             offersUpdate: model.coordinator.noticeOffersUpdate),
              mode != state.mode else { return }
        withTransaction(Self.modeTransaction(appearing: appearing, reduceMotion: reduceMotion)) {
            state.mode = mode
        }
    }

    /// Lit les fenêtres à l'écran pour savoir si le Dock est affiché sur cet écran (1 à 3 ms une fois
    /// la liste préchauffée par install(), 25 à 30 ms sinon).
    static func dockShown(on screen: NSScreen) -> Bool {
        dockShown(onFrame: screen.frame)
    }

    /// Même lecture, pour l'écran de ce cadre.
    static func dockShown(onFrame frame: CGRect) -> Bool {
        let dockPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        return OverlayLayout.dockShown(on: frame, primaryHeight: primaryHeight, windows: windows, dockPIDs: dockPIDs)
    }

    /// Maintien et finalisation : tout le panneau laisse passer la souris.
    /// Mains libres et messages : seule la pilule la capte, suivie par des moniteurs de mouvement.
    private func updateInteractivity() {
        guard let panel else { return }
        if wanted && state.mode.isInteractive {
            installMonitors()
            updateMouse()
        } else {
            removeMonitors()
            state.isHovered = false
            panel.ignoresMouseEvents = true
            model?.coordinator.holdMessages(false)
        }
    }

    private func updateMouse() {
        guard let panel, isMonitoringMouse else { return }
        let inside = OverlayLayout.pill(state.pillFrame, in: panel.frame, contains: NSEvent.mouseLocation)
        if state.isHovered != inside { state.isHovered = inside }
        // Le décompte d'un message attend tant que le pointeur est dessus ; la bulle d'enregistrement n'en a pas.
        model?.coordinator.holdMessages(inside && state.mode.isMessage)
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
        moveToTarget()
        updateInteractivity()
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.coordinator.phase
            _ = model.coordinator.notice
            _ = model.coordinator.noticeConfirmsLearning
            _ = model.coordinator.noticeOffersUpdate
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

extension NSScreen {
    /// Numéro de l'écran pour macOS (`CGDirectDisplayID`) : le même quand l'écran change de place, de résolution ou
    /// devient l'écran principal.
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension OverlayScreen {
    /// Écran de macOS tel que la bulle le voit ; nil si son numéro ou son cadre sont illisibles.
    @MainActor init?(_ screen: NSScreen) {
        guard let id = screen.displayID else { return nil }
        self.init(id: id, frame: screen.frame, visible: screen.visibleFrame)
    }
}
