import Foundation
import Testing
@testable import WispadCore

/// Filet anti-régression de `HistoryStore` : tout ce qui entre dans la base en ressort à l'identique, dans l'ordre promis.
/// Chaque test travaille sur une base temporaire, effacée à la fin.
struct HistoryStorePropertyTests {
    private func withStore(_ body: (HistoryStore, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-proprietes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        try body(try HistoryStore(path: path), path)
    }

    /// Texte enregistré : dictée plausible, caractères quelconques (contrôle, nul, emoji, marques combinantes), SQL.
    static func text(_ g: inout SeededGenerator) -> String {
        switch g.int(0...5) {
        case 0, 1: return SampleText.sentence(&g, english: g.chance(50))
        case 2: return SampleText.unicode(&g, length: 0...60)
        case 3: return g.pick(["", " ", "'; DROP TABLE dictations; --", "\"guillemets\"", "a\u{0}b", "\u{0}", "%_\\", "🇫🇷👍🏽", "e\u{301}"])
        case 4: return String(repeating: g.pick(["é", "x", "🙂", "\u{0}"]), count: g.int(1_000...20_000))
        default: return SampleText.digitless(&g)
        }
    }

    static func record(_ g: inout SeededGenerator, index: Int) -> DictationRecord {
        DictationRecord(
            id: "dictée-\(index)" + (g.chance(20) ? "-'; DROP TABLE dictations; --" : ""),
            // Secondes entières, demies ou quarts : la date se relit exactement.
            createdAt: Date(timeIntervalSince1970: Double(g.int(0...4_000_000_000)) + g.pick([0, 0.25, 0.5])),
            finalText: text(&g),
            rawText: text(&g),
            durationSeconds: g.chance(10) ? g.pick([0, 1e-300, 1e300, .greatestFiniteMagnitude, .infinity]) : g.double(0...7_200),
            wordCount: g.chance(10) ? g.pick([0, Int(Int32.max)]) : g.int(0...100_000),
            provider: g.pick(["xai", "openai", ""]),
            model: g.pick(["grok-voice-transcribe-2.0", "gpt-live-transcribe", text(&g)]),
            targetApp: g.chance(50) ? nil : text(&g),
            targetBundle: g.chance(50) ? nil : g.pick(["com.apple.Notes", "com.google.Chrome", ""]),
            usageCategory: g.chance(50) ? nil : g.pick(UsageKind.allCases).rawValue,
            insertionStatus: g.pick(["inserted", "pasteSent", "failed", "noTarget", "pending"]),
            audioPath: g.chance(50) ? nil : "/tmp/" + text(&g),
            audioExpiresAt: g.chance(50) ? nil : Date(timeIntervalSince1970: Double(g.int(0...4_000_000_000))),
            alternativeText: g.chance(50) ? nil : text(&g)
        )
    }

    // MARK: Défaut corrigé

    /// Un caractère nul arrêtait SQLite : « avant\0après » était enregistré « avant », sans erreur.
    @Test func aNulCharacterNoLongerCutsTheText() throws {
        try withStore { store, _ in
            let record = DictationRecord(finalText: "avant\u{0}après", rawText: "brut\u{0}", durationSeconds: 1, wordCount: 2,
                                         provider: "xai", model: "m", targetApp: "App\u{0}Nom", insertionStatus: "inserted",
                                         alternativeText: "\u{0}autre")
            try store.insert(record)
            let loaded = try #require(try store.dictations().first)
            #expect(loaded.finalText == "avant\u{0}après")
            #expect(loaded.rawText == "brut\u{0}")
            #expect(loaded.targetApp == "App\u{0}Nom")
            #expect(loaded.alternativeText == "\u{0}autre")
            try store.addTerm("Swift\u{0}UI")
            try store.addTerm("Swift")
            #expect(try store.dictionary().map(\.term).sorted() == ["Swift", "Swift\u{0}UI"])
            try store.rememberRefusal("mot\u{0}refusé")
            #expect(try store.hasRefused("mot\u{0}refusé"))
            #expect(try !store.hasRefused("mot"))
        }
    }

    // MARK: Propriétés

    /// Toute dictée enregistrée se relit à l'identique (textes, dates, durées extrêmes, champs absents), de la plus
    /// récente à la plus ancienne, y compris après fermeture et réouverture de la base.
    @Test func dictationsRoundTripInOrder() throws {
        try withStore { store, path in
            var g = SeededGenerator(seed: 0x4849_5331)
            var records: [String: DictationRecord] = [:]
            for index in 0..<150 {
                let record = Self.record(&g, index: index)
                try store.insert(record)
                records[record.id] = record
            }
            for loaded in [try store.dictations(), try HistoryStore(path: path).dictations()] {
                #expect(loaded.count == records.count)
                let changed = loaded.first { records[$0.id] != $0 }
                #expect(changed == nil, "relue autrement : \(changed?.id ?? "")")
                #expect(!zip(loaded, loaded.dropFirst()).contains { $0.createdAt < $1.createdAt }, "ordre")
            }
        }
    }

    /// Mises à jour : chaque champ changé se relit, les autres restent ; une app inconnue ne remplace pas celle connue.
    @Test func updatesOnlyTouchTheirFields() throws {
        try withStore { store, _ in
            var g = SeededGenerator(seed: 0x4849_5332)
            var records = (0..<40).map { Self.record(&g, index: $0) }
            for record in records { try store.insert(record) }
            for _ in 0..<200 {
                let index = g.int(0...(records.count - 1))
                var expected = records[index]
                switch g.int(0...3) {
                case 0:
                    expected.finalText = Self.text(&g)
                    expected.rawText = Self.text(&g)
                    expected.wordCount = g.int(0...10_000)
                    try store.updateTranscript(id: expected.id, finalText: expected.finalText, rawText: expected.rawText, wordCount: expected.wordCount)
                case 1:
                    expected.insertionStatus = g.pick(["inserted", "failed", "pasteSent"])
                    try store.updateStatus(id: expected.id, status: expected.insertionStatus)
                case 2:
                    let app: String? = g.chance(50) ? nil : Self.text(&g)
                    let bundle: String? = g.chance(50) ? nil : "com.apple.TextEdit"
                    let category: String? = g.chance(50) ? nil : UsageKind.writing.rawValue
                    expected.insertionStatus = "inserted"
                    expected.targetApp = app ?? expected.targetApp
                    expected.targetBundle = bundle ?? expected.targetBundle
                    expected.usageCategory = category ?? expected.usageCategory
                    try store.updateDelivery(id: expected.id, status: "inserted", targetApp: app, targetBundle: bundle, usageCategory: category)
                default:
                    expected.audioPath = g.chance(50) ? nil : "/tmp/" + Self.text(&g)
                    expected.audioExpiresAt = g.chance(50) ? nil : Date(timeIntervalSince1970: Double(g.int(0...4_000_000_000)))
                    try store.updateAudio(id: expected.id, path: expected.audioPath, expiresAt: expected.audioExpiresAt)
                }
                records[index] = expected
            }
            let loaded = Dictionary(uniqueKeysWithValues: try store.dictations().map { ($0.id, $0) })
            let changed = records.first { loaded[$0.id] != $0 }
            #expect(changed == nil, "relue autrement : \(changed?.id ?? "")")
        }
    }

    /// Dictionnaire : un mot rogné, jamais vide, une seule fois à la casse ASCII près (règle de SQLite), et la liste
    /// triée sans casse ; une suppression ne retire que son mot.
    @Test func dictionaryKeepsOneEntryPerTerm() throws {
        try withStore { store, _ in
            var g = SeededGenerator(seed: 0x4849_5333)
            func folded(_ term: String) -> [UInt8] { term.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 } }
            var expected: [String] = []
            for _ in 0..<300 {
                var term = g.chance(60) ? g.pick(SampleText.frenchWords + SampleText.englishWords + ["OAuth", "OAUTH", "oauth", "Vercel", "École", "école"])
                    : SampleText.unicode(&g, length: 0...12)
                if g.chance(20) { term = g.pick([" ", "\n", "\t"]) + term + g.pick([" ", ""]) }
                try store.addTerm(term, origin: g.pick([.user, .unknown]))
                let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty, !expected.contains(where: { folded($0) == folded(cleaned) }) { expected.append(cleaned) }
            }
            let terms = try store.dictionary().map(\.term)
            #expect(terms.count == expected.count)
            #expect(Set(terms) == Set(expected))
            let unordered = zip(terms, terms.dropFirst()).first { !folded($0).lexicographicallyPrecedes(folded($1)) }
            #expect(unordered == nil, "« \(unordered?.0 ?? "") » avant « \(unordered?.1 ?? "") »")
            let entries = try store.dictionary()
            let removed = g.pick(entries)
            try store.deleteTerm(id: removed.id)
            #expect(try store.dictionary().map(\.id) == entries.map(\.id).filter { $0 != removed.id })
        }
    }

    /// Refus : chaque mot refusé se retrouve, à la casse près ; un mot vide ou blanc n'est jamais refusé.
    @Test func refusalsAreRemembered() throws {
        try withStore { store, _ in
            var g = SeededGenerator(seed: 0x4849_5334)
            var refused: [String] = []
            for _ in 0..<150 {
                let term = g.chance(70) ? g.pick(SampleText.frenchWords + SampleText.englishWords + ["Seedance", "TypeSafe"])
                    : SampleText.unicode(&g, length: 0...10)
                try store.rememberRefusal(term)
                let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { refused.append(cleaned) }
            }
            let forgotten = try refused.first { try !store.hasRefused($0) || !store.hasRefused(" " + $0 + "\n") }
            #expect(forgotten == nil, "« \(forgotten ?? "") » oublié")
            for term in ["Seedance", "TypeSafe"] where refused.contains(term) {
                #expect(try store.hasRefused(term.uppercased()))
            }
            #expect(try !store.hasRefused(""))
            #expect(try !store.hasRefused(" \n "))
        }
    }
}
