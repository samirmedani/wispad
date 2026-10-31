import Testing
@testable import WispadCore

/// Le flux xAI ponctue chaque segment final comme une phrase : un petit morceau ouvert par un mot de liaison, isolé par
/// une pause, est recollé à la phrase précédente par une virgule. Une jonction entre deux propositions plus longues
/// garde son point : la correction la ponctue selon le sens. Exemples inventés.
struct PauseJoinTests {
    private func assemble(_ segments: [String]) -> TranscriptAssembler {
        var assembler = TranscriptAssembler()
        for (index, segment) in segments.enumerated() {
            assembler.apply(.partial(text: segment, isFinal: true, speechFinal: false, endSeconds: Double(index + 1)))
        }
        return assembler
    }

    @Test func aShortLinkedFragmentJoinsThePreviousSentence() {
        let assembler = assemble(["Il faudrait un dossier.", "Où quand une facture arrive.", "Tu sais si elle est payée.", "Ou non."])
        #expect(assembler.bestText == "Il faudrait un dossier, où quand une facture arrive. Tu sais si elle est payée, ou non.")
        #expect(assembler.displayText == assembler.bestText)
        #expect(assemble(["Regarde le fichier.", "Sans le modifier."]).bestText == "Regarde le fichier, sans le modifier.")
        #expect(assemble(["On garde le dossier.", "Qu'il soit fini ou pas."]).bestText == "On garde le dossier, qu'il soit fini ou pas.")
        #expect(assemble(["C'est validé.", "Ou non ?"]).bestText == "C'est validé, ou non ?")
        #expect(assemble(["We can ship it.", "Or not."]).bestText == "We can ship it, or not.")
    }

    @Test func twoLongerClausesKeepTheirPeriod() {
        #expect(assemble(["C'est un vieux modèle.", "Il a six ans et il marche encore."]).bestText
                == "C'est un vieux modèle. Il a six ans et il marche encore.")
        #expect(assemble(["Il faudrait un dossier.", "Et un classeur pour les factures du mois."]).bestText
                == "Il faudrait un dossier. Et un classeur pour les factures du mois.")
        #expect(assemble(["On teste avec.", "Marseille demain."]).bestText == "On teste avec. Marseille demain.")
        #expect(assemble(["C'est validé.", "OK pour moi."]).bestText == "C'est validé. OK pour moi.")
        #expect(assemble(["I think so.", "I will check."]).bestText == "I think so. I will check.")
    }

    @Test func questionsExclamationsEllipsesAbbreviationsAndInnerPeriodsStay() {
        #expect(assemble(["Tu viens demain ?", "Ou pas."]).bestText == "Tu viens demain ? Ou pas.")
        #expect(assemble(["Super !", "Et après."]).bestText == "Super ! Et après.")
        #expect(assemble(["Je pars. Tu restes.", "Et lui aussi."]).bestText == "Je pars. Tu restes, et lui aussi.")
        #expect(assemble(["Je réfléchis…", "Et toi ?"]).bestText == "Je réfléchis… Et toi ?")
        #expect(assemble(["On prend les vis, etc.", "Et les clous."]).bestText == "On prend les vis, etc. Et les clous.")
        #expect(assemble(["Je regarde ça.", "Qu'est-ce que tu en penses ?"]).bestText == "Je regarde ça. Qu'est-ce que tu en penses ?")
        #expect(assemble(["On se voit demain.", "Quand ça ?"]).bestText == "On se voit demain. Quand ça ?")
    }

    @Test func aCumulativeFinalOrDoneKeepsTheJoin() {
        var assembler = assemble(["Il faudrait un dossier.", "Ou pas."])
        assembler.apply(.partial(text: "Il faudrait un dossier. Ou pas.", isFinal: true, speechFinal: true, endSeconds: 3))
        #expect(assembler.bestText == "Il faudrait un dossier, ou pas.")
        assembler.apply(.done(text: "Il faudrait un dossier. Ou pas."))
        #expect(assembler.bestText == "Il faudrait un dossier, ou pas.")
        var growing = assemble(["On garde la liste."])
        growing.apply(.partial(text: "On garde la liste. Ou on la vide.", isFinal: true, speechFinal: true, endSeconds: 2))
        #expect(growing.bestText == "On garde la liste, ou on la vide.")
    }

    @Test func anInterimIsShownAsHeardUntilItIsFinal() {
        var assembler = assemble(["Il faudrait un dossier."])
        assembler.apply(.partial(text: "Ou quand une", isFinal: false, speechFinal: false, endSeconds: nil))
        #expect(assembler.displayText == "Il faudrait un dossier. Ou quand une")
        assembler.apply(.partial(text: "Ou quand une facture arrive.", isFinal: true, speechFinal: false, endSeconds: 2))
        #expect(assembler.displayText == "Il faudrait un dossier, ou quand une facture arrive.")
    }
}
