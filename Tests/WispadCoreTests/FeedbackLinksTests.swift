import Foundation
import Testing
@testable import WispadCore

/// Retours depuis l'app : ticket de bug prérempli avec les seules versions de Wispad et de macOS, encodées pour
/// l'adresse ; idées et questions dans les Discussions du dépôt public.
struct FeedbackLinksTests {
    private let macOS = OperatingSystemVersion(majorVersion: 15, minorVersion: 3, patchVersion: 1)

    @Test func bugReportPrefillsTheSidebarVersionAndMacOS() {
        let url = FeedbackLinks.bugReportURL(version: "0.1.0", commit: "0123ABCdef4567", system: macOS)
        #expect(url.absoluteString == "https://github.com/samirmedani/wispad/issues/new?template=bug.yml&version=0.1.0%20%C2%B7%200123abc&macos=macOS%2015.3.1")
    }

    /// « + » deviendrait une espace pour GitHub ; « & », « = » et « # » ajouteraient un champ ou couperaient l'adresse.
    @Test func valuesAreEncodedForTheURL() {
        let url = FeedbackLinks.bugReportURL(version: "1.0 beta+2&x=y#z", commit: "0123abc", system: macOS)
        #expect(url.absoluteString.contains("&version=1.0%20beta%2B2%26x%3Dy%23z%20%C2%B7%200123abc&macos=macOS%2015.3.1"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Rien d'autre que le formulaire et les deux versions ne part dans l'adresse.
        #expect(items.map(\.name) == ["template", "version", "macos"])
        let values: [String?] = ["bug.yml", "1.0 beta+2&x=y#z · 0123abc", "macOS 15.3.1"]
        #expect(items.map(\.value) == values)
    }

    @Test func missingCommitKeepsTheVersionAlone() {
        let url = FeedbackLinks.bugReportURL(version: "0.1.0", commit: nil, system: macOS)
        #expect(url.absoluteString == "https://github.com/samirmedani/wispad/issues/new?template=bug.yml&version=0.1.0&macos=macOS%2015.3.1")
        // Commit non gravé à la compilation (réglage non remplacé, texte quelconque) : comme absent.
        #expect(FeedbackLinks.bugReportURL(version: "0.1.0", commit: "$(WISPAD_BUILD_COMMIT)", system: macOS) == url)
        #expect(FeedbackLinks.bugReportURL(version: "0.1.0", commit: "", system: macOS) == url)
    }

    @Test func missingVersionKeepsTheCommitAlone() {
        let url = FeedbackLinks.bugReportURL(version: nil, commit: "0123abcdef", system: macOS)
        #expect(url.absoluteString == "https://github.com/samirmedani/wispad/issues/new?template=bug.yml&version=0123abc&macos=macOS%2015.3.1")
        #expect(FeedbackLinks.bugReportURL(version: " \n", commit: "0123abcdef", system: macOS) == url)
    }

    /// Ni version ni commit : le champ reste à remplir sur GitHub, la version de macOS part seule.
    @Test func withoutVersionNorCommitOnlyMacOSIsPrefilled() {
        let url = FeedbackLinks.bugReportURL(version: nil, commit: nil, system: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
        #expect(url.absoluteString == "https://github.com/samirmedani/wispad/issues/new?template=bug.yml&macos=macOS%2014.0.0")
    }

    @Test func macOSVersionAlwaysHasThreeNumbers() {
        #expect(FeedbackLinks.systemValue(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) == "macOS 26.0.0")
        #expect(FeedbackLinks.systemValue(macOS) == "macOS 15.3.1")
    }

    @Test func ideasAndQuestionsGoToTheDiscussions() {
        #expect(FeedbackLinks.ideasURL.absoluteString == "https://github.com/samirmedani/wispad/discussions/categories/ideas")
        #expect(FeedbackLinks.questionsURL.absoluteString == "https://github.com/samirmedani/wispad/discussions/categories/q-a")
    }
}
