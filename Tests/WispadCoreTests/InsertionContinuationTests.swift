import Foundation
import Testing
@testable import WispadCore

/// Raccord de la dictée avec l'endroit où elle arrive : majuscule, minuscule et point final (exemples fictifs).
struct InsertionContinuationTests {
    @Test func theTextBeforeTheCursorTellsWhereTheDictationLands() {
        #expect(SmartJoin.position(before: nil) == .unknown)
        #expect(SmartJoin.position(before: "") == .sentenceStart)
        #expect(SmartJoin.position(before: "Fini.") == .sentenceStart)
        #expect(SmartJoin.position(before: "Vraiment ? ") == .sentenceStart)
        #expect(SmartJoin.position(before: "Il a dit « oui. »") == .sentenceStart)
        #expect(SmartJoin.position(before: "Titre\n") == .sentenceStart)
        #expect(SmartJoin.position(before: "Je pense que ") == .continuation)
        #expect(SmartJoin.position(before: "Note :") == .continuation)
        #expect(SmartJoin.position(before: "Bonjour Paul,") == .continuation)
        #expect(SmartJoin.position(before: "Il a dit « ") == .quoteStart)
    }

    @Test func aCommonFirstWordFollowsTheSentence() {
        #expect(SmartJoin.fit("Demain c'est mieux.", before: "Je pense que") == "demain c'est mieux.")
        #expect(SmartJoin.fit("J'arrive vers midi.", before: "Pas de souci,") == "j'arrive vers midi.")
        #expect(SmartJoin.fit("Et la suite.", before: "Le début") == "et la suite.")
        #expect(SmartJoin.fit("demain on se voit.", before: "Fini. ") == "Demain on se voit.")
        #expect(SmartJoin.fit("le rendez-vous est confirmé.", before: "") == "Le rendez-vous est confirmé.")
        #expect(SmartJoin.fit("Then we ship it.", before: "We test it first and") == "then we ship it.")
    }

    @Test func namesAcronymsAndUnknownPlacesKeepTheCorrectionCase() {
        #expect(SmartJoin.fit("Paul arrive demain.", before: "Je pense que") == "Paul arrive demain.")
        #expect(SmartJoin.fit("API en panne.", before: "Alerte :") == "API en panne.")
        #expect(SmartJoin.fit("I will call you.", before: "Tomorrow") == "I will call you.")
        #expect(SmartJoin.fit("iPhone chargé.", before: "Fini. ") == "iPhone chargé.")
        #expect(SmartJoin.fit("Demain c'est mieux.", before: nil) == "Demain c'est mieux.")
        #expect(SmartJoin.fit("Demain c'est mieux.", before: "Il a dit « ") == "Demain c'est mieux.")
    }

    @Test func theFinalPeriodGoesWhenTheSentenceGoesOnAfterTheCursor() {
        #expect(SmartJoin.fit("Demain matin.", before: "On se voit", after: " pour le café") == "demain matin")
        #expect(SmartJoin.fit("Demain matin.", before: "On se voit", after: " Pour") == "demain matin.")
        #expect(SmartJoin.fit("Demain matin ?", before: "On se voit", after: " pour") == "demain matin ?")
        #expect(SmartJoin.fit("Et puis...", before: "On verra", after: " plus tard") == "et puis...")
        #expect(SmartJoin.fit("Demain matin.", before: "Fini. ", after: " pour") == "Demain matin.")
    }

    @Test func aDictationThatGoesOnFromThePreviousOneRemovesItsPeriod() {
        let previous = " Je voulais te dire que."
        let before = "Bonjour." + previous
        #expect(SmartJoin.continuesPreviousPaste("demain on se voit.", before: before, previous: previous))
        #expect(!SmartJoin.continuesPreviousPaste("Demain on se voit.", before: before, previous: previous))
        #expect(!SmartJoin.continuesPreviousPaste("demain on se voit.", before: before + " Autre", previous: previous))
        #expect(!SmartJoin.continuesPreviousPaste("demain on se voit.", before: "Fini?", previous: "Fini?"))
        #expect(!SmartJoin.continuesPreviousPaste("demain on se voit.", before: before, previous: nil))
        #expect(SmartJoin.fit("demain on se voit.", before: String(before.dropLast())) == "demain on se voit.")
    }

    /// Le 1er novembre 2026, un texte affiché relu à voix haute : la correction remettait « du », entendu par le direct
    /// mais perdu par le fichier, et le garde-fou jetait toute la correction, paragraphes compris.
    @Test func aWordHeardByTheLiveStreamIsNotACopyOfTheWindow() {
        let heard = "Texte deux, le stand-up dev. Ce matin j'ai déployé en prod un vendredi et le build est passé sans souci"
        let stream = "Texte deux, le stand-up du dev. Ce matin j'ai déployé en prod un vendredi et le build est passé sans souci"
        let window = "Texte 2, le stand-up du dev. Ce matin, j'ai déployé en prod un vendredi. Le build est passé sans souci."
        let corrected = "Texte deux, le stand-up du dev.\n\nCe matin, j'ai déployé en prod un vendredi et le build est passé sans souci."
        #expect(FidelityGuard.check(transcript: heard, corrected: corrected, previousDictations: [window], alternative: stream) == corrected)
        // Un seul mot repris du texte affiché, entendu par aucune écoute, ne fait plus jeter la mise en forme.
        #expect(FidelityGuard.check(transcript: heard, corrected: corrected, previousDictations: [window]) == corrected)
    }

    @Test func aRealCopyOfTheWindowIsStillRejected() {
        let heard = "Alors je voulais te parler du planning de la semaine prochaine pour la maquette du site"
        let window = "Rappel : la livraison du lot trois est décalée au jeudi suivant faute de validation client."
        let copied = "Alors je voulais te parler du planning. Rappel : la livraison du lot trois est décalée au jeudi suivant."
        #expect(FidelityGuard.check(transcript: heard, corrected: copied, previousDictations: [window]) == heard)
    }

    @Test func theCorrectionKnowsWhatIsJustBeforeTheCursor() {
        var request = CorrectionRequest(transcript: "demain c'est mieux")
        #expect(!CorrectionPrompt.userText(request).contains("Texte juste avant le curseur"))
        request.textBeforeCursor = "Je pense que"
        #expect(CorrectionPrompt.userText(request).contains("Texte juste avant le curseur (la dictée sera collée juste après ; ne jamais le recopier): « Je pense que »"))
        request.textBeforeCursor = ""
        #expect(CorrectionPrompt.userText(request).contains("ne jamais le recopier): «  »"))
        #expect(CorrectionPrompt.system(for: request).contains("la dictée continue cette phrase"))
        #expect(CorrectionPrompt.system(for: CorrectionRequest(transcript: "x", language: .english)).contains("the dictation continues that sentence"))
    }
}
