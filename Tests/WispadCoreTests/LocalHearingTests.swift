import Testing
@testable import WispadCore

/// Exemples inventés : seconde écoute sur le Mac, passages retenus pour la correction.
struct LocalHearingTests {
    private let known: (String) -> Bool = { word in
        !["juridicale", "serveurlesse", "serveurless", "tournerner"].contains(word.lowercased())
    }

    @Test func aDifferentEverydayPhraseIsKept() {
        let found = LocalHearing.divergences(transcript: "Il fait voir le matin, c'est un souci, tu vois.",
                                             hearing: "Il fait noir le matin, si t'as un souci, tu vois.",
                                             knownWord: known)
        #expect(found.map(\.heard) == ["fait voir le", "matin, c'est un"])
        #expect(found.map(\.local) == ["fait noir le", "matin, si t'as un"])
    }

    @Test(arguments: [
        // Nom propre, marque ou terme technique de la transcription : jamais remplacés.
        ("On écrit à Bastien demain.", "On écrit à bas tiens demain."),
        ("Passe par Vercel pour ça.", "Passe par verseau pour ça."),
        ("Ouvre le repo GitHub ce soir.", "Ouvre le ro GitHub ce soir."),
        ("Garde la RTX 5080 au frais.", "Garde la rt 50 80 au frais."),
        // Nombres, unités et symboles : affaire de mise en forme.
        ("Ça coûte 20 € par mois.", "Ça coûte vingt euros par mois."),
        ("Il reste cinq minutes.", "Il reste 5 min."),
        // Même mot à l'accord près, ou mot inventé par la seconde écoute.
        ("Les tests fonctionnent bien.", "Les tests fonctionne bien."),
        ("Change de forme juridique demain.", "Change de forme juridicale demain."),
        // Seuls des petits mots diffèrent.
        ("Je le vois demain.", "Je la vois demain."),
    ])
    func noiseIsDropped(transcript: String, hearing: String) {
        #expect(LocalHearing.divergences(transcript: transcript, hearing: hearing, knownWord: known,
                                         isTerm: { ["repo", "boots", "unlock"].contains($0.lowercased()) },
                                         protectedTerms: ["fastmode"]).isEmpty)
    }

    @Test func aProtectedTermStaysEvenInLowercase() {
        #expect(LocalHearing.divergences(transcript: "Tu vas retirer fastmode et Nova.", hearing: "Tu vas retirer fast mode et Nova.",
                                         knownWord: known, protectedTerms: ["fastmode"] + TechVocabulary.correction).isEmpty)
    }

    @Test func twoUnknownWordsLetTheModelDecide() {
        let found = LocalHearing.divergences(transcript: "Fais du serveurlesse sur le site.",
                                             hearing: "Fais du serveurless sur le site.", knownWord: known)
        #expect(found == [LocalDivergence(heard: "du serveurlesse sur", local: "du serveurless sur")])
    }

    @Test func aHearingThatLostTrackGivesNothing() {
        let transcript = (1...12).map { "mot\($0) chose" }.joined(separator: " ")
        let hearing = (1...12).map { "mot\($0) truc" }.joined(separator: " ")
        #expect(LocalHearing.divergences(transcript: transcript, hearing: hearing, knownWord: nil).isEmpty)
    }

    @Test func thePromptListsThePassagesAfterTheirRule() {
        var request = CorrectionRequest(transcript: "Il fait voir le matin.")
        request.localDivergences = [LocalDivergence(heard: "Il fait voir le matin.", local: "Il fait noir le matin.")]
        let text = CorrectionPrompt.userText(request)
        #expect(text.contains("seconde écoute du même audio"))
        #expect(text.contains("- « Il fait voir le matin. » / « Il fait noir le matin. »"))
        #expect(!CorrectionPrompt.userText(CorrectionRequest(transcript: "Bonjour.")).contains("seconde écoute"))
    }

    @Test func aWordTakenFromTheSecondHearingIsNotAnInvention() {
        let corrected = FidelityGuard.check(transcript: "Il fait voir le matin, c'est un souci, tu vois.",
                                            corrected: "Il fait noir le matin, si tu as un souci, tu vois.",
                                            otherHearings: ["fait noir le", "matin, si t'as un"])
        #expect(corrected == "Il fait noir le matin, si tu as un souci, tu vois.")
    }
}
