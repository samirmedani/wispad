import Foundation
import Testing
@testable import WispadCore

/// Réponses HTTP simulées, dans l'ordre ; chaque requête reçue est gardée pour être inspectée. Aucun réseau.
private actor ProviderHTTPStub {
    enum Step: Sendable {
        case status(Int)
        /// Aucune réponse : la requête attend jusqu'à son annulation.
        case silence
    }

    private var steps: [Step]
    private let body: String
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step], body: String) {
        self.steps = steps
        self.body = body
    }

    var hosts: [String] { requests.map { $0.url?.host ?? "" } }

    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case .silence:
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw URLError(.timedOut)
        case .status(let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            let payload = (200..<300).contains(status) ? body : #"{"error":{"message":"fixture"}}"#
            return (Data(payload.utf8), response)
        }
    }
}

/// Messages du flux réellement envoyés, dans l'ordre. Aucun socket n'est ouvert.
private final class SentMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String] = []

    func add(_ message: URLSessionWebSocketTask.Message) {
        let kind: String
        switch message {
        case .data(let data):
            kind = "audio:\(data.count)"
        case .string(let text):
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            kind = object?["type"] as? String ?? "text"
        @unknown default:
            kind = "other"
        }
        lock.withLock { kinds.append(kind) }
    }

    func wait(until predicate: @escaping @Sendable ([String]) -> Bool) async -> [String] {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let snapshot = lock.withLock { kinds }
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return lock.withLock { kinds }
    }
}

/// Appels aux fournisseurs, requête par requête : une réponse 429 ou 5xx, une réponse lente ou un flux muet donnent
/// un échec borné et lisible, sans nouvelle tentative chez le même service ni clé dans un message.
struct ProviderRequestTests {
    private static let transcript = "Phrase de test."
    private static let fileReply = #"{"text":"Phrase du fichier."}"#
    private static let correctionReply = #"{"choices":[{"message":{"content":"Phrase de test."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#

    private static func speech(_ provider: ProviderID = .xai) -> SpeechRequest {
        SpeechRequest(provider: provider, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture-voice-key",
                      language: .french, keyterms: ["Wispad"], prompt: "", cleanupKey: "fixture-deepseek-key",
                      fallbackKey: "fixture-openai-key")
    }

    private static func clean(_ stub: ProviderHTTPStub, speech: SpeechRequest = speech()) async -> CleanupOutcome {
        await TextCleaner.clean(transcript: transcript, request: CorrectionRequest(transcript: transcript),
                                speech: speech, enabled: true, transport: { try await stub.request($0) })
    }

    private static func audioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-provider-\(UUID().uuidString).wav")
        try Data(repeating: 0, count: 64).write(to: url)
        return url
    }

    private static func xaiSession() -> LiveSpeechSession {
        LiveSpeechSession(request: SpeechRequest(
            provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture-voice-key",
            language: .french, keyterms: [], prompt: ""
        ))
    }

    // MARK: - Fichier

    /// Quota (429) ou panne (5xx) : une seule requête, un message clair, sans la clé. Le relais éventuel est décidé
    /// une fois par la fin de dictée, jamais par une nouvelle tentative ici.
    @Test(arguments: [ProviderID.xai, .openAI], [429, 500, 503])
    func refusedFileFailsAfterOneRequestWithAReadableMessage(provider: ProviderID, status: Int) async throws {
        let audio = try Self.audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let stub = ProviderHTTPStub([.status(status), .status(200)], body: Self.fileReply)
        let speech = Self.speech(provider)
        do {
            _ = try await BatchTranscriber.transcribe(fileURL: audio, request: speech, transport: { try await stub.request($0) })
            Issue.record("Une réponse refusée doit faire échouer la transcription du fichier.")
        } catch {
            #expect(error.localizedDescription == "Transcription refusée (HTTP \(status)).")
            #expect(!error.localizedDescription.contains(speech.apiKey))
        }
        #expect(await stub.requests.count == 1)
    }

    /// La requête du fichier a son délai et ne porte la clé que dans son en-tête, jamais dans l'adresse.
    @Test(arguments: [ProviderID.xai, .openAI])
    func fileRequestHasATimeoutAndKeepsTheKeyInItsHeader(provider: ProviderID) async throws {
        let audio = try Self.audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let stub = ProviderHTTPStub([.status(200)], body: Self.fileReply)
        let speech = Self.speech(provider)
        let text = try await BatchTranscriber.transcribe(fileURL: audio, request: speech, transport: { try await stub.request($0) })
        #expect(text == "Phrase du fichier.")
        let requests = await stub.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.timeoutInterval == 60)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(speech.apiKey)")
        #expect(request.url?.absoluteString.contains(speech.apiKey) == false)
    }

    // MARK: - Correction

    /// 429 ou 5xx chez DeepSeek : le relais est essayé une fois, DeepSeek n'est pas rappelé.
    @Test(arguments: [429, 500, 503])
    func refusedCorrectionGoesToTheRelayOnceWithoutRetryingTheSameService(status: Int) async throws {
        let stub = ProviderHTTPStub([.status(status), .status(200), .status(200)], body: Self.correctionReply)
        let result = await Self.clean(stub)
        #expect(await stub.hosts == ["api.deepseek.com", "api.openai.com"])
        let usage = try #require(result.usage)
        #expect(usage.api == .openAICleanup)
        #expect(usage.succeeded)
        #expect(usage.fallback == APIFallback(fromAPI: .deepSeekCleanup, stage: .correction, reason: .requestFailed))
        #expect(result.failedUsages.map(\.api) == [.deepSeekCleanup])
        #expect(result.failedUsages.allSatisfy { !$0.succeeded && $0.costUSD == nil })
        #expect(result.fallback == "OpenAI")
    }

    /// Refusée partout : deux requêtes en tout, puis le texte transcrit est gardé tel quel.
    @Test(arguments: [429, 503])
    func correctionRefusedEverywhereKeepsTheTranscriptAfterTwoRequests(status: Int) async throws {
        let stub = ProviderHTTPStub([.status(status), .status(status), .status(200)], body: Self.correctionReply)
        let result = await Self.clean(stub)
        #expect(await stub.hosts == ["api.deepseek.com", "api.openai.com"])
        #expect(result.text == Self.transcript)
        #expect(result.usage?.succeeded == false)
        #expect(result.fallback == nil)
    }

    /// Un service qui ne répond pas est coupé à son délai, puis le relais répond : jamais d'attente sans fin.
    @Test(.timeLimit(.minutes(1))) func silentCorrectionIsCutAtItsBudgetThenTheRelayAnswers() async throws {
        let stub = ProviderHTTPStub([.silence, .status(200)], body: Self.correctionReply)
        let clock = Date()
        let result = await Self.clean(stub)
        let elapsed = Date().timeIntervalSince(clock)
        #expect(await stub.hosts == ["api.deepseek.com", "api.openai.com"])
        #expect(result.usage?.api == .openAICleanup)
        #expect(result.usage?.succeeded == true)
        #expect(result.failedUsages.map(\.succeeded) == [false])
        #expect(result.failedUsages.first?.costUSD == nil)
        #expect(elapsed >= TextCleaner.perRouteSeconds - 0.2)
        #expect(elapsed < TextCleaner.perRouteSeconds + 5)
    }

    /// Chaque requête de correction a son délai et ne porte sa clé que dans son en-tête : ni dans l'adresse, ni
    /// dans le texte envoyé.
    @Test func correctionRequestsCarryATimeoutAndTheirKeyOnlyInTheHeader() async throws {
        let stub = ProviderHTTPStub([.status(503), .status(200)], body: Self.correctionReply)
        let speech = Self.speech()
        _ = await Self.clean(stub, speech: speech)
        let requests = await stub.requests
        #expect(requests.count == 2)
        let keys = [speech.cleanupKey ?? "", speech.fallbackKey ?? "", speech.apiKey]
        for (request, key) in zip(requests, [speech.cleanupKey ?? "", speech.fallbackKey ?? ""]) {
            #expect(request.timeoutInterval > 0)
            #expect(request.timeoutInterval <= 8)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
            let address = request.url?.absoluteString ?? ""
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            for secret in keys {
                #expect(!address.contains(secret))
                #expect(!body.contains(secret))
            }
        }
    }

    // MARK: - Juge du dictionnaire

    /// Jev refuse (429) : une requête bornée, un échec compté, aucune nouvelle tentative.
    @Test func jevRefusalIsOneBoundedRequest() async throws {
        let stub = ProviderHTTPStub([.status(429), .status(200)], body: "{}")
        let candidates = [CorrectionLearner.Candidate(heard: "Openaille", corrected: "OpenAI")]
        let (scores, usage) = await JevJudge.scores(candidates, dictated: "Openaille", key: "fixture-jev-key",
                                                    transport: { try await stub.request($0) })
        #expect(scores == nil)
        #expect(!usage.succeeded)
        let requests = await stub.requests
        #expect(requests.count == 1)
        #expect(requests.first?.timeoutInterval == 5)
        #expect(requests.first?.url?.absoluteString.contains("fixture-jev-key") == false)
    }

    // MARK: - Flux en direct

    /// Le texte final n'arrive pas après l'arrêt : le flux est en échec au bout de sa borne, et l'arrêt n'a été
    /// envoyé qu'une fois (ni `finalize` ni `audio.done` répétés pendant l'attente).
    @Test(.timeLimit(.minutes(1))) func unansweredFinalEndsTheStreamOnceWithoutRetrying() async throws {
        let session = Self.xaiSession()
        defer { session.cancel() }
        session.tailFinalWaitSeconds = 0.05
        session.finalReplySeconds = 0.3
        let sent = SentMessages()
        session.onOutbound = { sent.add($0) }
        session.handle(.string(#"{"type":"transcript.created"}"#))
        session.send(Data([1, 2, 3, 4]))
        session.handle(.string(#"{"type":"transcript.partial","text":"Bonjour","is_final":false,"speech_final":false}"#))
        let clock = Date()
        await #expect(throws: SpeechError.self) { try await session.finish() }
        #expect(Date().timeIntervalSince(clock) < 5)
        let kinds = await sent.wait { $0.contains("audio.done") }
        #expect(kinds == ["audio:4", "finalize", "audio.done"])
    }

    /// Erreur du fournisseur au milieu du flux (quota, panne) : l'arrêt échoue aussitôt, sans attendre la borne du
    /// texte final ; la dictée passe par le fichier.
    @Test(.timeLimit(.minutes(1))) func providerErrorMidStreamFailsAtOnce() async throws {
        let session = Self.xaiSession()
        defer { session.cancel() }
        session.finalReplySeconds = 30
        session.handle(.string(#"{"type":"transcript.created"}"#))
        session.send(Data([1, 2, 3, 4]))
        session.handle(.string(#"{"type":"transcript.partial","text":"Bonjour","is_final":false,"speech_final":false}"#))
        session.handle(.string(#"{"type":"error","message":"fixture"}"#))
        let clock = Date()
        await #expect(throws: SpeechError.self) { try await session.finish() }
        #expect(Date().timeIntervalSince(clock) < 5)
    }
}
