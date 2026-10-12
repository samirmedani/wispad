import Foundation
import SQLite3
import Testing
@testable import WispadCore

/// Réponses simulées du modèle de correction : un hôte listé dans `failing` ne répond pas.
private actor ModelStub {
    private let failing: Set<String>
    private let content: String
    private(set) var hosts: [String] = []

    init(failing: Set<String> = [], content: String = #"{"garder": ["Seedance"]}"#) {
        self.failing = failing
        self.content = content
    }

    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let host = request.url?.host ?? ""
        hosts.append(host)
        if failing.contains(host) { throw URLError(.timedOut) }
        let object: [String: Any] = [
            "choices": [["message": ["content": content], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5]
        ]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: object), response)
    }
}

/// Origine des mots du dictionnaire : qui les a ajoutés, et pour un mot appris le juge qui a tranché, avec le
/// fournisseur et le modèle réellement appelés.
struct DictionaryOriginTests {
    private static let jev = DictionaryJudge(kind: .jev, provider: "TypeSafe", model: "jev-fixture")
    private static let deepSeek = DictionaryJudge(kind: .correctionModel, provider: "DeepSeek", model: CleanupModel.deepSeek)
    private static let sidance = [CorrectionLearner.Candidate(heard: "Sidance", corrected: "Seedance")]

    // MARK: - Base

    @Test func oldEntriesAreKeptWithUnknownOrigin() throws {
        try withDatabase { path in
            // Base d'une version précédente : dictionnaire sans origine, et un mot refusé.
            try execute(
                """
                CREATE TABLE dictionary (
                    id TEXT PRIMARY KEY,
                    term TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    created_at REAL NOT NULL
                );
                INSERT INTO dictionary VALUES ('ancien-1', 'Seedance', 1790000000.5);
                INSERT INTO dictionary VALUES ('ancien-2', 'OpenRouter', 1790000100);
                CREATE TABLE learning_refusals (term TEXT PRIMARY KEY COLLATE NOCASE, created_at REAL NOT NULL);
                INSERT INTO learning_refusals VALUES ('Commande', 1790000200);
                """,
                at: path
            )
            let store = try HistoryStore(path: path)
            #expect(try store.dictionary() == [
                DictionaryEntry(id: "ancien-2", term: "OpenRouter", createdAt: Date(timeIntervalSince1970: 1_790_000_100), origin: .unknown),
                DictionaryEntry(id: "ancien-1", term: "Seedance", createdAt: Date(timeIntervalSince1970: 1_790_000_000.5), origin: .unknown)
            ])
            #expect(try store.hasRefused("commande"))
            #expect(try columns(at: path) == ["id", "term", "created_at", "origin", "judge_provider", "judge_model", "confirmed_at"])

            // Un mot ajouté ensuite porte son origine ; un mot déjà là garde la sienne, même rouvert.
            try store.addTerm("Vercel", origin: .user)
            try store.addTerm("seedance", origin: .learned(Self.jev))
            _ = try HistoryStore(path: path)
            let reopened = try HistoryStore(path: path).dictionary()
            #expect(reopened.map(\.term) == ["OpenRouter", "Seedance", "Vercel"])
            #expect(reopened.map(\.origin) == [.unknown, .unknown, .user])
            #expect(reopened.prefix(2).map(\.id) == ["ancien-2", "ancien-1"])
        }
    }

    @Test func eachOriginIsStoredWithItsJudge() throws {
        try withDatabase { path in
            let openAI = DictionaryJudge(kind: .correctionModel, provider: "OpenAI", model: CleanupModel.openAIFallback)
            let store = try HistoryStore(path: path)
            try store.addTerm("Vercel", origin: .user)
            try store.addTerm("Seedance", origin: .learned(Self.jev))
            try store.addTerm("Cloudflare", origin: .learned(Self.deepSeek))
            try store.addTerm("OpenRouter", origin: .learned(openAI))
            // Sans origine précisée : jamais « ajouté par toi » ni un juge par défaut.
            try store.addTerm("Supabase")
            let entries = try HistoryStore(path: path).dictionary()
            let origins = Dictionary(uniqueKeysWithValues: entries.map { ($0.term, $0.origin) })
            #expect(origins == [
                "Vercel": .user, "Seedance": .learned(Self.jev), "Cloudflare": .learned(Self.deepSeek),
                "OpenRouter": .learned(openAI), "Supabase": .unknown
            ])
            #expect(entries.allSatisfy { $0.confirmedAt == nil })
        }
    }

    @Test func unreadableOriginIsUnknown() throws {
        try withDatabase { path in
            _ = try HistoryStore(path: path)
            // Valeur d'une version plus récente, ou juge incomplet : origine inconnue, jamais d'erreur.
            try execute(
                """
                INSERT INTO dictionary (id, term, created_at, origin, judge_provider, judge_model) VALUES
                    ('a', 'Alpha', 1790000000, 'robot', 'Fournisseur', 'modele'),
                    ('b', 'Beta', 1790000000, 'jev', NULL, 'jev-latest'),
                    ('c', 'Gamma', 1790000000, 'model', 'DeepSeek', '');
                """,
                at: path
            )
            #expect(try HistoryStore(path: path).dictionary().map(\.origin) == [.unknown, .unknown, .unknown])
        }
    }

    @Test func keepingALearnedWordNotesItWithoutChangingItsOrigin() throws {
        try withDatabase { path in
            let store = try HistoryStore(path: path)
            try store.addTerm("Seedance", origin: .learned(Self.jev))
            try store.addTerm("Vercel", origin: .user)
            try store.addTerm("Supabase")
            for term in ["seedance", "Vercel", "Supabase", "Absent"] { try store.confirmLearnedTerm(term) }
            let entries = try HistoryStore(path: path).dictionary()
            let seedance = try #require(entries.first { $0.term == "Seedance" })
            #expect(seedance.origin == .learned(Self.jev))
            #expect(entries.filter { $0.confirmedAt != nil }.map(\.term) == ["Seedance"])
            // Une seconde confirmation garde la date de la première.
            try store.confirmLearnedTerm("Seedance")
            #expect(try store.dictionary().first { $0.term == "Seedance" }?.confirmedAt == seedance.confirmedAt)
        }
    }

    @Test func filterSeparatesWordsAddedByHandFromLearnedOnes() {
        let entries = [
            DictionaryEntry(term: "Vercel", origin: .user),
            DictionaryEntry(term: "Seedance", origin: .learned(Self.jev)),
            DictionaryEntry(term: "Cloudflare", origin: .learned(Self.deepSeek), confirmedAt: Date()),
            DictionaryEntry(term: "Supabase", origin: .unknown)
        ]
        func terms(_ filter: DictionaryFilter) -> [String] { entries.filter(filter.includes).map(\.term) }
        #expect(terms(.all) == ["Vercel", "Seedance", "Cloudflare", "Supabase"])
        #expect(terms(.addedByUser) == ["Vercel"])
        // Gardé par « Oui », un mot appris le reste ; un mot d'avant le suivi n'est que dans « Tous ».
        #expect(terms(.learned) == ["Seedance", "Cloudflare"])
    }

    // MARK: - Juge

    private static func speech(deepSeek: Bool = true, openAI: Bool = true, voice: ProviderID = .xai, jev: Bool = false) -> SpeechRequest {
        SpeechRequest(provider: voice, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture-voice",
                      language: .french, keyterms: [], prompt: "", cleanupKey: deepSeek ? "fixture-ds" : nil,
                      fallbackKey: openAI ? "fixture-oa" : nil, judgeKey: jev ? "fixture-jev" : nil)
    }

    /// Jugement avec une note de Jev fixe (nil : Jev sans réponse) et un modèle de correction simulé.
    private static func judge(_ candidates: [CorrectionLearner.Candidate] = sidance, scores: [Double]?,
                              speech: SpeechRequest, stub: ModelStub) async -> TermJudgement {
        await TermJudge.judge(candidates, dictated: "J'ai testé Sidance avec open router.", speech: speech, scoreRequest: { _, _, _ in
            (scores, UsageEvent(api: .typesafeJudge, model: "jev-fixture", costUSD: 0, succeeded: scores != nil))
        }, transport: { try await stub.request($0) })
    }

    /// Jev tranche un cas net : le mot porte TypeSafe et le modèle que la réponse de Jev annonce.
    @Test func clearJevVerdictRecordsJevAndTheModelItAnnounced() async {
        let stub = ModelStub()
        let reply = Data(#"{"model":"jev-1.13.0","answers":{"c0":{"type":"noul","noul":0.93}},"usage":{"input_tokens":400}}"#.utf8)
        let judgement = await TermJudge.judge(Self.sidance, dictated: "J'ai testé Sidance.", speech: Self.speech(jev: true), scoreRequest: {
            await JevJudge.scores($0, dictated: $1, key: $2) { request in
                (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }, transport: { try await stub.request($0) })
        #expect(judgement.kept == [LearnedTerm(term: "Seedance", judge: DictionaryJudge(kind: .jev, provider: "TypeSafe", model: "jev-1.13.0"))])
        // Note nette : le modèle de correction n'est pas appelé.
        #expect(await stub.hosts.isEmpty)
    }

    /// Sans Jev, le modèle de correction tranche : le mot porte le fournisseur et le modèle de la route qui a
    /// répondu, qui suivent les clés enregistrées et le fournisseur de voix.
    @Test func modelVerdictRecordsTheRouteThatAnswered() async {
        func judge(_ speech: SpeechRequest, failing: Set<String> = []) async -> (judges: [DictionaryJudge], hosts: [String]) {
            let stub = ModelStub(failing: failing)
            let judgement = await Self.judge(scores: nil, speech: speech, stub: stub)
            return (judgement.kept.map(\.judge), await stub.hosts)
        }
        let primary = await judge(Self.speech())
        #expect(primary.judges == [Self.deepSeek])
        #expect(primary.hosts == ["api.deepseek.com"])

        let relay = await judge(Self.speech(), failing: ["api.deepseek.com"])
        #expect(relay.judges == [DictionaryJudge(kind: .correctionModel, provider: "OpenAI", model: CleanupModel.openAIFallback)])
        #expect(relay.hosts == ["api.deepseek.com", "api.openai.com"])

        let xai = await judge(Self.speech(deepSeek: false, openAI: false))
        #expect(xai.judges == [DictionaryJudge(kind: .correctionModel, provider: "xAI", model: ProviderID.xai.defaultCleanupModel)])
        #expect(xai.hosts == ["api.x.ai"])

        let openAIVoice = await judge(Self.speech(deepSeek: false, openAI: false, voice: .openAI))
        #expect(openAIVoice.judges == [DictionaryJudge(kind: .correctionModel, provider: "OpenAI", model: ProviderID.openAI.defaultCleanupModel)])

        // Personne ne répond : rien n'est appris.
        let silent = await judge(Self.speech(), failing: ["api.deepseek.com", "api.openai.com"])
        #expect(silent.judges.isEmpty)
    }

    /// Chaque mot garde son propre juge : Jev pour une note nette, le modèle de correction pour un cas douteux qu'il
    /// approuve ; s'il ne répond pas, la note de Jev suffit et Jev reste le juge.
    @Test func eachWordKeepsTheJudgeThatDecidedIt() async {
        let words = Self.sidance + [CorrectionLearner.Candidate(heard: "open router", corrected: "OpenRouter")]
        let mixed = await Self.judge(words, scores: [0.93, 0.6], speech: Self.speech(jev: true),
                                     stub: ModelStub(content: #"{"garder": ["OpenRouter"]}"#))
        #expect(mixed.kept == [LearnedTerm(term: "Seedance", judge: Self.jev), LearnedTerm(term: "OpenRouter", judge: Self.deepSeek)])

        let silent = await Self.judge(words, scores: [0.93, 0.75], speech: Self.speech(jev: true),
                                      stub: ModelStub(failing: ["api.deepseek.com", "api.openai.com"]))
        #expect(silent.kept == [LearnedTerm(term: "Seedance", judge: Self.jev), LearnedTerm(term: "OpenRouter", judge: Self.jev)])
    }

    // MARK: - Outils

    private func withDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-dictionary-origin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("history.sqlite").path)
    }

    private func execute(_ sql: String, at path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw StoreError.message("Ouverture de la base fictive impossible.")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.message(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func columns(at path: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw StoreError.message("Ouverture de la base fictive impossible.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(dictionary);", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.message("Lecture des colonnes impossible.")
        }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.append(String(cString: name)) }
        }
        return names
    }
}
