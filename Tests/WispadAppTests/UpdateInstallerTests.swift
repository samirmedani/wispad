import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Installation en un clic sur des frontières simulées : aucun réseau, aucun disque monté, aucune app remplacée ni
/// relancée. Seul le paquet .app change de place ; réglages, clés, historique et dictionnaire n'y sont pas.
@MainActor
struct UpdateInstallerTests {
    @MainActor final class Journal {
        var steps: [String] = []
        var opened: [URL] = []
        var removed: [URL] = []
        var relaunched: [String]?
        var terminated = false
        /// Étape affichée au moment où la fermeture est demandée.
        var phaseAtTerminate: UpdateInstaller.Phase?
        /// Fin de l'installation, dans l'ordre : fenêtres refermées, fermeture demandée, arrêt forcé.
        var quitSteps: [String] = []
        var downloadError: Error?
        var signatureValid = true
        var diskVersion: String? = "0.1.2"
        var idle = true
    }

    private static var app: URL { URL(fileURLWithPath: "/Applications/Wispad.app") }
    private static var staged: URL { UpdateInstallRules.stagingURL(for: app) }
    private static var release: ReleaseInfo {
        ReleaseInfo(
            version: SemanticVersion(major: 0, minor: 1, patch: 2), tag: "v0.1.2", notes: "",
            pageURL: ReleaseCheck.releasesURL.appendingPathComponent("tag/v0.1.2"),
            diskImage: DiskImageAsset(url: ReleaseCheck.releasesURL.appendingPathComponent("download/v0.1.2/Wispad.dmg"))
        )
    }

    private func makeInstaller(_ journal: Journal, writable: Bool = true, team: String? = "ABCDE12345") -> UpdateInstaller {
        let installer = UpdateInstaller()
        var system = UpdateSystem()
        system.appURL = { Self.app }
        system.teamID = { team }
        system.isWritable = { _ in writable }
        system.makeWorkspace = { URL(fileURLWithPath: "/private/tmp/wispad-update-test", isDirectory: true) }
        system.download = { _, _, progress in
            journal.steps.append("download")
            if let error = journal.downloadError { throw error }
            progress(0.5)
            progress(1)
        }
        system.mount = { _, _ in
            journal.steps.append("mount")
            return URL(fileURLWithPath: "/Volumes/Wispad", isDirectory: true)
        }
        system.detach = { _ in journal.steps.append("detach") }
        system.bundleVersion = { _ in journal.diskVersion }
        system.verify = { url, _ in
            journal.steps.append("verify " + url.lastPathComponent)
            return journal.signatureValid
        }
        system.copy = { _, destination in journal.steps.append("copy " + destination.lastPathComponent) }
        system.swap = { staged, app in journal.steps.append("swap \(staged.lastPathComponent) \(app.lastPathComponent)") }
        system.remove = { journal.removed.append($0) }
        // Verrou entre instances toujours libre ici (le vrai est testé dans UpdateToolsTests) : les tests, lancés en
        // parallèle, ne se le disputent pas.
        system.lock = { {} }
        system.relaunch = { _, arguments in
            journal.relaunched = arguments
            return true
        }
        // Le vrai NSApp.terminate ne rend la main que si macOS refuse de fermer l'app : ici, il la rend toujours.
        system.terminate = { [weak installer] in
            journal.phaseAtTerminate = installer?.phase
            journal.terminated = true
            journal.quitSteps.append("fermeture")
        }
        system.forceQuit = { journal.quitSteps.append("arrêt forcé") }
        system.open = { journal.opened.append($0) }
        installer.system = system
        return installer
    }

    @discardableResult
    private func install(_ installer: UpdateInstaller, _ journal: Journal) -> Bool {
        installer.install(Self.release, kind: .release, installed: "0.1.1", isIdle: { journal.idle },
                          relaunchArguments: { ["--updated", "--section", "home"] },
                          beforeQuit: { journal.quitSteps.append("fenêtres") })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        // Rend la main dès que la condition est vraie ; la marge sert aux machines de CI chargées.
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("délai dépassé")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Retour en arrière demandé dans Réglages : la version plus ancienne demandée s'installe avec les mêmes
    /// vérifications ; une autre version du disque est refusée sans rien remplacer.
    @Test func aRequestedPreviousVersionIsVerifiedThenInstalled() async throws {
        let journal = Journal()
        journal.diskVersion = "0.1.0"
        let installer = makeInstaller(journal)
        let older = ReleaseInfo(
            version: SemanticVersion(major: 0, minor: 1, patch: 0), tag: "v0.1.0", notes: "",
            pageURL: ReleaseCheck.releasesURL.appendingPathComponent("tag/v0.1.0"),
            diskImage: DiskImageAsset(url: ReleaseCheck.releasesURL.appendingPathComponent("download/v0.1.0/Wispad.dmg"))
        )
        func revert() -> Bool {
            installer.install(older, kind: .release, installed: "0.1.1", target: older.version, isIdle: { journal.idle },
                              relaunchArguments: { ["--updated"] }, beforeQuit: { journal.quitSteps.append("fenêtres") })
        }
        journal.diskVersion = "0.0.9"
        #expect(revert())
        try await waitUntil { !installer.isBusy }
        #expect(installer.phase == .failed(.notRequested))
        #expect(!journal.steps.contains { $0.hasPrefix("copy") || $0.hasPrefix("swap") })
        journal.steps = []
        journal.diskVersion = "0.1.0"
        #expect(revert())
        try await waitUntil { journal.terminated }
        #expect(installer.target == older.version)
        #expect(journal.steps == ["download", "mount", "verify Wispad.app", "copy .Wispad.nouveau.app",
                                  "verify .Wispad.nouveau.app", "detach", "swap .Wispad.nouveau.app Wispad.app"])
        #expect(journal.relaunched == ["--updated"])
    }

    @Test func verifiesCopiesNextToTheAppThenSwapsAndRelaunches() async throws {
        let journal = Journal()
        let installer = makeInstaller(journal)
        let started = install(installer, journal)
        #expect(started)
        #expect(installer.isBusy)
        try await waitUntil { journal.terminated }
        #expect(journal.steps == ["download", "mount", "verify Wispad.app", "copy .Wispad.nouveau.app",
                                  "verify .Wispad.nouveau.app", "detach", "swap .Wispad.nouveau.app Wispad.app"])
        #expect(journal.relaunched == ["--updated", "--section", "home"])
        #expect(journal.phaseAtTerminate == .relaunching)
        // La fenêtre de mise à jour (en feuille) se ferme avant la demande : sinon macOS refuse de quitter.
        #expect(journal.quitSteps.prefix(2) == ["fenêtres", "fermeture"])
        // L'ancienne version (dans la copie cachée après l'échange) est effacée ; l'app elle-même jamais.
        #expect(journal.removed.contains(Self.staged))
        #expect(!journal.removed.contains(Self.app))
        #expect(journal.opened.isEmpty)
    }

    /// Fermeture refusée par macOS (feuille ou fenêtre modale restée ouverte) : l'ancienne instance, qui ne peut plus
    /// dicter, s'arrête de force et l'aide ouvre la nouvelle version, déjà en place. Jamais « Relance… » sans fin.
    @Test func refusedQuitEndsOnARelaunchFailure() async throws {
        let journal = Journal()
        let installer = makeInstaller(journal)
        install(installer, journal)
        try await waitUntil { !installer.isBusy }
        #expect(journal.quitSteps == ["fenêtres", "fermeture", "arrêt forcé"])
        #expect(journal.steps.last == "swap .Wispad.nouveau.app Wispad.app")
        // Atteint seulement ici, où l'arrêt forcé rend la main.
        #expect(installer.phase == .failed(.relaunch))
        #expect(!installer.canCancel)
    }

    /// Dossier non modifiable, app sans signature Developer ID ou build de développement : la page de la release.
    @Test func opensTheReleasePageWhenItCannotInstallHere() {
        let cases: [(writable: Bool, team: String?, kind: BuildKind)] = [
            (false, "ABCDE12345", .release), (true, nil, .release), (true, "ABCDE12345", .development),
        ]
        for (writable, team, kind) in cases {
            let journal = Journal()
            let installer = makeInstaller(journal, writable: writable, team: team)
            let started = installer.install(Self.release, kind: kind, installed: "0.1.1", isIdle: { true },
                                            relaunchArguments: { [] })
            #expect(!started)
            #expect(journal.opened == [Self.release.pageURL])
            #expect(journal.steps.isEmpty)
            #expect(installer.phase == .idle)
        }
    }

    @Test func wrongSignatureReplacesNothing() async throws {
        let journal = Journal()
        journal.signatureValid = false
        let installer = makeInstaller(journal)
        install(installer, journal)
        try await waitUntil { !installer.isBusy }
        #expect(installer.phase == .failed(.signature))
        #expect(!journal.steps.contains { $0.hasPrefix("copy") || $0.hasPrefix("swap") })
        #expect(journal.steps.contains("detach"))
        #expect(!journal.terminated)
        #expect(journal.quitSteps.isEmpty)
        #expect(!journal.removed.contains(Self.app))
    }

    @Test func olderVersionInTheDiskImageIsRefused() async throws {
        let journal = Journal()
        journal.diskVersion = "0.1.1"
        let installer = makeInstaller(journal)
        install(installer, journal)
        try await waitUntil { !installer.isBusy }
        #expect(installer.phase == .failed(.notNewer))
        journal.diskVersion = nil
        install(installer, journal)
        try await waitUntil { !installer.isBusy }
        #expect(installer.phase == .failed(.missingApp))
        #expect(!journal.steps.contains { $0.hasPrefix("swap") })
    }

    @Test func downloadFailureIsExplained() async throws {
        let journal = Journal()
        journal.downloadError = URLError(.notConnectedToInternet)
        let installer = makeInstaller(journal)
        install(installer, journal)
        try await waitUntil { !installer.isBusy }
        #expect(installer.phase == .failed(.download))
        journal.downloadError = UpdateFailure.corrupted
        install(installer, journal)
        try await waitUntil { !installer.isBusy }
        #expect(installer.phase == .failed(.corrupted))
        #expect(journal.steps == ["download", "download"])
        // La fenêtre fermée, « Mettre à jour » revient.
        installer.dismissFailure()
        #expect(installer.phase == .idle)
    }

    /// Jamais pendant une dictée : la nouvelle version attend, vérifiée, puis remplace l'app à la fin de la dictée.
    @Test func waitsForTheDictationToEnd() async throws {
        let journal = Journal()
        journal.idle = false
        let installer = makeInstaller(journal)
        install(installer, journal)
        try await waitUntil { installer.phase == .waitingForDictation }
        #expect(!journal.steps.contains { $0.hasPrefix("swap") })
        journal.idle = true
        try await waitUntil { journal.terminated }
        #expect(journal.steps.last == "swap .Wispad.nouveau.app Wispad.app")
    }

    /// Wispad quitté entre la copie et le remplacement : la copie cachée part au lancement suivant, jamais l'app.
    @Test func leftoverCopyIsRemovedAtLaunch() {
        let journal = Journal()
        let installer = makeInstaller(journal)
        installer.system.exists = { $0 == Self.staged }
        installer.removeLeftovers()
        #expect(journal.removed == [Self.staged])
        installer.system.exists = { _ in false }
        installer.removeLeftovers()
        #expect(journal.removed == [Self.staged])
    }

    @Test func cancellingBeforeTheSwapReplacesNothing() async throws {
        let journal = Journal()
        journal.idle = false
        let installer = makeInstaller(journal)
        install(installer, journal)
        try await waitUntil { installer.phase == .waitingForDictation }
        #expect(installer.canCancel)
        installer.cancel()
        #expect(installer.phase == .idle)
        journal.idle = true
        try await Task.sleep(for: .milliseconds(500))
        #expect(!journal.steps.contains { $0.hasPrefix("swap") })
        #expect(!journal.terminated)
        #expect(journal.removed.contains(Self.staged))
        #expect(installer.phase == .idle)
    }
}
