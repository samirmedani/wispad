import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
struct BuildStatusTests {
    @Test func versionLineShowsVersionAndShortCommit() {
        let status = BuildStatus(info: ["CFBundleShortVersionString": "0.1.0", BuildStatus.commitInfoKey: "0123abcdef"])
        #expect(status.versionLine == "Wispad 0.1.0 · 0123abc")
    }

    @Test func versionLineWithoutBuildCommitShowsOnlyTheVersion() {
        let status = BuildStatus(info: ["CFBundleShortVersionString": "0.1.0"])
        #expect(status.commit == nil)
        #expect(status.versionLine == "Wispad 0.1.0")
        // Sans commit, aucune requête : l'état reste inconnu.
        status.start(delay: .zero)
        #expect(status.freshness == .unknown)
    }

    @Test func freshnessLabels() {
        #expect(BuildFreshness.upToDate.label == "À jour")
        #expect(BuildFreshness.behind(1).label == "1 commit de retard")
        #expect(BuildFreshness.behind(12).label == "12 commits de retard")
        #expect(BuildFreshness.unknown.label == nil)
    }

    /// Bandeau étoile : proposé tant qu'il n'a pas été cliqué, un merci juste après le clic, puis plus jamais.
    @Test func starBannerDisappearsForGoodAfterTheClick() {
        #expect(StarBanner.state(clicked: false, thanking: false) == .offer)
        #expect(StarBanner.state(clicked: true, thanking: true) == .thanks)
        #expect(StarBanner.state(clicked: true, thanking: false) == .hidden)
    }
}
