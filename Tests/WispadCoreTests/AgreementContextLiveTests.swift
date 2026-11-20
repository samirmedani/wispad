import Foundation
import XCTest
@testable import WispadCore

/// Exemples fictifs uniquement, via scripts/live-test.sh et la clé dédiée.
final class AgreementContextLiveTests: XCTestCase {
    func testAgreementFollowsTheReferent() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1", "Test réseau à la demande.")
        let key = env["WISPAD_LIVE_DEEPSEEK_KEY"] ?? ""
        try XCTSkipUnless(!key.isEmpty, "Clé DeepSeek de test absente.")
        let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: "", language: .french,
                                   keyterms: [], prompt: "", cleanupKey: key)
        let ledger = SpendLedger.wispadDefault()
        let cases: [(name: String, heard: String, before: String?, window: String?, expected: String)] = [
            ("suite singulière", "ils regardent encore le calendrier du dossier", "Paul a reçu le dossier.\n\n", nil,
             "il regarde encore"),
            ("liaison ambiguë", "ils étaient encore seuls dans le bureau quand le téléphone a sonné",
             "Hugo était de garde. Il était seul dans le bureau.\n\n", nil, "il était encore seul"),
            ("suite plurielle", "elle prépare donc la réponse pour le client",
             "Les deux assistantes sont arrivées. Elles préparent la réponse pour le client.\n\n", nil, "elles préparent"),
            ("changement de sujet", "les techniciens sont arrivés et ils regardent le calendrier",
             "Paul a reçu le dossier.\n\n", nil, "ils regardent le calendrier"),
            ("nouveau brouillon", "ils étaient déjà prêts à partir", "", nil, "ils étaient déjà prêts"),
            ("fil visible", "ils regardent encore le calendrier du dossier", "",
             "Paul est seul à vérifier le calendrier de ce dossier. Où en est-il ?", "il regarde encore"),
            ("forme citée", "dans ce paragraphe remplace « il » par « il » comme dans la première phrase",
             nil, nil, "« il » par « il »"),
        ]
        let reserved = Double(cases.count) * 0.003
        try ledger.reserve(reserved)
        var cost = 0.0
        for item in cases {
            var request = CorrectionRequest(transcript: item.heard,
                                            previousDictations: ["Les collègues de Paul attendent des nouvelles."],
                                            windowText: item.window, language: .french)
            request.textBeforeCursor = item.before
            request.windowMayResolveAgreement = item.window != nil
            let result = await TextCleaner.clean(transcript: item.heard, request: request, speech: speech, enabled: true)
            cost += result.usage?.costUSD ?? 0.003
            XCTAssertEqual(result.usage?.succeeded, true, item.name)
            XCTAssertTrue(result.text.lowercased().contains(item.expected), "\(item.name) : \(result.text)")
        }
        try ledger.settle(reserved: reserved, actual: cost)
    }
}
