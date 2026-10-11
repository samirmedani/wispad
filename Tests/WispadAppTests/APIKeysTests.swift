import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Choix du magasin de clés et fichier local d'un client, sur un dossier temporaire (jamais les vraies clés).
struct APIKeysTests {
    @Test func vaultIsUsedOnlyWhenItsToolIsInstalled() throws {
        let defaults = try #require(UserDefaults(suiteName: "wispad-keystore-\(UUID().uuidString)"))
        let missing = URL(fileURLWithPath: "/nonexistent/secret-tool")
        #expect(KeyStoreKind.detect(environment: [:], defaults: defaults, vaultTool: missing) == .file)
        let present = URL(fileURLWithPath: "/bin/ls")
        #expect(KeyStoreKind.detect(environment: [:], defaults: defaults, vaultTool: present) == .vault)
        #expect(KeyStoreKind.detect(environment: ["WISPAD_KEYSTORE": "file"], defaults: defaults, vaultTool: present) == .file)
        defaults.set("file", forKey: "wispad.keystore")
        #expect(KeyStoreKind.detect(environment: [:], defaults: defaults, vaultTool: present) == .file)
    }

    @Test func onlyTheAppFileAllowsDeletionAndRetiredAccountsAreGone() {
        #expect(APIKeys.Vault.names(for: "custom").isEmpty)
        #expect(!APIKeys.accounts.contains("custom"))
        #expect(KeyStoreKind.file.allowsDeletion)
        #expect(!KeyStoreKind.vault.allowsDeletion)
    }

    @Test func localFileStoresReplacesReadsAndDeletesPrivately() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("api-keys.json")
        #expect(await APIKeys.LocalFile.readAll(["xai"], url: url).map(\.1) == [nil])
        #expect(await APIKeys.LocalFile.write("xai", "première", url: url))
        #expect(await APIKeys.LocalFile.write("xai", "seconde", url: url))
        #expect(await APIKeys.LocalFile.write("deepseek", "autre", url: url))
        let all = await APIKeys.LocalFile.readAll(["xai", "deepseek", "openai"], url: url)
        #expect(all.map(\.1) == ["seconde", "autre", nil])
        #expect(all.allSatisfy { $0.2 })
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(await APIKeys.LocalFile.delete("xai", url: url))
        #expect(await APIKeys.LocalFile.readAll(["xai", "deepseek"], url: url).map(\.1) == [nil, "autre"])
        // Aucun fichier temporaire ne reste à côté.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["api-keys.json"])
    }

    @Test func unreadableFileIsReportedAndNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("api-keys.json")
        try Data("pas du JSON".utf8).write(to: url)
        #expect(await APIKeys.LocalFile.readAll(["xai"], url: url).map(\.2) == [false])
        #expect(!(await APIKeys.LocalFile.write("xai", "clé", url: url)))
        let untouched = try String(contentsOf: url, encoding: .utf8)
        #expect(untouched == "pas du JSON")
    }
}
