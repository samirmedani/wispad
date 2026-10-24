import SwiftUI
import WispadCore

/// Le cerveau : les mots fréquents en 3D, reliés quand ils reviennent dans les mêmes dictées, colorés par famille.
/// Glisser pour tourner, pincer ou « + / − » pour zoomer, cliquer un mot pour voir ses voisins.
struct BrainCard: View {
    var graph: WordGraph
    @Binding var selected: Int?
    /// Masquer un mot (cerveau par mots) ; nil pour les sujets.
    var hide: ((String) -> Void)?
    var caption: String
    var emptyText: String
    var modePicker: AnyView?
    var accessory: AnyView?

    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var yaw = 0.4
    @State private var pitch = -0.25
    @State private var zoom = 1.0
    @State private var dragStart: (yaw: Double, pitch: Double)?
    @State private var pinchStart: Double?
    @State private var spinning = true
    @State private var spinOrigin = Date()

    static let palette: [Color] = [Theme.brand, .blue, .green, .orange, .purple, .teal, .pink, .yellow, .indigo, .mint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: String(localized: "Ton cerveau")) {
                HStack(spacing: 4) {
                    if let modePicker { modePicker.padding(.trailing, 8) }
                    zoomButton("minus.magnifyingglass", String(localized: "Dézoomer")) { zoom = max(0.6, zoom / 1.2) }
                    zoomButton("plus.magnifyingglass", String(localized: "Zoomer")) { zoom = min(2.6, zoom * 1.2) }
                    zoomButton("arrow.counterclockwise", String(localized: "Recentrer")) { reset() }
                }
            }
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let accessory { accessory }
            if graph.nodes.count < 3 {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: !spinning || reduceMotion)) { timeline in
                        let angle = currentYaw(at: timeline.date)
                        GeometryReader { proxy in
                            let projected = project(size: proxy.size, yaw: angle)
                            Canvas { context, _ in draw(projected, in: &context) }
                                .contentShape(Rectangle())
                                .gesture(rotate(at: timeline.date))
                                .simultaneousGesture(pinch)
                                .gesture(SpatialTapGesture().onEnded { tap in select(at: tap.location, in: projected) })
                        }
                    }
                    .frame(height: 380)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill.opacity(0.6)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel(String(localized: "Nuage 3D de tes mots fréquents"))
                    details
                        .frame(width: 210, alignment: .topLeading)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    // MARK: Détail

    @ViewBuilder
    private var details: some View {
        if let id = selected, graph.nodes.indices.contains(id) {
            let node = graph.nodes[id]
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(color(node.cluster)).frame(width: 9, height: 9)
                    Text(node.word).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                }
                Text(node.count == 1 ? String(localized: "Dans 1 dictée") : String(localized: "Dans \(node.count) dictées"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if node.isCategory {
                    Text("Catégorie").font(.system(size: 11, weight: .semibold)).foregroundStyle(color(node.cluster))
                }
                if !node.details.isEmpty {
                    Text(node.details.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let neighbors = graph.neighbors(of: id)
                if neighbors.isEmpty {
                    Text("Aucun mot souvent dit avec lui.").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    Text("Souvent avec").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    FlowLayout(spacing: 5) {
                        ForEach(neighbors.prefix(8), id: \.node.id) { neighbor in
                            Button {
                                selected = neighbor.node.id
                            } label: {
                                Text(neighbor.node.word)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(color(neighbor.node.cluster).opacity(0.18)))
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Ensemble dans \(neighbor.weight) dictées"))
                        }
                    }
                }
                if let hide {
                    Button(String(localized: "Masquer ce mot")) { hide(node.word) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .padding(.top, 4)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "Glisse pour le faire tourner"), systemImage: "hand.draw")
                Label(String(localized: "Pince ou + / − pour zoomer"), systemImage: "plus.magnifyingglass")
                Label(String(localized: "Clique un mot pour voir ses voisins"), systemImage: "cursorarrow.click")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    private func zoomButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }

    private func color(_ cluster: Int) -> Color { Self.palette[cluster % Self.palette.count] }

    // MARK: Projection

    struct Projected {
        var node: WordGraph.Node
        var point: CGPoint
        /// Profondeur : -1 devant, 1 derrière.
        var depth: Double
        var scale: Double
    }

    private func currentYaw(at date: Date) -> Double {
        spinning && !reduceMotion ? yaw + date.timeIntervalSince(spinOrigin) * 0.18 : yaw
    }

    private func project(size: CGSize, yaw: Double) -> [Projected] {
        let radius = min(size.width, size.height) * 0.42 * zoom
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let (cy, sy, cp, sp) = (cos(yaw), sin(yaw), cos(pitch), sin(pitch))
        return graph.nodes.map { node in
            let x1 = node.x * cy + node.z * sy
            let z1 = -node.x * sy + node.z * cy
            let y2 = node.y * cp - z1 * sp
            let z2 = node.y * sp + z1 * cp
            let perspective = 3 / (3 + z2)
            return Projected(node: node,
                             point: CGPoint(x: center.x + x1 * radius * perspective, y: center.y - y2 * radius * perspective),
                             depth: z2, scale: perspective)
        }
    }

    private func draw(_ projected: [Projected], in context: inout GraphicsContext) {
        let maxCount = Double(graph.nodes.map(\.count).max() ?? 1)
        let maxWeight = Double(graph.edges.map(\.weight).max() ?? 1)
        let focus: Set<Int> = selected.map { id in Set([id] + graph.neighbors(of: id).map(\.node.id)) } ?? []
        for edge in graph.edges {
            let a = projected[edge.a], b = projected[edge.b]
            let touches = selected == edge.a || selected == edge.b
            let fade = (2 - (a.depth + b.depth) / 2) / 3
            var path = Path()
            path.move(to: a.point)
            path.addLine(to: b.point)
            let base = touches ? Theme.brand : color(a.node.cluster == b.node.cluster ? a.node.cluster : 99)
            let alpha = selected == nil ? 0.15 + 0.35 * Double(edge.weight) / maxWeight : (touches ? 0.85 : 0.05)
            context.stroke(path, with: .color(base.opacity(alpha * fade)),
                           lineWidth: touches ? 2 : 0.6 + 1.6 * Double(edge.weight) / maxWeight)
        }
        for item in projected.sorted(by: { $0.depth > $1.depth }) {
            let weight = (Double(item.node.count) / maxCount).squareRoot()
            let dimmed = selected != nil && !focus.contains(item.node.id)
            let fade = (dimmed ? 0.18 : 1) * (0.45 + 0.55 * (1 - item.depth) / 2)
            let radius = (item.node.isCategory ? 10 + 6 * weight : 3 + 7 * weight) * item.scale
            let dot = CGRect(x: item.point.x - radius, y: item.point.y - radius, width: radius * 2, height: radius * 2)
            let tint = color(item.node.cluster)
            if selected == item.node.id {
                context.fill(Path(ellipseIn: dot.insetBy(dx: -5, dy: -5)), with: .color(tint.opacity(0.25)))
            }
            context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(fade)))
            if item.node.isCategory {
                context.stroke(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)), with: .color(tint.opacity(fade * 0.6)), lineWidth: 1.5)
            }
        }
        // Étiquettes, du premier plan vers le fond : un mot dont l'étiquette chevaucherait une étiquette déjà posée
        // reste sans texte (il se lit en tournant le nuage ou en le choisissant).
        var placed: [CGRect] = []
        for item in projected.sorted(by: { $0.node.isCategory != $1.node.isCategory ? $0.node.isCategory : $0.depth < $1.depth }) {
            let weight = (Double(item.node.count) / maxCount).squareRoot()
            let isFocus = selected != nil && focus.contains(item.node.id)
            guard selected == nil || isFocus else { continue }
            let fade = 0.45 + 0.55 * (1 - item.depth) / 2
            let radius = (item.node.isCategory ? 10 + 6 * weight : 3 + 7 * weight) * item.scale
            let label = context.resolve(Text(item.node.word)
                .font(.system(size: (item.node.isCategory ? 14 + 3 * weight : 10 + 5 * weight) * item.scale,
                              weight: item.node.isCategory ? .bold : weight > 0.6 || selected == item.node.id ? .semibold : .medium))
                .foregroundStyle(Color.primary.opacity(fade)))
            let size = label.measure(in: CGSize(width: 300, height: 40))
            let frame = CGRect(x: item.point.x - size.width / 2, y: item.point.y - radius - 2 - size.height,
                               width: size.width, height: size.height).insetBy(dx: -2, dy: -1)
            guard selected == item.node.id || !placed.contains(where: { $0.intersects(frame) }) else { continue }
            placed.append(frame)
            context.draw(label, at: CGPoint(x: item.point.x, y: item.point.y - radius - 2), anchor: .bottom)
        }
    }

    // MARK: Gestes

    private func rotate(at date: Date) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil {
                    yaw = currentYaw(at: Date())
                    spinning = false
                    dragStart = (yaw, pitch)
                }
                guard let start = dragStart else { return }
                yaw = start.yaw + value.translation.width / 160
                pitch = min(1.3, max(-1.3, start.pitch + value.translation.height / 160))
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = zoom }
                zoom = min(2.6, max(0.6, (pinchStart ?? 1) * value.magnification))
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func select(at location: CGPoint, in projected: [Projected]) {
        let hit = projected
            .filter { hypot($0.point.x - location.x, $0.point.y - location.y) < 22 }
            .min { $0.depth < $1.depth }
        selected = hit?.node.id == selected ? nil : hit?.node.id
    }

    private func reset() {
        yaw = 0.4
        pitch = -0.25
        zoom = 1
        selected = nil
        spinOrigin = Date()
        spinning = true
    }
}
