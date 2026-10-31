import Testing
@testable import WispadCore

/// Exemples inventés. Le fichier xAI se trompe sur un passage que le flux et la seconde écoute du Mac ont entendu
/// pareil : deux écoutes contre une, le passage du flux est retenu.
struct ListeningVoteTests {
    private func vote(_ file: String, _ stream: String, _ local: String?, protected: [String] = []) -> ListeningVote.Resolution {
        ListeningVote.resolve(file: file, stream: stream, local: local, protected: protected)
    }

    @Test func twoHearingsAgainstOneReplaceTheFilePassage() {
        let screws = vote("On range les vices dans la boîte, je pense.", "on range les vis dans la boîte je pense",
                          "on range les vis dans la boîte je pense")
        #expect(screws == ListeningVote.Resolution(text: "On range les vis dans la boîte, je pense.", replacements: 1))
        let key = vote("Tu sais ouest la clé ? Je la cherche.", "Tu sais où est la clé ? Je la cherche.",
                       "tu sais où est la clé je la cherche")
        #expect(key.text == "Tu sais où est la clé ? Je la cherche.")
        // Début de phrase : la majuscule du fichier reste.
        #expect(vote("Vices et boulons, rien d'autre.", "vis et boulons rien d'autre", "vis et boulons rien d'autre").text
                == "Vis et boulons, rien d'autre.")
    }

    @Test func eachPassageIsDecidedOnItsOwn() {
        // Premier passage : Apple d'accord avec le flux. Second : Apple d'accord avec le fichier.
        let mixed = vote("Il range les vices dans la cave et la cuisine.", "il range les vis dans la cage et la cuisine",
                         "il range les vis dans la cave et la cuisine")
        #expect(mixed == ListeningVote.Resolution(text: "Il range les vis dans la cave et la cuisine.", replacements: 1))
    }

    @Test func withoutAgreementTheFileStays() {
        let file = "On range les vices dans la boîte."
        #expect(vote(file, "on range les vis dans la boîte", nil).text == file)
        #expect(vote(file, "on range les vis dans la boîte", "on range les vices dans la boîte").text == file)
        #expect(vote(file, "on range les vis dans la boîte", "on range les vides dans la boîte").text == file)
        #expect(vote(file, "on range les vis dans la boîte", "").text == file)
    }

    @Test func namesTermsNumbersElisionsAndSmallWordsAreNeverVoted() {
        // Nom propre en milieu de phrase, terme du dictionnaire, nombre, élision, mot outil seul.
        #expect(vote("On garde Vercel pour ça.", "on garde verseau pour ça", "on garde verseau pour ça").replacements == 0)
        #expect(vote("Le repo est prêt.", "le rapport est prêt", "le rapport est prêt", protected: ["repo"]).replacements == 0)
        #expect(vote("Il en reste douze ici.", "il en reste treize ici", "il en reste treize ici").replacements == 0)
        #expect(vote("T'as vu le film ?", "tu as vu le film", "tu as vu le film").replacements == 0)
        #expect(vote("Il voit le chat.", "il voit la chat", "il voit la chat").replacements == 0)
        // Un mot ajouté ou retiré par une écoute n'est pas un remplacement.
        #expect(vote("On part demain matin.", "on part demain", "on part demain").replacements == 0)
    }

    @Test func longDisagreementsStayToTheCorrection() {
        let file = "Je vais vérifier la grande cuisine du fond avant ce soir."
        let other = "je vais vérifier les quatre pièces du sous-sol avant ce soir"
        #expect(vote(file, other, other).replacements == 0)
    }
}

/// « v. » de la mise en forme française d'xAI : « vers ». Exemples inventés.
struct SpokenAbbreviationsTests {
    @Test func aStandaloneVBecomesVers() {
        #expect(SpokenAbbreviations.restore("Il marche v. la gare ?") == "Il marche vers la gare ?")
        #expect(SpokenAbbreviations.restore("On se retrouve v. la place, v. midi.") == "On se retrouve vers la place, vers midi.")
        #expect(SpokenAbbreviations.restore("On l'a eu v. 300 € la semaine dernière.") == "On l'a eu vers 300 € la semaine dernière.")
        #expect(FranglaisNormalizer.normalize("Il faut aller v. la gare.") == "Il faut aller vers la gare.")
    }

    @Test func otherUsesStay() {
        for text in ["Il a noté la v. 2 du fichier.", "Signé Victor V. demain.", "La lettre v. Puis la suite.",
                     "It was Apple v. Google in the end, you know.", "Le niveau v.2 est prêt.", "On garde le prév. pour lundi."] {
            #expect(SpokenAbbreviations.restore(text) == text, "\(text)")
        }
    }
}
