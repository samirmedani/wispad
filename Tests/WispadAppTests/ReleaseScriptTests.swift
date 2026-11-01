import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// scripts/release.sh : la clé de release que l'app lit, la signature et la notarisation attendues, et rien de propre
/// au mainteneur dans le dépôt (tout vient de l'environnement).
struct ReleaseScriptTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func readScript() throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("scripts/release.sh"), encoding: .utf8)
    }

    /// Seul ce script marque une release : l'app y lit `BuildKind.infoKey` pour choisir entre releases et retard sur main.
    @Test func addsTheReleaseKeyTheAppReads() throws {
        let script = try readScript()
        #expect(script.contains("Add :\(BuildKind.infoKey) bool true"))
        #expect(script.contains(ReleaseCheck.diskImageName))
        #expect(script.contains(#"ARCHS="arm64 x86_64""#))
        // Les builds de tous les jours n'ont pas la clé.
        for other in ["scripts/install.sh", "scripts/build.sh", "scripts/build-commit.sh", "project.yml", "Sources/Wispad/Info.plist"] {
            let text = try String(contentsOf: Self.root.appendingPathComponent(other), encoding: .utf8)
            #expect(!text.contains(BuildKind.infoKey), "\(other) ne doit pas marquer une release")
        }
    }

    @Test func signsNotarizesAndPublishes() throws {
        let script = try readScript()
        for step in ["--options runtime", "--timestamp", "--entitlements", "get-task-allow", "Developer ID Application",
                     "hdiutil create", "ln -s /Applications", "notarytool submit", "stapler staple", "gh release create"] {
            #expect(script.contains(step), "étape absente : \(step)")
        }
        let entitlements = try String(contentsOf: Self.root.appendingPathComponent("Sources/Wispad/Wispad.entitlements"), encoding: .utf8)
        #expect(!entitlements.contains("get-task-allow"))
    }

    @Test func containsNoSecretNorTeamIdentifier() throws {
        let script = try readScript()
        // Certificat, équipe et clé de notarisation : lus dans l'environnement.
        #expect(script.contains("$WISPAD_SIGNING_IDENTITY"))
        #expect(script.contains("$WISPAD_TEAM_ID"))
        #expect(script.contains("$WISPAD_NOTARY_KEY"))
        #expect(script.contains("$WISPAD_NOTARY_KEY_ID"))
        #expect(script.contains("$WISPAD_NOTARY_ISSUER"))
        // Ni identifiant d'équipe (10 majuscules et chiffres), ni identifiant d'émetteur (UUID), ni clé .p8.
        let words = script.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        let teamLike = words.filter { word in
            word.count == 10 && word.allSatisfy({ $0.isUppercase || $0.isNumber })
                && word.contains(where: \.isNumber) && word.contains(where: \.isLetter)
        }
        #expect(teamLike.isEmpty, "identifiant d'équipe en dur : \(teamLike)")
        let uuid = try Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        #expect(script.firstMatch(of: uuid) == nil)
        #expect(!script.contains("AuthKey_"))
        #expect(!script.contains("Developer ID Application:"))
    }

    /// Chaque chemin du texte existe : un fichier renommé ou déplacé ne sort pas du banc du texte sans qu'on le voie.
    @Test func textPathsExist() throws {
        let list = try String(contentsOf: Self.root.appendingPathComponent("scripts/text-paths.txt"), encoding: .utf8)
        let paths = list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(paths.count >= 20)
        for path in paths {
            #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(path).path), "\(path) n'existe plus")
        }
    }
}
