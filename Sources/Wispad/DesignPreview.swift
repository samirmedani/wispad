import AppKit
import CryptoKit
import WispadCore
import SwiftUI

// Outil de développement : absent de la version Release.
#if DEBUG

/// `--design-preview [--section usage] [--dark|--light] [--banner] [--relay]` : fenêtre principale
/// remplie de données fictives. Ni micro, ni raccourci global, ni coffre, ni API, ni réglages réels :
/// tout vit dans un dossier temporaire, hors écran par défaut, sans focus ni icône du Dock.
/// `--show-window` permet un aperçu visible uniquement sur demande explicite de l'utilisateur.
/// `--offscreen` force toujours le rendu hors écran, même si `--show-window` est présent.
/// `--history-count N` ajoute N longues dictées fictives le même jour ; `--performance-probe`
/// mesure deux ouvertures de l'historique, séparées par un retour à l'accueil, puis un défilement simulé
/// (`--scroll-steps N`, 240 par défaut) vers le bas puis vers le haut, et quitte.
/// `--audio-preview` ouvre le lecteur avec un WAV silencieux de 30 secondes, entièrement fictif.
/// `--fallback-preview` ajoute des bascules fictives et ouvre Consommation.
/// `--blur-recent` masque les extraits fictifs de la carte d'accueil.
/// `--details-preview` ajoute un diagnostic fictif avec bascule et retranscription.
/// `--usage-accuracy-preview` ajoute des coûts inconnus pour contrôler les minimums affichés.
/// `--hover-preview` montre les accents de survol ; `--reduce-motion` vérifie le mode sans mouvement.
/// `--privacy-text-preview` rend aussi le composant de texte visible/masqué, sans limite du cache AppKit.
/// `--customer-preview` : clés enregistrées dans le fichier local, une clé xAI fictive.
/// `--report-preview` : rend aussi le détail de la première dictée, saisie « Signaler une erreur » ouverte.
/// `--onboarding-step <étape> [--onboarding-state done|failed|progress]` : une étape du premier lancement guidé
/// avec un état fictif (réussi, problème, en cours), sans aucune demande d'autorisation.
/// `--shortcut-preview custom|long|disabled|recording` : Réglages › Raccourci avec des raccourcis fictifs.
@MainActor
enum DesignPreview {
    static func run(arguments: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--light") { app.appearance = NSAppearance(named: .aqua) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-design-preview-\(UUID().uuidString)")
        let performanceProbe = arguments.contains("--performance-probe")
        let audioPreview = arguments.contains("--audio-preview")
        let historyCount: Int?
        if let index = arguments.firstIndex(of: "--history-count"),
           arguments.indices.contains(index + 1), let count = Int(arguments[index + 1]) {
            historyCount = min(max(count, 0), 20_000)
        } else {
            historyCount = nil
        }
        let model: AppModel
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dependencies = AppDependencies()
            let customerPreview = arguments.contains("--customer-preview")
            dependencies.keyStore = customerPreview ? .file : .vault
            dependencies.loadKey = { account in customerPreview && account == ProviderID.xai.rawValue ? "fixture-key" : nil }
            dependencies.refreshKeys = { customerPreview }
            model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
            var audioURL: URL?
            if audioPreview {
                let url = directory.appendingPathComponent("preview.wav")
                let bytes = 30 * 24_000 * 2
                var wav = WAVHeader.make(dataBytes: bytes, sampleRate: 24_000)
                wav.append(Data(repeating: 0, count: bytes))
                try wav.write(to: url)
                audioURL = url
            }
            try seed(model.store, historyCount: historyCount, audioURL: audioURL)
            if arguments.contains("--details-preview") { try seedDetails(model.store) }
            if arguments.contains("--fallback-preview") { try seedFallbacks(model.store) }
            if arguments.contains("--usage-accuracy-preview") {
                for api in [UsageAPI.deepSeekCleanup, .openAIFile] {
                    try model.store.insertUsage(UsageEvent(api: api, model: "fixture", costUSD: nil, succeeded: false))
                }
            }
            model.reload()
        } catch {
            print("Aperçu impossible : \(error.localizedDescription)")
            return
        }
        if !performanceProbe, let index = arguments.firstIndex(of: "--section"),
           arguments.indices.contains(index + 1),
           let section = AppSection(rawValue: arguments[index + 1]) {
            model.selectedSection = section
        }
        if audioPreview, let record = model.history.first(where: { $0.audioPath != nil }) {
            model.selectedSection = .history
            model.play(record)
            model.historyPlayer.stop()
        }
        if arguments.contains("--fallback-preview") || arguments.contains("--usage-accuracy-preview") { model.selectedSection = .usage }
        if arguments.contains("--blur-recent") { model.settings.blurRecentDictations = true }
        // `--onboarding-step welcome|permissions|microphone|provider|shortcut|trial|finish`
        // `[--onboarding-state done|failed|progress]` : premier lancement à cette étape, avec un état fictif.
        // Aucune autorisation n'est demandée ni lue, aucun micro ouvert, aucune touche écoutée.
        if let index = arguments.firstIndex(where: { $0 == "--onboarding-step" || $0 == "--onboarding" }),
           arguments.indices.contains(index + 1) {
            let step = OnboardingStep(rawValue: arguments[index + 1]) ?? .welcome
            var state = OnboardingController.PreviewState.done
            if let stateIndex = arguments.firstIndex(of: "--onboarding-state"), arguments.indices.contains(stateIndex + 1) {
                state = OnboardingController.PreviewState(rawValue: arguments[stateIndex + 1]) ?? .done
            }
            model.settings.onboardingCompleted = false
            model.onboarding = OnboardingController.preview(model: model, step: step, state: state)
        } else {
            model.settings.onboardingCompleted = true
            model.onboarding = nil
        }
        // `--relay` : DeepSeek mis de côté, pour voir l'état des services et la ligne de relais.
        if arguments.contains("--relay") {
            model.health.record(ServiceHealth.deepSeek, succeeded: false)
            model.health.record(ServiceHealth.deepSeek, succeeded: false)
        }
        if arguments.contains("--banner") {
            model.statusBanner = "Ajouté au dictionnaire : Seedance."
        }
        if let index = arguments.firstIndex(of: "--shortcut-preview"), arguments.indices.contains(index + 1) {
            previewShortcuts(model, state: arguments[index + 1])
        }
        let offscreen = arguments.contains("--offscreen") || arguments.contains("--background") || !arguments.contains("--show-window")
        let renderedRows = HistoryProbeRenderCount()
        let rowDidRender: HistoryRowRenderCallback?
        if performanceProbe {
            rowDidRender = { @MainActor @Sendable id in renderedRows.record(id) }
        } else {
            rowDidRender = nil
        }
        let window = MainWindow.make(model: model, offscreen: offscreen, historyRowDidRender: rowDidRender,
                                    interactionPreviewHover: arguments.contains("--hover-preview"),
                                    reduceMotion: arguments.contains("--reduce-motion") ? true : nil)
        if let index = arguments.firstIndex(of: "--size"), arguments.indices.contains(index + 1) {
            let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { window.setContentSize(NSSize(width: parts[0], height: parts[1])) }
        }
        if offscreen {
            // Jamais visible : si macOS ramenait la fenêtre sur un écran, on la retire et on quitte.
            guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { exit(2) }
            window.orderFrontRegardless()
            guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
                window.orderOut(nil)
                exit(2)
            }
        } else {
            app.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            app.activate()
        }
        print("PREVIEW offscreen=\(offscreen) active=\(app.isActive) onScreen=\(NSScreen.screens.contains { $0.frame.intersects(window.frame) })")
        print("WINDOW \(window.windowNumber)")
        fflush(stdout)
        if performanceProbe {
            var scrollSteps = 240
            if let index = arguments.firstIndex(of: "--scroll-steps"),
               arguments.indices.contains(index + 1), let steps = Int(arguments[index + 1]) {
                scrollSteps = min(max(steps, 0), 5_000)
            }
            runPerformanceProbe(model: model, window: window, directory: directory, renderedRows: renderedRows,
                                scrollSteps: scrollSteps)
        } else if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
            let path = arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                snapshot(window, to: URL(fileURLWithPath: path))
                if arguments.contains("--privacy-text-preview") {
                    do {
                        try privacyTextSnapshots(to: URL(fileURLWithPath: path))
                    } catch {
                        print("PRIVACY_TEXT_RENDER failed")
                        try? FileManager.default.removeItem(at: directory)
                        exit(2)
                    }
                }
                if arguments.contains("--report-preview"), let record = model.history.first {
                    reportSnapshot(record: record, model: model, to: URL(fileURLWithPath: path))
                }
                model.historyPlayer.close()
                try? FileManager.default.removeItem(at: directory)
                exit(0)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { model.historyPlayer.close() }
            try? FileManager.default.removeItem(at: directory)
            exit(0)
        }
        app.run()
    }

    /// Raccourcis fictifs de Réglages › Raccourci : choisis par l'utilisateur (↺ visible), la plus longue
    /// combinaison possible, raccourci désactivé, ou les deux enregistrements en cours avec une combinaison refusée.
    /// Rien n'est écouté : seul l'affichage change.
    private static func previewShortcuts(_ model: AppModel, state: String) {
        let control = ModifierMask.control, option = ModifierMask.option
        switch state {
        case "custom":
            model.settings.keyCode = 49
            model.settings.modifierFlags = option
            model.settings.pasteLastShortcut = PasteShortcut(keyCode: 35, modifiers: control | ModifierMask.shift)
        case "long":
            model.settings.pasteLastShortcut = PasteShortcut(
                keyCode: PasteShortcut.vKeyCode, modifiers: control | option | ModifierMask.shift | ModifierMask.command)
        case "disabled":
            model.settings.pasteLastShortcut.enabled = false
        case "recording":
            model.isRecordingShortcut = true
            model.isRecordingPasteShortcut = true
            let copy = PasteShortcut(keyCode: 8, modifiers: ModifierMask.command)
            model.pasteShortcutProblem = PasteShortcutText.message(for: .reserved(.copy), shortcut: KeyLabels.describe(copy))
        default:
            break
        }
    }

    /// ImageRenderer prend en charge ce composant purement SwiftUI, contrairement au cache NSHostingView.
    private static func privacyTextSnapshots(to url: URL) throws {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for hidden in [false, true] {
            let content = RecentDictationText(text: "Une dictée fictive pour vérifier les contours doux du flou et le retour au texte.", blurred: hidden)
                .frame(width: 360, alignment: .leading)
                .padding(20)
                .background(Theme.card)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.interactionPreviewReduceMotion, true)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = url.deletingPathExtension().appendingPathExtension(hidden ? "blur.png" : "visible.png")
            try data.write(to: output)
            print("PRIVACY_TEXT_RENDER hidden=\(hidden) path=\(output.path)")
        }
    }

    /// Mesure la préparation du contenu sur le fil principal, hors création des données.
    /// Le délai entre visites laisse les animations précédentes finir, mais n'entre pas dans les temps.
    /// Le résultat inclut la prochaine mise à jour SwiftUI et le layout/display forcé ; il ne mesure pas
    /// le moment où le compositeur présente la dernière image d'une animation.
    private static func runPerformanceProbe(model: AppModel, window: NSWindow, directory: URL,
                                            renderedRows: HistoryProbeRenderCount, scrollSteps: Int) {
        let sections: [AppSection] = [.history, .home, .history]
        func measure(_ index: Int) {
            guard let view = window.contentView else {
                try? FileManager.default.removeItem(at: directory)
                exit(0)
            }
            guard index < sections.count else {
                runScrollProbe(model: model, view: view, renderedRows: renderedRows, steps: scrollSteps) {
                    try? FileManager.default.removeItem(at: directory)
                    exit(0)
                }
                return
            }
            let section = sections[index]
            renderedRows.reset()
            let start = ContinuousClock.now
            model.selectedSection = section
            DispatchQueue.main.async {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let duration = start.duration(to: .now).components
                let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
                print("PERFORMANCE records=\(model.history.count) visit=\(index + 1) section=\(section.rawValue) selection_layout_display_ms=\(String(format: "%.2f", milliseconds)) native_views=\(nativeViewCount(view)) row_count=\(renderedRows.count)")
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { measure(index + 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { measure(0) }
    }

    /// Défilement simulé de l'historique, sans souris ni écran : la vue de défilement avance de 60 points par étape,
    /// une étape par tour de boucle, vers le bas puis vers le haut (lignes déjà vues). Chaque étape mesure la mise à jour
    /// SwiftUI, le layout et l'affichage forcés ; une étape de plus de 16,7 ms aurait manqué une image à 60 Hz.
    /// `row_evaluations` compte les passages dans le corps des lignes, `row_count` les lignes distinctes.
    private static func runScrollProbe(model: AppModel, view: NSView, renderedRows: HistoryProbeRenderCount,
                                       steps: Int, completion: @escaping @MainActor @Sendable () -> Void) {
        guard steps > 0, let scrollView = largestScrollView(in: view), let document = scrollView.documentView else {
            print("PERFORMANCE scroll=unavailable")
            fflush(stdout)
            completion()
            return
        }
        let clip = scrollView.contentView
        let stepHeight: CGFloat = 60
        // La hauteur estimée du document change pendant que les lignes paresseuses se construisent.
        func maxOffset() -> CGFloat { max(document.frame.height - clip.bounds.height, 0) }
        // Le haut du document est à y = 0 dans une vue retournée (cas de SwiftUI), à y = max sinon.
        func origin(forOffset offset: CGFloat) -> CGFloat { document.isFlipped ? offset : maxOffset() - offset }
        let directions: [(name: String, sign: CGFloat)] = [("down", 1), ("up", -1)]
        let state = ScrollProbeState()

        func run(direction: Int, step: Int) {
            guard direction < directions.count else {
                completion()
                return
            }
            if step == 0 {
                renderedRows.reset()
                state.durations.removeAll(keepingCapacity: true)
            }
            guard step < steps else {
                let durations = state.durations
                let sorted = durations.sorted()
                let total = durations.reduce(0, +)
                let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                let mean = durations.isEmpty ? 0 : total / Double(durations.count)
                let fields: [String] = [
                    "records=\(model.history.count)",
                    "scroll=\(directions[direction].name)",
                    "steps=\(durations.count)",
                    "offset=\(Int(state.offset))",
                    "total_ms=\(String(format: "%.2f", total))",
                    "mean_ms=\(String(format: "%.2f", mean))",
                    "p95_ms=\(String(format: "%.2f", p95))",
                    "max_ms=\(String(format: "%.2f", sorted.last ?? 0))",
                    "over_16ms=\(durations.filter { $0 > 1_000 / 60 }.count)",
                    "row_evaluations=\(renderedRows.evaluations)",
                    "row_count=\(renderedRows.count)",
                ]
                print("PERFORMANCE " + fields.joined(separator: " "))
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(direction: direction + 1, step: 0) }
                return
            }
            state.offset = min(max(state.offset + directions[direction].sign * stepHeight, 0), maxOffset())
            let start = ContinuousClock.now
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: origin(forOffset: state.offset)))
            scrollView.reflectScrolledClipView(clip)
            DispatchQueue.main.async {
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let duration = start.duration(to: .now).components
                state.durations.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
                run(direction: direction, step: step + 1)
            }
        }
        run(direction: 0, step: 0)
    }

    private static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    private static func nativeViewCount(_ view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + nativeViewCount($1) }
    }

    /// Rendu de la fenêtre dans un PNG, sans passer par l'écran.
    /// Détail d'une dictée avec la saisie « Ce que tu as vraiment dit » ouverte, hors écran.
    private static func reportSnapshot(record: DictationRecord, model: AppModel, to url: URL) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DictationDetailView(record: record, reporting: true).environment(model))
        window.orderFrontRegardless()
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            window.orderOut(nil)
            return
        }
        window.contentView?.layoutSubtreeIfNeeded()
        snapshot(window, to: url.deletingPathExtension().appendingPathExtension("report.png"))
        window.orderOut(nil)
    }

    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("SNAPSHOT \(url.path)")
    }

    private static let apps: [(name: String, bundle: String)] = [
        ("Slack", "com.tinyspeck.slackmacgap"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Mail", "com.apple.mail"),
        ("Safari", "com.apple.Safari"),
        ("Notes", "com.apple.Notes"),
        ("Claude", "com.anthropic.claudefordesktop"),
    ]

    private static let texts = [
        "Salut, je regarde ça ce soir et je te fais un retour demain matin.",
        "Ajoute un test pour le cas où la clé API est vide, puis relance la suite complète.",
        "Merci pour l'envoi. Je confirme le rendez-vous de jeudi à 14 h au bureau.",
        "Peux-tu vérifier pourquoi le build échoue sur la branche principale depuis hier ?",
        "Idée : afficher le temps économisé directement dans la barre des menus.",
        "Rappelle-moi d'appeler le fournisseur pour la facture de septembre.",
        "Refactorise ce composant pour séparer l'affichage de la logique de chargement.",
        "On part sur la version deux, plus simple, et on garde l'ancienne derrière un réglage.",
    ]

    private static let statuses: [InsertionStatus] = [.inserted, .inserted, .inserted, .pasteSent, .inserted, .pending, .inserted, .transcriptionFailed]

    private static func seedFallbacks(_ store: HistoryStore) throws {
        for index in 0..<10 {
            let stage: FallbackStage = index < 3 ? .transcription : (index < 8 ? .correction : .dictionary)
            let from: UsageAPI = stage == .transcription ? .xaiFile : (stage == .dictionary ? .typesafeJudge : .deepSeekCleanup)
            let to: UsageAPI = stage == .transcription ? .openAIFile : .openAICleanup
            try store.insertUsage(UsageEvent(
                api: to,
                model: stage == .transcription ? "gpt-transcribe" : CleanupModel.openAIFallback,
                audioSeconds: stage == .transcription ? 12 : 0,
                costUSD: 0.0004,
                latencyMs: 450,
                succeeded: index != 7,
                fallback: APIFallback(fromAPI: from, stage: stage, reason: stage == .correction && index >= 6 ? .servicePaused : .requestFailed)
            ))
        }
    }

    private static func seedDetails(_ store: HistoryStore) throws {
        guard let record = try store.dictations().first else { return }
        let calls = [
            UsageEvent(api: .xaiStreaming, model: record.model, costUSD: 0, latencyMs: 130, succeeded: false),
            UsageEvent(api: .xaiFile, model: record.model, costUSD: 0.001, latencyMs: 420),
            UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0, latencyMs: 900, succeeded: false),
            UsageEvent(api: .openAICleanup, model: CleanupModel.openAIFallback, costUSD: 0.001, latencyMs: 800,
                       fallback: APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed))
        ]
        try store.saveTrace(DictationTrace(
            dictationID: record.id, createdAt: record.createdAt, origin: .toggle,
            timings: DictationTimings(microphoneMs: 130, firstAudioMs: 214, streamReadyMs: 320,
                                     transcriptionMs: 560, correctionMs: 1_800, insertionMs: 90, afterReleaseMs: 2_460),
            calls: calls.map(DictationAPICall.init), outcome: .inserted
        ))
        try store.saveTrace(DictationTrace(
            dictationID: record.id, createdAt: record.createdAt.addingTimeInterval(60), origin: .retry,
            timings: DictationTimings(transcriptionMs: 450, correctionMs: 810),
            calls: [DictationAPICall(UsageEvent(api: .xaiFile, model: record.model, costUSD: 0.001, latencyMs: 450))],
            outcome: .pending
        ))
        try store.saveTrace(DictationTrace(origin: .hold, outcome: .microphoneDenied))
        try store.updateStatus(id: record.id, status: InsertionStatus.pending.rawValue)
    }

    /// Données déterministes : un mois d'activité, plus dense ces derniers jours.
    private static func seed(_ store: HistoryStore, historyCount: Int? = nil, audioURL: URL? = nil) throws {
        let now = Date()
        var generator = SeededGenerator(seed: 42)
        let offsets: [Double]
        if let historyCount {
            // 20 000 maximum : les dates restent toutes dans la même journée.
            let latest = Calendar.current.startOfDay(for: now).addingTimeInterval(43_200)
            offsets = (0..<historyCount).map { now.timeIntervalSince(latest) + Double($0) }
        } else {
            offsets = (0..<46).map { index in
                let base = index < 14 ? Double(index) * 0.32 : 4.5 + Double(index - 14) * 0.8
                return base * 86_400 + Double.random(in: 600...20_000, using: &generator)
            }
        }
        for (index, offset) in offsets.enumerated() {
            let date = now.addingTimeInterval(-offset)
            let app = apps[Int.random(in: 0..<apps.count, using: &generator)]
            let text = historyCount == nil ? texts[index % texts.count] : Array(repeating: texts[index % texts.count], count: 6).joined(separator: " ")
            let status = statuses[index % statuses.count]
            let words = status == .transcriptionFailed ? 0 : WordCount.count(text) + Int.random(in: 0...40, using: &generator)
            let duration = Double(max(words, 12)) / Double.random(in: 2.4...3.4, using: &generator)
            try store.insert(DictationRecord(
                createdAt: date,
                finalText: status == .transcriptionFailed ? "" : text,
                rawText: text,
                durationSeconds: duration,
                wordCount: words,
                provider: "xAI",
                model: "grok-voice-transcribe-2.0",
                targetApp: app.name,
                targetBundle: app.bundle,
                usageCategory: UsageClassifier.classify(bundleIdentifier: app.bundle, appName: app.name).rawValue,
                insertionStatus: status.rawValue,
                audioPath: index % 3 == 0 ? (audioURL?.path ?? "/tmp/wispad-preview-\(index).wav") : nil
            ))
            try store.insertUsage(.transcription(
                provider: .xai,
                streaming: true,
                model: "grok-voice-transcribe-2.0",
                audioSeconds: duration,
                latencyMs: Int.random(in: 180...420, using: &generator),
                at: date
            ))
            let tokens = TokenUsage(input: Int.random(in: 500...1_200, using: &generator), cachedInput: 320, output: words + 20)
            try store.insertUsage(UsageEvent(
                createdAt: date.addingTimeInterval(1),
                api: .deepSeekCleanup,
                model: CleanupModel.deepSeek,
                tokens: tokens,
                costUSD: Pricing.tokenCost(model: CleanupModel.deepSeek, tokens: tokens, at: date),
                latencyMs: Int.random(in: 300...900, using: &generator)
            ))
        }
        // Toutes les origines : à la main, apprises (Jev, modèle de correction) et d'avant le suivi.
        let jev = DictionaryJudge(kind: .jev, provider: UsageAPI.typesafeJudge.provider, model: JevJudge.model)
        let deepSeek = DictionaryJudge(kind: .correctionModel, provider: "DeepSeek", model: CleanupModel.deepSeek)
        let openAI = DictionaryJudge(kind: .correctionModel, provider: "OpenAI", model: CleanupModel.openAIFallback)
        let terms: [(String, DictionaryOrigin)] = [
            ("SwiftUI", .user), ("RevenueCat", .user), ("Seedance", .learned(jev)), ("Grafana", .learned(deepSeek)),
            ("Kubernetes", .unknown), ("DeepSeek", .user), ("xAI", .unknown), ("Supabase", .learned(openAI)),
            ("Next.js", .unknown), ("PostgreSQL", .learned(jev)), ("Terraform", .user), ("Figma", .unknown)
        ]
        for (term, origin) in terms {
            try store.addTerm(term, origin: origin)
        }
    }
}

@MainActor
private final class ScrollProbeState {
    var durations: [Double] = []
    var offset: CGFloat = 0
}

@MainActor
private final class HistoryProbeRenderCount {
    private var ids: Set<String> = []
    private(set) var evaluations = 0
    var count: Int { ids.count }

    func record(_ id: String) {
        ids.insert(id)
        evaluations += 1
    }

    func reset() {
        ids.removeAll(keepingCapacity: true)
        evaluations = 0
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

#endif
