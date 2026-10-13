import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
struct BuildStatusTests {
    /// Relevé des appels faits par les fermetures simulées.
    @MainActor final class Recorder {
        var available: [SemanticVersion] = []
        var requests = 0
    }

    private static func release(_ version: String) -> ReleaseInfo {
        ReleaseInfo(version: SemanticVersion(version) ?? SemanticVersion(major: 0, minor: 0, patch: 0), tag: "v" + version,
                    notes: "", pageURL: ReleaseCheck.releasesURL, diskImage: nil)
    }

    @Test func versionLineShowsVersionAndShortCommit() {
        let status = BuildStatus(info: ["CFBundleShortVersionString": "0.1.0", BuildStatus.commitInfoKey: "0123abcdef"])
        #expect(status.kind == .development)
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

    /// « Signaler un problème » reprend la version et le commit de la barre latérale, et la version de macOS.
    @Test func bugReportCarriesTheSidebarVersion() {
        let macOS = OperatingSystemVersion(majorVersion: 15, minorVersion: 3, patchVersion: 1)
        let status = BuildStatus(info: ["CFBundleShortVersionString": "0.1.0", BuildStatus.commitInfoKey: "0123abcdef"])
        #expect(status.bugReportURL(system: macOS).absoluteString
            == "https://github.com/samirmedani/wispad/issues/new?template=bug.yml&version=0.1.0%20%C2%B7%200123abc&macos=macOS%2015.3.1")
        // Version absente de l'Info.plist : « — » dans la barre latérale, le commit seul dans le ticket.
        let unversioned = BuildStatus(info: [BuildStatus.commitInfoKey: "0123abcdef"])
        #expect(unversioned.versionLine == "Wispad — · 0123abc")
        #expect(unversioned.bugReportURL(system: macOS).absoluteString
            == "https://github.com/samirmedani/wispad/issues/new?template=bug.yml&version=0123abc&macos=macOS%2015.3.1")
    }

    @Test func freshnessLabels() {
        #expect(BuildFreshness.upToDate.label == "À jour")
        #expect(BuildFreshness.behind(1).label == "1 commit de retard")
        #expect(BuildFreshness.behind(12).label == "12 commits de retard")
        #expect(BuildFreshness.unknown.label == nil)
    }

    /// Release installée depuis le .dmg : la version seule, comparée à la dernière release ; un échec de la vérification
    /// (hors ligne, limite de l'API, tag mal formé) ne change rien à l'écran.
    @Test func releaseComparesItsVersionToTheLatestRelease() {
        let status = BuildStatus(info: ["CFBundleShortVersionString": "0.1.1", BuildStatus.commitInfoKey: "0123abcdef",
                                        BuildKind.infoKey: true])
        #expect(status.kind == .release)
        #expect(status.versionLine == "Wispad 0.1.1")
        #expect(status.display == .unknown)
        let recorder = Recorder()
        status.onAvailable = { recorder.available.append($0.version) }
        let newer = Self.release("0.1.2")
        status.apply(.release(newer))
        #expect(status.display == .available(newer))
        #expect(status.available == newer)
        #expect(recorder.available == [newer.version])
        for failure in [ReleaseCheckResult.unreachable, .rateLimited(retryAfter: 60), .unusable] {
            status.apply(failure)
            #expect(status.display == .available(newer))
        }
        #expect(recorder.available == [newer.version])
        status.apply(.release(Self.release("0.1.1")))
        #expect(status.display == .upToDate)
        #expect(status.available == nil)
    }

    @Test func releaseChecksTheLatestReleaseInTheBackground() async throws {
        let status = BuildStatus(info: ["CFBundleShortVersionString": "0.1.1", BuildKind.infoKey: true])
        let newer = Self.release("0.1.2")
        status.fetchLatest = { .release(newer) }
        status.start(delay: .zero)
        let deadline = Date().addingTimeInterval(3)
        while status.available == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(status.available == newer)
    }

    /// L'aide et la mise à jour partagent les métadonnées : une version absente n'est jamais inventée.
    @Test func releaseWithoutVersionDoesNotOfferAnUpdate() {
        let status = BuildStatus(info: [BuildKind.infoKey: true, BuildStatus.commitInfoKey: "0123abcdef"])
        let recorder = Recorder()
        status.onAvailable = { recorder.available.append($0.version) }
        status.apply(.release(Self.release("0.1.2")))
        #expect(status.version == nil)
        #expect(status.versionLine == "Wispad —")
        #expect(status.display == .unknown)
        #expect(status.available == nil)
        #expect(recorder.available.isEmpty)
        let query = URLComponents(url: status.bugReportURL(), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "version" })?.value == "0123abc")
    }

    /// Build compilé depuis les sources : « N commits de retard », jamais de release demandée ni proposée.
    @Test func developmentBuildNeverAsksForReleases() async throws {
        let status = BuildStatus(info: ["CFBundleShortVersionString": "0.1.1"])
        let recorder = Recorder()
        let later = Self.release("9.9.9")
        status.fetchLatest = {
            await MainActor.run { recorder.requests += 1 }
            return .release(later)
        }
        status.start(delay: .zero)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.requests == 0)
        #expect(status.display == .development(.unknown))
        #expect(status.available == nil)
    }

    @Test func installProgressLabels() {
        #expect(UpdateInstaller.Phase.idle.sidebarText == nil)
        #expect(UpdateInstaller.Phase.downloading(nil).sidebarText == "Téléchargement…")
        let downloading = UpdateInstaller.Phase.downloading(0.42).sidebarText ?? ""
        #expect(downloading.hasPrefix("Téléchargement…") && downloading.contains("42"))
        #expect(UpdateInstaller.Phase.failed(.signature).sidebarText == "Échec de la mise à jour")
        #expect(UpdateInstaller.Phase.failed(.signature).detailText == UpdateFailure.signature.message)
        #expect(UpdateFailure.signature.message.contains("rien n'a été installé"))
        #expect(UpdateFailure.replace.message.contains("reste en place"))
    }

    /// Bandeau étoile : proposé tant qu'il n'a pas été cliqué, un merci juste après le clic, puis plus jamais.
    @Test func starBannerDisappearsForGoodAfterTheClick() {
        #expect(StarBanner.state(clicked: false, thanking: false) == .offer)
        #expect(StarBanner.state(clicked: true, thanking: true) == .thanks)
        #expect(StarBanner.state(clicked: true, thanking: false) == .hidden)
    }
}
