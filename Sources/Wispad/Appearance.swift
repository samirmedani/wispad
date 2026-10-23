import SwiftUI
import AppKit

/// Apparence de l'app : celle de macOS (par défaut), claire ou sombre. La bulle de dictée reste toujours sombre.
enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Système")
        case .light: return String(localized: "Clair")
        case .dark: return String(localized: "Sombre")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// `nil` : l'app suit macOS, y compris quand il passe seul du clair au sombre.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Style de la bulle (Réglages › Bulle et messages). Le spectre garde ses couleurs dans les deux.
enum BubbleStyle: String, Codable, CaseIterable, Identifiable {
    /// Messages noir profond, comme la Dynamic Island ; bulle de dictée en verre fumé noir. Lisible sur tous les fonds.
    case black
    /// Liquid Glass transparent d'Apple pour la bulle de dictée et ses messages, clair ou sombre comme l'app.
    case glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: return String(localized: "Noir profond")
        case .glass: return String(localized: "Verre")
        }
    }
}

/// Les deux verres du style Verre.
enum GlassVariant: String, Codable, CaseIterable, Identifiable {
    /// Verre dessiné par Wispad, sans aucun flou : ce qu'il y a derrière reste net, sous un voile léger, un reflet et
    /// un liseré lumineux. Le Glass.clear d'Apple floute autant que le dépoli sur macOS (mesuré le 23 octobre 2026 sur
    /// des captures composées : rayures fondues, fond sombre devenu gris laiteux) ; il n'est donc plus utilisé.
    case clear
    /// Liquid Glass d'Apple (Glass.regular) : dépoli, plus lisible sur un fond chargé.
    case regular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: return String(localized: "Transparent")
        case .regular: return String(localized: "Dépoli")
        }
    }
}

/// Les trois allures de la bulle proposées dans Réglages, chacune un style et, pour le verre, une variante.
enum BubbleLook: String, CaseIterable, Identifiable {
    case black, clearGlass, frostedGlass

    var id: String { rawValue }

    init(style: BubbleStyle, glass: BubbleGlass) {
        switch style {
        case .black: self = .black
        case .glass: self = glass.isLens ? .clearGlass : .frostedGlass
        }
    }

    var style: BubbleStyle { self == .black ? .black : .glass }

    var variant: GlassVariant? {
        switch self {
        case .black: return nil
        case .clearGlass: return .clear
        case .frostedGlass: return .regular
        }
    }

    var title: String {
        switch self {
        case .black: return String(localized: "Noir profond")
        case .clearGlass: return String(localized: "Verre transparent")
        case .frostedGlass: return String(localized: "Verre dépoli")
        }
    }

    var caption: String {
        switch self {
        case .black: return String(localized: "Lisible sur tout fond")
        case .clearGlass: return String(localized: "Le fond reste net")
        case .frostedGlass: return String(localized: "Flouté, comme macOS")
        }
    }
}

/// Apparence du verre (style Verre). Clair par défaut : le verre clair d'Apple est brillant et laisse voir ce qu'il y a
/// derrière, comme la barre de navigation de l'iPhone ; le verre sombre ressemble à un verre fumé (mesuré sur des
/// captures composées le 21 octobre 2026).
enum GlassAppearance: String, Codable, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return String(localized: "Clair")
        case .dark: return String(localized: "Sombre")
        case .system: return String(localized: "Comme l'app")
        }
    }

    /// `nil` : le verre suit l'apparence de l'app (donc celle de macOS en réglage Système).
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

/// Verre de la bulle (style Verre) : un des deux verres d'Apple, plus ou moins teinté, clair ou sombre.
struct BubbleGlass: Codable, Equatable {
    var variant: GlassVariant = .clear
    /// Teinte, de 0 (le verre seul) à 1 (la plus forte) : sombre en apparence sombre, claire en apparence claire.
    var intensity = BubbleGlass.defaultIntensity
    var appearance: GlassAppearance = .light

    static let defaultIntensity = 0.25
    static let intensityRange = 0.0...1.0
    /// Opacité de la teinte au maximum : au-delà, ce ne serait plus du verre.
    static let maxTint = 0.7

    init() {}

    init(variant: GlassVariant, intensity: Double, appearance: GlassAppearance = .light) {
        self.variant = variant
        self.intensity = intensity
        self.appearance = appearance
    }

    /// Lecture tolérante, champ par champ : une valeur illisible ou hors bornes reprend son défaut, seule.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variant = (try? container.decodeIfPresent(GlassVariant.self, forKey: .variant)) ?? .clear
        let stored = (try? container.decodeIfPresent(Double.self, forKey: .intensity)) ?? Self.defaultIntensity
        intensity = Self.intensityRange.contains(stored) ? stored : Self.defaultIntensity
        appearance = (try? container.decodeIfPresent(GlassAppearance.self, forKey: .appearance)) ?? .light
    }

    /// Teinte posée sur le verre pour cette apparence ; nil à zéro.
    func tint(for scheme: ColorScheme) -> Color? {
        guard intensity > 0 else { return nil }
        return (scheme == .dark ? Color.black : Color.white).opacity(intensity * Self.maxTint)
    }

    @available(macOS 26, *)
    func glass(for scheme: ColorScheme) -> Glass {
        Glass.regular.tint(tint(for: scheme))
    }

    /// Verre transparent de Wispad, sans flou (`GlassLens`), au lieu du Liquid Glass d'Apple.
    var isLens: Bool { variant == .clear }

    /// Voile du verre transparent : léger sur la bulle de dictée, où le spectre se lit sur tout fond ; plus dense sous
    /// un message, dont le texte doit rester lisible. L'intensité le renforce.
    func lensVeil(message: Bool) -> Double {
        message ? 0.74 + intensity * 0.22 : 0.05 + intensity * 0.45
    }
}

/// Applique l'apparence à toute l'app. Changée à la main, les fenêtres ouvertes passent de l'une à l'autre en fondu
/// (sauf avec « Réduire les animations ») ; au lancement, elle est posée avant toute fenêtre.
@MainActor
enum AppearanceSwitcher {
    static func apply(_ appearance: AppAppearance, animated: Bool) {
        let target = appearance.nsAppearance
        guard NSApp.appearance?.name != target?.name else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // La bulle (panneau) n'est pas concernée : elle garde son apparence sombre.
            for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
                guard let layer = window.contentView?.layer else { continue }
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.3
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(fade, forKey: "wispad.appearance")
            }
        }
        NSApp.appearance = target
    }
}

extension AppModel {
    func setAppearance(_ appearance: AppAppearance) {
        guard settings.appearance != appearance else { return }
        settings.appearance = appearance
        saveSettings()
        AppearanceSwitcher.apply(appearance, animated: true)
    }

    func setBubbleStyle(_ style: BubbleStyle) {
        guard settings.bubbleStyle != style else { return }
        settings.bubbleStyle = style
        saveSettings()
        overlay.bubbleStyleChanged()
    }

    var bubbleLook: BubbleLook { BubbleLook(style: settings.bubbleStyle, glass: settings.bubbleGlass) }

    /// Choix d'une carte de Réglages › Bulle et messages : style et verre d'un coup, appliqués aussitôt à la bulle.
    func setBubbleLook(_ look: BubbleLook) {
        guard look != bubbleLook else { return }
        settings.bubbleStyle = look.style
        if let variant = look.variant { settings.bubbleGlass.variant = variant }
        saveSettings()
        overlay.bubbleStyleChanged()
    }

    func setGlassAppearance(_ appearance: GlassAppearance) {
        guard settings.bubbleGlass.appearance != appearance else { return }
        settings.bubbleGlass.appearance = appearance
        saveSettings()
        overlay.bubbleStyleChanged()
    }
}

/// Bouton de la barre latérale, à droite du nom : l'icône montre l'apparence choisie, un clic ouvre les trois choix.
struct AppearanceButton: View {
    @Environment(AppModel.self) private var model
    @State private var showsChoices = false

    var body: some View {
        let current = model.settings.appearance
        Button {
            showsChoices.toggle()
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(HoverButtonStyle(treatment: .icon, tint: .primary))
        .help(String(localized: "Apparence : \(current.title)"))
        .accessibilityLabel(String(localized: "Apparence"))
        .accessibilityValue(current.title)
        .popover(isPresented: $showsChoices, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Apparence")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                AppearancePicker(tileWidth: 76)
            }
            .padding(16)
        }
    }
}

/// Trois vignettes, comme dans les Réglages de macOS : Système (moitié claire, moitié sombre), Clair, Sombre.
struct AppearancePicker: View {
    @Environment(AppModel.self) private var model
    var tileWidth: CGFloat = 96

    var body: some View {
        HStack(alignment: .top, spacing: tileWidth * 0.16) {
            ForEach(AppAppearance.allCases) { option in
                AppearanceTile(option: option, selected: model.settings.appearance == option, width: tileWidth) {
                    model.setAppearance(option)
                }
            }
        }
    }
}

private struct AppearanceTile: View {
    var option: AppAppearance
    var selected: Bool
    var width: CGFloat
    var action: () -> Void

    private var radius: CGFloat { width * 0.1 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                AppearanceThumbnail(option: option)
                    .frame(width: width, height: width * 0.64)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                            .strokeBorder(selected ? Theme.brand : .clear, lineWidth: 2.5)
                    }
                Text(option.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(treatment: .row))
        .animation(Theme.quick, value: selected)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Fenêtre miniature de Wispad sur un fond d'écran, dessinée aux couleurs fixes de chaque apparence.
private struct AppearanceThumbnail: View {
    var option: AppAppearance

    var body: some View {
        switch option {
        case .light:
            MiniWindowScene(dark: false)
        case .dark:
            MiniWindowScene(dark: true)
        case .system:
            ZStack {
                MiniWindowScene(dark: false)
                MiniWindowScene(dark: true)
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear
                            Color.black
                        }
                    }
            }
        }
    }
}

private struct MiniWindowScene: View {
    var dark: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
                window(width: width * 0.86, height: height * 0.82)
                    .offset(x: width * 0.14, y: height * 0.18)
            }
        }
    }

    private var wallpaper: [Color] {
        dark ? [Color(red: 0.36, green: 0.09, blue: 0.08), Color(red: 0.08, green: 0.03, blue: 0.05)]
             : [Color(red: 1, green: 0.86, blue: 0.79), Color(red: 1, green: 0.55, blue: 0.45)]
    }

    private func window(width: CGFloat, height: CGFloat) -> some View {
        let unit = width / 80
        let canvas = dark ? Color(white: 0.11) : Color(white: 0.965)
        let sidebar = dark ? Color(white: 0.17) : Color(white: 0.9)
        let card = dark ? Color(white: 0.2) : Color.white
        let line = dark ? Color.white.opacity(0.22) : Color.black.opacity(0.14)
        let title = dark ? Color.white.opacity(0.75) : Color.black.opacity(0.6)
        return ZStack(alignment: .topLeading) {
            canvas
            sidebar.frame(width: width * 0.3)
            HStack(spacing: 2.2 * unit) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                    Circle().fill(color).frame(width: 3.4 * unit, height: 3.4 * unit)
                }
            }
            .padding(.leading, 4 * unit)
            .padding(.top, 4 * unit)
            VStack(alignment: .leading, spacing: 3 * unit) {
                Capsule().fill(Theme.brand.opacity(dark ? 0.9 : 0.85)).frame(width: width * 0.2, height: 3.4 * unit)
                Capsule().fill(line).frame(width: width * 0.17, height: 2.6 * unit)
                Capsule().fill(line).frame(width: width * 0.13, height: 2.6 * unit)
                Capsule().fill(line).frame(width: width * 0.15, height: 2.6 * unit)
            }
            .padding(.leading, 4 * unit)
            .padding(.top, 13 * unit)
            VStack(alignment: .leading, spacing: 3.2 * unit) {
                Capsule().fill(title).frame(width: width * 0.26, height: 3.6 * unit)
                RoundedRectangle(cornerRadius: 2.4 * unit, style: .continuous).fill(card)
                    .frame(height: height * 0.3)
                    .overlay(alignment: .bottomLeading) {
                        HStack(alignment: .bottom, spacing: 1.6 * unit) {
                            ForEach([0.35, 0.6, 0.45, 0.85, 0.55], id: \.self) { level in
                                RoundedRectangle(cornerRadius: 0.6 * unit).fill(Theme.brand.opacity(0.85))
                                    .frame(width: 2.6 * unit, height: height * 0.2 * level)
                            }
                        }
                        .padding(2.6 * unit)
                    }
                HStack(spacing: 3 * unit) {
                    RoundedRectangle(cornerRadius: 2.4 * unit, style: .continuous).fill(card)
                    RoundedRectangle(cornerRadius: 2.4 * unit, style: .continuous).fill(card)
                }
                .frame(height: height * 0.22)
            }
            .padding(.leading, width * 0.3 + 4 * unit)
            .padding(.trailing, 4 * unit)
            .padding(.top, 9 * unit)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4 * unit, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 3 * unit, y: unit)
    }
}
