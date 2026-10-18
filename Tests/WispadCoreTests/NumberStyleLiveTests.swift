import Foundation
import XCTest
@testable import WispadCore

/// Banc réseau, clés de test seulement : WISPAD_NUMBER_STYLE=1 scripts/live-test.sh NumberStyleLiveTests.
/// Phrases inventées, comme la transcription les rend (chiffres de sa mise en forme), corrigées par le premier service
/// de correction des clés fournies. Affiche chaque résultat et compte ceux qui suivent la règle attendue.
final class NumberStyleLiveTests: XCTestCase {
    private struct Case {
        var transcript: String
        var language: DictationLanguage = .french
        var inWords = true
        /// Formes attendues (expression régulière, sans casse) et formes refusées dans le texte corrigé.
        var expected: [String]
        var refused: [String] = []
    }

    private static let cases: [Case] = [
        Case(transcript: "non le logo il est cyan les 2 premières barres elles sont bleues foncées", expected: [#"deux premi"#], refused: [#"\b2 premi"#]),
        Case(transcript: "j'ai relancé le build 3 fois et ça marche toujours pas", expected: [#"trois fois"#], refused: [#"\b3 fois"#]),
        Case(transcript: "attends 2 minutes j'arrive", expected: [#"deux minutes"#]),
        Case(transcript: "il faut 4 serveurs avec des rtx 5090", expected: [#"quatre serveurs"#, #"RTX 5090"#]),
        Case(transcript: "j'ai 2 3 trucs à te dire avant la réunion", expected: [#"deux[,-]? ?trois trucs"#]),
        Case(transcript: "le chantier dure 2 mois et 1/2", expected: [#"deux mois et demi"#]),
        Case(transcript: "j'ai acheté 2 nouveaux claviers pour le bureau", expected: [#"deux nouveaux claviers"#]),
        Case(transcript: "il reste 3 places dans la salle si tu veux venir", expected: [#"trois places"#]),
        Case(transcript: "ça fait 2 jours que j'attends sa réponse", expected: [#"deux jours"#]),
        Case(transcript: "la latence est de 5 secondes c'est beaucoup trop", expected: [#"\b5 secondes"#]),
        Case(transcript: "le jeu tourne à 60 images par seconde", expected: [#"\b60 images"#]),
        Case(transcript: "on était entre 8 et 12 personnes", expected: [#"\b8 et 12"#]),
        Case(transcript: "la version 2 sort demain", expected: [#"version 2\b"#]),
        Case(transcript: "on a gagné 3 à 1 hier soir", expected: [#"\b3 à 1\b"#]),
        Case(transcript: "prends 16 go de ram à 6000 mhz", expected: [#"16\s?Go"#, #"6000\s?MHz"#]),
        Case(transcript: "il y a 12 utilisateurs connectés", expected: [#"\b12 utilisateurs"#]),
        Case(transcript: "le café coûte 3 euros 50", expected: [#"3,50\s?€"#]),
        Case(transcript: "franchement ils veulent quoi 2 mois", expected: [#"quoi de moi"#], refused: [#"\b2 mois"#, #"deux mois"#]),
        Case(transcript: "il est parti 100 rien dire", expected: [#"sans rien dire"#]),
        Case(transcript: "rendez-vous le 24 octobre 2026 à 14 h 30 pour 2 heures", expected: [#"24/10/2026"#]),
        Case(transcript: "the first 2 bars are dark blue and I retried 3 times", language: .english, expected: [#"first two bars"#, #"three times"#]),
        Case(transcript: "latency is 5 seconds at 60 frames per second", language: .english, expected: [#"\b5 seconds"#, #"\b60 frames"#]),
        Case(transcript: "non le logo il est cyan les 2 premières barres elles sont bleues foncées", inWords: false, expected: [#"\b2 premi"#]),
        Case(transcript: "j'ai relancé le build 3 fois et ça marche toujours pas", inWords: false, expected: [#"\b3 fois"#]),
        Case(transcript: "attends 2 minutes j'arrive", inWords: false, expected: [#"\b2 minutes"#]),
    ]

    func testNumbersFollowTheChosenStyle() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1" && env["WISPAD_NUMBER_STYLE"] == "1", "Banc réseau réservé à scripts/live-test.sh.")
        let xai = env["WISPAD_LIVE_XAI_KEY"] ?? ""
        let deepSeek = env["WISPAD_LIVE_DEEPSEEK_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        let openAI = env["WISPAD_LIVE_OPENAI_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        try XCTSkipIf(xai.isEmpty && deepSeek == nil && openAI == nil, "Aucune clé de test.")
        try SpendLedger.wispadDefault().reserve(Double(Self.cases.count) * 0.004)
        var followed = 0
        for item in Self.cases {
            let speech = SpeechRequest(provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0",
                                       apiKey: xai, language: item.language, keyterms: [], prompt: "",
                                       cleanupKey: deepSeek, fallbackKey: openAI)
            var request = CorrectionRequest(transcript: item.transcript, language: item.language)
            request.numberFormat = DictationNumberFormat(smallNumbersInWords: item.inWords)
            // WISPAD_NUMBER_STYLE_MODEL : un modèle xAI précis (rapide, sans raisonnement), même consigne et même garde-fou.
            var outcome = await TextCleaner.clean(transcript: item.transcript, request: request, speech: speech, enabled: env["WISPAD_NUMBER_STYLE_MODEL"] == nil)
            if let model = env["WISPAD_NUMBER_STYLE_MODEL"], !xai.isEmpty {
                let route = TextCleaner.Route(api: .xaiCleanup, model: model, url: URL(string: "https://api.x.ai/v1/chat/completions")!,
                                              key: xai, provider: "xAI", isFallback: false)
                let reply = try await TextCleaner.send(system: CorrectionPrompt.system(for: request), user: CorrectionPrompt.userText(request),
                                                       route: route, maxTokens: 400, includeReasoning: false)
                let cleaned = CorrectionPrompt.cleanModelOutput(reply.content, fallback: item.transcript)
                // Même suite que l'app : garde-fou, puis format des dates et des nombres.
                let english = item.language == .english
                let guarded = FidelityGuard.check(transcript: item.transcript, corrected: cleaned)
                let dated = DateTimeWriter.apply(guarded, format: request.dateFormat, english: english)
                outcome = CleanupOutcome(text: NumberWriter.apply(dated, format: request.numberFormat, english: english),
                                         usage: UsageEvent(createdAt: Date(), api: .xaiCleanup, model: model, tokens: reply.tokens ?? TokenUsage(),
                                                           costUSD: nil, latencyMs: 0, succeeded: true))
            }
            let text = outcome.text
            let ok = item.expected.allSatisfy { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
                && !item.refused.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
            if ok { followed += 1 }
            let answered = outcome.usage?.succeeded == true ? "répondu \(outcome.usage?.latencyMs ?? 0) ms" : "sans réponse (\(outcome.usage?.failureCause.map { "\($0)" } ?? "-"))"
            print("NOMBRES \(ok ? "ok " : "NON") [\(item.inWords ? "contexte" : "chiffres")] \(outcome.usage?.model ?? "-") \(answered) « \(item.transcript) » → « \(text) »")
        }
        print("NOMBRES \(followed)/\(Self.cases.count) conformes")
    }
}
