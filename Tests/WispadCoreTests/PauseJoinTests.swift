import Testing
@testable import WispadCore

/// Le flux xAI ponctue chaque segment final comme une phrase : à la jonction de deux segments, le point d'une pause
/// devient une virgule et le mot courant qui suit reprend sa minuscule. Exemples inventés.
struct PauseJoinTests {
    private func assemble(_ segments: [String]) -> TranscriptAssembler {
        var assembler = TranscriptAssembler()
        for (index, segment) in segments.enumerated() {
            assembler.apply(.partial(text: segment, isFinal: true, speechFinal: false, endSeconds: Double(index + 1)))
        }
        return assembler
    }

    @Test func aPausePeriodBecomesACommaAndTheNextWordLowercase() {
        let assembler = assemble(["Il faudrait un dossier.", "Où quand une facture arrive.", "Tu sais si elle est payée.", "Ou non."])
        #expect(assembler.bestText == "Il faudrait un dossier, où quand une facture arrive, tu sais si elle est payée, ou non.")
        #expect(assembler.displayText == assembler.bestText)
    }

    @Test func questionsExclamationsEllipsesAndInnerPeriodsStay() {
        #expect(assemble(["Tu viens demain ?", "On part tôt."]).bestText == "Tu viens demain ? On part tôt.")
        #expect(assemble(["Super !", "On y va."]).bestText == "Super ! On y va.")
        #expect(assemble(["Je pars. Tu restes.", "Et lui aussi."]).bestText == "Je pars. Tu restes, et lui aussi.")
        #expect(assemble(["Je réfléchis…", "Peut-être demain."]).bestText == "Je réfléchis… Peut-être demain.")
    }

    @Test func properNounsAcronymsInitialsAndAbbreviationsKeepTheirForm() {
        #expect(assemble(["On teste avec.", "Marseille demain."]).bestText == "On teste avec, Marseille demain.")
        #expect(assemble(["C'est validé.", "OK pour moi."]).bestText == "C'est validé, OK pour moi.")
        #expect(assemble(["On prend les vis, etc.", "Ensuite on monte."]).bestText == "On prend les vis, etc. Ensuite on monte.")
        #expect(assemble(["Signé J.", "Martin."]).bestText == "Signé J. Martin.")
        #expect(assemble(["I think so.", "I will check."]).bestText == "I think so, I will check.")
    }

    @Test func elidedWordsLowercase() {
        #expect(assemble(["Je regarde le fichier.", "J'ai trouvé la clé."]).bestText == "Je regarde le fichier, j'ai trouvé la clé.")
        #expect(assemble(["Je regarde.", "Qu’est-ce que tu en penses ?"]).bestText == "Je regarde, qu’est-ce que tu en penses ?")
    }

    @Test func aCumulativeFinalOrDoneKeepsTheSoftJoins() {
        var assembler = assemble(["Il faudrait un dossier.", "Ou pas."])
        assembler.apply(.partial(text: "Il faudrait un dossier. Ou pas.", isFinal: true, speechFinal: true, endSeconds: 3))
        #expect(assembler.bestText == "Il faudrait un dossier, ou pas.")
        assembler.apply(.done(text: "Il faudrait un dossier. Ou pas."))
        #expect(assembler.bestText == "Il faudrait un dossier, ou pas.")
        var growing = assemble(["On garde la liste."])
        growing.apply(.partial(text: "On garde la liste. Ou on la vide.", isFinal: true, speechFinal: true, endSeconds: 2))
        #expect(growing.bestText == "On garde la liste, ou on la vide.")
    }

    @Test func anInterimAfterAFinalIsShownSoftened() {
        var assembler = assemble(["Il faudrait un dossier."])
        #expect(assembler.bestText == "Il faudrait un dossier.")
        assembler.apply(.partial(text: "Ou quand une", isFinal: false, speechFinal: false, endSeconds: nil))
        #expect(assembler.displayText == "Il faudrait un dossier, ou quand une")
    }
}
