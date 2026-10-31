import Foundation
import Testing
@testable import WispadCore

/// La transcription pose un point à chaque pause : une alternative isolée (« Ou non. », « Ou pas ? ») est rattachée à
/// sa phrase par la finition locale, après la correction, sans appel au modèle.
struct PauseFragmentTests {
    private func finish(_ text: String, tone: DictationTone = .natural) -> String {
        TextCleaner.completeWrittenGrammar(text, language: .french, tone: tone)
    }

    @Test func anIsolatedAlternativeJoinsItsSentence() {
        // Dictée réelle du 31 octobre (0.7.7), telle que la correction l'avait laissée.
        #expect(finish("Il faudrait filtrer les gens à qui tu as répondu. Ou non. Parce que je trouve que ça marche mal.")
                == "Il faudrait filtrer les gens à qui tu as répondu ou non. Parce que je trouve que ça marche mal.")
        #expect(finish("On garde la version courte. Ou pas.") == "On garde la version courte ou pas.")
        #expect(finish("Tu viens demain ? Ou pas ?") == "Tu viens demain ou pas ?")
        #expect(finish("Tu viens demain\u{202F}? Ou non.") == "Tu viens demain ou non\u{202F}?")
        #expect(finish("C'est validé. Ou non ?") == "C'est validé ou non ?")
        #expect(finish("On garde ça. Ou pas") == "On garde ça ou pas.")
    }

    @Test func otherSentencesAndTonesStayAsWritten() {
        let unchanged = [
            "Ou non, je préfère attendre.",                 // l'alternative commence une vraie phrase
            "Tu choisis. Ou non, c'est toi qui vois.",      // elle continue au-delà de « non »
            "Tu choisis. Ou non je sais pas.",              // même sans virgule
            "On prend les vis, etc. Ou pas.",               // abréviation
            "Génial ! Ou pas.",                             // après une exclamation, l'effet est voulu
            "Liste des réponses.\nOu non.",                 // autre ligne
            "Il a dit « Je viens. Ou pas. » hier.",          // citation protégée
        ]
        for text in unchanged { #expect(finish(text) == text, "\(text)") }
        // Le ton détendu garde les phrases telles qu'elles ont été dites, l'anglais aussi.
        #expect(finish("On garde la version courte. Ou pas.", tone: .casual) == "On garde la version courte. Ou pas.")
        #expect(TextCleaner.completeWrittenGrammar("We keep it. Or not.", language: .english, tone: .natural)
                == "We keep it. Or not.")
    }

    @Test func thePromptPunctuatesByMeaningRatherThanByPause() {
        #expect(CorrectionPrompt.system.contains("La ponctuation de la transcription suit les pauses de la voix"))
        #expect(CorrectionPrompt.system.contains("« Un écran ou on choisit la langue » → « Un écran où on choisit la langue. »"))
        #expect(CorrectionPrompt.englishSystem.contains("The transcription's punctuation follows the pauses of the voice"))
    }
}
