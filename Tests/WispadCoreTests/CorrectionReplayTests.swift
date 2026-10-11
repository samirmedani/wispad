import Foundation
import XCTest
@testable import WispadCore

/// Rejoue la vraie correction (consigne, appel DeepSeek, garde-fou) sur des dictées exportées dans un fichier local,
/// jamais dans le dépôt, pour comparer deux versions de la consigne sur les mêmes textes.
///   WISPAD_LIVE_TESTS=1 WISPAD_CORRECTION_REPLAY=<entrée.json> WISPAD_CORRECTION_REPLAY_OUT=<sortie.json>
///   WISPAD_LIVE_DEEPSEEK_KEY=… swift test --filter CorrectionReplayTests
/// Entrée : [{"id", "transcript", "app", "previous": [..], "dictionary": [..]}]. Rien n'est journalisé.
final class CorrectionReplayTests: XCTestCase {
    private struct Case: Codable, Sendable {
        var id: String
        var transcript: String
        var app: String?
        var previous: [String]
        var dictionary: [String]
    }

    private struct Outcome: Codable, Sendable {
        var id: String
        var text: String
        var corrected: Bool
    }

    func testReplayCorrection() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1", "Rejeu réseau réservé à la passe explicite.")
        let key = env["WISPAD_LIVE_DEEPSEEK_KEY"] ?? ""
        guard let input = env["WISPAD_CORRECTION_REPLAY"], let output = env["WISPAD_CORRECTION_REPLAY_OUT"], !key.isEmpty else {
            throw XCTSkip("Fichiers de rejeu ou clé absents.")
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: "", language: .french,
                                   keyterms: [], prompt: "", cleanupKey: key)
        var outcomes: [Outcome] = []
        // Quelques appels à la fois : au-delà, DeepSeek ralentit et le délai de l'app rendrait le texte brut.
        for batch in stride(from: 0, to: cases.count, by: 6).map({ Array(cases[$0..<min($0 + 6, cases.count)]) }) {
            let results = await withTaskGroup(of: Outcome.self) { group in
                for item in batch {
                    group.addTask { await Self.replay(item, speech: speech) }
                }
                return await group.reduce(into: [Outcome]()) { $0.append($1) }
            }
            outcomes += results
        }
        let order = Dictionary(uniqueKeysWithValues: cases.enumerated().map { ($1.id, $0) })
        outcomes.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(outcomes).write(to: URL(fileURLWithPath: output))
        print("REJEU cas=\(outcomes.count) corrigés=\(outcomes.filter(\.corrected).count)")
    }

    private static func replay(_ item: Case, speech: SpeechRequest) async -> Outcome {
        let request = CorrectionRequest(transcript: item.transcript, dictionary: item.dictionary, appName: item.app,
                                        previousDictations: item.previous)
        // Un second essai si le service n'a pas répondu à temps : on compare des corrections, pas des délais.
        for _ in 0..<2 {
            let outcome = await TextCleaner.clean(transcript: item.transcript, request: request, speech: speech, enabled: true)
            if outcome.usage?.succeeded == true {
                return Outcome(id: item.id, text: outcome.text, corrected: true)
            }
        }
        return Outcome(id: item.id, text: item.transcript, corrected: false)
    }
}
