import AppKit
import SwiftUI

// Outil de développement : absent de la version Release.
#if DEBUG

/// Propositions de style pour les messages de la bulle, le spectre restant tel quel :
/// `Wispad --bubble-gallery <dossier> --styles`. Mêmes messages dans chaque style, sur fond sombre et sur fond
/// clair, sans contour blanc. Rendu par ImageRenderer : l'image montre ce que la bulle dessinerait.
@MainActor
enum BubbleStyleLab {
    enum Style: CaseIterable {
        case island, notification, halo

        var file: String {
            switch self {
            case .island: "style-a-ile.png"
            case .notification: "style-b-notification.png"
            case .halo: "style-c-halo.png"
            }
        }

        var title: String {
            switch self {
            case .island: "A · Île noire"
            case .notification: "B · Notification"
            case .halo: "C · Halo"
            }
        }

        var summary: String {
            switch self {
            case .island: "Noir profond comme la Dynamic Island. Pastille de couleur dont l'anneau fait le décompte."
            case .notification: "Carte graphite comme une notification de macOS. Icône en tuile, décompte en bas."
            case .halo: "Noir, éclairé par la couleur du message. Icône lumineuse, décompte fin."
            }
        }
    }

    enum Kind {
        case success, info, relay, error, update, ready, learning

        var symbol: String {
            switch self {
            case .success: "checkmark"
            case .info: "info"
            case .relay: "arrow.triangle.branch"
            case .error: "exclamationmark"
            case .update: "arrow.down"
            case .ready: "doc.on.clipboard"
            case .learning: "sparkles"
            }
        }

        var filledSymbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            case .relay: "arrow.triangle.branch"
            case .error: "exclamationmark.circle.fill"
            case .update: "arrow.down.circle.fill"
            case .ready: "doc.on.clipboard.fill"
            case .learning: "sparkles"
            }
        }

        var tint: Color {
            switch self {
            case .success: OverlayStyle.green
            case .info: Color(white: 0.78)
            case .relay: OverlayStyle.relay
            case .error: OverlayStyle.red
            case .update: OverlayStyle.update
            case .ready: Color(red: 1, green: 0.62, blue: 0.16)
            case .learning: Color(red: 0.72, green: 0.49, blue: 1)
            }
        }
    }

    struct Action: Hashable {
        var title: String
        var prominent = false
    }

    /// Un message : une ligne, ou une carte quand il a un titre.
    struct Content {
        var kind: Kind
        var title: String?
        var message: String
        var footnote: String?
        var actions: [Action] = []
        var hovered = false
        /// Part restante du décompte.
        var remaining = 0.68
    }

    static let samples: [(caption: String, content: Content)] = {
        let error = Content(kind: .error, message: "Transcription impossible : l'audio est gardé dans l'historique",
                            actions: [Action(title: "Historique")])
        let ready = Content(kind: .ready, title: "Texte prêt à copier", message: "Pas de champ où écrire",
                            actions: [Action(title: "Coller"), Action(title: "Copier", prominent: true)])
        var errorHovered = error
        errorHovered.hovered = true
        var readyHovered = ready
        readyHovered.hovered = true
        return [
            ("Erreur avec action", error),
            ("Erreur, pointeur dessus", errorHovered),
            ("Erreur simple", Content(kind: .error, message: "Le micro n'a pas démarré : réessaie")),
            ("Confirmation", Content(kind: .success, message: "Collé")),
            ("Bascule de fournisseur", Content(kind: .relay, message: "DeepSeek ne répond pas : correction via OpenAI")),
            ("Nouvelle version", Content(kind: .update, message: "Wispad 0.2.5 est disponible",
                                         actions: [Action(title: "Voir"), Action(title: "Ne plus me rappeler")])),
            ("Texte prêt à copier", ready),
            ("Texte prêt, pointeur dessus", readyHovered),
            ("Mots appris", Content(kind: .learning, title: "3 ajouts au dictionnaire",
                                    message: "Kubernetes · RevenueCat · Figma", footnote: "Appris de tes corrections",
                                    actions: [Action(title: "Voir"), Action(title: "Annuler l'ajout")])),
        ]
    }()

    static func render(to directory: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return 2
        }
        var code: Int32 = 0
        for style in Style.allCases {
            let renderer = ImageRenderer(content: StyleBoard(style: style))
            renderer.scale = 2
            let url = directory.appendingPathComponent(style.file)
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? data.write(to: url)) != nil else {
                print("BUBBLE_STYLES_FAILED \(style.file)")
                code = 1
                continue
            }
            print("BUBBLE_STYLES \(url.path)")
        }
        return code
    }

    /// Une proposition : chaque message sur fond sombre, puis sur fond clair.
    struct StyleBoard: View {
        var style: Style

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: style.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text(verbatim: style.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.08))
                HStack(alignment: .top, spacing: 0) {
                    column(dark: true)
                    column(dark: false)
                }
            }
            .fixedSize()
        }

        private func column(dark: Bool) -> some View {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(BubbleStyleLab.samples.indices, id: \.self) { index in
                    let sample = BubbleStyleLab.samples[index]
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: sample.caption)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(dark ? Color.white.opacity(0.5) : Color.black.opacity(0.5))
                        Bubble(style: style, content: sample.content)
                            .frame(width: 520, alignment: .leading)
                    }
                }
            }
            .padding(32)
            .background(dark ? Color(white: 0.13) : Color(white: 0.93))
        }
    }

    struct Bubble: View {
        var style: Style
        var content: Content

        var body: some View {
            switch style {
            case .island: IslandBubble(content: content)
            case .notification: NotificationBubble(content: content)
            case .halo: HaloBubble(content: content)
            }
        }
    }

    // MARK: - A · Île noire

    struct IslandBubble: View {
        var content: Content

        var body: some View {
            if content.title == nil { line } else { card }
        }

        private var line: some View {
            HStack(spacing: 10) {
                RingBadge(kind: content.kind, size: 26, remaining: content.remaining, closing: content.hovered)
                LineText(text: content.message)
                ForEach(content.actions, id: \.self) { action in
                    LabButton(action: action, height: 26, size: 12)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, content.actions.isEmpty ? 16 : 8)
            .padding(.vertical, 8)
            .background(IslandBackground(shape: RoundedRectangle(cornerRadius: 21, style: .continuous)))
        }

        private var card: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RingBadge(kind: content.kind, size: 36, remaining: content.remaining)
                    CardTexts(content: content)
                        .padding(.top, 1)
                    Spacer(minLength: 8)
                    CloseDot(hovered: content.hovered)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach(content.actions, id: \.self) { action in
                        LabButton(action: action, height: 30, size: 13)
                    }
                }
            }
            .padding(16)
            .frame(width: 392)
            .background(IslandBackground(shape: RoundedRectangle(cornerRadius: 26, style: .continuous)))
        }
    }

    /// Noir profond, un reflet très doux sur le haut, une ombre : la forme se lit sans contour.
    struct IslandBackground<S: Shape>: View {
        var shape: S

        var body: some View {
            shape.fill(Color.black)
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0)],
                                                   startPoint: .top, endPoint: .center)))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        }
    }

    /// Pastille teintée ; son anneau se vide avec le décompte.
    struct RingBadge: View {
        var kind: Kind
        var size: CGFloat
        var remaining: Double
        /// Pointeur sur la bulle : la pastille devient la ✕, l'anneau reste (décompte en pause).
        var closing = false

        var body: some View {
            ZStack {
                Circle().inset(by: 3.5).fill(closing ? Color.white.opacity(0.14) : kind.tint.opacity(0.2))
                Image(systemName: closing ? "xmark" : kind.symbol)
                    .font(.system(size: size * (closing ? 0.3 : 0.36), weight: .bold))
                    .foregroundStyle(closing ? Color.white.opacity(0.9) : kind.tint)
                Circle().inset(by: 1).stroke(kind.tint.opacity(0.16), lineWidth: 2)
                Circle().inset(by: 1).trim(from: 0, to: remaining)
                    .stroke(kind.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: - B · Notification

    struct NotificationBubble: View {
        var content: Content

        var body: some View {
            if content.title == nil { line } else { card }
        }

        private var line: some View {
            HStack(spacing: 10) {
                SymbolTile(kind: content.kind, size: 24, closing: content.hovered)
                LineText(text: content.message)
                ForEach(content.actions, id: \.self) { action in
                    LabButton(action: action, height: 24, size: 12, radius: 6)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, content.actions.isEmpty ? 15 : 9)
            .padding(.vertical, 9)
            .background(NotificationBackground(shape: RoundedRectangle(cornerRadius: 13, style: .continuous),
                                               tint: content.kind.tint, remaining: content.remaining))
        }

        private var card: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    SymbolTile(kind: content.kind, size: 34)
                    CardTexts(content: content)
                    Spacer(minLength: 8)
                    CloseDot(hovered: content.hovered)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach(content.actions, id: \.self) { action in
                        LabButton(action: action, height: 28, size: 13, radius: 8)
                    }
                }
            }
            .padding(16)
            .frame(width: 392)
            .background(NotificationBackground(shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                                               tint: content.kind.tint, remaining: content.remaining))
        }
    }

    /// Tuile de couleur, glyphe blanc, comme l'icône d'une notification.
    struct SymbolTile: View {
        var kind: Kind
        var size: CGFloat
        /// Pointeur sur la bulle : la tuile devient la ✕.
        var closing = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            shape.fill(closing ? Color.white.opacity(0.16) : kind.tint)
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(closing ? 0.06 : 0.24), .white.opacity(0)],
                                                   startPoint: .top, endPoint: .bottom)))
                .overlay(Image(systemName: closing ? "xmark" : kind.symbol)
                    .font(.system(size: size * (closing ? 0.36 : 0.44), weight: .bold))
                    .foregroundStyle(.white))
                .frame(width: size, height: size)
        }
    }

    /// Graphite en léger dégradé ; le décompte est une barre de couleur qui épouse le bas.
    struct NotificationBackground<S: Shape>: View {
        var shape: S
        var tint: Color
        var remaining: Double

        var body: some View {
            shape.fill(LinearGradient(colors: [Color(white: 0.21), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottomLeading) {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(tint.opacity(0.95))
                            .frame(width: proxy.size.width * remaining, height: 2.5)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .clipShape(shape)
                .shadow(color: .black.opacity(0.4), radius: 18, y: 7)
        }
    }

    // MARK: - C · Halo

    struct HaloBubble: View {
        var content: Content

        var body: some View {
            if content.title == nil { line } else { card }
        }

        private var line: some View {
            HStack(spacing: 10) {
                GlowSymbol(kind: content.kind, size: 17, closing: content.hovered)
                LineText(text: content.message)
                ForEach(content.actions, id: \.self) { action in
                    LabButton(action: action, height: 26, size: 12, tint: content.kind.tint)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, content.actions.isEmpty ? 18 : 8)
            .padding(.vertical, 8)
            .frame(minHeight: 42)
            .background(HaloBackground(shape: RoundedRectangle(cornerRadius: 21, style: .continuous),
                                       tint: content.kind.tint, remaining: content.remaining,
                                       center: UnitPoint(x: 0.02, y: 0.5), radius: 170))
        }

        private var card: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    GlowSymbol(kind: content.kind, size: 22)
                        .frame(width: 30, height: 30)
                    CardTexts(content: content)
                        .padding(.top, 4)
                    Spacer(minLength: 8)
                    CloseDot(hovered: content.hovered)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach(content.actions, id: \.self) { action in
                        LabButton(action: action, height: 30, size: 13, tint: content.kind.tint)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 4)
            .frame(width: 392)
            .background(HaloBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous),
                                       tint: content.kind.tint, remaining: content.remaining,
                                       center: UnitPoint(x: 0.08, y: 0.18), radius: 280))
        }
    }

    struct GlowSymbol: View {
        var kind: Kind
        var size: CGFloat
        /// Pointeur sur la bulle : l'icône devient la ✕.
        var closing = false

        var body: some View {
            Image(systemName: closing ? "xmark.circle.fill" : kind.filledSymbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(closing ? Color.white.opacity(0.75) : kind.tint)
                .shadow(color: closing ? .clear : kind.tint.opacity(0.65), radius: 7)
        }
    }

    /// Presque noir, éclairé par la couleur du message depuis l'icône ; décompte en fine barre.
    struct HaloBackground<S: Shape>: View {
        var shape: S
        var tint: Color
        var remaining: Double
        var center: UnitPoint
        var radius: CGFloat

        var body: some View {
            shape.fill(Color(white: 0.055))
                .overlay(shape.fill(RadialGradient(colors: [tint.opacity(0.32), tint.opacity(0)], center: center,
                                                   startRadius: 0, endRadius: radius)))
                .overlay(alignment: .bottomLeading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.35)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, proxy.size.width - 36) * remaining, height: 2)
                            .offset(x: 18)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 4)
                    }
                }
                .clipShape(shape)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        }
    }

    // MARK: - Éléments communs

    /// Texte d'une ligne : 13 points, deux lignes au plus quand il est long.
    struct LineText: View {
        var text: String

        var body: some View {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Titre et raison d'une carte ; pour les mots appris, les mots passent devant.
    struct CardTexts: View {
        var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                if content.kind == .learning {
                    Text(content.title ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(content.kind.tint)
                    Text(content.message)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(content.title ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(content.message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.62))
                }
                if let footnote = content.footnote {
                    Text(footnote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Bouton : blanc plein pour l'action principale, voile clair (ou teinté) pour les autres.
    struct LabButton: View {
        var action: Action
        var height: CGFloat
        var size: CGFloat
        /// nil : capsule.
        var radius: CGFloat?
        /// Teinte du message pour les boutons secondaires ; nil : voile blanc.
        var tint: Color?

        var body: some View {
            let shape = radius.map { AnyShape(RoundedRectangle(cornerRadius: $0, style: .continuous)) } ?? AnyShape(Capsule())
            let secondaryFill = tint.map { $0.opacity(0.2) } ?? Color.white.opacity(0.13)
            let secondaryText = tint ?? Color.white.opacity(0.92)
            Text(action.title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(action.prominent ? Color.black.opacity(0.9) : secondaryText)
                .padding(.horizontal, height * 0.45)
                .frame(height: height)
                .background(shape.fill(action.prominent ? Color.white : secondaryFill))
                .fixedSize()
        }
    }

    /// ✕ d'une carte au survol : place gardée en haut à droite, visible seulement sous le pointeur.
    struct CloseDot: View {
        var hovered: Bool

        var body: some View {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.12)))
                .opacity(hovered ? 1 : 0)
        }
    }
}

#endif
