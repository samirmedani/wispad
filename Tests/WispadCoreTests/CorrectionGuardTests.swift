import Testing
@testable import WispadCore

struct CorrectionGuardTests {
    /// Un grand dictionnaire ne ralentit pas une correction ordinaire : ses mots ne sont relus que pour vérifier un nom
    /// d'allure inventée. Avant, chaque correction (jusqu'à six par dictée) les découpait tous : 20 ms pour 2 000 termes,
    /// mesuré sous Linux.
    @Test func largeDictionaryDoesNotSlowAnOrdinaryCorrection() {
        let heard = "bonjour je voulais te dire que le déploiement de vercel est terminé et que tout marche bien"
        let written = "Bonjour, je voulais te dire que le déploiement de Vercel est terminé et que tout marche bien."
        let dictionary = (0..<20_000).map { "Terme\($0) Spécial" }
        #expect(FidelityGuard.check(transcript: heard, corrected: written, dictionary: dictionary) == written)
        let without = Timing.fastest(of: 5) { _ = FidelityGuard.check(transcript: heard, corrected: written) }
        let with = Timing.fastest(of: 5) { _ = FidelityGuard.check(transcript: heard, corrected: written, dictionary: dictionary) }
        #expect(with < without * 4)
    }

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

    /// Un mot de la page lue, mis à la place de mots dits qui ne lui ressemblent pas, est refusé. Le 28 octobre 2026,
    /// « habilitée RAID » (abliterated, dit avec l'accent) est devenu « quantifiées », mot de la page.
    @Test func contextWordSwappedForUnlikeSpeechIsRestored() {
        let page = "Des variantes de la communauté retirent les refus du modèle ; d'autres sont quantifiées en GGUF."
        let heard = "Tu vois les versions habilitée RAID d'un modèle ?"
        let swapped = FidelityGuard.check(transcript: heard, corrected: "Tu vois les versions quantifiées d'un modèle ?",
                                          previousDictations: [page])
        #expect(swapped == heard)
        // Le terme dit avec l'accent sonne comme les mots transcrits : il reste, avec ou sans contexte.
        let fixed = "Tu vois les versions abliterated d'un modèle ?"
        #expect(FidelityGuard.check(transcript: heard, corrected: fixed, previousDictations: [page + " Qwen3-abliterated."]) == fixed)
        #expect(FidelityGuard.check(transcript: heard, corrected: fixed) == fixed)
    }

    /// Une vraie correction d'écoute reste, même quand le mot juste figure aussi dans le contexte.
    @Test(arguments: [
        ("Le mer a inauguré la nouvelle école du quartier.", "Le maire a inauguré la nouvelle école du quartier.", "Le maire de la ville était là."),
        ("Ce soir le compte parle d'un loup et de trois cochons.", "Ce soir, le conte parle d'un loup et de trois cochons.", "Je lis un conte aux enfants."),
        ("Tire la fenêtre v le bas pour voir la suite.", "Tire la fenêtre vers le bas pour voir la suite.", "Glisse la carte vers le haut."),
        ("Il est parti cent rien dire à personne.", "Il est parti sans rien dire à personne.", "Il est parti sans prévenir."),
        ("Hier j'écris le train pour aller voir mamie.", "Hier, j'ai pris le train pour aller voir mamie.", "J'ai pris le métro ce matin."),
        ("On fait tourner le modèle avec au lama sur le Mac.", "On fait tourner le modèle avec Ollama sur le Mac.", "Lance Ollama avant le test."),
    ])
    func hearingFixConfirmedByContextStays(heard: String, corrected: String, context: String) {
        #expect(FidelityGuard.check(transcript: heard, corrected: corrected, previousDictations: [context]) == corrected)
    }

    /// Le jargon de l'IA va à la correction, pas aux mots-clés de la reconnaissance : limités à 100, ils restent ceux
    /// mesurés sur les bancs.
    @Test func aiJargonReachesTheCorrectionButNotTheRecognitionHints() {
        let hints = RecognitionHints.keyterms(dictionary: [], context: [])
        #expect(hints == KeytermList.sanitize(TechVocabulary.all))
        #expect(!hints.contains("abliterated"))
        let user = CorrectionPrompt.userText(CorrectionRequest(transcript: "x"))
        #expect(user.contains("abliterated"))
        #expect(user.contains("Hugging Face"))
    }

    /// Le 28 octobre 2026 : « envoie-le » dans le fichier, « envoie-lui » en direct, et la correction a écrit
    /// « envoie-la », que personne n'a entendu. Le texte garde un mot entendu.
    @Test func aThirdSmallWordGivesWayToTheOtherHearing() {
        let file = "Si t'as pas envoyé la réponse, envoie-le.", live = "Si t'as pas envoyé la réponse, envoie-lui."
        #expect(FidelityGuard.check(transcript: file, corrected: "Si tu n'as pas envoyé la réponse, envoie-la.", alternative: live)
            == "Si tu n'as pas envoyé la réponse, envoie-lui.")
        // Un mot entendu par l'une des deux écoutes reste.
        #expect(FidelityGuard.check(transcript: file, corrected: live, alternative: live) == live)
        #expect(FidelityGuard.check(
            transcript: "Prends le dossier et envoie-le à Paul.", corrected: "Prends le dossier et envoie-le à Paul.",
            alternative: "Prends le dossier et envoie-lui à Paul."
        ) == "Prends le dossier et envoie-le à Paul.")
        // Sans autre écoute, la correction reste seule juge.
        #expect(FidelityGuard.check(transcript: file, corrected: "Si t'as pas envoyé la réponse, envoie-la.")
            == "Si t'as pas envoyé la réponse, envoie-la.")
        // Un écart sur un mot plein n'est pas concerné.
        #expect(FidelityGuard.check(
            transcript: "On range les ulti dans le garage.", corrected: "On range les outils dans le garage.",
            alternative: "On range les outils dans le garage."
        ) == "On range les outils dans le garage.")
        // Les voisins désignent la place : seul le mot où les écoutes divergent change.
        #expect(FidelityGuard.check(
            transcript: "Donne-le et prends-le.", corrected: "Donne-la et prends-la.", alternative: "Donne-lui et prends-le."
        ) == "Donne-lui et prends-la.")
    }
}
