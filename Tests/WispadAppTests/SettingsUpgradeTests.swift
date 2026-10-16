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

    /// Réglages tels qu'ils s'écrivent dans le bloc, clé par clé.
    private func encoded(_ settings: AppSettings) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }

    /// Valeur d'un autre type que celle enregistrée : illisible pour cette version, quel que soit le réglage.
    private func unreadable(insteadOf value: Any?) -> Any {
        value is [String: Any] ? "valeur d'un autre type" : ["valeur": "d'un autre type"]
    }

    /// Chaque réglage à une valeur différente de celle d'une installation existante sans réglage lisible : un réglage
    /// remis à sa valeur par défaut se voit forcément.
    private static var customized: AppSettings {
        var settings = AppSettings()
        settings.provider = .openAI
        settings.xaiModel = "grok-voice-transcribe-1.0"
        settings.openAIModel = "gpt-4o-mini-transcribe"
        settings.language = .english
        settings.cleanupEnabled = false
        settings.verifyWithFile = false
        settings.tones = ["email": .polished, "notes": .casual]
        settings.selectionCommands = false
        settings.structureDictation = false
        settings.dateFormat = DictationDateFormat(order: .monthDayYear, separator: .dot, fourDigitYear: false, leadingZero: false,
                                                  monthInWords: true, clock: .twelveHour, timeStyle: .colon)
        settings.numberFormat = DictationNumberFormat(thousands: .none, symbols: false)
        settings.useWindowContext = false
        settings.onboardingCompleted = false
        settings.onboardingResume = OnboardingStep.permissions.rawValue
        settings.microphoneUID = "fixture-usb-mic"
        settings.retention = .keepWithHistory
        settings.temporaryHours = 72
        settings.maxStorageMB = 400
        settings.launchAtLogin = true
        settings.keyCode = 61
        settings.modifierFlags = 0x80000
        settings.pasteLastShortcut = PasteShortcut(keyCode: 11, modifiers: ModifierMask.control | ModifierMask.option, enabled: false)
        settings.typingWPM = 52.5
        settings.soundsEnabled = false
        settings.learnCorrections = false
        settings.blurRecentDictations = true
        settings.muteWhileDictating = false
        settings.muteMode = .always
        settings.githubStarClicked = true
        settings.updateRemindedVersion = "0.1.2"
        settings.homePeriod = .days30
        settings.usagePeriod = .all
        settings.usageTaxRate = 8.1
        settings.lastSection = .dictionary
        settings.showsOptionalKeys = true
        settings.dictionaryOriginFilter = .learned
        settings.dictionaryPeriod = .days30
        settings.dictionaryKind = .phrase
        settings.dictionarySort = .originDescending
        settings.overlayPlacement.avoidsInput = false
        settings.overlayPlacement.setAnchor(OverlayAnchor(x: 0.25, y: 0.75), for: .info)
        settings.appearance = .dark
        return settings
    }

    /// La fixture couvre tous les réglages, y compris ceux ajoutés plus tard.
    @Test func customizedFixtureChangesEverySetting() throws {
        let customized = try encoded(Self.customized)
        let defaults = try encoded(AppSettings.existingInstallDefaults)
        #expect(Set(customized.keys) == Set(defaults.keys))
        for (key, value) in customized {
            #expect(!StoredJSON.same(value, try #require(defaults[key])), "\(key) : donne-lui dans `customized` une autre valeur que son défaut")
        }
        #expect(try decode(String(decoding: JSONEncoder().encode(Self.customized), as: UTF8.self)) == Self.customized)
    }

    /// Chaque réglage, rendu illisible à son tour (autre type) : lui seul prend sa valeur par défaut, tous les autres
    /// sont lus tels quels. Un réglage ajouté plus tard est couvert d'office : la liste vient de l'encodage.
    @Test func onlyTheUnreadableSettingTakesItsDefault() throws {
        let original = try encoded(Self.customized)
        let defaults = try encoded(AppSettings.existingInstallDefaults)
        for key in original.keys {
            var block = original
            block[key] = unreadable(insteadOf: original[key])
            let read = try encoded(JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: block)))
            for (other, value) in original {
                let expected = try #require(other == key ? defaults[other] : Optional(value))
                #expect(StoredJSON.same(try #require(read[other]), expected), "\(other) quand \(key) est illisible")
            }
        }
    }

    /// Retour en arrière : chaque réglage tient à son tour une valeur que cette version ne sait pas lire (écrite par une
    /// version plus récente). Lu, réenregistré tel quel puis après un autre changement, le bloc garde cette valeur.
    @Test func olderVersionNeverReplacesAValueItCannotRead() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        let original = try encoded(Self.customized)
        for key in original.keys {
            var block = original
            let newer = unreadable(insteadOf: original[key])
            block[key] = newer
            fixture.defaults.set(try JSONSerialization.data(withJSONObject: block), forKey: AppSettings.defaultsKey)

            var settings = AppSettings.load(from: fixture.defaults)
            settings.save(to: fixture.defaults)
            #expect(StoredJSON.same(try #require(try fixture.storedObject()[key]), newer), "\(key) réenregistré tel quel")
            if key == "blurRecentDictations" { settings.soundsEnabled.toggle() } else { settings.blurRecentDictations.toggle() }
            settings.save(to: fixture.defaults)
            #expect(StoredJSON.same(try #require(try fixture.storedObject()[key]), newer), "\(key) après un autre changement")
            #expect(AppSettings.load(from: fixture.defaults) == settings, "\(key)")
        }
    }

    /// Retour en arrière, cas concret : une version plus récente a enregistré un fournisseur, un modèle, une langue, un
    /// mode, une durée, un format de date (ordre et champ nouveaux), une place de bulle (rôle nouveau) et un ton que
    /// cette version ne connaît pas. Elle les lit à leur valeur par défaut, on change de section : rien n'est perdu.
    @Test func choicesOfANewerVersionSurviveAnOlderOne() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        fixture.store(#"""
        {"provider": "fournisseur-futur", "xaiModel": "grok-voice-transcribe-9.0", "openAIModel": "gpt-live-transcribe",
         "language": "de", "muteMode": "mode-futur", "temporaryHours": 2000, "lastSection": "history",
         "dateFormat": {"order": "ordre-futur", "separator": "dot", "champFutur": "court"},
         "overlayPlacement": {"avoidsInput": false, "anchors": {"roleFutur": {"x": 0.1, "y": 0.2}, "info": {"x": 0.3, "y": 0.4}}},
         "tones": {"email": "ton-futur", "notes": "casual"}, "reglageFutur": {"actif": true}}
        """#)
        let before = try fixture.storedObject()

        var settings = AppSettings.load(from: fixture.defaults)
        #expect(settings.provider == AppSettings().provider)
        #expect(settings.xaiModel == ProviderID.xai.defaultLiveModel)
        #expect(settings.openAIModel == "gpt-live-transcribe")
        #expect(settings.language == .french)
        #expect(settings.muteMode == AppSettings().muteMode)
        #expect(settings.temporaryHours == AppSettings().temporaryHours)
        #expect(settings.dateFormat.order == .dayMonthYear)
        #expect(settings.dateFormat.separator == .dot)
        #expect(settings.overlayPlacement.anchors == ["info": OverlayAnchor(x: 0.3, y: 0.4)])
        #expect(settings.tones == ["notes": .casual])

        settings.lastSection = .usage
        settings.save(to: fixture.defaults)

        let after = try fixture.storedObject()
        for (key, value) in before where key != "lastSection" {
            #expect(StoredJSON.same(try #require(after[key]), value), "\(key)")
        }
        #expect(after["lastSection"] as? String == "usage")
        #expect(AppSettings.load(from: fixture.defaults) == settings)
    }

    /// Réglage changé dans cette version : la nouvelle valeur remplace celle qu'elle ne lisait pas ; un réglage composé
    /// garde ses champs inconnus et ses champs inchangés ; une entrée retirée d'une table disparaît.
    @Test func changedSettingIsWrittenAndKeepsWhatThisVersionDoesNotKnow() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        fixture.store(#"""
        {"provider": "fournisseur-futur", "xaiModel": "grok-voice-transcribe-9.0",
         "dateFormat": {"order": "ordre-futur", "separator": "dot", "champFutur": "court"},
         "overlayPlacement": {"anchors": {"roleFutur": {"x": 0.1, "y": 0.2}}},
         "tones": {"email": "ton-futur", "notes": "casual"}}
        """#)
        var settings = AppSettings.load(from: fixture.defaults)
        settings.provider = .openAI
        settings.xaiModel = "grok-voice-transcribe-1.0"
        settings.dateFormat.separator = .hyphen
        settings.overlayPlacement.setAnchor(OverlayAnchor(x: 0.9, y: 0.9), for: .info)
        settings.tones["notes"] = nil
        settings.save(to: fixture.defaults)

        let stored = try fixture.storedObject()
        #expect(stored["provider"] as? String == "openai")
        #expect(stored["xaiModel"] as? String == "grok-voice-transcribe-1.0")
        let format = try #require(stored["dateFormat"] as? [String: Any])
        #expect(format["order"] as? String == "ordre-futur")
        #expect(format["separator"] as? String == "hyphen")
        #expect(format["champFutur"] as? String == "court")
        let anchors = try #require((stored["overlayPlacement"] as? [String: Any])?["anchors"] as? [String: Any])
        #expect(Set(anchors.keys) == ["roleFutur", "info"])
        #expect(StoredJSON.same(try #require(stored["tones"]), ["email": "ton-futur"]))
        #expect(AppSettings.load(from: fixture.defaults) == settings)
    }

    /// Champs liés (touche et modificateurs d'un raccourci, validés ensemble) : un nouveau raccourci est écrit en entier,
    /// jamais mêlé aux restes illisibles de l'ancien.
    @Test func linkedFieldsAreWrittenTogether() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        // Combinaison sans modificateur, invalide : relue comme ⌃⌥V, désactivé.
        fixture.store(#"{"pasteLastShortcut": {"keyCode": 9, "modifiers": 0, "enabled": false}}"#)
        var settings = AppSettings.load(from: fixture.defaults)
        #expect(settings.pasteLastShortcut == PasteShortcut(keyCode: 9, modifiers: PasteShortcut.standard.modifiers, enabled: false))
        settings.pasteLastShortcut = PasteShortcut(keyCode: 11, modifiers: ModifierMask.control | ModifierMask.option)
        settings.save(to: fixture.defaults)
        #expect(AppSettings.load(from: fixture.defaults).pasteLastShortcut == settings.pasteLastShortcut)
    }

    /// Bloc tronqué, coupé à chaque octet : chaque réglage écrit en entier avant la coupure garde sa valeur, les autres
    /// prennent celle d'une installation existante. Le bloc est mis de côté et n'est pas réécrit par la lecture.
    @Test func truncatedBlockKeepsEveryCompleteSetting() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        let original = try encoded(Self.customized)
        let defaults = try encoded(AppSettings.existingInstallDefaults)
        var text = "{"
        var ends: [(key: String, end: Int)] = []
        for key in original.keys.sorted() {
            let pair = try JSONSerialization.data(withJSONObject: [key: try #require(original[key])], options: .sortedKeys)
            text += (text == "{" ? "" : ",") + String(decoding: pair.dropFirst().dropLast(), as: UTF8.self)
            // Un nombre ou un booléen n'est entier que suivi de son séparateur.
            let closed = text.hasSuffix("\"") || text.hasSuffix("}") || text.hasSuffix("]")
            ends.append((key, text.utf8.count + (closed ? 0 : 1)))
        }
        text += "}"
        let bytes = Array(text.utf8)
        #expect(try decode(text) == Self.customized)

        for cut in 1..<bytes.count {
            let block = Data(bytes[..<cut])
            fixture.defaults.removeObject(forKey: AppSettings.unreadableBackupKey)
            fixture.defaults.set(block, forKey: AppSettings.defaultsKey)
            let read = try encoded(AppSettings.load(from: fixture.defaults))
            for (key, end) in ends {
                let expected = try #require(cut >= end ? original[key] : defaults[key])
                #expect(StoredJSON.same(try #require(read[key]), expected), "\(key) coupé à \(cut)")
            }
            #expect(fixture.defaults.data(forKey: AppSettings.defaultsKey) == block)
            #expect(fixture.defaults.data(forKey: AppSettings.unreadableBackupKey) == block)
        }
    }

    /// Octet abîmé au milieu du bloc : seul le réglage qui le contient prend sa valeur par défaut. La lecture ne
    /// réécrit pas le bloc ; un enregistrement le met de côté avant d'écrire un bloc lisible.
    @Test func damagedByteOnlyResetsItsSetting() throws {
        let fixture = try Defaults()
        defer { fixture.dispose() }
        var bytes = Array(try JSONSerialization.data(withJSONObject: encoded(Self.customized), options: .sortedKeys))
        let uid = Array("fixture-usb-mic".utf8)
        let start = try #require(bytes.indices.first { bytes[$0...].starts(with: uid) })
        bytes[start + 3] = 0xFF
        fixture.defaults.set(Data(bytes), forKey: AppSettings.defaultsKey)

        var settings = AppSettings.load(from: fixture.defaults)
        var expected = Self.customized
        expected.microphoneUID = AppSettings().microphoneUID
        #expect(settings == expected)
        #expect(fixture.defaults.data(forKey: AppSettings.defaultsKey) == Data(bytes))

        settings.microphoneUID = "fixture-usb-mic"
        settings.save(to: fixture.defaults)
        #expect(AppSettings.load(from: fixture.defaults) == Self.customized)
        #expect(fixture.defaults.data(forKey: AppSettings.unreadableBackupKey) == Data(bytes))
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

    /// Fichier de clés écrit dans un dossier temporaire, jamais le vrai.
    private func keyFile(_ contents: String) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("api-keys.json")
        try Data(contents.utf8).write(to: url)
        return (directory, url)
    }

    /// Entrée d'un autre type (ajoutée par une version plus récente, ou abîmée) : elle rendait toutes les clés illisibles
    /// et bloquait l'enregistrement. Elle ne cache plus les autres clés et reste telle quelle quand on en enregistre une.
    @Test func entryOfAnotherTypeHidesNoOtherKey() async throws {
        let (directory, url) = try keyFile(#"{"xai": "valeur-de-test-xai", "openai": 42, "format": {"version": 2}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }

        let read = await APIKeys.LocalFile.readAll(["xai", "openai", "deepseek"], url: url)
        #expect(read.map(\.1) == ["valeur-de-test-xai", nil, nil])
        #expect(read.allSatisfy { $0.2 })
        #expect(await APIKeys.LocalFile.write("deepseek", "valeur-de-test-deepseek", url: url))

        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(StoredJSON.same(stored, [
            "xai": "valeur-de-test-xai", "openai": 42, "format": ["version": 2], "deepseek": "valeur-de-test-deepseek",
        ]))
    }

    /// Fichier de clés tronqué : les clés de sa partie intacte servent, les autres sont dites illisibles (pas absentes),
    /// et le fichier n'est jamais réécrit.
    @Test func truncatedKeyFileKeepsItsIntactKeysAndIsNeverRewritten() async throws {
        let damaged = #"{"deepseek":"valeur-de-test-deepseek","openai":"valeur-de-test-ope"#
        let (directory, url) = try keyFile(damaged)
        defer { try? FileManager.default.removeItem(at: directory) }

        let read = await APIKeys.LocalFile.readAll(["deepseek", "openai", "xai"], url: url)
        #expect(read.map(\.1) == ["valeur-de-test-deepseek", nil, nil])
        #expect(read.map(\.2) == [true, false, false])
        #expect(!(await APIKeys.LocalFile.write("xai", "valeur-de-test-xai", url: url)))
        #expect(!(await APIKeys.LocalFile.delete("deepseek", url: url)))
        #expect(try String(contentsOf: url, encoding: .utf8) == damaged)
    }
}
