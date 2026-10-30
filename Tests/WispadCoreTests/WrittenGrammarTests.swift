import Foundation
import Testing
@testable import WispadCore

struct WrittenGrammarTests {
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
        ("J'sais pas.", "Je ne sais pas."),
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
