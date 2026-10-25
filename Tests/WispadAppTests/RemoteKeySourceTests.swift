import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

@Suite struct RemoteKeySourceTests {
    private func defaults(_ values: [String: String]) -> UserDefaults {
        let suite = "wispad.tests.remote.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    @Test func remoteSourceIsChosenOnlyWithACommandHoldingTheName() {
        #expect(APIKeys.Vault.remoteCommand(defaults: defaults([:])) == nil)
        #expect(APIKeys.Vault.remoteCommand(defaults: defaults(["wispad.keystore": "remote", "wispad.remoteCommand": "echo x"])) == nil)
        let chosen = defaults(["wispad.keystore": "remote", "wispad.remoteCommand": " op read op://W/{name}/credential "])
        #expect(APIKeys.Vault.remoteCommand(defaults: chosen) == "op read op://W/{name}/credential")
        #expect(KeyStoreKind.detect(environment: [:], defaults: chosen, vaultTool: nil) == .vault)
        #expect(KeyStoreKind.detect(environment: ["WISPAD_KEYSTORE": "file"], defaults: chosen, vaultTool: nil) == .file)
        #expect(KeyStoreKind.detect(environment: [:], defaults: defaults(["wispad.remoteCommand": "x {name}"]), vaultTool: nil) == .file)
    }

    @Test func remoteCommandFindsMissesAndFails() async {
        let command = "case {name} in WISPAD_XAI_API_KEY) printf 'xai-cle-de-test\\n';; WISPAD_DEEPSEEK_API_KEY) exit 1;; *) exit 0;; esac"
        let (found, value) = await APIKeys.Vault.runRemote(command, name: "WISPAD_XAI_API_KEY")
        #expect(found == 0)
        #expect(value.trimmingCharacters(in: .whitespacesAndNewlines) == "xai-cle-de-test")
        let results = await APIKeys.Vault.probe(command: command)
        #expect(results.first { $0.account == "xai" }?.found == true)
        #expect(results.first { $0.account == "deepseek" }?.found == false)
        #expect(results.allSatisfy { $0.reachable })
        let broken = await APIKeys.Vault.probe(command: "exit 7 # {name}")
        #expect(broken.allSatisfy { !$0.found && !$0.reachable })
    }
}

@Suite struct RemoteKeySourceLiveTests {
    /// Commande réelle (WISPAD_REMOTE_TEST_COMMAND) : affiche seulement les comptes trouvés, jamais une valeur.
    @Test func liveRemoteCommand() async {
        guard let command = ProcessInfo.processInfo.environment["WISPAD_REMOTE_TEST_COMMAND"] else { return }
        let start = Date()
        let results = await APIKeys.Vault.probe(command: command)
        print("REMOTE-LIVE", String(format: "%.1f s", Date().timeIntervalSince(start)),
              results.map { "\($0.account):\($0.found ? "trouvée" : "absente")\($0.reachable ? "" : " injoignable")" })
    }
}
