import Foundation
import XCTest
@testable import WispadCore

/// Autocorrections orales sur la vraie correction (consigne, modèle, garde-fou), en français et en anglais.
/// Réseau et payant (quelques centimes) : seulement via `scripts/live-test.sh SelfCorrectionLiveTests`,
/// avec les clés de test du coffre. DeepSeek si sa clé de test existe, sinon Grok (clé de test xAI).
final class SelfCorrectionLiveTests: XCTestCase {
    private struct Case: Sendable {
        var id: String
        var language: DictationLanguage
        var transcript: String
        /// Au moins une de ces formes doit rester (insensible à la casse).
        var keepAny: [String]
        /// Aucune de ces formes ne doit rester.
        var drop: [String]
    }

    private static let cases: [Case] = [
        Case(id: "fr-jour", language: .french, transcript: "on se voit mardi ah non non mercredi", keepAny: ["mercredi"], drop: ["mardi", "non"]),
        Case(id: "fr-nom", language: .french, transcript: "envoie le à paul non pardon à julie", keepAny: ["julie"], drop: ["paul", "pardon"]),
        Case(id: "fr-nombre", language: .french, transcript: "il faut trois enfin quatre serveurs", keepAny: ["4", "quatre"], drop: ["trois", " 3 "]),
        Case(id: "fr-begaiement", language: .french, transcript: "je je je pense que c'est bon", keepAny: ["pense"], drop: ["je je"]),
        Case(id: "fr-technique", language: .french, transcript: "le deploy non non le build a fail", keepAny: ["build"], drop: ["deploy"]),
        Case(id: "fr-quantite", language: .french, transcript: "réserve une table pour six personnes euh non pour huit", keepAny: ["8", "huit"], drop: ["six", " 6 "]),
        Case(id: "fr-dossier", language: .french, transcript: "mets le dans le dossier factures non attends dans le dossier devis", keepAny: ["devis"], drop: ["factures"]),
        Case(id: "fr-garde-non", language: .french, transcript: "je lui ai dit non pas question", keepAny: ["non"], drop: []),
        Case(id: "fr-garde-enfin", language: .french, transcript: "enfin une bonne nouvelle pour le projet", keepAny: ["enfin"], drop: []),
        Case(id: "fr-garde-plutot", language: .french, transcript: "je préfère plutôt le rouge que le bleu", keepAny: ["bleu"], drop: []),
        Case(id: "en-day", language: .english, transcript: "let's meet on tuesday no wait wednesday", keepAny: ["wednesday"], drop: ["tuesday"]),
        Case(id: "en-name", language: .english, transcript: "send it to mark sorry i mean julia", keepAny: ["julia"], drop: ["mark"]),
        Case(id: "en-number", language: .english, transcript: "we need three actually four servers", keepAny: ["4", "four"], drop: ["three", " 3 "]),
        Case(id: "en-stutter", language: .english, transcript: "i i i think it's fine", keepAny: ["think"], drop: ["i i"]),
        Case(id: "en-quantity", language: .english, transcript: "book a table for six uh no for eight people", keepAny: ["8", "eight"], drop: ["six", " 6 "]),
        Case(id: "en-folder", language: .english, transcript: "put it in the invoices folder scratch that the quotes folder", keepAny: ["quotes"], drop: ["invoices"]),
        Case(id: "en-keep-no", language: .english, transcript: "i told him no not today", keepAny: ["no"], drop: []),
        Case(id: "en-keep-rather", language: .english, transcript: "i'd rather take the red one than the blue one", keepAny: ["blue"], drop: []),
    ]

    func testSpokenSelfCorrections() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1", "Test réseau réservé à scripts/live-test.sh.")
        let deepSeek = env["WISPAD_LIVE_DEEPSEEK_KEY"] ?? ""
        let xai = env["WISPAD_LIVE_XAI_KEY"] ?? ""
        try XCTSkipUnless(!deepSeek.isEmpty || !xai.isEmpty, "Aucune clé de test de correction.")
        let runs = 2
        try SpendLedger.wispadDefault().reserve(Double(Self.cases.count * runs) * 0.006)
        var passed = 0
        var total = 0
        for item in Self.cases {
            let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: xai, language: item.language,
                                       keyterms: [], prompt: "", cleanupKey: deepSeek.isEmpty ? nil : deepSeek)
            let request = CorrectionRequest(transcript: item.transcript, structureDictation: true, language: item.language)
            for run in 1...runs {
                let outcome = await TextCleaner.clean(transcript: item.transcript, request: request, speech: speech, enabled: true)
                let text = " " + outcome.text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                    .replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: ",", with: " ") + " "
                let fold = { (form: String) in form.lowercased().folding(options: .diacriticInsensitive, locale: nil) }
                let kept = item.keepAny.contains { text.contains(fold($0)) }
                let dropped = item.drop.allSatisfy { form in
                    let needle = fold(form)
                    return needle.hasPrefix(" ") ? !text.contains(needle) : !text.contains(" \(needle) ") && !text.contains(" \(needle)'")
                }
                let ok = outcome.usage?.succeeded == true && kept && dropped
                total += 1
                if ok { passed += 1 }
                print("AUTOCORRECTION \(item.id) passe=\(run) \(ok ? "ok" : "ÉCHEC") → \(outcome.text)")
            }
        }
        print("AUTOCORRECTION total \(passed)/\(total)")
        XCTAssertGreaterThanOrEqual(Double(passed) / Double(total), 0.85, "Autocorrections orales trop souvent manquées.")
    }
}
