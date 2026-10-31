import Testing
@testable import WispadCore

/// Exemples inventés : une correction fluide ne doit pas escamoter une nuance ou un complément court. Le mot
/// retiré reprend sa place dans la correction, qui garde ses autres retouches.
struct ShortDeletionGuardTests {
    @Test(arguments: [
        ("Le plan reste vraiment utile demain.", "Le plan reste utile demain.", "Le plan reste vraiment utile demain."),
        ("La méthode reste, assez franchement, stable depuis hier.", "La méthode reste stable depuis hier.",
         "La méthode reste assez franchement stable depuis hier."),
        ("Le plan reste dans ce cas utile demain.", "Le plan reste utile demain.", "Le plan reste dans ce cas utile demain."),
        ("The plan is genuinely useful for tomorrow.", "The plan is useful for tomorrow.",
         "The plan is genuinely useful for tomorrow."),
        ("Le plan reste clair et sera prêt lundi.", "Le plan reste clair sera prêt lundi.",
         "Le plan reste clair et sera prêt lundi."),
    ])
    func anInternalMeaningfulDeletionIsRestored(transcript: String, corrected: String, expected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == expected)
    }

    /// Ce qu'une réécriture fidèle retire d'une dictée orale : la correction est gardée telle quelle.
    @Test(arguments: [
        ("Je pense pas qu'on a besoin d'aide.", "Je pense qu'on n'a pas besoin d'aide."),
        ("Regarde si y a des, si t'as des fichiers à trier.", "Regarde si tu as des fichiers à trier."),
        ("On garde les les mmh les trois dossiers.", "On garde les trois dossiers."),
        ("Le taux atteint 12 pour 100 cette année.", "Le taux atteint 12 % cette année."),
        ("Il a déjà une petite, un un manteau pour sortir.", "Il a déjà un manteau pour sortir."),
        ("Le fichier est prêt et je pars demain matin.", "Le fichier est prêt. Je pars demain matin."),
        ("Le tri est fini. Et je, est-ce que tu peux vérifier ?", "Le tri est fini. Est-ce que tu peux vérifier ?"),
        ("Ça redirige vers le site v de Paul.", "Ça redirige vers le site de Paul."),
        ("Le dossier est en gros prêt genre demain.", "Le dossier est prêt demain."),
        ("Tu vois le button là du bouton bleu ?", "Tu vois le bouton bleu ?"),
    ])
    func oralRewritesKeepTheCorrection(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == corrected)
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
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected)
                == "Bonjour.\n\nLa méthode reste assez franchement stable depuis hier.")
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
                                    corrected: "Pour demain prends :\n- Pommes\n- Poires.\nLe plan reste stable depuis hier.")
                == "Pour demain prends :\n- Pommes\n- Poires.\nLe plan reste assez franchement stable depuis hier.")
        let prose = "Pour demain prends pommes et poires. Le plan reste clair et sera prêt lundi."
        #expect(FidelityGuard.check(transcript: prose,
                                    corrected: "Pour demain prends :\n- Pommes\n- Poires.\nLe plan reste clair sera prêt lundi.")
                == "Pour demain prends :\n- Pommes\n- Poires.\nLe plan reste clair et sera prêt lundi.")
    }

    @Test func anAddedNegationDoesNotCompensateForLostContent() {
        let transcript = "On sait pas si le plan est vraiment utile demain."
        #expect(FidelityGuard.check(transcript: transcript, corrected: "On ne sait pas si le plan est utile demain.")
                == "On ne sait pas si le plan est vraiment utile demain.")
    }

    @Test func anImmediatelyRepeatedNominalSubjectCanBeRemoved() {
        let transcript = "Le voyant il est bleu. Les 3 premières rangées elles sont libres."
        let corrected = "Le voyant est bleu. Les trois premières rangées sont libres."
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == corrected)
    }

    @Test func subjectCleanupDoesNotExcuseLostMeaning() {
        let transcript = "Le voyant il est assez franchement stable depuis hier."
        #expect(FidelityGuard.check(transcript: transcript, corrected: "Le voyant est stable depuis hier.")
                == "Le voyant est assez franchement stable depuis hier.")
        let separateSubject = "Le plan avance et il est utile demain."
        #expect(FidelityGuard.check(transcript: separateSubject, corrected: "Le plan avance et est utile demain.") == separateSubject)
        let clitic = "Je le vois il est prêt pour demain."
        #expect(FidelityGuard.check(transcript: clitic, corrected: "Je le vois est prêt pour demain.") == clitic)
    }
}
