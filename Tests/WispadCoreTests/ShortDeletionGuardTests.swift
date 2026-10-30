import Testing
@testable import WispadCore

/// Exemples inventés : une correction fluide ne doit pas escamoter une nuance ou un complément court.
struct ShortDeletionGuardTests {
    @Test(arguments: [
        ("Le plan reste vraiment utile demain.", "Le plan reste utile demain."),
        ("La méthode reste, assez franchement, stable depuis hier.", "La méthode reste stable depuis hier."),
        ("Le plan reste dans ce cas utile demain.", "Le plan reste utile demain."),
        ("The plan is genuinely useful for tomorrow.", "The plan is useful for tomorrow."),
    ])
    func anInternalMeaningfulDeletionKeepsTheTranscript(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == transcript)
    }

    @Test(arguments: [
        ("La méthode euh hum reste stable demain.", "La méthode reste stable demain."),
        ("La méthode reste reste stable demain.", "La méthode reste stable demain."),
        ("Je crois que je je je peux finir demain.", "Je crois que je peux finir demain."),
        ("On repart mardi, ah non, mercredi matin.", "On repart mercredi matin."),
        ("Envoie le dossier à Paul, pardon, à Julie demain.", "Envoie le dossier à Julie demain."),
        ("We leave Tuesday, no wait, Wednesday morning.", "We leave Wednesday morning."),
        ("On part le vingt-quatre octobre à quatorze heures trente.", "On part le 24/10 à 14h30."),
        ("Le trajet dure deux heures demain.", "Le trajet dure 2 heures demain."),
        ("Bonjour. Nouveau paragraphe. Le dossier est prêt.", "Bonjour.\n\nLe dossier est prêt."),
        ("Il faut première puce ranger la salle deuxième puce fermer la porte.", "Il faut\n- Ranger la salle\n- Fermer la porte."),
        ("Bonjour virgule le dossier est prêt.", "Bonjour, le dossier est prêt."),
    ])
    func legitimateCleanupAndFormattingRemain(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == corrected)
    }

    @Test func aFormattingCommandDoesNotExcuseAnUnrelatedDeletion() {
        let transcript = "Bonjour. Nouveau paragraphe. La méthode reste assez franchement stable depuis hier."
        let corrected = "Bonjour.\n\nLa méthode reste stable depuis hier."
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == transcript)
    }

    @Test func aMeaningfulCorrectionCueAloneStays() {
        let transcript = "Cette méthode est enfin disponible pour lundi."
        #expect(FidelityGuard.check(transcript: transcript, corrected: "Cette méthode est disponible pour lundi.") == transcript)
    }

    @Test func aSpokenPercentStillRegainsItsSymbol() {
        let transcript = "Le score atteint 100 pour cent dans cette série."
        #expect(FidelityGuard.check(transcript: transcript,
                                    corrected: "Le score atteint 100 dans cette série.")
                == "Le score atteint 100% dans cette série.")
        #expect(FidelityGuard.check(transcript: transcript, corrected: "Le score atteint 100 % dans cette série.")
                == "Le score atteint 100 % dans cette série.")
    }

    @Test func listLinksMayDisappearOnlyAtActualItemBoundaries() {
        #expect(FidelityGuard.check(transcript: "Pour demain prends pommes et poires et prunes.",
                                    corrected: "Pour demain prends :\n- Pommes\n- Poires\n- Prunes.")
                == "Pour demain prends :\n- Pommes\n- Poires\n- Prunes.")
        let transcript = "Pour demain prends pommes et poires. Le plan reste assez franchement stable depuis hier."
        #expect(FidelityGuard.check(transcript: transcript,
                                    corrected: "Pour demain prends :\n- Pommes\n- Poires.\nLe plan reste stable depuis hier.") == transcript)
        let prose = "Pour demain prends pommes et poires. Le plan reste clair et sera prêt lundi."
        #expect(FidelityGuard.check(transcript: prose,
                                    corrected: "Pour demain prends :\n- Pommes\n- Poires.\nLe plan reste clair sera prêt lundi.") == prose)
    }

    @Test func anAddedNegationDoesNotCompensateForLostContent() {
        let transcript = "On sait pas si le plan est vraiment utile demain."
        #expect(FidelityGuard.check(transcript: transcript, corrected: "On ne sait pas si le plan est utile demain.") == transcript)
    }
}
