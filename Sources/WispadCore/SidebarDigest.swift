import Foundation

/// Chiffres de la barre latérale : la journée de dictée en un coup d'œil (mots et dictées du jour, mots des sept
/// derniers jours, série de jours d'affilée) et la dernière dictée réussie. Calculé sur ce Mac depuis l'historique ;
/// une dictée sans texte (annulée, en échec) ne compte pas.
public struct SidebarDigest: Equatable, Sendable {
    public struct LastDictation: Equatable, Sendable {
        public var id: String
        public var text: String
        public var app: String?
        public var date: Date
    }

    public var wordsToday: Int
    public var dictationsToday: Int
    /// Mots dictés par jour, du plus ancien à aujourd'hui (sept valeurs).
    public var wordsByDay: [Int]
    /// Jours d'affilée avec au moins une dictée, en finissant aujourd'hui, ou hier si aujourd'hui est encore vide.
    public var streak: Int
    public var last: LastDictation?

    public static let days = 7

    /// `records` dans n'importe quel ordre.
    public static func make(records: [DictationRecord], now: Date = Date(), calendar: Calendar = .current) -> SidebarDigest {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var wordsByDay = Array(repeating: 0, count: days)
        var dictationsToday = 0
        var dayStarts = Set<Date>()
        var last: DictationRecord?
        for record in records where !record.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard record.createdAt <= now else { continue }
            let day = calendar.startOfDay(for: record.createdAt)
            dayStarts.insert(day)
            if day >= firstDay, let offset = calendar.dateComponents([.day], from: firstDay, to: day).day,
               wordsByDay.indices.contains(offset) {
                wordsByDay[offset] += max(0, record.wordCount)
                if day == today { dictationsToday += 1 }
            }
            if last.map({ record.createdAt > $0.createdAt }) ?? true { last = record }
        }
        return SidebarDigest(
            wordsToday: wordsByDay[days - 1],
            dictationsToday: dictationsToday,
            wordsByDay: wordsByDay,
            streak: streak(dayStarts, today: today, calendar: calendar),
            last: last.map { record in
                let text = record.finalText.split(whereSeparator: \.isNewline).joined(separator: " ")
                return LastDictation(id: record.id, text: text, app: record.targetApp, date: record.createdAt)
            })
    }

    private static func streak(_ days: Set<Date>, today: Date, calendar: Calendar) -> Int {
        var day = today
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today), days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}
