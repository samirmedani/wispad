import Foundation
import Testing
@testable import WispadCore

/// Filet anti-régression des versions (`SemanticVersion`), de la vérification des releases (`ReleaseCheck`), des notes
/// de version (`ReleaseNotes`) et des règles d'installation (`UpdateInstallRules`).
struct SemanticVersionPropertyTests {
    /// Identifiants de pré-version valides : numériques sans zéro initial, alphanumériques, tirets.
    static func identifier(_ g: inout SeededGenerator) -> String {
        switch g.int(0...4) {
        case 0: return String(g.int(0...30))
        case 1: return String(g.int(100...99_999))
        case 2: return g.pick(["alpha", "beta", "rc", "a", "b", "z", "A", "Z", "x-y", "0a", "1-", "-", "--", "rc-1"])
        case 3: return String(g.int(0...9)) + g.pick(["a", "b", "-"])
        default: return g.pick(["alpha", "beta"]) + String(g.int(0...12))
        }
    }

    /// Version tirée d'un petit espace, pour que les égalités et les pré-versions voisines soient fréquentes.
    static func version(_ g: inout SeededGenerator, spread: Int = 3) -> SemanticVersion {
        let core = "\(g.int(0...spread)).\(g.int(0...spread)).\(g.int(0...spread))"
        let prerelease = g.chance(60) ? "-" + (0..<g.int(1...3)).map { _ in identifier(&g) }.joined(separator: ".") : ""
        // Toutes ces écritures sont valides : la lecture ne doit jamais échouer.
        return SemanticVersion(core + prerelease) ?? SemanticVersion(major: -1, minor: -1, patch: -1)
    }

    /// Précédence de semver.org (§ 11), écrite à part pour juger `SemanticVersion.<` : -1, 0 ou 1.
    static func reference(_ a: SemanticVersion, _ b: SemanticVersion) -> Int {
        for (x, y) in [(a.major, b.major), (a.minor, b.minor), (a.patch, b.patch)] where x != y { return x < y ? -1 : 1 }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (left?, right?): return left < right ? -1 : 1
            case (.some, nil): return -1
            case (nil, .some): return 1
            case (nil, nil): return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8)) ? -1 : 1
            }
        }
        return a.prerelease.count == b.prerelease.count ? 0 : (a.prerelease.count < b.prerelease.count ? -1 : 1)
    }

    @Test func validVersionsAlwaysParse() {
        forAll(2_000, seed: 0x5345_5631, { g in Self.version(&g) }) { version in
            version.major >= 0 ? nil : "version valide refusée"
        }
    }

    /// Écrire puis relire une version la redonne : « v » initial et métadonnées de build ne comptent pas.
    @Test func descriptionRoundTrips() {
        forAll(2_000, seed: 0x5345_5632, { g in (version: Self.version(&g), build: g.chance(50) ? "+build." + String(g.int(0...99)) : "") }) { sample in
            let text = sample.version.description
            guard SemanticVersion(text) == sample.version else { return "« \(text) » relu autrement" }
            guard SemanticVersion("v" + text + sample.build) == sample.version else { return "« v\(text)\(sample.build) » relu autrement" }
            return text.contains("+") || text.hasPrefix("v") ? "« \(text) »" : nil
        }
    }

    /// N'importe quelle chaîne : soit refusée, soit lue en une version qui se réécrit et se relit à l'identique.
    @Test func arbitraryTagsParseConsistently() {
        forAll(5_000, seed: 0x5345_5633, { g in
            g.chance(50) ? SampleText.unicode(&g, length: 0...14)
                : g.pick(["v", "V", "", " ", "vv"]) + "\(g.int(0...20)).\(g.int(0...20)).\(g.int(0...20))"
                    + g.pick(["", "-", "-beta", "-beta.1", "+b", "-rc.01", "-1.2", "+", "-x+y", ".4", "-é", " ", "\n"])
        }) { text in
            guard let version = SemanticVersion(text) else { return nil }
            return SemanticVersion(version.description) == version ? nil : "« \(text) » → « \(version.description) »"
        }
    }

    /// Ordre total et cohérent : une seule relation entre deux versions, transitivité, égalité et hachage d'accord,
    /// et l'ordre de semver.org.
    @Test func orderIsTotalAndFollowsSemver() {
        // Un espace serré : mêmes numéros et pré-versions voisines à chaque tirage ou presque.
        forAll(5_000, seed: 0x5345_5634, { g in (Self.version(&g, spread: 1), Self.version(&g, spread: 1), Self.version(&g, spread: 1)) }) { versions in
            let (a, b, c) = versions
            let relations = [a < b, a == b, b < a].filter { $0 }.count
            guard relations == 1 else { return "\(a) et \(b) : \(relations) relations" }
            let expected = Self.reference(a, b)
            guard (a < b ? -1 : a == b ? 0 : 1) == expected else { return "\(a) et \(b) : semver dit \(expected)" }
            if a < b, b < c, !(a < c) { return "\(a) < \(b) < \(c) sans \(a) < \(c)" }
            if a == b, a.hashValue != b.hashValue { return "\(a) == \(b) mais hachages différents" }
            return nil
        }
    }

    /// Trier une liste mélangée donne toujours le même ordre, celui de semver.org.
    @Test func sortingIsStableAcrossShuffles() {
        forAll(300, seed: 0x5345_5635, { g -> (versions: [SemanticVersion], shuffled: [SemanticVersion]) in
            let versions = (0..<g.int(2...30)).map { _ in Self.version(&g) }
            var shuffled = versions
            for index in shuffled.indices.reversed() { shuffled.swapAt(index, g.int(0...index)) }
            return (versions, shuffled)
        }) { sample in
            let sorted = sample.versions.sorted()
            guard sample.shuffled.sorted() == sorted else { return "\(sample.versions) trié de deux façons" }
            for (lower, higher) in zip(sorted, sorted.dropFirst()) where Self.reference(lower, higher) > 0 {
                return "\(lower) placé avant \(higher)"
            }
            return nil
        }
    }

    /// Installer, rappeler, proposer : trois décisions qui suivent toutes le même ordre des versions.
    @Test func updateDecisionsFollowTheOrder() {
        forAll(3_000, seed: 0x5345_5636, { g in (Self.version(&g), Self.version(&g), g.chance(10)) }) { sample in
            let (candidate, installed, unreadable) = sample
            let installedText = unreadable ? "—" : installed.description
            let newer = UpdateInstallRules.isNewer(candidate.description, than: installedText)
            if newer != (!unreadable && candidate > installed) { return "isNewer(\(candidate), \(installedText))" }
            if newer, UpdateInstallRules.isNewer(installedText, than: candidate.description) { return "chacune plus récente que l'autre" }
            if UpdateInstallRules.isNewer(candidate.description, than: candidate.description) { return "\(candidate) plus récente qu'elle-même" }
            let remind = UpdateReminder.shouldRemind(candidate, lastReminded: installedText)
            if remind != (unreadable || candidate > installed) { return "shouldRemind(\(candidate), \(installedText))" }
            let release = ReleaseInfo(version: candidate, tag: "v" + candidate.description, notes: "", pageURL: ReleaseCheck.releasesURL, diskImage: nil)
            let display = UpdateDisplay.make(kind: .release, installed: installedText, latest: release, freshness: .unknown)
            let expected: UpdateDisplay = unreadable ? .unknown : (candidate > installed ? .available(release) : .upToDate)
            if display != expected { return "affichage \(display) pour \(candidate) / \(installedText)" }
            if UpdateDisplay.make(kind: .development, installed: installedText, latest: release, freshness: .behind(2)) != .development(.behind(2)) {
                return "un build de développement propose une release"
            }
            return nil
        }
    }
}

struct ReleaseCheckPropertyTests {
    /// Toute réponse, même absurde, donne un résultat sans plantage ; le statut seul choisit sa famille.
    @Test func everyResponseIsClassified() {
        forAll(3_000, seed: 0x5243_4B31, { g -> (status: Int, data: Data, retry: String?, reset: String?) in
            let status = g.pick([0, 200, 200, 201, 204, 301, 304, 400, 401, 403, 404, 408, 418, 429, 500, 502, 503, 599, 600, -1, g.int(-1_000...1_000)])
            var bytes = [UInt8](repeating: 0, count: g.int(0...300))
            for index in bytes.indices { bytes[index] = UInt8(g.int(0...255)) }
            let json = #"{"tag_name":"\#(g.pick(["v0.1.2", "v1.0.0-beta", "latest", "", "v9.9.9"]))","draft":\#(g.chance(20)),"prerelease":\#(g.chance(20)),"assets":[{"name":"Wispad.dmg","browser_download_url":"https://github.com/samirmedani/wispad/releases/download/v0.1.2/Wispad.dmg","size":\#(g.int(-5...600_000_000))}]}"#
            let data = g.chance(50) ? Data(bytes) : Data(json.utf8)
            let header = { (g: inout SeededGenerator) -> String? in
                g.chance(30) ? nil : g.pick(["120", "-5", "nan", "inf", "1e308", " 60 ", "demain", "", "2000000", String(g.int(-100...10_000_000))])
            }
            return (status, data, header(&g), header(&g))
        }) { sample in
            let result = ReleaseCheck.result(statusCode: sample.status, data: sample.data, retryAfter: sample.retry,
                                             rateLimitReset: sample.reset, now: Date(timeIntervalSince1970: 1_000_000))
            switch (sample.status, result) {
            case (200, .release), (200, .unusable), (0, .unreachable), (408, .unreachable), (500...599, .unreachable):
                return nil
            case (403, .rateLimited(let wait)), (429, .rateLimited(let wait)):
                guard let wait else { return nil }
                return wait.isFinite && wait >= 0 ? nil : "attente \(wait)"
            case (let status, .unusable) where ![0, 200, 403, 408, 429].contains(status) && !(500...599).contains(status):
                return nil
            default:
                return "statut \(sample.status) → \(result)"
            }
        }
    }

    /// Jamais deux demandes à moins de 5 minutes, jamais plus de 6 heures sans demande, quoi qu'annonce GitHub.
    @Test func delayIsAlwaysBetweenFiveMinutesAndSixHours() {
        let results: [ReleaseCheckResult] = [.unusable, .unreachable, .rateLimited(retryAfter: nil)]
            + [-1e300, -1, 0, 1, 299, 300, 301, 3_600, 21_599, 21_600, 21_601, 1e300, .infinity, -.infinity, .nan, .greatestFiniteMagnitude]
                .map { ReleaseCheckResult.rateLimited(retryAfter: $0) }
        for result in results {
            let delay = ReleaseCheck.delay(after: result)
            #expect(delay >= ReleaseCheck.minimumDelay && delay <= ReleaseCheck.interval, "\(result) → \(delay)")
        }
        forAll(3_000, seed: 0x5243_4B32, { g in g.double(-1e7...1e7) }) { wait in
            let delay = ReleaseCheck.delay(after: .rateLimited(retryAfter: wait))
            return delay >= ReleaseCheck.minimumDelay && delay <= ReleaseCheck.interval ? nil : "\(wait) → \(delay)"
        }
    }

    /// Empreinte SHA-256 : 64 chiffres hexadécimaux, rendus en minuscules ; tout le reste est refusé.
    @Test func digestsAreSHA256OrNothing() {
        forAll(3_000, seed: 0x5243_4B33, { g -> String in
            let hex = String((0..<g.pick([63, 64, 64, 64, 65])).map { _ in g.pick(Array("0123456789abcdefABCDEF")) })
            switch g.int(0...4) {
            case 0: return g.pick(["sha256:", "SHA256:", "Sha256:"]) + hex
            case 1: return g.pick(["sha512:", "md5:", "sha256", "", " sha256:"]) + hex
            case 2: return "sha256:" + SampleText.unicode(&g, length: 60...68)
            default: return "sha256:" + hex
            }
        }) { digest in
            guard let value = ReleaseCheck.sha256(fromDigest: digest) else { return nil }
            guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return "« \(digest) » → « \(value) »" }
            return digest.lowercased().hasSuffix(value) && digest.lowercased().hasPrefix("sha256:") ? nil : "« \(digest) » → « \(value) »"
        }
    }
}

struct ReleaseNotesPropertyTests {
    /// Réécrit des blocs en markdown que `ReleaseNotes.blocks` relit à l'identique.
    static func markdown(_ blocks: [ReleaseNoteBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(let level, let text): return String(repeating: "#", count: level) + " " + text
            case .bullet(let text): return "+ " + text
            case .numbered(let number, let text): return number + ". " + text
            case .paragraph(let text): return text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .code(let code): return "```\n" + code + "\n```"
            }
        }.joined(separator: "\n\n")
    }

    /// Notes de version plausibles : titres, puces, listes, citations, séparations, code, mise en forme dans la ligne.
    static func notes(_ g: inout SeededGenerator) -> String {
        let starts = ["# ", "## ", "###### ", "####### ", "- ", "* ", "+ ", "1. ", "2) ", "123456789. ", "1234567890. ", "> ", ">",
                      "```", "```swift", "---", "***", "_ _ _", "", " ", "\t", "#PasUnTitre", "-pasunepuce", "1.pas"]
        let contents = ["**gras**", "`code`", "[lien](https://exemple.fr)", "texte", "Une phrase.", "*italique*", "Wispad 0.2.1",
                        "- tiret", "« citation »", "x", "", "  "]
        var lines: [String] = []
        for _ in 0..<g.int(0...40) {
            lines.append(g.pick(starts) + g.pick(contents) + (g.chance(30) ? " " + g.pick(contents) : ""))
            if g.chance(25) { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }

    /// Au plus 200 blocs ; un titre, une puce, un élément numéroté ou un paragraphe n'est jamais vide ni bordé de blancs.
    @Test func blocksAreBoundedAndTrimmed() {
        forAll(2_000, seed: 0x4E4F_5431, { g in g.chance(70) ? Self.notes(&g) : SampleText.unicode(&g, length: 0...200) }) { notes in
            let blocks = ReleaseNotes.blocks(notes)
            guard blocks.count <= ReleaseNotes.maximumBlocks else { return "\(blocks.count) blocs" }
            for block in blocks {
                switch block {
                case .heading(let level, let text):
                    if !(1...6).contains(level) { return "titre de niveau \(level)" }
                    if text.isEmpty || text != text.trimmingCharacters(in: .whitespaces) { return "titre « \(text) »" }
                case .bullet(let text), .numbered(_, let text), .paragraph(let text):
                    if text.isEmpty || text != text.trimmingCharacters(in: .whitespaces) { return "\(block)" }
                case .code:
                    break
                }
            }
            return nil
        }
        let many = (1...1_000).map { "- point \($0)" }.joined(separator: "\n\n")
        #expect(ReleaseNotes.blocks(many).count == ReleaseNotes.maximumBlocks)
    }

    /// Relire des notes réécrites en markdown redonne les mêmes blocs.
    @Test func blocksRoundTripThroughMarkdown() {
        forAll(2_000, seed: 0x4E4F_5432, { g in Self.notes(&g) }) { notes in
            let blocks = ReleaseNotes.blocks(notes)
            let again = ReleaseNotes.blocks(Self.markdown(blocks))
            return again == blocks ? nil : "« \(notes) » : \(blocks) ≠ \(again)"
        }
    }

    /// Fins de ligne Windows ou Mac classiques : mêmes blocs qu'avec des fins de ligne Unix.
    @Test func lineEndingsDoNotMatter() {
        forAll(2_000, seed: 0x4E4F_5433, { g in Self.notes(&g) }) { notes in
            let unix = ReleaseNotes.blocks(notes)
            guard ReleaseNotes.blocks(notes.replacingOccurrences(of: "\n", with: "\r\n")) == unix else { return "CRLF : « \(notes) »" }
            return ReleaseNotes.blocks(notes.replacingOccurrences(of: "\n", with: "\r")) == unix ? nil : "CR : « \(notes) »"
        }
    }
}

struct UpdateInstallRulesPropertyTests {
    /// L'exigence de signature ne s'écrit qu'avec un identifiant et une équipe sûrs : rien ne peut s'y insérer.
    @Test func requirementCannotBeInjected() {
        forAll(5_000, seed: 0x494E_5331, { g -> (bundle: String, team: String) in
            let bundle = g.chance(50) ? g.pick(["com.yatofix.wispad", "a", "a-b.c", "x\"y", "", "é.com", "a b", "a\nb", "a\")or(\""])
                : SampleText.unicode(&g, length: 0...12)
            let team = g.chance(60) ? g.pick(["ABCDE12345", "abcde12345", "ABCDE1234", "ABCDE123456", "ABCDÉ12345", "ABCDE1234\"", "0000000000"])
                : SampleText.unicode(&g, length: 8...12)
            return (bundle, team)
        }) { sample in
            guard let requirement = UpdateInstallRules.requirement(bundleID: sample.bundle, teamID: sample.team) else { return nil }
            guard UpdateInstallRules.isTeamID(sample.team) else { return "équipe « \(sample.team) » acceptée" }
            guard requirement.filter({ $0 == "\"" }).count == 4 else { return "« \(requirement) »" }
            guard requirement.hasPrefix("identifier \"\(sample.bundle)\" and anchor apple generic"),
                  requirement.hasSuffix("certificate leaf[subject.OU] = \"\(sample.team)\"") else { return "« \(requirement) »" }
            return nil
        }
    }

    /// Identifiant d'équipe : dix majuscules ou chiffres ASCII, rien d'autre.
    @Test func teamIdentifiersAreTenUppercaseASCII() {
        forAll(5_000, seed: 0x494E_5332, { g in
            String((0..<g.int(8...12)).map { _ in g.pick(Array("ABCXYZ0189abcÉ -\"") + ["\u{FF21}"]) })
        }) { team in
            let expected = team.count == 10 && team.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
            return UpdateInstallRules.isTeamID(team) == expected ? nil : "« \(team) »"
        }
    }

    /// La copie de la nouvelle version et la sauvegarde de l'ancienne sont cachées, à côté de l'app, et distinctes.
    @Test func stagingAndBackupAreHiddenSiblings() {
        forAll(3_000, seed: 0x494E_5333, { g -> URL in
            let name = g.chance(60) ? g.pick(["Wispad", "Wispad 2", "Wis.pad", ".Wispad", "Ω", "Wispad (1)", "Dictée"])
                : SampleText.unicode(&g, length: 1...10).replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "\0", with: "")
            let folder = g.pick(["/Applications", "/Volumes/Externe/Applications", "/tmp/a b"])
            return URL(fileURLWithPath: folder).appendingPathComponent((name.isEmpty ? "Wispad" : name) + ".app", isDirectory: true)
        }) { app in
            let staging = UpdateInstallRules.stagingURL(for: app), backup = UpdateInstallRules.backupURL(for: app)
            for copy in [staging, backup] {
                if copy.deletingLastPathComponent().standardizedFileURL != app.deletingLastPathComponent().standardizedFileURL { return "\(copy.path) hors de \(app.path)" }
                if copy.lastPathComponent.utf8.first != UInt8(ascii: ".") || copy.pathExtension != "app" { return copy.path }
                if copy.standardizedFileURL == app.standardizedFileURL { return "\(copy.path) écrase l'app" }
            }
            return staging.standardizedFileURL == backup.standardizedFileURL ? "\(staging.path) sert deux fois" : nil
        }
    }

    /// La sortie de `hdiutil`, même illisible, ne fait jamais planter ; seuls des points de montage non vides sortent.
    @Test func mountPointsFromAnyOutput() {
        forAll(2_000, seed: 0x494E_5334, { g -> (data: Data, points: [String]) in
            let points = (0..<g.int(0...3)).map { _ in "/Volumes/" + g.pick(["Wispad", "Wispad 1", "dmg.AbC", "é & <x>"]) }
            let entities = points.map { "<dict><key>mount-point</key><string>\($0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;"))</string></dict>" }
            let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk9</string></dict>"#
                + entities.joined() + "</array></dict></plist>"
            switch g.int(0...2) {
            case 0: return (Data((g.pick(["", "Vérification…\n", "hdiutil: attach\n"]) + plist).utf8), points)
            case 1:
                var bytes = [UInt8](repeating: 0, count: g.int(0...400))
                for index in bytes.indices { bytes[index] = UInt8(g.int(0...255)) }
                return (Data(bytes), [])
            default: return (Data(("<?xml" + SampleText.unicode(&g)).utf8), [])
            }
        }) { sample in
            let found = UpdateInstallRules.mountPoints(fromPlist: sample.data)
            if found.contains(where: \.isEmpty) { return "point de montage vide" }
            return sample.points.isEmpty || found == sample.points ? nil : "\(found) ≠ \(sample.points)"
        }
    }

    /// L'ordre des obstacles est fixe : build de développement, disque absent, signature, emplacement.
    @Test func obstaclesComeInTheirOrder() {
        let disk = DiskImageAsset(url: ReleaseCheck.releasesURL.appendingPathComponent("download/v9.9.9/Wispad.dmg"))
        for kind in [BuildKind.release, .development] {
            for hasDisk in [true, false] {
                for team in ["ABCDE12345", nil, "abc"] as [String?] {
                    for path in ["/Applications/Wispad.app", "/Applications/Wispad", "/private/var/folders/x/AppTranslocation/1/d/Wispad.app"] {
                        for folderWritable in [true, false] {
                            for appWritable in [true, false] {
                                let release = ReleaseInfo(version: SemanticVersion(major: 9, minor: 9, patch: 9), tag: "v9.9.9", notes: "",
                                                          pageURL: ReleaseCheck.releasesURL, diskImage: hasDisk ? disk : nil)
                                let expected: UpdateInstallObstacle?
                                if kind != .release { expected = .developmentBuild }
                                else if !hasDisk { expected = .noDiskImage }
                                else if team.map(UpdateInstallRules.isTeamID) != true { expected = .unsigned }
                                else if !path.hasSuffix(".app") || path.contains("/AppTranslocation/") || !folderWritable || !appWritable { expected = .readOnlyLocation }
                                else { expected = nil }
                                #expect(UpdateInstallRules.obstacle(kind: kind, release: release, appPath: path, teamID: team,
                                                                    folderWritable: folderWritable, appWritable: appWritable) == expected)
                            }
                        }
                    }
                }
            }
        }
    }
}
