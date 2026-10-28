import Foundation
import Testing
@testable import WispadCore

/// Un pourcentage dit que la correction a perdu : le « % » revient, sans jamais toucher un autre nombre.
@Suite struct PercentRestoreTests {
    private func restore(_ heard: String, _ corrected: String) -> String {
        FidelityGuard.restoreDroppedPercents(heard: heard, corrected: corrected)
    }

    @Test func dictationOfOctober28GetsItsPercentBack() {
        #expect(restore("Renseigne-toi mon ref, je suis sûr à cent pour cent.", "Renseigne-toi mon ref, je suis sûr à 100.")
                == "Renseigne-toi mon ref, je suis sûr à 100%.")
        #expect(restore("le taux passe à quinze pour cent", "Le taux passe à 15.") == "Le taux passe à 15%.")
        #expect(restore("le taux passe à 15 %", "Le taux passe à 15.") == "Le taux passe à 15%.")
        #expect(restore("deux virgule cinq pour cent de remise", "2,5 de remise.") == "2,5% de remise.")
        #expect(restore("i'm one hundred percent sure", "I'm 100 sure.") == "I'm 100% sure.")
    }

    @Test func onlyTheNumberThatWasAPercentChanges() {
        #expect(restore("j'ai payé cent euros et je suis sûr à cent pour cent", "J'ai payé 100 € et je suis sûr à 100.")
                == "J'ai payé 100 € et je suis sûr à 100%.")
        #expect(restore("cent pour cent des cent clients", "100 des 100 clients.") == "100% des 100 clients.")
    }

    @Test func nothingChangesWhenThePercentIsThereOrTheNumberMoved() {
        for (heard, corrected) in [
            ("je suis sûr à cent pour cent", "Je suis sûr à 100 %."),
            ("je suis sûr à cent pour cent", "Je suis sûr à 100 pour cent."),
            ("je suis sûr à cent pour cent", "J'en suis certain."),
            ("je suis sûr à cent pour cent", "Je suis sûr à cent pour cent."),
            ("je l'ai eu pour cent euros", "Je l'ai eu pour 100 €."),
            ("on se voit le vingt-quatre à quinze heures", "On se voit le 24 à 15 h."),
            ("cent pour cent des cent clients", "Tous les 100 clients."),
        ] {
            #expect(restore(heard, corrected) == corrected, "\(corrected)")
        }
    }

    /// Toute la chaîne : le modèle rend « à 100. », la dictée colle « 100 % » au format choisi.
    @Test func cleanupChainWritesThePercentInTheChosenFormat() async {
        let transcript = "Frérot, je te fais confiance, vas-y. Renseigne-toi mon ref, je suis sûr à cent pour cent."
        let reply = "Frérot, je te fais confiance, vas-y. Renseigne-toi mon ref, je suis sûr à 100."
        let transport: TextCleaner.HTTPTransport = { request in
            let body = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": reply], "finish_reason": "stop"]],
                "usage": ["prompt_tokens": 10, "completion_tokens": 10]
            ])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var speech = SpeechRequest(provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0",
                                   apiKey: "", language: .french, keyterms: [], prompt: "")
        speech.cleanupKey = "cle-de-test"
        speech.cleanupRelay = .off
        let outcome = await TextCleaner.clean(transcript: transcript, request: CorrectionRequest(transcript: transcript, language: .french),
                                              speech: speech, enabled: true, transport: transport)
        #expect(outcome.text.range(of: #"sûr à 100[ \x{00A0}\x{202F}]%\.$"#, options: .regularExpression) != nil, "\(outcome.text)")
    }
}
