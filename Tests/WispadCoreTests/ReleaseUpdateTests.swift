import Foundation
import Testing
@testable import WispadCore

struct SemanticVersionTests {
    private func version(_ text: String) -> SemanticVersion {
        SemanticVersion(text) ?? SemanticVersion(major: -1, minor: -1, patch: -1)
    }

    @Test func readsReleaseTagsAndAppVersions() {
        #expect(SemanticVersion("v0.1.2") == SemanticVersion(major: 0, minor: 1, patch: 2))
        #expect(SemanticVersion("0.1.2") == SemanticVersion(major: 0, minor: 1, patch: 2))
        #expect(SemanticVersion("V10.20.30") == SemanticVersion(major: 10, minor: 20, patch: 30))
        #expect(SemanticVersion(" v2.0.0\n") == SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion("1.2.3-beta.1") == SemanticVersion(major: 1, minor: 2, patch: 3, prerelease: ["beta", "1"]))
        // Les métadonnées de build ne comptent pas.
        #expect(SemanticVersion("1.2.3+build.5") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("1.2.3-rc.1+sha.abc") == SemanticVersion(major: 1, minor: 2, patch: 3, prerelease: ["rc", "1"]))
        #expect(SemanticVersion("v0.1.2")?.description == "0.1.2")
        #expect(SemanticVersion("v1.2.3-beta.1")?.description == "1.2.3-beta.1")
    }

    @Test func malformedTagsAreRejected() {
        for tag in ["", "v", "latest", "nightly-2026-10-12", "1.2", "v1.2", "1.2.3.4", "v01.2.3", "1.02.3", "1.2.03",
                    "1.2.x", "vv1.2.3", "v 1.2.3", "1.2.3-", "1.2.3+", "1.2.3-beta..1", "1.2.3-01", "-1.2.3", "1.-2.3",
                    "１.２.３", "1.2.3 beta", "1.2.3-bêta", "99999999999999999999.0.0"] {
            #expect(SemanticVersion(tag) == nil, "« \(tag) » devrait être refusé")
        }
    }

    @Test func comparesNumbersThenPrereleases() {
        #expect(version("0.1.2") > version("0.1.1"))
        #expect(version("0.2.0") > version("0.1.9"))
        #expect(version("0.10.0") > version("0.9.0"))
        #expect(version("1.0.0") > version("0.99.99"))
        #expect(version("v1.2.3") == version("1.2.3+build"))
        #expect(!(version("1.2.3") < version("1.2.3")))
        // Ordre de semver.org : une pré-version passe avant la version finale.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"].map { version($0) }
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(lower < higher, "\(lower) < \(higher)")
        }
        #expect(ordered.reversed().sorted() == ordered)
    }
}

struct ReleaseCheckTests {
    /// Réponse de `releases/latest` (celle de la v0.1.1 de Wispad, raccourcie), pour une version 0.1.2.
    static let latest = #"""
    {"tag_name":"v0.1.2","name":"Wispad 0.1.2","draft":false,"prerelease":false,
     "html_url":"https://github.com/samirmedani/wispad/releases/tag/v0.1.2",
     "body":"Wispad corrige mieux ce que tu dictes.\r\n\r\n**Nouveau**\r\n- Mises à jour en un clic.\r\n",
     "assets":[{"name":"Wispad.dmg","state":"uploaded","content_type":"application/x-apple-diskimage","size":6461561,
                "digest":"sha256:80070167916c206f6c7676eb75e35405ea805ca29f485658fc5c498f38abed29",
                "browser_download_url":"https://github.com/samirmedani/wispad/releases/download/v0.1.2/Wispad.dmg"}]}
    """#

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func result(_ json: String, status: Int = 200, retryAfter: String? = nil, reset: String? = nil) -> ReleaseCheckResult {
        ReleaseCheck.result(statusCode: status, data: Data(json.utf8), retryAfter: retryAfter, rateLimitReset: reset, now: now)
    }

    private func readRelease(_ json: String) -> ReleaseInfo? {
        guard case .release(let release) = result(json) else { return nil }
        return release
    }

    @Test func readsTheLatestRelease() throws {
        let release = try #require(readRelease(Self.latest))
        #expect(release.version == SemanticVersion(major: 0, minor: 1, patch: 2))
        #expect(release.tag == "v0.1.2")
        #expect(release.id == "v0.1.2")
        #expect(release.pageURL.absoluteString == "https://github.com/samirmedani/wispad/releases/tag/v0.1.2")
        #expect(release.notes.hasPrefix("Wispad corrige mieux ce que tu dictes."))
        let disk = try #require(release.diskImage)
        #expect(disk.url.absoluteString == "https://github.com/samirmedani/wispad/releases/download/v0.1.2/Wispad.dmg")
        #expect(disk.size == 6_461_561)
        #expect(disk.sha256 == "80070167916c206f6c7676eb75e35405ea805ca29f485658fc5c498f38abed29")
        // Vérification suivante dans 6 heures.
        #expect(ReleaseCheck.delay(after: .release(release)) == 6 * 3600)
        #expect(ReleaseCheck.latestURL.absoluteString == "https://api.github.com/repos/samirmedani/wispad/releases/latest")
    }

    /// Limite de l'API publique (60 demandes par heure sans clé) : rien ne s'affiche, nouvel essai plus tard.
    @Test func rateLimitIsSilentAndRetriesLater() {
        let limited = result(#"{"message":"API rate limit exceeded for 203.0.113.7."}"#, status: 403, reset: "1001800")
        #expect(limited == .rateLimited(retryAfter: 1_800))
        #expect(ReleaseCheck.delay(after: limited) == 1_800)
        #expect(result("", status: 429, retryAfter: "120") == .rateLimited(retryAfter: 120))
        // Jamais moins de 5 minutes ni plus de 6 heures ; sans délai annoncé, une heure.
        #expect(ReleaseCheck.delay(after: .rateLimited(retryAfter: 120)) == 5 * 60)
        #expect(ReleaseCheck.delay(after: .rateLimited(retryAfter: 86_400)) == 6 * 3600)
        #expect(result("{}", status: 403) == .rateLimited(retryAfter: nil))
        #expect(ReleaseCheck.delay(after: .rateLimited(retryAfter: nil)) == 3600)
        // Remise à zéro déjà passée, ou en-tête illisible : aucun délai annoncé.
        #expect(result("{}", status: 403, reset: "999000") == .rateLimited(retryAfter: nil))
        #expect(result("{}", status: 429, retryAfter: "demain") == .rateLimited(retryAfter: nil))
        #expect(result("{}", status: 429, retryAfter: "nan") == .rateLimited(retryAfter: nil))
    }

    /// Hors ligne (aucune réponse), délai dépassé ou GitHub en panne : silencieux, nouvel essai dans 30 minutes.
    @Test func offlineOrServerErrorRetriesSooner() {
        #expect(result("", status: 0) == .unreachable)
        #expect(result("", status: 408) == .unreachable)
        #expect(result("<html>Unicorn!</html>", status: 503) == .unreachable)
        #expect(ReleaseCheck.delay(after: .unreachable) == 30 * 60)
    }

    @Test func malformedTagOrUnpublishedReleaseIsIgnored() {
        for tag in ["latest", "v1.2", "nightly", "v1.2.3.4", "", "v0.1.2-"] {
            let json = Self.latest.replacingOccurrences(of: #""tag_name":"v0.1.2""#, with: #""tag_name":"\#(tag)""#)
            #expect(result(json) == .unusable, "« \(tag) »")
        }
        #expect(result(Self.latest.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)) == .unusable)
        #expect(result(Self.latest.replacingOccurrences(of: #""prerelease":false"#, with: #""prerelease":true"#)) == .unusable)
        // Aucune release publiée, réponse illisible.
        #expect(result(#"{"message":"Not Found"}"#, status: 404) == .unusable)
        #expect(result("<html>erreur</html>") == .unusable)
        #expect(result("[]") == .unusable)
        #expect(result(#"{"tag_name":12}"#) == .unusable)
        #expect(ReleaseCheck.delay(after: .unusable) == 6 * 3600)
    }

    /// Le disque ne vient que des releases du dépôt, en HTTPS ; sans lui, seule la page de la release est proposée.
    @Test func diskImageMustComeFromTheRepositoryReleases() throws {
        let download = "https://github.com/samirmedani/wispad/releases/download/"
        let withoutDisk = try #require(readRelease(Self.latest.replacingOccurrences(of: #""name":"Wispad.dmg""#, with: #""name":"Wispad.zip""#)))
        #expect(withoutDisk.diskImage == nil)
        for other in ["https://example.com/samirmedani/wispad/releases/download/", "http://github.com/samirmedani/wispad/releases/download/",
                      "https://github.com/autre/depot/releases/download/"] {
            let moved = try #require(readRelease(Self.latest.replacingOccurrences(of: download, with: other)))
            #expect(moved.diskImage == nil, "\(other)")
        }
        #expect(readRelease(Self.latest.replacingOccurrences(of: #""state":"uploaded""#, with: #""state":"open""#))?.diskImage == nil)
        #expect(readRelease(Self.latest.replacingOccurrences(of: #""size":6461561"#, with: #""size":0"#))?.diskImage == nil)
        // Empreinte dans un autre format : le disque reste, sans empreinte à comparer.
        let md5 = try #require(readRelease(Self.latest.replacingOccurrences(of: "sha256:8007", with: "md5:8007"))?.diskImage)
        #expect(md5.sha256 == nil)
        // Un élément illisible dans la liste n'empêche pas de trouver le disque.
        let noisy = Self.latest.replacingOccurrences(of: #""assets":["#, with: #""assets":[{"name":42},null,"#)
        #expect(readRelease(noisy)?.diskImage?.size == 6_461_561)
    }

    @Test func foreignPageIsRebuiltFromTheTag() throws {
        let json = Self.latest.replacingOccurrences(of: "https://github.com/samirmedani/wispad/releases/tag/v0.1.2",
                                                    with: "https://example.com/wispad")
        let release = try #require(readRelease(json))
        #expect(release.pageURL.absoluteString == "https://github.com/samirmedani/wispad/releases/tag/v0.1.2")
    }

    @Test func digestIsSHA256Only() {
        let hex = String(repeating: "ab", count: 32)
        #expect(ReleaseCheck.sha256(fromDigest: "sha256:" + hex.uppercased()) == hex)
        #expect(ReleaseCheck.sha256(fromDigest: "sha256:abc") == nil)
        #expect(ReleaseCheck.sha256(fromDigest: "sha512:" + hex) == nil)
        #expect(ReleaseCheck.sha256(fromDigest: "sha256:" + String(repeating: "zz", count: 32)) == nil)
        #expect(ReleaseCheck.sha256(fromDigest: nil) == nil)
    }
}

struct UpdateDisplayTests {
    private let newer = ReleaseInfo(version: SemanticVersion(major: 0, minor: 1, patch: 2), tag: "v0.1.2", notes: "",
                                    pageURL: ReleaseCheck.releasesURL, diskImage: nil)

    @Test func releaseComparesItsVersionToTheLatestRelease() {
        #expect(UpdateDisplay.make(kind: .release, installed: "0.1.1", latest: newer, freshness: .behind(4)) == .available(newer))
        #expect(UpdateDisplay.make(kind: .release, installed: "0.1.2", latest: newer, freshness: .unknown) == .upToDate)
        // Plus récente que la dernière publiée (release retirée, build du mainteneur) : rien à proposer.
        #expect(UpdateDisplay.make(kind: .release, installed: "0.2.0", latest: newer, freshness: .unknown) == .upToDate)
        // GitHub pas encore lu (ou injoignable), version illisible : seule la version s'affiche.
        #expect(UpdateDisplay.make(kind: .release, installed: "0.1.1", latest: nil, freshness: .upToDate) == .unknown)
        #expect(UpdateDisplay.make(kind: .release, installed: "—", latest: newer, freshness: .unknown) == .unknown)
    }

    /// Build local : la release publique plus récente prime, sinon le diagnostic de main reste affiché.
    @Test func developmentBuildOffersNewerReleasesThenKeepsTheCommitsBehindMain() {
        #expect(UpdateDisplay.make(kind: .development, installed: "0.1.1", latest: newer, freshness: .behind(3)) == .available(newer))
        #expect(UpdateDisplay.make(kind: .development, installed: "0.1.2", latest: newer, freshness: .behind(3)) == .development(.behind(3)))
        #expect(UpdateDisplay.make(kind: .development, installed: "—", latest: newer, freshness: .unknown) == .development(.unknown))
        #expect(UpdateDisplay.make(kind: .development, installed: "0.1.1", latest: nil, freshness: .upToDate) == .development(.upToDate))
        #expect(UpdateDisplay.make(kind: .development, installed: "0.1.1", latest: nil, freshness: .unknown) == .development(.unknown))
    }

    /// Seul scripts/release.sh ajoute la clé : un build depuis les sources reste un build de développement.
    @Test func onlyTheReleaseKeyMakesARelease() {
        #expect(BuildKind.infoKey == "WispadRelease")
        #expect(BuildKind(info: ["WispadRelease": true]) == .release)
        #expect(BuildKind(info: ["WispadRelease": "YES"]) == .release)
        #expect(BuildKind(info: ["WispadRelease": false]) == .development)
        #expect(BuildKind(info: ["WispadRelease": "non"]) == .development)
        #expect(BuildKind(info: ["CFBundleShortVersionString": "0.1.1", "WispadBuildCommit": "0123abc"]) == .development)
        #expect(BuildKind(info: nil) == .development)
    }

    @Test func reminderComesOncePerVersion() {
        let version = SemanticVersion(major: 0, minor: 1, patch: 2)
        #expect(UpdateReminder.shouldRemind(version, lastReminded: ""))
        #expect(!UpdateReminder.shouldRemind(version, lastReminded: "0.1.2"))
        #expect(UpdateReminder.shouldRemind(SemanticVersion(major: 0, minor: 1, patch: 3), lastReminded: "0.1.2"))
        // Une version plus ancienne (release retirée entre-temps) n'est pas rappelée de nouveau.
        #expect(!UpdateReminder.shouldRemind(version, lastReminded: "0.1.3"))
        #expect(UpdateReminder.shouldRemind(version, lastReminded: "illisible"))
    }
}

struct ReleaseNotesTests {
    @Test func publishedNotesBecomeBlocks() {
        let notes = "Wispad corrige mieux ce que tu dictes.\r\n\r\n**Nouveau**\r\n- Un mot mal entendu est remplacé.\r\n"
            + "- Les tics disparaissent.\r\n\r\n**Installer** : télécharge `Wispad.dmg`.\r\n"
        #expect(ReleaseNotes.blocks(notes) == [
            .paragraph("Wispad corrige mieux ce que tu dictes."),
            .paragraph("**Nouveau**"),
            .bullet("Un mot mal entendu est remplacé."),
            .bullet("Les tics disparaissent."),
            .paragraph("**Installer** : télécharge `Wispad.dmg`."),
        ])
    }

    @Test func headingsListsCodeQuotesAndRules() {
        let notes = """
        ## Nouveautés
        * Mises à jour en un clic
        + Notes de version
        1. Télécharge
        2) Installe
        ---
        ```
        scripts/release.sh
          (indenté)
        ```
        > Citation
        #PasUnTitre
        Ligne un
        ligne deux
        """
        #expect(ReleaseNotes.blocks(notes) == [
            .heading(level: 2, text: "Nouveautés"),
            .bullet("Mises à jour en un clic"),
            .bullet("Notes de version"),
            .numbered("1", "Télécharge"),
            .numbered("2", "Installe"),
            .code("scripts/release.sh\n  (indenté)"),
            .paragraph("Citation\n#PasUnTitre\nLigne un\nligne deux"),
        ])
    }

    @Test func emptyNotesUnclosedCodeAndTheBlockLimit() {
        #expect(ReleaseNotes.blocks("").isEmpty)
        #expect(ReleaseNotes.blocks("\n\n---\n").isEmpty)
        #expect(ReleaseNotes.blocks("```\nlet x = 1") == [.code("let x = 1")])
        let many = (1...500).map { "- point \($0)" }.joined(separator: "\n")
        #expect(ReleaseNotes.blocks(many).count == ReleaseNotes.maximumBlocks)
    }
}

/// Notes prêtes à montrer dans l'app : accroche, rubriques, points « titre : détail », sans ce qui ne sert que sur
/// GitHub (conseil pour une ancienne version, empreinte du disque).
struct ReleaseDigestTests {
    @Test func publishedNotesBecomeAHeadlineAndSections() {
        let notes = """
        La bulle de dictée se règle à ta taille.

        > Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
        > La 0.3.2 est déjà installée.

        **Nouveau**
        - Réglages › Bulle › Taille de la bulle : de 80 % à 160 %. Le spectre grandit avec elle.
        - Une nouvelle installation commence toujours avec la bulle en Noir profond.

        **Corrigé**
        - **Ombre** : elle tient entière.

        SHA-256 de `Wispad.dmg` : `b385dd0e122fda6dfa039e4dfb1c823574e8ddbe6b7220cce9bdcb477859ac16`
        """
        #expect(ReleaseNotes.digest(notes) == ReleaseDigest(headline: "La bulle de dictée se règle à ta taille.", sections: [
            ReleaseDigest.Section(kind: .new, items: [
                ReleaseDigest.Item(title: "Réglages › Bulle › Taille de la bulle", text: "De 80 % à 160 %. Le spectre grandit avec elle."),
                ReleaseDigest.Item(text: "Une nouvelle installation commence toujours avec la bulle en Noir profond."),
            ]),
            ReleaseDigest.Section(kind: .fixed, items: [ReleaseDigest.Item(title: "Ombre", text: "Elle tient entière.")]),
        ]))
    }

    @Test func otherShapesStayReadable() {
        let notes = "## Améliorations\n- Plus rapide. Encore : oui\nUne phrase libre.\n\n**Installer**\n1. Télécharge"
        #expect(ReleaseNotes.digest(notes) == ReleaseDigest(sections: [
            ReleaseDigest.Section(kind: .improved, items: [
                ReleaseDigest.Item(text: "Plus rapide. Encore : oui"),
                ReleaseDigest.Item(text: "Une phrase libre."),
            ]),
            ReleaseDigest.Section(kind: .other("Installer"), items: [ReleaseDigest.Item(text: "Télécharge")]),
        ]))
        #expect(ReleaseNotes.digest("").isEmpty)
        #expect(ReleaseNotes.digest("> seulement une citation\nSHA-256 : abc").isEmpty)
    }

    /// Versions sautées : celles d'après la version installée jusqu'à la plus récente, la plus récente en premier.
    @Test func missedVersionsAreTheOnesAfterTheInstalledOne() {
        func release(_ text: String) -> ReleaseInfo {
            ReleaseInfo(version: SemanticVersion(text)!, tag: "v" + text, notes: "", pageURL: ReleaseCheck.releasesURL, diskImage: nil)
        }
        let latest = release("0.3.2")
        let list = [release("0.2.15"), release("0.3.1"), latest, release("0.3.0"), release("0.3.1")]
        #expect(ReleaseCheck.missed(list, after: SemanticVersion("0.3.0"), upTo: latest).map(\.tag) == ["v0.3.2", "v0.3.1"])
        #expect(ReleaseCheck.missed([], after: SemanticVersion("0.3.0"), upTo: latest).map(\.tag) == ["v0.3.2"])
        #expect(ReleaseCheck.missed(list, after: nil, upTo: latest).map(\.tag) == ["v0.3.2"])
        let many = (1...20).map { release("0.2.\($0)") }
        #expect(ReleaseCheck.missed(many, after: SemanticVersion("0.1.0"), upTo: latest).count == 21)
        let lots = (1...40).map { release("0.2.\($0)") }
        #expect(ReleaseCheck.missed(lots, after: SemanticVersion("0.1.0"), upTo: latest).count == ReleaseCheck.maximumMissed)
    }

    @Test func theReleaseListIsReadWithDates() throws {
        let json = """
        [{"tag_name": "v0.3.2", "body": "B", "html_url": "https://github.com/samirmedani/wispad/releases/tag/v0.3.2",
          "published_at": "2026-10-23T12:40:24Z", "assets": []},
         {"tag_name": "pas-une-version"}, {"tag_name": "v0.3.1", "draft": true}, 42]
        """
        let releases = ReleaseCheck.releases(from: Data(json.utf8))
        #expect(releases.map(\.tag) == ["v0.3.2"])
        #expect(releases.first?.publishedAt == ISO8601DateFormatter().date(from: "2026-10-23T12:40:24Z"))
    }
}

struct UpdateInstallRulesTests {
    private let release = ReleaseInfo(
        version: SemanticVersion(major: 0, minor: 1, patch: 2), tag: "v0.1.2", notes: "", pageURL: ReleaseCheck.releasesURL,
        diskImage: DiskImageAsset(url: ReleaseCheck.releasesURL.appendingPathComponent("download/v0.1.2/Wispad.dmg"))
    )

    private func obstacle(kind: BuildKind = .release, disk: Bool = true, path: String = "/Applications/Wispad.app",
                          team: String? = "ABCDE12345", folder: Bool = true, app: Bool = true) -> UpdateInstallObstacle? {
        var candidate = release
        if !disk { candidate.diskImage = nil }
        return UpdateInstallRules.obstacle(kind: kind, release: candidate, appPath: path, teamID: team,
                                           folderWritable: folder, appWritable: app)
    }

    @Test func installsInPlaceOnlyWhenEverythingAllowsIt() {
        #expect(obstacle() == nil)
        #expect(obstacle(path: "/Volumes/Externe/Applications/Wispad.app") == nil)
        #expect(obstacle(kind: .development) == .developmentBuild)
        #expect(obstacle(disk: false) == .noDiskImage)
        #expect(obstacle(team: nil) == .unsigned)
        #expect(obstacle(team: "-") == .unsigned)
        // Dossier non modifiable, app lancée depuis le disque ou déplacée par macOS : la page de la release.
        #expect(obstacle(folder: false) == .readOnlyLocation)
        #expect(obstacle(app: false) == .readOnlyLocation)
        #expect(obstacle(path: "/private/var/folders/xy/T/AppTranslocation/1234/d/Wispad.app") == .readOnlyLocation)
        #expect(obstacle(path: "/Applications/Wispad") == .readOnlyLocation)
    }

    @Test func requirementDemandsDeveloperIDFromTheSameTeam() throws {
        let requirement = try #require(UpdateInstallRules.requirement(bundleID: "com.yatofix.wispad", teamID: "ABCDE12345"))
        #expect(requirement.hasPrefix(#"identifier "com.yatofix.wispad" and anchor apple generic"#))
        // Certificat intermédiaire Developer ID, certificat d'application Developer ID, même équipe.
        #expect(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
        #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        #expect(requirement.hasSuffix(#"certificate leaf[subject.OU] = "ABCDE12345""#))
        // Rien d'autre ne peut s'insérer dans l'exigence.
        #expect(UpdateInstallRules.requirement(bundleID: "com.yatofix.wispad", teamID: #"ABCDE1234" or anchor apple"#) == nil)
        #expect(UpdateInstallRules.requirement(bundleID: #"x" or anchor apple"#, teamID: "ABCDE12345") == nil)
        #expect(UpdateInstallRules.requirement(bundleID: "com.yatofix.wispad", teamID: "abcde12345") == nil)
        #expect(UpdateInstallRules.isTeamID("ABCDE12345"))
        #expect(!UpdateInstallRules.isTeamID("ABCDE1234"))
    }

    @Test func newVersionWaitsHiddenNextToTheApp() {
        let app = URL(fileURLWithPath: "/Applications/Wispad.app")
        #expect(UpdateInstallRules.stagingURL(for: app).path == "/Applications/.Wispad.nouveau.app")
        #expect(UpdateInstallRules.backupURL(for: app).path == "/Applications/.Wispad.ancien.app")
    }

    @Test func neverInstallsAnOlderOrUnreadableVersion() {
        #expect(UpdateInstallRules.isNewer("0.1.2", than: "0.1.1"))
        #expect(!UpdateInstallRules.isNewer("0.1.1", than: "0.1.1"))
        #expect(!UpdateInstallRules.isNewer("0.1.0", than: "0.1.1"))
        #expect(!UpdateInstallRules.isNewer(nil, than: "0.1.1"))
        #expect(!UpdateInstallRules.isNewer("0.1.2", than: "—"))
    }

    @Test func readsTheMountPointFromHdiutil() {
        let output = """
        Vérification de la somme de contrôle…
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>content-hint</key><string>GUID_partition_scheme</string>
                    <key>dev-entry</key><string>/dev/disk9</string>
                </dict>
                <dict>
                    <key>content-hint</key><string>Apple_HFS</string>
                    <key>dev-entry</key><string>/dev/disk9s1</string>
                    <key>mount-point</key><string>/private/var/folders/xy/T/WispadUpdate-1/dmg.AbCdEf</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        #expect(UpdateInstallRules.mountPoints(fromPlist: Data(output.utf8)) == ["/private/var/folders/xy/T/WispadUpdate-1/dmg.AbCdEf"])
        #expect(UpdateInstallRules.mountPoints(fromPlist: Data("hdiutil: attach failed".utf8)).isEmpty)
        #expect(UpdateInstallRules.mountPoints(fromPlist: Data()).isEmpty)
    }

    /// Sortie réelle de `diskutil image attach --plist` (repli de hdiutil, macOS 27) : appareils sans `/dev/`,
    /// conteneur APFS, un seul volume monté.
    @Test func readsTheMountPointFromDiskutilImageAttach() {
        let output = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>disk6</string></dict>
                <dict><key>content-hint</key><string>Apple_APFS</string><key>dev-entry</key><string>disk6s1</string></dict>
                <dict><key>content-hint</key><string>Apple_APFS_Container</string><key>dev-entry</key><string>disk7</string></dict>
                <dict>
                    <key>content-hint</key><string>Apple_APFS_Volume</string>
                    <key>dev-entry</key><string>disk7s1</string>
                    <key>filesystem-type</key><string>apfs</string>
                    <key>mount-point</key><string>/private/var/folders/xy/T/WispadUpdate-1/volume</string>
                    <key>volume-name</key><string>Wispad</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        #expect(UpdateInstallRules.mountPoints(fromPlist: Data(output.utf8)) == ["/private/var/folders/xy/T/WispadUpdate-1/volume"])
    }
}

struct ManualUpdateCheckTests {
    /// Une recherche à la main par minute ; limite de GitHub : l'heure annoncée, un quart d'heure sans indication, six
    /// heures au plus.
    @Test func waitsAMinuteOrTheTimeGitHubAnnounces() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var check = ManualUpdateCheck()
        #expect(check.remaining(at: now) == 0)
        check.record(.unreachable, at: now)
        #expect(check.remaining(at: now) == 60)
        #expect(check.remaining(at: now.addingTimeInterval(45)) == 15)
        #expect(check.remaining(at: now.addingTimeInterval(90)) == 0)
        check.record(.rateLimited(retryAfter: 600), at: now)
        #expect(check.remaining(at: now) == 600)
        check.record(.rateLimited(retryAfter: nil), at: now)
        #expect(check.remaining(at: now) == 15 * 60)
        check.record(.rateLimited(retryAfter: 86_400), at: now)
        #expect(check.remaining(at: now) == ReleaseCheck.interval)
        check.record(nil, at: now)
        #expect(check.remaining(at: now) == 60)
    }
}
