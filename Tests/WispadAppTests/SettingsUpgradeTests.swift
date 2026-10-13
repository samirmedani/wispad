import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Une mise à jour ne fait jamais perdre les fournisseurs, réglages ni clés : blocs de réglages d'anciennes versions
/// (valeurs retirées, champs manquants, champs en trop) lus sur des préférences temporaires, jamais les vraies.
struct SettingsUpgradeTests {
    private struct Defaults {
        let suite = "wispad-settings-\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        func store(_ json: String) {
            defaults.set(Data(json.utf8), forKey: AppSettings.defaultsKey)
        }

        func storedObject() throws -> [String: Any] {
            let data = try #require(defaults.data(forKey: AppSettings.defaultsKey))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func dispose() {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func dictionaryFiltersPersistAndReadOlderSettings() throws {
        let old = try decode(#"{"provider": "openai"}"#)
        #expect(old.dictionaryOriginFilter == .all)
        #expect(old.dictionaryPeriod == .all)
        #expect(old.dictionarySort == .newest)
        #expect(try decode(#"{"dictionarySort":"future"}"#).dictionarySort == .newest)
        let invalid = try decode(#"{"dictionaryOriginFilter":"future", "dictionaryPeriod":7, "provider":"openai"}"#)
        #expect(invalid.dictionaryOriginFilter == .all)
        #expect(invalid.dictionaryPeriod == .all)
        #expect(invalid.provider == .openAI)
        let fixture = try Defaults()
        defer { fixture.dispose() }
        var settings = old
        settings.dictionaryOriginFilter = .learned
        settings.dictionaryPeriod = .days30
        settings.dictionaryKind = .phrase
        settings.dictionarySort = .originDescending
        settings.numberFormat = DictationNumberFormat(thousands: .none, symbols: false)
        settings.save(to: fixture.defaults)
        let reloaded = AppSettings.load(from: fixture.defaults)
        #expect(reloaded.dictionaryOriginFilter == .learned)
        #expect(reloaded.dictionaryPeriod == .days30)
        #expect(reloaded.dictionaryKind == .phrase)
        #expect(reloaded.dictionarySort == .originDescending)
        #expect(reloaded.numberFormat == DictationNumberFormat(thousands: .none, symbols: false))
        #expect(old.numberFormat == DictationNumberFormat())
        #expect(reloaded.provider == .openAI)
    }

    /// Bloc d'une ancienne version : modes et fournisseurs depuis retirés (transcription « Sur ce Mac », serveur
    /// compatible OpenAI, raccourcis vocaux), plus des valeurs inconnues. Les choix encore valables restent.
    @Test func removedValuesKeepEveryOtherChoice() throws {
        let settings = try decode(#"""
        {
          "voiceEngine": "local", "localModel": "modele-local-retire",
          "correction": "custom", "customCorrectionURL": "http://localhost:11434/v1", "customCorrectionModel": "m",
          "snippets": [{"id": "a", "trigger": "ma signature", "text": "Bonne journée"}, {"trigger": 42}],
          "offlineLocalVoice": false,
          "provider": "openai", "openAIModel": "gpt-live-transcribe", "xaiModel": "grok-voice-transcribe-1.0",
          "language": "en", "cleanupEnabled": false, "structureDictation": false,
          "tones": {"email": "polished", "messagerie": "ton-retire", "notes": "casual"},
          "retention": "keepWithHistory", "temporaryHours": 48, "maxStorageMB": 400,
          "keyCode": 61, "modifierFlags": 0, "soundsEnabled": false, "learnCorrections": false,
          "muteWhileDictating": false, "muteMode": "always"
        }
        """#)
        #expect(settings.provider == .openAI)
        #expect(settings.openAIModel == "gpt-live-transcribe")
        #expect(settings.xaiModel == "grok-voice-transcribe-1.0")
        #expect(settings.language == .english)
        #expect(settings.cleanupEnabled == false)
        #expect(settings.structureDictation == false)
        #expect(settings.tones == ["email": .polished, "notes": .casual])
        #expect(settings.retention == .keepWithHistory)
        #expect(settings.temporaryHours == 48)
        #expect(settings.maxStorageMB == 400)
        #expect(settings.keyCode == 61)
        #expect(settings.modifierFlags == 0)
        #expect(settings.soundsEnabled == false)
        #expect(settings.learnCorrections == false)
        #expect(settings.muteWhileDictating == false)
        #expect(settings.muteMode == .always)
        #expect(settings.onboardingCompleted)
        #expect(settings.githubStarClicked == false)
    }

    /// Bandeau étoile : absent ou illisible, il reste proposé ; une fois cliqué, il le reste après un rechargement.
    @Test func githubStarClickIsReadLenientlyAndPersists() throws {
        #expect(try decode(#"{"githubStarClicked": "oui", "provider": "openai"}"#).githubStarClicked == false)
        #expect(try decode(#"{"githubStarClicked": "oui", "provider": "openai"}"#).provider == .openAI)
        let fixture = try Defaults()
        defer { fixture.dispose() }
        var settings = AppSettings.load(from: fixture.defaults)
        #expect(settings.githubStarClicked == false)
        settings.githubStarClicked = true
        settings.save(to: fixture.defaults)
        #expect(AppSettings.load(from: fixture.defaults).githubStarClicked)
    }

    /// « Coller la dernière dictée » : absent d'un ancien bloc, ⌃⌥V activé ; illisible ou invalide, ⌃⌥V sans toucher
    /// aux autres réglages ; un choix (combinaison, désactivation) survit à un rechargement.
    @Test func pasteLastShortcutIsReadLenientlyAndPersists() throws {
        #expect(try decode(#"{"provider": "openai"}"#).pasteLastShortcut == .standard)
        let unreadable = try decode(#"{"pasteLastShortcut": "⌃⌥V", "provider": "openai", "keyCode": 61}"#)
        #expect(unreadable.pasteLastShortcut == .standard)
        #expect(unreadable.provider == .openAI)
        #expect(unreadable.keyCode == 61)
        let invalid = try decode(#"{"pasteLastShortcut": {"keyCode": 9, "modifiers": 0, "enabled": false}}"#)
        #expect(invalid.pasteLastShortcut == PasteShortcut(keyCode: 9, modifiers: PasteShortcut.standard.modifiers, enabled: false))

        let fixture = try Defaults()
        defer { fixture.dispose() }
        var settings = AppSettings.load(from: fixture.defaults)
        settings.pasteLastShortcut = PasteShortcut(keyCode: 11, modifiers: ModifierMask.control | ModifierMask.option, enabled: false)
        settings.save(to: fixture.defaults)
        #expect(AppSettings.load(from: fixture.defaults).pasteLastShortcut == settings.pasteLastShortcut)
        #expect(try fixture.storedObject()["pasteLastShortcut"] != nil)
    }

    /// Format des dates et des heures : absent d'un ancien bloc, celui par défaut ; illisible en entier, celui par défaut
    /// sans toucher aux autres réglages ; un champ illisible ne remet que lui-même ; un choix survit à un rechargement.
    @Test func dateFormatIsReadLenientlyAndPersists() throws {
        #expect(try decode(#"{"provider": "openai"}"#).dateFormat == DictationDateFormat(timeStyle: .compact))
        let unreadable = try decode(#"{"dateFormat": "JJ/MM/AAAA", "provider": "openai", "keyCode": 61}"#)
        #expect(unreadable.dateFormat == DictationDateFormat(timeStyle: .compact))
        #expect(unreadable.provider == .openAI)
        #expect(unreadable.keyCode == 61)
        let partial = try decode(#"{"dateFormat": {"order": "iso", "clock": "horloge-retiree", "monthInWords": true}}"#)
        #expect(partial.dateFormat == DictationDateFormat(order: .iso, monthInWords: true))

        let fixture = try Defaults()
        defer { fixture.dispose() }
        var settings = AppSettings.load(from: fixture.defaults)
        settings.dateFormat = DictationDateFormat(order: .monthDayYear, separator: .dot, fourDigitYear: false, leadingZero: false,
                                                  monthInWords: true, clock: .twelveHour, timeStyle: .colon)
        settings.save(to: fixture.defaults)
        #expect(AppSettings.load(from: fixture.defaults).dateFormat == settings.dateFormat)
        #expect(try fixture.storedObject()["dateFormat"] != nil)
    }

    /// Fournisseur ou modèle de voix retiré : le fournisseur par défaut, ou le modèle par défaut du même fournisseur.
    @Test func removedProviderOrModelFallsBackToTheClosestValidOne() throws {
        let removedProvider = try decode(#"{"provider": "fournisseur-retire", "cleanupEnabled": false}"#)
        #expect(removedProvider.provider == AppSettings().provider)
        #expect(removedProvider.cleanupEnabled == false)

        let removedModels = try decode(#"{"provider": "openai", "openAIModel": "modele-retire", "xaiModel": "autre-retire"}"#)
        #expect(removedModels.provider == .openAI)
        #expect(removedModels.openAIModel == ProviderID.openAI.defaultLiveModel)
        #expect(removedModels.xaiModel == ProviderID.xai.defaultLiveModel)
    }

    /// Une valeur d'un mauvais type ou hors limites ne remet que ce réglage à sa valeur par défaut.
    @Test func unreadableFieldOnlyResetsItself() throws {
        let settings = try decode(#"""
        {"provider": "openai", "soundsEnabled": "oui", "temporaryHours": -5, "maxStorageMB": "beaucoup",
         "typingWPM": 0, "tones": "pas un dictionnaire", "muteMode": 3, "keyCode": 61}
        """#)
        let defaults = AppSettings()
        #expect(settings.provider == .openAI)
        #expect(settings.keyCode == 61)
        #expect(settings.soundsEnabled == defaults.soundsEnabled)
        #expect(settings.temporaryHours == defaults.temporaryHours)
        #expect(settings.maxStorageMB == defaults.maxStorageMB)
        #expect(settings.typingWPM == defaults.typingWPM)
        #expect(settings.tones.isEmpty)
        #expect(settings.muteMode == defaults.muteMode)
    }

    /// Bloc d'une version d'avant la plupart des réglages : seuls les choix présents sont repris.
    @Test func missingFieldsTakeTheirDefaults() throws {
        let settings = try decode(#"{"provider": "openai"}"#)
        let defaults = AppSettings()
        #expect(settings.provider == .openAI)
        #expect(settings.openAIModel == defaults.openAIModel)
        #expect(settings.muteMode == defaults.muteMode)
        #expect(settings.retention == defaults.retention)
        #expect(settings.language == .french)
        #expect(settings.onboardingCompleted)
        #expect(settings.dateFormat == defaults.dateFormat)
    }

    /// Un élément illisible d'une liste ou d'un dictionnaire est écarté, ses voisins restent.
    @Test func unreadableElementsAreDroppedAlone() throws {
        let list = try JSONDecoder().decode([Lenient<DictationTone>].self, from: Data(#"["natural", "retire", 3, "casual"]"#.utf8))
        #expect(list.compactMap(\.value) == [.natural, .casual])
    }

    @Test func absentBlockIsAFreshInstall() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        #expect(AppSettings.load(from: fixture.defaults) == AppSettings())
    }

    /// Bloc illisible en entier : rien n'est réécrit à la lecture, une copie est mise de côté avant toute écriture,
    /// et l'app repart comme une installation existante (pas de premier lancement guidé).
    @Test func unreadableBlockIsSetAsideAndNeverOverwrittenOnRead() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        let original = Data("pas du JSON".utf8)
        fixture.defaults.set(original, forKey: AppSettings.defaultsKey)

        let loaded = AppSettings.load(from: fixture.defaults)

        #expect(loaded == AppSettings.existingInstallDefaults)
        #expect(loaded.onboardingCompleted)
        #expect(fixture.defaults.data(forKey: AppSettings.defaultsKey) == original)
        #expect(fixture.defaults.data(forKey: AppSettings.unreadableBackupKey) == original)

        // Une lecture suivante, puis une écriture, ne remplacent jamais la copie mise de côté.
        fixture.defaults.set(Data("autre bloc illisible".utf8), forKey: AppSettings.defaultsKey)
        var changed = AppSettings.load(from: fixture.defaults)
        changed.soundsEnabled = false
        changed.save(to: fixture.defaults)
        #expect(fixture.defaults.data(forKey: AppSettings.unreadableBackupKey) == original)
        #expect(AppSettings.load(from: fixture.defaults).soundsEnabled == false)
    }

    /// Lire un bloc ancien ne l'écrit pas ; l'enregistrer garde les clés inconnues (réglage retiré ou plus récent)
    /// pour qu'un retour à une version précédente retrouve ses choix.
    @Test func savingKeepsKeysThisVersionDoesNotKnow() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        fixture.store(#"""
        {"provider": "openai", "reglageRetire": [{"trigger": "ma signature", "text": "Bonne journée"}],
         "reglageFutur": {"actif": true}}
        """#)
        let before = fixture.defaults.data(forKey: AppSettings.defaultsKey)

        var settings = AppSettings.load(from: fixture.defaults)
        #expect(fixture.defaults.data(forKey: AppSettings.defaultsKey) == before)
        #expect(settings.provider == .openAI)

        settings.soundsEnabled = false
        settings.save(to: fixture.defaults)

        let stored = try fixture.storedObject()
        #expect(stored["provider"] as? String == "openai")
        #expect(stored["soundsEnabled"] as? Bool == false)
        #expect((stored["reglageRetire"] as? [Any])?.count == 1)
        #expect((stored["reglageFutur"] as? [String: Bool]) == ["actif": true])
        #expect(AppSettings.load(from: fixture.defaults) == settings)
    }

    /// Un réglage retiré volontairement (`retiredKeys`) n'est pas recopié par l'enregistrement.
    @Test func savingDoesNotReviveRetiredKeys() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        fixture.store(#"{"provider": "openai", "snippets": [{"trigger": "ma signature", "text": "Bonne journée"}], "voiceEngine": "local", "localModel": "parakeet-tdt-0.6b-v3", "offlineLocalVoice": true, "correction": "custom", "customCorrectionURL": "http://localhost:11434/v1", "customCorrectionModel": "m", "reglageFutur": 1}"#)
        var settings = AppSettings.load(from: fixture.defaults)
        settings.soundsEnabled = false
        settings.save(to: fixture.defaults)
        let stored = try fixture.storedObject()
        #expect(AppSettings.retiredKeys.allSatisfy { stored[$0] == nil })
        #expect(stored["reglageFutur"] as? Int == 1)
        #expect(stored["provider"] as? String == "openai")
    }

    /// Rappel de mise à jour : absent ou illisible, aucune version n'a été rappelée ; une fois noté, il le reste.
    @Test func updateReminderIsReadLenientlyAndPersists() throws {
        #expect(try decode(#"{"provider": "openai"}"#).updateRemindedVersion == "")
        #expect(try decode(#"{"updateRemindedVersion": 12, "provider": "openai"}"#).updateRemindedVersion == "")
        #expect(try decode(#"{"updateRemindedVersion": 12, "provider": "openai"}"#).provider == .openAI)
        let fixture = try Defaults()
        defer { fixture.dispose() }
        var settings = AppSettings.load(from: fixture.defaults)
        #expect(settings.updateRemindedVersion == "")
        settings.updateRemindedVersion = "0.1.2"
        settings.save(to: fixture.defaults)
        #expect(AppSettings.load(from: fixture.defaults).updateRemindedVersion == "0.1.2")
    }

    @Test func everySettingSurvivesASaveAndReload() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        var settings = AppSettings()
        settings.provider = .openAI
        settings.openAIModel = "gpt-4o-mini-transcribe"
        settings.language = .auto
        settings.tones = ["email": .polished]
        settings.temporaryHours = 72
        settings.typingWPM = 52.5
        settings.modifierFlags = 0x100000
        settings.onboardingCompleted = true
        settings.githubStarClicked = true
        settings.updateRemindedVersion = "0.1.2"
        settings.dateFormat = DictationDateFormat(order: .iso, clock: .twelveHour)
        settings.save(to: fixture.defaults)
        #expect(AppSettings.load(from: fixture.defaults) == settings)
    }
}

/// Identité et emplacements dont dépendent les données d'un utilisateur : les changer ferait perdre réglages,
/// historique et clés à la mise à jour suivante. Toute modification doit passer par une reprise (`LegacyMigration`).
struct StorageIdentityTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func identifiersAndStorageNamesStayStable() {
        #expect(AppIdentity.bundleID == "com.yatofix.wispad")
        #expect(AppIdentity.supportFolderName == "Wispad")
        #expect(AppIdentity.databaseName == "wispad.sqlite")
        #expect(AppSettings.defaultsKey == "wispad.settings.v1")
        #expect(LegacyMigration.legacyBundleID == "com.yatofix.openflow")
        #expect(APIKeys.Vault.names(for: ProviderID.xai.rawValue) == ["WISPAD_XAI_API_KEY"])
        #expect(APIKeys.Vault.names(for: ProviderID.openAI.rawValue) == ["WISPAD_OPENAI_API_KEY"])
        #expect(APIKeys.Vault.names(for: CleanupModel.deepSeekAccount) == ["WISPAD_DEEPSEEK_API_KEY"])
        #expect(ProviderID.xai.rawValue == "xai")
        #expect(ProviderID.openAI.rawValue == "openai")
    }

    @Test func projectKeepsTheBundleIdentifier() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: \(AppIdentity.bundleID)"))
    }

    /// La réinstallation ne remplace que le paquet .app : jamais les données, les préférences ni les autorisations.
    @Test func installScriptOnlyReplacesTheAppBundle() throws {
        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        for forbidden in ["Application Support", "Library/", "defaults delete", "tccutil", "api-keys", ".sqlite"] {
            #expect(!script.contains(forbidden), "install.sh ne doit pas toucher à \(forbidden)")
        }
        let removals = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("rm ") }
        #expect(removals == [#"rm -rf "$STAGED""#, #"rm -rf "$DEST""#])
        #expect(script.contains(#"[[ "$DEST" == *.app"#))
    }
}

/// Clés API à la mise à jour : un fournisseur retiré ne fait perdre aucune clé enregistrée.
struct APIKeysUpgradeTests {
    @Test func savingAKeepsKeysOfAccountsThisVersionNoLongerKnows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("api-keys.json")
        let old = #"{"xai": "valeur-de-test-xai", "fournisseur-retire": "valeur-de-test-retiree"}"#
        try Data(old.utf8).write(to: url)

        #expect(await APIKeys.LocalFile.readAll(["xai", "openai"], url: url).map(\.1) == ["valeur-de-test-xai", nil])
        #expect(await APIKeys.LocalFile.write("openai", "valeur-de-test-openai", url: url))

        let stored = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        #expect(stored == [
            "xai": "valeur-de-test-xai",
            "openai": "valeur-de-test-openai",
            "fournisseur-retire": "valeur-de-test-retiree",
        ])
    }
}
