import Foundation
import XCTest
@testable import WispadCore

final class LiveAPITests: XCTestCase {
    private let phrase = "On fait la réunion mercredi à quinze heures."

    func testBudgetedOpenAIDictationPipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1", "Test réseau réservé à la passe explicite.")
        let key = env["WISPAD_LIVE_OPENAI_KEY"] ?? ""
        try XCTSkipUnless(!key.isEmpty, "Clé absente.")

        let wav = try makeSpeechWAV(phrase)
        let duration = wavDuration(wav)
        XCTAssertGreaterThan(duration, 0.4)
        XCTAssertLessThan(duration, 8, "La phrase de test doit rester très courte.")
        let estimate = duration / 60 * (0.0045 + 0.017) + 0.05
        let ledger = SpendLedger.wispadDefault()
        try ledger.reserve(estimate)

        let request = SpeechRequest(
            provider: .openAI,
            liveModel: "gpt-live-transcribe",
            fileModel: "gpt-transcribe",
            apiKey: key,
            language: .french,
            keyterms: ["réunion"],
            prompt: "Dictée française. Réunion."
        )
        let fileText = try await BatchTranscriber.transcribe(fileURL: wav, request: request)
        defer { try? FileManager.default.removeItem(at: wav) }
        let stream = LiveSpeechSession(request: request)
        defer { stream.cancel() }
        let partials = PartialLog()
        stream.onPartial = { partials.add($0) }
        try await stream.start()
        let pcm = try pcm16(from: wav)
        var offset = 0
        let chunk = 3200
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            stream.send(pcm.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let streamed = try await stream.finish()
        let cleaned = await TextCleaner.clean(
            transcript: "euh on fait la réunion mardi non mercredi à quinze heures",
            request: CorrectionRequest(
                transcript: "euh on fait la réunion mardi non mercredi à quinze heures",
                dictionary: ["réunion"]
            ),
            speech: SpeechRequest(
                provider: .openAI,
                liveModel: request.liveModel,
                fileModel: request.fileModel,
                apiKey: key,
                language: .french,
                keyterms: [],
                prompt: ""
            ),
            enabled: true
        ).text

        XCTAssertTrue(mentionsMeeting(fileText), "Le fichier doit contenir la phrase de test.")
        XCTAssertTrue(mentionsMeeting(streamed.text), "Le flux doit contenir la phrase de test.")
        XCTAssertTrue(cleaned.localizedCaseInsensitiveContains("mercredi"), "La correction doit respecter la phrase de test.")
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("mardi"), "La correction doit respecter la phrase de test.")
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("euh"), "La correction doit respecter la phrase de test.")
    }

    /// xAI (fichier) puis DeepSeek (correction) : vérifie que la consommation mesurée correspond aux appels réels.
    func testBudgetedXAIAndDeepSeekUsageIsMeasured() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1", "Test réseau réservé à la passe explicite.")
        let xaiKey = env["WISPAD_LIVE_XAI_KEY"] ?? ""
        let deepSeekKey = env["WISPAD_LIVE_DEEPSEEK_KEY"] ?? ""
        try XCTSkipUnless(!xaiKey.isEmpty && !deepSeekKey.isEmpty, "Clés absentes.")

        let wav = try makeSpeechWAV(phrase)
        let duration = wavDuration(wav)
        XCTAssertLessThan(duration, 8, "La phrase de test doit rester très courte.")
        try SpendLedger.wispadDefault().reserve(duration / 3_600 * 0.10 + 0.01)

        let request = SpeechRequest(
            provider: .xai,
            liveModel: "grok-voice-transcribe-2.0",
            fileModel: "grok-voice-transcribe-2.0",
            apiKey: xaiKey,
            language: .french,
            keyterms: [],
            prompt: "",
            cleanupKey: deepSeekKey
        )
        let text = try await BatchTranscriber.transcribe(fileURL: wav, request: request)
        XCTAssertTrue(mentionsMeeting(text), "La transcription xAI doit contenir la phrase de test.")
        let file = UsageEvent.transcription(provider: .xai, streaming: false, model: request.liveModel, audioSeconds: duration)
        XCTAssertEqual(file.costUSD!, duration / 3_600 * 0.10, accuracy: 1e-9)

        let outcome = await TextCleaner.clean(
            transcript: "euh " + text,
            request: CorrectionRequest(transcript: "euh " + text, dictionary: []),
            speech: request,
            enabled: true
        )
        let usage = try XCTUnwrap(outcome.usage)
        XCTAssertTrue(usage.succeeded, "La correction DeepSeek doit répondre en moins de 4 s.")
        XCTAssertEqual(usage.api, .deepSeekCleanup)
        XCTAssertGreaterThan(usage.tokens.input + usage.tokens.cachedInput, 50)
        XCTAssertGreaterThan(usage.tokens.output, 3)
        XCTAssertGreaterThan(usage.costUSD ?? 0, 0)
        XCTAssertTrue(mentionsMeeting(outcome.text))
        print("MESURE xai_fichier=\(String(format: "%.2f", duration)) s coût=\(file.costUSD!) $ | deepseek entrée=\(usage.tokens.input)+\(usage.tokens.cachedInput) cache sortie=\(usage.tokens.output) coût=\(usage.costUSD!) $ latence=\(usage.latencyMs) ms")
    }

    /// Juge réel (DeepSeek) : garde les marques mal entendues, refuse les retouches sans intérêt.
    func testBudgetedTermJudgeKeepsOnlyUsefulTerms() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1", "Test réseau réservé à la passe explicite.")
        let deepSeekKey = env["WISPAD_LIVE_DEEPSEEK_KEY"] ?? ""
        try XCTSkipUnless(!deepSeekKey.isEmpty, "Clé DeepSeek absente.")
        try SpendLedger.wispadDefault().reserve(0.01)
        let speech = SpeechRequest(
            provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0",
            apiKey: "", language: .french, keyterms: [], prompt: "", cleanupKey: deepSeekKey
        )
        let cases: [(String, [CorrectionLearner.Candidate], [String])] = [
            ("J'ai testé Sidance hier soir avec open router.",
             [.init(heard: "Sidance", corrected: "Seedance"), .init(heard: "open router", corrected: "OpenRouter")],
             ["Seedance", "OpenRouter"]),
            ("Passe la commande avant mardi, bonjour à l'équipe.",
             [.init(heard: "commande", corrected: "Commande"), .init(heard: "bonjour", corrected: "Bonjour")],
             []),
            ("On déploie sur cloud flair et on prévient Jean demain.",
             [.init(heard: "cloud flair", corrected: "Cloudflare"), .init(heard: "demain", corrected: "Demain")],
             ["Cloudflare"]),
        ]
        for (dictated, candidates, expected) in cases {
            let judgement = await TermJudge.judge(candidates, dictated: dictated, speech: speech)
            let usage = try XCTUnwrap(judgement.usages.last)
            XCTAssertTrue(usage.succeeded, "Le juge doit répondre en moins de 15 s.")
            XCTAssertEqual(judgement.kept.map(\.term), expected, dictated)
            // Seul DeepSeek a une clé : c'est lui qui a tranché, avec le modèle de sa route.
            XCTAssertTrue(judgement.kept.allSatisfy { $0.judge == DictionaryJudge(kind: .correctionModel, provider: "DeepSeek", model: CleanupModel.deepSeek) })
            print("MESURE juge \(candidates.map(\.corrected)) → \(judgement.kept.map(\.term)) entrée=\(usage.tokens.input)+\(usage.tokens.cachedInput) sortie=\(usage.tokens.output) coût=\(usage.costUSD ?? 0) $ latence=\(usage.latencyMs) ms")
        }
    }

    /// Relais réel : correction DeepSeek → gpt-5.4-mini, et juge Jev + second avis.
    func testBudgetedRelayAndCombinedJudge() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1", "Test réseau réservé à la passe explicite.")
        let deepSeek = env["WISPAD_LIVE_DEEPSEEK_KEY"] ?? "", openAI = env["WISPAD_LIVE_OPENAI_KEY"] ?? "", jev = env["WISPAD_LIVE_TYPESAFE_KEY"] ?? ""
        try XCTSkipUnless(!deepSeek.isEmpty && !openAI.isEmpty && !jev.isEmpty, "Clés absentes.")
        try SpendLedger.wispadDefault().reserve(0.02)
        let speech = SpeechRequest(provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0",
                                   apiKey: "", language: .french, keyterms: [], prompt: "",
                                   cleanupKey: deepSeek, fallbackKey: openAI, judgeKey: jev)
        let raw = "euh donc on se voit euh mercredi à quinze heures pour la réunion"
        let started = Date()
        let cleaned = await TextCleaner.clean(transcript: raw, request: CorrectionRequest(transcript: raw), speech: speech, enabled: true)
        let seconds = Date().timeIntervalSince(started)
        print("MESURE correction en \(String(format: "%.2f", seconds)) s via \(cleaned.fallback ?? "DeepSeek") : \(cleaned.text) | échecs avant : \(cleaned.failedUsages.map(\.api.rawValue)) | coût \(cleaned.usage?.costUSD ?? 0) $")
        XCTAssertTrue(cleaned.usage?.succeeded == true)
        XCTAssertLessThan(seconds, 5.5)
        XCTAssertFalse(cleaned.text.localizedCaseInsensitiveContains("euh"))

        let words: [CorrectionLearner.Candidate] = [
            .init(heard: "cloud flair", corrected: "Cloudflare"), .init(heard: "demain", corrected: "Demain"),
            .init(heard: "notion", corrected: "Notion"), .init(heard: "cursor", corrected: "Cursor")
        ]
        let judged = await TermJudge.judge(words, dictated: "On déploie sur cloud flair demain, note-le dans notion, j'ouvre cursor.", speech: speech)
        print("MESURE juge → \(judged.kept.map { "\($0.term) (\($0.judge.provider) \($0.judge.model))" }) | appels : \(judged.usages.map { "\($0.api.rawValue) \($0.succeeded ? "ok" : "échec") \($0.latencyMs) ms" })")
        XCTAssertTrue(judged.kept.map(\.term).contains("Cloudflare"))
        XCTAssertFalse(judged.kept.map(\.term).contains("Demain"))
    }

    private func mentionsMeeting(_ text: String) -> Bool {
        let value = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR")).lowercased()
        return value.contains("reunion") || value.contains("mercredi") || value.contains("quinze") || value.contains("15")
    }

    private func makeSpeechWAV(_ text: String) throws -> URL {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-live-" + UUID().uuidString + ".wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Thomas", "-o", wav.path, "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        if say.terminationStatus != 0 || !FileManager.default.fileExists(atPath: wav.path) {
            let aiff = wav.deletingPathExtension().appendingPathExtension("aiff")
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            fallback.arguments = ["-o", aiff.path, text]
            try fallback.run()
            fallback.waitUntilExit()
            let convert = Process()
            convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            convert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", aiff.path, wav.path]
            try convert.run()
            convert.waitUntilExit()
            XCTAssertEqual(convert.terminationStatus, 0)
        }
        return wav
    }

    private func wavDuration(_ url: URL) -> Double {
        let count = (try? Data(contentsOf: url).count) ?? 0
        return Double(max(0, count - 44)) / 2 / 16_000
    }

    private func pcm16(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { return Data() }
        return data.subdata(in: 44..<data.count)
    }

    private final class PartialLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return values.count
        }
        func add(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
    }
}
