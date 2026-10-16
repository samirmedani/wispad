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
