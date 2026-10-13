import Foundation
import Testing
@testable import WispadCore

/// Montants, pourcentages, mesures et téléphones : ce qui change, et surtout ce qui ne doit pas bouger.
struct NumberFormatTests {
    private let nb = "\u{00A0}"
    private let thin = "\u{202F}"
    private func french(_ text: String, _ format: DictationNumberFormat = DictationNumberFormat()) -> String {
        NumberWriter.apply(text, format: format, english: false)
    }
    private func english(_ text: String, _ format: DictationNumberFormat = DictationNumberFormat()) -> String {
        NumberWriter.apply(text, format: format, english: true)
    }

    @Test func frenchAmountsTakeTheirSymbolAfterANoBreakSpace() {
        #expect(french("Ça coûte 25 euros.") == "Ça coûte 25\(nb)€.")
        #expect(french("Ça coûte 25€.") == "Ça coûte 25\(nb)€.")
        #expect(french("Un loyer de 1500 €.") == "Un loyer de 1\(thin)500\(nb)€.")
        #expect(french("Un café à 3,5 € et un autre à 3.50 €.") == "Un café à 3,50\(nb)€ et un autre à 3,50\(nb)€.")
        #expect(french("Il gagne 12.500 € par an.") == "Il gagne 12\(thin)500\(nb)€ par an.")
        #expect(french("Ça fait $3.50 là-bas.") == "Ça fait 3,50\(nb)$ là-bas.")
        #expect(french("On est à 15% de remise, 100 pour cent d'accord.") == "On est à 15\(nb)% de remise, 100\(nb)% d'accord.")
    }

    @Test func frenchMeasuresUseTheirSymbol() {
        #expect(french("J'ai couru 5 kilomètres à 12 kilomètres par heure.") == "J'ai couru 5\(nb)km à 12\(nb)km/h.")
        #expect(french("Un appartement de 120 mètres carrés.") == "Un appartement de 120\(nb)m² .".replacingOccurrences(of: " .", with: "."))
        #expect(french("Il fait 20 degrés Celsius.") == "Il fait 20\(nb)°C.")
        #expect(french("Prends 16 gigaoctets de RAM à 6000 MHz.") == "Prends 16\(nb)Go de RAM à 6000\(nb)MHz.")
        #expect(french("Ajoute 250 grammes de farine.") == "Ajoute 250\(nb)g de farine.")
    }

    @Test func numbersThatAreNotQuantitiesNeverMove() {
        let untouched = [
            "En 2026, la RTX 4070 remplace le i7-12700K.",
            "Le code postal est 75001 Paris.",
            "Passe en version 2.1.295 ce soir.",
            "Les 3 l'ont vu, 5 m'ont écrit.",
            "Ça prend 5 min et 300 ms.",
            "Il dure 2 heures de route.",
            "La DDR5 6000 tient.",
            "C'est 12 500 personnes.",
            "Ajoute 18 modules de 16 gigas.",
        ]
        for text in untouched { #expect(french(text) == text) }
        #expect(english("It costs 3,50 € there.") == "It costs 3,50 € there.")
    }

    /// La transcription vocale écrit parfois « et 1/2 » : on écrit « et demi », accordé au nom.
    @Test func spokenHalvesStayInWords() {
        #expect(french("Le chantier dure 2 mois et 1/2.") == "Le chantier dure 2 mois et demi.")
        #expect(french("Compte 1 heure et 1/2, voire 2 semaines et ½.") == "Compte 1 heure et demie, voire 2 semaines et demie.")
        #expect(french("Ajoute 1/2 litre d'eau, score 2 et 1/2.") == "Ajoute 1/2 litre d'eau, score 2 et 1/2.")
        #expect(english("It took 2 months and 1/2.") == "It took 2 months and 1/2.")
        #expect(DictationNumberFormat().instructions(english: false).contains("« deux mois et demi » → « 2 mois et demi »"))
    }

    @Test func frenchPhoneNumbersAreWrittenByPairs() {
        #expect(french("Appelle le 0612345678.") == "Appelle le 06 12 34 56 78.")
        #expect(french("Mon numéro : 06.12.34.56.78 ou 06-12-34-56-78.") == "Mon numéro : 06 12 34 56 78 ou 06 12 34 56 78.")
        #expect(french("Écris au +33612345678 ou au +33 (0)6 12 34 56 78.") == "Écris au +33 6 12 34 56 78 ou au +33 6 12 34 56 78.")
        // Trop long, collé à une adresse ou à un identifiant : ce n'est pas un téléphone.
        #expect(french("Commande 061234567890 reçue.") == "Commande 061234567890 reçue.")
        #expect(french("Écris à 0612345678@sms.fr.") == "Écris à 0612345678@sms.fr.")
        #expect(french("La facture FR0612345678 est payée.") == "La facture FR0612345678 est payée.")
    }

    @Test func thousandsSeparatorFollowsTheSetting() {
        #expect(french("Un loyer de 1500 €.", DictationNumberFormat(thousands: .space)) == "Un loyer de 1 500\(nb)€.")
        #expect(french("Un loyer de 1500 €.", DictationNumberFormat(thousands: .none)) == "Un loyer de 1500\(nb)€.")
        #expect(english("It costs 1500 dollars.") == "It costs $1,500.")
    }

    @Test func wordsInsteadOfSymbolsWhenAsked() {
        let words = DictationNumberFormat(symbols: false)
        #expect(french("Ça coûte 25 € et 1 €.", words) == "Ça coûte 25 euros et 1 euro.")
        #expect(french("Un café à 1,5 €.", words) == "Un café à 1,50 euro.")
        #expect(french("J'ai couru 5 km.", words) == "J'ai couru 5 kilomètres.")
        // Une lettre seule n'est pas récrite : « 5 m » pourrait vouloir dire autre chose.
        #expect(french("Il reste 5 m.", words) == "Il reste 5 m.")
        #expect(french("Une remise de 15 %.", words) == "Une remise de 15\(nb)%.")
        #expect(english("It costs $25.", words) == "It costs 25 dollars.")
    }

    @Test func englishUsesItsOwnConventions() {
        #expect(english("It costs 25 dollars, or 25 €.") == "It costs $25, or €25.")
        #expect(english("A $3.5 coffee.") == "A $3.50 coffee.")
        #expect(english("About 15 percent off.") == "About 15% off.")
        #expect(english("I ran 5 kilometers.") == "I ran 5\(nb)km.")
    }

    @Test func samplesAndInstructionsUseTheChosenFormat() {
        #expect(DictationNumberFormat().samples(english: false) == ["12\(thin)500\(nb)€", "3,50\(nb)€", "15\(nb)%", "5\(nb)km"])
        #expect(DictationNumberFormat().samples(english: true) == ["€12,500", "$3.50", "15%", "5\(nb)km"])
        let french = DictationNumberFormat().instructions(english: false)
        #expect(french.contains("« vingt-cinq euros » → « 25\(nb)€ »"))
        #expect(french.contains("→ « 06 12 34 56 78 »"))
        #expect(french.contains("Ne regroupe jamais les chiffres d'une année"))
        let words = DictationNumberFormat(symbols: false).instructions(english: false)
        #expect(words.contains("« cinq kilomètres » → « 5 kilomètres »"))
        #expect(DictationNumberFormat().instructions(english: true).contains("\"twenty-five dollars\" → \"$25\""))
        var request = CorrectionRequest(transcript: "x")
        request.numberFormat = DictationNumberFormat(thousands: .space)
        #expect(CorrectionPrompt.system(for: request).contains("« douze mille cinq cents habitants » → « 12 500 habitants »"))
    }

    @Test func oldSettingsAreReadLeniently() throws {
        let decoded = try JSONDecoder().decode(DictationNumberFormat.self, from: Data(#"{"thousands": "futur", "symbols": false}"#.utf8))
        #expect(decoded == DictationNumberFormat(thousands: .byLanguage, symbols: false))
        #expect(try JSONDecoder().decode(DictationNumberFormat.self, from: Data("{}".utf8)) == DictationNumberFormat())
    }

    /// Le garde-fou garde un symbole d'unité au lieu de le prendre pour un nom inventé.
    @Test func theGuardKeepsUnitSymbols() {
        #expect(FidelityGuard.check(transcript: "il fait vingt degrés celsius", corrected: "Il fait 20 °C.") == "Il fait 20 °C.")
        #expect(FidelityGuard.check(transcript: "ça coûte vingt-cinq euros", corrected: "Ça coûte 25 €.") == "Ça coûte 25 €.")
        #expect(FidelityGuard.check(transcript: "une conso de trois kilowattheures", corrected: "Une conso de 3 kWh.") == "Une conso de 3 kWh.")
        #expect(FidelityGuard.check(transcript: "écris à jean point dupont arobase gmail point com",
                                    corrected: "Écris à jean.dupont@gmail.com.") == "Écris à jean.dupont@gmail.com.")
    }

    @Test func theCorrectionOutputTakesTheNumberFormatAfterTheGuard() async {
        let stub = NumberFormatHTTPStub(reply: "Le loyer est de 1500 euros, appelle le 0612345678.")
        var request = CorrectionRequest(transcript: "le loyer est de mille cinq cents euros appelle le zéro six douze trente-quatre cinquante-six soixante-dix-huit")
        request.numberFormat = DictationNumberFormat(thousands: .space)
        let speech = SpeechRequest(provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture-vocal",
                                   language: .french, keyterms: [], prompt: "", cleanupKey: "fixture-primary")
        let outcome = await TextCleaner.clean(transcript: request.transcript, request: request, speech: speech, enabled: true,
                                              transport: { try await stub.request($0) })
        #expect(outcome.text == "Le loyer est de 1 500\(nb)€, appelle le 06 12 34 56 78.")
        #expect(await stub.system.contains("Nombres, montants et unités"))
    }
}

/// Correction simulée : aucune clé réelle ni réseau.
private actor NumberFormatHTTPStub {
    let reply: String
    private(set) var system = ""

    init(reply: String) { self.reply = reply }

    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let messages = body?["messages"] as? [[String: String]] ?? []
        system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        let payload: [String: Any] = [
            "choices": [["message": ["content": reply], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
