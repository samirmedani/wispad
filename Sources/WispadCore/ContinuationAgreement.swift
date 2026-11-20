import Foundation

/// Filet local pour une reprise littérale du sujet et du prédicat déjà écrits dans le brouillon.
enum ContinuationAgreement {
    private static let onset = try! NSRegularExpression(pattern: #"^\s*(il|ils|elle|elles) +([\p{L}]+)\b"#, options: .caseInsensitive)
    private static let opposite = ["il": "ils", "ils": "il", "elle": "elles", "elles": "elle"]
    private static let linkWords: Set<String> = ["encore", "toujours", "donc", "déjà"]
    private static let clauses = CharacterSet(charactersIn: ".!?;:\n\r")
    private static let letters = try! NSRegularExpression(pattern: #"[\p{L}]+"#)

    static func reapply(in text: String, after before: String?) -> String {
        guard let before, let previous = before.components(separatedBy: clauses).last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return text }
        let earlier = previous as NSString
        let written = text as NSString
        guard let lead = onset.firstMatch(in: text, range: NSRange(location: 0, length: written.length)),
              let prior = onset.firstMatch(in: previous, range: NSRange(location: 0, length: earlier.length)) else { return text }
        let pronoun = written.substring(with: lead.range(at: 1))
        let referent = earlier.substring(with: prior.range(at: 1)).lowercased()
        guard opposite[pronoun.lowercased()] == referent else { return text }

        let verb = written.substring(with: lead.range(at: 2)).lowercased()
        let priorVerb = earlier.substring(with: prior.range(at: 2)).lowercased()
        let (singular, plural) = referent.hasSuffix("s") ? (verb, priorVerb) : (priorVerb, verb)
        guard (singular.hasSuffix("e") && plural == singular + "nt")
              || (singular.hasSuffix("ait") && plural == String(singular.dropLast()) + "ent") else { return text }

        let earlierBody = bodyWords(in: previous, after: NSMaxRange(prior.range))
        let currentClause = text.components(separatedBy: clauses).first ?? text
        let writtenBody = bodyWords(in: currentClause, after: NSMaxRange(lead.range))
        let repeated = writtenBody.drop(while: { linkWords.contains($0.0) })
        guard repeated.count < writtenBody.count, repeated.count >= 3, earlierBody.count >= 3 else { return text }
        let oldHead = earlierBody[0].0
        let newHead = repeated[repeated.startIndex].0
        // Pour le premier attribut d'« être », seul le -s régulier d'un mot déjà présent peut varier.
        let hasAdjectiveEnding = referent.hasSuffix("s") ? oldHead == newHead + "s" : newHead == oldHead + "s"
        let sameAdjective = singular == "était" && hasAdjectiveEnding
        guard oldHead == newHead || sameAdjective else { return text }
        let oldTail = earlierBody.dropFirst().prefix(4).map(\.0)
        let newTail = repeated.dropFirst().prefix(oldTail.count).map(\.0)
        guard oldTail == newTail else { return text }

        let result = NSMutableString(string: text)
        if sameAdjective { result.replaceCharacters(in: repeated[repeated.startIndex].1, with: oldHead) }
        result.replaceCharacters(in: lead.range(at: 2), with: priorVerb)
        result.replaceCharacters(in: lead.range(at: 1), with: pronoun.first?.isUppercase == true ? referent.capitalized : referent)
        return result as String
    }

    private static func bodyWords(in text: String, after start: Int) -> [(String, NSRange)] {
        let source = text as NSString
        guard start < source.length else { return [] }
        let range = NSRange(location: start, length: source.length - start)
        return letters.matches(in: text, range: range).map { (source.substring(with: $0.range).lowercased(), $0.range) }
    }
}
