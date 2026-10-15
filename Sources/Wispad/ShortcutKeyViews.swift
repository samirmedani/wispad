import SwiftUI
import WispadCore

/// Une touche d'un raccourci, comme sur un clavier Mac : symbole (⌃) et nom (« control »), ou le seul nom d'une
/// lettre (« V »). `keyCode` donne sa place sur le schéma du clavier.
struct ShortcutKey: Hashable {
    var keyCode: Int
    var symbol: String?
    var systemImage: String?
    var name: String

    init(keyCode: Int, symbol: String? = nil, systemImage: String? = nil, name: String) {
        self.keyCode = keyCode
        self.symbol = symbol
        self.systemImage = systemImage
        self.name = name
    }

    /// Lettre, chiffre ou flèche : un seul caractère, écrit en grand au centre de la touche.
    var isGlyph: Bool { symbol == nil && systemImage == nil && name.count == 1 }

    /// Inscription réduite, quand la place manque : le symbole (« ⌃ »), sinon le nom (« fn », « V »).
    var compactLabel: String { symbol ?? name }
}

/// Touches à dessiner pour un raccourci, dans l'ordre de macOS (fn ⌃ ⌥ ⇧ ⌘, puis la touche).
enum ShortcutKeys {
    /// Modificateurs de gauche : ceux que l'on allume sur le schéma.
    static let function = ShortcutKey(keyCode: ChordMatcher.functionKeyCode, systemImage: "globe", name: "fn")
    static let control = ShortcutKey(keyCode: 59, symbol: "⌃", name: "control")
    static let option = ShortcutKey(keyCode: 58, symbol: "⌥", name: "option")
    static let shift = ShortcutKey(keyCode: 56, symbol: "⇧", name: "shift")
    static let command = ShortcutKey(keyCode: 55, symbol: "⌘", name: "command")

    /// Raccourci de dictée : fn seule, ou modificateurs (masques `ModifierMask`) puis une touche.
    /// `name` : nom de la touche, celui de la disposition active par défaut (fil principal).
    @MainActor static func dictation(keyCode: Int, modifiers: UInt64,
                          name: @MainActor (Int) -> String = KeyLabels.name(for:)) -> [ShortcutKey] {
        if keyCode == ChordMatcher.functionKeyCode { return [function] }
        var keys = modifierKeys(modifiers)
        // Flèches et touches F portent fn dans chaque frappe : ce n'est pas une touche de plus à enfoncer.
        if modifiers & ModifierMask.function != 0, !PasteShortcutRules.carriesFunctionFlag(keyCode) {
            keys.insert(function, at: 0)
        }
        return keys + [key(keyCode, name: name)]
    }

    /// « Coller la dernière dictée » : modificateurs puis touche, jamais fn.
    @MainActor static func paste(_ shortcut: PasteShortcut,
                                 name: @MainActor (Int) -> String = KeyLabels.name(for:)) -> [ShortcutKey] {
        modifierKeys(shortcut.modifiers) + [key(shortcut.keyCode, name: name)]
    }

    /// Lecture par VoiceOver : « control option V ».
    static func spoken(_ keys: [ShortcutKey]) -> String {
        keys.map(\.name).joined(separator: " ")
    }

    private static func modifierKeys(_ flags: UInt64) -> [ShortcutKey] {
        var keys: [ShortcutKey] = []
        if flags & ModifierMask.control != 0 { keys.append(control) }
        if flags & ModifierMask.option != 0 { keys.append(option) }
        if flags & ModifierMask.shift != 0 { keys.append(shift) }
        if flags & ModifierMask.command != 0 { keys.append(command) }
        return keys
    }

    @MainActor private static func key(_ keyCode: Int, name: @MainActor (Int) -> String) -> ShortcutKey {
        let symbols: [Int: String] = [36: "↩", 48: "⇥", 51: "⌫"]
        return ShortcutKey(keyCode: keyCode, symbol: symbols[keyCode], name: name(keyCode))
    }
}

/// Tailles des touches dessinées ; dans une taille, toutes les touches ont la même hauteur. `regular` dans une
/// rangée de réglage, un popover ou une carte ; `large` pour le test de la touche du premier lancement.
enum KeyCapSize {
    case regular, large

    var height: CGFloat { self == .large ? 32 : 22 }
    /// Corps du symbole et du nom.
    var font: CGFloat { self == .large ? 14 : 11 }
    /// Une lettre seule : un point de plus, en demi-gras.
    var glyphFont: CGFloat { self == .large ? 15 : 12 }
    var radius: CGFloat { self == .large ? 8 : 5.5 }
    var padding: CGFloat { self == .large ? 9 : 5.5 }
    /// Entre le symbole et le nom d'une touche.
    var gap: CGFloat { self == .large ? 4 : 3 }
    /// Espace de part et d'autre du « + » qui sépare deux touches.
    var spacing: CGFloat { self == .large ? 5 : 3.5 }
}

/// Une touche dessinée, compacte : symbole et nom sur une même ligne (« ⌃ control », « 🌐 fn »), ou la seule lettre
/// (« V »). Léger relief : face à peine dégradée, contour fin, lèvre plus sombre en bas. `compact` n'écrit que
/// `compactLabel` ; `tint` colore la touche (touche reçue, par exemple).
struct ShortcutKeyCap: View {
    var key: ShortcutKey
    var size: KeyCapSize = .regular
    var compact = false
    var tint: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        let ink: Color = tint ?? Color.primary
        let border: Color = tint ?? Theme.keyBorder
        let borderWidth: CGFloat = tint == nil ? 0.5 : 1
        inscription
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size.padding)
            .frame(minWidth: size.height)
            .frame(height: size.height)
            .background { face(shape) }
            .overlay { shape.strokeBorder(border, lineWidth: borderWidth) }
    }

    @ViewBuilder private var inscription: some View {
        if let text = singleText {
            Text(text)
                .font(singleFont(text))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: size.gap) {
                symbol
                Text(key.name)
                    .font(.system(size: size.font, weight: .medium))
            }
        }
    }

    @ViewBuilder private var symbol: some View {
        let ink: Color = tint ?? Color.secondary
        if let systemImage = key.systemImage {
            Image(systemName: systemImage)
                .font(.system(size: size.font, weight: .regular))
                .imageScale(.small)
                .foregroundStyle(ink)
        } else if let symbol = key.symbol {
            Text(symbol)
                .font(.system(size: size.font, weight: .medium))
                .foregroundStyle(ink)
        }
    }

    /// Une seule inscription : touche réduite, ou touche sans symbole (lettre, « espace »).
    private var singleText: String? {
        if compact { return key.compactLabel }
        return key.symbol == nil && key.systemImage == nil ? key.name : nil
    }

    /// Un seul caractère (« V », « ⌃ ») en demi-gras d'un point plus grand ; un mot (« espace ») comme un nom.
    private func singleFont(_ text: String) -> Font {
        if text.count == 1 { return .system(size: size.glyphFont, weight: .semibold) }
        return .system(size: size.font, weight: .medium)
    }

    @ViewBuilder private func face(_ shape: RoundedRectangle) -> some View {
        if let tint {
            shape.fill(tint.opacity(0.14))
        } else {
            let gradient = LinearGradient(colors: [Theme.keyTop, Theme.keyBottom], startPoint: .top, endPoint: .bottom)
            shape
                .fill(gradient)
                .shadow(color: Theme.keyEdge, radius: 0, x: 0, y: 1)
        }
    }
}

/// Les touches d'un raccourci séparées par un petit « + » discret (« control + option + V »), lues d'un bloc par
/// VoiceOver. `compact` n'écrit que les symboles (« ⌃ + ⌥ + V »), quand la place manque.
struct ShortcutKeyCaps: View {
    var keys: [ShortcutKey]
    var size: KeyCapSize = .regular
    var compact = false
    var tint: Color?

    var body: some View {
        HStack(spacing: size.spacing) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                cell(index, key)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShortcutKeys.spoken(keys))
    }

    /// Une touche, précédée d'un « + » sauf la première.
    @ViewBuilder private func cell(_ index: Int, _ key: ShortcutKey) -> some View {
        if index > 0 {
            plus
        }
        ShortcutKeyCap(key: key, size: size, compact: compact, tint: tint)
    }

    private var plus: some View {
        Text(verbatim: "+")
            .font(.system(size: size.font, weight: .medium))
            .foregroundStyle(.tertiary)
    }
}

/// À la place des touches pendant l'enregistrement d'un raccourci : point rouge qui pulse et consigne, à la hauteur
/// des touches.
struct ShortcutRecordingField: View {
    var prompt: String
    var size: KeyCapSize = .regular
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        HStack(spacing: size.gap * 2) {
            dot
            Text(prompt)
                .font(.system(size: size.font, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, size.padding)
        .frame(height: size.height)
        .background(Theme.brand.opacity(0.07), in: shape)
        .overlay { shape.strokeBorder(Theme.brand.opacity(0.5), lineWidth: 1) }
        .onAppear { if !reduceMotion { dimmed = true } }
        .accessibilityElement(children: .combine)
    }

    private var dot: some View {
        Circle()
            .fill(Theme.brand)
            .frame(width: size.gap * 2, height: size.gap * 2)
            .opacity(dimmed ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dimmed)
    }
}

/// Clavier de MacBook (disposition ANSI) en unités de touche : une lettre fait 1 × 1, la rangée des touches de
/// fonction est moins haute. Les positions suivent les codes de touche de macOS, indépendants de la disposition.
enum MacKeyboardLayout {
    struct Key: Hashable {
        /// Code de touche macOS ; -1 pour Touch ID, qui n'en a pas.
        var code: Int
        /// Inscription fixe (esc, ⇧, ⌘…) ; nil pour une touche de caractère, lue dans la disposition active.
        var label: String?
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    static let width: CGFloat = 14.5
    static let functionRowHeight: CGFloat = 0.6
    static let height: CGFloat = functionRowHeight + 5

    private struct Spec {
        var code: Int
        var label: String?
        var width: CGFloat = 1
    }

    /// Touches de caractère : inscription lue dans la disposition active.
    private static func letters(_ codes: [Int]) -> [Spec] {
        codes.map { Spec(code: $0) }
    }

    /// Touches sans inscription sur le schéma (touches de fonction).
    private static func blanks(_ codes: [Int]) -> [Spec] {
        codes.map { Spec(code: $0, label: "") }
    }

    private static let rows: [[Spec]] = [
        [Spec(code: 53, label: "esc", width: 1.5)]
            + blanks([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111])
            + blanks([-1]),
        letters([50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24])
            + [Spec(code: 51, label: "⌫", width: 1.5)],
        [Spec(code: 48, label: "⇥", width: 1.5)]
            + letters([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]),
        [Spec(code: 57, label: "⇪", width: 1.75)]
            + letters([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39])
            + [Spec(code: 36, label: "↩", width: 1.75)],
        [Spec(code: 56, label: "⇧", width: 2.25)]
            + letters([6, 7, 8, 9, 11, 45, 46, 43, 47, 44])
            + [Spec(code: 60, label: "⇧", width: 2.25)],
        [
            Spec(code: 63, label: "fn"), Spec(code: 59, label: "⌃"), Spec(code: 58, label: "⌥"),
            Spec(code: 55, label: "⌘", width: 1.25), Spec(code: 49, label: "", width: 5),
            Spec(code: 54, label: "⌘", width: 1.25), Spec(code: 61, label: "⌥"),
        ],
    ]

    static let keys: [Key] = {
        var keys: [Key] = []
        for (index, row) in rows.enumerated() {
            let y = index == 0 ? 0 : functionRowHeight + CGFloat(index - 1)
            let height = index == 0 ? functionRowHeight : 1
            var x: CGFloat = 0
            for spec in row {
                keys.append(Key(code: spec.code, label: spec.label, x: x, y: y, width: spec.width, height: height))
                x += spec.width
            }
        }
        // Flèches en T inversé : ← et → pleine hauteur, ↑ et ↓ en demi-touches l'une sur l'autre.
        let bottom = functionRowHeight + 4
        keys.append(Key(code: 123, label: "←", x: 11.5, y: bottom, width: 1, height: 1))
        keys.append(Key(code: 126, label: "↑", x: 12.5, y: bottom, width: 1, height: 0.5))
        keys.append(Key(code: 125, label: "↓", x: 12.5, y: bottom + 0.5, width: 1, height: 0.5))
        keys.append(Key(code: 124, label: "→", x: 13.5, y: bottom, width: 1, height: 1))
        return keys
    }()
}

/// Schéma d'un clavier de MacBook dessiné touche par touche ; celles de `highlighted` (codes de touche) prennent
/// la couleur d'accent. `unit` : côté d'une touche de lettre, en points.
struct MacKeyboardDiagram: View {
    var highlighted: Set<Int>
    var unit: CGFloat = 26

    var body: some View {
        let characters = KeyboardLayout.characters()
        let gap = max(2, unit * 0.1)
        ZStack(alignment: .topLeading) {
            ForEach(MacKeyboardLayout.keys, id: \.self) { key in
                DiagramKey(label: key.label ?? characters[key.code] ?? "", lit: highlighted.contains(key.code),
                           unit: unit)
                    .frame(width: key.width * unit - gap, height: key.height * unit - gap)
                    .offset(x: key.x * unit, y: key.y * unit)
            }
        }
        .frame(width: MacKeyboardLayout.width * unit - gap, height: MacKeyboardLayout.height * unit - gap,
               alignment: .topLeading)
        .padding(unit * 0.3)
        .background {
            RoundedRectangle(cornerRadius: unit * 0.45, style: .continuous)
                .fill(Theme.subtleFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: unit * 0.45, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Schéma du clavier, touches du raccourci en couleur"))
    }
}

private struct DiagramKey: View {
    var label: String
    var lit: Bool
    var unit: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: unit * 0.16, style: .continuous)
        shape
            .fill(lit ? Theme.brand : Theme.raised)
            .shadow(color: .black.opacity(lit ? 0 : 0.12), radius: 0, y: 1)
            .overlay {
                shape.strokeBorder(lit ? Color.clear : Theme.cardBorder, lineWidth: 0.5)
            }
            .overlay {
                Text(label)
                    .font(.system(size: unit * 0.34, weight: lit ? .semibold : .regular))
                    .foregroundStyle(lit ? Color.white : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
    }
}
