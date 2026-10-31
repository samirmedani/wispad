import Foundation
import os
import XCTest
@testable import WispadCore

/// Banc du texte, obligatoire avant une release qui touche au texte (docs/BANC-TEXTE.md). Ne tourne que lancé par
/// scripts/text-bench.sh (WISPAD_LIVE_TESTS=1, WISPAD_TEXT_BENCH=1), avec les clés de test WISPAD_TEST_*.
/// Les dictées viennent d'un dossier privé hors du dépôt (WISPAD_TEXT_BENCH_DIR), où vont aussi les résultats ; la
/// sortie ne montre que des comptes et des coûts, jamais un texte dicté.
///
/// Le script copie ce fichier, avec SpendLedger.swift, dans un arbre temporaire de la release de base : la même mesure
/// s'applique aux deux versions. Il ne doit donc appeler que du code présent dans l'une et l'autre.
final class TextBenchLiveTests: XCTestCase {
    // MARK: - Fichiers privés

    /// Étape correction : dictées de l'historique, leur texte brut et leur contexte (text-bench.py corpus).
    struct CorrectionCorpus: Codable, Sendable {
        var dictionary: [String]
        var cases: [CorrectionCase]
    }

    struct CorrectionCase: Codable, Sendable {
        var id: String
        var group: String
        var transcript: String
        var app: String?
        var previous: [String]
    }

    /// Étape flux, avant l'enregistrement : audios de l'historique (text-bench.py corpus --flux).
    struct StreamEntry: Codable, Sendable {
        var dictionary: [String]
        var cases: [StreamEntryCase]
    }

    struct StreamEntryCase: Codable, Sendable {
        var id: String
        var audio: String
        var seconds: Double
        var app: String?
        var previous: [String]
    }

    /// Étape flux enregistrée une fois (--record) : tout ce que xAI a renvoyé, rejoué ensuite sans réseau.
    struct StreamRecording: Codable, Sendable {
        var recordedAt: String
        /// Empreinte des paramètres du flux et du fichier dans le code enregistré (text-bench.py empreinte).
        var fingerprint: String
        var endpoint: String
        var liveModel: String
        var fileModel: String
        var cases: [RecordedCase]
    }

    struct RecordedEvent: Codable, Sendable {
        /// Secondes depuis l'ouverture du socket.
        var t: Double
        var json: String
    }

    struct RecordedCase: Codable, Sendable {
        var id: String
        var seconds: Double
        var app: String?
        var previous: [String]
        var audioBytes: Int
        /// Instant d'envoi de chaque paquet d'audio (3 200 octets, 100 ms).
        var sends: [Double]
        var finalizeAt: Double?
        var events: [RecordedEvent]
        /// Réponse brute de la transcription du fichier : chaque version la relit avec son propre code.
        var fileStatus: Int?
        var fileBody: String?
        var error: String?
    }

    struct Correction: Codable, Sendable {
        /// Texte final, tel que l'app le colle (après sa dernière normalisation).
        var text: String
        var corrected: Bool
        var attempts: Int
        var latencyMs: Int?
        var inputTokens: Int
        var cachedTokens: Int
        var outputTokens: Int
        var costUSD: Double
    }

    struct CorrectionOutcome: Codable, Sendable {
        var id: String
        var group: String
        var input: String
        var correction: Correction
    }

    struct StreamOutcome: Codable, Sendable {
        var id: String
        /// Texte du flux de cette version, et s'il a fini sur un segment final.
        var stream: String
        var streamFinalized: Bool
        var streamFailed: Bool
        var file: String?
        /// Texte retenu comme l'app : « flux », « fichier », ou « vide » (aucune parole).
        var source: String
        var input: String
        var correction: Correction?
    }

    struct PassReport: Codable, Sendable {
        var run: String
        var reservedUSD: Double
        var costUSD: Double
        var correction: [CorrectionOutcome]
        var stream: [StreamOutcome]
    }

    struct BenchError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Un passage (base ou head)

    /// Étape correction sur le corpus, puis étape flux : les événements enregistrés repassent dans le flux de cette
    /// version, la réponse du fichier dans sa transcription, le texte est retenu comme dans l'app, puis corrigé.
    /// Seule la correction appelle le réseau (DeepSeek, clé de test).
    func testBenchPass() async throws {
        let setup = try benchSetup(mode: "pass", key: "WISPAD_LIVE_DEEPSEEK_KEY")
        let env = ProcessInfo.processInfo.environment
        let run = env["WISPAD_TEXT_BENCH_RUN"] ?? "passage"
        guard let out = env["WISPAD_TEXT_BENCH_OUT"], !out.isEmpty else { throw BenchError("WISPAD_TEXT_BENCH_OUT absent.") }
        let decoder = JSONDecoder()
        let corpus = try decoder.decode(CorrectionCorpus.self, from: Data(contentsOf: setup.directory.appendingPathComponent("correction.json")))
        let recording = try decoder.decode(StreamRecording.self, from: Data(contentsOf: setup.directory.appendingPathComponent("flux.json")))

        var streams: [StreamOutcome] = []
        var streamRequests: [CorrectionRequest?] = []
        for item in recording.cases where item.error == nil {
            let (outcome, request) = await Self.retain(item, recording: recording, dictionary: corpus.dictionary)
            streams.append(outcome)
            streamRequests.append(request)
        }
        let requests = corpus.cases.map {
            Self.correctionRequest($0.transcript, app: $0.app, previous: $0.previous, dictionary: corpus.dictionary)
        }
        let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: "", language: .french,
                                   keyterms: [], prompt: "", cleanupKey: setup.key)
        // Estimation prudente : un appel par dictée au pire coût. Les seconds essais tiennent dans la marge, sinon le
        // passage s'arrête au lieu de dépasser ; le cumul ne garde ensuite que le coût mesuré.
        let reserved = (requests + streamRequests.compactMap { $0 }).map(Self.worstCallUSD).reduce(0, +)
        let ledger = SpendLedger.wispadDefault()
        try ledger.reserve(reserved)
        var budget = Budget(limit: reserved)
        var report = PassReport(run: run, reservedUSD: reserved, costUSD: 0, correction: [], stream: [])
        do {
            // Une dictée à la fois, comme dans l'app : le délai mesuré est celui d'une correction seule.
            for (item, request) in zip(corpus.cases, requests) {
                let correction = try await Self.correct(request, speech: speech, budget: &budget)
                report.correction.append(CorrectionOutcome(id: item.id, group: item.group, input: request.transcript, correction: correction))
            }
            for (index, request) in streamRequests.enumerated() {
                guard let request else { continue }
                streams[index].correction = try await Self.correct(request, speech: speech, budget: &budget)
            }
        } catch {
            try? ledger.settle(reserved: reserved, actual: budget.spent)
            throw error
        }
        try ledger.settle(reserved: reserved, actual: budget.spent)
        report.stream = streams
        report.costUSD = budget.spent
        try Self.writePrivate(report, to: URL(fileURLWithPath: out))
        let corrected = report.correction.filter(\.correction.corrected).count
        let streamCorrected = streams.filter { $0.correction?.corrected == true }.count
        let fromStream = streams.filter { $0.source == "flux" }.count
        print("BANC-TEXTE \(run) : correction \(corrected)/\(report.correction.count) corrigées ; flux \(streamCorrected)/\(streams.count) corrigées, \(fromStream) gardées du flux ; coût \(String(format: "%.4f", budget.spent)) $ (réservé \(String(format: "%.3f", reserved)) $)")
    }

    struct Budget {
        var limit: Double
        var spent = 0.0
    }

    /// La requête de l'app avec ses réglages par défaut (AppSettings) : français, listes, heures compactes, ton naturel.
    /// Ni texte voisin ni fenêtre : l'historique ne les garde pas.
    static func correctionRequest(_ transcript: String, app: String?, previous: [String], dictionary: [String],
                                  alternative: String? = nil) -> CorrectionRequest {
        var request = CorrectionRequest(transcript: transcript, dictionary: dictionary, appName: app,
                                        previousDictations: previous, alternativeTranscript: alternative)
        request.dateFormat = DictationDateFormat(timeStyle: .compact)
        return request
    }

    /// Pire coût d'un appel de correction : toute l'entrée hors cache, à un jeton pour 2,5 caractères, et la sortie
    /// maximale de TextCleaner, au tarif plein de DeepSeek (Pricing : 0,30 $ et 1,20 $ par million de jetons).
    static func worstCallUSD(_ request: CorrectionRequest) -> Double {
        let characters = CorrectionPrompt.system(for: request).count + CorrectionPrompt.userText(request).count
        let output = min(4_096, max(400, request.transcript.count / 2))
        return (Double(characters) / 2.5 * 0.30 + Double(output) * 1.20) / 1_000_000
    }

    /// La correction de l'app (TextCleaner, DeepSeek seul), un second essai si elle échoue, puis sa dernière
    /// normalisation. Un appel au coût inconnu compte au pire coût.
    static func correct(_ request: CorrectionRequest, speech: SpeechRequest, budget: inout Budget) async throws -> Correction {
        let worst = worstCallUSD(request)
        var result = Correction(text: request.transcript, corrected: false, attempts: 0, latencyMs: nil,
                                inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 0)
        var text = request.transcript
        for _ in 0..<2 {
            guard budget.spent + worst <= budget.limit + 0.000_001 else {
                throw BenchError("réservation épuisée : passage arrêté avant de la dépasser.")
            }
            let outcome = await TextCleaner.clean(transcript: request.transcript, request: request, speech: speech, enabled: true)
            let calls = outcome.failedUsages + [outcome.usage].compactMap { $0 }
            let cost = calls.reduce(0) { $0 + ($1.costUSD ?? worst) }
            budget.spent += cost
            result.costUSD += cost
            result.attempts += 1
            text = outcome.text
            if let usage = outcome.usage, usage.succeeded {
                result.corrected = true
                result.latencyMs = usage.latencyMs
                result.inputTokens = usage.tokens.input
                result.cachedTokens = usage.tokens.cachedInput
                result.outputTokens = usage.tokens.output
                break
            }
        }
        result.text = FranglaisNormalizer.normalize(text)
        return result
    }

    /// Le texte que l'app retient en fin de dictée, fichier arrivé à temps (DictationCoordinator.verifyAgainstFile) :
    /// le flux s'il dit la même chose que le fichier, sinon le fichier, avec le flux en seconde écoute pour la
    /// correction. Flux en échec ou vide : le fichier.
    static func retain(_ item: RecordedCase, recording: StreamRecording, dictionary: [String]) async -> (StreamOutcome, CorrectionRequest?) {
        let finish = await replayStream(item, liveModel: recording.liveModel)
        let file = await replayFile(item, fileModel: recording.fileModel)
        let stream = finish.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var raw = stream
        var source = "flux"
        var alternative: String?
        if finish.failed || stream.isEmpty {
            raw = file ?? ""
            source = "fichier"
        } else if let file, !TranscriptEquivalence.normalize(file).isEmpty, !TranscriptEquivalence.equivalent(stream, file) {
            raw = file
            alternative = stream
            source = "fichier"
        }
        let input = FranglaisNormalizer.normalize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let outcome = StreamOutcome(id: item.id, stream: stream, streamFinalized: finish.finalized, streamFailed: finish.failed,
                                    file: file, source: input.isEmpty ? "vide" : source, input: input, correction: nil)
        guard !input.isEmpty else { return (outcome, nil) }
        let request = correctionRequest(input, app: item.app, previous: item.previous, dictionary: dictionary,
                                        alternative: alternative.map { FranglaisNormalizer.normalize($0) })
        return (outcome, request)
    }

    /// Le flux de cette version, sans socket : des paquets d'audio de la taille de l'enregistrement (des zéros) et les
    /// événements reçus repassent dans LiveSpeechSession dans leur ordre d'origine ; finish() envoie finalize au même
    /// endroit, et la fin suit la règle de l'app (segment final qui couvre l'audio, ou transcript.done).
    static func replayStream(_ item: RecordedCase, liveModel: String) async -> (text: String, finalized: Bool, failed: Bool) {
        let speech = SpeechRequest(provider: .xai, liveModel: liveModel, fileModel: liveModel, apiKey: "", language: .french,
                                   keyterms: [], prompt: "")
        let session = LiveSpeechSession(request: speech)
        let finalizeQueued = OSAllocatedUnfairLock(initialState: false)
        session.onOutbound = { message in
            if case .string(let text) = message, text.contains("\"finalize\"") { finalizeQueued.withLock { $0 = true } }
        }
        defer { session.cancel() }
        let cut = item.finalizeAt ?? .infinity
        var remaining = item.audioBytes
        var sent = 0
        for event in item.events where event.t < cut {
            while sent < item.sends.count, item.sends[sent] < event.t {
                session.send(Data(count: min(3_200, remaining)))
                remaining -= min(3_200, remaining)
                sent += 1
            }
            session.handle(.string(event.json))
        }
        while sent < item.sends.count {
            session.send(Data(count: min(3_200, remaining)))
            remaining -= min(3_200, remaining)
            sent += 1
        }
        let finish = Task { try await session.finish() }
        for _ in 0..<1_000 where !finalizeQueued.withLock({ $0 }) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        for event in item.events where event.t >= cut {
            session.handle(.string(event.json))
        }
        do {
            let result = try await finish.value
            return (result.text, result.endingFinalized, false)
        } catch {
            return ("", false, true)
        }
    }

    /// La transcription du fichier de cette version, sur la réponse enregistrée : aucune requête ne part.
    static func replayFile(_ item: RecordedCase, fileModel: String) async -> String? {
        guard let status = item.fileStatus, let body = item.fileBody else { return nil }
        let data = Data(body.utf8)
        let speech = SpeechRequest(provider: .xai, liveModel: fileModel, fileModel: fileModel, apiKey: "", language: .french,
                                   keyterms: [], prompt: "")
        let transport: TextCleaner.HTTPTransport = { request in
            let url = request.url ?? URL(string: "https://api.x.ai/v1/stt")!
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return try? await BatchTranscriber.transcribe(fileURL: URL(fileURLWithPath: "/dev/null"), request: speech,
                                                      transport: transport, readFile: { _ in Data() })
    }

    // MARK: - Enregistrement de l'étape flux (--record)

    /// Rejoue chaque audio en temps réel dans le flux xAI, avec l'adresse que l'app construit, et garde tout ce qui
    /// revient ; puis la réponse brute du fichier. Une fois seulement : le banc relit ensuite ces réponses sans réseau.
    func testRecordStream() async throws {
        let setup = try benchSetup(mode: "record", key: "WISPAD_LIVE_XAI_KEY")
        let fingerprint = ProcessInfo.processInfo.environment["WISPAD_TEXT_BENCH_FINGERPRINT"] ?? ""
        guard !fingerprint.isEmpty else { throw BenchError("WISPAD_TEXT_BENCH_FINGERPRINT absente.") }
        let entry = try JSONDecoder().decode(StreamEntry.self, from: Data(contentsOf: setup.directory.appendingPathComponent("flux-entree.json")))
        let liveModel = ProviderID.xai.defaultLiveModel
        let fileModel = ProviderCatalog.model(id: liveModel, provider: .xai)?.fileModel ?? liveModel
        let speech = SpeechRequest(provider: .xai, liveModel: liveModel, fileModel: fileModel, apiKey: setup.key, language: .french,
                                   keyterms: RecognitionHints.keyterms(dictionary: entry.dictionary, context: []),
                                   prompt: CorrectionPrompt.recognitionPrompt(appName: nil, nearby: nil))
        let endpoint = try await Self.appEndpoint(speech)
        let tailWait = LiveSpeechSession(request: speech).tailFinalWaitSeconds
        let seconds = entry.cases.map(\.seconds).reduce(0, +)
        let reserved = Self.audioCostUSD(stream: seconds, file: seconds, model: liveModel) * 1.25 + 0.002
        let ledger = SpendLedger.wispadDefault()
        try ledger.reserve(reserved)
        var cases: [RecordedCase] = []
        for batch in stride(from: 0, to: entry.cases.count, by: 6).map({ Array(entry.cases[$0..<min($0 + 6, entry.cases.count)]) }) {
            cases += await withTaskGroup(of: RecordedCase.self) { group in
                for item in batch {
                    group.addTask { await Self.record(item, endpoint: endpoint, speech: speech, tailWait: tailWait) }
                }
                return await group.reduce(into: [RecordedCase]()) { $0.append($1) }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: entry.cases.enumerated().map { ($1.id, $0) })
        cases.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
        // Coût mesuré comme dans l'app : l'audio parti dans le flux, et chaque fichier envoyé.
        let streamed = cases.reduce(0.0) { $0 + Double(min($1.sends.count * 3_200, $1.audioBytes)) / 32_000 }
        let filed = cases.filter { $0.fileStatus != nil }.reduce(0.0) { $0 + $1.seconds }
        let actual = Self.audioCostUSD(stream: streamed, file: filed, model: liveModel)
        try ledger.settle(reserved: reserved, actual: actual)
        let recording = StreamRecording(recordedAt: ISO8601DateFormatter().string(from: Date()), fingerprint: fingerprint,
                                        endpoint: endpoint.absoluteString, liveModel: liveModel, fileModel: fileModel, cases: cases)
        try Self.writePrivate(recording, to: setup.directory.appendingPathComponent("flux.json"))
        let failed = cases.filter { $0.error != nil || $0.fileStatus != 200 }.count
        print("BANC-TEXTE enregistrement : \(cases.count) audios, \(failed) en échec, \(Int(streamed.rounded())) s de flux ; coût \(String(format: "%.4f", actual)) $")
    }

    static func audioCostUSD(stream: Double, file: Double, model: String) -> Double {
        (Pricing.audioCost(provider: .xai, model: model, streaming: true, seconds: stream) ?? stream * 0.20 / 3_600)
            + (Pricing.audioCost(provider: .xai, model: model, streaming: false, seconds: file) ?? file * 0.10 / 3_600)
    }

    /// Adresse du flux telle que l'app la construit (paramètres, langue, mots-clés), lue sur une LiveSpeechSession
    /// ouverte sans clé puis refermée aussitôt : aucun audio, aucun coût.
    static func appEndpoint(_ speech: SpeechRequest) async throws -> URL {
        var keyless = speech
        keyless.apiKey = ""
        let session = LiveSpeechSession(request: keyless)
        let opening = Task { try? await session.start() }
        defer {
            session.cancel()
            opening.cancel()
        }
        for _ in 0..<400 {
            if let socket = Mirror(reflecting: session).descendant("task") as? URLSessionWebSocketTask,
               let url = socket.originalRequest?.url {
                return url
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw BenchError("adresse du flux introuvable dans LiveSpeechSession.")
    }

    /// Ce qu'un enregistrement fait remonter du socket. Suit aussi, comme l'app (TranscriptAssembler.endingFinalized),
    /// si la fin entendue est verrouillée par un segment final.
    final class RecordLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [RecordedEvent] = []
        private var sawCreated = false
        private var finished = false
        private var tailFinal = false
        private var live = ""

        func add(_ json: String, at t: Double) {
            lock.withLock {
                recorded.append(RecordedEvent(t: t, json: json))
                guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
                switch object["type"] as? String {
                case "transcript.created":
                    sawCreated = true
                case "transcript.done", "error":
                    finished = true
                case "transcript.partial":
                    let text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if object["is_final"] as? Bool == true || object["speech_final"] as? Bool == true {
                        tailFinal = true
                        live = ""
                    } else {
                        live = text
                        if !text.isEmpty { tailFinal = false }
                    }
                default:
                    break
                }
            }
        }

        func noteAudio() { lock.withLock { tailFinal = false } }
        func close() { lock.withLock { finished = true } }
        var created: Bool { lock.withLock { sawCreated } }
        var done: Bool { lock.withLock { finished } }
        var endingFinalized: Bool { lock.withLock { tailFinal && live.isEmpty } }
        var events: [RecordedEvent] { lock.withLock { recorded } }
    }

    final class ResponseCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int?
        private var body: String?

        func keep(_ data: Data, status code: Int) {
            lock.withLock {
                status = code
                body = String(data: data, encoding: .utf8)
            }
        }

        var value: (Int?, String?) { lock.withLock { (status, body) } }
    }

    /// Même protocole que l'app : audio en temps réel, finalize, audio.done après le segment final de la fin (ou après
    /// tailFinalWaitSeconds), puis attente de transcript.done.
    static func record(_ item: StreamEntryCase, endpoint: URL, speech: SpeechRequest, tailWait: Double) async -> RecordedCase {
        var result = RecordedCase(id: item.id, seconds: item.seconds, app: item.app, previous: item.previous, audioBytes: 0,
                                  sends: [], finalizeAt: nil, events: [], fileStatus: nil, fileBody: nil, error: nil)
        let audio = URL(fileURLWithPath: item.audio)
        let log = RecordLog()
        do {
            let pcm = try FranglaisBenchmarkTests.pcm(fromWAV: Data(contentsOf: audio))
            result.audioBytes = pcm.count
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(speech.apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            let session = URLSession(configuration: .ephemeral)
            let socket = session.webSocketTask(with: request)
            defer {
                socket.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
            }
            let began = Date()
            socket.resume()
            let reader = Task {
                while !Task.isCancelled {
                    guard let message = try? await socket.receive() else { break }
                    switch message {
                    case .string(let json): log.add(json, at: Date().timeIntervalSince(began))
                    case .data(let data): log.add(String(decoding: data, as: UTF8.self), at: Date().timeIntervalSince(began))
                    @unknown default: break
                    }
                    if log.done { break }
                }
                log.close()
            }
            defer { reader.cancel() }
            for _ in 0..<100 where !log.created && !log.done { try await Task.sleep(nanoseconds: 30_000_000) }
            guard log.created else { throw BenchError("flux non ouvert") }
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + 3_200, pcm.count)
                log.noteAudio()
                result.sends.append(Date().timeIntervalSince(began))
                try await socket.send(.data(pcm.subdata(in: offset..<end)))
                offset = end
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            result.finalizeAt = Date().timeIntervalSince(began)
            try await socket.send(.string(#"{"type":"finalize"}"#))
            let deadline = Date().addingTimeInterval(tailWait)
            while Date() < deadline, !log.endingFinalized, !log.done { try await Task.sleep(nanoseconds: 10_000_000) }
            if !log.done { try await socket.send(.string(#"{"type":"audio.done"}"#)) }
            for _ in 0..<240 where !log.done { try await Task.sleep(nanoseconds: 50_000_000) }
            result.events = log.events
        } catch {
            result.events = log.events
            result.error = (error as? BenchError)?.description ?? "échec du flux (\((error as? URLError)?.code.rawValue ?? 0))"
        }
        let capture = ResponseCapture()
        let transport: TextCleaner.HTTPTransport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            capture.keep(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            return (data, response)
        }
        _ = try? await BatchTranscriber.transcribe(fileURL: audio, request: speech, transport: transport)
        (result.fileStatus, result.fileBody) = capture.value
        return result
    }

    // MARK: - Outils

    struct BenchSetup {
        var directory: URL
        var key: String
    }

    /// Hors du banc (swift test ordinaire, autres sondes) : ignoré. Dans le banc, une clé ou un dossier manquant arrête
    /// le passage au lieu de l'ignorer : le script ne lit jamais un passage vide.
    private func benchSetup(mode: String, key name: String) throws -> BenchSetup {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1" && env["WISPAD_TEXT_BENCH"] == "1" && env["WISPAD_TEXT_BENCH_MODE"] == mode,
                          "Banc du texte réservé à scripts/text-bench.sh.")
        guard let key = env[name], !key.isEmpty else { throw BenchError("\(name) absente : clé de test requise.") }
        guard let path = env["WISPAD_TEXT_BENCH_DIR"], !path.isEmpty else { throw BenchError("WISPAD_TEXT_BENCH_DIR absent.") }
        return BenchSetup(directory: URL(fileURLWithPath: path, isDirectory: true), key: key)
    }

    /// Fichier lisible par son seul propriétaire (0600), comme tout le dossier du banc.
    static func writePrivate<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
