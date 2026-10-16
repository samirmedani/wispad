import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Choix d'affichage (périodes, section, clés facultatives dépliées) : retrouvés après une relance, lus de façon
/// tolérante, sur des préférences temporaires, jamais les vraies.
struct DisplayChoicesTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    /// Nouvelle installation : Accueil sur 7 jours, Consommation sur Aujourd'hui, section Accueil, clés repliées.
    @Test func defaultsAreUnchangedForANewUser() {
        let settings = AppSettings()
        #expect(settings.homePeriod == .days7)
        #expect(settings.usagePeriod == .today)
        #expect(settings.lastSection == .home)
        #expect(settings.showsOptionalKeys == false)
    }

    /// Ancien bloc, sans ces clés : valeurs par défaut, les autres réglages restent.
    @Test func missingChoicesTakeTheirDefaults() throws {
        let settings = try decode(#"{"provider": "openai", "soundsEnabled": false}"#)
        #expect(settings.homePeriod == .days7)
        #expect(settings.usagePeriod == .today)
        #expect(settings.usageTaxRate == 20)
        #expect(settings.lastSection == .home)
        #expect(settings.showsOptionalKeys == false)
        #expect(settings.provider == .openAI)
        #expect(settings.soundsEnabled == false)
    }

    /// Valeur inconnue (période ou section retirée, ajoutée par une version plus récente) ou d'un mauvais type :
    /// la valeur par défaut de ce seul choix.
    @Test func unknownChoicesFallBackToTheirDefaultsAlone() throws {
        let settings = try decode(#"""
        {"homePeriod": "days90", "usagePeriod": 30, "lastSection": "section-retiree", "showsOptionalKeys": "oui",
         "usageTaxRate": 99, "provider": "openai", "learnCorrections": false}
        """#)
        #expect(settings.homePeriod == .days7)
        #expect(settings.usagePeriod == .today)
        #expect(settings.usageTaxRate == 20)
        #expect(settings.lastSection == .home)
        #expect(settings.showsOptionalKeys == false)
        #expect(settings.provider == .openAI)
        #expect(settings.learnCorrections == false)

        let mixed = try decode(#"{"homePeriod": "inconnue", "usagePeriod": "days30", "lastSection": "usage"}"#)
        #expect(mixed.homePeriod == .days7)
        #expect(mixed.usagePeriod == .days30)
        #expect(mixed.lastSection == .usage)
    }

    /// Aller-retour : les choix enregistrés reviennent tels quels, les deux périodes restent indépendantes.
    @Test func choicesSurviveARelaunch() throws {
        let suite = "wispad-display-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var settings = AppSettings.load(from: defaults)
        settings.homePeriod = .days30
        settings.usagePeriod = .all
        settings.usageTaxRate = 25.5
        settings.lastSection = .dictionary
        settings.showsOptionalKeys = true
        settings.save(to: defaults)

        let reloaded = AppSettings.load(from: defaults)
        #expect(reloaded.homePeriod == .days30)
        #expect(reloaded.usagePeriod == .all)
        #expect(reloaded.usageTaxRate == 25.5)
        #expect(reloaded.lastSection == .dictionary)
        #expect(reloaded.showsOptionalKeys)
        #expect(reloaded == settings)
    }

    /// La fenêtre rouvre sur la section mémorisée ; changer de section ou de période met le choix à jour.
    @MainActor
    @Test func modelRestoresAndRecordsChoices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var dependencies = AppDependencies()
        dependencies.loadKey = { _ in nil }
        var settings = AppSettings()
        settings.onboardingCompleted = true
        settings.lastSection = .usage
        let model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        defer { model.coordinator.cancel() }
        #expect(model.selectedSection == .usage)

        model.selectedSection = .history
        #expect(model.settings.lastSection == .history)
        model.setDisplayChoice(\.homePeriod, .days30)
        #expect(model.settings.homePeriod == .days30)
        #expect(model.settings.usagePeriod == .today)
    }
}
