import Foundation
import CoreFoundation

/// Jev (TypeSafe) : modèle de décision qui renvoie, pour chaque mot corrigé, la probabilité qu'il mérite
/// le dictionnaire. Les questions sont en anglais, sa langue la mieux maîtrisée.
public enum JevJudge {
    public static let model = "jev-latest"
    static let url = URL(string: "https://api.typesafe.ai/v1/systemone")!
    typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let httpTransport: HTTPTransport = { try await URLSession.shared.data(for: $0) }

    static func body(_ candidates: [CorrectionLearner.Candidate], dictated: String) -> [String: Any] {
        var questions: [String: Any] = [:]
        for index in candidates.indices {
            let item = "`corrections[\(index)].corrected`"
            questions["c\(index)"] = [
                "type": "noul",
                "instructions": "Should \(item) be added to the user's personal speech-recognition dictionary?",
                "criteria": [
                    "true": "\(item) is a specific term whose spelling cannot be guessed by ear: a brand, product, software, company, uncommon person or place name, acronym, technical jargon, or a rare or foreign word; and `corrections[\(index)].heard` looks like the speech recognizer mishearing it.",
                    "false": "\(item) is a common French or English word (even capitalized), a very common first name or place, a typo or accent fix, grammar, agreement or conjugation, punctuation, a rewording, a change of mind or meaning, a number, or a swear word."
                ]
            ]
        }
        return [
            "model": model,
            "state": [
                "dictated_sentence": TermJudge.excerpt(dictated, around: candidates.first?.heard ?? ""),
                "corrections": candidates.map { ["heard": $0.heard, "corrected": $0.corrected] }
            ],
            "questions": questions
        ]
    }

    /// Probabilités dans l'ordre des candidats, ou nil si Jev n'a pas répondu.
    static func parse(_ data: Data, count: Int) -> (scores: [Double], inputTokens: Int?, model: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any] else { return nil }
        var scores: [Double] = []
        for index in 0..<count {
            guard let answer = answers["c\(index)"] as? [String: Any],
                  let number = answer["noul"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = answer["noul"] as? Double,
                  value.isFinite, (0...1).contains(value) else { return nil }
            scores.append(value)
        }
        return (scores, inputTokens(object), object["model"] as? String ?? model)
    }

    private static func inputTokens(_ object: [String: Any]) -> Int? {
        guard let usage = object["usage"] as? [String: Any],
              let count = TokenUsage.nonnegativeInteger(usage["input_tokens"]) else { return nil }
        return count
    }

    static func scores(_ candidates: [CorrectionLearner.Candidate], dictated: String, key: String,
                       transport: @escaping HTTPTransport = httpTransport) async -> ([Double]?, UsageEvent) {
        let started = Date()
        func failed() -> UsageEvent {
            UsageEvent(createdAt: started, api: .typesafeJudge, model: model, costUSD: nil,
                       latencyMs: Int(Date().timeIntervalSince(started) * 1_000), succeeded: false)
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body(candidates, dictated: dictated))
            request.timeoutInterval = 5
            let (data, response) = try await transport(request)
            guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return (nil, failed()) }
            let result = parse(data, count: candidates.count)
            let billedModel = object["model"] as? String ?? model
            let tokens = inputTokens(object).map { TokenUsage(input: $0) }
            let usage = UsageEvent(
                createdAt: started, api: .typesafeJudge, model: billedModel, tokens: tokens ?? TokenUsage(),
                costUSD: tokens.flatMap { Pricing.tokenCost(model: billedModel, tokens: $0, at: started) },
                latencyMs: Int(Date().timeIntervalSince(started) * 1_000), succeeded: result != nil
            )
            return (result?.scores, usage)
        } catch {
            return (nil, failed())
        }
    }
}
