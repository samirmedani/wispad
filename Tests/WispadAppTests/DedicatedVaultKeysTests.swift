import Foundation
import Testing
@testable import WispadApp
import WispadCore

struct DedicatedVaultKeysTests {
    @Test func productionProvidersNeverFallBackToSharedOrBenchmarkKeys() {
        #expect(APIKeys.Vault.names(for: ProviderID.xai.rawValue) == ["WISPAD_XAI_API_KEY"])
        #expect(APIKeys.Vault.names(for: ProviderID.openAI.rawValue) == ["WISPAD_OPENAI_API_KEY"])
        #expect(APIKeys.Vault.names(for: CleanupModel.deepSeekAccount) == ["WISPAD_DEEPSEEK_API_KEY"])
    }

    @Test func vaultCommandIsOnlyUsedWhenConfigured() throws {
        let defaults = try #require(UserDefaults(suiteName: "wispad-secret-command-\(UUID().uuidString)"))
        #expect(APIKeys.Vault.configuredTool(environment: [:], defaults: defaults) == nil)
        defaults.set("~/bin/secret", forKey: "wispad.secretCommand")
        #expect(APIKeys.Vault.configuredTool(environment: [:], defaults: defaults)?.path == NSHomeDirectory() + "/bin/secret")
        #expect(APIKeys.Vault.configuredTool(environment: ["WISPAD_SECRET_COMMAND": "/opt/secret"], defaults: defaults)?.path == "/opt/secret")
        #expect(KeyStoreKind.detect(environment: [:], defaults: defaults, vaultTool: nil) == .file)
    }
}
