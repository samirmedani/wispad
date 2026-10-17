import AppKit
import SwiftUI
import WispadCore

/// Réglages › Bulle et messages : ne pas couvrir le champ, et position de chaque affichage sur un écran quadrillé.
struct OverlayPlacementSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            SettingRow(text: SettingsPresentation.bubbleStyle) {
                Picker(SettingsPresentation.bubbleStyle.title, selection: Binding(
                    get: { model.settings.bubbleStyle },
                    set: { model.setBubbleStyle($0) }
                )) {
                    ForEach(BubbleStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingToggle(text: SettingsPresentation.avoidInput, isOn: Binding(
                get: { model.settings.overlayPlacement.avoidsInput },
                set: { model.settings.overlayPlacement.avoidsInput = $0; model.saveSettings() }
            ))
            OverlayLayoutEditor()
        } header: {
            SectionTitle(title: SettingsPresentation.overlayTitle, summary: SettingsPresentation.overlaySummary)
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
