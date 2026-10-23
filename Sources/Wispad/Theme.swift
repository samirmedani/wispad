import SwiftUI
import AppKit
import WispadCore

/// Jetons de design de la fenêtre principale : une seule source pour les couleurs, rayons et animations.
enum Theme {
    /// Même rouge que la bulle de dictée.
    static let brand = Color(red: 1, green: 0.23, blue: 0.21)
    static let canvas = Color.adaptive(light: NSColor(white: 0.965, alpha: 1), dark: NSColor(white: 0.105, alpha: 1))
    static let card = Color.adaptive(light: .white, dark: NSColor(white: 0.15, alpha: 1))
    static let cardBorder = Color.adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.075))
    static let subtleFill = Color.adaptive(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07))
    static let raised = Color.adaptive(light: .white, dark: NSColor(white: 0.28, alpha: 1))
    static let cardShadow = Color.adaptive(light: NSColor(white: 0, alpha: 0.05), dark: .clear)
    /// Touches dessinées : face à peine dégradée, contour fin et lèvre plus sombre en bas, pour un léger relief.
    static let keyTop = Color.adaptive(light: .white, dark: NSColor(white: 0.31, alpha: 1))
    static let keyBottom = Color.adaptive(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.255, alpha: 1))
    static let keyBorder = Color.adaptive(light: NSColor(white: 0, alpha: 0.13), dark: NSColor(white: 1, alpha: 0.09))
    static let keyEdge = Color.adaptive(light: NSColor(white: 0, alpha: 0.22), dark: NSColor(white: 0, alpha: 0.6))

    static let radius: CGFloat = 14
    static let sidebarWidth: CGFloat = 220
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.14)
    static let hover = Animation.easeOut(duration: 0.18)
    static let privacy = Animation.easeInOut(duration: 0.24)
}

private struct InteractionPreviewHoverKey: EnvironmentKey {
    static let defaultValue = false
}

private struct InteractionPreviewReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Survol déterministe pour les captures hors écran ; les vues réelles gardent leur état local.
    var interactionPreviewHover: Bool {
        get { self[InteractionPreviewHoverKey.self] }
        set { self[InteractionPreviewHoverKey.self] = newValue }
    }

    var interactionPreviewReduceMotion: Bool? {
        get { self[InteractionPreviewReduceMotionKey.self] }
        set { self[InteractionPreviewReduceMotionKey.self] = newValue }
    }

    /// Respecte le réglage macOS ; seul un aperçu peut fournir une valeur déterministe.
    var interactionReduceMotion: Bool { interactionPreviewReduceMotion ?? accessibilityReduceMotion }
}

enum HoverTreatment {
    case quiet, icon, filled, row

    fileprivate var radius: CGFloat { self == .icon ? 9 : 10 }
    fileprivate var hoverScale: CGFloat {
        switch self {
        case .quiet: 1.025
        case .icon: 1.06
        case .filled: 1.025
        case .row: 1.006
        }
    }
}

/// Les transformations restent visuelles : la taille et la zone du bouton ne changent pas au survol.
struct HoverButtonStyle: ButtonStyle {
    var treatment: HoverTreatment
    var tint: Color

    init(treatment: HoverTreatment = .quiet, tint: Color = Theme.brand) {
        self.treatment = treatment
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, treatment: treatment, tint: tint)
    }
}

private struct HoverButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var treatment: HoverTreatment
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @Environment(\.interactionPreviewHover) private var previewHover
    @State private var hovering = false

    private var highlighted: Bool { isEnabled && (hovering || previewHover) }
    private var pressed: Bool { isEnabled && configuration.isPressed }
    private var scale: CGFloat {
        guard isEnabled, !reduceMotion else { return 1 }
        if pressed { return treatment == .row ? 0.985 : 0.96 }
        return highlighted ? treatment.hoverScale : 1
    }

    private var fill: Color {
        if treatment == .filled { return tint.opacity(pressed ? 0.78 : highlighted ? 0.9 : 1) }
        if treatment == .row { return .clear }
        return tint.opacity(pressed ? 0.14 : highlighted ? 0.085 : 0)
    }

    @ViewBuilder private var label: some View {
        if treatment == .filled {
            configuration.label.foregroundStyle(.white)
        } else {
            configuration.label
        }
    }

    var body: some View {
        label
            .padding(.horizontal, treatment == .filled ? 13 : 0)
            .padding(.vertical, treatment == .filled ? 7 : 0)
            .background {
                if treatment != .row {
                    RoundedRectangle(cornerRadius: treatment.radius, style: .continuous)
                        .fill(fill)
                        .shadow(color: highlighted ? tint.opacity(0.12) : .clear, radius: 7, y: 1)
                }
            }
            .scaleEffect(scale)
            .contentShape(RoundedRectangle(cornerRadius: treatment.radius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : Theme.hover, value: highlighted)
            .animation(reduceMotion ? nil : Theme.hover, value: pressed)
    }
}

private struct HoverFeedback: ViewModifier {
    var tint: Color
    var scale: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @Environment(\.interactionPreviewHover) private var previewHover
    @State private var hovering = false

    private var highlighted: Bool { isEnabled && (hovering || previewHover) }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(highlighted ? 0.045 : 0))
                    .shadow(color: highlighted ? tint.opacity(0.12) : .clear, radius: 7)
            }
            .scaleEffect(highlighted && !reduceMotion ? scale : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : Theme.hover, value: highlighted)
    }
}

extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    /// Réaction légère pour les liens et contrôles natifs, sans remplacer leur style de bouton.
    func hoverFeedback(tint: Color = Theme.brand, scale: CGFloat = 1.015) -> some View {
        modifier(HoverFeedback(tint: tint, scale: scale))
    }

    /// Surface de carte : fond, filet et ombre légère en mode clair.
    func card(radius: CGFloat = Theme.radius) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.card)
                .shadow(color: Theme.cardShadow, radius: 8, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 1)
        }
    }
}

/// Fenêtre principale : contenu sous la barre de titre, feux tricolores posés sur la barre latérale.
@MainActor
enum MainWindow {
    /// Pendant l'ouverture seulement : la fenêtre vient sur le bureau où l'on se trouve, même par-dessus une app
    /// en plein écran ; sinon elle apparaît sur un autre bureau et le menu semble ne rien faire.
    static let openingBehavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    /// Une fois affichée : sans `.moveToActiveSpace`, qui la détache de son bureau et la déplace à chaque
    /// activation de Wispad.
    static let settledBehavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]

    /// La fenêtre doit-elle être amenée sur le bureau actif ? Seulement si elle n'y est pas déjà visible.
    static func needsMoveToActiveSpace(isVisible: Bool, isOnActiveSpace: Bool) -> Bool {
        !isVisible || !isOnActiveSpace
    }

    /// Montre la fenêtre sur le bureau actif, puis lui rend le comportement d'une fenêtre ordinaire.
    static func bringToFront(_ window: NSWindow) {
        let moves = needsMoveToActiveSpace(isVisible: window.isVisible, isOnActiveSpace: window.isOnActiveSpace)
        if moves { window.collectionBehavior = openingBehavior }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Une app de barre des menus n'est pas toujours activée à temps : la fenêtre passe devant quand même.
        window.orderFrontRegardless()
        if moves { window.collectionBehavior = settledBehavior }
    }

    static func make(model: AppModel, offscreen: Bool = false, historyRowDidRender: HistoryRowRenderCallback? = nil,
                     interactionPreviewHover: Bool = false, reduceMotion: Bool? = nil, systemGlass: Bool = true) -> NSWindow {
        let window = (offscreen ? OffscreenWindow.self : NSWindow.self).init(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Wispad"
        // Fenêtre ordinaire : elle reste sur son bureau quand on passe à une autre app ou à un autre bureau.
        window.collectionBehavior = settledBehavior
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: RootView()
            .environment(model)
            .environment(\.historyRowDidRender, historyRowDidRender)
            .environment(\.interactionPreviewHover, interactionPreviewHover)
            .environment(\.interactionPreviewReduceMotion, reduceMotion)
            // Captures hors écran : la capture d'une fenêtre ne dessine pas le Liquid Glass (zone blanche), son repli si.
            .environment(\.overlayGlass, systemGlass))
        window.minSize = NSSize(width: 820, height: 540)
        if offscreen {
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        } else {
            window.center()
        }
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Fenêtre que macOS ne ramène jamais à l'écran : sert aux captures de l'aperçu sans rien afficher.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Matériau translucide AppKit (barre latérale, bulles).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// En-tête commun : grand titre, sous-titre, et contrôles à droite.
struct ScreenHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Page défilante centrée, largeur de lecture bornée.
struct ScreenScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 14)
            .padding(.bottom, 32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// Sélecteur compact à pastille glissante.
struct PillPicker<Value: Hashable>: View {
    var options: [Value]
    @Binding var selection: Value
    var title: (Value) -> String
    @Namespace private var pill
    @Environment(\.interactionReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { item in
                let selected = item == selection
                Button {
                    withAnimation(reduceMotion ? nil : Theme.spring) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.raised)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(HoverButtonStyle())
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.subtleFill))
        .fixedSize()
    }
}

extension PillPicker where Value == StatsPeriod {
    init(selection: Binding<StatsPeriod>) {
        self.init(options: StatsPeriod.allCases, selection: selection, title: { $0.label })
    }
}

/// Pastille d'icône teintée.
struct IconBadge: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// Chiffre clé avec transition numérique.
struct MetricTile: View {
    var symbol: String
    var tint: Color
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconBadge(symbol: symbol, tint: tint, size: 24)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}

/// Chiffres clés sur une ligne si la largeur le permet, sinon sur deux colonnes.
struct MetricGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) { content }
        }
    }
}

/// Titre de carte avec action facultative à droite.
struct CardTitle<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            trailing
        }
    }
}

extension CardTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Petite étiquette colorée (statut).
struct StatusChip: View {
    var text: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// Touche de clavier dessinée.
struct KeyCap: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.raised)
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            }
    }
}

/// Bouton icône discret avec survol.
struct HoverIconButton: View {
    var symbol: String
    var help: String
    var tint: Color = .secondary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(treatment: .icon, tint: tint == .secondary ? .primary : tint))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// État vide centré.
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

/// Disposition en lignes qui passent à la ligne (puces du dictionnaire).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Icônes des applications cibles, mises en cache en mémoire, une par taille affichée.
/// Une app introuvable est retenue aussi : sans cela, chaque passage d'une ligne de l'historique
/// relancerait une recherche Launch Services pendant le défilement.
@MainActor
enum AppIcons {
    private struct Key: Hashable {
        var bundleID: String
        var size: CGFloat
        var dark: Bool
    }

    private static var originals: [String: NSImage?] = [:]
    private static var sized: [Key: NSImage] = [:]

    static func icon(bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = originals[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        originals[bundleID] = .some(image)
        return image
    }

    /// L'icône déjà réduite à sa taille d'affichage (rendue en 2x), dans l'apparence claire ou sombre de la vue :
    /// l'image système compte de nombreuses représentations jusqu'au 1024 px, coûteuses à rééchantillonner
    /// à chaque image.
    static func icon(bundleID: String?, size: CGFloat, dark: Bool) -> NSImage? {
        guard let bundleID, let original = icon(bundleID: bundleID) else { return nil }
        let key = Key(bundleID: bundleID, size: size, dark: dark)
        if let cached = sized[key] { return cached }
        var image: NSImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = thumbnail(of: original, side: size)
        }
        let result = image ?? original
        sized[key] = result
        return result
    }

    private static func thumbnail(of image: NSImage, side: CGFloat) -> NSImage? {
        let scale: CGFloat = 2
        let pixels = Int((side * scale).rounded(.up))
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB), let bitmap = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        bitmap.interpolationQuality = .high
        bitmap.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = bitmap.makeImage() else { return nil }
        return NSImage(cgImage: rendered, size: NSSize(width: side, height: side))
    }
}

struct AppIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    var bundleID: String?
    var size: CGFloat = 18

    var body: some View {
        if let image = AppIcons.icon(bundleID: bundleID, size: size, dark: colorScheme == .dark) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}
