import AppKit
import Foundation
import os
import SQLite3

/// Reprise, au premier lancement de Wispad, des données de l'ancien identifiant (`com.yatofix.openflow`,
/// dossier « OpenFlow »). Une seule fois : la base, les audios et les réglages changent de place, rien n'est
/// recopié deux fois et rien de non repris n'est supprimé. Les autorisations macOS (micro, accessibilité,
/// surveillance des entrées) suivent l'identifiant de l'app : elles sont à redonner, l'accueil le signale.
enum LegacyMigration {
    static let legacyBundleID = "com.yatofix.openflow"
    static let legacyFolderName = "OpenFlow"
    static let legacyDatabaseName = "openflow.sqlite"
    static let legacySettingsKey = "openflow.settings.v1"
    /// Clés reprises telles quelles (même nom des deux côtés).
    static let sharedDefaultsKeys = ["wispad.output.muted"]

    struct Report: Equatable {
        var movedDatabase = false
        /// Une base sans historique Wispad (ancien prototype) occupait la place : renommée, pas supprimée.
        var setAsideDatabase = false
        var movedFiles = 0
        var relocatedAudioPaths = 0
        var copiedSettings = false
        var launchAtLogin = false
    }

    private static let log = Logger.wispad("migration")

    /// Lancement normal de l'app : dossier Application Support et préférences réelles.
    @MainActor
    static func runAtLaunch() {
        guard let root = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        closeLegacyApp()
        let report = run(
            supportRoot: root,
            defaults: .standard,
            legacyDefaults: UserDefaults(suiteName: legacyBundleID)
        )
        if report.launchAtLogin {
            // L'ancienne ouverture à la connexion visait l'ancien identifiant : la nouvelle app la reprend.
            try? LoginItemController.setEnabled(true)
        }
        if report != Report() {
            log.notice("reprise OpenFlow : base=\(report.movedDatabase, privacy: .public) écartée=\(report.setAsideDatabase, privacy: .public) fichiers=\(report.movedFiles, privacy: .public) audios=\(report.relocatedAudioPaths, privacy: .public) réglages=\(report.copiedSettings, privacy: .public)")
        }
    }

    /// Cœur de la reprise, sans dépendance au système : testé sur des dossiers et des préférences temporaires.
    static func run(supportRoot: URL, defaults: UserDefaults, legacyDefaults: UserDefaults?) -> Report {
        var report = Report()
        let fileManager = FileManager.default
        let legacy = supportRoot.appendingPathComponent(legacyFolderName, isDirectory: true)
        let current = supportRoot.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)

        // Un bloc Wispad présent, même abîmé ou d'un autre type, n'est jamais remplacé : `AppSettings.load` le met
        // de côté.
        if let legacyDefaults, defaults.object(forKey: AppSettings.defaultsKey) == nil,
           let settings = legacyDefaults.data(forKey: legacySettingsKey) {
            defaults.set(settings, forKey: AppSettings.defaultsKey)
            report.copiedSettings = true
            report.launchAtLogin = (try? JSONDecoder().decode(AppSettings.self, from: settings))?.launchAtLogin ?? false
            for key in sharedDefaultsKeys where defaults.object(forKey: key) == nil {
                if let value = legacyDefaults.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return report
        }
        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)

        let legacyDatabase = legacy.appendingPathComponent(legacyDatabaseName)
        let database = current.appendingPathComponent(AppIdentity.databaseName)
        if fileManager.fileExists(atPath: legacyDatabase.path), fileManager.fileExists(atPath: database.path),
           !holdsDictations(database.path) {
            report.setAsideDatabase = setAside(database)
        }
        if fileManager.fileExists(atPath: legacyDatabase.path), !fileManager.fileExists(atPath: database.path) {
            // Le journal WAL est d'abord reversé dans la base : elle se déplace alors en un seul fichier.
            checkpoint(legacyDatabase.path)
            do {
                try fileManager.moveItem(at: legacyDatabase, to: database)
                report.movedDatabase = true
                for suffix in ["-wal", "-shm"] {
                    let side = URL(fileURLWithPath: legacyDatabase.path + suffix)
                    if fileManager.fileExists(atPath: side.path) {
                        try? fileManager.moveItem(at: side, to: URL(fileURLWithPath: database.path + suffix))
                    }
                }
            } catch {
                log.error("reprise OpenFlow : base non déplacée")
            }
        }

        let legacyAudio = legacy.appendingPathComponent("Audio", isDirectory: true)
        let audio = current.appendingPathComponent("Audio", isDirectory: true)
        if let files = try? fileManager.contentsOfDirectory(atPath: legacyAudio.path), !files.isEmpty {
            try? fileManager.createDirectory(at: audio, withIntermediateDirectories: true)
            for name in files {
                let destination = audio.appendingPathComponent(name)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                if (try? fileManager.moveItem(at: legacyAudio.appendingPathComponent(name), to: destination)) != nil {
                    report.movedFiles += 1
                }
            }
        }
        if report.movedDatabase || report.movedFiles > 0 {
            report.relocatedAudioPaths = relocateAudioPaths(
                in: database.path,
                from: legacyAudio.path + "/",
                to: audio.path + "/"
            )
        }

        // Le fichier de clés n'est repris que si Wispad n'en a pas encore : une clé déjà saisie n'est jamais écrasée,
        // et l'ancien fichier reste alors en place.
        for name in ["latence.log", "api-test-spend.json", "api-keys.json"] {
            let source = legacy.appendingPathComponent(name)
            let destination = current.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else { continue }
            if (try? fileManager.moveItem(at: source, to: destination)) != nil { report.movedFiles += 1 }
        }

        // Le dossier n'est retiré que s'il ne contient plus rien d'utile (un .DS_Store ne compte pas).
        removeIfEmpty(legacyAudio)
        removeIfEmpty(legacy)
        return report
    }

    /// L'ancienne app tient la base ouverte : elle est fermée avant la reprise.
    @MainActor
    private static func closeLegacyApp() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, running.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// Vraie base Wispad : elle a la table des dictées. Un ancien prototype du même nom ne l'a pas.
    private static func holdsDictations(_ path: String) -> Bool {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            // Illisible : dans le doute, rien n'est déplacé.
            return true
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'dictations';"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return true }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Renomme une base (et son journal) en « …-avant-reprise.sqlite », sans rien écraser.
    private static func setAside(_ database: URL) -> Bool {
        let fileManager = FileManager.default
        let folder = database.deletingLastPathComponent()
        let stem = database.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent("\(stem)-avant-reprise.sqlite")
        var index = 2
        while fileManager.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem)-avant-reprise-\(index).sqlite")
            index += 1
        }
        do {
            try fileManager.moveItem(at: database, to: target)
        } catch {
            log.error("reprise OpenFlow : ancienne base non renommée")
            return false
        }
        for suffix in ["-wal", "-shm"] where fileManager.fileExists(atPath: database.path + suffix) {
            try? fileManager.moveItem(atPath: database.path + suffix, toPath: target.path + suffix)
        }
        return true
    }

    private static func checkpoint(_ path: String) {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return
        }
        sqlite3_exec(connection, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        sqlite3_close(connection)
    }

    /// Les chemins d'audio sont absolus dans la base : ils suivent les fichiers déplacés.
    private static func relocateAudioPaths(in path: String, from oldPrefix: String, to newPrefix: String) -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return 0
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        let sql = "UPDATE dictations SET audio_path = ?1 || substr(audio_path, ?2) WHERE substr(audio_path, 1, ?3) = ?4;"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        // SQLite compte les caractères Unicode d'un texte, pas ses octets.
        let prefixLength = Int32(oldPrefix.unicodeScalars.count)
        sqlite3_bind_text(statement, 1, newPrefix, -1, transient)
        sqlite3_bind_int(statement, 2, prefixLength + 1)
        sqlite3_bind_int(statement, 3, prefixLength)
        sqlite3_bind_text(statement, 4, oldPrefix, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(connection))
    }

    private static func removeIfEmpty(_ directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
