import ApplicationServices
import Foundation
import Testing
@testable import WispadApp

/// Données venues d'une autre app ou d'une commande choisie par l'utilisateur : Wispad ne s'arrête jamais sur elles.
struct ExternalDataAppTests {
    // MARK: Coffre de secrets

    /// Commande du coffre écrite dans un dossier temporaire ; `body` est le script shell.
    private func vaultTool(_ body: String) throws -> (tool: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-coffre-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("coffre")
        try ("#!/bin/sh\n" + body + "\n").write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        return (tool, folder)
    }

    /// Une commande qui se termine sans lire la clé (`put` refusé) fermait le tuyau : l'écriture de la clé arrêtait
    /// Wispad (signal SIGPIPE ou exception de `FileHandle.write`).
    @Test(.timeLimit(.minutes(1))) func vaultCommandThatIgnoresItsInputDoesNotStopWispad() async throws {
        let (tool, folder) = try vaultTool("exit 3")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Plus long que le tampon d'un tuyau : l'écriture rencontre forcément le tuyau fermé.
        let secret = String(repeating: "k", count: 1_000_000)
        let (status, output) = await APIKeys.Vault.run(["put", "WISPAD_TEST_COFFRE"], input: secret, tool: tool)
        #expect(status == 3)
        #expect(output.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func vaultCommandStillReceivesTheKeyOnItsInput() async throws {
        let (tool, folder) = try vaultTool(#"/bin/cat > "$0.recu"; echo enregistré"#)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (status, output) = await APIKeys.Vault.run(["put", "WISPAD_TEST_COFFRE"], input: "cle-de-test", tool: tool)
        #expect(status == 0)
        #expect(output == "enregistré\n")
        #expect(try String(contentsOf: URL(fileURLWithPath: tool.path + ".recu"), encoding: .utf8) == "cle-de-test")
        let (readStatus, value) = await APIKeys.Vault.run(["get", "WISPAD_TEST_COFFRE"], tool: tool)
        #expect(readStatus == 0)
        #expect(value == "enregistré\n")
    }

    // MARK: Texte autour du curseur

    /// La plage de sélection vient de l'app au premier plan : une valeur d'un autre type n'était pas vérifiée
    /// (`as! AXValue`), et une longueur démesurée faisait déborder l'addition qui borne l'extrait.
    @Test func nearbyTextToleratesOddSelections() throws {
        let value = String(repeating: "a", count: 300) + "MILIEU" + String(repeating: "b", count: 300)
        let text = value as NSString
        func around(_ range: CFRange) throws -> String {
            var range = range
            let selection = try #require(AXValueCreate(.cfRange, &range))
            return ContextProbe.nearby(value: value, selection: selection)
        }
        // Cas ordinaire : 220 caractères de part et d'autre de la sélection.
        #expect(try around(CFRange(location: 300, length: 6)) == text.substring(with: NSRange(location: 80, length: 446)))
        // Longueur démesurée annoncée par l'app : l'extrait va jusqu'à la fin du champ.
        #expect(try around(CFRange(location: 300, length: .max)) == text.substring(from: 80))
        #expect(try around(CFRange(location: .max, length: .max)) == text.substring(from: 386))
        // Pas une plage : le début du champ sert de repère, comme sans sélection lisible.
        let start = String(value.prefix(220))
        var point = CGPoint(x: 1, y: 2)
        #expect(ContextProbe.nearby(value: value, selection: "pas une plage" as CFString) == start)
        #expect(ContextProbe.nearby(value: value, selection: NSNumber(value: 42)) == start)
        #expect(ContextProbe.nearby(value: value, selection: AXValueCreate(.cgPoint, &point)) == start)
        #expect(ContextProbe.nearby(value: value, selection: nil) == start)
    }
}
