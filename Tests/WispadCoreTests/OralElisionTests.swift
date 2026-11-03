import Testing
@testable import WispadCore

struct OralElisionTests {
    @Test func oralElisionsBeforeAConsonantAreWrittenOut() {
        // Cas réel du 3 novembre 2026.
        #expect(WrittenGrammar.expandOralElisions("moi j'avais pensé à m'créer mon propre utilitaire")
                == "moi j'avais pensé à me créer mon propre utilitaire")
        #expect(WrittenGrammar.expandOralElisions("J'pense qu'tu vas l'faire") == "Je pense que tu vas le faire")
        #expect(WrittenGrammar.expandOralElisions("c'que j'sais, ça s'passe bien") == "ce que je sais, ça se passe bien")
    }

    @Test func writtenElisionsAndFamiliarFormsStay() {
        let kept = [
            "t'as vu ? t'es où ? t'sais quoi", "j'habite à Paris", "aujourd'hui", "lorsqu'il viendra",
            "jusqu'demain", "N'Golo Kanté", "l'Wi-Fi", "c'est l'heure", "j'y vais",
        ]
        for text in kept { #expect(WrittenGrammar.expandOralElisions(text) == text) }
    }

    @Test(arguments: [DictationTone.natural, .polished, .casual])
    func everyFrenchToneWritesThemOut(_ tone: DictationTone) {
        #expect(TextCleaner.completeWrittenGrammar("Je vais m'créer un outil.", language: .french, tone: tone)
                == "Je vais me créer un outil.")
        #expect(TextCleaner.completeWrittenGrammar("I'm fine", language: .english, tone: tone) == "I'm fine")
    }
}
