import Testing
@testable import WispadCore

/// « Quand tu parles de toi » : seul ce qui se rapporte à « je » s'accorde, et seulement quand l'oreille ne fait pas la
/// différence. Le reste de la phrase ne bouge jamais.
struct SpeakerAgreementTests {
    private func feminine(_ text: String, _ language: DictationLanguage = .french) -> String {
        SpeakerAgreementRule.apply(text, agreement: .feminine, language: language)
    }

    private func masculine(_ text: String) -> String {
        SpeakerAgreementRule.apply(text, agreement: .masculine, language: .french)
    }

    @Test(arguments: [
        ("Je suis allé au marché.", "Je suis allée au marché."),
        ("Je me suis trompé de numéro.", "Je me suis trompée de numéro."),
        ("Désolé, je suis vraiment désolé.", "Désolé, je suis vraiment désolée."),
        ("Ce soir je suis seul.", "Ce soir je suis seule."),
        ("Hier j'étais très fatigué.", "Hier j'étais très fatiguée."),
        ("Je ne suis pas encore arrivé.", "Je ne suis pas encore arrivée."),
        ("j'suis parti tôt", "j'suis partie tôt"),
        ("Je me sens perdu.", "Je me sens perdue."),
        ("Je suis resté tranquille.", "Je suis restée tranquille."),
        ("Je me suis senti mal.", "Je me suis sentie mal."),
        ("Je suis né à Lyon.", "Je suis née à Lyon."),
        ("J'ai été surpris et je suis déçu.", "J'ai été surpris et je suis déçue."),
        ("Je suis très professionnel.", "Je suis très professionnelle."),
    ])
    func feminineAgreesWhatSoundsTheSame(input: String, expected: String) {
        #expect(feminine(input) == expected)
    }

    @Test(arguments: [
        // Prononcés différemment : déjà entendus, rien à deviner.
        "Je suis prêt.", "Je suis content.", "Je suis heureux.",
        // Quelqu'un d'autre.
        "Tu es allé où ?", "Il est parti.", "Nous sommes arrivés.", "On est fatigué.",
        // Participe suivi de son complément d'objet.
        "Je me suis lavé les mains.", "Je me suis acheté une voiture.",
        // Avoir, « suivre », nom, nom propre, pluriel.
        "J'ai mangé.", "Je suis le cours.", "Je suis à côté.", "Je suis Michel.", "Je suis là.",
    ])
    func feminineLeavesTheRestAlone(input: String) {
        #expect(feminine(input) == input)
    }

    @Test func feminineIsIdempotent() {
        let once = feminine("Je suis allé, puis je me suis trompé.")
        #expect(once == "Je suis allée, puis je me suis trompée.")
        #expect(feminine(once) == once)
    }

    @Test(arguments: [
        ("Je suis allée au marché.", "Je suis allé au marché."),
        ("Je me suis trompée.", "Je me suis trompé."),
        ("Je suis seule ce soir.", "Je suis seul ce soir."),
        ("Je suis partie hier.", "Je suis parti hier."),
        ("Je suis très professionnelle.", "Je suis très professionnel."),
    ])
    func masculineAgreesWhatSoundsTheSame(input: String, expected: String) {
        #expect(masculine(input) == expected)
    }

    @Test(arguments: ["Je suis belle.", "Je suis nouvelle ici.", "C'est une bonne idée.", "Elle est partie."])
    func masculineLeavesTheRestAlone(input: String) {
        #expect(masculine(input) == input)
    }

    @Test func asHeardAndEnglishChangeNothing() {
        #expect(SpeakerAgreementRule.apply("Je suis allé.", agreement: .asHeard, language: .french) == "Je suis allé.")
        #expect(feminine("I am tired.", .english) == "I am tired.")
        #expect(feminine("Je suis allé.", .english) == "Je suis allé.")
        #expect(feminine("Bon, je suis allé au cinéma avec Paul.", .auto) == "Bon, je suis allée au cinéma avec Paul.")
    }

    @Test func promptAsksForTheChosenAgreementInFrenchOnly() {
        var request = CorrectionRequest(transcript: "je suis allé au marché")
        #expect(!CorrectionPrompt.system(for: request).contains("parle d'elle au"))
        request.speakerAgreement = .feminine
        #expect(CorrectionPrompt.system(for: request).contains("parle d'elle au féminin"))
        request.speakerAgreement = .masculine
        #expect(CorrectionPrompt.system(for: request).contains("parle d'elle au masculin"))
        request.language = .english
        request.transcript = "I went to the market"
        #expect(!CorrectionPrompt.system(for: request).contains("parle d'elle"))
        request.language = .french
        request.commandSelection = "Texte sélectionné"
        #expect(!CorrectionPrompt.system(for: request).contains("parle d'elle"))
    }
}
