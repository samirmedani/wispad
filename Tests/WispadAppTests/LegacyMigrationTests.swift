import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore
import SQLite3

/// Reprise des données OpenFlow, sur un dossier et des préférences temporaires (jamais les vrais).
@MainActor
struct LegacyMigrationTests {
    private struct Fixture {
        let root: URL
        let legacy: URL
        let current: URL
        let defaults: UserDefaults
        let legacyDefaults: UserDefaults
        let suites: [String]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-migration-\(UUID().uuidString)")
            legacy = root.appendingPathComponent(LegacyMigration.legacyFolderName, isDirectory: true)
            current = root.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Audio"), withIntermediateDirectories: true)
            suites = ["wispad-migration-new-\(UUID().uuidString)", "wispad-migration-old-\(UUID().uuidString)"]
            defaults = try #require(UserDefaults(suiteName: suites[0]))
            legacyDefaults = try #require(UserDefaults(suiteName: suites[1]))
        }

        func dispose() {
            try? FileManager.default.removeItem(at: root)
            suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        }
    }

    @Test func movesDatabaseAudioAndSettingsThenForgetsTheLegacyFolder() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let legacyAudio = fixture.legacy.appendingPathComponent("Audio/dictee.wav")
        try Data("RIFF".utf8).write(to: legacyAudio)
        try Data("latence".utf8).write(to: fixture.legacy.appendingPathComponent("latence.log"))
        do {
            let store = try HistoryStore(path: fixture.legacy.appendingPathComponent(LegacyMigration.legacyDatabaseName).path)
            try store.insert(DictationRecord(
                id: "dictee", finalText: "Bonjour.", rawText: "bonjour", durationSeconds: 1, wordCount: 1,
                provider: "xai", model: "m", insertionStatus: "inserted", audioPath: legacyAudio.path
            ))
            try store.insert(DictationRecord(
                id: "ailleurs", finalText: "Autre.", rawText: "autre", durationSeconds: 1, wordCount: 1,
                provider: "xai", model: "m", insertionStatus: "inserted", audioPath: "/Volumes/Autre/garde.wav"
            ))
        }
        var settings = AppSettings()
        settings.launchAtLogin = true
        settings.soundsEnabled = false
        fixture.legacyDefaults.set(try JSONEncoder().encode(settings), forKey: LegacyMigration.legacySettingsKey)
        fixture.legacyDefaults.set(["volume": 0.5], forKey: "wispad.output.muted")

        let report = LegacyMigration.run(supportRoot: fixture.root, defaults: fixture.defaults, legacyDefaults: fixture.legacyDefaults)

        #expect(report.movedDatabase)
        #expect(report.copiedSettings)
        #expect(report.launchAtLogin)
        #expect(report.relocatedAudioPaths == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.legacy.path))
        let store = try HistoryStore(path: fixture.current.appendingPathComponent(AppIdentity.databaseName).path)
        let records = try store.dictations()
        let moved = try #require(records.first { $0.id == "dictee" })
        #expect(moved.audioPath == fixture.current.appendingPathComponent("Audio/dictee.wav").path)
        #expect(FileManager.default.fileExists(atPath: moved.audioPath ?? ""))
        #expect(records.first { $0.id == "ailleurs" }?.audioPath == "/Volumes/Autre/garde.wav")
        #expect(FileManager.default.fileExists(atPath: fixture.current.appendingPathComponent("latence.log").path))
        let copied = try JSONDecoder().decode(AppSettings.self, from: try #require(fixture.defaults.data(forKey: AppSettings.defaultsKey)))
        #expect(copied.soundsEnabled == false)
        #expect(fixture.defaults.dictionary(forKey: "wispad.output.muted") != nil)
    }

    @Test func runsOnceAndNeverOverwritesExistingWispadData() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(at: fixture.current, withIntermediateDirectories: true)
        do {
            let store = try HistoryStore(path: fixture.current.appendingPathComponent(AppIdentity.databaseName).path)
            try store.addTerm("Wispad")
        }
        do {
            let legacyStore = try HistoryStore(path: fixture.legacy.appendingPathComponent(LegacyMigration.legacyDatabaseName).path)
            try legacyStore.addTerm("OpenFlow")
        }
        var kept = AppSettings()
        kept.soundsEnabled = false
        fixture.defaults.set(try JSONEncoder().encode(kept), forKey: AppSettings.defaultsKey)
        fixture.legacyDefaults.set(try JSONEncoder().encode(AppSettings()), forKey: LegacyMigration.legacySettingsKey)

        let report = LegacyMigration.run(supportRoot: fixture.root, defaults: fixture.defaults, legacyDefaults: fixture.legacyDefaults)

        #expect(!report.movedDatabase)
        #expect(!report.copiedSettings)
        let terms = try HistoryStore(path: fixture.current.appendingPathComponent(AppIdentity.databaseName).path).dictionary().map(\.term)
        #expect(terms == ["Wispad"])
        // L'ancienne base, non reprise, reste à sa place.
        #expect(FileManager.default.fileExists(atPath: fixture.legacy.appendingPathComponent(LegacyMigration.legacyDatabaseName).path))
        let settings = try JSONDecoder().decode(AppSettings.self, from: try #require(fixture.defaults.data(forKey: AppSettings.defaultsKey)))
        #expect(settings.soundsEnabled == false)
    }

    @Test func aPrototypeDatabaseInTheWayIsSetAsideNotDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        // Cas réel : un « wispad.sqlite » d'un ancien prototype, sans table des dictées, occupe la place.
        try FileManager.default.createDirectory(at: fixture.current, withIntermediateDirectories: true)
        let prototype = fixture.current.appendingPathComponent(AppIdentity.databaseName)
        var connection: OpaquePointer?
        #expect(sqlite3_open(prototype.path, &connection) == SQLITE_OK)
        sqlite3_exec(connection, "CREATE TABLE dictation (id TEXT); INSERT INTO dictation VALUES ('ancienne');", nil, nil, nil)
        sqlite3_close(connection)
        do {
            let legacyStore = try HistoryStore(path: fixture.legacy.appendingPathComponent(LegacyMigration.legacyDatabaseName).path)
            try legacyStore.addTerm("OpenFlow")
        }

        let report = LegacyMigration.run(supportRoot: fixture.root, defaults: fixture.defaults, legacyDefaults: fixture.legacyDefaults)

        #expect(report.setAsideDatabase)
        #expect(report.movedDatabase)
        let terms = try HistoryStore(path: prototype.path).dictionary().map(\.term)
        #expect(terms == ["OpenFlow"])
        let setAside = fixture.current.appendingPathComponent("wispad-avant-reprise.sqlite")
        #expect(FileManager.default.fileExists(atPath: setAside.path))
    }

    /// Bloc OpenFlow d'une ancienne version (valeurs retirées, champ inconnu) : repris tel quel, fournisseur gardé.
    @Test func legacySettingsWithRemovedValuesKeepTheirProvider() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let legacy = #"{"provider": "openai", "voiceEngine": "local", "correction": "custom", "champInconnu": 1, "launchAtLogin": true, "soundsEnabled": "oui"}"#
        fixture.legacyDefaults.set(Data(legacy.utf8), forKey: LegacyMigration.legacySettingsKey)

        let report = LegacyMigration.run(supportRoot: fixture.root, defaults: fixture.defaults, legacyDefaults: fixture.legacyDefaults)

        #expect(report.copiedSettings)
        #expect(report.launchAtLogin)
        #expect(fixture.defaults.data(forKey: AppSettings.defaultsKey) == Data(legacy.utf8))
        let settings = AppSettings.load(from: fixture.defaults)
        #expect(settings.provider == .openAI)
        #expect(settings.launchAtLogin)
        #expect(settings.soundsEnabled == AppSettings().soundsEnabled)
        // L'ancien bloc reste dans les préférences OpenFlow.
        #expect(fixture.legacyDefaults.data(forKey: LegacyMigration.legacySettingsKey) != nil)
    }

    /// Bloc Wispad présent mais d'un autre type (abîmé) : il était pris pour absent et remplacé par les réglages
    /// OpenFlow, sans copie. Il reste en place, et la lecture des réglages le met de côté.
    @Test func aWispadBlockOfAnotherTypeIsNeverReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        fixture.defaults.set("bloc d'un autre type", forKey: AppSettings.defaultsKey)
        fixture.legacyDefaults.set(try JSONEncoder().encode(AppSettings()), forKey: LegacyMigration.legacySettingsKey)

        let report = LegacyMigration.run(supportRoot: fixture.root, defaults: fixture.defaults, legacyDefaults: fixture.legacyDefaults)

        #expect(!report.copiedSettings)
        #expect(fixture.defaults.string(forKey: AppSettings.defaultsKey) == "bloc d'un autre type")
        #expect(AppSettings.load(from: fixture.defaults) == AppSettings.existingInstallDefaults)
        #expect(fixture.defaults.string(forKey: AppSettings.unreadableBackupKey) == "bloc d'un autre type")
    }

    /// Fichier de clés OpenFlow : repris si Wispad n'en a pas, laissé en place (jamais écrasé) sinon.
    @Test func legacyKeyFileMovesOnlyWhenWispadHasNone() throws {
        let keys = Data(#"{"xai": "valeur-de-test-ancienne"}"#.utf8)
        do {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            try keys.write(to: fixture.legacy.appendingPathComponent("api-keys.json"))
            _ = LegacyMigration.run(supportRoot: fixture.root, defaults: fixture.defaults, legacyDefaults: fixture.legacyDefaults)
            #expect(try Data(contentsOf: fixture.current.appendingPathComponent("api-keys.json")) == keys)
        }
        do {
            let fixture = try Fixture()
            defer { fixture.dispose() }
            try FileManager.default.createDirectory(at: fixture.current, withIntermediateDirectories: true)
            let current = Data(#"{"xai": "valeur-de-test-actuelle"}"#.utf8)
            try current.write(to: fixture.current.appendingPathComponent("api-keys.json"))
            try keys.write(to: fixture.legacy.appendingPathComponent("api-keys.json"))
            _ = LegacyMigration.run(supportRoot: fixture.root, defaults: fixture.defaults, legacyDefaults: fixture.legacyDefaults)
            #expect(try Data(contentsOf: fixture.current.appendingPathComponent("api-keys.json")) == current)
            #expect(try Data(contentsOf: fixture.legacy.appendingPathComponent("api-keys.json")) == keys)
        }
    }

    @Test func freshInstallLeavesEverythingUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        try FileManager.default.removeItem(at: fixture.legacy)
        let report = LegacyMigration.run(supportRoot: fixture.root, defaults: fixture.defaults, legacyDefaults: fixture.legacyDefaults)
        #expect(report == LegacyMigration.Report())
        #expect(!FileManager.default.fileExists(atPath: fixture.current.path))
    }
}
