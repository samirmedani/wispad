import Foundation
import Testing
@testable import WispadCore

struct WrittenFinishPipelineTests {
    @Test(arguments: [DictationTone.natural, .polished, .casual])
    func anUnchangedModelReplyGetsOnlyTheChosenWrittenRegister(_ tone: DictationTone) async throws {
        actor Counter {
            var count = 0
            func increment() { count += 1 }
        }
        let calls = Counter()
        let heard = "Faut inspecter le toit."
        var request = CorrectionRequest(transcript: heard, language: .french)
        request.tone = tone
        let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: "",
                                   language: .french, keyterms: [], prompt: "", cleanupKey: "fixture", cleanupRelay: .off)
        let result = await TextCleaner.clean(transcript: heard, request: request, speech: speech, enabled: true) { call in
            await calls.increment()
            let payload: [String: Any] = ["choices": [["message": ["content": heard], "finish_reason": "stop"]],
                                           "usage": ["prompt_tokens": 10, "completion_tokens": 7]]
            return (try JSONSerialization.data(withJSONObject: payload),
                    HTTPURLResponse(url: call.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.text == (tone == .casual ? heard : "Il faut inspecter le toit."))
        #expect(await calls.count == 1)
        #expect(TextCleaner.completeWrittenGrammar(heard, language: .english, tone: tone) == heard)
    }

    @Test func failedCorrectionKeepsItsOriginalFallback() async {
        let heard = "Faut inspecter le toit."
        let request = CorrectionRequest(transcript: heard, language: .french)
        let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: "",
                                   language: .french, keyterms: [], prompt: "", cleanupKey: "fixture", cleanupRelay: .off)
        let result = await TextCleaner.clean(transcript: heard, request: request, speech: speech, enabled: true) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(result.text == heard)
    }
}
