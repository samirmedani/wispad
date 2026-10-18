import Testing
@testable import WispadCore

/// Ordinaux en exposant de la mise en forme française d'xAI, rendus tels que dits. Phrases fictives.
struct SpokenOrdinalsTests {
    @Test(arguments: [
        ("La vidéo tourne à 60 images par 2ᵈᵉ.", "La vidéo tourne à 60 images par seconde."),
        ("Il faut attendre 5 2ᵈᵉˢ avant de relancer.", "Il faut attendre 5 secondes avant de relancer."),
        ("Ça prend 9,3 2ᵈᵉˢ.", "Ça prend 9,3 secondes."),
        ("Dans un 1ᵉʳ temps, on teste.", "Dans un premier temps, on teste."),
        ("C'est la 1ʳᵉ fois.", "C'est la première fois."),
        ("Les 1ᵉʳˢ essais et les 1ʳᵉˢ versions.", "Les premiers essais et les premières versions."),
        ("Ouvre un 2ᵈ compte, puis une 2ⁿᵈᵉ fenêtre.", "Ouvre un second compte, puis une seconde fenêtre."),
        ("La 2ᵉ semaine, puis la 3ᵉ option et la 10ᵉ.", "La deuxième semaine, puis la troisième option et la dixième."),
        ("1ʳᵉ étape : installer. 2ᵉ étape : tester !", "Première étape : installer. Deuxième étape : tester !"),
        ("Il a dit : « 1ʳᵉ fois », puis\n2ᵉ essai.", "Il a dit : « première fois », puis\nDeuxième essai."),
        ("On se voit le 1ᵉʳ mai.", "On se voit le premier mai."),
    ])
    func givesBackTheSpokenWord(heard: String, expected: String) {
        #expect(SpokenOrdinals.restore(heard) == expected)
    }

    @Test(arguments: [
        "Le 21ᵉ siècle et le 11ᵉ arrondissement.",
        "Rendez-vous le 1er mai, au 2e étage, en 2de.",
        "Le 3ᵉʳ et le 1ᵈᵉ n'existent pas.",
        "Version 2.1ᵉ, H2O, A3ᵉ et 1ᵉʳmai.",
        "Sans aucun ordinal, juste 60 images par seconde.",
        "",
    ])
    func leavesEverythingElse(text: String) {
        #expect(SpokenOrdinals.restore(text) == text)
    }

    @Test func isIdempotent() {
        let once = SpokenOrdinals.restore("Dans un 1ᵉʳ temps, 60 images par 2ᵈᵉ, la 2ᵉ fois.")
        #expect(SpokenOrdinals.restore(once) == once)
    }

    /// Filet avant et après la correction : un ordinal en exposant ne reste jamais dans le texte collé.
    @Test func runsWithTheDeterministicRetouches() {
        #expect(FranglaisNormalizer.normalize("Ça tourne à 60 images par 2ᵈᵉ.") == "Ça tourne à 60 images par seconde.")
    }
}
