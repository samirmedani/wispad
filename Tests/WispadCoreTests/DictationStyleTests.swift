import Foundation
import Testing
@testable import WispadCore

struct SelectionCommandTests {
    @Test func spokenInstructionsAreRecognized() {
        for command in ["Reformule plus poliment.", "Traduis en anglais", "Peux-tu résumer en deux lignes ?",
                        "Rends-le plus court.", "Mets ça en liste.", "Make it shorter.", "Translate to French",
                        "OK, corrige les fautes.", "S'il te plaît, simplifie."] {
            #expect(SelectionCommand.isCommand(command), "\(command)")
        }
    }

    @Test func ordinaryDictationIsNotACommand() {
        for text in ["Je reformulerai demain.", "Rendez-vous à 15 h.", "Mets-toi à l'aise.", "Make sure it builds.",
                     "Le résumé est prêt.", "Bonjour à tous", ""] {
            #expect(!SelectionCommand.isCommand(text), "\(text)")
        }
    }

    @Test func commandPromptCarriesTheWholeSelection() {
        var request = CorrectionRequest(transcript: "Traduis en anglais.", structureDictation: true)
        request.commandSelection = "Bonjour à tous.\n- un\n- deux"
        #expect(CorrectionPrompt.system(for: request).contains("Tu modifies un texte sélectionné"))
        let user = CorrectionPrompt.userText(request)
        #expect(user.contains("Consigne : Traduis en anglais."))
        #expect(user.contains("Bonjour à tous.\n- un\n- deux"))
        #expect(!user.contains("Vocabulaire technique"))
    }
}

struct DictationToneTests {
    @Test func naturalToneKeepsThePromptUnchanged() {
        let request = CorrectionRequest(transcript: "t'as vu ?")
        #expect(CorrectionPrompt.system(for: request) == CorrectionPrompt.system + "\n" + CorrectionPrompt.system(for: request).components(separatedBy: CorrectionPrompt.system + "\n").last!)
        #expect(!CorrectionPrompt.system(for: request).contains("Ton soigné"))
    }

    @Test func toneIsAddedInTheDictationLanguage() {
        var request = CorrectionRequest(transcript: "t'as vu ?")
        request.tone = .polished
        #expect(CorrectionPrompt.system(for: request).hasSuffix(DictationTone.polished.instructions(english: false)))
        request.language = .english
        request.tone = .casual
        #expect(CorrectionPrompt.system(for: request).hasSuffix(DictationTone.casual.instructions(english: true)))
    }
}
