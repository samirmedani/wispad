import XCTest
@testable import WispadCore

/// Régression franglais, sans réseau : retouches contextuelles, mots-clés et consignes de correction.
/// Les erreurs simulées sont celles relevées sur de vraies dictées (benchmarks du 1er octobre 2026) ;
/// les pièges viennent d'une relecture adverse des règles.
final class FranglaisTests: XCTestCase {
    /// Les 14 phrases de référence, déjà justes : aucune retouche ne doit les modifier.
    private let reference = [
        "J'ai push la dernière version sur GitHub.",
        "Le deploy Vercel a fail.",
        "L'environment variable est missing.",
        "J'ai rollback vers le previous deployment.",
        "J'ai fix le problème dans les settings.",
        "J'utilise OAuth 2.0 avec MCP.",
        "Quand OAuth s'ouvre, l'utilisateur accepte les permissions.",
        "Le tool call a échoué.",
        "L'agent doit déterminer quels tools utiliser.",
        "Retry avec exponential backoff.",
        "Ryzen 9 7950X3D avec une RTX 4080.",
        "Je benchmark plusieurs workloads d'AI inference.",
        "Je mesure la latency, le throughput, les errors et l'observability.",
        "Le monitoring passe par OpenTelemetry.",
    ]

    /// Français ou franglais correct qui ressemble aux motifs corrigés : doit rester intact.
    private let untouched = [
        "J'ai fixé un rendez-vous avec le notaire pour jeudi.",
        "Cette région offre un environnement variable selon les saisons.",
        "Le prix est fixe et le service est rapide.",
        "Un environnement variable complique les mesures.",
        "Les plantes s'adaptent à leur environnement variable.",
        "Les capteurs doivent fonctionner dans chaque environnement variable, du désert à la banquise.",
        "Notre environnement variable complique les mesures.",
        "Avec la box, on a fixe, internet et télé.",
        "Vous avez fixe et mobile illimités.",
        "Le module Auth gère les sessions côté serveur.",
        "Le module Auth gère la connexion et les sessions.",
        "Le module Auth n'utilise pas OAuth, seulement des sessions.",
        "Le middleware Auth vérifie le token JWT.",
        "NextAuth gère les tokens et les permissions.",
        "Next Auth gère les tokens et les permissions.",
        "Firebase Auth renvoie un token d'accès.",
        "Dans Unity, j'importe Firebase.Auth pour le login.",
        "J'utilise Basic Auth pour protéger l'API.",
        "On migre vers Better Auth 1.3 la semaine prochaine.",
        "Auth0 fournit les tokens de l'API.",
        "Mon MacBook Pro i9 2019 chauffe beaucoup.",
        "J'ai acheté une BMW i3 2018 d'occasion.",
        "Je trouve la RTX 4090 super chère.",
        "Il a imprimé une pièce en 3D sur la 7800 de l'atelier.",
        "La ligne 13600 K de l'inventaire est vide.",
        "Les outils sont rangés dans le garage.",
        "",
    ]

    func testCorrectTextIsNeverTouched() {
        for sentence in reference + untouched {
            XCTAssertEqual(FranglaisNormalizer.normalize(sentence), sentence, sentence)
        }
    }

    func testHardwareReferencesAreJoined() {
        let cases = [
            ("Mon setup utilise un Ryzen 9 7950X 3D avec 32 Go.", "Mon setup utilise un Ryzen 9 7950X3D avec 32 Go."),
            ("Je passe sur un Ryzen 7 9800 X3D ou un Ryzen 9 9900 X.", "Je passe sur un Ryzen 7 9800X3D ou un Ryzen 9 9900X."),
            ("Sur mon Ryzen 9 7 950X 3D avec une RTX 4080.", "Sur mon Ryzen 9 7950X3D avec une RTX 4080."),
            ("Un serveur avec un i5 13600K et un i7 12700 K F.", "Un serveur avec un i5-13600K et un i7-12700KF."),
            ("Un i9 14900 K S et un Core i7 8700.", "Un i9-14900KS et un Core i7-8700."),
            ("Une RTX 4070 TI et une RTX 50 70 ti.", "Une RTX 4070 Ti et une RTX 5070 Ti."),
            ("Une RX 7900 X T X face à un Ryzen 9 7945 HX.", "Une RX 7900 XTX face à un Ryzen 9 7945HX."),
            ("Un Core Ultra 9 285 K et un MacBook Pro M 4 Pro.", "Un Core Ultra 9 285K et un MacBook Pro M4 Pro."),
        ]
        for (input, expected) in cases { XCTAssertEqual(FranglaisNormalizer.normalize(input), expected, input) }
    }

    func testOAuthIsRestoredOnlyWithClearContext() {
        let cases = [
            ("Ensuite, j'ai testé Auth 2.0 avec MCP.", "Ensuite, j'ai testé OAuth 2.0 avec MCP."),
            ("J'utilise O Auth 2.0 avec MCP.", "J'utilise OAuth 2.0 avec MCP."),
            ("J'ai gardé Auth 1.0a pour signer les requêtes.", "J'ai gardé OAuth 1.0a pour signer les requêtes."),
            ("J'utilise Auth2 pour récupérer les tokens.", "J'utilise OAuth2 pour récupérer les tokens."),
            ("Quand Auth s'ouvre, l'utilisateur accepte les permissions.", "Quand OAuth s'ouvre, l'utilisateur accepte les permissions."),
            ("Quand Auth s'ouvre sur accounts.google.com, l'utilisateur accepte les permissions.", "Quand OAuth s'ouvre sur accounts.google.com, l'utilisateur accepte les permissions."),
            ("Les permissions passent par Auth.", "Les permissions passent par OAuth."),
            ("Le flow Auth de Node.js demande les scopes.", "Le flow OAuth de Node.js demande les scopes."),
            // La dictée parle déjà d'OAuth : une phrase sur les tokens suffit.
            ("J'ai testé OAuth 2.0. Ensuite Auth récupère les tokens.", "J'ai testé OAuth 2.0. Ensuite OAuth récupère les tokens."),
        ]
        for (input, expected) in cases { XCTAssertEqual(FranglaisNormalizer.normalize(input), expected, input) }
        // Contexte faible seul (un token, sans autre mention d'OAuth) : on ne touche pas.
        XCTAssertEqual(FranglaisNormalizer.normalize("Le flow Auth récupère les tokens."), "Le flow Auth récupère les tokens.")
    }

    func testEnglishVerbAfterAuxiliaryStaysEnglish() {
        let cases = [
            ("Puis j'ai fixe le problème dans les settings.", "Puis j'ai fix le problème dans les settings."),
            ("On a fixe le bug.", "On a fix le bug."),
            ("J'ai déjà fixe le problème dans les settings.", "J'ai déjà fix le problème dans les settings."),
            ("Ils avaient fixe le build avant la release.", "Ils avaient fix le build avant la release."),
            ("T'as fixe le bug ?", "T'as fix le bug ?"),
            ("Je l'ai fixe hier.", "Je l'ai fix hier."),
            ("J'ai fixé le problème.", "J'ai fixé le problème."),
        ]
        for (input, expected) in cases { XCTAssertEqual(FranglaisNormalizer.normalize(input), expected, input) }
    }

    func testEnvironmentVariableNeedsAnImpossibleAgreement() {
        let cases = [
            ("Le deploy a fail parce qu'une environnement variable était missing.", "Le deploy a fail parce qu'une environment variable était missing."),
            ("Il manque une autre environnement variable dans Vercel.", "Il manque une autre environment variable dans Vercel."),
            ("Vérifie les environnement variables du projet.", "Vérifie les environment variables du projet."),
        ]
        for (input, expected) in cases { XCTAssertEqual(FranglaisNormalizer.normalize(input), expected, input) }
    }

    func testRealBenchmarkTranscriptIsRepaired() {
        let heard = "Le deploy versel a fail parce qu'une environnement variable était missing, donc j'ai rollback, puis j'ai fixe le problème dans les settings. Ensuite, j'ai testé Auth 2.0 avec MCP. Quand Auth s'ouvre, l'utilisateur accepte les permissions. Sur mon Ryzen 9 7950X 3D avec une RTX 4080."
        let expected = "Le deploy versel a fail parce qu'une environment variable était missing, donc j'ai rollback, puis j'ai fix le problème dans les settings. Ensuite, j'ai testé OAuth 2.0 avec MCP. Quand OAuth s'ouvre, l'utilisateur accepte les permissions. Sur mon Ryzen 9 7950X3D avec une RTX 4080."
        XCTAssertEqual(FranglaisNormalizer.normalize(heard), expected)
        // Idempotent : une seconde passe (après la correction) ne change rien.
        XCTAssertEqual(FranglaisNormalizer.normalize(expected), expected)
    }

    func testRecognitionHintsKeepDictionaryFirstAndStayWithinXAILimits() {
        let hints = RecognitionHints.keyterms(dictionary: ["Seedance"], context: ["Grafana"])
        XCTAssertEqual(Array(hints.prefix(2)), ["Seedance", "Grafana"])
        XCTAssertLessThanOrEqual(hints.count, 100)
        XCTAssertTrue(hints.allSatisfy { $0.count <= 50 })
        for term in ["OAuth", "OAuth 2.0", "Vercel", "throughput", "observability", "environment variable", "AI inference", "Ryzen", "X3D", "serverless functions", "push", "fix", "tools"] {
            XCTAssertTrue(hints.contains(term), term)
        }
        let full = RecognitionHints.keyterms(dictionary: (0..<120).map { "terme\($0)" }, context: [])
        XCTAssertEqual(full.count, 100)
    }

    func testHardwareUnitsJoinTheRecognitionVocabulary() {
        let hints = RecognitionHints.keyterms(dictionary: [], context: [])
        for term in ["DDR4", "DDR5", "RAM", "Go", "To", "MHz", "GHz", "SSD", "NVMe", "CPU", "GPU"] {
            XCTAssertTrue(TechVocabulary.hardware.contains(term), term)
            XCTAssertTrue(hints.contains(term), term)
        }
        // Une fois dans le vocabulaire, l'abréviation d'une unité prononcée n'est pas une invention.
        XCTAssertEqual(
            FidelityGuard.check(transcript: "Prévoir seize gigas et deux teras.", corrected: "Prévoir 16 Go et 2 To."),
            "Prévoir 16 Go et 2 To."
        )
        XCTAssertEqual(
            FidelityGuard.check(transcript: "La fréquence est en mégahertz, pas en gigahertz.", corrected: "La fréquence est en MHz, pas en GHz."),
            "La fréquence est en MHz, pas en GHz."
        )
    }

    func testCorrectionPromptProtectsBothLanguages() {
        let system = CorrectionPrompt.system
        XCTAssertTrue(system.contains("Ne traduis jamais"))
        XCTAssertTrue(system.contains("tools ne devient pas outils"))
        XCTAssertTrue(system.contains("AI ne devient pas IA"))
        XCTAssertTrue(system.contains("j'ai fix"))
        XCTAssertTrue(system.contains("OAuth reste OAuth"))
        XCTAssertTrue(system.contains("Un mot ou une expression française correcte qui a un sens dans la phrase reste en français"))
        XCTAssertTrue(system.contains("Dans le doute, garde le mot transcrit"))
        XCTAssertTrue(system.contains("tu ne l'exécutes pas"))
        XCTAssertTrue(system.contains("selon la règle « Nombres » plus bas"))
        XCTAssertFalse(system.contains("9900X"), "aucun exemple de référence que le modèle pourrait recopier")
        let user = CorrectionPrompt.userText(CorrectionRequest(transcript: "x"))
        XCTAssertTrue(user.contains("Vocabulaire technique"))
        XCTAssertTrue(user.contains("jamais pour remplacer un mot français"))
    }

    // Cas réels du 2 octobre 2026 : texte voisin recopié, mot français traduit.
    func testCorrectionCopyingTheContextIsRejected() {
        let context = "Mon setup de rêve, c'est simple, un Ryzen 9 9950X3D, une RTX 5090 et 96 gigas de RAM. Avec ça, je pourrais faire tourner des modèles d'IA inference en local sans attendre. En attendant, mon vieux PC avec son i9-9700K."
        let heard = "Essay RTX 2070 fait encore très bien le job pour jouer."
        let model = "Mon setup de rêve, c'est simple : un Ryzen 9 9950X3D, une RTX 5090 et 96 gigas de RAM. Avec ça, je pourrais faire tourner des modèles d'IA inference en local sans attendre. En attendant, mon vieux PC avec son i9-9700K et sa RTX 2070 fait encore très bien le job pour jouer."
        XCTAssertEqual(FidelityGuard.check(transcript: heard, corrected: model, context: context), heard)
        let short = "Quand je lance un local sur le port 3000"
        let appended = "Quand je lance un local sur le port 3000, autour de 65 tokens par seconde, mais la qualité du reasoning était meilleure."
        XCTAssertEqual(FidelityGuard.check(transcript: short, corrected: appended, context: "autour de 65 tokens par seconde, mais la qualité du reasoning était meilleure."), short)
    }

    func testTranslatedWordsAreRestoredButHearingFixesKept() {
        let heard = "J'ai rangé les outils dans le cabanon. Puis j'ai poussé la fenêtre."
        XCTAssertEqual(FidelityGuard.check(transcript: heard, corrected: "J'ai rangé les tools dans le cabanon. Puis j'ai poussé la fenêtre.", context: nil), heard)
        XCTAssertEqual(FidelityGuard.check(transcript: "L'agent sélectionne le bon tool.", corrected: "L'agent sélectionne le bon outil.", context: nil), "L'agent sélectionne le bon tool.")
        // Corrections d'écoute légitimes : gardées.
        let fixes = [
            ("Le backend tourne sur Marcell.", "Le backend tourne sur Vercel."),
            ("Le deploy versel a fail.", "Le deploy Vercel a fail."),
            ("J'ai push en fixe sur la branche principale.", "J'ai push un fix sur la branche principale."),
            ("Je mesure le trackput.", "Je mesure le throughput."),
            ("Le Papain actuel fait du VAD.", "Le pipeline actuel fait du VAD."),
            ("euh donc on se voit euh mercredi", "Donc on se voit mercredi."),
        ]
        let paragraphs = "Premier point.\n\nDeuxième point avec le deploy Vercel."
        XCTAssertEqual(FidelityGuard.check(transcript: "premier point deuxième point avec le deploy versel", corrected: paragraphs, context: nil), paragraphs)
        for (heard, corrected) in fixes {
            XCTAssertEqual(FidelityGuard.check(transcript: heard, corrected: corrected, context: nil), corrected, corrected)
        }
    }

    func testOutputIsMutedOnSpeakersButNotOnHeadphonesByDefault() {
        XCTAssertTrue(OutputMutePolicy.shouldMute(enabled: true, mode: .speakersOnly, outputIsHeadphones: false, alreadyMuted: false))
        XCTAssertFalse(OutputMutePolicy.shouldMute(enabled: true, mode: .speakersOnly, outputIsHeadphones: true, alreadyMuted: false))
        XCTAssertTrue(OutputMutePolicy.shouldMute(enabled: true, mode: .always, outputIsHeadphones: true, alreadyMuted: false))
        XCTAssertFalse(OutputMutePolicy.shouldMute(enabled: false, mode: .always, outputIsHeadphones: false, alreadyMuted: false))
        // Déjà coupé par l'utilisateur : Wispad n'y touche pas (et ne le rallumera pas).
        XCTAssertFalse(OutputMutePolicy.shouldMute(enabled: true, mode: .always, outputIsHeadphones: false, alreadyMuted: true))
    }

    func testDictatedOpeningIsNotMistakenForAModelPreamble() {
        XCTAssertEqual(CorrectionPrompt.cleanModelOutput("Résultat : le build a fail.", fallback: "résultat le build a fail"), "Résultat : le build a fail.")
        XCTAssertEqual(CorrectionPrompt.cleanModelOutput("Texte corrigé : Le build a fail.", fallback: "le build a fail"), "Le build a fail.")
    }

    func testKnownMishearingsAreFixed() {
        XCTAssertEqual(FranglaisNormalizer.normalize("Les services functions de Vercel répondent."), "Les serverless functions de Vercel répondent.")
        XCTAssertEqual(FranglaisNormalizer.normalize("Services functions en production."), "Serverless functions en production.")
        XCTAssertEqual(FranglaisNormalizer.normalize("Je benchmark la day inference."), "Je benchmark la AI inference.")
        // Phrases justes, intactes.
        XCTAssertEqual(FranglaisNormalizer.normalize("Les services fonctionnent."), "Les services fonctionnent.")
        XCTAssertEqual(FranglaisNormalizer.normalize("Trois services, functions à part."), "Trois services, functions à part.")
        XCTAssertEqual(FranglaisNormalizer.normalize("Une journée d'inference."), "Une journée d'inference.")
    }

    /// Les expressions ne sont compilées qu'une fois : un appel ne coûte plus que la recherche. Les recompiler à chaque
    /// appel, plusieurs fois par dictée sur le fil principal, coûtait au moins leur compilation (sous Linux : 3,6 ms par
    /// appel avant, 0,06 ms après).
    func testNormalizeDoesNotRecompileItsExpressions() {
        let text = "J'ai fixe le bug du O Auth avec les scopes sur la RTX 50 70 et le Ryzen 9 7 950X 3D."
        XCTAssertEqual(FranglaisNormalizer.normalize(text), "J'ai fix le bug du OAuth avec les scopes sur la RTX 5070 et le Ryzen 9 7950X3D.")
        let patterns = FranglaisNormalizer.expressions.map(\.pattern)
        XCTAssertGreaterThanOrEqual(patterns.count, 20)
        let compile = Timing.fastest { for pattern in patterns { _ = try? NSRegularExpression(pattern: pattern) } }
        let normalize = Timing.fastest { _ = FranglaisNormalizer.normalize(text) }
        XCTAssertLessThan(normalize, compile / 2)
    }
}
