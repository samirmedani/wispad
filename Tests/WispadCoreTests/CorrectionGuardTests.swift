import Testing
@testable import WispadCore

struct CorrectionGuardTests {
    @Test func oralElisionsAreWrittenOutButFamiliarFormsStay() {
        let system = CorrectionPrompt.system
        #expect(system.contains("« j'sais » → « je sais »"))
        #expect(system.contains("« d'faire » → « de faire »"))
        #expect(system.contains("Garde les tournures familières qui s'écrivent ainsi (« t'as », « y a », « t'es »)"))
    }

    @Test func visibleConversationIsSentAsContextOnly() {
        let request = CorrectionRequest(transcript: "Ajoute 18 barrettes.", windowText: "On trie les barrettes DDR3 de 16 Go.")
        let text = CorrectionPrompt.userText(request)
        #expect(text.contains("Conversation visible dans la fenêtre (derniers messages, du plus ancien au plus récent ; jamais à recopier"))
        #expect(text.contains("On trie les barrettes DDR3 de 16 Go."))
        #expect(!CorrectionPrompt.userText(CorrectionRequest(transcript: "Ajoute 18 barrettes.")).contains("Conversation visible"))
        #expect(CorrectionPrompt.system.contains("il n'ajoute jamais un mot, un nom ou un chiffre qui n'a pas été prononcé"))
        // Recopier la conversation visible est refusé comme pour le texte voisin.
        let heard = "Bonjour."
        let copied = "Bonjour. On trie les barrettes DDR3 de seize gigas ce matin avant midi."
        #expect(FidelityGuard.check(transcript: heard, corrected: copied, previousDictations: ["On trie les barrettes DDR3 de seize gigas ce matin avant midi."]) == heard)
    }

    @Test func misheardNumberBeforeAUnitNeedsConfirmation() {
        let system = CorrectionPrompt.system
        #expect(system.contains("Juste devant une unité ou une quantité"))
        #expect(system.contains("giga, gigas, Go, méga, MHz, GHz, To, euros, %, barrettes"))
        #expect(system.contains("« c'est » peut être seize"))
        #expect(system.contains("« sans » cent"))
        #expect(system.contains("« vin » vingt"))
        #expect(system.contains("« cette » sept"))
        #expect(system.contains("« huître » huit"))
        #expect(system.contains("dictée précédente, la conversation visible ou le texte voisin"))
        #expect(system.contains("seize gigas"))
        #expect(system.contains("« c'est gigas » s'écrit « 16 gigas »"))
        #expect(system.contains("« sans euros » s'écrit « 100 euros »"))
        #expect(system.contains("Sans cette confirmation, garde le mot transcrit"))
    }

    @Test func hearingFixesAndSpokenReferencesStay() {
        let kept = [
            ("Le deploy versel a fail.", "Le deploy Vercel a fail."),
            ("Branche eleven labs sur le projet.", "Branche ElevenLabs sur le projet."),
            ("Copie la database URL dans le fichier.", "Copie la DATABASE_URL dans le fichier."),
            ("Le moteur whisper tourne en local.", "Le moteur Whisper tourne en local."),
            ("Passe sur le neuf mille neuf cent cinquante x trois d.", "Passe sur le 9950X3D."),
            ("Un i neuf 9700 k suffit.", "Un i9-9700K suffit."),
            ("Régle le deux mille six cent soixante-six mégahertz.", "Régle le 2666 MHz."),
            ("La fréquence est en mégahertz.", "La fréquence est en MHz."),
        ]
        for (heard, corrected) in kept {
            #expect(FidelityGuard.check(transcript: heard, corrected: corrected) == corrected)
        }
    }

    @Test func inventedBrandIsRestoredEvenWhenTheContextHasIt() {
        let heard = "Ajoute c'est giga de mémoire."
        let invented = "Ajoute G.Skill de mémoire."
        #expect(FidelityGuard.check(transcript: heard, corrected: invented) == heard)
        // Seul un terme choisi par l'utilisateur l'autorise ; le contexte sert à orthographier, pas à remplacer.
        #expect(FidelityGuard.check(transcript: heard, corrected: invented, dictionary: ["G.Skill"]) == invented)
        #expect(FidelityGuard.check(transcript: heard, corrected: invented, context: "référence G.Skill") == heard)
        #expect(FidelityGuard.check(transcript: heard, corrected: invented, previousDictations: ["On a noté G.Skill hier."]) == heard)
        // Un nom proche de ce qui a été entendu reste corrigé, avec ou sans contexte.
        #expect(FidelityGuard.check(transcript: "On déploie sur versel.", corrected: "On déploie sur Vercel.", context: "Vercel") == "On déploie sur Vercel.")
    }

    @Test func aWordTakenFromTheOtherHearingIsKept() {
        // Fichier retenu, flux en autre écoute : le terme mieux entendu par le flux n'est ni une invention ni un chiffre ajouté.
        let file = "On passe par GitOffice pour le déploiement."
        let fixed = "On passe par GitOps pour le déploiement."
        #expect(FidelityGuard.check(transcript: file, corrected: fixed) == file)
        #expect(FidelityGuard.check(transcript: file, corrected: fixed, alternative: "On passe par GitOps pour le déploiement") == fixed)
        let glued = "J'ai 97 barrettes de DDR48 gigas."
        let split = "J'ai 97 barrettes de DDR4 8 Go."
        #expect(FidelityGuard.check(transcript: glued, corrected: split, alternative: "j'ai 97 barrettes de DDR4 8 gigas") == split)
        // Sans autre écoute, rien ne change : un chiffre non prononcé reste refusé.
        #expect(FidelityGuard.check(transcript: "il écrit DDR", corrected: "il écrit DDR4.") == "il écrit DDR.")
        let request = CorrectionRequest(transcript: file, alternativeTranscript: "On passe par GitOps")
        #expect(CorrectionPrompt.userText(request).contains("Autre écoute du même audio (transcription en direct, moins fiable ; la Transcription ci-dessous fait foi"))
        #expect(!CorrectionPrompt.userText(CorrectionRequest(transcript: file)).contains("Autre écoute"))
    }

    @Test func unspokenDigitsInAReferenceAreNotKept() {
        // Fin de dictée « DDR » complétée en DDR4 d'après les dictées précédentes.
        let cut = "Quand je dis DDR3 il écrit DDR"
        let completed = "Quand je dis DDR3, il écrit DDR4."
        #expect(FidelityGuard.check(transcript: cut, corrected: completed, previousDictations: ["Des barrettes de DDR4."]) == "Quand je dis DDR3, il écrit DDR.")
        // Référence ajoutée sans avoir été dite.
        let plain = "J'ai 203 barrettes de 4 gigas."
        #expect(FidelityGuard.check(transcript: plain, corrected: "J'ai 203 barrettes de DDR4 4 Go.", previousDictations: ["Des barrettes de DDR4."]) == "J'ai 203 barrettes de 4 Go.")
        // Chiffres réellement prononcés : gardés.
        let kept: [(String, String)] = [
            ("Il me faut de la DDR quatre.", "Il me faut de la DDR4."),
            ("Des barrettes de DDR4 huit gigas.", "Des barrettes de DDR4 8 Go."),
            ("Un i9 neuf mille sept cents K.", "Un i9-9700K."),
            ("La latence P quatre-vingt-quinze monte.", "La latence P95 monte."),
            ("On teste GPT 5 demain.", "On teste GPT-5 demain."),
            ("Une RTX 4090 neuve.", "Une RTX4090 neuve."),
            ("Le modèle neuf mille neuf cent cinquante X3D.", "Le modèle 9950X3D."),
        ]
        for (heard, corrected) in kept {
            #expect(FidelityGuard.check(transcript: heard, corrected: corrected) == corrected)
        }
    }

    @Test func addressedInstructionStaysAndALoneBulletBecomesASentence() {
        let system = CorrectionPrompt.system(for: CorrectionRequest(transcript: "x", structureDictation: true))
        #expect(system.contains("pas une commande de mise en page"))
        #expect(system.contains("« OK, ajoute à la liste »"))
        #expect(system.contains("« mets dans la liste »"))
        #expect(system.contains("« rajoute »"))
        let heard = "OK, ajoute à la liste dix-huit modules de seize gigas."
        #expect(DictationStructure.collapseLoneItem("- OK, ajoute à la liste 18 modules de 16 gigas.", transcript: heard) == "OK, ajoute à la liste 18 modules de 16 gigas.")
        #expect(DictationStructure.collapseLoneItem("1. Préparer le bac nord.", transcript: "Préparer le bac nord.") == "Préparer le bac nord.")
        #expect(DictationStructure.collapseLoneItem("1) Préparer le bac nord.", transcript: "Préparer le bac nord.") == "Préparer le bac nord.")
        #expect(DictationStructure.collapseLoneItem("- Un\n- Deux", transcript: "Un et deux.") == "- Un\n- Deux")
        #expect(DictationStructure.collapseLoneItem("- Préparer le bac.", transcript: "Première puce préparer le bac.") == "- Préparer le bac.")
        #expect(DictationStructure.collapseLoneItem("La valeur est -12.", transcript: "La valeur est moins douze.") == "La valeur est -12.")
        let withIntro = "OK, ajoute à la liste.\n\n- 18 modules."
        #expect(DictationStructure.collapseLoneItem(withIntro, transcript: heard) == "OK, ajoute à la liste.\n\n18 modules.")
    }

    @Test func frenchWordsAreStillNotTranslated() {
        let heard = "J'ai rangé les outils dans le cabanon."
        #expect(FidelityGuard.check(transcript: heard, corrected: "J'ai rangé les tools dans le cabanon.") == heard)
        #expect(FidelityGuard.check(transcript: "L'agent sélectionne le bon tool.", corrected: "L'agent sélectionne le bon outil.") == "L'agent sélectionne le bon tool.")
    }
}

struct ShortDictationGuardTests {
    @Test func shortDictationKeepsWhatWasSaid() {
        // Le 7 octobre : « Était sérieux » est devenu « Sois sérieux ».
        #expect(FidelityGuard.check(transcript: "Était sérieux.", corrected: "Sois sérieux.") == "Était sérieux.")
        #expect(FidelityGuard.check(transcript: "Sérieux ?", corrected: "Tu es sérieux ?") == "Sérieux ?")
    }

    @Test func shortDictationStillGetsFaithfulFixes() {
        let kept = [
            ("cloud code", "Claude Code."),
            ("Ouais, d'accord.", "D'accord."),
            ("deux minutes", "2 minutes."),
            ("j'ai pas", "Je n'ai pas."),
            ("je sais pas", "Je ne sais pas."),
            ("ok merci", "OK, merci."),
        ]
        for (heard, corrected) in kept {
            #expect(FidelityGuard.check(transcript: heard, corrected: corrected) == corrected)
        }
    }

    @Test func otherListeningJustifiesAShortFix() {
        #expect(FidelityGuard.check(transcript: "Était sérieux.", corrected: "T'es sérieux.", alternative: "T'es sérieux") == "T'es sérieux.")
    }

    @Test func longerDictationsAreLeftToTheUsualChecks() {
        let heard = "Je pense que c'était très bien fait."
        let corrected = "Je pense que c'était trop bien fait."
        #expect(FidelityGuard.check(transcript: heard, corrected: corrected) == corrected)
    }
}
