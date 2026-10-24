import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// AppModel sur un dossier temporaire, avec un juge des mots remplaçable : aucun vrai réseau, bulle jamais affichée.
@MainActor
private final class InsightsFixture {
    let directory: URL
    var model: AppModel!

    init(judge: @escaping ([CorrectionLearner.Candidate], String, SpeechRequest) async -> TermJudgement = { _, _, _ in
        TermJudgement(kept: [])
    }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-dictionary-insights-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.loadKey = { _ in nil }
        dependencies.refreshKeys = { true }
        dependencies.judgeTerms = judge
        dependencies.copyText = { _ in }
        dependencies.playCue = { _, _ in }
        var settings = AppSettings()
        settings.onboardingCompleted = true
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    /// Dictée inventée enregistrée dans l'historique, puis analysée comme à la fin d'une vraie dictée.
    func dictate(_ id: String, raw: String, final: String) async throws {
        try model.store.insert(DictationRecord(id: id, finalText: final, rawText: raw, durationSeconds: 3,
                                               wordCount: WordCount.count(final), provider: "xai", model: "modele-fictif",
                                               insertionStatus: InsertionStatus.inserted.rawValue))
        model.reloadHistory()
        model.considerRepeatedFixes(raw: raw, final: final, dictationID: id, speech: model.speechRequest(context: nil))
        await model.learning?.value
    }

    func insights() async -> [DictionaryInsights.Suggestion] {
        model.refreshDictionaryInsights()
        await model.insightsTask?.value
        return model.dictionaryInsights.suggestions
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Apprentissage des noms que la correction répare d'une dictée à l'autre, et suggestions de l'écran Dictionnaire.
@MainActor
struct DictionaryInsightsAppTests {
    private let jev = DictionaryJudge(kind: .jev, provider: "TypeSafe", model: "modele-fictif")
    private static let answered = [UsageEvent(api: .typesafeJudge, model: "modele-fictif", costUSD: nil, succeeded: true)]

    @Test func aNameRepairedInTwoDictationsIsJudgedThenLearned() async throws {
        var judged: [[CorrectionLearner.Candidate]] = []
        var dictatedTexts: [String] = []
        let jev = self.jev
        let f = try InsightsFixture(judge: { candidates, dictated, _ in
            judged.append(candidates)
            dictatedTexts.append(dictated)
            return TermJudgement(kept: candidates.map { LearnedTerm(term: $0.corrected, judge: jev) }, usages: Self.answered)
        })
        defer { f.dispose() }
        try await f.dictate("a", raw: "on branche sentri sur l'app", final: "On branche Sentry sur l'app.")
        #expect(judged.isEmpty)
        #expect(f.model.dictionary.isEmpty)
        try await f.dictate("b", raw: "l'erreur est dans sentri", final: "L'erreur est dans Sentry.")
        #expect(judged == [[CorrectionLearner.Candidate(heard: "sentri", corrected: "Sentry")]])
        // Le juge lit la phrase telle qu'elle a été entendue, où figure le mot mal entendu.
        #expect(dictatedTexts == ["l'erreur est dans sentri"])
        let entry = try #require(f.model.dictionary.first)
        #expect(entry.term == "Sentry")
        #expect(entry.origin == .learned(jev))
        #expect(entry.heard == "sentri")
        #expect(entry.source == .repeatedFix)
        #expect(f.model.coordinator.learningOfferedTerms == ["Sentry"])
        // Déjà appris : la réparation suivante ne repasse pas par le juge.
        try await f.dictate("c", raw: "sentri remonte une alerte", final: "Sentry remonte une alerte.")
        #expect(judged.count == 1)
    }

    @Test func aRejectedNameIsNotResubmittedButASilentJudgeIsRetried() async throws {
        var calls = 0
        var answers = true
        let f = try InsightsFixture(judge: { _, _, _ in
            calls += 1
            return TermJudgement(kept: [], usages: answers ? Self.answered
                                 : [UsageEvent(api: .typesafeJudge, model: "modele-fictif", costUSD: nil, succeeded: false)])
        })
        defer { f.dispose() }
        try await f.dictate("a", raw: "on branche sentri sur l'app", final: "On branche Sentry sur l'app.")
        try await f.dictate("b", raw: "l'erreur est dans sentri", final: "L'erreur est dans Sentry.")
        try await f.dictate("c", raw: "sentri remonte une alerte", final: "Sentry remonte une alerte.")
        #expect(calls == 1)
        #expect(f.model.dictionary.isEmpty)

        answers = false
        try await f.dictate("d", raw: "les mails partent avec ri send", final: "Les mails partent avec Resend.")
        try await f.dictate("e", raw: "une clé ri send pour la prod", final: "Une clé Resend pour la prod.")
        try await f.dictate("f", raw: "on relance ri send demain", final: "On relance Resend demain.")
        #expect(calls == 3)
    }

    @Test func nothingIsLearnedWithLearningOffOrForARefusedName() async throws {
        var calls = 0
        let f = try InsightsFixture(judge: { candidates, _, _ in
            calls += 1
            return TermJudgement(kept: candidates.map { LearnedTerm(term: $0.corrected, judge: DictionaryJudge(kind: .jev, provider: "TypeSafe", model: "modele-fictif")) },
                                 usages: Self.answered)
        })
        defer { f.dispose() }
        f.model.settings.learnCorrections = false
        try await f.dictate("a", raw: "on branche sentri sur l'app", final: "On branche Sentry sur l'app.")
        try await f.dictate("b", raw: "l'erreur est dans sentri", final: "L'erreur est dans Sentry.")
        #expect(calls == 0)
        f.model.settings.learnCorrections = true
        f.model.refuseLearnedTerm("Sentry")
        try await f.dictate("c", raw: "sentri remonte une alerte", final: "Sentry remonte une alerte.")
        #expect(calls == 0)
        #expect(f.model.dictionary.isEmpty)
    }

    @Test func suggestionsAreAddedRenamedOrIgnored() async throws {
        let f = try InsightsFixture()
        defer { f.dispose() }
        f.model.settings.learnCorrections = false
        try await f.dictate("a", raw: "on branche sentri sur l'app", final: "On branche Sentry sur l'app.")
        try await f.dictate("b", raw: "l'erreur est dans sentri", final: "L'erreur est dans Sentry.")
        for index in 0..<3 {
            let text = "Les chiffres arrivent dans PostHog le jour \(index)."
            try await f.dictate("p\(index)", raw: text, final: text)
        }
        for (index, text) in ["La build part sur TestFlight ce soir.", "Les testeurs ont reçu TestFlight hier.",
                              "On attend la revue TestFlight.", "Je relance Testflight demain.", "Le lien Testflight a expiré."].enumerated() {
            try await f.dictate("t\(index)", raw: text, final: text)
        }
        f.model.addTerm("posthog")
        let posthog = try #require(f.model.dictionary.first)

        let suggestions = await f.insights()
        #expect(suggestions.map(\.term) == ["Sentry", "PostHog", "TestFlight"])
        #expect(f.model.dictionaryInsights.usage[posthog.id] == 3)

        f.model.acceptSuggestion(suggestions[0])
        let sentry = try #require(f.model.dictionary.first { $0.term == "Sentry" })
        #expect(sentry.origin == .user)
        #expect(sentry.source == .suggestion)
        #expect(sentry.heard == "sentri")

        f.model.acceptSuggestion(suggestions[1])
        let renamed = try #require(f.model.dictionary.first { $0.id == posthog.id })
        #expect(renamed.term == "PostHog")
        #expect(renamed.origin == .user)

        f.model.ignoreSuggestion(suggestions[2])
        #expect(try f.model.store.hasRefused("testflight"))
        #expect(await f.insights().isEmpty)
    }

    @Test func renamingToATakenTermIsRefused() throws {
        let f = try InsightsFixture()
        defer { f.dispose() }
        f.model.addTerm("Figma")
        f.model.addTerm("codex")
        let codex = try #require(f.model.dictionary.first { $0.term == "codex" })
        #expect(!f.model.renameTerm(codex, to: "figma"))
        #expect(f.model.renameTerm(codex, to: "Codex"))
        #expect(f.model.dictionary.map(\.term).sorted() == ["Codex", "Figma"])
    }
}

