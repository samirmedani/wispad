import AppKit
import SwiftUI
import WispadCore

/// Réglages › Bulle et messages : le style de la bulle, montré en vrai, puis où elle et ses messages apparaissent.
struct OverlayPlacementSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        BubbleLookSection()
        Section {
            SettingToggle(text: SettingsPresentation.avoidInput, isOn: Binding(
                get: { model.settings.overlayPlacement.avoidsInput },
                set: { model.settings.overlayPlacement.avoidsInput = $0; model.saveSettings() }
            ))
            OverlayLayoutEditor()
        } header: {
            SectionTitle(title: SettingsPresentation.placementTitle, summary: SettingsPresentation.placementSummary)
        }
    }
}

/// Style : trois cartes qui montrent la vraie bulle (noir profond, verre transparent, verre dépoli), les réglages du
/// verre, puis un grand aperçu avec un message. Tout suit le réglage en direct, la bulle à l'écran comprise.
struct BubbleLookSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let look = model.bubbleLook
        Section {
            HStack(spacing: 12) {
                ForEach(BubbleLook.allCases) { item in
                    BubbleLookCard(look: item, selected: item == look) { model.setBubbleLook(item) }
                }
            }
            .padding(.vertical, 4)
            SettingRow(text: SettingsPresentation.bubbleSize) {
                // La bulle et l'aperçu suivent le curseur ; le réglage s'enregistre au relâchement.
                Slider(value: Binding(
                    get: { model.settings.bubbleSize },
                    set: { model.settings.bubbleSize = ($0 * 10).rounded() / 10 }
                ), in: AppSettings.bubbleSizeRange, step: 0.1) { editing in
                    if !editing { model.saveSettings() }
                }
                .labelsHidden()
                .frame(width: 170)
                Text(model.settings.bubbleSize, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            if look != .black {
                SettingRow(text: SettingsPresentation.glassAppearance) {
                    Picker(SettingsPresentation.glassAppearance.title, selection: Binding(
                        get: { model.settings.bubbleGlass.appearance },
                        set: { model.setGlassAppearance($0) }
                    )) {
                        ForEach(GlassAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingRow(text: SettingsPresentation.glassIntensity) {
                    // La bulle et l'aperçu suivent le curseur ; le réglage s'enregistre au relâchement.
                    Slider(value: Binding(
                        get: { model.settings.bubbleGlass.intensity },
                        set: { model.settings.bubbleGlass.intensity = $0 }
                    ), in: BubbleGlass.intensityRange) { editing in
                        if !editing { model.saveSettings() }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Text(model.settings.bubbleGlass.intensity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            BubblePreview()
        } header: {
            SectionTitle(title: SettingsPresentation.bubbleStyle.title, summary: SettingsPresentation.bubbleStyle.summary ?? "")
        }
    }
}

/// Une allure de la bulle, montrée en vrai sur une page claire et un fond coloré ; la carte choisie porte la couleur
/// de l'app.
struct BubbleLookCard: View {
    @Environment(AppModel.self) private var model
    var look: BubbleLook
    var selected: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    BubbleScene()
                    BubbleSample()
                }
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .bubbleLook(look, glass: model.settings.bubbleGlass)
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(look.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(look.caption)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Theme.brand : Color.secondary.opacity(0.45))
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            .padding(7)
            .background(shape.fill(selected ? Theme.brand.opacity(0.08) : Theme.subtleFill))
            .overlay(shape.strokeBorder(selected ? Theme.brand : hovered ? Theme.brand.opacity(0.35) : Theme.cardBorder,
                                        lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Theme.quick, value: selected)
        .animation(Theme.hover, value: hovered)
        .accessibilityLabel(look.title)
        .accessibilityHint(look.caption)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Grand aperçu du style choisi : la bulle des mains libres et un message, au-dessus d'une page claire et d'un fond
/// coloré, comme des apps derrière la bulle.
struct BubblePreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            BubbleScene(lines: true)
            VStack(spacing: 16) {
                BubbleSample(orbs: true)
                MessageLine(kind: .success, message: String(localized: "Collé"), countdown: nil, onDismiss: nil)
                    .modifier(BubbleScheme(style: model.settings.bubbleStyle))
            }
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .bubbleLook(model.bubbleLook, glass: model.settings.bubbleGlass)
        .environment(\.bubbleSize, model.settings.bubbleSize)
        .accessibilityHidden(true)
    }
}

/// Fond des aperçus : une page claire à gauche, un dégradé coloré à droite, la bulle à cheval sur les deux.
struct BubbleScene: View {
    var lines = false
    private static let widths: [CGFloat] = [190, 150, 210, 120, 175, 160, 200, 130, 180]

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(white: 0.97)
                VStack(alignment: .leading, spacing: lines ? 8 : 6) {
                    ForEach(Self.widths.indices, id: \.self) { index in
                        Capsule().fill(Color.black.opacity(0.2))
                            .frame(width: Self.widths[index] * (lines ? 1 : 0.5), height: lines ? 6 : 4)
                    }
                }
                .padding(lines ? 16 : 10)
            }
            LinearGradient(colors: [Color(red: 0.13, green: 0.2, blue: 0.48), Color(red: 0.58, green: 0.17, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Bulle de démonstration, rendue comme la vraie (verre compris) dans le style de l'environnement : la pilule et son
/// spectre, et les boutons des mains libres si demandés.
struct BubbleSample: View {
    @Environment(\.bubbleStyle) private var style
    @Environment(\.bubbleSize) private var size
    @Namespace private var glass
    var orbs = false

    private static let levels: [Float] = [0.18, 0.3, 0.5, 0.72, 0.9, 1, 0.86, 0.66, 0.44, 0.26, 0.14]

    var body: some View {
        let pill = PillMetrics.of(style, size: size)
        HStack(spacing: OverlayLayout.orbGap) {
            if orbs {
                orb("xmark", tint: style == .glass ? Color.primary.opacity(0.8) : .white.opacity(0.78), id: "sample-cancel", pill: pill)
            }
            SpectrumBars(levels: Self.levels, color: OverlayStyle.red, scale: pill.spectrumScale)
                .lensHalo()
                .padding(.horizontal, pill.spectrumPadding)
                .frame(height: pill.height)
                .overlayGlass(RoundedRectangle(cornerRadius: pill.cornerRadius, style: .continuous), id: "sample-pill", in: glass)
            if orbs {
                orb("stop.fill", tint: OverlayStyle.red, id: "sample-stop", pill: pill)
            }
        }
        .modifier(BubbleScheme(style: style))
    }

    private func orb(_ symbol: String, tint: Color, id: String, pill: PillMetrics) -> some View {
        Image(systemName: symbol)
            .font(.system(size: pill.symbolSize, weight: .bold))
            .foregroundStyle(tint)
            .lensHalo()
            .frame(width: pill.height, height: pill.height)
            .overlayGlass(Circle(), id: id, in: glass)
    }
}

extension View {
    /// Pose une allure de la bulle (style, verre et son apparence) sur un aperçu.
    func bubbleLook(_ look: BubbleLook, glass: BubbleGlass) -> some View {
        var shown = glass
        if let variant = look.variant { shown.variant = variant }
        return environment(\.bubbleStyle, look.style)
            .environment(\.bubbleGlass, shown)
            .modifier(GlassPreviewAppearance(appearance: look.style == .glass ? glass.appearance : .system))
    }
}


/// L'aperçu prend l'apparence choisie pour le verre ; « Comme l'app » le laisse suivre la fenêtre des Réglages.
struct GlassPreviewAppearance: ViewModifier {
    var appearance: GlassAppearance

    @ViewBuilder func body(content: Content) -> some View {
        switch appearance {
        case .light: content.environment(\.colorScheme, .light)
        case .dark: content.environment(\.colorScheme, .dark)
        case .system: content
        }
    }
}

extension OverlayRole {
    var label: String {
        switch self {
        case .dictation: return String(localized: "Dictée")
        case .alerts: return String(localized: "Alertes de collage")
        case .info: return String(localized: "Messages")
        }
    }

    var symbol: String {
        switch self {
        case .dictation: return "waveform"
        case .alerts: return "doc.on.clipboard"
        case .info: return "text.bubble"
        }
    }

    /// Taille réelle à l'écran, réduite à l'échelle du schéma.
    @MainActor var screenSize: CGSize {
        switch self {
        case .dictation: return CGSize(width: OverlayLayout.spectrumPillWidth, height: OverlayLayout.pillHeight)
        case .alerts: return OverlayLayout.contentSize(for: .failure(""), hasReadyText: true)
        case .info: return CGSize(width: 300, height: OverlayLayout.messageHeight)
        }
    }
}

/// Schéma de l'écran : on fait glisser chaque bulle à main levée ; la grille aimante légèrement.
struct OverlayLayoutEditor: View {
    @Environment(AppModel.self) private var model
    @State private var selected: OverlayRole = .alerts
    @State private var dragging: (role: OverlayRole, anchor: OverlayAnchor)?
    @State private var grab: CGSize = .zero

    private static let columns = 12
    private static let rows = 8
    private static let menuBar: CGFloat = 9
    private static let dockBand: CGFloat = 16
    private static let edge: CGFloat = 4
    private static let space = "wispad-overlay-layout"

    /// Proportions de l'écran principal, zone utile comprise.
    private var screen: CGRect { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Position à l'écran")
                Text("Fais glisser chaque bulle : elle apparaîtra à cet endroit. Double-clic : place par défaut.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                canvas(size: proxy.size)
            }
            .aspectRatio(screen.width / max(1, screen.height), contentMode: .fit)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Label(selected.label, systemImage: selected.symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(anchorDescription(selected))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Aperçu à l'écran") { model.coordinator.previewPlacement(selected) }
                    .hoverFeedback()
                Button("Par défaut") { setAnchor(nil, for: selected) }
                    .disabled(placement.anchor(for: selected) == nil)
                    .hoverFeedback()
                Button("Tout réinitialiser") {
                    OverlayRole.allCases.forEach { setAnchor(nil, for: $0) }
                }
                .disabled(placement.anchors.isEmpty)
                .hoverFeedback()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var placement: OverlayPlacement { model.settings.overlayPlacement }

    private func canvas(size: CGSize) -> some View {
        let scale = size.width / max(1, screen.width)
        let frames = tokenFrames(in: size, scale: scale)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
            grid(size: size)
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: size.width, height: Self.menuBar)
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: size.width * 0.42, height: Self.dockBand - 6)
                .position(x: size.width / 2, y: size.height - Self.dockBand / 2)
            ForEach(OverlayRole.allCases, id: \.self) { role in
                if let frame = frames[role] {
                    token(role, frame: frame, size: size, scale: scale)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .coordinateSpace(.named(Self.space))
        .environment(\.colorScheme, .dark)
    }

    private func grid(size: CGSize) -> some View {
        Canvas { context, size in
            for column in 1..<Self.columns {
                let x = size.width * CGFloat(column) / CGFloat(Self.columns)
                var path = Path()
                path.move(to: CGPoint(x: x, y: Self.menuBar))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.white.opacity(column * 2 == Self.columns ? 0.16 : 0.06)), lineWidth: 1)
            }
            for row in 1..<Self.rows {
                let y = Self.menuBar + (size.height - Self.menuBar) * CGFloat(row) / CGFloat(Self.rows)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private func token(_ role: OverlayRole, frame: CGRect, size: CGSize, scale: CGFloat) -> some View {
        let isSelected = role == selected
        return HStack(spacing: 4) {
            Image(systemName: role.symbol)
            Text(role.label).lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(width: frame.width, height: frame.height)
        .background(RoundedRectangle(cornerRadius: min(frame.height / 2, 8), style: .continuous).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: min(frame.height / 2, 8), style: .continuous)
            .strokeBorder(isSelected ? Theme.brand : Color.white.opacity(0.28), lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        .position(x: frame.midX, y: frame.midY)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    if dragging?.role != role {
                        selected = role
                        grab = CGSize(width: value.startLocation.x - frame.midX, height: value.startLocation.y - frame.maxY)
                    }
                    let center = CGPoint(x: value.location.x - grab.width, y: value.location.y - grab.height)
                    dragging = (role, anchor(bottomCenter: center, tokenSize: frame.size, in: size))
                }
                .onEnded { _ in
                    if let dragging { setAnchor(dragging.anchor, for: dragging.role) }
                    dragging = nil
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { setAnchor(nil, for: role) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(role.label)
        .accessibilityValue(anchorDescription(role))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAdjustableAction { direction in
            let current = placement.anchor(for: role) ?? OverlayAnchor(x: 0.5, y: 0)
            let step = direction == .increment ? 0.1 : -0.1
            setAnchor(OverlayAnchor(x: current.x, y: current.y + step), for: role)
        }
        .help(role.label)
    }

    /// Cadres des bulles sur le schéma. Plusieurs bulles à la même place sont empilées pour rester saisissables.
    private func tokenFrames(in size: CGSize, scale: CGFloat) -> [OverlayRole: CGRect] {
        var frames: [OverlayRole: CGRect] = [:]
        var placed: [(OverlayAnchor, CGRect)] = []
        for role in [OverlayRole.dictation, .info, .alerts] {
            let anchor = dragging?.role == role ? dragging!.anchor : (placement.anchor(for: role) ?? OverlayAnchor(x: 0.5, y: 0))
            let tokenSize = CGSize(width: max(64, role.screenSize.width * scale), height: max(20, role.screenSize.height * scale))
            var frame = rect(for: anchor, tokenSize: tokenSize, in: size)
            for (other, otherFrame) in placed where other == anchor && frame.intersects(otherFrame) {
                frame.origin.y = otherFrame.minY - frame.height - 3
            }
            placed.append((anchor, frame))
            frames[role] = frame
        }
        return frames
    }

    private func usable(in size: CGSize) -> CGRect {
        CGRect(x: Self.edge, y: Self.menuBar + Self.edge,
               width: size.width - 2 * Self.edge, height: size.height - Self.menuBar - Self.dockBand - 2 * Self.edge)
    }

    private func rect(for anchor: OverlayAnchor, tokenSize: CGSize, in size: CGSize) -> CGRect {
        let area = usable(in: size)
        let x = area.minX + tokenSize.width / 2 + max(0, area.width - tokenSize.width) * anchor.x
        let bottom = area.maxY - max(0, area.height - tokenSize.height) * anchor.y
        return CGRect(x: x - tokenSize.width / 2, y: bottom - tokenSize.height, width: tokenSize.width, height: tokenSize.height)
    }

    /// Position (fractions) d'un bas-centre sur le schéma, aimantée au centre, aux bords et à la grille.
    private func anchor(bottomCenter: CGPoint, tokenSize: CGSize, in size: CGSize) -> OverlayAnchor {
        let area = usable(in: size)
        let spanX = max(1, area.width - tokenSize.width)
        let spanY = max(1, area.height - tokenSize.height)
        var x = (bottomCenter.x - area.minX - tokenSize.width / 2) / spanX
        var y = (area.maxY - bottomCenter.y) / spanY
        x = Self.snap(min(1, max(0, x)), steps: Self.columns)
        y = Self.snap(min(1, max(0, y)), steps: Self.rows)
        return OverlayAnchor(x: Double(x), y: Double(y))
    }

    private static func snap(_ value: CGFloat, steps: Int) -> CGFloat {
        let nearest = (value * CGFloat(steps)).rounded() / CGFloat(steps)
        return abs(nearest - value) < 0.018 ? nearest : value
    }

    private func setAnchor(_ anchor: OverlayAnchor?, for role: OverlayRole) {
        model.settings.overlayPlacement.setAnchor(anchor, for: role)
        model.saveSettings()
    }

    private func anchorDescription(_ role: OverlayRole) -> String {
        guard (dragging?.role == role ? dragging?.anchor : nil) ?? placement.anchor(for: role) != nil else {
            return String(localized: "Place par défaut")
        }
        return String(localized: "Position personnalisée")
    }
}

