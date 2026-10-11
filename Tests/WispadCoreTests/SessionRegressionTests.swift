import Foundation
import Testing
@testable import WispadCore

struct SessionRegressionTests {
    private func session() -> LiveSpeechSession {
        LiveSpeechSession(request: SpeechRequest(provider: .openAI, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture", language: .french, keyterms: [], prompt: ""))
    }

    @Test(.timeLimit(.minutes(1))) func completionBeforeFinishIsNotLost() async throws {
        let stream = session()
        defer { stream.cancel() }
        stream.send(Data([0, 0]))
        stream.handle(.string(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Phrase de test."}"#))
        let first = try await stream.finish()
        #expect(first.text == "Phrase de test.")
        #expect(first.endingFinalized)
        let second = try await stream.finish()
        #expect(second.text == "Phrase de test.")
    }

    @Test func cancelledSessionRejectsLateFinish() async throws {
        let stream = session()
        stream.send(Data([0, 0]))
        stream.cancel()
        await #expect(throws: CancellationError.self) { try await stream.finish() }
    }

    @Test func serverErrorRejectsPartialInsteadOfSilentlyTruncating() async throws {
        let stream = session()
        defer { stream.cancel() }
        stream.send(Data([0, 0]))
        stream.handle(.string(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"partial"}"#))
        stream.handle(.string(#"{"type":"error","error":{"message":"fixture-error"}}"#))
        await #expect(throws: SpeechError.self) { try await stream.finish() }
    }

    @Test func resultResolutionBeforeAndAfterWaiting() async throws {
        let early = AsyncResult<String>()
        early.resolve(.success("first"))
        early.resolve(.success("duplicate"))
        #expect(try await early.value() == "first")
        let late = AsyncResult<String>()
        let waiter = Task { try await late.value() }
        late.resolve(.success("later"))
        #expect(try await waiter.value == "later")
    }
}
