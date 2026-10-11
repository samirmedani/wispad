import Testing
@testable import WispadCore

struct DictationStructureTests {
    @Test(arguments: [
        (
            "Première puce vérifier le build. Deuxième puce lancer les tests.",
            "- Vérifier le build.\n- Lancer les tests."
        ),
        (
            "Voici mes courses : première puce acheter du lait. Deuxième puce prendre des pommes. Troisième puce payer.",
            "Voici mes courses :\n\n- Acheter du lait.\n- Prendre des pommes.\n- Payer."
        ),
        (
            "Premiere puce: appeler OpenAI. Seconde puce: vérifier les 4 modèles.",
            "- Appeler OpenAI.\n- Vérifier les 4 modèles."
        ),
        (
            "Première puce acheter du lait deuxième puce payer le loyer troisième puce appeler Léa",
            "- Acheter du lait\n- Payer le loyer\n- Appeler Léa"
        ),
        (
            "First bullet check the build. Second bullet run the tests.",
            "- Check the build.\n- Run the tests."
        ),
        (
            "Premier point vérifier le build. Deuxième point lancer les tests. Troisième point publier.",
            "1. Vérifier le build.\n2. Lancer les tests.\n3. Publier."
        ),
        (
            "Premièrement, installer le paquet. Deuxièmement, vérifier les 20 résultats. Troisièmement, lancer Wispad.",
            "1. Installer le paquet.\n2. Vérifier les 20 résultats.\n3. Lancer Wispad."
        ),
        (
            "Firstly, save the document. Secondly, close the window. Thirdly, restart.",
            "1. Save the document.\n2. Close the window.\n3. Restart."
        ),
        (
            "Pour demain : première puce appeler Camille. Deuxième puce préparer le dossier. En conclusion, rien ne presse.",
            "Pour demain :\n\n- Appeler Camille.\n- Préparer le dossier.\n\nEn conclusion, rien ne presse."
        ),
        (
            "Voici les tâches. Première puce tester. Deuxième puce publier. Fin de liste. Merci à tous.",
            "Voici les tâches.\n\n- Tester.\n- Publier.\n\nMerci à tous."
        ),
        (
            "Première puce tester. Deuxième puce publier. Fin de la liste.",
            "- Tester.\n- Publier."
        ),
        (
            "Première puce xAI coûte 0,25 €. Deuxième puce iOS 26 utilise OpenAI et DeepSeek.",
            "- xAI coûte 0,25 €.\n- iOS 26 utilise OpenAI et DeepSeek."
        ),
        (
            "Première puce -30 °C au minimum. Deuxième puce .5 litre de produit.",
            "- -30 °C au minimum.\n- .5 litre de produit."
        ),
        (
            "  Première puce tester. Deuxième puce publier.  ",
            "  - Tester.\n- Publier.  "
        )
    ])
    func explicitOrderedListsAreFormatted(_ fixture: (String, String)) {
        #expect(DictationStructure.format(fixture.0) == fixture.1)
        #expect(DictationStructure.format(fixture.1) == fixture.1)
    }

    @Test(arguments: [
        ("Bonjour. Nouveau paragraphe. Merci pour ton aide.", "Bonjour.\n\nMerci pour ton aide."),
        ("Titre. À la ligne. Le corps du texte.", "Titre.\nLe corps du texte."),
        ("Bonjour ! Nouvelle ligne. Merci.", "Bonjour !\nMerci."),
        ("Hello. New paragraph. Thank you.", "Hello.\n\nThank you."),
        ("Title. New line. Contents.", "Title.\nContents."),
        ("Bonjour. À la ligne. Nouveau paragraphe. Merci.", "Bonjour.\n\nMerci."),
        ("Bonjour. Nouveau paragraphe. À la ligne. Merci.", "Bonjour.\n\nMerci."),
        ("Première puce tester. Deuxième puce publier. Fin de liste. Nouveau paragraphe. Merci.", "- Tester.\n- Publier.\n\nMerci.")
    ])
    func isolatedFormattingControlsCreateBreaks(_ fixture: (String, String)) {
        #expect(DictationStructure.format(fixture.0) == fixture.1)
        #expect(DictationStructure.format(fixture.1) == fixture.1)
    }

    @Test(arguments: [
        "",
        "Je vais vérifier le build, ensuite lancer les tests et enfin publier.",
        "D'abord je mange, puis je travaille et ensuite je rentre.",
        "Mon premier point est important, le deuxième point concerne le budget.",
        "Premier point est une expression. Deuxième point concerne son orthographe.",
        "Première puce, c'est une commande. Deuxième puce, c'est une autre expression.",
        "Le premier point est au nord. Le deuxième point est au sud.",
        "Premier point vérifier le build.",
        "Deuxième puce tester. Troisième puce publier.",
        "Première puce tester. Troisième puce publier.",
        "Première puce tester. Deuxième point publier.",
        "Première puce. Deuxième puce publier.",
        "Première puce tester. Deuxième puce.",
        "Il a dit « première puce tester, deuxième puce publier ».",
        "Il a dit \"Bonjour. Nouveau paragraphe. Merci.\"",
        "'Première puce tester. Deuxième puce publier.'",
        "L'expression nouveau paragraphe indique une commande. Nouveau paragraphe. Je l'explique.",
        "Que veut dire la commande à la ligne ? À la ligne. Je cherche sa définition.",
        "Je veux un nouveau paragraphe pour la conclusion.",
        "On travaille à la ligne de production.",
        "Nouveau paragraphe.",
        "Nouveau paragraphe. Bonjour.",
        "Bonjour. À la ligne.",
        "Bonjour nouveau paragraphe merci.",
        "Première puce ouvrir https://example.com. Deuxième puce lire le résultat.",
        "Première puce regarder api.openai.com. Deuxième puce lire le résultat.",
        "`Première puce tester. Deuxième puce publier.`",
        "let message = \"Première puce tester. Deuxième puce publier.\";",
        "<p>Première puce tester. Deuxième puce publier.</p>",
        "- Tester.\n- Publier.",
        "1. Tester. 2. Publier.",
        "Bonjour.\n\nNouveau paragraphe. Merci.",
        "Bonjour.\r\nMerci.",
        "🤖 Première puce tester. Deuxième puce publier."
    ])
    func ambiguousLiteralProtectedAndStructuredProseIsUnchanged(_ text: String) {
        #expect(DictationStructure.format(text) == text)
    }

    @Test func normalLongDictationIsNotSplitByLength() {
        let text = Array(repeating: "Il reste 4 modèles à comparer, et le budget est de 0,25 €. ", count: 200).joined()
        #expect(DictationStructure.format(text) == text)
    }
}
