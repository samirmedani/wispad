import Testing
@testable import WispadCore

/// Mots mal entendus, tics répétés, citations et lettres épelées : consignes française et anglaise, garde-fou.
/// Sans réseau ; phrases inventées. Le banc réseau correspondant : cas h, r, g, l et e de `scripts/franglais-bench.sh`.
struct SoundAlikeCorrectionTests {
    // MARK: Consignes

    @Test func misheardEverydayWordsAreFixedOnlyWhenTheSentenceIsIllogical() {
        let french = CorrectionPrompt.system
        #expect(french.contains("Un mot courant mal entendu se corrige aussi"))
        #expect(french.contains("rend la phrase illogique"))
        #expect(french.contains("(« j'écris » / « j'ai pris », « c'est » / « s'est », « vers » / « verre »)"))
        #expect(french.contains("vu la phrase, le contexte et les dictées précédentes"))
        #expect(french.contains("Ne réécris pas une phrase qui a déjà un sens, n'ajoute aucune idée et ne change pas un mot qui a un sens plausible"))
        #expect(french.contains("Un nombre devant une unité suit la règle des nombres ci-dessus. Dans le doute, garde le mot transcrit."))
        let english = CorrectionPrompt.englishSystem
        #expect(english.contains("A misheard everyday word is fixed too"))
        #expect(english.contains("makes the sentence illogical"))
        #expect(english.contains("Do not rewrite a sentence that already makes sense, add no idea and do not change a word that has a plausible meaning"))
        #expect(english.contains("When in doubt, keep the transcribed word."))
        // L'autre écoute du même audio peut donner le mot juste.
        let request = CorrectionRequest(transcript: "Hier j'écris le train.", alternativeTranscript: "Hier j'ai pris le train")
        #expect(CorrectionPrompt.userText(request).contains("un nombre ou un mot qui rend la phrase illogique"))
        let englishRequest = CorrectionRequest(transcript: "The whether is nice.", alternativeTranscript: "The weather is nice", language: .english)
        #expect(CorrectionPrompt.userText(englishRequest).contains("a number or a word that makes the sentence illogical"))
    }

    @Test func repeatedTicsGoButAMeaningfulOccurrenceStays() {
        let french = CorrectionPrompt.system
        #expect(french.contains("« par exemple, par exemple », « genre », « en fait » ou « tu vois » répétés, « nan nan nan », mot doublé"))
        #expect(french.contains("gardes-en une occurrence : « par exemple » qui introduit un vrai exemple"))
        #expect(french.contains("Cette règle ne retire rien d'autre."))
        let english = CorrectionPrompt.englishSystem
        #expect(english.contains("\"for example, for example\""))
        #expect(english.contains("keep one occurrence: \"for example\" introducing a real example"))
        #expect(english.contains("This rule removes nothing else."))
    }

    @Test func spokenQuotationsGetQuotesButAnUnclearWordDoesNot() {
        let french = CorrectionPrompt.system
        #expect(french.contains("sans guillemets autour de ta réponse"))
        #expect(!french.contains("sans guillemets et sans commentaire"))
        #expect(french.contains("mets la citation entre guillemets français « » ; les mots qui l'introduisent restent hors des guillemets"))
        #expect(french.contains("« si tu dis… », « tu mets… », « genre… »"))
        #expect(french.contains("si tu dis bonjour il répond → Si tu dis « bonjour », il répond."))
        #expect(french.contains("Ne mets jamais entre guillemets un mot incompréhensible pour le garder tel quel"))
        let english = CorrectionPrompt.englishSystem
        #expect(english.contains("no quotes around your reply"))
        #expect(english.contains("curly double quotes “ ”, with the words that introduce it outside the quotes"))
        #expect(english.contains("Never put an incomprehensible word in quotes to keep it as is"))
    }

    @Test func spelledLettersAreGroupedAndLetterSoundsSeparated() {
        let french = CorrectionPrompt.system
        #expect(french.contains("regroupe ses lettres en un seul mot épelé, en capitales séparées par des tirets"))
        #expect(french.contains("le mot lui-même entre guillemets"))
        #expect(french.contains("C et « c'est », T et « t'es »"))
        #expect(french.contains("Une lettre isolée sans sens ne reste jamais dans le texte final"))
        #expect(french.contains("ça s'écrit t'es E S T → Ça s'écrit T-E-S-T."))
        let english = CorrectionPrompt.englishSystem
        #expect(english.contains("group its letters into one spelled word, in capitals joined by hyphens"))
        #expect(english.contains("An isolated letter without meaning never stays in the final text"))
        #expect(english.contains("it's spelled see A T → It's spelled C-A-T."))
    }

    // MARK: Garde-fou

    @Test(arguments: [
        // Dictées courtes, écrites autrement mais dites pareil : refusées avant la proximité à l'oreille.
        ("Un sot d'eau.", "Un seau d'eau."),
        ("Appelle le mer.", "Appelle le maire."),
        ("T sérieux ?", "T'es sérieux ?"),
        // Déjà proches à l'écrit : toujours gardées.
        ("Il c'est trompé.", "Il s'est trompé."),
        ("Un vers d'eau.", "Un verre d'eau."),
        ("J'écris le train.", "J'ai pris le train."),
        ("hier j'écris le train de 8 h pour aller au bureau", "Hier, j'ai pris le train de 8 h pour aller au bureau."),
        ("C bon pour moi.", "C'est bon pour moi."),
    ])
    func soundAlikeReplacementIsKept(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == corrected)
    }

    @Test(arguments: [
        // Ni écrits ni dits pareil : une invention, la transcription reste.
        ("Un sot d'eau.", "Un verre d'eau."),
        ("Appelle le mer.", "Appelle le directeur."),
        ("Était sérieux.", "Sois sérieux."),
        // Un mot ajouté à une dictée courte reste refusé.
        ("Le maire.", "Le maire adjoint."),
        // Une marque absente de ce qui a été dit reste refusée.
        ("On a installé c'est giga hier soir.", "On a installé G.Skill hier soir."),
    ])
    func inventionIsStillRefused(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == transcript)
    }

    @Test func aBrandInventedBetweenQuotesIsStillRestored() {
        // Les guillemets ne sont pas des mots : ils ne font plus sortir le bloc des tailles contrôlées.
        #expect(FidelityGuard.check(transcript: "J'ai installé c'est giga hier.", corrected: "J'ai installé « G.Skill Trident » hier.")
            == "J'ai installé « c'est giga » hier.")
    }

    @Test(arguments: [
        ("Ça s'écrit aime E elle, pas autrement.", "Ça s'écrit M-E-L, pas autrement."),
        ("aime E elle", "M-E-L."),
        ("Le code de la salle, c'est aime E elle.", "Le code de la salle, c'est « mel »."),
        ("Le titre du livre s'écrit t'es O M E.", "Le titre du livre s'écrit T-O-M-E."),
        ("Sur l'affiche on lit V, V E R T, alors qu'il fallait V E R S.", "Sur l'affiche, on lit « vert », alors qu'il fallait « vers »."),
        ("Sur l'affiche on lit V, V E R T, alors qu'il fallait V E R S.", "Sur l'affiche, on lit V-E-R-T, alors qu'il fallait V-E-R-S."),
        ("Dans le message il faut écrire c'est E S et pas S E S.", "Dans le message, il faut écrire C-E-S et pas S-E-S."),
        ("Le mot ville s'écrit avec deux elle.", "Le mot « ville » s'écrit avec deux L."),
        ("The code is spelled see A T.", "The code is spelled C-A-T."),
    ])
    func groupedSpelledLettersAreNotTakenForAnInvention(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == corrected)
    }

    @Test func anInventedSpellingIsRefused() {
        #expect(FidelityGuard.check(transcript: "Ça s'écrit aime E elle, pas autrement.", corrected: "Ça s'écrit B-O-B, pas autrement.")
            == "Ça s'écrit aime E elle, pas autrement.")
        #expect(FidelityGuard.check(transcript: "aime E elle", corrected: "B-O-B.") == "aime E elle.")
        // Aucune lettre isolée entendue : rien n'a été épelé, un sigle qui sonne pareil reste une invention.
        #expect(FidelityGuard.check(transcript: "Il faut c'est des neufs.", corrected: "Il faut CD neufs.") == "Il faut c'est des neufs.")
    }

    @Test(arguments: [
        // Les guillemets d'une citation ne comptent pas comme des mots ajoutés.
        ("tu mets oui tu mets non ou tu mets peut-être", "Tu mets « oui », tu mets « non » ou tu mets « peut-être »."),
        ("il m'a dit on verra demain", "Il m'a dit : « On verra demain. »"),
        ("si tu dis bonjour il répond bonjour aussi", "Si tu dis « bonjour », il répond « bonjour » aussi."),
        ("she said we'll see tomorrow", "She said, “We'll see tomorrow.”"),
        // Tics et répétitions retirés : rien d'inventé.
        ("genre le projet genre il avance bien genre vraiment", "Le projet, il avance bien, vraiment."),
        ("par exemple par exemple tu peux prendre le bus", "Par exemple, tu peux prendre le bus."),
        ("nan nan nan je viendrai pas", "Nan, je viendrai pas."),
    ])
    func quotationsAndRemovedTicsAreKept(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == corrected)
    }

    @Test func dictatedQuotationsAreNotTakenForAWrapper() {
        #expect(CorrectionPrompt.cleanModelOutput("« ces » ou « ses »", fallback: "C E S ou S E S") == "« ces » ou « ses »")
        #expect(CorrectionPrompt.cleanModelOutput("“Hello,” she said, “see you soon.”", fallback: "hello she said see you soon")
            == "“Hello,” she said, “see you soon.”")
        #expect(CorrectionPrompt.cleanModelOutput("\"oui\" ou \"non\"", fallback: "oui ou non") == "\"oui\" ou \"non\"")
        // Une vraie enveloppe reste retirée, citation intérieure comprise.
        #expect(CorrectionPrompt.cleanModelOutput("« Il a dit « bonjour ». »", fallback: "il a dit bonjour") == "Il a dit « bonjour ».")
        #expect(CorrectionPrompt.cleanModelOutput("\"Il a dit « bonjour ».\"", fallback: "il a dit bonjour") == "Il a dit « bonjour ».")
    }

    // MARK: Oreille

    @Test func phoneticKeyHearsHomophonesAndLetterNames() {
        #expect(PhoneticKey.soundsAlike(["j'ai", "pris"], ["j'écris"]))
        #expect(PhoneticKey.soundsAlike(["maire"], ["mer"]))
        #expect(PhoneticKey.soundsAlike(["seau"], ["sot"]))
        #expect(PhoneticKey.soundsAlike(["s'est"], ["c'est"]))
        #expect(PhoneticKey.soundsAlike(["C"], ["c'est"]))
        #expect(PhoneticKey.soundsAlike(["T"], ["t'es"]))
        #expect(PhoneticKey.soundsAlike(["M-E-L"], ["aime", "E", "elle"]))
        #expect(PhoneticKey.key(["eau"]) == PhoneticKey.key(["haut"]))
        // Proches à l'écrit ou de longueur voisine, mais pas dits pareil.
        #expect(!PhoneticKey.soundsAlike(["Sois"], ["Était"]))
        #expect(!PhoneticKey.soundsAlike(["maître"], ["mer"]))
        #expect(!PhoneticKey.soundsAlike(["verre"], ["sot"]))
        #expect(!PhoneticKey.soundsAlike(["directeur"], ["mer"]))
    }

    @Test func spellingNeedsAnIsolatedLetterThatWasHeard() {
        #expect(PhoneticKey.spells(["M-E-L"], ["aime", "E", "elle"]))
        #expect(PhoneticKey.spells(["mel"], ["aime", "E", "elle"]))
        #expect(PhoneticKey.spells(["C-E-S"], ["c'est", "E", "S"]))
        #expect(!PhoneticKey.spells(["B-O-B"], ["aime", "E", "elle"]))
        #expect(!PhoneticKey.spells(["CD"], ["c'est", "des"]))
        #expect(!PhoneticKey.spells(["mel"], ["aime"]))
    }
}
