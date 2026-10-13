import Foundation
import Testing
@testable import WispadCore

struct DictionarySortTests {
    private var entries: [DictionaryEntry] {
        [DictionaryEntry(id: "old", term: "Alpha", createdAt: Date(timeIntervalSince1970: 1), origin: .user),
         DictionaryEntry(id: "new", term: "Zèbre", createdAt: Date(timeIntervalSince1970: 4), origin: .user),
         DictionaryEntry(id: "auto", term: "Étoile", createdAt: Date(timeIntervalSince1970: 3),
                         origin: .learned(DictionaryJudge(kind: .jev, provider: "TypeSafe", model: "fixture"))),
         DictionaryEntry(id: "legacy", term: "Avant", createdAt: Date(timeIntervalSince1970: 2), origin: .unknown)]
    }

    @Test func latestAdditionIsFirstByDefaultInEveryFilter() {
        #expect(DictionaryFilter.all.matchingEntries(in: entries, period: .all, search: "").map(\.id) == ["new", "auto", "legacy", "old"])
        #expect(DictionaryFilter.addedByUser.matchingEntries(in: entries, period: .all, search: "").map(\.id) == ["new", "old"])
        #expect(DictionaryFilter.all.matchingEntries(in: entries, period: .all, search: "", sort: .oldest).map(\.id) == ["old", "legacy", "auto", "new"])
    }

    @Test func originsGroupEntriesKeepingLatestFirstWithinEachGroup() {
        #expect(entries.sorted(by: DictionarySort.originAscending.precedes).map(\.id) == ["new", "old", "auto", "legacy"])
        #expect(entries.sorted(by: DictionarySort.originDescending.precedes).map(\.id) == ["legacy", "auto", "new", "old"])
    }

    @Test func headersToggleAndChangingColumnChoosesItsNaturalOrder() {
        #expect(DictionarySort.newest.selecting(.date) == .oldest)
        #expect(DictionarySort.oldest.selecting(.date) == .newest)
        #expect(DictionarySort.newest.selecting(.origin) == .originAscending)
        #expect(DictionarySort.originAscending.selecting(.origin) == .originDescending)
        #expect(DictionarySort.originDescending.selecting(.date) == .newest)
        #expect(DictionarySort.newest.selecting(.term) == .termAscending)
        #expect(entries.sorted(by: DictionarySort.termAscending.precedes).map(\.id) == ["old", "legacy", "auto", "new"])
    }

    @Test func equalDatesHaveAStableOrder() {
        let tied = entries.map { entry in
            var copy = entry
            copy.createdAt = Date(timeIntervalSince1970: 10)
            return copy
        }
        #expect(tied.sorted(by: DictionarySort.newest.precedes).map(\.id) == tied.reversed().sorted(by: DictionarySort.newest.precedes).map(\.id))
    }
}
