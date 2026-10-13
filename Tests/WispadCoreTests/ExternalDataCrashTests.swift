import Foundation
import Testing
@testable import WispadCore

/// Données venues de l'extérieur (transcription, réponses des fournisseurs, base locale) : aucune ne doit arrêter
/// l'app, et les cas ordinaires gardent exactement leur résultat d'avant.
struct ExternalDataCrashTests {
    // MARK: Nombres dits démesurés

    /// « cent » dix fois de suite, dit ou mal transcrit, dépassait `Int.max` : la fin de la dictée arrêtait l'app.
    @Test func repeatedHundredsStopBeforeOverflowing() {
        let hundreds = Array(repeating: "cent", count: 10)
        let parsed = SpokenNumbers.parse(hundreds, from: 0)
        #expect(parsed?.value == 1_000_000_000_000_000_000)
        #expect(parsed?.next == 9)
        #expect(SpokenNumbers.spell(hundreds) == ["1000000000000000000", "100"])
        #expect(SpokenNumbers.spell(Array(repeating: "hundred", count: 12)) == ["1000000000000000000", "1000000"])
        // « mille » qui ferait déborder le total : le nombre s'arrête juste avant lui.
        #expect(SpokenNumbers.parse(Array(repeating: "cent", count: 9) + ["mille"], from: 0)?.next == 9)
    }

    @Test func ordinarySpokenNumbersKeepTheirValue() {
        #expect(SpokenNumbers.spell(["deux", "mille", "six", "cent", "soixante", "six"]) == ["2666"])
        #expect(SpokenNumbers.spell(["quatre", "vingt", "quinze"]) == ["95"])
        #expect(SpokenNumbers.spell(["one", "hundred", "and", "five"]) == ["105"])
        #expect(SpokenNumbers.spell(["vingt", "et", "un", "mille"]) == ["21000"])
    }

    /// La même transcription passe par chaque étape de la fin de dictée : comparaison flux/fichier, garde-fou,
    /// année non dite.
    @Test func dictationOfRepeatedHundredsReachesTheEnd() {
        for word in ["cent", "cents", "hundred"] {
            let spoken = Array(repeating: word, count: 25)
            let transcript = spoken.joined(separator: " ")
            #expect(TranscriptEquivalence.equivalent(transcript, transcript))
            #expect(TranscriptEquivalence.differingWords(transcript, transcript + " fin") == 1)
            let guarded = FidelityGuard.check(
                transcript: "il y a " + transcript + " serveurs", corrected: "Il y a 1000000000000000000 serveurs."
            )
            #expect(!guarded.isEmpty)
            #expect(DateTimeWriter.removingUnspokenYears(from: "Le 03/11/2026.", heard: ["le", "trois", "novembre"] + spoken)
                    == "Le 03/11.")
        }
    }

    /// Une année dite en deux morceaux se compare sans addition : un nombre démesuré à côté ne déborde plus.
    @Test func yearInTwoPiecesSurvivesHugeNeighbors() {
        #expect(MomentReading.formsYear(20, 26, 2026))
        #expect(!MomentReading.formsYear(19, 26, 2026))
        #expect(!MomentReading.formsYear(20, .max, 2026))
        #expect(!MomentReading.yearWasSaid(2026, day: 3, month: 11, in: [3, 11, 20, .max]))
        #expect(MomentReading.yearWasSaid(2026, day: 3, month: 11, in: [3, 11, 20, 26]))
        #expect(MomentReading.sameMoment(written: ["03/11/2026"], heard: ["the", "third", "of", "November", "twenty", "twenty-six"]))
    }

    // MARK: Jetons annoncés par un fournisseur

    /// Un fournisseur peut annoncer n'importe quel compteur positif : la somme de deux appels démesurés dépassait
    /// `Int.max`, et Consommation (comme le menu de la barre) arrêtait l'app à chaque ouverture.
    @Test func hugeTokenCountersAreCappedInsteadOfOverflowing() throws {
        let parsed = try #require(TokenUsage.parse(["prompt_tokens": Int.max, "completion_tokens": Int.max]))
        let events = (0..<3).map { _ in
            UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, tokens: parsed, costUSD: nil)
        }
        let row = try #require(UsageSummary.make(events: events, period: .all).rows.first)
        #expect(row.tokens == TokenUsage(input: .max, cachedInput: 0, output: .max))
        #expect(row.requests == 3)
        #expect(TokenUsage(input: .max, cachedInput: .max).totalInput == .max)
        #expect(TokenUsage(input: .min, cachedInput: -1).totalInput == .min)
    }

    @Test func ordinaryTokenCountersAddUpAsBefore() {
        let first = TokenUsage(input: 100, cachedInput: 20, output: 7)
        let second = TokenUsage(input: 5, cachedInput: 1, output: 3)
        #expect(first.adding(second) == TokenUsage(input: 105, cachedInput: 21, output: 10))
        #expect(first.totalInput == 120)
        let events = [first, second].map { UsageEvent(api: .xaiCleanup, model: "grok-4.7", tokens: $0, costUSD: 0.5) }
        #expect(UsageSummary.make(events: events, period: .all).rows.first?.tokens == TokenUsage(input: 105, cachedInput: 21, output: 10))
    }

    // MARK: Durées lues dans la base

    /// Une durée abîmée dans la base (infinie, NaN, démesurée) arrêtait l'app dès l'écran Accueil, à chaque lancement.
    @Test func corruptedDurationsAreShownWithoutCrashing() {
        #expect(DurationFormat.audio(.nan) == "0s")
        #expect(DurationFormat.saved(.nan) == "0m")
        #expect(DurationFormat.audio(-.infinity) == "0s")
        #expect(DurationFormat.audio(.infinity) == "2562047788015215h 13min")
        #expect(DurationFormat.saved(1e300) == "2562047788015215h 13m")
        let samples = [DictationSample(createdAt: Date(), wordCount: 10, durationSeconds: .infinity),
                       DictationSample(createdAt: Date(), wordCount: 10, durationSeconds: 12)]
        let summary = StatsCalculator.summary(samples: samples, typingWordsPerMinute: 40)
        #expect(DurationFormat.audio(summary.audioSeconds) == "2562047788015215h 13min")
        #expect(DurationFormat.saved(summary.savedSeconds) == "0m")
    }

    @Test func ordinaryDurationsKeepTheirFormat() {
        #expect(DurationFormat.audio(0) == "0s")
        #expect(DurationFormat.audio(42.4) == "42s")
        #expect(DurationFormat.audio(42.5) == "43s")
        #expect(DurationFormat.audio(125) == "2min 5s")
        #expect(DurationFormat.audio(3_725) == "1h 2min")
        #expect(DurationFormat.audio(-3) == "0s")
        #expect(DurationFormat.saved(45_240) == "12h 34m")
        #expect(DurationFormat.saved(59) == "0m")
    }

    // MARK: Nombre de mots

    /// Le nombre de mots s'écrit en Int32 : un compte démesuré y était une conversion qui arrêtait l'app.
    @Test func hugeWordCountIsStoredWithoutCrashing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(path: directory.appendingPathComponent("history.sqlite").path)
        try store.insert(DictationRecord(id: "huge", finalText: "texte", rawText: "texte", durationSeconds: 1, wordCount: .max,
                                         provider: "xai", model: "m", insertionStatus: InsertionStatus.inserted.rawValue))
        #expect(try store.dictations().first?.wordCount == Int(Int32.max))
        try store.updateTranscript(id: "huge", finalText: "autre", rawText: "autre", wordCount: 12)
        #expect(try store.dictations().first?.wordCount == 12)
        try store.updateTranscript(id: "huge", finalText: "autre", rawText: "autre", wordCount: .max)
        #expect(try store.dictations().first?.wordCount == Int(Int32.max))
    }

    // MARK: Adresse de facturation xAI

    /// L'identifiant d'équipe vient de la réponse de xAI : quel qu'il soit, la facturation reste une adresse de la
    /// console. Non reproductible aujourd'hui (Foundation encode les caractères invalides), d'où le seul repli.
    @Test func billingAddressSurvivesAnyTeamIdentifier() {
        let normal = XAIAccountStatus(teamID: "team-123", keyName: nil, blocked: false)
        #expect(normal.billingURL.absoluteString == "https://console.x.ai/team/team-123/billing")
        for team in ["", "a b", "%", "é/../", "#?", "😀", "\u{0}"] {
            #expect(XAIAccountStatus(teamID: team, keyName: nil, blocked: false).billingURL.host == "console.x.ai")
        }
    }
}
