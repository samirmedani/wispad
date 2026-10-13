import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Outils réels de l'installation, dans un dossier temporaire : échange de l'app et de sa copie cachée, verrou entre
/// instances de Wispad, aide de relance. Aucune app remplacée ni relancée : l'aide y appelle un faux `open`, qui note
/// ce qu'il reçoit.
struct UpdateToolsTests {
    /// Volume du Mac (APFS) : l'app et la copie cachée échangent leurs noms d'un coup ; la copie contient ensuite
    /// l'ancienne version, et rien d'autre ne reste.
    @Test func swapExchangesTheAppAndItsStagedCopy() throws {
        let folder = try SwapFolder()
        try folder.make(folder.app, version: "0.1.1")
        try folder.make(folder.staged, version: "0.1.2")
        try UpdateTools.swap(folder.staged, into: folder.app)
        #expect(folder.version(folder.app) == "0.1.2")
        #expect(folder.version(folder.staged) == "0.1.1")
        #expect(!FileManager.default.fileExists(atPath: folder.backup.path))
    }

    /// Volume qui sait échanger deux noms (APFS) et échange raté (disque plein, droits retirés) : plus de repli à deux
    /// renommages, qui sortait l'app de sa place puis l'y remettait sans contrôle. Rien ne bouge, pas même une ancienne
    /// copie mise de côté.
    @Test func aFailedSwapOnAVolumeThatCanSwapNeverMovesTheApp() throws {
        let folder = try SwapFolder()
        try folder.make(folder.app, version: "0.1.1")
        try folder.make(folder.staged, version: "0.1.2")
        try folder.make(folder.backup, version: "0.1.0")
        #expect(throws: UpdateFailure.replace) {
            try UpdateTools.swap(folder.staged, into: folder.app, exchange: { _, _ in false }, canSwap: { _ in true })
        }
        #expect(folder.version(folder.app) == "0.1.1")
        #expect(folder.version(folder.staged) == "0.1.2")
        #expect(folder.version(folder.backup) == "0.1.0")
    }

    /// Volume qui ne sait pas échanger (HFS+, exFAT, partage réseau), ou qui ne le dit pas : deux renommages, même
    /// résultat qu'un échange.
    @Test func aVolumeThatCannotSwapStillReplacesTheAppWithTwoRenames() throws {
        for answer in [false, nil] as [Bool?] {
            let folder = try SwapFolder()
            try folder.make(folder.app, version: "0.1.1")
            try folder.make(folder.staged, version: "0.1.2")
            try UpdateTools.swap(folder.staged, into: folder.app, exchange: { _, _ in false }, canSwap: { _ in answer })
            #expect(folder.version(folder.app) == "0.1.2")
            #expect(folder.version(folder.staged) == "0.1.1")
            #expect(!FileManager.default.fileExists(atPath: folder.backup.path))
        }
    }

    /// Même volume, copie cachée disparue (effacée pendant l'attente d'une dictée) : l'app ne quitte jamais sa place.
    @Test func aVolumeThatCannotSwapNeverMovesTheAppWithoutItsStagedCopy() throws {
        let folder = try SwapFolder()
        try folder.make(folder.app, version: "0.1.1")
        try folder.make(folder.backup, version: "0.1.0")
        #expect(throws: UpdateFailure.replace) {
            try UpdateTools.swap(folder.staged, into: folder.app, exchange: { _, _ in false }, canSwap: { _ in false })
        }
        #expect(folder.version(folder.app) == "0.1.1")
        #expect(folder.version(folder.backup) == "0.1.0")
    }

    /// macOS dit si le volume sait échanger deux noms : sans réponse, le repli à deux renommages resterait permis
    /// partout, APFS compris.
    @Test func theVolumeTellsWhetherItCanSwap() throws {
        let folder = try SwapFolder()
        #expect(UpdateTools.volumeCanSwap(folder.root) != nil)
    }

    /// Un seul Wispad tient le verrou de l'installation ; rendu, il se reprend. macOS le rend aussi à la fin du
    /// processus qui le tient, même tué (`flock`). Il vit dans le dossier temporaire de l'utilisateur.
    @Test func onlyOneWispadHoldsTheUpdateLock() throws {
        let folder = try SwapFolder()
        let file = folder.root.appendingPathComponent("WispadUpdate.lock")
        let unlock = try #require(UpdateTools.lock(at: file))
        #expect(UpdateTools.lock(at: file) == nil)
        unlock()
        let again = try #require(UpdateTools.lock(at: file))
        again()
        #expect(UpdateTools.lockURL.deletingLastPathComponent().path == FileManager.default.temporaryDirectory.path)
    }

    /// Fichier de verrou impossible à créer : rien n'est bloqué, le verrou est sans effet, comme avant lui.
    @Test func anUnusableLockFileNeverBlocksTheUpdate() throws {
        let unlock = try #require(UpdateTools.lock(at: URL(fileURLWithPath: "/dev/null/WispadUpdate.lock")))
        unlock()
    }

    /// Aide de relance exécutée pour de vrai : le chemin de l'app et les arguments de Wispad arrivent à `open` tels
    /// quels, même pleins de guillemets, `$(…)`, backquotes et points-virgules. Seul le script, toujours le même, est
    /// lu comme du code : rien d'autre n'est exécuté, rien d'autre n'est ouvert.
    @Test func theRelaunchHelperOpensExactlyTheAppItWasGiven() async throws {
        let folder = try SwapFolder()
        let app = URL(fileURLWithPath: "/Applications/Wispad \"; touch injected; $(touch injected) `touch injected`.app")
        let arguments = ["--updated", "--section", "home; touch injected", "$(touch injected)"]
        let command = UpdateTools.relaunchCommand(pid: Int32.max, app: app, arguments: arguments)
        #expect(Array(command.prefix(3)) == ["-c", UpdateTools.relaunchScript, "wispad-relance"])
        #expect(Array(command.dropFirst(3)) == [String(Int32.max), app.path] + arguments)
        let status = try await runHelper(command, in: folder, opener: #"printf '%s\0' "$@" > opened"#)
        #expect(status == 0)
        let opened = try String(contentsOf: folder.root.appendingPathComponent("opened"), encoding: .utf8)
        #expect(opened.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
                == ["-g", app.path, "--args"] + arguments)
        #expect(!FileManager.default.fileExists(atPath: folder.root.appendingPathComponent("injected").path))
    }

    /// Wispad fermé, ou tué, pendant la relance : l'aide attend la fin de son processus, et seulement ensuite ouvre
    /// l'app.
    @Test func theRelaunchHelperWaitsForWispadToEndBeforeOpeningIt() async throws {
        let folder = try SwapFolder()
        // Wispad simulé : un processus d'une demi-seconde, détaché par un shell intermédiaire. Rattaché à launchd, il
        // disparaît dès sa fin (un enfant du test resterait zombie, et `kill -0` le dirait encore là).
        let output = await Task.detached { () -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "/bin/sleep 0.5 >/dev/null 2>&1 & echo $!"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
            } catch {
                return ""
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        let pid = try #require(Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let command = UpdateTools.relaunchCommand(pid: pid, app: folder.app, arguments: ["--updated"])
        let status = try await runHelper(
            command, in: folder,
            opener: #"if /bin/kill -0 "$WISPAD_PID" 2>/dev/null; then echo vivant; else echo fini; fi > state"#,
            environment: ["WISPAD_PID": String(pid)]
        )
        #expect(status == 0)
        #expect(try String(contentsOf: folder.root.appendingPathComponent("state"), encoding: .utf8) == "fini\n")
    }

    /// Lance l'aide comme Wispad le fait, son `/usr/bin/open` remplacé par un faux script ; rend son code de sortie.
    private func runHelper(_ command: [String], in folder: SwapFolder, opener body: String,
                           environment: [String: String] = [:]) async throws -> Int32 {
        let opener = folder.root.appendingPathComponent("open")
        try ("#!/bin/sh\n" + body + "\n").write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        // Le faux prend la place du vrai dans le texte du script : son chemin doit pouvoir y être écrit tel quel.
        #expect(opener.path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) })
        #expect(command[1].components(separatedBy: "/usr/bin/open").count == 2)
        let arguments = [command[0], command[1].replacingOccurrences(of: "/usr/bin/open", with: opener.path)]
            + command.dropFirst(2)
        let directory = folder.root
        let variables = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        // Comme `UpdateTools.run` : lancé, puis attendu, hors du fil du test.
        return await Task.detached { () -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = variables
            do {
                try process.run()
            } catch {
                return -1
            }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}

/// Dossier temporaire avec une app et la place de sa copie cachée, effacé à la fin du test.
private final class SwapFolder {
    let root: URL
    let app: URL
    let staged: URL
    let backup: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispad-update-\(UUID().uuidString)", isDirectory: true)
        app = root.appendingPathComponent("Wispad.app", isDirectory: true)
        staged = UpdateInstallRules.stagingURL(for: app)
        backup = UpdateInstallRules.backupURL(for: app)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Paquet .app réduit à son numéro de version.
    func make(_ bundle: URL, version: String) throws {
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(version.utf8).write(to: contents.appendingPathComponent("version"))
    }

    func version(_ bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/version")) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
