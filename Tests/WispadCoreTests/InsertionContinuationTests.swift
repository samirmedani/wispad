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

    @Test func agreementContextKeepsTheParagraphBeforeTheCursor() {
        let paragraph = "Paul a reçu le dossier.\n\n"
        var request = CorrectionRequest(transcript: "ils regardent encore le calendrier",
                                        previousDictations: ["Les collègues de Victor replacent les agendas."],
                                        windowText: "Ses collègues relisent le planning.")
        request.textBeforeCursor = String(repeating: "x", count: CorrectionRequest.cursorContextLimit) + paragraph
        let prompt = CorrectionPrompt.userText(request)
        #expect(prompt.contains(paragraph))
        #expect(!prompt.contains(String(repeating: "x", count: CorrectionRequest.cursorContextLimit)))
        #expect(!prompt.contains("replacent les agendas"))
        #expect(prompt.contains("orthographe uniquement): Victor"))
        #expect(!prompt.contains("champ de saisie vide"))
        #expect(CorrectionPrompt.system(for: request).contains("même après un saut de paragraphe"))
        request.windowMayResolveAgreement = true
        #expect(CorrectionPrompt.userText(request).contains("champ de saisie vide"))
    }

    @Test func exactContinuationKeepsItsEarlierSubject() {
        let before = "Hugo était de garde. Il était seul dans le bureau.\n\n"
        #expect(ContinuationAgreement.reapply(in: "Ils étaient encore seuls dans le bureau quand le téléphone a sonné.", after: before)
                == "Il était encore seul dans le bureau quand le téléphone a sonné.")
        #expect(ContinuationAgreement.reapply(in: "Elle prépare donc la réponse pour le client.",
                                             after: "Elles préparent la réponse pour le client.\n") == "Elles préparent donc la réponse pour le client.")
        for other in ["Les techniciens étaient encore seuls dans le bureau.", "Ils étaient encore seuls dans le garage.",
                      "« Ils étaient encore seuls dans le bureau. »", "Ils sont encore seuls dans le bureau.",
                      "Ils étaient seuls dans le bureau."] {
            #expect(ContinuationAgreement.reapply(in: other, after: before) == other)
        }
        #expect(ContinuationAgreement.reapply(in: "Ils étaient encore seuls dans le bureau.", after: nil)
                == "Ils étaient encore seuls dans le bureau.")
    }

    @Test func coordinatedDraftUsesTheLastSubjectOutsideQuotes() {
        let heard = "Elle examine encore le tableau électrique avant de partir."
        let draft = "Elle ferme la porte, puis elles examinent le tableau électrique.\u{2028}"
        #expect(ContinuationAgreement.reapply(in: heard, after: draft)
                == "Elles examinent encore le tableau électrique avant de partir.")
        let quotation = "Le rapport indique « Les techniciennes arrivent et elles examinent le tableau électrique »."
        #expect(ContinuationAgreement.reapply(in: heard, after: quotation) == heard)
        let different = "Les techniciennes arrivent et elles examinent le plan de secours."
        #expect(ContinuationAgreement.reapply(in: heard, after: different) == heard)
    }

    @Test func aSubjectAfterACommaKeepsItsOwnAgreement() {
        let draft = "Les passagers montent et ils surveillent la porte du quai."
        let differentSubject = "Il surveille encore la porte du quai, le gardien."
        #expect(ContinuationAgreement.reapply(in: differentSubject, after: draft) == differentSubject)

        let continuation = "Il surveille encore la porte du quai. Ensuite, la gare ferme."
        #expect(ContinuationAgreement.reapply(in: continuation, after: draft)
                == "Ils surveillent encore la porte du quai. Ensuite, la gare ferme.")
    }
}
