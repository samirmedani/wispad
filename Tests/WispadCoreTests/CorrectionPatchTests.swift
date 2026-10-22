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
        // Le mot apparaît deux fois au même genre d'endroit : on ne sait pas lequel changer.
        #expect(CorrectionPatch.apply(
            corrected: "On voit mardi, on voit mardi.",
            stream: "on voit mardi on voit mardi", file: "on voit mardi on voit mercredi"
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
        #expect(CorrectionPatch.isCandidate(stream: "on part demain", file: "on part pas demain"))
        #expect(CorrectionPatch.isCandidate(stream: "on part pas demain", file: "on part demain"))
        #expect(!CorrectionPatch.isCandidate(stream: "on part", file: "on part demain matin"))
        #expect(!CorrectionPatch.isCandidate(stream: "part demain", file: "on part demain"))
    }

    /// Mot entendu d'un seul côté au milieu de la phrase (mesuré le 21 octobre 2026 : 86 dictées sur 368 qui
    /// différaient d'un à quatre mots) : il est ajouté ou retiré dans la correction du flux.
    @Test func wordAddedOrDroppedByTheFileIsReported() {
        #expect(CorrectionPatch.apply(
            corrected: "On part demain.", stream: "on part demain", file: "on part pas demain"
        ) == "On part pas demain.")
        #expect(CorrectionPatch.apply(
            corrected: "Je sais pas pourquoi.", stream: "je sais pas pourquoi", file: "Je ne sais pas pourquoi."
        ) == "Je ne sais pas pourquoi.")
        // Un mot écrit avec trait d'union compte pour un.
        #expect(CorrectionPatch.apply(
            corrected: "Il viendra demain.", stream: "il viendra demain", file: "il viendra peut-être demain"
        ) == "Il viendra peut-être demain.")
        // Majuscule d'un début de phrase du fichier : le mot arrive en milieu de phrase.
        #expect(CorrectionPatch.apply(
            corrected: "On part demain matin.", stream: "on part demain matin", file: "On part. Pas demain matin"
        ) == "On part pas demain matin.")
        // Nom propre au milieu du fichier : sa majuscule reste.
        #expect(CorrectionPatch.apply(
            corrected: "On part avec demain.", stream: "on part avec demain", file: "on part avec Julie demain"
        ) == "On part avec Julie demain.")
        #expect(CorrectionPatch.apply(
            corrected: "On part pas demain.", stream: "on part pas demain", file: "on part demain"
        ) == "On part demain.")
        // Remplacement et ajout dans la même dictée.
        #expect(CorrectionPatch.apply(
            corrected: "On se voit mardi à la réunion, je sais pas quand.",
            stream: "on se voit mardi à la réunion je sais pas quand",
            file: "on se voit mercredi à la réunion je ne sais pas quand"
        ) == "On se voit mercredi à la réunion, je ne sais pas quand.")
    }

    @Test func doubtfulAdditionsAndRemovalsFallBack() {
        // Une virgule entre les voisins : on ne sait pas de quel côté mettre le mot.
        #expect(CorrectionPatch.apply(
            corrected: "On part, demain.", stream: "on part demain", file: "on part pas demain"
        ) == nil)
        // Plusieurs mots écrits ajoutés d'un coup : peut-être un rattrapage (« mardi non mercredi »).
        #expect(CorrectionPatch.apply(
            corrected: "On se voit mercredi.", stream: "on se voit mercredi", file: "on se voit mardi non mercredi"
        ) == nil)
        // Élision collée au mot suivant : « l » seul ne se place pas.
        #expect(CorrectionPatch.apply(
            corrected: "Il a fini hier.", stream: "il a fini hier", file: "il l'a fini hier"
        ) == nil)
        #expect(CorrectionPatch.apply(
            corrected: "Il l'a fini hier.", stream: "il l'a fini hier", file: "il a fini hier"
        ) == nil)
        // Répétition entendue par le fichier : la correction l'enlèverait, le report ne la remet pas.
        #expect(CorrectionPatch.apply(
            corrected: "Le chat dort.", stream: "le chat dort", file: "le le chat dort"
        ) == nil)
        // Répétition déjà enlevée par la correction du flux : le mot qui reste ne part pas.
        #expect(CorrectionPatch.apply(
            corrected: "Par exemple, ça marche bien.",
            stream: "par exemple par exemple ça marche bien", file: "par exemple ça marche bien"
        ) == nil)
        #expect(CorrectionPatch.apply(
            corrected: "Le chat dort ici.", stream: "le chat chat dort ici", file: "le chat dort ici"
        ) == nil)
        // Mot à retirer collé à une virgule : la ponctuation resterait orpheline.
        #expect(CorrectionPatch.apply(
            corrected: "On part, pas demain.", stream: "on part pas demain", file: "on part demain"
        ) == nil)
        // Mot à retirer qui n'a plus ses deux voisins dans la correction.
        #expect(CorrectionPatch.apply(
            corrected: "On part vraiment pas demain.", stream: "on part pas demain", file: "on part demain"
        ) == nil)
        // Terme du dictionnaire : le fichier ne le retire pas.
        #expect(CorrectionPatch.apply(
            corrected: "On utilise vraiment Wispad ici.", stream: "on utilise vraiment Wispad ici",
            file: "on utilise vraiment ici", protected: ["Wispad"]
        ) == nil)
    }

    /// Mot présent plusieurs fois dans la correction : ses voisins de l'écoute disent lequel changer.
    @Test func repeatedWordIsLocatedByItsNeighbors() {
        #expect(CorrectionPatch.apply(
            corrected: "Mardi, on voit mardi.", stream: "mardi on voit mardi", file: "mardi on voit mercredi"
        ) == "Mardi, on voit mercredi.")
        #expect(CorrectionPatch.apply(
            corrected: "Je prends le train et le bus.", stream: "je prends le train et le bus", file: "je prends le train et un bus"
        ) == "Je prends le train et un bus.")
    }
}
