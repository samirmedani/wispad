import Foundation
import XCTest
@testable import WispadCore

/// Banc des modèles de correction, lancé seulement par scripts/model-bench.sh : les dictées privées du banc du texte
/// (étapes correction et mots), corrigées par chaque modèle à tour de rôle, avec les seules clés de test WISPAD_TEST_*.
/// Les résultats vont dans le dossier privé du banc ; la sortie ne montre que des comptes et des coûts.
final class ModelBenchLiveTests: XCTestCase {
    struct Model {
        var account: String
        var model: String
        var key: String
        /// Dollars par million de jetons : entrée hors cache, entrée en cache, sortie.
        var input: Double
        var cached: Double
        var output: Double
    }

    struct Call: Codable {
        var model: String
        var set: String
        var id: String
        var group: String
        var input: String
        var text: String
        var corrected: Bool
        var latencyMs: Int?
        var inputTokens: Int
        var cachedTokens: Int
        var outputTokens: Int
        var costUSD: Double
    }

    struct Item {
        var set: String
        var id: String
        var group: String
        var request: CorrectionRequest
    }

    func testModelBench() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1" && env["WISPAD_MODEL_BENCH"] == "1",
                          "Banc des modèles réservé à scripts/model-bench.sh.")
        guard let dir = env["WISPAD_TEXT_BENCH_DIR"], !dir.isEmpty, let out = env["WISPAD_MODEL_BENCH_OUT"], !out.isEmpty else {
            throw TextBenchLiveTests.BenchError("WISPAD_TEXT_BENCH_DIR ou WISPAD_MODEL_BENCH_OUT absent.")
        }
        let models = try (env["WISPAD_MODEL_BENCH_MODELS"] ?? "").split(separator: ",").map { try Self.model(String($0), env: env) }
        guard !models.isEmpty else { throw TextBenchLiveTests.BenchError("WISPAD_MODEL_BENCH_MODELS vide.") }
        let items = try await Self.items(URL(fileURLWithPath: dir, isDirectory: true))
        let limit = Double(env["WISPAD_MODEL_BENCH_RESERVE"] ?? "") ?? 0.40
        let ledger = SpendLedger.wispadDefault()
        try ledger.reserve(limit)
        var spent = 0.0
        var calls: [Call] = []
        do {
            for (index, item) in items.enumerated() {
                // Chaque dictée passe chez tous les modèles, dans un ordre qui tourne : une dérive du réseau les touche tous.
                for offset in models.indices {
                    let model = models[(index + offset) % models.count]
                    guard spent + Self.worstUSD(item.request, model) <= limit else {
                        throw TextBenchLiveTests.BenchError("réservation épuisée : banc arrêté avant de la dépasser.")
                    }
                    let call = await Self.correct(item, model: model)
                    spent += call.costUSD
                    calls.append(call)
                }
            }
        } catch {
            try? ledger.settle(reserved: limit, actual: spent)
            try? TextBenchLiveTests.writePrivate(calls, to: URL(fileURLWithPath: out))
            throw error
        }
        try ledger.settle(reserved: limit, actual: spent)
        try TextBenchLiveTests.writePrivate(calls, to: URL(fileURLWithPath: out))
        for model in models {
            let mine = calls.filter { $0.model == model.model }
            print("BANC-MODELES \(model.model) : \(mine.filter(\.corrected).count)/\(mine.count) corrigées ; "
                  + "coût \(String(format: "%.4f", mine.reduce(0) { $0 + $1.costUSD })) $")
        }
        print("BANC-MODELES total \(String(format: "%.4f", spent)) $ (réservé \(String(format: "%.2f", limit)) $)")
    }

    /// Les requêtes du banc du texte, construites comme lui : étape correction, puis étape mots (texte retenu comme
    /// l'app, seconde écoute comprise) si sa référence privée existe.
    static func items(_ directory: URL) async throws -> [Item] {
        let correction = try JSONDecoder().decode(TextBenchLiveTests.CorrectionCorpus.self,
                                                  from: Data(contentsOf: directory.appendingPathComponent("correction.json")))
        var items = correction.cases.map {
            Item(set: "correction", id: $0.id, group: $0.group,
                 request: TextBenchLiveTests.correctionRequest($0.transcript, app: $0.app, previous: $0.previous,
                                                               dictionary: correction.dictionary))
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("mots.json")) else { return items }
        let words = try JSONDecoder().decode(TextBenchLiveTests.WordsCorpus.self, from: data)
        let spelling = await TextBenchLiveTests.spelling()
        for item in words.cases {
            let (_, request) = await TextBenchLiveTests.retainHeard(item, spelling: spelling)
            if let request { items.append(Item(set: "mots", id: item.id, group: item.group, request: request)) }
        }
        return items
    }

    /// Une correction de l'app avec ce seul modèle (choisi dans Fournisseurs, sans relais), sans second essai : un échec
    /// compte comme tel.
    static func correct(_ item: Item, model: Model) async -> Call {
        let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: "", language: .french, keyterms: [],
                                   prompt: "", cleanupChoice: CleanupChoice(account: model.account, model: model.model),
                                   chosenCleanupKey: model.key)
        let outcome = await TextCleaner.clean(transcript: item.request.transcript, request: item.request, speech: speech, enabled: true)
        let usages = outcome.failedUsages + [outcome.usage].compactMap { $0 }
        let cost = usages.reduce(0) { total, usage in
            total + (Double(usage.tokens.input) * model.input + Double(usage.tokens.cachedInput) * model.cached
                + Double(usage.tokens.output) * model.output) / 1_000_000
        }
        let succeeded = outcome.usage?.succeeded == true
        return Call(model: model.model, set: item.set, id: item.id, group: item.group, input: item.request.transcript,
                    text: FranglaisNormalizer.normalize(outcome.text), corrected: succeeded,
                    latencyMs: succeeded ? outcome.usage?.latencyMs : nil,
                    inputTokens: outcome.usage?.tokens.input ?? 0, cachedTokens: outcome.usage?.tokens.cachedInput ?? 0,
                    outputTokens: outcome.usage?.tokens.output ?? 0, costUSD: cost)
    }

    /// Pire coût d'un appel : toute l'entrée hors cache, à un jeton pour 2,5 caractères, et la sortie maximale.
    static func worstUSD(_ request: CorrectionRequest, _ model: Model) -> Double {
        let characters = CorrectionPrompt.system(for: request).count + CorrectionPrompt.userText(request).count
        let output = min(4_096, max(400, request.transcript.count / 2))
        return (Double(characters) / 2.5 * model.input + Double(output) * model.output) / 1_000_000
    }

    /// « compte:modèle:entrée:cache:sortie » ; la clé de test du compte vient de l'environnement du seul processus.
    static func model(_ spec: String, env: [String: String]) throws -> Model {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 5, let input = Double(parts[2]), let cached = Double(parts[3]), let output = Double(parts[4]) else {
            throw TextBenchLiveTests.BenchError("modèle mal décrit : compte:modèle:entrée:cache:sortie.")
        }
        let variable = parts[0] == CleanupModel.deepSeekAccount ? "WISPAD_LIVE_DEEPSEEK_KEY" : "WISPAD_LIVE_XAI_KEY"
        guard let key = env[variable], !key.isEmpty else { throw TextBenchLiveTests.BenchError("\(variable) absente.") }
        return Model(account: parts[0], model: parts[1], key: key, input: input, cached: cached, output: output)
    }
}
