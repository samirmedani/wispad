import Testing
@testable import WispadCore

struct OralCleanupTests {
    @Test func spokenPleaseAndThereIsAreWrittenOut() {
        // Formes écrites par xAI le 3 novembre 2026.
        #expect(WrittenGrammar.expandOralSpellings("Mets ça à 360 degrés s'te plaît") == "Mets ça à 360 degrés s'il te plaît")
        #expect(WrittenGrammar.expandOralSpellings("S'vous plait, entrez") == "S'il vous plaît, entrez")
        #expect(WrittenGrammar.expandOralSpellings("avec OpenCodex y'a Hermes, y'avait rien, y'en a deux")
                == "avec OpenCodex y a Hermes, y avait rien, y en a deux")
        #expect(WrittenGrammar.expandOralSpellings("Y'a un souci") == "Y a un souci")
        #expect(WrittenGrammar.expandOralSpellings("il y a, s'il te plaît") == "il y a, s'il te plaît")
    }

    @Test func stutteredWordsAreRemoved() {
        #expect(WrittenGrammar.removeRepeatedWords("En fait c'est, c'est une putain d'offre") == "En fait c'est une putain d'offre")
        #expect(WrittenGrammar.removeRepeatedWords("Il, il coûterait genre 8 700 €") == "Il coûterait genre 8 700 €")
        #expect(WrittenGrammar.removeRepeatedWords("tu tu peux lui lui dire") == "tu peux lui lui dire")
        #expect(WrittenGrammar.removeRepeatedWords("fait la même la même chose") == "fait la même chose")
        #expect(WrittenGrammar.removeRepeatedWords("je je je pense") == "je pense")
        #expect(WrittenGrammar.removeRepeatedWords("de gros modèles en, en local") == "de gros modèles en local")
        #expect(WrittenGrammar.removeRepeatedWords("le trajet sur le, le, le fader") == "le trajet sur le fader")
    }

    @Test func intendedRepetitionsStay() {
        let kept = [
            "nous nous voyons demain", "vous vous trompez", "non non, c'est bon", "c'est très très bien",
            "elle, elle n'a rien dit", "on part à Bora Bora", "le score est 2 2", "vite vite, on y va", "Fini. Fini, vraiment.",
            "« je je » est un tic", "Et tout ça, ça a été fait", "C'est qui qui l'a intégré ?", "Vas-y, vas-y, fais-le",
            "pas du tout, du tout", "Et si c'est demain, c'est demain", "C'est ça que je veux, je veux pas juste ça",
            "la deuxième, la deuxième pour avoir la troisième", "je vais faire faire le travail", "Ouh là là",
        ]
        for text in kept { #expect(WrittenGrammar.removeRepeatedWords(text) == text) }
    }

    @Test(arguments: [DictationTone.natural, .polished, .casual])
    func everyFrenchToneGetsTheCleanup(_ tone: DictationTone) {
        #expect(TextCleaner.completeWrittenGrammar("Envoie-le s'te plaît, c'est, c'est urgent.", language: .french, tone: tone)
                == "Envoie-le s'il te plaît, c'est urgent.")
        #expect(TextCleaner.completeWrittenGrammar("the the end", language: .english, tone: tone) == "the the end")
    }
}
