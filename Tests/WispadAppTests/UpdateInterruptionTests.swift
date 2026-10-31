import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Mise à jour en un clic interrompue n'importe où, sur un disque simulé derrière le faux `UpdateSystem` : l'app à sa
/// place reste toujours une Wispad entière et signée (l'ancienne version ou la nouvelle), et le lancement suivant
/// efface les copies cachées. Aucun réseau, aucun disque monté, aucune app remplacée ni relancée.
@MainActor
struct UpdateInterruptionTests {
    /// Mise à jour menée à son terme, une dictée en cours au moment de remplacer l'app : à chaque état du disque,
    /// l'app à sa place est une Wispad entière, et Wispad tué (ou Mac coupé) à n'importe lequel de ces états la
    /// retrouve entière au lancement suivant, sans copie cachée.
    @Test func everyStateOfAnUpdateLeavesAUsableWispad() async throws {
        let disk = SimulatedDisk()
        let wispad = launch(disk)
        wispad.journal.idle = false
        wispad.install()
        try await waitUntil { wispad.installer.phase == .waitingForDictation }
        wispad.journal.idle = true
        try await waitUntil { wispad.journal.terminated }
        let app = UpdateFixture.app.path
        let staged = UpdateFixture.staged.path
        #expect(disk.apps[app] == DiskCopy(version: UpdateFixture.available))
        #expect(!disk.contains(UpdateFixture.staged))
        // Le disque est bien passé par chaque étape : copie en cours, copie prête, échange, effacement de l'ancienne.
        #expect(disk.states.contains { $0[staged]?.version == UpdateFixture.available && $0[staged]?.intact == false })
        #expect(disk.states.contains { $0[staged] == DiskCopy(version: UpdateFixture.available) })
        #expect(disk.states.contains {
            $0[app] == DiskCopy(version: UpdateFixture.available) && $0[staged] == DiskCopy(version: UpdateFixture.installed)
        })
        #expect(disk.states.contains { $0[staged]?.version == UpdateFixture.installed && $0[staged]?.intact == false })
        // Wispad tué ou Mac coupé à n'importe lequel de ces états, puis rouvert.
        expectAlwaysUsable(disk)
    }

    /// Panne à chaque étape : coupure réseau, disque plein, dossier temporaire supprimé par macOS, disque de la mise à
    /// jour illisible, droits retirés, copie altérée, échange refusé. L'ancienne app reste en place, entière, à chaque
    /// état ; aucune copie cachée ne reste ; rien n'est relancé. « Réessayer », la panne passée, installe la nouvelle.
    @Test func aFailureAtAnyStepKeepsTheInstalledWispad() async throws {
        let faults: [(name: String, expected: UpdateFailure, inject: (SimulatedDisk) -> Void)] = [
            ("coupure réseau", .download, { $0.downloadError = URLError(.networkConnectionLost) }),
            ("disque plein pendant le téléchargement", .download, {
                $0.downloadError = CocoaError(.fileWriteOutOfSpace)
            }),
            ("dossier temporaire supprimé pendant le téléchargement", .download, {
                $0.downloadError = CocoaError(.fileNoSuchFile)
            }),
            ("dossier temporaire impossible à recréer", .download, { $0.workspaceMissing = true }),
            ("disque de la mise à jour illisible", .diskImage, { $0.mountFails = true }),
            ("disque plein pendant la copie", .copy, { $0.copyFault = .diskFull }),
            ("droits retirés avant la copie", .copy, { $0.copyFault = .denied }),
            ("copie altérée", .signature, { $0.copyCorrupted = true }),
            ("disque plein pendant l'échange", .replace, { $0.swapError = POSIXError(.ENOSPC) }),
            ("droits retirés avant l'échange", .replace, { $0.swapError = POSIXError(.EACCES) }),
        ]
        for fault in faults {
            let disk = SimulatedDisk()
            fault.inject(disk)
            let wispad = launch(disk)
            wispad.install()
            try await waitUntil { !wispad.installer.isBusy }
            #expect(wispad.installer.phase == .failed(fault.expected), "\(fault.name)")
            #expect(disk.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.installed), "\(fault.name)")
            #expect(!disk.contains(UpdateFixture.staged), "\(fault.name)")
            #expect(wispad.journal.relaunchedApp == nil && wispad.journal.quitSteps.isEmpty, "\(fault.name)")
            expectAlwaysUsable(disk)
            disk.repair()
            wispad.install()
            try await waitUntil { wispad.journal.terminated }
            #expect(disk.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.available), "\(fault.name)")
        }
    }

    /// Copie cachée effacée pendant l'attente de la fin d'une dictée (à la main, par un antivirus) : l'échange échoue
    /// et l'ancienne app reste en place.
    @Test func aStagedCopyDeletedWhileWaitingKeepsTheInstalledWispad() async throws {
        let disk = SimulatedDisk()
        let wispad = launch(disk)
        wispad.journal.idle = false
        wispad.install()
        try await waitUntil { wispad.installer.phase == .waitingForDictation }
        disk.remove(UpdateFixture.staged)
        wispad.journal.idle = true
        try await waitUntil { !wispad.installer.isBusy }
        #expect(wispad.installer.phase == .failed(.replace))
        #expect(disk.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.installed))
        #expect(wispad.journal.relaunchedApp == nil)
        expectAlwaysUsable(disk)
    }

    /// Échec après l'échange : la nouvelle version est déjà en place, entière. Aide de relance qui ne démarre pas : la
    /// fenêtre reste ouverte sur « quitte-le, puis rouvre-le », Wispad n'est pas fermé. Ancienne version impossible à
    /// effacer (droits retirés) : la relance a lieu quand même, et le lancement suivant efface ce qu'il en reste.
    @Test func aFailureAfterTheSwapLeavesTheNewWispadInPlace() async throws {
        let disk = SimulatedDisk()
        let wispad = launch(disk)
        wispad.journal.helperStarts = false
        wispad.install()
        try await waitUntil { !wispad.installer.isBusy }
        #expect(wispad.installer.phase == .failed(.relaunch))
        #expect(wispad.journal.relaunchedApp == UpdateFixture.app)
        #expect(wispad.journal.quitSteps.isEmpty)
        #expect(disk.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.available))
        #expect(!disk.contains(UpdateFixture.staged))
        expectAlwaysUsable(disk)

        let locked = SimulatedDisk()
        locked.undeletable = [UpdateFixture.staged.path]
        let other = launch(locked)
        other.install()
        try await waitUntil { other.journal.terminated }
        #expect(other.journal.relaunchedApp == UpdateFixture.app)
        #expect(locked.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.available))
        #expect(locked.apps[UpdateFixture.staged.path]?.version == UpdateFixture.installed)
        expectAlwaysUsable(locked)
        locked.undeletable = []
        launch(locked).installer.removeLeftovers()
        #expect(locked.apps == [UpdateFixture.app.path: DiskCopy(version: UpdateFixture.available)])
    }

    /// Deux Wispad ouverts (`open -n`, ou une deuxième session) : pendant que le premier attend la fin d'une dictée,
    /// sa copie vérifiée à côté de l'app, le second se lance. Son nettoyage du lancement n'y touche pas : sans verrou,
    /// il l'effaçait, et l'échange du premier, dans un autre processus, pouvait mettre à la place de l'app un paquet à
    /// moitié effacé. Son installation s'arrête avant de rien télécharger, copier ni échanger.
    @Test func aSecondWispadNeverTouchesAnUpdateInProgress() async throws {
        let disk = SimulatedDisk()
        let first = launch(disk)
        first.journal.idle = false
        first.install()
        try await waitUntil { first.installer.phase == .waitingForDictation }
        let second = launch(disk)
        // Deux processus en parallèle : un effacement du second serait encore en cours quand le premier échange.
        second.journal.removalInProgress = true
        second.installer.removeLeftovers()
        #expect(disk.apps[UpdateFixture.staged.path] == DiskCopy(version: UpdateFixture.available))
        second.install()
        try await waitUntil { !second.installer.isBusy }
        #expect(second.installer.phase == .failed(.busy))
        #expect(second.journal.steps.isEmpty)
        #expect(UpdateFailure.busy.message.contains("réessaie"))
        first.journal.idle = true
        try await waitUntil { first.journal.terminated }
        #expect(disk.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.available))
        #expect(!disk.contains(UpdateFixture.staged))
        expectAlwaysUsable(disk)
        // Le premier fini, le verrou est rendu : le second peut réessayer.
        second.journal.removalInProgress = false
        second.install()
        try await waitUntil { second.journal.terminated }
        #expect(disk.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.available))
    }

    /// Deux installations lancées en même temps depuis deux Wispad ouverts : une seule a lieu, l'autre s'arrête avant
    /// de rien toucher. Dans un même Wispad, un deuxième clic pendant l'installation ne lance rien.
    @Test func twoUpdatesStartedTogetherReplaceTheAppOnce() async throws {
        let disk = SimulatedDisk()
        // Téléchargements retenus : celle qui a démarré la première est encore en cours quand l'autre démarre, comme
        // dans deux processus.
        disk.holdDownloads = true
        let first = launch(disk)
        let second = launch(disk)
        #expect(first.install())
        #expect(!first.install())
        second.install()
        try await waitUntil { [first, second].contains { $0.installer.phase == .failed(.busy) } }
        disk.holdDownloads = false
        try await waitUntil { !first.installer.isBusy && !second.installer.isBusy }
        let stopped = [first, second].filter { $0.installer.phase == .failed(.busy) }
        #expect(stopped.count == 1)
        #expect(stopped.first?.journal.steps.isEmpty == true)
        #expect([first, second].filter { $0.journal.terminated }.count == 1)
        #expect((first.journal.steps + second.journal.steps).filter { $0 == "download" }.count == 1)
        #expect(disk.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.available))
        expectAlwaysUsable(disk)
    }

    /// Copies cachées laissées par une installation interrompue : la nouvelle version en attente, ou l'ancienne mise de
    /// côté par les deux renommages d'un volume qui ne sait pas échanger deux noms. Le lancement suivant efface les
    /// deux, jamais l'app ; une installation ne se mélange jamais à un reste.
    @Test func hiddenCopiesLeftBehindAreRemovedAndNeverMixedIn() async throws {
        let leftovers = SimulatedDisk([
            UpdateFixture.app.path: DiskCopy(version: UpdateFixture.installed),
            UpdateFixture.staged.path: DiskCopy(version: UpdateFixture.available, intact: false),
            UpdateFixture.backup.path: DiskCopy(version: "0.1.0"),
        ])
        launch(leftovers).installer.removeLeftovers()
        #expect(leftovers.apps == [UpdateFixture.app.path: DiskCopy(version: UpdateFixture.installed)])

        // Reste à la place de la copie cachée : effacé avant la copie, la nouvelle version s'installe entière.
        let stale = SimulatedDisk([
            UpdateFixture.app.path: DiskCopy(version: UpdateFixture.installed),
            UpdateFixture.staged.path: DiskCopy(version: "0.1.0"),
        ])
        let wispad = launch(stale)
        wispad.install()
        try await waitUntil { wispad.journal.terminated }
        #expect(stale.apps == [UpdateFixture.app.path: DiskCopy(version: UpdateFixture.available)])
        expectAlwaysUsable(stale)

        // Reste impossible à effacer (droits retirés) : la copie par-dessus ne passe pas la vérification de signature,
        // rien n'est remplacé.
        let stuck = SimulatedDisk([
            UpdateFixture.app.path: DiskCopy(version: UpdateFixture.installed),
            UpdateFixture.staged.path: DiskCopy(version: "0.1.0"),
        ])
        stuck.undeletable = [UpdateFixture.staged.path]
        let blocked = launch(stuck)
        blocked.install()
        try await waitUntil { !blocked.installer.isBusy }
        #expect(blocked.installer.phase == .failed(.signature))
        #expect(!blocked.journal.steps.contains("swap"))
        #expect(stuck.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.installed))
        expectAlwaysUsable(stuck)
    }

    /// Release dont l'app n'est pas une Wispad plus récente : autre identifiant, autre équipe, version égale, plus
    /// ancienne ou illisible, ou disque sans Wispad. Rien n'est copié à côté de l'app, ni échangé, ni relancé.
    @Test func aReleaseThatIsNotANewerWispadReplacesNothing() async throws {
        let cases: [(name: String, inDiskImage: DiskCopy?, expected: UpdateFailure)] = [
            ("autre identifiant", DiskCopy(version: UpdateFixture.available, identifier: "com.exemple.autre"), .signature),
            ("autre équipe", DiskCopy(version: UpdateFixture.available, team: "ZZZZZ99999"), .signature),
            ("version égale", DiskCopy(version: UpdateFixture.installed), .notNewer),
            ("version plus ancienne", DiskCopy(version: "0.1.0"), .notNewer),
            ("version illisible", DiskCopy(version: "latest"), .notNewer),
            ("pas de Wispad dans le disque", nil, .missingApp),
        ]
        for item in cases {
            let disk = SimulatedDisk()
            disk.diskImageApp = item.inDiskImage
            let wispad = launch(disk)
            wispad.install()
            try await waitUntil { !wispad.installer.isBusy }
            #expect(wispad.installer.phase == .failed(item.expected), "\(item.name)")
            #expect(!wispad.journal.steps.contains { $0.hasPrefix("copy") || $0 == "swap" }, "\(item.name)")
            #expect(wispad.journal.steps.contains("detach"), "\(item.name)")
            #expect(disk.apps[UpdateFixture.app.path] == DiskCopy(version: UpdateFixture.installed), "\(item.name)")
            #expect(!disk.contains(UpdateFixture.staged), "\(item.name)")
            #expect(wispad.journal.relaunchedApp == nil, "\(item.name)")
            expectAlwaysUsable(disk)
        }
    }

    /// Nom de dossier ou de volume inattendu (espaces, accents, guillemets, `$(…)`, point-virgule) : la copie cachée
    /// reste à côté de l'app, sous son nom à elle, et la relance vise l'app elle-même.
    @Test func unexpectedFolderAndVolumeNamesStillInstallNextToTheApp() async throws {
        let app = URL(fileURLWithPath: "/Applications/Outils à moi/Wispad \"bêta\" $(reboot).app")
        let staged = UpdateInstallRules.stagingURL(for: app)
        #expect(staged.deletingLastPathComponent().path == app.deletingLastPathComponent().path)
        #expect(staged.lastPathComponent == ".Wispad \"bêta\" $(reboot).nouveau.app")
        let disk = SimulatedDisk([app.path: DiskCopy(version: UpdateFixture.installed)])
        disk.volume = UpdateFixture.workspace.appendingPathComponent("Wispad 0.1.2 ; rm -rf ~", isDirectory: true)
        let wispad = launch(disk, app: app)
        wispad.install()
        try await waitUntil { wispad.journal.terminated }
        #expect(wispad.journal.steps.contains("copy " + staged.lastPathComponent))
        #expect(wispad.journal.relaunchedApp == app)
        #expect(disk.apps == [app.path: DiskCopy(version: UpdateFixture.available)])
        expectAlwaysUsable(disk, app: app)
    }

    /// L'aide de relance ne reçoit rien de la release (tag, notes, adresses, nom de volume) : seulement le chemin de
    /// l'app en place, vérifiée, et les arguments fixes de Wispad. Rien ne s'ouvre dans le navigateur.
    @Test func theRelaunchHelperOnlyEverReceivesTheInstalledApp() async throws {
        let hostile = "\"; open -a Calculator; $(touch injected) `touch injected`"
        let release = ReleaseInfo(
            version: SemanticVersion(major: 0, minor: 1, patch: 2), tag: "v0.1.2" + hostile, notes: hostile,
            pageURL: ReleaseCheck.releasesURL.appendingPathComponent("tag").appendingPathComponent(hostile),
            diskImage: DiskImageAsset(url: ReleaseCheck.releasesURL.appendingPathComponent("download/v0.1.2/Wispad.dmg"))
        )
        let disk = SimulatedDisk()
        disk.volume = UpdateFixture.workspace.appendingPathComponent(hostile, isDirectory: true)
        let wispad = launch(disk)
        wispad.install(release)
        try await waitUntil { wispad.journal.terminated }
        #expect(wispad.journal.relaunchedApp == UpdateFixture.app)
        #expect(wispad.journal.relaunchArguments == ["--updated", "--section", "home"])
        #expect(wispad.journal.opened.isEmpty)
    }

    // MARK: - Disque simulé

    /// Une instance de Wispad (un processus) dont toutes les frontières système passent par le disque simulé.
    private func launch(_ disk: SimulatedDisk, app: URL = UpdateFixture.app) -> SimulatedInstance {
        let journal = InstanceJournal()
        let installer = UpdateInstaller()
        var system = UpdateSystem()
        system.appURL = { app }
        system.teamID = { UpdateFixture.team }
        system.isWritable = { _ in true }
        system.exists = { disk.contains($0) }
        system.makeWorkspace = {
            guard !disk.workspaceMissing else { throw CocoaError(.fileNoSuchFile) }
            return UpdateFixture.workspace
        }
        system.download = { _, _, progress in
            journal.steps.append("download")
            while disk.holdDownloads { try await Task.sleep(for: .milliseconds(10)) }
            if let error = disk.downloadError { throw error }
            progress(1)
        }
        system.mount = { _, _ in
            journal.steps.append("mount")
            return try disk.mount()
        }
        system.detach = { volume in
            journal.steps.append("detach")
            disk.detach(volume)
        }
        system.bundleVersion = { disk.apps[$0.path]?.version }
        system.verify = { url, team in
            journal.steps.append("verify " + url.lastPathComponent)
            return disk.isValid(url, team: team)
        }
        system.copy = { source, destination in
            journal.steps.append("copy " + destination.lastPathComponent)
            try disk.copy(source, to: destination)
        }
        system.swap = { staged, app in
            journal.steps.append("swap")
            try disk.swap(staged, app)
        }
        system.remove = { url in
            if journal.removalInProgress { disk.startRemoving(url) } else { disk.remove(url) }
        }
        system.lock = { disk.takeLock() }
        system.relaunch = { app, arguments in
            journal.relaunchedApp = app
            journal.relaunchArguments = arguments
            return journal.helperStarts
        }
        // Le vrai NSApp.terminate ne rend la main que si macOS refuse de fermer l'app : ici, il la rend toujours.
        system.terminate = { journal.quitSteps.append("fermeture") }
        system.forceQuit = { journal.quitSteps.append("arrêt forcé") }
        system.open = { journal.opened.append($0) }
        // Aucune attente réelle ni note dans les préférences du processus de test.
        system.pause = { _ in }
        system.handoff = { _, _ in }
        installer.system = system
        return SimulatedInstance(installer: installer, journal: journal)
    }

    /// À chaque état par lequel le disque est passé, l'app à sa place est une Wispad entière. Wispad tué (ou Mac coupé)
    /// à cet état puis rouvert, nouveau processus dont macOS a rendu le verrou : elle l'est toujours, et le lancement a
    /// effacé les copies cachées qui pouvaient l'être.
    private func expectAlwaysUsable(_ disk: SimulatedDisk, app: URL = UpdateFixture.app,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        let leftovers = [UpdateInstallRules.stagingURL(for: app), UpdateInstallRules.backupURL(for: app)]
        for (index, state) in disk.states.enumerated() {
            #expect(UpdateFixture.isUsable(state, at: app), "état \(index) : \(state)", sourceLocation: sourceLocation)
            let reopened = SimulatedDisk(state)
            reopened.undeletable = disk.undeletable
            launch(reopened, app: app).installer.removeLeftovers()
            #expect(UpdateFixture.isUsable(reopened.apps, at: app), "rouvert après l'état \(index)",
                    sourceLocation: sourceLocation)
            for leftover in leftovers where !disk.undeletable.contains(leftover.path) {
                #expect(!reopened.contains(leftover), "rouvert après l'état \(index)", sourceLocation: sourceLocation)
            }
        }
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
}

/// Ce que les tests installent, et où.
private enum UpdateFixture {
    static let team = "ABCDE12345"
    static let installed = "0.1.1"
    static let available = "0.1.2"
    static let app = URL(fileURLWithPath: "/Applications/Wispad.app")
    static let staged = UpdateInstallRules.stagingURL(for: app)
    static let backup = UpdateInstallRules.backupURL(for: app)
    static let workspace = URL(fileURLWithPath: "/private/tmp/wispad-update-test", isDirectory: true)
    static let release = ReleaseInfo(
        version: SemanticVersion(major: 0, minor: 1, patch: 2), tag: "v0.1.2", notes: "",
        pageURL: ReleaseCheck.releasesURL.appendingPathComponent("tag/v0.1.2"),
        diskImage: DiskImageAsset(url: ReleaseCheck.releasesURL.appendingPathComponent("download/v0.1.2/Wispad.dmg"))
    )

    /// L'app à sa place est une Wispad entière, de l'équipe : l'ancienne version ou la nouvelle.
    static func isUsable(_ state: [String: DiskCopy], at location: URL = UpdateFixture.app) -> Bool {
        guard let copy = state[location.path] else { return false }
        return copy.intact && copy.identifier == AppIdentity.bundleID && copy.team == team
            && [installed, available].contains(copy.version)
    }
}

/// Une copie de Wispad dans un dossier .app du disque simulé.
private struct DiskCopy: Equatable, CustomStringConvertible {
    var version: String
    var identifier = AppIdentity.bundleID
    var team = UpdateFixture.team
    /// Faux pour un paquet à moitié écrit, à moitié effacé ou altéré : sa signature ne tient plus.
    var intact = true

    var description: String { "\(identifier) \(version) \(team)\(intact ? "" : " (abîmée)")" }
}

/// Disque simulé : ce que contient chaque dossier .app, et chaque état par lequel il passe. Wispad peut être tué, ou le
/// Mac coupé, à n'importe lequel de ces états.
@MainActor
private final class SimulatedDisk {
    enum CopyFault { case diskFull, denied }

    private(set) var apps: [String: DiskCopy]
    private(set) var states: [[String: DiskCopy]]
    /// Wispad.app dans le disque de la mise à jour ; nil : absent.
    var diskImageApp: DiskCopy? = DiskCopy(version: UpdateFixture.available)
    var volume = UpdateFixture.workspace.appendingPathComponent("dmg.Ab12Cd", isDirectory: true)
    /// Téléchargement retenu tant que c'est vrai.
    var holdDownloads = false
    // Pannes.
    var workspaceMissing = false
    var downloadError: Error?
    var mountFails = false
    var copyFault: CopyFault?
    var copyCorrupted = false
    var swapError: Error?
    /// Droits retirés : l'effacement de ces dossiers s'arrête en route.
    var undeletable: Set<String> = []
    private var lockHeld = false

    init(_ apps: [String: DiskCopy] = [UpdateFixture.app.path: DiskCopy(version: UpdateFixture.installed)]) {
        self.apps = apps
        states = [apps]
    }

    func repair() {
        workspaceMissing = false
        downloadError = nil
        mountFails = false
        copyFault = nil
        copyCorrupted = false
        swapError = nil
        undeletable = []
    }

    func contains(_ url: URL) -> Bool { apps[url.path] != nil }

    func isValid(_ url: URL, team: String) -> Bool {
        guard let copy = apps[url.path] else { return false }
        return copy.intact && copy.identifier == AppIdentity.bundleID && copy.team == team
    }

    func mount() throws -> URL {
        if mountFails { throw UpdateFailure.diskImage }
        if let diskImageApp { set(volume.appendingPathComponent("Wispad.app"), diskImageApp) }
        return volume
    }

    func detach(_ mountPoint: URL) {
        for path in Array(apps.keys) where path.hasPrefix(mountPoint.path + "/") {
            set(URL(fileURLWithPath: path), nil)
        }
    }

    /// `ditto` écrit fichier par fichier : un paquet à moitié écrit existe pendant la copie. Par-dessus un reste qui
    /// n'a pas pu être effacé, les fichiers en trop cassent la signature.
    func copy(_ source: URL, to destination: URL) throws {
        guard var copy = apps[source.path], copyFault != .denied else { throw UpdateFailure.copy }
        let mixed = apps[destination.path] != nil
        var partial = copy
        partial.intact = false
        set(destination, partial)
        if copyFault == .diskFull { throw UpdateFailure.copy }
        copy.intact = !mixed && !copyCorrupted
        set(destination, copy)
    }

    /// `renamex_np` : les deux dossiers échangent leurs noms d'un coup, ou rien ne change.
    func swap(_ staged: URL, _ app: URL) throws {
        if let swapError { throw swapError }
        guard let new = apps[staged.path], let old = apps[app.path] else { throw CocoaError(.fileNoSuchFile) }
        apps[app.path] = new
        apps[staged.path] = old
        states.append(apps)
    }

    /// Effacement : en route, le paquet n'est plus entier ; droits retirés, il en reste une partie.
    func remove(_ url: URL) {
        guard contains(url) else { return }
        startRemoving(url)
        guard !undeletable.contains(url.path) else { return }
        set(url, nil)
    }

    /// Effacement commencé, pas encore fini (par un autre processus, en parallèle).
    func startRemoving(_ url: URL) {
        guard var copy = apps[url.path] else { return }
        copy.intact = false
        set(url, copy)
    }

    /// Verrou entre instances, comme `flock` : une seule le tient.
    func takeLock() -> (() -> Void)? {
        guard !lockHeld else { return nil }
        lockHeld = true
        return { [weak self] in self?.lockHeld = false }
    }

    private func set(_ url: URL, _ copy: DiskCopy?) {
        apps[url.path] = copy
        states.append(apps)
    }
}

/// Ce qu'une instance de Wispad a demandé au système, et ce qu'elle vit (dictée en cours, aide de relance).
@MainActor
private final class InstanceJournal {
    var steps: [String] = []
    var relaunchedApp: URL?
    var relaunchArguments: [String]?
    /// Fin de l'installation, dans l'ordre : fenêtres refermées, fermeture demandée, arrêt forcé.
    var quitSteps: [String] = []
    var opened: [URL] = []
    var idle = true
    var helperStarts = true
    /// Les effacements de cette instance sont encore en cours quand une autre agit (deux processus en parallèle).
    var removalInProgress = false

    var terminated: Bool { quitSteps.contains("fermeture") }
}

@MainActor
private struct SimulatedInstance {
    let installer: UpdateInstaller
    let journal: InstanceJournal

    @discardableResult
    func install(_ release: ReleaseInfo = UpdateFixture.release) -> Bool {
        installer.install(release, kind: .release, installed: UpdateFixture.installed,
                          isIdle: { [journal] in journal.idle },
                          relaunchArguments: { ["--updated", "--section", "home"] },
                          beforeQuit: { [journal] in journal.quitSteps.append("fenêtres") })
    }
}
