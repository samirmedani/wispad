import Foundation
import Testing
@testable import WispadCore

@Suite struct LocalModelTests {
    private func speech(_ address: String, model: String = "qwen2.5:7b") -> SpeechRequest {
        var request = SpeechRequest(provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0",
                                    apiKey: "", language: .french, keyterms: [], prompt: "")
        request.cleanupChoice = CleanupChoice(account: CleanupModel.localAccount, model: model)
        request.chosenCleanupKey = address
        request.cleanupRelay = .off
        return request
    }

    @Test func localAddressesAreValidated() {
        #expect(TextCleaner.localBase("http://localhost:11434/v1/")?.absoluteString == "http://localhost:11434/v1")
        #expect(TextCleaner.localBase(" https://gpu.lan:8080/v1 ") != nil)
        #expect(TextCleaner.localBase("localhost:11434") == nil)
        #expect(TextCleaner.localBase("ftp://x/v1") == nil)
        #expect(TextModelCatalog.listURL(account: CleanupModel.localAccount, key: CleanupModel.ollamaURL)?.absoluteString
                == "http://localhost:11434/v1/models")
        #expect(CleanupChoice(rawValue: "local/llama3.2")?.providerName == "Local")
    }

    @Test func localCorrectionSendsNoKeyNoReasoningAndCostsNothing() async throws {
        let route = try #require(TextCleaner.routes(speech(CleanupModel.ollamaURL)).first)
        #expect(route.api == .localCleanup)
        #expect(route.url.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(route.key.isEmpty)
        let seen = Captured()
        let transport: TextCleaner.HTTPTransport = { request in
            await seen.store(request)
            let body = #"{"choices":[{"message":{"content":"On se voit mercredi à 14 h."},"finish_reason":"stop"}],"usage":{"prompt_tokens":900,"completion_tokens":12}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let text = "on se voit mercredi à quatorze heures"
        let outcome = await TextCleaner.clean(transcript: text, request: CorrectionRequest(transcript: text, dictionary: [], previousDictations: [], language: .french),
                                              speech: speech(CleanupModel.ollamaURL), enabled: true, transport: transport)
        #expect(outcome.text.contains("mercredi"))
        #expect(outcome.usage?.api == .localCleanup)
        #expect(outcome.usage?.costUSD == 0)
        let request = try #require(await seen.request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["reasoning_effort"] == nil)
        #expect(body["max_tokens"] != nil)
        #expect(body["model"] as? String == "qwen2.5:7b")
    }

    actor Captured {
        var request: URLRequest?
        func store(_ value: URLRequest) { request = value }
    }

    /// Aller-retour HTTP réel contre un serveur compatible OpenAI sur ce Mac (WISPAD_LOCAL_TEST_URL).
    @Test func liveLocalServer() async throws {
        guard let address = ProcessInfo.processInfo.environment["WISPAD_LOCAL_TEST_URL"] else { return }
        let text = "euh on se voit mercredi à quatorze heures"
        let start = Date()
        let outcome = await TextCleaner.clean(transcript: text, request: CorrectionRequest(transcript: text, dictionary: [], previousDictations: [], language: .french),
                                              speech: speech(address, model: "faux-modele"), enabled: true)
        print("LOCAL-LIVE", String(format: "%.2f s", Date().timeIntervalSince(start)), outcome.usage?.api.rawValue ?? "-", outcome.usage?.costUSD ?? -1, "|", outcome.text)
        #expect(outcome.usage?.succeeded == true)
    }
}
