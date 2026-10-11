import Foundation
import Testing
@testable import WispadApp

/// Réglages retirés (raccourcis vocaux, transcription sur le Mac, serveur de correction) : effacés des préférences au lancement, sur des préférences temporaires.
struct RetiredSettingsTests {
    private struct Fixture {
        let suite = "wispad-retired-\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        func dispose() {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        func stored() throws -> [String: Any] {
            let data = try #require(defaults.data(forKey: AppSettings.defaultsKey))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    @Test func savedVoiceSnippetsAreErasedAndOtherSettingsKept() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        var settings = AppSettings()
        settings.soundsEnabled = false
        settings.tones = ["email": .polished]
        var stored = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        stored["snippets"] = [["id": "un", "trigger": "mon adresse mail", "text": "camille@example.com"]]
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: AppSettings.defaultsKey)

        AppSettings.removeRetiredKeys(from: fixture.defaults)

        #expect(try fixture.stored()["snippets"] == nil)
        let kept = try JSONDecoder().decode(AppSettings.self, from: try #require(fixture.defaults.data(forKey: AppSettings.defaultsKey)))
        #expect(kept == settings)
    }

    @Test func localTranscriptionChoiceGoesBackToTheCloud() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let saved = #"{"voiceEngine":"local","localModel":"parakeet-tdt-0.6b-v3","offlineLocalVoice":true,"provider":"openai","soundsEnabled":false}"#
        fixture.defaults.set(Data(saved.utf8), forKey: AppSettings.defaultsKey)

        AppSettings.removeRetiredKeys(from: fixture.defaults)

        #expect(Set(try fixture.stored().keys) == ["provider", "soundsEnabled"])
        let kept = try JSONDecoder().decode(AppSettings.self, from: try #require(fixture.defaults.data(forKey: AppSettings.defaultsKey)))
        #expect(kept.provider == .openAI)
        #expect(!kept.soundsEnabled)
    }

    @Test func customCorrectionServerGoesBackToAutomatic() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let saved = #"{"correction":"custom","customCorrectionURL":"http://localhost:11434/v1","customCorrectionModel":"modele-fictif","cleanupEnabled":false}"#
        fixture.defaults.set(Data(saved.utf8), forKey: AppSettings.defaultsKey)

        AppSettings.removeRetiredKeys(from: fixture.defaults)

        #expect(Set(try fixture.stored().keys) == ["cleanupEnabled"])
    }

    @Test func nothingIsWrittenWithoutRetiredSettings() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        AppSettings.removeRetiredKeys(from: fixture.defaults)
        #expect(fixture.defaults.data(forKey: AppSettings.defaultsKey) == nil)

        let data = try JSONEncoder().encode(AppSettings())
        fixture.defaults.set(data, forKey: AppSettings.defaultsKey)
        AppSettings.removeRetiredKeys(from: fixture.defaults)
        #expect(fixture.defaults.data(forKey: AppSettings.defaultsKey) == data)
    }
}
