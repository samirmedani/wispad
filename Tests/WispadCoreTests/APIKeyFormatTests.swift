import Testing
@testable import WispadCore

/// Fournisseur d'une clé reconnu à sa forme, sans réseau. Les clés sont fabriquées ici, jamais de vraies clés.
struct APIKeyFormatTests {
    private static func key(_ prefix: String, _ filler: String, count: Int) -> String {
        prefix + String(repeating: filler, count: count)
    }

    @Test func providersAreRecognizedFromTheKeyAlone() {
        #expect(APIKeyFormat.guess(Self.key("xai-", "a", count: 80)) == .xai)
        #expect(APIKeyFormat.guess(Self.key("XAI-", "a", count: 80)) == .xai)
        // DeepSeek : « sk- » puis 32 caractères hexadécimaux.
        #expect(APIKeyFormat.guess(Self.key("sk-", "0f", count: 16)) == .account(CleanupModel.deepSeekAccount))
        #expect(APIKeyFormat.guess(Self.key("sk-proj-", "b", count: 60)) == .account(ProviderID.openAI.rawValue))
        #expect(APIKeyFormat.guess(Self.key("sk-svcacct-", "c", count: 60)) == .account(ProviderID.openAI.rawValue))
        // Ancienne clé OpenAI : « sk- » puis 48 caractères, pas seulement hexadécimaux.
        #expect(APIKeyFormat.guess(Self.key("sk-", "z", count: 48)) == .account(ProviderID.openAI.rawValue))
        // 32 caractères qui ne sont pas tous hexadécimaux : pas DeepSeek.
        #expect(APIKeyFormat.guess(Self.key("sk-", "g", count: 32)) == .account(ProviderID.openAI.rawValue))
    }

    @Test func pastedDecorationsAreIgnored() {
        let deepSeek = Self.key("sk-", "0f", count: 16)
        #expect(APIKeyFormat.normalize("  Bearer \(deepSeek)\n") == deepSeek)
        #expect(APIKeyFormat.normalize("\"\(deepSeek)\"") == deepSeek)
        #expect(APIKeyFormat.guess("“\(deepSeek)”") == .account(CleanupModel.deepSeekAccount))
    }

    @Test func otherServicesAndUnknownShapesAreNotGuessed() {
        #expect(APIKeyFormat.guess(Self.key("sk-ant-", "d", count: 60)) == .unsupported("Anthropic"))
        #expect(APIKeyFormat.guess(Self.key("sk-or-", "d", count: 60)) == .unsupported("OpenRouter"))
        #expect(APIKeyFormat.guess(Self.key("gsk_", "d", count: 50)) == .unsupported("Groq"))
        // TypeSafe n'a pas de forme connue : le fournisseur se choisit.
        #expect(APIKeyFormat.guess(Self.key("ts", "e", count: 40)) == .unknown)
        #expect(APIKeyFormat.guess("sk-court") == .unknown)
        #expect(APIKeyFormat.guess("deux mots " + Self.key("sk-", "f", count: 40)) == .unknown)
        #expect(APIKeyFormat.guess("") == .unknown)
    }

    @Test func maskedKeysShowOnlyThePrefixAndTheLastFourCharacters() {
        #expect(APIKeyFormat.masked(Self.key("xai-", "a", count: 76) + "3f9a") == "xai-••••3f9a")
        #expect(APIKeyFormat.masked(Self.key("sk-proj-", "b", count: 56) + "WXYZ") == "sk-proj-••••WXYZ")
        #expect(APIKeyFormat.masked(Self.key("sk-", "0f", count: 14) + "beef") == "sk-••••beef")
        #expect(APIKeyFormat.masked(Self.key("ts", "e", count: 30) + "1234") == "••••1234")
        #expect(APIKeyFormat.masked("court") == "••••")
    }
}
