import AppKit
import WispadCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, MainMenuActions {
    private var model: AppModel?
    private var hotkeys: HotkeyMonitor?
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var retentionTimer: Timer?
    private var pendingReopen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Diagnostic de lecture : pas de Dock, pas de fenêtre, pas d'activation.
        if CommandLine.arguments.contains("--window-context-probe") {
            WindowTextProbe.runDiagnostic(arguments: CommandLine.arguments)
        }
        #endif
        // Toujours dans le Dock : on retrouve Wispad, et un clic sur son icône rouvre la fenêtre.
        // (Info.plist garde LSUIElement pour les modes de test et de diagnostic, qui restent invisibles.)
        NSApp.setActivationPolicy(.regular)
        MainMenu.install()
        // Wispad a pu quitter en pleine dictée, son coupé : on le rétablit.
        // Données de l'ancien identifiant (OpenFlow) reprises avant d'ouvrir la base et de relire le son coupé.
        LegacyMigration.runAtLaunch()
        AppSettings.removeRetiredKeys()
        // Modèles et clé laissés par des fonctions retirées.
        RetiredFeatures.runAtLaunch()
        OutputMuter.recoverAfterCrash()
        SoundCues.prepare()
        // Liste des composants audio de macOS chargée tout de suite, en arrière-plan, sans moteur ni micro : la
        // première dictée (après une mise à jour aussi) n'attend plus jusqu'à 3 s que le service système réponde.
        AudioCapture.preloadComponents()
        do {
            let model = try AppModel()
            self.model = model
            // Avant toute fenêtre (premier lancement guidé compris) : l'apparence choisie, sinon celle de macOS.
            AppearanceSwitcher.apply(model.settings.appearance, animated: false)
            model.overlay.install(model: model)
            let hotkeys = HotkeyMonitor()
            hotkeys.start(model: model)
            model.hotkeys = hotkeys
            self.hotkeys = hotkeys
            model.onOpenWindow = { [weak self] section in
                self?.show(section: section)
            }
            model.coordinator.onChange = { [weak self] in
                self?.updateIcon()
            }
            installStatusItem()
            // Dernière release (ou, pour un build de développement, retard sur le dépôt public) : en arrière-plan, après
            // le démarrage, puis toutes les 6 heures. Une version plus récente est rappelée une fois dans la bulle.
            BuildStatus.shared.onAvailable = { [weak model] release in model?.noteAvailableRelease(release) }
            BuildStatus.shared.start()
            model.isWindowVisible = { [weak self] in self?.window?.isVisible == true }
            model.updater.removeLeftovers()
            // Relancé par une mise à jour en un clic : la bulle le confirme, sans prendre le focus.
            if CommandLine.arguments.contains("--updated") { model.announceUpdated() }
            retentionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak model] _ in
                Task { @MainActor in
                    model?.purgeAudio()
                    await model?.checkDownServices()
                }
            }
            // Toujours chaque minute, à quelques secondes près : macOS peut grouper ce réveil avec d'autres au repos.
            retentionTimer?.tolerance = 6
            Task { @MainActor [weak self] in
                await model.refreshKeys()
                // Relance technique ou diagnostic : aucune fenêtre, même si le coffre ne répond pas.
                guard !CommandLine.arguments.contains("--status-diagnostic"),
                      !CommandLine.arguments.contains("--window-context-probe"),
                      !CommandLine.arguments.contains("--background"),
                      !CommandLine.arguments.contains("--offscreen") else { return }
                // `--section usage` (ou autre) ouvre directement la fenêtre sur cette section.
                if let index = CommandLine.arguments.firstIndex(of: "--section"),
                   CommandLine.arguments.indices.contains(index + 1),
                   let section = AppSection(rawValue: CommandLine.arguments[index + 1]) {
                    self?.show(section: section)
                } else if model.onboarding != nil {
                    self?.show(section: .home)
                } else if model.setupWarning != nil {
                    self?.show(section: .providers)
                }
            }
        } catch {
            if CommandLine.arguments.contains("--background") || CommandLine.arguments.contains("--offscreen") || CommandLine.arguments.contains("--status-diagnostic") || CommandLine.arguments.contains("--window-context-probe") {
                print("Démarrage de Wispad impossible : stockage local indisponible.")
                NSApp.terminate(nil)
                return
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "Wispad ne peut pas démarrer")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        retentionTimer?.invalidate()
        model?.historyPlayer.close()
        model?.coordinator.cancel()
        OutputMuter.restore()
    }

    func show(section: AppSection) {
        guard let model else { return }
        model.selectedSection = section
        NSApp.setActivationPolicy(.regular)
        let window = self.window ?? makeWindow(model: model)
        let reopening = self.window != nil && !window.isVisible
        self.window = window
        MainWindow.bringToFront(window)
        if reopening { model.onboarding?.resume() }
    }

    func windowWillClose(_ notification: Notification) {
        model?.historyPlayer.close()
        // Fenêtre fermée pendant la configuration guidée : micro du test et écoute de la touche rendus,
        // pour que fn dicte de nouveau normalement.
        model?.onboarding?.suspend()
    }

    /// Ouverture à la main (Dock, Spotlight, Finder) alors que Wispad tourne déjà : on montre la fenêtre.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Une relance `open -g` ne doit pas activer l'app. Finder/Dock l'activent eux-mêmes ;
        // si leur événement arrive tôt, attendre cette activation avant de montrer la fenêtre.
        guard sender.isActive else {
            pendingReopen = true
            return false
        }
        pendingReopen = false
        show(section: model?.selectedSection ?? .home)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Retour de Réglages Système : une autorisation a pu y être retirée ou rendue. Réglages › Autorisations et la
        // barre latérale le montrent aussitôt, sans attendre qu'on rouvre l'écran ; lu hors du fil principal.
        model?.refreshPermissionsInBackground()
        guard pendingReopen else { return }
        pendingReopen = false
        show(section: model?.selectedSection ?? .home)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let window = MainWindow.make(model: model)
        window.delegate = self
        return window
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Empêche un retrait accidentel (⌘-glisser hors de la barre). Le nom par défaut garde la place déjà choisie.
        item.behavior = []
        item.button?.image = BrandIcon.menuBarImage(listening: false)
        item.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu()
        #if DEBUG
        if CommandLine.arguments.contains("--status-diagnostic") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let window = item.button?.window
                print("STATUS visible=\(item.isVisible) frame=\(window?.frame ?? .zero) occlusionVisible=\(window?.occlusionState.contains(.visible) ?? false) screen=\(window?.screen?.frame ?? .zero)")
                exit(0)
            }
        }
        #endif
    }

    private func updateIcon() {
        let listening = model?.coordinator.isListening == true
        // Image modèle dans les deux états : la teinte rouge s'applique en écoute.
        statusItem?.button?.image = BrandIcon.menuBarImage(listening: listening)
        statusItem?.button?.contentTintColor = listening ? .systemRed : nil
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu, let model else { return }
        menu.removeAllItems()
        for item in StatusMenu.items(model: model, target: self) {
            menu.addItem(item)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    @objc private func toggleDictation() {
        guard let model else { return }
        switch model.coordinator.phase {
        case .listening:
            model.hotkeys?.sessionEnded()
            model.coordinator.enqueue { model.coordinator.endCapture() }
        case .starting:
            return
        case .idle, .finishing, .failure:
            model.hotkeys?.externalToggleStarted()
            model.coordinator.enqueue { await model.coordinator.begin(.toggle) }
        }
    }

    @objc private func cancelDictation() {
        model?.coordinator.cancel()
    }

    @objc private func retryServices() {
        guard let model else { return }
        Task { await model.checkDownServices() }
    }

    @objc private func removeLearned(_ sender: NSMenuItem) {
        guard let term = sender.representedObject as? String else { return }
        model?.removeTerm(named: term)
    }

    @objc private func copyLastDictation() {
        guard let model, let last = model.history.first(where: { !$0.finalText.isEmpty }) else { return }
        model.copy(last.finalText)
    }

    /// « Ouvrir Wispad » : la dernière section ouverte, retrouvée après une relance.
    @objc private func openWindow() { show(section: model?.selectedSection ?? .home) }
    @objc private func openUsage() { show(section: .usage) }
    @objc private func openHistory() { show(section: .history) }
    @objc private func openDictionary() { show(section: .dictionary) }
    @objc func openSettings() { show(section: .settings) }

    /// Menu Présentation : ⌘1 à ⌘6.
    @objc func openSectionFromMenu(_ sender: NSMenuItem) {
        guard AppSection.allCases.indices.contains(sender.tag) else { return }
        show(section: AppSection.allCases[sender.tag])
    }

    /// Menu de la barre et menu Aide : la page GitHub s'ouvre dans le navigateur, sans ouvrir la fenêtre de Wispad.
    @objc func reportProblem() { HelpPage.reportProblem.open() }
    @objc func proposeIdea() { HelpPage.proposeIdea.open() }

    @objc private func quit() { NSApp.terminate(nil) }
}
