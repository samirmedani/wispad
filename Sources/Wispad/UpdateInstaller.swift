import AppKit
import CryptoKit
import Foundation
import os
import Security
import WispadCore

/// Ce qui a arrêté une installation. L'app en place n'est jamais laissée à moitié remplacée.
enum UpdateFailure: Error, Equatable {
    /// Téléchargement interrompu (réseau, serveur).
    case download
    /// Taille ou empreinte différente de celles annoncées par GitHub.
    case corrupted
    /// Disque d'installation impossible à ouvrir.
    case diskImage
    /// Pas de Wispad dans le disque.
    case missingApp
    /// Version du disque pas plus récente que celle qui tourne.
    case notNewer
    /// Signature invalide, absente, ou d'une autre équipe que l'app qui tourne.
    case signature
    /// Copie à côté de l'app impossible.
    case copy
    /// Remplacement impossible : l'ancienne version reste en place.
    case replace
    /// Nouvelle version en place, mais la relance n'a pas pu être préparée.
    case relaunch

    /// Nom court pour le journal, sans chemin ni donnée personnelle.
    var logName: String { String(describing: self) }
}

/// Frontières système de l'installation. Les tests les remplacent : aucun réseau, aucun disque monté, aucune app
/// remplacée ni relancée.
@MainActor
struct UpdateSystem {
    /// Paquet .app qui tourne.
    var appURL: () -> URL = { Bundle.main.bundleURL }
    /// Team ID de la signature de l'app qui tourne ; nil pour une signature locale.
    var teamID: () -> String? = { CodeSignature.currentTeamID() }
    var isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }
    var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    /// Dossier de travail temporaire (disque téléchargé, point de montage), effacé à la fin.
    var makeWorkspace: () throws -> URL = { try UpdateTools.makeWorkspace() }
    var download: (DiskImageAsset, URL, @escaping @Sendable (Double?) -> Void) async throws -> Void = {
        try await UpdateTools.download($0, to: $1, progress: $2)
    }
    /// Monte le disque (dans le dossier de travail) et rend son point de montage.
    var mount: (URL, URL) async throws -> URL = { try await UpdateTools.mount($0, under: $1) }
    var detach: (URL) async -> Void = { await UpdateTools.detach($0) }
    /// `CFBundleShortVersionString` d'un paquet .app, sans le charger.
    var bundleVersion: (URL) -> String? = { UpdateTools.bundleVersion($0) }
    /// Signature Developer ID valide, de cette équipe, pour l'identifiant de Wispad.
    var verify: (URL, String) async -> Bool = { await UpdateTools.verify($0, teamID: $1) }
    var copy: (URL, URL) async throws -> Void = { try await UpdateTools.copy($0, to: $1) }
    /// Échange la copie et l'app : après l'appel, la copie contient l'ancienne version.
    var swap: (URL, URL) throws -> Void = { try UpdateTools.swap($0, into: $1) }
    var remove: (URL) -> Void = { _ = try? FileManager.default.removeItem(at: $0) }
    /// Lance l'aide qui attend la fin de cette instance puis ouvre la nouvelle ; faux si elle n'a pas démarré.
    var relaunch: (URL, [String]) -> Bool = { UpdateTools.relaunch($0, arguments: $1) }
    var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    var open: @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
}

/// Installation en un clic d'une release : téléchargement du disque, vérification de la signature, copie à côté de
/// l'app, remplacement atomique hors dictée, puis relance. Réglages, clés, historique et dictionnaire vivent hors de
/// l'app : rien n'y touche.
@MainActor
@Observable
final class UpdateInstaller {
    enum Phase: Equatable {
        case idle
        /// Part téléchargée, de 0 à 1 ; nil tant que la taille n'est pas connue.
        case downloading(Double?)
        case verifying
        /// Nouvelle version prête : elle remplace l'app dès que la dictée en cours est finie.
        case waitingForDictation
        case installing
        case relaunching
        case failed(UpdateFailure)
    }

    private(set) var phase: Phase = .idle
    /// Release en cours d'installation, ou dont l'installation a échoué.
    private(set) var release: ReleaseInfo?
    @ObservationIgnored var system = UpdateSystem()
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Chaque installation a son numéro : une installation annulée ne touche plus à l'état de la suivante.
    @ObservationIgnored private var attempt = 0
    private static let log = Logger.wispad("mise-a-jour")

    var isBusy: Bool {
        switch phase {
        case .idle, .failed: return false
        case .downloading, .verifying, .waitingForDictation, .installing, .relaunching: return true
        }
    }

    /// Annulable tant que rien n'est remplacé.
    var canCancel: Bool {
        switch phase {
        case .downloading, .verifying, .waitingForDictation: return true
        case .idle, .installing, .relaunching, .failed: return false
        }
    }

    /// Ce qui empêche d'installer cette release ici ; nil si l'installation en un clic est possible.
    func obstacle(for release: ReleaseInfo, kind: BuildKind) -> UpdateInstallObstacle? {
        let app = system.appURL()
        return UpdateInstallRules.obstacle(
            kind: kind, release: release, appPath: app.path, teamID: system.teamID(),
            folderWritable: system.isWritable(app.deletingLastPathComponent()), appWritable: system.isWritable(app)
        )
    }

    /// Lance l'installation en place. Si elle ne peut pas se faire ici (build de développement, dossier non
    /// modifiable, release sans disque, app sans signature Developer ID), la page de la release s'ouvre à la place.
    /// Vrai si l'installation démarre.
    @discardableResult
    func install(_ release: ReleaseInfo, kind: BuildKind, installed: String,
                 isIdle: @escaping @MainActor () -> Bool,
                 relaunchArguments: @escaping @MainActor () -> [String]) -> Bool {
        guard !isBusy else { return false }
        if let blocker = obstacle(for: release, kind: kind) {
            Self.log.notice("installation en place impossible (\(String(describing: blocker), privacy: .public)) : page de la release")
            system.open(release.pageURL)
            return false
        }
        guard let asset = release.diskImage, let team = system.teamID() else { return false }
        attempt += 1
        let current = attempt
        let app = system.appURL()
        self.release = release
        phase = .downloading(nil)
        // Une installation annulée finit de ranger (disque démonté, copie effacée) avant que la suivante commence.
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            await self?.run(attempt: current, asset: asset, teamID: team, app: app, installed: installed,
                            isIdle: isIdle, relaunchArguments: relaunchArguments)
        }
        return true
    }

    /// Annule pendant le téléchargement, la vérification ou l'attente de la fin d'une dictée : rien n'est remplacé.
    func cancel() {
        guard canCancel else { return }
        attempt += 1
        work?.cancel()
        phase = .idle
    }

    /// Fenêtre de mise à jour fermée après un échec : la barre latérale repropose « Mettre à jour ».
    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// Copie cachée laissée par une installation interrompue (Wispad quitté entre la copie et le remplacement) :
    /// effacée au lancement suivant. Jamais l'app elle-même.
    func removeLeftovers() {
        let staged = UpdateInstallRules.stagingURL(for: system.appURL())
        if system.exists(staged) { system.remove(staged) }
    }

    private func run(attempt current: Int, asset: DiskImageAsset, teamID: String, app: URL, installed: String,
                     isIdle: @MainActor () -> Bool, relaunchArguments: @MainActor () -> [String]) async {
        let system = self.system
        guard !Task.isCancelled else { return finish(current, .idle) }
        guard let workspace = try? system.makeWorkspace() else { return finish(current, .failed(.download)) }
        defer { system.remove(workspace) }
        let image = workspace.appendingPathComponent(ReleaseCheck.diskImageName)
        do {
            try await system.download(asset, image) { [weak self] fraction in
                _ = Task { @MainActor in self?.noteProgress(fraction, attempt: current) }
            }
        } catch {
            return finish(current, Task.isCancelled ? .idle : .failed((error as? UpdateFailure) ?? .download))
        }
        guard !Task.isCancelled else { return finish(current, .idle) }
        set(.verifying, attempt: current)
        let volume: URL
        do {
            volume = try await system.mount(image, workspace)
        } catch {
            return finish(current, Task.isCancelled ? .idle : .failed(.diskImage))
        }
        let staged = UpdateInstallRules.stagingURL(for: app)
        var problem: UpdateFailure?
        if !Task.isCancelled {
            problem = await prepare(from: volume, to: staged, teamID: teamID, installed: installed)
        }
        await system.detach(volume)
        if let problem {
            system.remove(staged)
            return finish(current, .failed(problem))
        }
        // Jamais pendant une dictée : la nouvelle version attend, vérifiée, à côté de l'app.
        while !Task.isCancelled, !isIdle() {
            set(.waitingForDictation, attempt: current)
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled else {
            system.remove(staged)
            return finish(current, .idle)
        }
        set(.installing, attempt: current)
        do {
            try system.swap(staged, app)
        } catch {
            system.remove(staged)
            return finish(current, .failed(.replace))
        }
        // Après l'échange, la copie cachée contient l'ancienne version.
        system.remove(staged)
        system.remove(workspace)
        set(.relaunching, attempt: current)
        Self.log.notice("nouvelle version installée : relance")
        guard system.relaunch(app, relaunchArguments()) else { return finish(current, .failed(.relaunch)) }
        system.terminate()
    }

    /// Vérifie la nouvelle version dans le disque, la copie à côté de l'app, puis revérifie la copie (c'est elle qui
    /// sera installée). Nil si tout est bon.
    private func prepare(from volume: URL, to staged: URL, teamID: String, installed: String) async -> UpdateFailure? {
        let system = self.system
        let candidate = volume.appendingPathComponent(AppIdentity.displayName + ".app", isDirectory: true)
        guard let version = system.bundleVersion(candidate) else { return .missingApp }
        guard UpdateInstallRules.isNewer(version, than: installed) else { return .notNewer }
        guard await system.verify(candidate, teamID) else { return .signature }
        system.remove(staged)
        do {
            try await system.copy(candidate, staged)
        } catch {
            return .copy
        }
        guard await system.verify(staged, teamID) else { return .signature }
        return nil
    }

    private func set(_ next: Phase, attempt current: Int) {
        guard attempt == current, phase != next else { return }
        phase = next
    }

    private func noteProgress(_ fraction: Double?, attempt current: Int) {
        guard attempt == current, case .downloading = phase else { return }
        phase = .downloading(fraction)
    }

    private func finish(_ current: Int, _ next: Phase) {
        guard attempt == current else { return }
        phase = next
        if case .failed(let failure) = next {
            Self.log.error("mise à jour impossible : \(failure.logName, privacy: .public)")
        }
    }
}

/// Outils système de l'installation, hors du fil principal.
enum UpdateTools {
    static func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WispadUpdate-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func download(_ asset: DiskImageAsset, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        try await DiskImageDownload(destination: destination, progress: progress).run(asset.url)
        try await Task.detached(priority: .userInitiated) {
            try UpdateTools.checkDownload(destination, asset: asset)
        }.value
    }

    /// Taille et empreinte SHA-256 annoncées par GitHub : un fichier tronqué ou modifié s'arrête ici.
    static func checkDownload(_ file: URL, asset: DiskImageAsset) throws {
        if let size = asset.size {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == size else { throw UpdateFailure.corrupted }
        }
        if let expected = asset.sha256 {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw UpdateFailure.corrupted }
        }
    }

    /// `hdiutil attach` en lecture seule, invisible dans le Finder (`-nobrowse`), sans ouverture automatique, monté
    /// dans le dossier de travail.
    static func mount(_ image: URL, under directory: URL) async throws -> URL {
        let result = await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist",
                                                    "-mountrandom", directory.path, image.path])
        guard result.status == 0, let point = UpdateInstallRules.mountPoints(fromPlist: result.output).first else {
            throw UpdateFailure.diskImage
        }
        return URL(fileURLWithPath: point, isDirectory: true)
    }

    static func detach(_ mountPoint: URL) async {
        if await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]).status != 0 {
            _ = await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"])
        }
    }

    /// `ditto` garde tout du paquet : liens, attributs, signature.
    static func copy(_ source: URL, to destination: URL) async throws {
        guard await run("/usr/bin/ditto", [source.path, destination.path]).status == 0 else { throw UpdateFailure.copy }
    }

    static func bundleVersion(_ app: URL) -> String? {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    static func verify(_ app: URL, teamID: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            CodeSignature.satisfies(app, bundleID: AppIdentity.bundleID, teamID: teamID)
        }.value
    }

    /// Échange atomique de deux dossiers du même volume (`renamex_np`, APFS). Repli : deux renommages, l'ancienne app
    /// remise en place si le second échoue. Dans les deux cas, `staged` contient ensuite l'ancienne version.
    static func swap(_ staged: URL, into app: URL) throws {
        let swapped = staged.withUnsafeFileSystemRepresentation { (from: UnsafePointer<CChar>?) -> Bool in
            app.withUnsafeFileSystemRepresentation { (to: UnsafePointer<CChar>?) -> Bool in
                guard let from, let to else { return false }
                return renamex_np(from, to, UInt32(RENAME_SWAP)) == 0
            }
        }
        if swapped { return }
        let fileManager = FileManager.default
        let backup = UpdateInstallRules.backupURL(for: app)
        try? fileManager.removeItem(at: backup)
        try fileManager.moveItem(at: app, to: backup)
        do {
            try fileManager.moveItem(at: staged, to: app)
        } catch {
            try? fileManager.moveItem(at: backup, to: app)
            throw error
        }
        try? fileManager.moveItem(at: backup, to: staged)
    }

    /// Petite aide : attend la fin de cette instance (60 s au plus), puis ouvre la nouvelle version ; LaunchServices
    /// peut mettre un instant à la voir. Chemin et arguments passés à part, jamais dans le texte de la commande.
    static func relaunch(_ app: URL, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", relaunchScript, "wispad-relance",
                             String(ProcessInfo.processInfo.processIdentifier), app.path] + arguments
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    static let relaunchScript = """
        pid=$1; app=$2; shift 2
        i=0
        while /bin/kill -0 "$pid" 2>/dev/null && [ "$i" -lt 300 ]; do /bin/sleep 0.2; i=$((i + 1)); done
        for attempt in 1 2 3; do
          /usr/bin/open -g "$app" --args "$@" && exit 0
          /bin/sleep 2
        done
        exit 1
        """

    /// Lance un outil du système et attend sa fin, hors du fil principal : code de sortie et sortie standard.
    static func run(_ tool: String, _ arguments: [String]) async -> (status: Int32, output: Data) {
        await Task.detached(priority: .userInitiated) { () -> (status: Int32, output: Data) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return (status: -1, output: Data())
            }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (status: process.terminationStatus, output: output)
        }.value
    }
}

/// Téléchargement du disque de la release, avec sa progression. URLSession efface le fichier reçu à la fin du rappel :
/// il est déplacé tout de suite à sa place.
final class DiskImageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private let result = AsyncResult<Void>()
    private let lock = NSLock()
    private var session: URLSession?
    private var reported: Double = -1

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 30 * 60
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            lock.withLock { self.session = session }
            var request = URLRequest(url: url)
            request.setValue(AppIdentity.displayName, forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
            try await result.value()
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let session = lock.withLock { self.session }
        session?.invalidateAndCancel()
        result.resolve(.failure(CancellationError()))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        // Un pour cent à la fois : la fenêtre n'est pas redessinée à chaque paquet.
        let changed = lock.withLock { () -> Bool in
            guard fraction - reported >= 0.01 || (fraction >= 1 && reported < 1) else { return false }
            reported = fraction
            return true
        }
        if changed { progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            result.resolve(.failure(UpdateFailure.download))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            result.resolve(.success(()))
        } catch {
            result.resolve(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        // Sans erreur, le fichier a déjà été rangé (ou refusé) juste avant : ce résultat-ci ne compte plus.
        result.resolve(.failure(error ?? UpdateFailure.download))
    }
}

/// Signature de code : Team ID de l'app qui tourne, et contrôle d'une nouvelle version avant de l'installer.
enum CodeSignature {
    /// Team ID de la signature de l'app qui tourne ; nil pour une signature locale (ad hoc) ou absente.
    static func currentTeamID() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let staticCode = staticRef else { return nil }
        var informationRef: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &informationRef) == errSecSuccess,
              let information = informationRef else { return nil }
        let team = (information as NSDictionary)[kSecCodeInfoTeamIdentifier as String] as? String
        return team.flatMap { UpdateInstallRules.isTeamID($0) ? $0 : nil }
    }

    /// Vrai si l'app à cet emplacement est intacte (toutes architectures, code imbriqué compris, validation stricte)
    /// et signée Developer ID par la même équipe, avec le même identifiant (`UpdateInstallRules.requirement`).
    static func satisfies(_ app: URL, bundleID: String, teamID: String) -> Bool {
        guard let text = UpdateInstallRules.requirement(bundleID: bundleID, teamID: teamID) else { return false }
        var requirementRef: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirementRef) == errSecSuccess,
              let requirement = requirementRef else { return false }
        var staticRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else { return false }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode)
                               | UInt32(kSecCSStrictValidate))
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }
}
