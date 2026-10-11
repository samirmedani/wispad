import Foundation
import os
import XCTest
@testable import WispadCore

/// Sonde réseau : rejoue un enregistrement (WISPAD_REPLAY_AUDIO, WAV 16 kHz) en temps réel dans le flux xAI, puis en
/// fichier, et n'affiche que des comptes de mots : segments reçus, texte du flux, texte du fichier, écart. Sert à
/// comprendre un désaccord flux/fichier sans afficher la dictée. Clés de test : scripts/live-test.sh StreamReplayLiveTests.
final class StreamReplayLiveTests: XCTestCase {
    func testReplayCountsOnly() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = env["WISPAD_LIVE_XAI_KEY"] ?? ""
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1" && !key.isEmpty, "Sonde réseau réservée à scripts/live-test.sh.")
        let path = try XCTUnwrap(env["WISPAD_REPLAY_AUDIO"], "WISPAD_REPLAY_AUDIO absent.")
        let url = URL(fileURLWithPath: path)
        var pcm = try FranglaisBenchmarkTests.pcm(fromWAV: Data(contentsOf: url))
        // WISPAD_REPLAY_CUT=secondes : arrête le flux en pleine parole, comme un arrêt sans pause.
        if let cut = env["WISPAD_REPLAY_CUT"].flatMap(Double.init) {
            pcm = pcm.prefix(min(pcm.count, Int(cut * 32_000) / 2 * 2))
        }
        let speech = SpeechRequest(
            provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0", apiKey: key,
            language: .french, keyterms: RecognitionHints.keyterms(dictionary: [], context: []),
            prompt: CorrectionPrompt.recognitionPrompt(appName: nil, nearby: nil)
        )
        let session = LiveSpeechSession(request: speech)
        let settled = OSAllocatedUnfairLock(initialState: [Int]())
        let shown = OSAllocatedUnfairLock(initialState: 0)
        session.onPartial = { text in shown.withLock { $0 = WordCount.count(text) } }
        session.onSettled = { text in settled.withLock { $0.append(WordCount.count(text)) } }
        try await session.start()
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 3_200, pcm.count)
            session.send(pcm.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let finish = try await session.finish()
        session.cancel()
        let file = try await BatchTranscriber.transcribe(fileURL: url, request: speech)
        print("REPLAY pauses (mots à chaque pause) : \(settled.withLock { $0 })")
        print("REPLAY affiché en dernier \(shown.withLock { $0 }) mots")
        print("REPLAY flux \(WordCount.count(finish.text)) mots, fin finalisée \(finish.endingFinalized) ; fichier \(WordCount.count(file)) mots ; écart \(TranscriptEquivalence.differingWords(finish.text, file)) mots")
    }
}
