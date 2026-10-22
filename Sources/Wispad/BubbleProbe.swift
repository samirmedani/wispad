import AppKit
import ScreenCaptureKit
import SwiftUI
import WispadCore

// Outil de développement : absent de la version Release.
#if DEBUG

/// Capture la vraie bulle (verre d'Apple compris) sans rien montrer à l'écran : la bulle et un fond d'essai sont
/// posés derrière la fenêtre au premier plan, puis ces deux fenêtres seules sont composées par ScreenCaptureKit.
/// Les rendus hors écran (ImageRenderer) ne dessinent pas le Liquid Glass ; ceci le dessine.
///
///   Wispad --bubble-probe <dossier> [--appearance dark|light]
///
/// Écrit <style>-<mode>-<fond>.png pour chaque style de bulle, chaque état et trois fonds : rayures vives, fenêtre
/// sombre avec du texte, photo claire. Lancer depuis un shell autorisé à enregistrer l'écran ; jamais de focus pris.
@MainActor
enum BubbleProbe {
    static let modes: [(name: String, apply: @MainActor (AppModel) -> Void)] = [
        ("ecoute", { model in model.coordinator.phase = .listening(.pushToTalk); model.overlay.show() }),
        ("mains-libres", { model in model.coordinator.phase = .listening(.toggle); model.overlay.show() }),
        ("finalisation", { model in model.coordinator.phase = .finishing; model.overlay.show() }),
        ("texte-pret", { model in
            model.coordinator.failureText = "Texte de démonstration."
            model.coordinator.phase = .failure("Le texte n'est pas arrivé dans le champ")
            model.overlay.show()
        }),
        ("mot-appris", { model in model.coordinator.phase = .idle; model.overlay.hide(); model.coordinator.notifyLearned(["Seedance"]) }),
    ]

    static func run(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--bubble-probe"), arguments.indices.contains(index + 1) else {
            print("Usage : --bubble-probe <dossier>"); return
        }
        let outDir = URL(fileURLWithPath: arguments[index + 1])
        let light = arguments.firstIndex(of: "--appearance").map { arguments.indices.contains($0 + 1) && arguments[$0 + 1] == "light" } ?? false
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        guard let front = frontWindow() else { print("PROBE aucune fenêtre opaque assez grande au premier plan"); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-bubble-probe-\(UUID().uuidString)")
        let model: AppModel
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: AppDependencies())
        } catch {
            print("PROBE impossible : \(error.localizedDescription)"); return
        }
        // Le contrôleur suit les phases sans mettre son panneau à l'écran : la bulle vit dans le panneau caché.
        model.overlay.displaysPanel = false
        model.overlay.install(model: model)
        model.overlay.state.forcesReduceMotion = true
        let size = OverlayLayout.panelSize
        let primaryHeight = NSScreen.screens[0].frame.height
        let origin = NSPoint(x: (front.rect.midX - size.width / 2).rounded(), y: (primaryHeight - front.rect.maxY + 40).rounded())
        let frame = NSRect(origin: origin, size: size)
        let back = makePanel(frame)
        let background = ProbeBackground(frame: NSRect(origin: .zero, size: size))
        back.contentView = background
        back.isOpaque = true
        back.backgroundColor = .white
        let bubble = makePanel(frame)
        let hosting = NSHostingView(rootView: OverlayBar().environment(model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        bubble.contentView = hosting
        bubble.order(.below, relativeTo: front.number)
        back.order(.below, relativeTo: bubble.windowNumber)
        // Spectre figé, lisible : une voix à mi-course.
        let bands = (0..<SpectrumAnalyzer.bandCount).map { Float(0.25 + 0.6 * max(0, 1 - Double($0) * 0.14)) }
        model.coordinator.spectrum = bands.reversed() + bands.dropFirst()
        print("PROBE fenêtre \(front.number) cadre \(NSStringFromRect(frame))")
        fflush(stdout)
        Task { @MainActor in
            for style in BubbleStyle.allCases {
                model.settings.bubbleStyle = style
                model.settings.bubbleGlass = BubbleGlass(variant: .clear, intensity: 0)
                for mode in modes {
                    mode.apply(model)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    for kind in ProbeBackground.Kind.allCases {
                        background.kind = kind
                        background.display()
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        await capture(windows: [back.windowNumber, bubble.windowNumber], frame: frame, primaryHeight: primaryHeight,
                                      to: outDir.appendingPathComponent("\(style.rawValue)-\(mode.name)-\(kind.rawValue).png"))
                    }
                    model.coordinator.phase = .idle
                    model.coordinator.failureText = nil
                    model.overlay.hide()
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }
            print("PROBE fini")
            fflush(stdout)
            try? FileManager.default.removeItem(at: directory)
            app.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { app.terminate(nil) }
        app.run()
    }

    private struct FrontWindow {
        var number: Int
        var rect: CGRect
    }

    /// Fenêtre opaque d'une autre app, assez grande pour cacher le panneau (origine en haut à gauche de l'écran principal).
    private static func frontWindow() -> FrontWindow? {
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let myPID = ProcessInfo.processInfo.processIdentifier
        for info in infos {
            guard info[kCGWindowLayer as String] as? Int == 0, info[kCGWindowOwnerPID as String] as? pid_t != myPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) >= 0.99,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= OverlayLayout.panelSize.width + 80, rect.height >= OverlayLayout.panelSize.height + 120 else { continue }
            return FrontWindow(number: number, rect: rect)
        }
        return nil
    }

    private static func makePanel(_ frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }

    private static func capture(windows: [Int], frame: NSRect, primaryHeight: CGFloat, to url: URL) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let selected = content.windows.filter { windows.contains(Int($0.windowID)) }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { print("PROBE écran introuvable"); return }
            let scale = NSScreen.screens[0].backingScaleFactor
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
            configuration.width = Int(frame.width * scale)
            configuration.height = Int(frame.height * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: selected), configuration: configuration)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try data.write(to: url)
            print("PROBE \(url.lastPathComponent) \(image.width)x\(image.height)")
        } catch {
            print("PROBE capture impossible : \(error.localizedDescription)")
        }
        fflush(stdout)
    }

    /// Fond d'essai, plein : rayures vives, fenêtre sombre avec du texte, ou photo claire.
    private final class ProbeBackground: NSView {
        enum Kind: String, CaseIterable { case rayures, sombre, photo }
        var kind: Kind = .rayures

        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            switch kind {
            case .rayures:
                NSColor.white.setFill()
                bounds.fill()
                let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .black, .systemPurple]
                var x: CGFloat = -bounds.height
                var index = 0
                while x < bounds.width + bounds.height {
                    colors[index % colors.count].setFill()
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: x, y: 0))
                    path.line(to: NSPoint(x: x + 9, y: 0))
                    path.line(to: NSPoint(x: x + 9 + bounds.height, y: bounds.height))
                    path.line(to: NSPoint(x: x + bounds.height, y: bounds.height))
                    path.close()
                    path.fill()
                    x += 9
                    index += 1
                }
            case .sombre:
                NSColor(white: 0.11, alpha: 1).setFill()
                bounds.fill()
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
                let lines = ["func render(_ frame: Frame) -> Image {", "    let bars = spectrum.levels(at: t)", "    return glass.draw(bars, in: shape)", "}",
                             "La bulle écoute, puis le texte corrigé s'écrit là où se trouve ton curseur, dans l'app du moment.",
                             "Double appui sur fn pour les mains libres ; un appui suivant l'arrête ; esc annule."]
                for (row, line) in lines.enumerated() {
                    (line as NSString).draw(at: NSPoint(x: 24, y: bounds.height - 30 - CGFloat(row) * 24), withAttributes: attributes)
                }
                NSColor(red: 1, green: 0.23, blue: 0.21, alpha: 1).setFill()
                NSRect(x: 24, y: 14, width: 120, height: 26).fill()
            case .photo:
                let gradient = NSGradient(colors: [NSColor(red: 0.98, green: 0.78, blue: 0.55, alpha: 1), NSColor(red: 0.55, green: 0.75, blue: 0.98, alpha: 1)])
                gradient?.draw(in: bounds, angle: 90)
                NSColor(white: 1, alpha: 0.9).setFill()
                NSBezierPath(ovalIn: NSRect(x: 150, y: 90, width: 70, height: 70)).fill()
                NSColor(red: 0.2, green: 0.45, blue: 0.3, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 300, y: -60, width: 220, height: 120)).fill()
                NSColor(red: 0.95, green: 0.35, blue: 0.3, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 40, y: -30, width: 120, height: 80)).fill()
            }
        }
    }
}

#endif
