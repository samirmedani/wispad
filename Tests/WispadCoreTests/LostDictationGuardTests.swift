import Foundation
import Testing
@testable import WispadCore

/// Une correction qui perd la dictée (le modèle répond à côté) n'est jamais collée : la transcription l'est.
struct LostDictationGuardTests {
    /// Le 15 octobre, une minute de dictée est devenue « Travaillez avec Codex », un texte de la fenêtre : aucun de ces
    /// mots n'avait été dit, et le garde-fou ne jugeait qu'une copie de huit mots du contexte ou un texte allongé.
    @Test func aCorrectionReplacedByTheWindowTextKeepsTheTranscript() {
        let heard = "Alors je voulais te parler du planning de la semaine prochaine parce que lundi on a la réunion avec l'équipe "
            + "et mardi il faut absolument terminer la maquette du site avant de l'envoyer au client pour validation"
        let window = "Travaillez avec Codex. Nouvelle tâche. Rechercher."
        #expect(FidelityGuard.check(transcript: heard, corrected: "Travaillez avec Codex", context: window) == heard)
        #expect(FidelityGuard.check(transcript: heard, corrected: "Travaillez avec Codex.") == heard)
    }

    @Test func anAnswerOrATranslationInsteadOfTheDictationKeepsTheTranscript() {
        let question = "Est-ce que tu peux me dire quelle est la capitale de la France s'il te plaît"
        #expect(FidelityGuard.check(transcript: question, corrected: "Paris.") == question)
        let french = "je pense que c'est une très bonne idée de partir demain matin avec toute l'équipe"
        #expect(FidelityGuard.check(transcript: french, corrected: "I think it's a great idea to leave tomorrow morning with the whole team.") == french)
        // Plus aucun mot : une ponctuation seule ne remplace pas une phrase entière.
        let long = "bon alors on se retrouve demain à la gare vers dix heures avec les valises"
        #expect(FidelityGuard.check(transcript: long, corrected: "?") == long)
    }

    @Test func faithfulButShortCorrectionsStay() {
        // Phrase annulée à l'oral : peu de mots restent, tous dits.
        let scratched = "euh alors je voulais dire que non en fait oublie tout ça écris juste merci beaucoup"
        #expect(FidelityGuard.check(transcript: scratched, corrected: "Merci beaucoup.") == "Merci beaucoup.")
        // Hésitations seules autour d'un mot.
        let hesitations = "euh euh bon ben euh voilà euh ok euh"
        #expect(FidelityGuard.check(transcript: hesitations, corrected: "OK.") == "OK.")
        // Date et heure mises en forme : les mots changent, rien n'est inventé.
        let date = "le vingt-quatre octobre deux mille vingt-six à quatorze heures trente"
        #expect(FidelityGuard.check(transcript: date, corrected: "Le 24/10/2026 à 14h30.") == "Le 24/10/2026 à 14h30.")
        let phone = "mon numéro c'est le zéro six douze trente-quatre cinquante-six soixante-dix-huit"
        #expect(FidelityGuard.check(transcript: phone, corrected: "Mon numéro, c'est le 06 12 34 56 78.") == "Mon numéro, c'est le 06 12 34 56 78.")
        // Une commande courte reste rendue par sa ponctuation.
        #expect(FidelityGuard.check(transcript: "point d'interrogation", corrected: "?") == "?")
    }

    @Test func theRuleOnlyJudgesWhatItCan() {
        let heard = (1...40).map { "mot\($0)" }
        #expect(!FidelityGuard.losesTheDictation(heard: Array(heard.prefix(7)), written: ["Ailleurs"]))
        #expect(FidelityGuard.losesTheDictation(heard: heard, written: ["Ailleurs", "complètement"]))
        // Un quart des mots dits gardé : c'est une correction, même avec des mots nouveaux.
        #expect(!FidelityGuard.losesTheDictation(heard: heard, written: Array(heard.prefix(10)) + ["nouveau"]))
        // Mots repris de l'autre écoute du même audio : entendus, pas inventés.
        #expect(!FidelityGuard.losesTheDictation(heard: heard, written: ["Ailleurs"], alsoHeard: ["ailleurs"]))
    }
}

struct HistorySearchTests {
    @Test func aDictationIsFoundByWhatWasSaidEvenWhenTheCorrectionWentWrong() {
        let record = DictationRecord(finalText: "Travaillez avec Codex", rawText: "On revoit la maquette du site demain",
                                     durationSeconds: 55, wordCount: 3, provider: "xai", model: "test",
                                     insertionStatus: "paste_sent", alternativeText: "On revoit la maquette du site demain matin")
        #expect(record.matches(search: "Codex"))
        #expect(record.matches(search: "maquette"))
        #expect(record.matches(search: "MATIN"))
        #expect(!record.matches(search: "facture"))
        let plain = DictationRecord(finalText: "Bonjour.", rawText: "bonjour", durationSeconds: 1, wordCount: 1,
                                    provider: "xai", model: "test", insertionStatus: "inserted")
        #expect(plain.matches(search: "bonjour"))
        #expect(!plain.matches(search: "maquette"))
    }
}
