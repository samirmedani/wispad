import Testing
@testable import WispadCore

/// Report des mots du fichier dans la correction du flux : seulement quand l'endroit est sûr.
struct CorrectionPatchTests {
    @Test func oneWordFromTheFileReplacesTheStreamWord() {
        #expect(CorrectionPatch.apply(
            corrected: "On se voit mardi à la réunion.",
            stream: "on se voit mardi à la réunion", file: "On se voit mercredi à la réunion."
        ) == "On se voit mercredi à la réunion.")
    }

    @Test func capitalOfTheCorrectionIsKept() {
        #expect(CorrectionPatch.apply(
            corrected: "Bonjour tout le monde.", stream: "bonjour tout le monde", file: "bonsoir tout le monde"
        ) == "Bonsoir tout le monde.")
        // En milieu de phrase, la majuscule de début de phrase du fichier ne passe pas.
        #expect(CorrectionPatch.apply(
            corrected: "Alors, on part mardi.", stream: "alors on part mardi", file: "Alors on part. Mercredi"
        ) == "Alors, on part mercredi.")
    }

    @Test func apostrophesAndFillersAreHandled() {
        #expect(CorrectionPatch.apply(
            corrected: "J'ai vu l'API hier.", stream: "j'ai vu l'API hier", file: "J'ai vu l'IA hier."
        ) == "J'ai vu l'IA hier.")
        #expect(CorrectionPatch.apply(
            corrected: "On part mardi.", stream: "euh on part mardi", file: "on part mercredi"
        ) == "On part mercredi.")
    }

    @Test func twoShortReplacementsAreReported() {
        #expect(CorrectionPatch.apply(
            corrected: "Le build passe sur la branche main, puis on déploie vendredi.",
            stream: "le build passe sur la branche main puis on déploie vendredi",
            file: "le bilde passe sur la branche main puis on déploie jeudi"
        ) == "Le bilde passe sur la branche main, puis on déploie jeudi.")
    }

    @Test func doubtfulCasesFallBackToAFullCorrection() {
        // Le mot apparaît deux fois dans la correction : on ne sait pas lequel changer.
        #expect(CorrectionPatch.apply(
            corrected: "Mardi, on voit mardi.", stream: "mardi on voit mardi", file: "mardi on voit mercredi"
        ) == nil)
        // Mot ajouté sans remplacement.
        #expect(CorrectionPatch.apply(
            corrected: "On part demain.", stream: "on part demain", file: "on part pas demain"
        ) == nil)
        // Trois endroits différents.
        #expect(CorrectionPatch.apply(
            corrected: "Un deux trois quatre cinq six sept.",
            stream: "un deux trois quatre cinq six sept", file: "un douze trois quatorze cinq seize sept"
        ) == nil)
        // Trop de mots d'un coup.
        #expect(CorrectionPatch.apply(
            corrected: "Je pense que le serveur est tombé hier soir.",
            stream: "je pense que le serveur est tombé hier soir",
            file: "je pense que la base de données a planté hier soir"
        ) == nil)
        // La correction a déjà changé ce mot.
        #expect(CorrectionPatch.apply(
            corrected: "Le serverless tourne.", stream: "le services tourne", file: "le server tourne"
        ) == nil)
        // Terme du dictionnaire : le fichier ne l'écrase pas.
        #expect(CorrectionPatch.apply(
            corrected: "On utilise Wispad ici.", stream: "on utilise Wispad ici", file: "on utilise whisper ici",
            protected: ["Wispad"]
        ) == nil)
        // Écoutes identiques : rien à reporter.
        #expect(CorrectionPatch.apply(corrected: "Bonjour.", stream: "bonjour", file: "Bonjour") == nil)
        // Flux tronqué : la fin manquante n'est pas un mot mal entendu.
        #expect(CorrectionPatch.apply(corrected: "Il écrit DDR.", stream: "il écrit DDR", file: "il écrit DDR4 ce bâtard.") == nil)
    }

    @Test func candidateCheckMatchesTheBlocks() {
        #expect(CorrectionPatch.isCandidate(stream: "on part mardi", file: "on part mercredi"))
        #expect(!CorrectionPatch.isCandidate(stream: "on part", file: "on part demain matin"))
    }
}
