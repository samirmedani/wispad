import Foundation
import Testing
@testable import WispadCore

struct RecentDictationContextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let bundle = "com.example.fictif.editeur"

    private func record(
        _ text: String,
        age: TimeInterval,
        bundle: String? = nil,
        status: String = InsertionStatus.inserted.rawValue,
        id: String = UUID().uuidString
    ) -> DictationRecord {
        DictationRecord(
            id: id,
            createdAt: now.addingTimeInterval(-age),
            finalText: text,
            rawText: text,
            durationSeconds: 1,
            wordCount: 3,
            provider: "fixture",
            model: "fixture",
            targetBundle: bundle ?? self.bundle,
            insertionStatus: status
        )
    }

    @Test func sameAppKeepsTheThreeNewestDeliveredTexts() {
        let records = [
            record("la quatrième, trop ancienne dans la file", age: 200, id: "4"),
            record("la troisième", age: 180, id: "3"),
            record("la deuxième parle de 2400", age: 120, status: InsertionStatus.pasteSent.rawValue, id: "2"),
            record("autre application", age: 30, bundle: "com.example.fictif.navigateur", id: "autre"),
            record("annulée", age: 10, status: InsertionStatus.cancelled.rawValue, id: "annulee"),
            record("échec", age: 20, status: InsertionStatus.failed.rawValue, id: "echec"),
            record("transcription ratée", age: 25, status: InsertionStatus.transcriptionFailed.rawValue, id: "ratée"),
            record("encore en attente", age: 15, status: InsertionStatus.pending.rawValue, id: "attente"),
            record("champ sécurisé", age: 40, status: InsertionStatus.refusedSecure.rawValue, id: "secret"),
            record("aucun champ", age: 45, status: InsertionStatus.noTarget.rawValue, id: "vide"),
            record("   ", age: 5, id: "blanc"),
            record("trop vieille", age: 15 * 60, id: "vieille"),
            record("la plus récente parle de DDR4", age: 60, id: "1"),
        ]
        #expect(RecentDictationContext.texts(in: records, bundleID: bundle, now: now) == [
            "la plus récente parle de DDR4",
            "la deuxième parle de 2400",
            "la troisième",
        ])
        #expect(RecentDictationContext.texts(in: records, bundleID: nil, now: now).isEmpty)
        #expect(RecentDictationContext.texts(in: records, bundleID: "", now: now).isEmpty)
    }

    @Test func characterBudgetKeepsTheNewestAndClipsTheRest() {
        let newest = String(repeating: "a", count: 450)
        let middle = String(repeating: "b", count: 200)
        let oldest = String(repeating: "c", count: 100)
        let records = [
            record(oldest, age: 180, id: "3"),
            record(middle, age: 120, id: "2"),
            record(newest, age: 30, id: "1"),
        ]
        let texts = RecentDictationContext.texts(in: records, bundleID: bundle, now: now)
        #expect(texts == [newest, String(repeating: "b", count: 150)])
        #expect(texts.reduce(0) { $0 + $1.count } == 600)
    }

    @Test func aSingleLongDictationIsClippedToTheBudget() {
        let text = String(repeating: "m", count: 700)
        let texts = RecentDictationContext.texts(in: [record(text, age: 10)], bundleID: bundle, now: now)
        #expect(texts == [String(repeating: "m", count: 600)])
    }

    @Test func promptLineDescribesPreviousDictationsWithoutAskingToCopyThem() {
        let request = CorrectionRequest(
            transcript: "encore une ligne",
            previousDictations: ["Le bac nord contient douze modules."]
        )
        let prompt = CorrectionPrompt.userText(request)
        #expect(prompt.contains("Dictées précédentes dans cette application (même conversation ; jamais à recopier ; servent seulement à comprendre le sujet, l'orthographe et les nombres): Le bac nord contient douze modules."))
        let empty = CorrectionPrompt.userText(CorrectionRequest(transcript: "x"))
        #expect(!empty.contains("Dictées précédentes"))
    }

    @Test func priorTermsFollowTheDictionaryAndTheNearbyContext() throws {
        let hints = RecognitionHints.keyterms(
            dictionary: ["AlphaTerm"],
            context: ["BetaTerm"],
            prior: ContextTerms.hints(from: "Le module DDR4 tient 2400 MHz")
        )
        let alpha = try #require(hints.firstIndex(of: "AlphaTerm"))
        let beta = try #require(hints.firstIndex(of: "BetaTerm"))
        let ddr = try #require(hints.firstIndex(of: "DDR4"))
        let push = try #require(hints.firstIndex(of: "push"))
        #expect(alpha < beta)
        #expect(beta < ddr)
        #expect(ddr < push)
        #expect(hints.contains("2400"))
        #expect(hints.contains("MHz"))
        let full = RecognitionHints.keyterms(
            dictionary: (0..<100).map { "mot\($0)" },
            context: [],
            prior: ["DDR4"]
        )
        #expect(full.count == 100)
        #expect(full[0] == "mot0")
        #expect(!full.contains("DDR4"))
    }

    @Test func copyingAPreviousDictationIsRejectedLikeNearbyText() {
        let previous = "Le bac nord contient douze modules identiques prêts à partir demain matin."
        let heard = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
        let copied = "Le bac nord contient douze modules identiques prêts iota kappa"
        #expect(FidelityGuard.check(transcript: heard, corrected: copied, previousDictations: [previous]) == heard)
        let faithful = "Alpha beta gamma delta epsilon zeta eta theta iota kappa."
        #expect(FidelityGuard.check(transcript: heard, corrected: faithful, previousDictations: [previous]) == faithful)
    }
}
