import Foundation
import Testing
@testable import WispadCore

struct WrittenGrammarTests {
    @Test func windowsAndUnixLineBreaksKeepTheSameClauseBoundaries() {
        for text in ["Faut\nla porte reste ouverte.", "Faut pas\nle bus arrive.", "Y a une\nla table est libre.",
                     "Faut fermer.\nY a du vent."] {
            let unix = WrittenGrammar.completeImpersonalSubjects(text)
            let windows = WrittenGrammar.completeImpersonalSubjects(text.replacingOccurrences(of: "\n", with: "\r\n"))
            #expect(windows.replacingOccurrences(of: "\r\n", with: "\n") == unix)
        }
    }

    @Test(arguments: [
        ("Faut déplacer la caisse.", "Il faut déplacer la caisse."),
        ("Fallait prévenir le gardien.", "Il fallait prévenir le gardien."),
        ("Faudra vérifier le stock.", "Il faudra vérifier le stock."),
        ("Faudrait fermer la porte.", "Il faudrait fermer la porte."),
        ("Fallut recommencer.", "Il fallut recommencer."),
        ("Y a une table libre.", "Il y a une table libre."),
        ("Y avait du vent.", "Il y avait du vent."),
        ("Y aura des visiteurs.", "Il y aura des visiteurs."),
        ("Y aurait deux places.", "Il y aurait deux places."),
        ("Y en a.", "Il y en a."),
        ("Y en avait.", "Il y en avait."),
        ("Et faut fermer la porte.", "Et il faut fermer la porte."),
        ("On attend, mais y a du retard.", "On attend, mais il y a du retard."),
        ("Le sol glisse ; faut marcher doucement.", "Le sol glisse ; il faut marcher doucement."),
        ("Le sol glisse. Faut marcher doucement.", "Le sol glisse. Il faut marcher doucement."),
        ("Une consigne : faut garder le badge.", "Une consigne : il faut garder le badge."),
        ("\n  Faut garder le badge.\nY a du monde.", "\n  Il faut garder le badge.\nIl y a du monde."),
        ("FAUT FERMER LA PORTE.", "IL FAUT FERMER LA PORTE."),
        ("T'as vu ? Faut prévenir le gardien.", "T'as vu ? Il faut prévenir le gardien."),
        ("« Gardez ce badge. » Faut prévenir le gardien.", "« Gardez ce badge. » Faut prévenir le gardien."),
        ("« Gardez ce badge ». Faut prévenir le gardien.", "« Gardez ce badge ». Il faut prévenir le gardien."),
    ])
    func completesOnlyCertainImpersonalSubjects(text: String, expected: String) {
        #expect(WrittenGrammar.completeImpersonalSubjects(text) == expected)
        #expect(WrittenGrammar.completeImpersonalSubjects(expected) == expected)
    }

    @Test(arguments: [
        "", "Faut", "Faut.", "Faut pas…", "Faut que", "Faut qu'il", "Faut en", "Faut le.", "Faut pas mais le bus arrive.",
        "Y a", "Y a.", "Y a une…", "Y avait des", "Y aura pas.", "Y a-t-il un abri ?",
        "Que faut préparer ?", "Alors que faut préparer ?", "Que fallait apporter ?", "Faut-il patienter ?",
        "La personne y a pensé.", "Cette salle y avait sa place.", "Il faut ouvrir.", "Il y a une sortie.",
        "Faille critique.", "La faille se ferme.", "T'as une lampe.", "J'sais où aller.",
        "« Faut fermer. Y a du vent. »", "« Faut fermer", "\"Faut fermer.\nY a du vent.\"",
        "‘Faut fermer.’", "'Y a du vent.'", "`Faut fermer`", "```\nFaut fermer.\n```", "~~~\nY a du vent.\n~~~",
        "https://example.org/Faut-fermer", "faut@example.org", "« la caisse »faut déplacer.",
    ])
    func finishingLeavesAmbiguityFragmentsAndLiteralsUntouched(_ text: String) {
        #expect(WrittenGrammar.completeImpersonalSubjects(text) == text)
    }

    @Test func longUnpunctuatedDictationKeepsEveryCompletion() {
        let text = "Faut ranger le local" + String(repeating: " et faut nettoyer la table", count: 180)
        let expected = "Il faut ranger le local" + String(repeating: " et il faut nettoyer la table", count: 180)
        #expect(WrittenGrammar.completeImpersonalSubjects(text) == expected)
    }

    @Test func complementSearchHasNoArbitraryLengthLimitAndStopsAtBoundaries() {
        let padding = String(repeating: "pas ", count: 600)
        let prefix = "Faut " + padding
        #expect(WrittenGrammar.completeImpersonalSubjects(prefix + "marcher.") == "Il faut " + padding + "marcher.")
        for suffix in ["; marcher.", "\nmarcher.", "mais le bus arrive."] {
            #expect(WrittenGrammar.completeImpersonalSubjects(prefix + suffix) == prefix + suffix)
        }
        #expect(WrittenGrammar.completeImpersonalSubjects("Faut\u{00A0}déplacer la table.") == "Il faut\u{00A0}déplacer la table.")
        #expect(WrittenGrammar.completeImpersonalSubjects("Y en a-t-il ?") == "Y en a-t-il ?")
    }

    @Test(arguments: [
        ("Faut ralentir.", "Il faut ralentir."),
        ("Faut pas traverser.", "Il ne faut pas traverser."),
        ("Fallait téléphoner.", "Il fallait téléphoner."),
        ("Faudrait essayer.", "Il faudrait essayer."),
        ("Y a personne.", "Il n'y a personne."),
        ("Y avait personne.", "Il n'y avait personne."),
        ("Y en a.", "Il y en a."),
        ("T'as raison.", "Tu as raison."),
        ("T'es arrivé.", "Tu es arrivé."),
        ("J'peux pas.", "Je ne peux pas."),
        ("Elle m'écoute pas.", "Elle ne m'écoute pas."),
        ("Faut ralentir. Fallait téléphoner. Faudrait essayer. Faut patienter. Faut rentrer.",
         "Il faut ralentir. Il fallait téléphoner. Il faudrait essayer. Il faut patienter. Il faut rentrer."),
    ])
    func grammaticalCompletionIsAccepted(heard: String, written: String) {
        #expect(FidelityGuard.check(transcript: heard, corrected: written) == written)
    }

    @Test(arguments: [
        ("Faut ralentir.", "Il faut vraiment ralentir."),
        ("Faut ralentir.", "Il ne faut ralentir."),
        ("Faut pas traverser.", "Il ne ne faut pas traverser."),
        ("Faut -12 degrés.", "Il faut 12 degrés."),
        ("Faut 1.5 litres.", "Il faut 15 litres."),
        ("Faut ralentir.", "Il faut."),
        ("Faut rester. Faut patienter.", "Faut rester. Faut patienter. Le ciel est vraiment bleu."),
        ("Faut rester. Faut patienter.", "Faut rester. Faut patienter. Il manque 12 boulons dehors."),
        ("Faut ralentir.", "Elle doit ralentir."),
        ("Y a personne.", "Il y a quelqu'un."),
        ("Y a personne.", "Il y a."),
        ("T'as raison.", "Tu as toujours raison."),
        ("Je la garde.", "Il la garde."),
        ("Elle vient peut-être avec un colis.", "Elle vient avec un colis."),
        ("Le couloir reste presque toujours vide.", "Le couloir reste toujours vide."),
    ])
    func completionDoesNotLicenseOtherChanges(heard: String, written: String) {
        #expect(FidelityGuard.check(transcript: heard, corrected: written) == heard)
    }

    @Test(arguments: [
        "Faille critique.", "La personne y a pensé.", "Il y a trois marches.", "Il faut ralentir.",
        "« Faut ralentir. Y a personne. »", "\"T'as raison\"", "`faut`", "« Faut patienter",
        "‘Faut ralentir.’", "'Y a personne.'", "« ce terme »faut", "« phrase » y a",
        "~~~\nFaut ralentir.\n~~~", "\"Citation\nFaut ralentir.\"",
        "https://example.org/faut", "faut@example.org", "Il faut plus de lumière.",
    ])
    func referencePreservesOtherConstructionsAndLiterals(_ text: String) {
        #expect(WrittenGrammar.reference(text) == text)
    }

    @Test func referenceIsOnlyAnAllowanceAndNeverTheFallbackText() {
        let heard = "Faut ralentir."
        #expect(FidelityGuard.check(transcript: heard, corrected: "Je souhaite réserver une table au restaurant.") == heard)
        #expect(FidelityGuard.check(transcript: heard, corrected: heard) == heard)
        #expect(FidelityGuard.check(transcript: heard, corrected: "Il faut ralentir.", language: .english) == heard)
    }

    @Test func oversizedComparisonDoesNotApproveAnExpansion() {
        let heard = "Faut patienter. " + String(repeating: "Le panneau reste bleu. ", count: 130)
        let expanded = heard + String(repeating: "Une voiture traverse la place. ", count: 50)
        #expect(FidelityGuard.check(transcript: heard, corrected: expanded) == heard)
    }

    @Test func oneCorrectionCallKeepsGrammarAndFormattingTogether() async throws {
        actor Counter {
            var calls = 0
            func increment() { calls += 1 }
        }
        let counter = Counter()
        let heard = "Faut pas traverser."
        let written = "Il ne faut pas traverser."
        let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: "",
                                   language: .french, keyterms: [], prompt: "", cleanupKey: "fixture", cleanupRelay: .off)
        let request = CorrectionRequest(transcript: heard)
        let outcome = await TextCleaner.clean(transcript: heard, request: request, speech: speech, enabled: true) { call in
            await counter.increment()
            let payload: [String: Any] = ["choices": [["message": ["content": written], "finish_reason": "stop"]],
                                           "usage": ["prompt_tokens": 10, "completion_tokens": 7]]
            return (try JSONSerialization.data(withJSONObject: payload),
                    HTTPURLResponse(url: call.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(outcome.text == written)
        #expect(await counter.calls == 1)
        #expect(outcome.usage?.succeeded == true)
        let disabled = await TextCleaner.clean(transcript: heard, request: request, speech: speech, enabled: false) { _ in
            await counter.increment()
            throw URLError(.badServerResponse)
        }
        #expect(disabled.text == heard)
        #expect(await counter.calls == 1)
    }
}
