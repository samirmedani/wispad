import Testing
@testable import WispadCore

/// Paragraphes automatiques : la consigne de découpage n'arrive qu'avec le réglage, sur une dictée longue.
struct ParagraphPolicyTests {
    private static let long = Array(repeating: "Je te fais un point rapide sur le projet.", count: 6).joined(separator: " ")
    private static let short = "On se voit demain à 14h, je t'apporte les documents."

    @Test(arguments: [DictationLanguage.french, .english])
    func longDictationGetsTheParagraphRuleLast(language: DictationLanguage) {
        let system = CorrectionPrompt.system(for: CorrectionRequest(transcript: Self.long, language: language))
        let marker = language == .english ? "Paragraphs: this dictation is long." : "Paragraphes : cette dictée est longue."
        #expect(system.contains(marker))
        #expect(system.hasSuffix(language == .english ? "Have a good evening." : "Bonne soirée."))
    }

    @Test func shortDictationStaysInOneBlock() {
        let system = CorrectionPrompt.system(for: CorrectionRequest(transcript: Self.short))
        #expect(!system.contains("Paragraphes : cette dictée est longue."))
        #expect(system.contains("N'ajoute pas de paragraphe de toi-même"))
    }

    @Test(arguments: [true, false])
    func settingOffNeverAsksForParagraphs(structure: Bool) {
        var request = CorrectionRequest(transcript: Self.long, structureDictation: structure)
        request.autoParagraphs = false
        let system = CorrectionPrompt.system(for: request)
        #expect(!system.contains("Paragraphes : cette dictée est longue."))
        #expect(system.contains("N'ajoute pas de paragraphe de toi-même"))
    }

    @Test func selectionCommandIgnoresParagraphs() {
        var request = CorrectionRequest(transcript: Self.long)
        request.commandSelection = "Un texte sélectionné."
        #expect(!ParagraphPolicy.applies(to: request))
    }

    @Test func thresholdCountsWords() {
        let below = Array(repeating: "mot", count: ParagraphPolicy.minimumWords - 1).joined(separator: " ")
        let at = below + " mot"
        #expect(!ParagraphPolicy.applies(to: CorrectionRequest(transcript: below)))
        #expect(ParagraphPolicy.applies(to: CorrectionRequest(transcript: at)))
    }
}
