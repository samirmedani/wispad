import Foundation

/// Suit les lectures successives d'un champ après un collage, sans accessibilité.
/// La dernière valeur où la dictée est encore reconnaissable sert de comparaison :
/// un champ vidé, envoyé ou remplacé ne doit pas effacer la correction vue juste avant.
public struct CorrectionWatch: Sendable {
    /// Lecture du champ. Une correction déjà partie au relevé suivant n'est pas inventée.
    public static let pollIntervalNanoseconds: UInt64 = 250_000_000
    /// Fenêtre après le collage. `pollCount` lectures espacées de `pollIntervalNanoseconds`.
    public static let windowNanoseconds: UInt64 = 30_000_000_000
    public static var pollCount: Int { Int(windowNanoseconds / pollIntervalNanoseconds) }
    /// Lectures d'affilée sans la dictée avant de conclure à l'envoi (2 s) : un mot en cours de frappe,
    /// un champ vidé pour être retapé ou un champ illisible un instant ne closent pas la surveillance.
    public static let graceSamples = 8

    public enum Stop: Equatable, Sendable {
        /// Champ vidé, message envoyé, ou texte qui ne contient plus la dictée.
        case fieldGone
        case appLeft
        case timeout
        case unreadable
        /// Une nouvelle dictée a clos la surveillance : on juge ce qui a déjà été vu.
        case interrupted
    }

    public struct Outcome: Equatable, Sendable {
        public var stop: Stop
        public var candidates: [CorrectionLearner.Candidate]
    }

    /// Une lecture. `sameElement` est faux quand l'accessibilité a recréé le champ.
    public struct FocusSample: Equatable, Sendable {
        public var sameApplication: Bool
        public var sameElement: Bool
        public var value: String?

        public init(sameApplication: Bool, sameElement: Bool, value: String?) {
            self.sameApplication = sameApplication
            self.sameElement = sameElement
            self.value = value
        }
    }

    public enum Step: Equatable, Sendable {
        /// `adoptElement` : le champ recréé contient encore la dictée, on le suit.
        case continueWatching(adoptElement: Bool)
        case stop(Outcome)
    }

    private let inserted: String
    private let known: [String]
    private var before: String?
    private var lastValid: String?
    private var misses = 0
    private var finished: Outcome?

    /// Une surveillance suit un texte livré dans un champ, après une dictée comme après « Coller la dernière
    /// dictée » : seulement si l'apprentissage est activé, jamais pour une sélection réécrite (le texte n'a pas
    /// été dicté mot pour mot) ni pour un texte que Wispad écrit lui-même dans sa fenêtre (essai du premier
    /// lancement, sans collage).
    public static func shouldStart(status: InsertionStatus, learnCorrections: Bool, selectionCommand: Bool, writtenByWispad: Bool) -> Bool {
        status.delivered && learnCorrections && !selectionCommand && !writtenByWispad
    }

    public init(inserted: String, known: [String]) {
        self.inserted = inserted
        self.known = known
    }

    public mutating func observe(_ sample: FocusSample) -> Step {
        if let finished { return .stop(finished) }
        if !sample.sameApplication { return .stop(finish(.appLeft)) }
        guard let value = sample.value else {
            guard before != nil else { return .stop(finish(.unreadable)) }
            return miss(.unreadable)
        }
        if before == nil {
            guard CorrectionLearner.insertedSpan(of: inserted, in: value) != nil else {
                // Le collage n'est pas encore là : on attend, sans suivre un autre champ.
                return .continueWatching(adoptElement: false)
            }
            before = value
            lastValid = value
            return .continueWatching(adoptElement: !sample.sameElement)
        }
        guard Self.recognizes(inserted: inserted, baseline: before ?? value, in: value) else {
            return miss(.fieldGone)
        }
        misses = 0
        lastValid = value
        return .continueWatching(adoptElement: !sample.sameElement)
    }

    /// La dictée n'est pas lue : `lastValid` reste la référence, sans suivre un autre champ.
    private mutating func miss(_ stop: Stop) -> Step {
        misses += 1
        return misses >= Self.graceSamples ? .stop(finish(stop)) : .continueWatching(adoptElement: false)
    }

    public mutating func timeOut() -> Outcome {
        finish(.timeout)
    }

    public mutating func interrupt() -> Outcome {
        finish(.interrupted)
    }

    private mutating func finish(_ stop: Stop) -> Outcome {
        if let finished { return finished }
        let candidates: [CorrectionLearner.Candidate]
        if let before, let lastValid {
            candidates = CorrectionLearner.candidates(inserted: inserted, before: before, after: lastValid, known: known)
        } else {
            candidates = []
        }
        let outcome = Outcome(stop: stop, candidates: candidates)
        finished = outcome
        return outcome
    }

    /// La dictée collée est-elle encore dans `value`, éventuellement retouchée ?
    static func recognizes(inserted: String, baseline: String, in value: String) -> Bool {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if CorrectionLearner.insertedSpan(of: inserted, in: value) != nil { return true }
        guard let span = CorrectionLearner.insertedSpan(of: inserted, in: baseline) else { return false }
        let baselineWords = CorrectionLearner.words(in: baseline)
        guard span.upperBound <= baselineWords.count else { return false }
        let target = Array(baselineWords[span])
        let all = CorrectionLearner.words(in: value)
        let minLength = max(1, target.count - 2)
        let maxLength = target.count + 1
        guard !target.isEmpty, all.count >= minLength else { return false }
        let lastStart = all.count - minLength
        var lower = max(0, span.lowerBound - 40)
        var upper = min(lastStart, span.lowerBound + 40)
        if lower > upper {
            lower = 0
            upper = lastStart
        }
        var starts = Array(lower...upper)
        if !starts.contains(lastStart) { starts.append(lastStart) }
        let ordered = starts.sorted { abs($0 - span.lowerBound) < abs($1 - span.lowerBound) }
        let lengths = [target.count, target.count - 1, target.count + 1, target.count - 2].filter {
            (minLength...maxLength).contains($0)
        }
        for start in ordered {
            for length in lengths {
                let end = start + length
                guard end <= all.count else { continue }
                if isRetouch(of: target, window: Array(all[start..<end])) { return true }
            }
        }
        return false
    }

    /// Fenêtre encore proche du texte collé : quelques mots retouchés, le reste en place.
    /// Un mot seul remplacé doit rester ressemblant ; le filtre du dictionnaire, lui, ne change pas.
    private static func isRetouch(of target: [String], window: [String]) -> Bool {
        if target == window { return true }
        guard !target.isEmpty, !window.isEmpty else { return false }
        let delta = window.count - target.count
        guard (-2...1).contains(delta) else { return false }
        let hunks = CorrectionLearner.replacements(target, window)
        guard !hunks.isEmpty else { return false }
        let removed = hunks.reduce(0) { $0 + $1.oldWords.count }
        let unchanged = target.count - removed
        guard removed > 0, removed <= 3 * CorrectionLearner.maxTermsPerDictation else { return false }
        if unchanged == 0 {
            guard hunks.count == 1, (1...3).contains(hunks[0].oldWords.count) else { return false }
            return similarity(hunks[0].oldWords, hunks[0].newWords) >= 0.45
        }
        guard unchanged * 2 >= target.count else { return false }
        return hunks.allSatisfy { (1...3).contains($0.oldWords.count) }
    }

    private static func similarity(_ old: [String], _ new: [String]) -> Double {
        let left = old.map(CorrectionLearner.key).joined()
        let right = new.map(CorrectionLearner.key).joined()
        if left == right { return 1 }
        let scale = max(left.count, right.count)
        guard scale > 0 else { return 0 }
        return 1 - Double(CorrectionLearner.levenshtein(left, right)) / Double(scale)
    }
}
