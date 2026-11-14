import Foundation
import XCTest
@testable import WispadCore

final class SidebarDigestTests: XCTestCase {
    /// Vendredi 13 novembre 2026, 22 h UTC.
    private let now = Date(timeIntervalSince1970: 1_794_607_200)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func record(_ text: String, words: Int, daysAgo: Int, hour: Int = 10, app: String? = "Slack") -> DictationRecord {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        let date = calendar.date(byAdding: .hour, value: hour, to: day)!
        return DictationRecord(createdAt: date, finalText: text, rawText: text, durationSeconds: 3, wordCount: words,
                               provider: "xai", model: "test", targetApp: app, insertionStatus: "inserted")
    }

    func testCountsTodayAndTheLastSevenDays() {
        let digest = SidebarDigest.make(records: [
            record("Bonjour", words: 10, daysAgo: 0, hour: 9),
            record("Ça va", words: 5, daysAgo: 0, hour: 20),
            record("Hier", words: 7, daysAgo: 1),
            record("Il y a six jours", words: 3, daysAgo: 6),
            record("Trop ancien", words: 100, daysAgo: 7),
        ], now: now, calendar: calendar)
        XCTAssertEqual(digest.wordsToday, 15)
        XCTAssertEqual(digest.dictationsToday, 2)
        XCTAssertEqual(digest.wordsByDay, [3, 0, 0, 0, 0, 7, 15])
    }

    func testIgnoresEmptyDictationsAndKeepsTheLatestOne() {
        let digest = SidebarDigest.make(records: [
            record("Plus ancienne", words: 2, daysAgo: 0, hour: 8, app: "Mail"),
            record("  ", words: 9, daysAgo: 0, hour: 21),
            record("Je regarde ça ce soir\net je te fais un retour.", words: 11, daysAgo: 0, hour: 20),
        ], now: now, calendar: calendar)
        XCTAssertEqual(digest.dictationsToday, 2, "une dictée sans texte n'est pas comptée")
        XCTAssertEqual(digest.wordsToday, 13)
        XCTAssertEqual(digest.last?.text, "Je regarde ça ce soir et je te fais un retour.", "sur une ligne")
        XCTAssertEqual(digest.last?.app, "Slack")
    }

    func testStreakEndsTodayOrYesterday() {
        let running = SidebarDigest.make(records: [0, 1, 2, 4].map { record("x", words: 1, daysAgo: $0) },
                                         now: now, calendar: calendar)
        XCTAssertEqual(running.streak, 3)
        let fromYesterday = SidebarDigest.make(records: [1, 2].map { record("x", words: 1, daysAgo: $0) },
                                               now: now, calendar: calendar)
        XCTAssertEqual(fromYesterday.streak, 2, "la série tient encore tant que la journée n'est pas finie")
        let broken = SidebarDigest.make(records: [2, 3].map { record("x", words: 1, daysAgo: $0) },
                                        now: now, calendar: calendar)
        XCTAssertEqual(broken.streak, 0)
    }

    func testEmptyHistory() {
        let digest = SidebarDigest.make(records: [], now: now, calendar: calendar)
        XCTAssertEqual(digest, SidebarDigest(wordsToday: 0, dictationsToday: 0, wordsByDay: Array(repeating: 0, count: 7),
                                             streak: 0, last: nil))
    }
}
