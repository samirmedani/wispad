import Foundation
import XCTest
@testable import WispadCore

/// Corpus fabriqué pour le banc, sans dictée ni correction provenant d'un utilisateur.
private struct LearningCase {
    let id: String
    let heard: String
    let corrected: String
    let useful: Bool
    var inserted: String { "Nous utilisons \(heard) dans ce projet." }
    var correctedSentence: String { "Nous utilisons \(corrected) dans ce projet." }
    var candidates: [CorrectionLearner.Candidate] {
        CorrectionLearner.candidates(inserted: inserted, before: inserted, after: correctedSentence, known: [])
    }
    static let corpus: [Self] = [
        .init(id: "brand-01", heard: "Sidance", corrected: "Seedance", useful: true),
        .init(id: "brand-02", heard: "open router", corrected: "OpenRouter", useful: true),
        .init(id: "brand-03", heard: "claudeflare", corrected: "Cloudflare", useful: true),
        .init(id: "brand-04", heard: "grafanna", corrected: "Grafana", useful: true),
        .init(id: "brand-05", heard: "kubermetes", corrected: "Kubernetes", useful: true),
        .init(id: "brand-06", heard: "terraforme", corrected: "Terraform", useful: true),
        .init(id: "brand-07", heard: "supabaze", corrected: "Supabase", useful: true),
        .init(id: "brand-08", heard: "postgress", corrected: "PostgreSQL", useful: true),
        .init(id: "brand-09", heard: "revencat", corrected: "RevenueCat", useful: true),
        .init(id: "brand-10", heard: "hugingface", corrected: "Hugging Face", useful: true),
        .init(id: "brand-11", heard: "swift ui", corrected: "SwiftUI", useful: true),
        .init(id: "brand-12", heard: "figema", corrected: "Figma", useful: true),
        .init(id: "ordinary-01", heard: "maison", corrected: "maisons", useful: false),
        .init(id: "ordinary-02", heard: "projet", corrected: "projets", useful: false),
        .init(id: "ordinary-03", heard: "bonjour", corrected: "Bonjour", useful: false),
        .init(id: "ordinary-04", heard: "commande", corrected: "Commande", useful: false),
        .init(id: "ordinary-05", heard: "bonjoru", corrected: "bonjour", useful: false),
        .init(id: "ordinary-06", heard: "univeristé", corrected: "université", useful: false),
        .init(id: "ordinary-07", heard: "pomme", corrected: "poire", useful: false),
        .init(id: "ordinary-08", heard: "DDR3", corrected: "DDR4", useful: false),
        .init(id: "ordinary-09", heard: "trois", corrected: "quatre", useful: false),
        .init(id: "ordinary-10", heard: "nous parlons", corrected: "nous parlerons", useful: false),
        .init(id: "ordinary-11", heard: "réunion", corrected: "Réunion", useful: false),
        .init(id: "ordinary-12", heard: "Bonjour", corrected: "Bonjour !", useful: false)
    ]
}

final class LearningBenchmarkTests: XCTestCase {
    /// Vérifie le filtre préalable, pas la qualité de Jev : les mots courants qui passent devront être jugés.
    func testLocalExtractionBenchmark() throws {
        var milliseconds: [Double] = []
        var missed: [String] = []
        var rejectedLocally = 0
        for item in LearningCase.corpus {
            let candidates = item.candidates
            if item.useful && !candidates.contains(where: { $0.corrected == item.corrected }) { missed.append(item.id) }
            if !item.useful && candidates.isEmpty { rejectedLocally += 1 }
            for _ in 0..<20 {
                let start = ContinuousClock.now
                _ = item.candidates
                let elapsed = start.duration(to: .now).components
                milliseconds.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            }
        }
        XCTAssertEqual(missed, [], "Le préfiltre a perdu des termes utiles : identifiants synthétiques seulement.")
        print(String(format: "LEARNING_LOCAL cases=%d positives=%d negative_prefilter_rejections=%d samples=%d p50_ms=%.3f p95_ms=%.3f",
                     LearningCase.corpus.count, LearningCase.corpus.filter(\.useful).count, rejectedLocally, milliseconds.count,
                     percentile(milliseconds, 0.50), percentile(milliseconds, 0.95)))
    }

    /// Explicite seulement, clés dédiées seulement. Deux passes : 48 cas, sans lire les données de l'app.
    func testLiveJevBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LEARNING_BENCH_LIVE"] == "1", "Banc Jev réseau non demandé.")
        let key = env["WISPAD_TEST_TYPESAFE_API_KEY"] ?? ""
        try XCTSkipUnless(!key.isEmpty, "Clé Jev dédiée aux tests absente.")
        let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: "", language: .french,
                                   keyterms: [], prompt: "", cleanupKey: env["WISPAD_TEST_DEEPSEEK_API_KEY"], judgeKey: key)
        var tp = 0, tn = 0, fp = 0, fn = 0, failures = 0, modelCalls = 0
        var latencies: [Double] = [], observedModels = Set<String>()
        for _ in 0..<2 {
            for item in LearningCase.corpus {
                let candidates = item.candidates
                var accepted = false
                if !candidates.isEmpty {
                    // Réserve conservatrice par cas, sans réessai non borné.
                    try SpendLedger.wispadDefault().reserve(0.02)
                    let start = ContinuousClock.now
                    let result = await TermJudge.judge(candidates, dictated: item.inserted, speech: speech)
                    let elapsed = start.duration(to: .now).components
                    latencies.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                    accepted = result.kept.contains { $0.term == item.corrected }
                    failures += result.usages.filter { !$0.succeeded }.count
                    modelCalls += result.usages.filter { $0.api != .typesafeJudge }.count
                    observedModels.formUnion(result.usages.map(\.model))
                }
                switch (item.useful, accepted) {
                case (true, true): tp += 1
                case (true, false): fn += 1
                case (false, true): fp += 1
                case (false, false): tn += 1
                }
            }
        }
        print(String(format: "LEARNING_LIVE tp=%d tn=%d fp=%d fn=%d failed_calls=%d correction_calls=%d p50_ms=%.1f p95_ms=%.1f", tp, tn, fp, fn, failures, modelCalls, percentile(latencies, 0.5), percentile(latencies, 0.95)))
        print("LEARNING_MODELS " + observedModels.sorted().joined(separator: ", "))
        XCTAssertEqual(failures, 0, "Des appels ont échoué : ne pas confondre indisponibilité et qualité.")
        XCTAssertEqual(fp, 0, "Le corpus contient des ajouts indésirables.")
        XCTAssertGreaterThanOrEqual(Double(tp) / Double(max(1, tp + fn)), 0.9, "Rappel inférieur à 90 % sur ce corpus synthétique.")
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}
