import AppKit
import SwiftUI
import WispadCore

// Outil de développement : absent de la version Release.
#if DEBUG

/// `--bubble-gallery <dossier>` : une planche PNG par famille d'états de la bulle (dictée, texte prêt, erreurs,
/// messages, survol), avec les vues et les textes de l'app. Rien ne s'affiche : app d'arrière-plan sans fenêtre ni
/// panneau, modèle fictif dans un dossier temporaire, rendu par ImageRenderer, donc sans l'effet de verre de macOS 26.
@MainActor
enum BubbleGallery {
    struct Shot {
        var caption: String
        var image: CGImage
    }

    struct Board {
        var file: String
        var title: String
        var columns: Int
        var shots: [Shot] = []
    }

    static func run(arguments: [String]) {
        let app = NSApplication.shared
        // Comme les aperçus hors écran : jamais au premier plan, une dictée en cours garde son app cible.
        app.setActivationPolicy(.prohibited)
        guard let index = arguments.firstIndex(of: "--bubble-gallery"), arguments.indices.contains(index + 1) else {
            print("Usage : Wispad --bubble-gallery <dossier>")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Task { @MainActor in
            exit(await render(to: output))
        }
        app.run()
    }

    private static func render(to output: URL) async -> Int32 {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-bubble-gallery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let model: AppModel
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            var dependencies = AppDependencies()
            dependencies.keyStore = .vault
            dependencies.loadKey = { _ in nil }
            dependencies.refreshKeys = { false }
            model = try AppModel(supportDirectory: support, settings: AppSettings(), dependencies: dependencies)
        } catch {
            print("Galerie impossible : \(error.localizedDescription)")
            return 2
        }
        let studio = Studio(model: model)
        var boards: [Board] = []
        boards.append(studio.dictation())
        boards.append(await studio.readyText())
        boards.append(await studio.errors())
        boards.append(await studio.messages())
        boards.append(await studio.hovered())
        var code: Int32 = studio.missing.isEmpty ? 0 : 1
        for caption in studio.missing { print("BUBBLE_GALLERY_MISSING \(caption)") }
        for board in boards {
            guard let url = write(board, to: output) else {
                print("BUBBLE_GALLERY_FAILED \(board.file)")
                code = 1
                continue
            }
            print("BUBBLE_GALLERY \(url.path)")
        }
        return code
    }

    private static func write(_ board: Board, to directory: URL) -> URL? {
        let renderer = ImageRenderer(content: BoardView(board: board))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        let url = directory.appendingPathComponent(board.file)
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }

    /// Met la bulle dans chaque état par les entrées du coordinateur, puis la rend comme l'app la montrerait.
    @MainActor
    final class Studio {
        let model: AppModel
        private(set) var missing: [String] = []
        private var coordinator: DictationCoordinator { model.coordinator }
        private let sampleText = "Texte fictif de la dictée."
        private let sampleTerms = ["Kubernetes", "RevenueCat", "Figma"]
        private let sampleVersion = SemanticVersion("0.2.5")

        init(model: AppModel) {
            self.model = model
        }

        /// Voix fictive : graves au centre, aigus sur les bords, comme le vrai spectre.
        private static let voiceLevels: [Float] = (0..<DictationCoordinator.barCount).map { index in
            let center = Double(DictationCoordinator.barCount - 1) / 2
            let distance = abs(Double(index) - center) / center
            let ripple = 0.82 + 0.18 * cos(Double(index) * 2.3)
            return Float(max(0.08, (0.92 - 0.72 * distance) * ripple))
        }

        func dictation() -> Board {
            var board = Board(file: "1-dictee.png", title: "Bulle de dictée", columns: 4)
            coordinator.spectrum = Self.voiceLevels
            coordinator.phase = .listening(.pushToTalk)
            snap("Écoute (touche maintenue)", into: &board)
            coordinator.phase = .listening(.toggle)
            snap("Mains libres : ✕ annule, ■ termine", into: &board)
            coordinator.phase = .finishing
            snap("Transcription et correction", into: &board)
            coordinator.showRelay("OpenAI")
            snap("Correction par un relais", into: &board)
            coordinator.phase = .idle
            return board
        }

        func readyText() async -> Board {
            var board = Board(file: "2-texte-pret.png", title: "Texte prêt : la dictée n'a pas pu être écrite", columns: 2)
            let cases: [(caption: String, message: String)] = [
                ("Collage envoyé, texte absent du champ", DictationCoordinator.readyMessage(for: .failed)),
                ("Aucun champ de texte actif", DictationCoordinator.readyMessage(for: .noTarget)),
                ("Champ de mot de passe : texte non copié", DictationCoordinator.readyMessage(for: .refusedSecure)),
                ("Accessibilité non accordée", DictationCoordinator.readyMessage(for: .failed, accessibilityRefused: true)),
                ("Une touche encore tenue", DictationCoordinator.readyMessage(for: .failed, heldModifiers: ModifierMask.option)),
                ("Plusieurs touches encore tenues",
                 DictationCoordinator.readyMessage(for: .failed, heldModifiers: ModifierMask.control | ModifierMask.option)),
                ("Autre échec du collage", DictationCoordinator.readyMessage(for: .pending)),
                ("Dictée non enregistrée dans l'historique", "Historique indisponible. Copie le texte avant de fermer."),
            ]
            for item in cases {
                await showFailure(item.message, text: sampleText)
                snap(item.caption, into: &board)
                clearFailure()
            }
            await showFailure("Copié", copied: true)
            snap("Après « Copier »", into: &board)
            clearFailure()
            return board
        }

        func errors() async -> Board {
            var board = Board(file: "3-erreurs.png", title: "Erreurs", columns: 2)
            let cases: [(caption: String, message: String, history: Bool)] = [
                ("Micro trop lent à démarrer", DictationCoordinator.microphoneStalledMessage, false),
                ("Aucun micro disponible", AudioCaptureError.noInput.localizedDescription, false),
                ("Micro coupé pendant l'écoute", DictationCoordinator.microphoneLostMessage, false),
                ("Accès au micro retiré pendant l'écoute", DictationCoordinator.microphoneRevokedMessage, false),
                ("Accessibilité retirée pendant la dictée",
                 DictationCoordinator.keyboardLostMessage(KeyboardPermissions(listen: true, accessibility: false)), false),
                ("Surveillance des entrées retirée pendant la dictée",
                 DictationCoordinator.keyboardLostMessage(KeyboardPermissions(listen: false, accessibility: true)), false),
                ("Transcription impossible (réseau, clé, quota)",
                 "Transcription impossible. L'audio est gardé dans l'historique.", true),
                ("Consigne sur une sélection restée sans réponse", "Consigne non appliquée : la sélection est inchangée.", true),
            ]
            for item in cases {
                await showFailure(item.message, offersHistory: item.history)
                snap(item.caption, into: &board)
                clearFailure()
            }
            return board
        }

        func messages() async -> Board {
            var board = Board(file: "4-messages.png", title: "Messages", columns: 2)
            let notices: [(caption: String, message: String, relay: Bool, info: Bool)] = [
                ("Après « Coller » ou le raccourci", "Collé", false, false),
                ("Raccourci sans dictée à coller", "Aucune dictée à coller", false, true),
                ("Bascule de la correction", "DeepSeek ne répond pas : correction via OpenAI.", true, false),
                ("Bascule de la transcription", "xAI ne répond pas : voix via OpenAI.", true, false),
                ("Après une mise à jour", "Wispad 0.2.5 est installé", false, false),
            ]
            for item in notices {
                await showNotice(item.message, relay: item.relay, info: item.info)
                snap(item.caption, into: &board)
                coordinator.dismissCurrentNotice()
            }
            await showUpdate()
            snap("Nouvelle version disponible", into: &board)
            coordinator.dismissCurrentNotice()
            await showLearning(["Seedance"])
            snap("Mot appris de tes corrections", into: &board)
            coordinator.dismissCurrentNotice()
            await showLearning(sampleTerms)
            snap("Plusieurs mots appris", into: &board)
            coordinator.dismissCurrentNotice()
            let previews: [(caption: String, message: String)] = [
                ("Réglages › Bulle et messages : place de la dictée", "La bulle de dictée apparaîtra ici"),
                ("Réglages › Bulle et messages : place des alertes", "Les alertes de collage apparaîtront ici"),
                ("Réglages › Bulle et messages : place des messages", "Les messages apparaîtront ici"),
            ]
            for item in previews {
                await showNotice(item.message, info: true, seconds: 3)
                snap(item.caption, into: &board)
                coordinator.dismissCurrentNotice()
            }
            return board
        }

        func hovered() async -> Board {
            var board = Board(file: "5-survol.png", title: "Au survol : ✕ pour fermer, décompte en pause", columns: 2)
            model.overlay.state.isHovered = true
            defer { model.overlay.state.isHovered = false }
            await showFailure(DictationCoordinator.readyMessage(for: .failed), text: sampleText)
            snap("Texte prêt", into: &board)
            clearFailure()
            await showFailure("Transcription impossible. L'audio est gardé dans l'historique.")
            snap("Erreur", into: &board)
            clearFailure()
            await showNotice("Collé")
            snap("Message", into: &board)
            coordinator.dismissCurrentNotice()
            await showUpdate()
            snap("Nouvelle version", into: &board)
            coordinator.dismissCurrentNotice()
            await showLearning(sampleTerms)
            snap("Mots appris", into: &board)
            coordinator.dismissCurrentNotice()
            return board
        }

        /// Rend la bulle telle que l'app la montrerait pour l'état actuel du coordinateur.
        private func snap(_ caption: String, into board: inout Board) {
            guard let mode = OverlayMode.resolve(phase: coordinator.phase, notice: coordinator.notice,
                                                 confirmsLearning: coordinator.noticeConfirmsLearning,
                                                 offersUpdate: coordinator.noticeOffersUpdate) else {
                missing.append(caption)
                return
            }
            let content = OverlayCluster(mode: mode)
                .padding(16)
                .environment(model)
                .environment(\.colorScheme, .dark)
                .environment(\.overlayGlass, false)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage else {
                missing.append(caption)
                return
            }
            board.shots.append(Shot(caption: caption, image: image))
        }

        /// Le décompte a un peu couru, comme quelques instants après l'apparition ; figé pour le rendu.
        private func settle() async {
            try? await Task.sleep(nanoseconds: 600_000_000)
            coordinator.failureTimer.setPaused(true)
            coordinator.noticeTimer.setPaused(true)
        }

        private func showFailure(_ message: String, text: String? = nil, offersHistory: Bool = true, copied: Bool = false) async {
            coordinator.failureText = text
            coordinator.failureCopied = copied
            coordinator.failureOffersHistory = offersHistory
            coordinator.phase = .failure(message)
            let seconds = copied ? DictationCoordinator.copiedSeconds : DictationCoordinator.failureSeconds
            coordinator.failureTimer.start(seconds: seconds, paused: false) {}
            await settle()
        }

        private func clearFailure() {
            coordinator.failureTimer.cancel()
            coordinator.failureText = nil
            coordinator.failureCopied = false
            coordinator.failureOffersHistory = true
            coordinator.phase = .idle
        }

        private func showNotice(_ message: String, relay: Bool = false, info: Bool = false, seconds: Double? = nil) async {
            coordinator.announce(message, relay: relay, info: info, seconds: seconds)
            await settle()
        }

        private func showUpdate() async {
            guard let sampleVersion else { return }
            coordinator.announce(DictationCoordinator.updateMessage(sampleVersion), relay: false, offersUpdate: true,
                                 seconds: DictationCoordinator.updateSeconds)
            await settle()
        }

        private func showLearning(_ terms: [String]) async {
            coordinator.notifyLearned(terms)
            await settle()
        }
    }

    /// Planche : un titre, puis chaque bulle sous sa légende, sur un fond sombre comme celui d'une app.
    struct BoardView: View {
        var board: Board

        var body: some View {
            let columnWidth = max(240, board.shots.map { CGFloat($0.image.width) / 2 }.max() ?? 240)
            let rows = stride(from: 0, to: board.shots.count, by: board.columns).map {
                Array(board.shots[$0..<min($0 + board.columns, board.shots.count)])
            }
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: board.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 16)
                ForEach(rows.indices, id: \.self) { row in
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(rows[row].indices, id: \.self) { column in
                            let shot = rows[row][column]
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: shot.caption)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .padding(.leading, 16)
                                Image(decorative: shot.image, scale: 2)
                            }
                            .frame(width: columnWidth, alignment: .leading)
                        }
                    }
                }
            }
            .padding(24)
            .background(Color(white: 0.14))
            .environment(\.colorScheme, .dark)
        }
    }
}

#endif
