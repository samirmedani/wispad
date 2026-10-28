import Testing
@testable import WispadApp
@testable import WispadCore

/// Mots connus pour le report du fichier dans la correction du flux : orthographe de macOS dans la langue de la dictée,
/// dictionnaire et vocabulaire technique. Sans dictionnaire français dans macOS, la vérification ne s'applique pas.
@MainActor
struct DivergentHearingTests {
    @Test func knownWordsComeFromMacOSTheDictionaryAndTheVocabulary() {
        guard let known = DictationCoordinator.knownWord(for: "Et même sur des mots", language: .french, terms: ["Wispad"]) else { return }
        #expect(known("mots"))
        #expect(!known("mope"))
        #expect(known("t'as"))
        #expect(known("Wispad"))
        #expect(known("Vercel"))
    }

    /// Le 28 octobre 2026 : « des mots » entendu en direct, « des mope » dans l'enregistrement complet. Le report
    /// s'abstient ; la correction complète reçoit les deux écoutes.
    @Test func unknownWordFromTheFileIsNotReported() {
        guard let known = DictationCoordinator.knownWord(for: "x", language: .french, terms: []) else { return }
        #expect(CorrectionPatch.apply(
            corrected: "Et même sur des mots, on dirait que la correction ne se fait pas réellement.",
            stream: "Et même sur des mots. On dirait que la correction ne se fait pas réellement.",
            file: "Et même sur des mope, on dirait que la correction ne se fait pas réellement.",
            knownWord: known
        ) == nil)
    }
}
