import AppKit
import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Aide et retours : les mêmes liens dans Réglages, le menu de la barre et le menu Aide. Aucune page n'est ouverte ici.
@MainActor
struct HelpPagesTests {
    @Test func settingsOfferThreeLinksToGitHub() {
        #expect(SettingsPresentation.helpTitle == "Aide et retours")
        #expect(HelpPage.allCases.map(\.title) == ["Signaler un problème", "Proposer une idée", "Poser une question"])
        #expect(HelpPage.reportProblem.url.absoluteString.hasPrefix("https://github.com/samirmedani/wispad/issues/new?template=bug.yml&"))
        #expect(HelpPage.proposeIdea.url == FeedbackLinks.ideasURL)
        #expect(HelpPage.askQuestion.url == FeedbackLinks.questionsURL)
    }

    /// Menu Aide : signaler un problème et proposer une idée, chacun relié à une méthode du délégué de l'app.
    @Test func helpMenuOffersTheBugReportAndTheIdea() throws {
        let help = MainMenu.helpMenu()
        #expect(help.title == "Aide")
        #expect(help.items.map(\.title) == ["Signaler un problème", "Proposer une idée"])
        let delegate = AppDelegate()
        for item in help.items {
            let action = try #require(item.action)
            #expect(delegate.responds(to: action), "\(item.title)")
        }
    }
}
