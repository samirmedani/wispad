import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Cartes du Profil : réglage par défaut et lecture tolérante, place à l'écran, et calcul gardé par `ProfileLoader`
/// (une carte masquée n'est pas calculée). Préférences et dossiers temporaires, jamais les vrais.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ProfileCardsTests {
    private func fixture() throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-profile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.loadKey = { _ in nil }
        let model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
        model.overlay.displaysPanel = false
        return (model, directory)
    }

    private func record(_ index: Int) -> DictationRecord {
        let final = index % 2 == 0 ? "Je pousse le build sur GitHub, demande à Claude." : "Train pour Lyon et hôtel réservé."
        return DictationRecord(id: "fiction-\(index)", createdAt: Date().addingTimeInterval(-Double(index) * 3_600), finalText: final,
                               rawText: "euh " + final.lowercased(), durationSeconds: 5, wordCount: 8, provider: "fixture",
                               model: "fixture", targetApp: "Notes", insertionStatus: "inserted")
    }

    /// Nouvelle installation comme installation existante (bloc sans la clé) : cerveau et sujets coupés, toutes les
    /// autres cartes affichées.
    @Test func brainIsOffByDefaultEvenForAnExistingInstall() throws {
        let existing = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"provider": "openai"}"#.utf8))
        for settings in [AppSettings(), existing] {
            #expect(!settings.profileCards.brain)
            #expect(!settings.profileTopicsEnabled)
            #expect(settings.profileCards.shown == [.rhythm, .days, .words, .tics, .fixes, .languages, .apps])
            #expect(settings.profileCards.parts == .all)
        }
    }

    /// Lu champ par champ : une valeur illisible garde le défaut de sa seule carte ; une carte inconnue (version plus
    /// récente) reste dans le bloc enregistré quand une autre change.
    @Test func cardsAreReadFieldByFieldAndKeepUnknownOnes() throws {
        let suite = "wispad-profile-cards-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"profileCards": {"brain": true, "tics": "oui", "carteFuture": false}, "provider": "openai"}"#.utf8),
                     forKey: AppSettings.defaultsKey)
        var settings = AppSettings.load(from: defaults)
        #expect(settings.profileCards.brain && settings.profileCards.tics && settings.provider == .openAI)
        settings.profileCards.words = false
        settings.save(to: defaults)
        let data = try #require(defaults.data(forKey: AppSettings.defaultsKey))
        let stored = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cards = try #require(stored["profileCards"] as? [String: Any])
        #expect(cards["carteFuture"] as? Bool == false)
        #expect(cards["words"] as? Bool == false && cards["brain"] as? Bool == true)
        #expect(AppSettings.load(from: defaults).profileCards == settings.profileCards)
    }

    /// Les cartes étroites vont par deux, dans l'ordre de l'écran ; une carte large est seule ; une carte restée sans
    /// voisine prend la ligne.
    @Test func narrowCardsGoInPairs() {
        var cards = ProfileCards()
        #expect(ProfileCard.rows(cards.shown) == [[.rhythm, .days], [.words], [.tics, .fixes], [.languages, .apps]])
        cards.brain = true
        cards.days = false
        #expect(ProfileCard.rows(cards.shown) == [[.rhythm], [.brain], [.words], [.tics, .fixes], [.languages, .apps]])
        cards.fixes = false
        #expect(ProfileCard.rows(cards.shown) == [[.rhythm], [.brain], [.words], [.tics, .languages], [.apps]])
    }

    /// Le Profil calculé est gardé : masquer une carte ne refait aucun calcul ; une nouvelle dictée le refait en
    /// arrière-plan, l'écran gardant l'ancien jusque-là ; une carte masquée n'est pas calculée, et le cerveau seulement
    /// quand il est affiché.
    @Test func loaderKeepsItsSnapshotAndComputesOnlyShownCards() async throws {
        let (model, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.history = (0..<6).map(record)
        let loader = ProfileLoader()
        loader.load(ProfileRequest(model: model), model: model)
        await loader.task?.value
        let first = try #require(loader.snapshot)
        #expect(first.profile.dictations == 6)
        #expect(first.graph == nil && !first.has(.brain))
        #expect(first.has(.tics) && !first.profile.tics.isEmpty)

        model.settings.profileCards.tics = false
        loader.load(ProfileRequest(model: model), model: model)
        #expect(loader.task == nil)

        model.history.insert(record(6), at: 0)
        loader.load(ProfileRequest(model: model), model: model)
        #expect(loader.snapshot?.profile.dictations == 6)
        await loader.task?.value
        let second = try #require(loader.snapshot)
        #expect(second.profile.dictations == 7)
        #expect(!second.has(.tics) && second.profile.tics.isEmpty)

        model.settings.profileCards.brain = true
        loader.load(ProfileRequest(model: model), model: model)
        await loader.task?.value
        #expect(loader.snapshot?.has(.brain) == true && loader.snapshot?.graph?.nodes.isEmpty == false)
    }

    /// Période changée puis remise avant la fin du calcul : le calcul devenu inutile ne remplace pas l'écran.
    @Test func aStaleComputationNeverReplacesTheShownPeriod() async throws {
        let (model, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.history = (0..<6).map(record)
        let loader = ProfileLoader()
        loader.load(ProfileRequest(model: model), model: model)
        await loader.task?.value
        model.settings.profilePeriod = .today
        loader.load(ProfileRequest(model: model), model: model)
        let stale = loader.task
        model.settings.profilePeriod = .all
        loader.load(ProfileRequest(model: model), model: model)
        #expect(loader.task == nil)
        await stale?.value
        #expect(loader.snapshot?.request.period == .all)
    }
}
