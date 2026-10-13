import Foundation

public enum StatsPeriod: String, CaseIterable, Sendable, Codable {
    case today
    case days7
    case days30
    case all

    public var title: String {
        switch self {
        case .today: return "Aujourd'hui"
        case .days7: return "7 jours"
        case .days30: return "30 jours"
        case .all: return "Tout"
        }
    }
}

public struct DictationSample: Equatable, Sendable {
    public var createdAt: Date
    public var wordCount: Int
    public var durationSeconds: Double
    public var usageCategory: String?

    public init(createdAt: Date, wordCount: Int, durationSeconds: Double, usageCategory: String? = nil) {
        self.createdAt = createdAt
        self.wordCount = wordCount
        self.durationSeconds = durationSeconds
        self.usageCategory = usageCategory
    }
}

public struct StatsSummary: Equatable, Sendable {
    public struct UsageCount: Equatable, Sendable {
        public var label: String
        public var count: Int

        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    public var words: Int
    public var sessions: Int
    public var audioSeconds: Double
    public var wordsPerMinute: Double?
    public var savedSeconds: Double
    public var usageCounts: [UsageCount]

    public init(
        words: Int,
        sessions: Int,
        audioSeconds: Double,
        wordsPerMinute: Double?,
        savedSeconds: Double,
        usageCounts: [UsageCount]
    ) {
        self.words = words
        self.sessions = sessions
        self.audioSeconds = audioSeconds
        self.wordsPerMinute = wordsPerMinute
        self.savedSeconds = savedSeconds
        self.usageCounts = usageCounts
    }
}

public enum StatsCalculator {
    public static func filter(
        samples: [DictationSample],
        period: StatsPeriod,
        now: Date,
        calendar: Calendar = .current
    ) -> [DictationSample] {
        let start: Date?
        switch period {
        case .today:
            start = calendar.startOfDay(for: now)
        case .days7:
            start = calendar.date(byAdding: .day, value: -7, to: now)
        case .days30:
            start = calendar.date(byAdding: .day, value: -30, to: now)
        case .all:
            start = nil
        }
        guard let start else { return samples }
        return samples.filter { $0.createdAt >= start }
    }

    /// Time saved compares dictated audio with typing at `typingWordsPerMinute`.
    public static func summary(samples: [DictationSample], typingWordsPerMinute: Double) -> StatsSummary {
        let words = samples.reduce(0) { $0 + max(0, $1.wordCount) }
        let seconds = samples.reduce(0.0) { $0 + max(0, $1.durationSeconds) }
        let minutes = seconds / 60
        let wpm = minutes > 0.01 ? Double(words) / minutes : nil
        let typingSeconds = typingWordsPerMinute > 0 ? Double(words) / typingWordsPerMinute * 60 : 0
        var counts: [String: Int] = [:]
        for sample in samples {
            let label = sample.usageCategory ?? UsageKind.other.rawValue
            counts[label, default: 0] += 1
        }
        let usage = counts.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }.map { StatsSummary.UsageCount(label: $0.key, count: $0.value) }
        return StatsSummary(
            words: words,
            sessions: samples.count,
            audioSeconds: seconds,
            wordsPerMinute: wpm,
            savedSeconds: max(0, typingSeconds - seconds),
            usageCounts: usage
        )
    }
}

public enum DurationFormat {
    public static func audio(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)min" }
        if minutes > 0 { return "\(minutes)min \(secs)s" }
        return "\(secs)s"
    }

    public static func saved(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Secondes entières, jamais négatives. Une durée lue d'une base abîmée ne fait pas planter la conversion en
    /// `Int` : NaN compte pour 0, une durée infinie ou démesurée s'arrête au plus grand nombre convertible.
    static func wholeSeconds(_ seconds: Double) -> Int {
        let rounded = seconds.rounded()
        guard rounded > 0 else { return 0 }
        return Int(min(rounded, Double(Int.max).nextDown))
    }
}

public enum WordCount {
    public static func count(_ text: String) -> Int {
        func isListMarker(_ token: Substring) -> Bool {
            if ["-", "*", "+", "•"].contains(token) { return true }
            guard token.last == "." || token.last == ")" else { return false }
            let digits = token.dropLast()
            return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
        }

        var count = 0
        var fence: (character: Character, length: Int)?
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            count += tokens.count
            if fence == nil, tokens.count > 1, let first = tokens.first, isListMarker(first) {
                count -= 1
            }

            let content = line.drop(while: { $0.isWhitespace })
            guard let head = content.first, head == "`" || head == "~" else { continue }
            let run = content.prefix(while: { $0 == head }).count
            guard run >= 3 else { continue }
            if let current = fence {
                if current.character == head, run >= current.length,
                   content.dropFirst(run).allSatisfy({ $0.isWhitespace }) {
                    fence = nil
                }
            } else {
                fence = (head, run)
            }
        }
        return count
    }
}
