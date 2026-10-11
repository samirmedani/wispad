import Foundation
import XCTest
@testable import WispadCore

/// Énumérations dites sans annonce (« tomate, yaourt, pain ») mises en liste à puces par la vraie correction, et
/// phrases qui doivent le rester. Réseau et payant (quelques centimes) : seulement via
/// `scripts/live-test.sh ImplicitListLiveTests`, avec les clés de test du coffre (DeepSeek, sinon Grok).
final class ImplicitListLiveTests: XCTestCase {
    private struct Case: Sendable {
        var id: String
        var language: DictationLanguage
        var transcript: String
        /// Nombre de puces attendu ; 0 : la dictée reste une phrase.
        var bullets: Int
        /// Mots qui doivent rester (insensible à la casse et aux accents).
        var keep: [String]
    }

    private static let cases: [Case] = [
        Case(id: "fr-courses", language: .french, transcript: "Tomate, yaourt, pain.", bullets: 3, keep: ["tomate", "yaourt", "pain"]),
        Case(id: "fr-courses-intro", language: .french, transcript: "Pour les courses, il me faut des tomates, du yaourt et du pain.",
             bullets: 3, keep: ["courses", "tomates", "yaourt", "pain"]),
        Case(id: "fr-taches", language: .french, transcript: "Demain je dois appeler le plombier, envoyer le devis et réserver le train.",
             bullets: 3, keep: ["plombier", "devis", "train"]),
        Case(id: "fr-quatre", language: .french, transcript: "Il faut prendre les câbles, l'écran, le clavier et la souris.",
             bullets: 4, keep: ["cables", "ecran", "clavier", "souris"]),
        Case(id: "en-groceries", language: .english, transcript: "Eggs, milk, bread.", bullets: 3, keep: ["eggs", "milk", "bread"]),
        Case(id: "en-intro", language: .english, transcript: "I need to buy eggs, milk and bread.", bullets: 3, keep: ["eggs", "milk", "bread"]),
        Case(id: "fr-garde-phrase", language: .french, transcript: "J'ai vu Paul, Marc et Julie hier au cinéma.", bullets: 0, keep: ["julie", "cinema"]),
        Case(id: "fr-garde-deux", language: .french, transcript: "Je prends le train puis le bus.", bullets: 0, keep: ["train", "bus"]),
        Case(id: "fr-garde-recit", language: .french, transcript: "Hier je suis allé au marché, j'ai acheté du pain et je suis rentré chez moi.",
             bullets: 0, keep: ["marche", "pain"]),
        Case(id: "en-keep", language: .english, transcript: "I saw Paul, Mark and Julia at the cinema yesterday.", bullets: 0, keep: ["julia", "cinema"]),
    ]

    func testImplicitListsAreFormatted() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1", "Test réseau réservé à scripts/live-test.sh.")
        let deepSeek = env["WISPAD_LIVE_DEEPSEEK_KEY"] ?? ""
        let xai = env["WISPAD_LIVE_XAI_KEY"] ?? ""
        try XCTSkipUnless(!deepSeek.isEmpty || !xai.isEmpty, "Aucune clé de test de correction.")
        let runs = 2
        try SpendLedger.wispadDefault().reserve(Double(Self.cases.count * runs) * 0.006)
        let fold = { (text: String) in text.lowercased().folding(options: .diacriticInsensitive, locale: nil) }
        var passed = 0
        var total = 0
        for item in Self.cases {
            let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: xai, language: item.language,
                                       keyterms: [], prompt: "", cleanupKey: deepSeek.isEmpty ? nil : deepSeek)
            let request = CorrectionRequest(transcript: item.transcript, structureDictation: true, language: item.language)
            for run in 1...runs {
                let outcome = await TextCleaner.clean(transcript: item.transcript, request: request, speech: speech, enabled: true)
                let bullets = outcome.text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.count
                let kept = item.keep.allSatisfy { fold(outcome.text).contains($0) }
                let ok = outcome.usage?.succeeded == true && bullets == item.bullets && kept
                total += 1
                if ok { passed += 1 }
                let call = outcome.usage?.succeeded == true ? "" : " appel=échec"
                print("LISTE \(item.id) passe=\(run) \(ok ? "ok" : "ÉCHEC") puces=\(bullets)\(call) → \(outcome.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        print("LISTE total \(passed)/\(total)")
        XCTAssertGreaterThanOrEqual(Double(passed) / Double(total), 0.85, "Listes implicites trop souvent manquées ou inventées.")
    }
}
