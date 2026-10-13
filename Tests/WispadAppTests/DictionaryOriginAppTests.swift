import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Modèle de correction simulé : approuve les mots qu'on lui soumet et note les hôtes appelés. Aucun vrai réseau.
private actor ApprovingModel {
    private(set) var hosts: [String] = []

    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        hosts.append(request.url?.host ?? "")
        let content = #"{"garder": ["Seedance", "Cloudflare", "OpenRouter"]}"#
        let object: [String: Any] = [
            "choices": [["message": ["content": content], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5]
        ]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: object), response)
    }
}

/// AppModel sur un dossier temporaire : clés en mémoire, juge des mots remplaçable, bulle jamais affichée.
@MainActor
private final class OriginFixture {
    let directory: URL
    var keys: [String: String] = [:]
    var model: AppModel!

    init(judge: @escaping ([CorrectionLearner.Candidate], String, SpeechRequest) async -> TermJudgement = { _, _, _ in
        TermJudgement(kept: [])
    }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-dictionary-origin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.loadKey = { [weak self] in self?.keys[$0] }
        dependencies.refreshKeys = { true }
        dependencies.judgeTerms = judge
        dependencies.copyText = { _ in }
        dependencies.playCue = { _ in }
        var settings = AppSettings()
        settings.onboardingCompleted = true
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    func reopened() throws -> HistoryStore {
        try HistoryStore(path: directory.appendingPathComponent(AppIdentity.databaseName).path)
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Origine des mots dans l'app : ajout à la main, mot appris avec son juge (fournisseur et modèle de l'appel qui a
/// tranché), « Oui » de la bulle, textes du badge et de l'info-bulle.
@MainActor
struct DictionaryOriginAppTests {
    private let jev = DictionaryJudge(kind: .jev, provider: "TypeSafe", model: "jev-1.13.0")
    private let deepSeek = DictionaryJudge(kind: .correctionModel, provider: "DeepSeek", model: CleanupModel.deepSeek)

    @Test func aLateVerdictDoesNotRelearnARefusedWord() async throws {
        var release: CheckedContinuation<Void, Never>?
        let f = try OriginFixture(judge: { candidates, _, _ in
            await withCheckedContinuation { release = $0 }
            return TermJudgement(kept: candidates.map { LearnedTerm(term: $0.corrected, judge: self.jev) })
        })
        defer { f.dispose() }
        f.model.considerLearning([.init(heard: "Sidance", corrected: "Seedance")], dictated: "On teste Sidance.", speech: f.model.speechRequest(context: nil))
        for _ in 0..<1_000 where release == nil { await Task.yield() }
        let continuation = try #require(release)
        f.model.refuseLearnedTerm("Seedance")
        continuation.resume()
        await f.model.learning?.value
        #expect(f.model.dictionary.isEmpty)
        #expect(f.model.coordinator.notice == nil)
    }

    @Test func queuedDuplicatesAreJudgedOnlyOnce() async throws {
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let f = try OriginFixture(judge: { candidates, _, _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { release = $0 } }
            return TermJudgement(kept: candidates.map { LearnedTerm(term: $0.corrected, judge: self.jev) })
        })
        defer { f.dispose() }
        let candidates = [CorrectionLearner.Candidate(heard: "Sidance", corrected: "Seedance")]
        let speech = f.model.speechRequest(context: nil)
        f.model.considerLearning(candidates, dictated: "On teste Sidance.", speech: speech)
        for _ in 0..<1_000 where release == nil { await Task.yield() }
        let continuation = try #require(release)
        f.model.considerLearning(candidates, dictated: "On teste Sidance.", speech: speech)
        continuation.resume()
        await f.model.learning?.value
        #expect(calls == 1)
        #expect(f.model.dictionary.count == 1)
        #expect(f.model.coordinator.learningOfferedTerms == ["Seedance"])
    }

    @Test func disablingLearningWhileWaitingDropsTheVerdict() async throws {
        var release: CheckedContinuation<Void, Never>?
        let f = try OriginFixture(judge: { candidates, _, _ in
            await withCheckedContinuation { release = $0 }
            return TermJudgement(kept: candidates.map { LearnedTerm(term: $0.corrected, judge: self.jev) })
        })
        defer { f.dispose() }
        f.model.considerLearning([.init(heard: "Sidance", corrected: "Seedance")], dictated: "On teste Sidance.", speech: f.model.speechRequest(context: nil))
        for _ in 0..<1_000 where release == nil { await Task.yield() }
        let continuation = try #require(release)
        f.model.settings.learnCorrections = false
        continuation.resume()
        await f.model.learning?.value
        #expect(f.model.dictionary.isEmpty)
        #expect(f.model.coordinator.notice == nil)
    }

    @Test func wordAddedByHandIsYours() throws {
        let f = try OriginFixture()
        defer { f.dispose() }
        f.model.addTerm("  Vercel ")
        let entry = try #require(f.model.dictionary.first)
        #expect(entry.term == "Vercel")
        #expect(entry.origin == .user)
        #expect(try f.reopened().dictionary().map(\.origin) == [.user])
        #expect(DictionaryFilter.addedByUser.includes(entry))
        #expect(!DictionaryFilter.learned.includes(entry))
    }

    @Test func learnedWordsKeepTheJudgeThatRetainedThem() async throws {
        let jev = self.jev, deepSeek = self.deepSeek
        let f = try OriginFixture(judge: { _, _, _ in
            TermJudgement(kept: [LearnedTerm(term: "Seedance", judge: jev), LearnedTerm(term: "OpenRouter", judge: deepSeek)])
        })
        defer { f.dispose() }
        f.model.considerLearning(
            [.init(heard: "Sidance", corrected: "Seedance"), .init(heard: "open router", corrected: "OpenRouter")],
            dictated: "J'ai testé Sidance avec open router.", speech: f.model.speechRequest(context: nil)
        )
        await f.model.learning?.value
        let origins = Dictionary(uniqueKeysWithValues: try f.reopened().dictionary().map { ($0.term, $0.origin) })
        #expect(origins == ["Seedance": .learned(jev), "OpenRouter": .learned(deepSeek)])
        #expect(f.model.dictionary.allSatisfy { DictionaryFilter.learned.includes($0) && !DictionaryFilter.addedByUser.includes($0) })
    }

    /// Juge réel sur un réseau simulé : chaque mot porte le fournisseur et le modèle qui ont répondu pour lui, selon
    /// les clés du moment. Changer de clé change le juge des mots suivants, jamais celui des mots déjà appris.
    @Test func learnedWordsFollowTheKeysOfTheMoment() async throws {
        let network = ApprovingModel()
        let f = try OriginFixture(judge: { candidates, dictated, speech in
            await TermJudge.judge(candidates, dictated: dictated, speech: speech, scoreRequest: { _, _, _ in
                (nil, UsageEvent(api: .typesafeJudge, model: JevJudge.model, costUSD: nil, succeeded: false))
            }, transport: { try await network.request($0) })
        })
        defer { f.dispose() }
        func learn(_ heard: String, _ corrected: String) async {
            f.model.considerLearning([.init(heard: heard, corrected: corrected)], dictated: "On parle de \(heard).",
                                     speech: f.model.speechRequest(context: nil))
            await f.model.learning?.value
        }
        f.keys = [ProviderID.xai.rawValue: "fixture-xai", CleanupModel.deepSeekAccount: "fixture-deepseek"]
        await learn("Sidance", "Seedance")
        f.keys = [ProviderID.xai.rawValue: "fixture-xai", ProviderID.openAI.rawValue: "fixture-openai"]
        await learn("cloud flair", "Cloudflare")
        f.keys = [ProviderID.xai.rawValue: "fixture-xai"]
        await learn("open router", "OpenRouter")

        let origins = Dictionary(uniqueKeysWithValues: try f.reopened().dictionary().map { ($0.term, $0.origin) })
        #expect(origins == [
            "Seedance": .learned(DictionaryJudge(kind: .correctionModel, provider: "DeepSeek", model: CleanupModel.deepSeek)),
            "Cloudflare": .learned(DictionaryJudge(kind: .correctionModel, provider: "OpenAI", model: CleanupModel.openAIFallback)),
            "OpenRouter": .learned(DictionaryJudge(kind: .correctionModel, provider: "xAI", model: ProviderID.xai.defaultCleanupModel))
        ])
        #expect(await network.hosts == ["api.deepseek.com", "api.openai.com", "api.x.ai"])
    }

    /// « Oui » dans la bulle : le mot reste appris par son juge et la confirmation est notée ; sans réponse, rien
    /// n'est noté.
    @Test func keepingAWordInTheBubbleNotesTheConfirmation() async throws {
        let deepSeek = self.deepSeek
        let f = try OriginFixture(judge: { candidates, _, _ in
            TermJudgement(kept: candidates.map { LearnedTerm(term: $0.corrected, judge: deepSeek) })
        })
        defer { f.dispose() }
        f.model.considerLearning(
            [.init(heard: "Sidance", corrected: "Seedance"), .init(heard: "open router", corrected: "OpenRouter")],
            dictated: "J'ai testé Sidance avec open router.", speech: f.model.speechRequest(context: nil)
        )
        await f.model.learning?.value
        let coordinator = f.model.coordinator
        #expect(coordinator.learningOfferedTerms == ["Seedance", "OpenRouter"])
        coordinator.acceptLearning()
        #expect(coordinator.notice == nil)
        coordinator.dismissCurrentNotice()

        let entries = try f.reopened().dictionary()
        let seedance = try #require(entries.first { $0.term == "Seedance" })
        let openRouter = try #require(entries.first { $0.term == "OpenRouter" })
        #expect(seedance.origin == .learned(deepSeek))
        #expect(seedance.confirmedAt != nil)
        #expect(openRouter.origin == .learned(deepSeek))
        #expect(openRouter.confirmedAt != nil)
        #expect(f.model.dictionary.first { $0.term == "Seedance" }?.confirmedAt != nil)
        // Gardé par « Oui », un mot appris reste dans « Appris automatiquement ».
        #expect(f.model.dictionary.filter(DictionaryFilter.learned.includes).map(\.term) == ["OpenRouter", "Seedance"])
    }

    @Test func badgeAndTooltipSayWhoAddedTheWord() {
        let date = Date(timeIntervalSince1970: 1_791_028_800)
        let kept = date.addingTimeInterval(60)
        let french = Locale(identifier: "fr_FR")
        let added = DictionaryOriginText.date(date, locale: french)

        #expect(DictionaryOriginText.judgeName(jev) == "Jev")
        #expect(DictionaryOriginText.judgeName(deepSeek) == "DeepSeek")
        #expect(DictionaryOriginText.summary(.user) == "Ajouté par toi")
        #expect(DictionaryOriginText.summary(.learned(deepSeek)) == "Appris automatiquement, juge : DeepSeek")
        #expect(DictionaryOriginText.summary(.unknown) == "Avant le suivi")

        func detail(_ origin: DictionaryOrigin, confirmedAt: Date? = nil) -> String {
            DictionaryOriginText.detail(DictionaryEntry(term: "Mot", createdAt: date, origin: origin, confirmedAt: confirmedAt), locale: french)
        }
        #expect(detail(.user) == "Ajouté par toi le \(added)")
        #expect(detail(.learned(jev)) == "Appris automatiquement le \(added)\nJuge : Jev (fournisseur TypeSafe, modèle jev-1.13.0)")
        #expect(detail(.learned(deepSeek), confirmedAt: kept) == [
            "Appris automatiquement le \(added)",
            "Juge : modèle de correction (fournisseur DeepSeek, modèle \(CleanupModel.deepSeek))",
            "Gardé par toi le \(DictionaryOriginText.date(kept, locale: french))"
        ].joined(separator: "\n"))
        #expect(detail(.unknown) == "Avant le suivi : origine inconnue\nAjouté le \(added)")

        #expect(DictionaryFilter.allCases.map(\.label) == ["Tous", "Par toi", "Automatique", "Avant le suivi"])
        #expect(DictionaryOriginText.emptyMessage(.addedByUser) == "Aucun mot ajouté par toi pour l'instant.")
        #expect(DictionaryOriginText.emptyMessage(.learned) == "Aucun mot appris de tes corrections pour l'instant.")
    }
}
