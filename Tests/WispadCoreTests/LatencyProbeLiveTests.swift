import Foundation
import os
import XCTest
@testable import WispadCore

/// Sonde de délais, clés de test seulement : WISPAD_LATENCY_PROBE=1 scripts/live-test.sh LatencyProbeLiveTests.
/// Phrases synthétiques (voix « Thomas ») rejouées en temps réel dans le flux xAI, puis en fichier, puis corrigées par
/// Grok avec une invite de taille réelle. N'affiche que des durées et des comptes de mots. Coût : moins d'un centime.
final class LatencyProbeLiveTests: XCTestCase {
    private static let phrases = [
        "D'accord, parfait.",
        "Je pense qu'on peut décaler la réunion à demain matin si tu veux bien.",
        "Alors pour le projet, il faudrait d'abord finir la maquette de la page d'accueil, ensuite valider les textes avec le client, et enfin préparer la mise en ligne pour la fin de la semaine prochaine, sans oublier les tests sur mobile."
    ]

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    private func key() throws -> String {
        let env = ProcessInfo.processInfo.environment
        let key = env["WISPAD_LIVE_XAI_KEY"] ?? ""
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1" && env["WISPAD_LATENCY_PROBE"] == "1" && !key.isEmpty,
                          "Sonde réseau réservée à scripts/live-test.sh.")
        return key
    }

    private static func speechRequest(_ key: String) -> SpeechRequest {
        SpeechRequest(provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0",
                      apiKey: key, language: .french, keyterms: [], prompt: "")
    }

    /// Arrêt sans silence de fin, comme une dictée réelle : arrêt → texte final du flux, puis fichier complet.
    func testStreamAndFileTimings() async throws {
        let key = try key()
        try SpendLedger.wispadDefault().reserve(0.03)
        let speech = Self.speechRequest(key)
        for phrase in Self.phrases {
            let wav = try makeSpeechWAV(phrase)
            defer { try? FileManager.default.removeItem(at: wav) }
            let pcm = try FranglaisBenchmarkTests.pcm(fromWAV: Data(contentsOf: wav))
            for run in 1...3 {
                let session = LiveSpeechSession(request: speech)
                try await session.start()
                var offset = 0
                while offset < pcm.count {
                    let end = min(offset + 3_200, pcm.count)
                    session.send(pcm.subdata(in: offset..<end))
                    offset = end
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let stop = Self.now()
                let finish = try await session.finish()
                let streamMs = Int((Self.now() - stop).rounded())
                session.cancel()
                let fileStart = Self.now()
                let file = try await BatchTranscriber.transcribe(fileURL: wav, request: speech)
                let fileMs = Int((Self.now() - fileStart).rounded())
                print("SONDE \(WordCount.count(finish.text)) mots, \(String(format: "%.1f", Double(pcm.count) / 32_000)) s, essai \(run) : arrêt → texte final \(streamMs) ms (finalisé \(finish.endingFinalized)) ; fichier \(fileMs) ms ; écart flux/fichier \(TranscriptEquivalence.differingWords(finish.text, file)) mots")
            }
        }
    }

    /// Protocole xAI vu du socket : après « finalize », instant du segment final (et sa fin, comparée à l'audio
    /// envoyé), puis délai de « transcript.done » après « audio.done ». Vérifie que le segment final suffit.
    func testFinalizeProtocol() async throws {
        let key = try key()
        try SpendLedger.wispadDefault().reserve(0.02)
        for phrase in Self.phrases {
            let wav = try makeSpeechWAV(phrase)
            defer { try? FileManager.default.removeItem(at: wav) }
            let pcm = try FranglaisBenchmarkTests.pcm(fromWAV: Data(contentsOf: wav))
            for run in 1...3 {
                var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
                components.queryItems = [
                    URLQueryItem(name: "model", value: "grok-voice-transcribe-2.0"),
                    URLQueryItem(name: "sample_rate", value: "16000"),
                    URLQueryItem(name: "encoding", value: "pcm"),
                    URLQueryItem(name: "interim_results", value: "true"),
                    URLQueryItem(name: "endpointing", value: "5000"),
                    URLQueryItem(name: "vad_threshold", value: "0.05"),
                    URLQueryItem(name: "language", value: "fr")
                ]
                var request = URLRequest(url: components.url!)
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let session = URLSession(configuration: .ephemeral)
                let socket = session.webSocketTask(with: request)
                let log = EventLog()
                socket.resume()
                let reader = SocketReader(socket: socket, log: log)
                let receiver = Task { await reader.run() }
                for _ in 0..<300 where !log.created { try await Task.sleep(nanoseconds: 10_000_000) }
                var offset = 0
                while offset < pcm.count {
                    let end = min(offset + 3_200, pcm.count)
                    try await socket.send(.data(pcm.subdata(in: offset..<end)))
                    offset = end
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let stop = Self.now()
                try await socket.send(.string(#"{"type":"finalize"}"#))
                var final: Event?
                for _ in 0..<150 {
                    final = log.events.last { $0.at >= stop && $0.speechFinal }
                    if final != nil { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let doneSent = Self.now()
                try await socket.send(.string(#"{"type":"audio.done"}"#))
                var done: Event?
                for _ in 0..<300 {
                    done = log.events.first { $0.type == "transcript.done" }
                    if done != nil { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                receiver.cancel()
                socket.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                let finalMs = final.map { String(Int(($0.at - stop).rounded())) } ?? "—"
                let doneMs = done.map { String(Int(($0.at - doneSent).rounded())) } ?? "—"
                let end = final?.end.map { String(format: "%.2f", $0) } ?? "—"
                // Texte assemblé au segment final, puis avec transcript.done : la règle de Wispad (`bestText`) tranche.
                let atFinal = final.map { log.committed(until: $0.at) } ?? ""
                let withDone = log.committed(until: done?.at ?? stop, includingDone: true)
                print("SONDE protocole \(String(format: "%.2f", Double(pcm.count) / 32_000)) s envoyées, essai \(run) : segment final \(finalMs) ms après finalize (fin \(end) s) ; transcript.done \(doneMs) ms après audio.done (\(WordCount.count(done?.text ?? "")) mots) ; texte retenu identique \(atFinal == withDone)")
            }
        }
    }

    /// Correction par Grok, invite de taille réelle (dictionnaire, fenêtre, dictées récentes).
    func testGrokCorrectionTimings() async throws {
        let key = try key()
        try SpendLedger.wispadDefault().reserve(0.05)
        let window = String(repeating: "On a parlé du lancement de la nouvelle version, des retours des testeurs sur la vitesse de la dictée et du coût mensuel des fournisseurs. ", count: 11)
        let transcripts = ["d'accord parfait", "je pense qu'on peut décaler la réunion à demain matin si tu veux bien"]
        let models: [(String, Bool)] = [("grok-4.7", true), ("grok-4.20-0309-non-reasoning", false)]
        for (model, reasoning) in models {
            let route = TextCleaner.Route(api: .xaiCleanup, model: model, url: URL(string: "https://api.x.ai/v1/chat/completions")!,
                                          key: key, provider: "xAI", isFallback: false)
            for transcript in transcripts {
                var latencies: [Int] = []
                for _ in 0..<4 {
                    let request = CorrectionRequest(
                        transcript: transcript,
                        dictionary: ["Wispad", "DeepSeek", "Claude Code", "Codex", "Forgejo", "Vercel", "GitHub", "OpenAI", "xAI", "Supabase", "TypeSafe", "Grok"],
                        appName: "Codex",
                        nearbyText: "Tu peux regarder la vitesse de la dictée ?",
                        previousDictations: ["Il faudrait vérifier la vitesse de collage.", "On teste la nouvelle version ce soir."],
                        windowText: window,
                        language: .french
                    )
                    let started = Self.now()
                    do {
                        _ = try await TextCleaner.send(system: CorrectionPrompt.system(for: request), user: CorrectionPrompt.userText(request),
                                                       route: route, maxTokens: 400, includeReasoning: reasoning)
                        latencies.append(Int((Self.now() - started).rounded()))
                    } catch {
                        print("SONDE correction \(model) : erreur \(APIFailureCause.classify(error))")
                        break
                    }
                }
                print("SONDE correction \(model), \(WordCount.count(transcript)) mots : \(latencies) ms")
            }
        }
    }

    private struct Event: Sendable {
        var at: Double
        var type: String
        var isFinal: Bool
        var speechFinal: Bool
        var end: Double?
        var text: String
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Event] = []

        var events: [Event] { lock.withLock { stored } }
        var created: Bool { lock.withLock { stored.contains { $0.type == "transcript.created" } } }

        func add(_ object: [String: Any], at time: Double) {
            let start = (object["start"] as? NSNumber)?.doubleValue
            let duration = (object["duration"] as? NSNumber)?.doubleValue
            let event = Event(at: time, type: object["type"] as? String ?? "?", isFinal: object["is_final"] as? Bool ?? false,
                              speechFinal: object["speech_final"] as? Bool ?? false,
                              end: start.flatMap { start in duration.map { start + $0 } }, text: object["text"] as? String ?? "")
            lock.withLock { stored.append(event) }
        }

        /// Texte que Wispad aurait retenu à cet instant (segments finaux, et `transcript.done` si demandé).
        func committed(until time: Double, includingDone: Bool = false) -> String {
            var assembler = TranscriptAssembler()
            for event in events where event.at <= time {
                if event.type == "transcript.partial" {
                    assembler.apply(.partial(text: event.text, isFinal: event.isFinal, speechFinal: event.speechFinal, endSeconds: event.end))
                } else if includingDone, event.type == "transcript.done" {
                    assembler.apply(.done(text: event.text))
                }
            }
            return assembler.bestText
        }
    }

    /// Lit le socket dans son propre objet : la tâche de lecture ne capture qu'une référence.
    private final class SocketReader: @unchecked Sendable {
        private let socket: URLSessionWebSocketTask
        private let log: EventLog

        init(socket: URLSessionWebSocketTask, log: EventLog) {
            self.socket = socket
            self.log = log
        }

        func run() async {
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { return }
                let text: String?
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                guard let text, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                log.add(object, at: LatencyProbeLiveTests.now())
            }
        }
    }

    private func makeSpeechWAV(_ text: String) throws -> URL {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-sonde-" + UUID().uuidString + ".wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Thomas", "-o", wav.path, "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0, FileManager.default.fileExists(atPath: wav.path) else {
            throw NSError(domain: "sonde", code: 1, userInfo: [NSLocalizedDescriptionKey: "say a échoué"])
        }
        return wav
    }
}
