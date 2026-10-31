import Foundation
import os
import Testing
@testable import WispadCore

struct StreamEndTests {
    @Test func reliabilityIgnoresPunctuationAndUsesTheFinalFlag() {
        let interim = StreamFinish(text: "Tu vois un autre truc", endingFinalized: false, coveredSeconds: nil)
        #expect(StreamEndReliability.fallback(interim, audioSeconds: 4.28) == .unfinalized)
        let locked = StreamFinish(text: "sans ponctuation du tout", endingFinalized: true, coveredSeconds: 4)
        #expect(StreamEndReliability.fallback(locked, audioSeconds: 4.28) == nil)
        let short = StreamFinish(text: "Début seulement.", endingFinalized: true, coveredSeconds: 1)
        #expect(StreamEndReliability.fallback(short, audioSeconds: 4) == .shortCoverage)
        let trailingSilence = StreamFinish(text: "Phrase entière.", endingFinalized: true, coveredSeconds: 2)
        #expect(StreamEndReliability.fallback(trailingSilence, audioSeconds: 4) == nil)
        let longPause = StreamFinish(text: "Dictée longue.", endingFinalized: true, coveredSeconds: 8)
        #expect(StreamEndReliability.fallback(longPause, audioSeconds: 10.5) == nil)
    }

    @Test func staleDoneDoesNotReplaceALongerFinal() {
        var assembler = TranscriptAssembler()
        assembler.apply(.partial(text: "Bonjour tout le monde.", isFinal: true, speechFinal: true, endSeconds: 1.5))
        assembler.apply(.done(text: "Bonjour"))
        #expect(assembler.endingFinalized)
        #expect(assembler.bestText == "Bonjour tout le monde.")
        #expect(assembler.finalizedCoverageEnd == 1.5)
        assembler.noteAudioAfterFinal()
        #expect(!assembler.endingFinalized)
    }

    @Test func interimThenDoneIsNotFinalized() async throws {
        let session = xaiSession()
        defer { session.cancel() }
        session.tailFinalWaitSeconds = 0.05
        let log = OutboundLog()
        session.onOutbound = { log.add($0) }
        session.handle(.string(#"{"type":"transcript.created"}"#))
        session.send(Data([1, 2, 3, 4]))
        session.handle(.string(#"{"type":"transcript.partial","text":"Tu vois un autre truc","is_final":false,"speech_final":false}"#))
        let task = Task { try await session.finish() }
        let kinds = await log.wait { $0.contains("audio.done") }
        #expect(kinds == ["audio:4", "finalize", "audio.done"])
        session.handle(.string(#"{"type":"transcript.done","text":"Tu vois un autre truc","duration":1.1}"#))
        let finish = try await task.value
        #expect(finish.text == "Tu vois un autre truc")
        #expect(!finish.endingFinalized)
        #expect(StreamEndReliability.fallback(finish, audioSeconds: 4.28) == .unfinalized)
    }

    @Test func finalThenDoneStaysFinalized() async throws {
        let session = xaiSession()
        defer { session.cancel() }
        session.handle(.string(#"{"type":"transcript.created"}"#))
        session.send(Data([1, 2, 3, 4]))
        session.handle(.string(#"{"type":"transcript.partial","text":"Phrase complète.","is_final":true,"speech_final":true,"start":0,"duration":1.2}"#))
        session.handle(.string(#"{"type":"transcript.done","text":"Phrase complète.","duration":1.2}"#))
        let finish = try await session.finish()
        #expect(finish.text == "Phrase complète.")
        #expect(finish.endingFinalized)
        #expect(finish.coveredSeconds == 1.2)
        #expect(StreamEndReliability.fallback(finish, audioSeconds: 1.4) == nil)
    }

    @Test func finalArrivingAfterFinalizeIsKeptAndAudioPrecedesIt() async throws {
        let session = xaiSession()
        defer { session.cancel() }
        session.tailFinalWaitSeconds = 2
        let log = OutboundLog()
        session.onOutbound = { log.add($0) }
        session.beforeFinalizeDrain = { session.send(Data([9, 9])) }
        session.handle(.string(#"{"type":"transcript.created"}"#))
        session.send(Data([1, 2, 3, 4]))
        session.handle(.string(#"{"type":"transcript.partial","text":"Bonjour","is_final":false,"speech_final":false}"#))
        let task = Task { try await session.finish() }
        let afterFinalize = await log.wait { $0.contains("finalize") }
        #expect(afterFinalize == ["audio:4", "audio:2", "finalize"])
        session.handle(.string(#"{"type":"transcript.partial","text":"Bonjour tout le monde.","is_final":true,"speech_final":true,"start":0,"duration":1.6}"#))
        let afterDone = await log.wait { $0.contains("audio.done") }
        #expect(afterDone == ["audio:4", "audio:2", "finalize", "audio.done"])
        session.handle(.string(#"{"type":"transcript.done","text":"Bonjour","duration":1.6}"#))
        let finish = try await task.value
        #expect(finish.text == "Bonjour tout le monde.")
        #expect(finish.endingFinalized)
        #expect(finish.coveredSeconds == 1.6)
    }

    @Test func aSpeechFinalCoveringAllTheAudioEndsWithoutWaitingForDone() async throws {
        let session = xaiSession()
        defer { session.cancel() }
        session.tailFinalWaitSeconds = 2
        let log = OutboundLog()
        session.onOutbound = { log.add($0) }
        session.handle(.string(#"{"type":"transcript.created"}"#))
        session.send(Data(count: 32_000))
        session.handle(.string(#"{"type":"transcript.partial","text":"D'accord","is_final":false,"speech_final":false}"#))
        let task = Task { try await session.finish() }
        _ = await log.wait { $0.contains("finalize") }
        session.handle(.string(#"{"type":"transcript.partial","text":"D'accord, parfait.","is_final":true,"speech_final":false,"start":0,"duration":1.0}"#))
        session.handle(.string(#"{"type":"transcript.partial","text":"D'accord, parfait.","is_final":true,"speech_final":true,"start":0,"duration":1.0}"#))
        // Aucun transcript.done : le segment final couvre la seconde envoyée, la fin est tranchée.
        let finish = try await task.value
        #expect(finish.text == "D'accord, parfait.")
        #expect(finish.endingFinalized)
        #expect(finish.coveredSeconds == 1.0)
        let kinds = await log.wait { $0.contains("audio.done") }
        #expect(kinds == ["audio:32000", "finalize", "audio.done"])
    }

    @Test func aFinalShorterThanTheAudioStillWaitsForDone() async throws {
        let session = xaiSession()
        defer { session.cancel() }
        session.tailFinalWaitSeconds = 2
        let log = OutboundLog()
        session.onOutbound = { log.add($0) }
        session.handle(.string(#"{"type":"transcript.created"}"#))
        session.send(Data(count: 64_000))
        let resolved = OSAllocatedUnfairLock(initialState: false)
        let task = Task { () throws -> StreamFinish in
            let finish = try await session.finish()
            resolved.withLock { $0 = true }
            return finish
        }
        _ = await log.wait { $0.contains("finalize") }
        session.handle(.string(#"{"type":"transcript.partial","text":"Début","is_final":true,"speech_final":true,"start":0,"duration":1.0}"#))
        _ = await log.wait { $0.contains("audio.done") }
        // La seconde restante peut encore porter des mots : rien n'est tranché avant transcript.done.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!resolved.withLock { $0 })
        session.handle(.string(#"{"type":"transcript.done","text":"Début et la suite.","duration":2.0}"#))
        let finish = try await task.value
        #expect(finish.text == "Début et la suite.")
    }

    @Test func anIntermediateFinalWithoutSpeechFinalWaitsForDone() async throws {
        let session = xaiSession()
        defer { session.cancel() }
        session.tailFinalWaitSeconds = 2
        let log = OutboundLog()
        session.onOutbound = { log.add($0) }
        session.handle(.string(#"{"type":"transcript.created"}"#))
        session.send(Data(count: 32_000))
        let resolved = OSAllocatedUnfairLock(initialState: false)
        let task = Task { () throws -> StreamFinish in
            let finish = try await session.finish()
            resolved.withLock { $0 = true }
            return finish
        }
        _ = await log.wait { $0.contains("finalize") }
        session.handle(.string(#"{"type":"transcript.partial","text":"Un segment","is_final":true,"speech_final":false,"start":0,"duration":1.0}"#))
        _ = await log.wait { $0.contains("audio.done") }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!resolved.withLock { $0 })
        session.handle(.string(#"{"type":"transcript.done","text":"Un segment","duration":1.0}"#))
        let finish = try await task.value
        #expect(finish.text == "Un segment")
    }
}

private func xaiSession() -> LiveSpeechSession {
    LiveSpeechSession(request: SpeechRequest(
        provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture",
        language: .french, keyterms: [], prompt: ""
    ))
}

private final class OutboundLog: @unchecked Sendable {
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
        lock.lock()
        kinds.append(kind)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return kinds
    }

    func wait(until predicate: @escaping @Sendable ([String]) -> Bool) async -> [String] {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let kinds = snapshot()
            if predicate(kinds) { return kinds }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return snapshot()
    }
}

struct StreamPauseTests {
    @Test func aFinalSegmentWithNothingPendingAnnouncesAPause() {
        let session = xaiSession()
        defer { session.cancel() }
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        session.onSettled = { text in heard.withLock { $0.append(text) } }
        session.handle(.string(#"{"type":"transcript.created"}"#))
        session.handle(.string(#"{"type":"transcript.partial","text":"Bonjour","is_final":false,"speech_final":false}"#))
        #expect(heard.withLock { $0 }.isEmpty)
        session.handle(.string(#"{"type":"transcript.partial","text":"Bonjour à tous.","is_final":true,"speech_final":true}"#))
        #expect(heard.withLock { $0 } == ["Bonjour à tous."])
        session.handle(.string(#"{"type":"transcript.partial","text":"Et merci","is_final":false,"speech_final":false}"#))
        session.handle(.string(#"{"type":"transcript.partial","text":"Et merci.","is_final":true,"speech_final":true}"#))
        #expect(heard.withLock { $0 } == ["Bonjour à tous.", "Bonjour à tous, et merci."])
    }
}
