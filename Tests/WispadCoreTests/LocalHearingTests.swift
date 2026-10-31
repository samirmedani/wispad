import Testing
@testable import WispadCore

/// Exemples inventés : seconde écoute sur le Mac, passages retenus pour la correction.
struct LocalHearingTests {
    private let known: (String) -> Bool = { word in
        !["juriqueidique", "computarius", "computeruse", "tournerner"].contains(word.lowercased())
    }

    @Test func aDifferentEverydayPhraseIsKept() {
        let found = LocalHearing.divergences(transcript: "Faut voter développeur, c'est un problème, tu codes.",
                                             hearing: "Si t'es développeur, si t'as un problème, tu codes.",
                                             knownWord: known)
        #expect(found.map(\.heard) == ["Faut voter développeur,", "développeur, c'est un"])
        #expect(found.map(\.local) == ["Si t'es développeur,", "développeur, si t'as un"])
    }

    @Test(arguments: [
        // Nom propre, marque ou terme technique de la transcription : jamais remplacés.
        ("On écrit à Lulu demain.", "On écrit à le lieu demain."),
        ("Passe par DeepSeek pour ça.", "Passe par dick pour ça."),
        ("Ouvre le repo GitHub ce soir.", "Ouvre le ro GitHub ce soir."),
        ("Garde la RTX 5080 au frais.", "Garde la rt 50 80 au frais."),
        // Nombres, unités et symboles : affaire de mise en forme.
        ("Ça coûte 20 € par mois.", "Ça coûte vingt euros par mois."),
        ("Il reste cinq minutes.", "Il reste 5 min."),
        // Même mot à l'accord près, ou mot inventé par la seconde écoute.
        ("Les tests fonctionnent bien.", "Les tests fonctionne bien."),
        ("Change de forme juridique demain.", "Change de forme juriqueidique demain."),
        // Seuls des petits mots diffèrent.
        ("Je le vois demain.", "Je la vois demain."),
    ])
    func noiseIsDropped(transcript: String, hearing: String) {
        #expect(LocalHearing.divergences(transcript: transcript, hearing: hearing, knownWord: known,
                                         isTerm: { ["repo", "boots", "unlock"].contains($0.lowercased()) },
                                         protectedTerms: ["xhigh"]).isEmpty)
    }

    @Test func aProtectedTermStaysEvenInLowercase() {
        #expect(LocalHearing.divergences(transcript: "Tu vas retirer xhigh et Mimo.", hearing: "Tu vas retirer XI et Mimo.",
                                         knownWord: known, protectedTerms: ["xhigh"] + TechVocabulary.correction).isEmpty)
    }

    @Test func twoUnknownWordsLetTheModelDecide() {
        let found = LocalHearing.divergences(transcript: "Fais du computarius sur le site.",
                                             hearing: "Fais du computeruse sur le site.", knownWord: known)
        #expect(found == [LocalDivergence(heard: "du computarius sur", local: "du computeruse sur")])
    }

    @Test func aHearingThatLostTrackGivesNothing() {
        let transcript = (1...12).map { "mot\($0) chose" }.joined(separator: " ")
        let hearing = (1...12).map { "mot\($0) truc" }.joined(separator: " ")
        #expect(LocalHearing.divergences(transcript: transcript, hearing: hearing, knownWord: nil).isEmpty)
    }

    @Test func thePromptListsThePassagesAfterTheirRule() {
        var request = CorrectionRequest(transcript: "Faut voter développeur.")
        request.localDivergences = [LocalDivergence(heard: "Faut voter développeur.", local: "Si t'es développeur.")]
        let text = CorrectionPrompt.userText(request)
        #expect(text.contains("seconde écoute du même audio"))
        #expect(text.contains("- « Faut voter développeur. » / « Si t'es développeur. »"))
        #expect(!CorrectionPrompt.userText(CorrectionRequest(transcript: "Bonjour.")).contains("seconde écoute"))
    }

    @Test func aWordTakenFromTheSecondHearingIsNotAnInvention() {
        let corrected = FidelityGuard.check(transcript: "Faut voter développeur, c'est un problème, tu codes.",
                                            corrected: "Si tu es développeur, si tu as un problème, tu codes.",
                                            otherHearings: ["Si t'es développeur, si t'as un"])
        #expect(corrected == "Si tu es développeur, si tu as un problème, tu codes.")
    }
}
