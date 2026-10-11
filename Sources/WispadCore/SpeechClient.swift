import Foundation

public enum SpeechError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

public struct SpeechRequest: Sendable {
    public var provider: ProviderID
    public var liveModel: String
    public var fileModel: String
    public var apiKey: String
    public var language: DictationLanguage
    public var keyterms: [String]
    public var prompt: String
    /// Clé DeepSeek : si présente, la correction passe par DeepSeek au lieu du fournisseur vocal.
    public var cleanupKey: String?
    /// Clé OpenAI : relais de la correction (gpt-5.4-mini) quand DeepSeek ne répond pas.
    public var fallbackKey: String?
    /// DeepSeek vient d'échouer plusieurs fois : la correction passe d'abord par le relais.
    public var cleanupPrimaryDown: Bool
    /// Clé TypeSafe : Jev donne le premier avis sur les mots à apprendre.
    public var judgeKey: String?

    public init(
        provider: ProviderID,
        liveModel: String,
        fileModel: String,
        apiKey: String,
        language: DictationLanguage,
        keyterms: [String],
        prompt: String,
        cleanupKey: String? = nil,
        fallbackKey: String? = nil,
        cleanupPrimaryDown: Bool = false,
        judgeKey: String? = nil
    ) {
        self.provider = provider
        self.liveModel = liveModel
        self.fileModel = fileModel
        self.apiKey = apiKey
        self.language = language
        self.keyterms = keyterms
        self.prompt = prompt
        self.cleanupKey = cleanupKey
        self.fallbackKey = fallbackKey
        self.cleanupPrimaryDown = cleanupPrimaryDown
        self.judgeKey = judgeKey
    }
}

/// Résultat du flux. `endingFinalized` est faux si la dernière portion n'a été qu'un intermédiaire.
public struct StreamFinish: Equatable, Sendable {
    public var text: String
    public var endingFinalized: Bool
    /// Fin couverte par les segments finaux (start + duration), si le serveur l'a donnée.
    public var coveredSeconds: Double?

    public init(text: String, endingFinalized: Bool, coveredSeconds: Double? = nil) {
        self.text = text
        self.endingFinalized = endingFinalized
        self.coveredSeconds = coveredSeconds
    }
}

/// Pourquoi la dictée est passée par le fichier alors que le flux avait déjà un texte.
public enum StreamEndFallback: String, Codable, Equatable, Sendable {
    /// `transcript.done` sans segment final pour la dernière portion.
    case unfinalized
    /// Les segments finaux couvrent nettement moins que l'audio.
    case shortCoverage
}

public enum StreamEndReliability {
    /// Écart minimum, et part de l'audio laissée dehors. Un silence de fin court ne rappelle pas le fichier.
    public static let shortCoverageGap = 2.5
    public static let shortCoverageFraction = 0.4

    public static func fallback(_ finish: StreamFinish, audioSeconds: Double) -> StreamEndFallback? {
        if !finish.endingFinalized { return .unfinalized }
        guard let covered = finish.coveredSeconds, covered.isFinite, audioSeconds.isFinite, covered > 0, audioSeconds > 0 else {
            return nil
        }
        let gap = audioSeconds - covered
        if gap >= shortCoverageGap, gap / audioSeconds >= shortCoverageFraction { return .shortCoverage }
        return nil
    }
}

public final class LiveSpeechSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let request: SpeechRequest
    private let lock = NSLock()
    private let outbound = DispatchQueue(label: "com.yatofix.wispad.speech-send")
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var closed = false
    private var configured = false
    private var sentAudio = false
    private var acceptingAudio = true
    private var finalizeQueued = false
    private var audioDoneQueued = false
    private var finishStarted = false
    private var didFinish = false
    private var pending = Data()
    private var assembler = TranscriptAssembler()
    private let readyResult = AsyncResult<Void>()
    private let finishResult = AsyncResult<StreamFinish>()

    public var onPartial: (@Sendable (String) -> Void)?
    /// Appelé quand un segment final clôt tout ce qui a été entendu (pause dans la parole), avec ce texte.
    public var onSettled: (@Sendable (String) -> Void)?
    /// Borne avant `audio.done`. xAI clôt le socket dès ce message : l'envoyer avec `finalize` laisse la fin en intermédiaire.
    var tailFinalWaitSeconds = 0.8
    /// Tests : appelé après le gel de l'audio, avant l'envoi de `finalize`, pour glisser le dernier paquet.
    var beforeFinalizeDrain: (@Sendable () -> Void)?
    /// Tests : messages réellement enfilés, dans l'ordre. Aucun socket n'est ouvert.
    var onOutbound: (@Sendable (URLSessionWebSocketTask.Message) -> Void)?

    public init(request: SpeechRequest) {
        self.request = request
    }

    public func start() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let socket = session.webSocketTask(with: makeRequest())
            guard storeSocket(session: session, socket: socket) else {
                session.invalidateAndCancel()
                throw CancellationError()
            }
            socket.resume()
            receive()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self?.failReady(SpeechError.message("La transcription temps réel n'a pas démarré."))
            }
            try await readyResult.value()
            flushPending()
        } onCancel: {
            self.cancel()
        }
    }

    public func send(_ pcm16k: Data) {
        guard !pcm16k.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        // Après `finalize`, on garde encore l'audio jusqu'à `audio.done` pour ne pas le perdre.
        // Une fois `audio.done` parti, plus rien : le serveur a clos la session.
        if !acceptingAudio || !ready || finalizeQueued {
            guard !audioDoneQueued else { return }
            pending.append(pcm16k)
            if pending.count > 8_000_000 {
                pending.removeFirst(pending.count - 8_000_000)
            }
            return
        }
        sentAudio = true
        transmit(pcm16k)
    }

    public func finish() async throws -> StreamFinish {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (hasAudio, already, isClosed, finished) = finishSnapshot()
            if isClosed || finished { return try await finishResult.value() }
            guard hasAudio || !already.isEmpty else {
                return StreamFinish(text: "", endingFinalized: false, coveredSeconds: nil)
            }
            let start = lock.withLock { () -> Bool in
                if closed || didFinish || finishStarted { return false }
                finishStarted = true
                return true
            }
            guard start else { return try await finishResult.value() }
            // Audio d'abord, puis `finalize`. `audio.done` seulement après un segment final,
            // ou après une borne courte : ce message fait émettre `transcript.done` et ferme le socket.
            sealAudioThenFinalize()
            if request.provider == .xai, !lock.withLock({ assembler.endingFinalized || closed || didFinish }) {
                await waitForTailFinal()
            }
            if request.provider == .xai, !lock.withLock({ closed || didFinish }) {
                sendAudioDone()
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                self?.finishResult.resolve(.failure(SpeechError.message("La transcription finale n'a pas répondu.")))
            }
            return try await finishResult.value()
        } onCancel: {
            self.cancel()
        }
    }

    public func cancel() {
        let (socket, session) = takeCancellation()
        readyResult.resolve(.failure(CancellationError()))
        finishResult.resolve(.failure(CancellationError()))
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func storeSocket(session: URLSession, socket: URLSessionWebSocketTask) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            urlSession = session
            task = socket
            return true
        }
    }

    private func finishSnapshot() -> (Bool, String, Bool, Bool) {
        lock.withLock { (sentAudio || !pending.isEmpty, assembler.bestText, closed, didFinish) }
    }

    private func takeCancellation() -> (URLSessionWebSocketTask?, URLSession?) {
        lock.withLock {
            closed = true
            let resources = (task, urlSession)
            task = nil
            urlSession = nil
            pending.removeAll()
            return resources
        }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard request.provider == .openAI else { return }
        sendJSON(openAISessionUpdate())
        lock.lock()
        configured = true
        lock.unlock()
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: endpoint())
        request.setValue("Bearer \(self.request.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    private func endpoint() -> URL {
        switch request.provider {
        case .xai:
            var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
            var items = [
                URLQueryItem(name: "model", value: request.liveModel),
                URLQueryItem(name: "sample_rate", value: "16000"),
                URLQueryItem(name: "encoding", value: "pcm"),
                URLQueryItem(name: "interim_results", value: "true"),
                URLQueryItem(name: "endpointing", value: "5000"),
                URLQueryItem(name: "vad_threshold", value: "0.05")
            ]
            if let language = request.language.xaiCode {
                items.append(URLQueryItem(name: "language", value: language))
            }
            for term in request.keyterms {
                items.append(URLQueryItem(name: "keyterm", value: term))
            }
            components.queryItems = items
            return components.url!
        case .openAI:
            return URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        }
    }

    private func openAISessionUpdate() -> [String: Any] {
        var transcription: [String: Any] = [
            "model": request.liveModel,
            "prompt": request.prompt
        ]
        if !request.keyterms.isEmpty {
            transcription["keywords"] = request.keyterms
        }
        let languages = request.language.openAICodes
        if request.liveModel == "gpt-live-transcribe" {
            if !languages.isEmpty {
                transcription["languages"] = languages
            }
            transcription["delay"] = "low"
        } else if languages.count == 1 {
            transcription["language"] = languages[0]
        }
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
    }

    private func receive() {
        let socket = lock.withLock { closed ? nil : task }
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success(let message):
                self.handle(message)
                self.receive()
            }
        }
    }

    func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = object["type"] as? String ?? ""
        guard !lock.withLock({ closed }) else { return }
        if request.provider == .openAI, type == "session.created" {
            lock.lock()
            let needsConfig = !configured
            configured = true
            lock.unlock()
            if needsConfig {
                sendJSON(openAISessionUpdate())
            }
        }
        if request.provider == .openAI, type == "session.updated" {
            markReady()
        }
        switch request.provider {
        case .xai:
            let event = TranscriptEventParser.parseXAI(object)
            if case .created = event { markReady() }
            if case .error = event {
                fail(SpeechError.message("Le fournisseur a refusé la transcription temps réel."))
                return
            }
            lock.lock()
            assembler.apply(event)
            let partial = assembler.displayText
            let done = streamFinishIfDone(event)
            let settled: String? = {
                guard case .partial(_, let isFinal, let speechFinal, _) = event, isFinal || speechFinal,
                      assembler.endingFinalized, !finishStarted else { return nil }
                return assembler.bestText
            }()
            lock.unlock()
            publish(partial)
            if let settled, !settled.isEmpty { onSettled?(settled) }
            if let done { completeFinish(done) }
        case .openAI:
            let event = TranscriptEventParser.parseOpenAI(object)
            if case .error = event {
                fail(SpeechError.message("Le fournisseur a refusé la transcription temps réel."))
                return
            }
            lock.lock()
            assembler.apply(event)
            let partial = assembler.displayText
            let completed: StreamFinish? = {
                if case .completed = event {
                    return StreamFinish(text: assembler.bestText, endingFinalized: true, coveredSeconds: nil)
                }
                return nil
            }()
            lock.unlock()
            publish(partial)
            if let completed { completeFinish(completed) }
        }
    }

    private func streamFinishIfDone(_ event: XAIEvent) -> StreamFinish? {
        guard case .done = event else { return nil }
        return StreamFinish(
            text: assembler.bestText,
            endingFinalized: assembler.endingFinalized,
            coveredSeconds: assembler.finalizedCoverageEnd
        )
    }

    private func transmit(_ pcm16k: Data) {
        assembler.noteAudioAfterFinal()
        switch request.provider {
        case .xai:
            enqueueMessage(.data(pcm16k))
        case .openAI:
            let pcm24 = PCM16Resampler.resample(pcm16k, from: 16_000, to: 24_000)
            guard !pcm24.isEmpty else { return }
            sendJSON(["type": "input_audio_buffer.append", "audio": pcm24.base64EncodedString()])
        }
    }

    private func flushPending() {
        lock.withLock { drainPendingLocked() }
    }

    // Caller owns the state lock. Queue old audio before exposing readiness to
    // a concurrent microphone callback, and serialize the final commit after it.
    private func drainPendingLocked() {
        guard ready, !closed, !pending.isEmpty else { return }
        let data = pending
        pending.removeAll(keepingCapacity: true)
        sentAudio = true
        transmit(data)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        enqueueMessage(.string(text))
    }

    private func enqueueMessage(_ message: URLSessionWebSocketTask.Message) {
        outbound.async { [weak self] in
            guard let self else { return }
            let (socket, probe) = self.lock.withLock { (self.closed ? nil : self.task, self.onOutbound) }
            probe?(message)
            socket?.send(message) { [weak self] error in
                if let error { self?.fail(error) }
            }
        }
    }

    /// Gèle l'audio, laisse un envoi déjà engagé se ranger, puis : paquets en attente, ensuite `finalize`.
    private func sealAudioThenFinalize() {
        lock.lock()
        acceptingAudio = false
        let hook = beforeFinalizeDrain
        lock.unlock()
        hook?()
        lock.lock()
        if !closed {
            drainPendingLocked()
            switch request.provider {
            case .xai:
                sendJSON(["type": "finalize"])
            case .openAI:
                sendJSON(["type": "input_audio_buffer.commit"])
            }
            finalizeQueued = true
        }
        lock.unlock()
    }

    private func waitForTailFinal() async {
        let seconds = tailFinalWaitSeconds
        guard seconds > 0 else { return }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { return }
            if lock.withLock({ assembler.endingFinalized || closed || didFinish }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func sendAudioDone() {
        lock.lock()
        if !closed, !audioDoneQueued {
            drainPendingLocked()
            sendJSON(["type": "audio.done"])
            audioDoneQueued = true
        }
        lock.unlock()
    }

    private func markReady() {
        let changed = lock.withLock {
            guard !ready, !closed else { return false }
            ready = true
            drainPendingLocked()
            return true
        }
        guard changed else { return }
        readyResult.resolve(.success(()))
        flushPending()
    }

    private func failReady(_ error: Error) {
        let timedOut = lock.withLock {
            guard !ready, !closed else { return false }
            closed = true
            return true
        }
        guard timedOut else { return }
        readyResult.resolve(.failure(error))
        finishResult.resolve(.failure(error))
    }

    private func fail(_ error: Error) {
        lock.lock()
        closed = true
        didFinish = true
        lock.unlock()
        readyResult.resolve(.failure(error))
        // Do not accept a partial transcript as a complete recording on failure.
        finishResult.resolve(.failure(error))
    }

    private func completeFinish(_ finish: StreamFinish) {
        lock.lock()
        let first = !didFinish
        didFinish = true
        lock.unlock()
        if first { finishResult.resolve(.success(finish)) }
    }

    private func publish(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onPartial?(trimmed)
    }


}

public enum BatchTranscriber {
    public static func transcribe(fileURL: URL, request: SpeechRequest) async throws -> String {
        switch request.provider {
        case .xai:
            return try await xai(fileURL: fileURL, request: request)
        case .openAI:
            return try await openAI(fileURL: fileURL, request: request)
        }
    }

    private static func xai(fileURL: URL, request: SpeechRequest) async throws -> String {
        var fields: [(String, String)] = [
            ("model", request.fileModel),
            ("filler_words", "false")
        ]
        if let language = request.language.xaiCode {
            fields.append(("format", "true"))
            fields.append(("language", language))
        }
        for term in request.keyterms {
            fields.append(("keyterm", term))
        }
        let (body, contentType) = try multipart(fields: fields, fileURL: fileURL)
        var http = URLRequest(url: URL(string: "https://api.x.ai/v1/stt")!)
        http.httpMethod = "POST"
        http.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        http.setValue(contentType, forHTTPHeaderField: "Content-Type")
        http.httpBody = body
        http.timeoutInterval = 60
        return try await textResponse(http)
    }

    private static func openAI(fileURL: URL, request: SpeechRequest) async throws -> String {
        var fields = [
            ("model", request.fileModel),
            ("prompt", String(request.prompt.prefix(800)))
        ]
        if let language = request.language.openAICodes.first, request.language != .auto {
            fields.append(("language", language))
        }
        let (body, contentType) = try multipart(fields: fields, fileURL: fileURL)
        var http = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        http.httpMethod = "POST"
        http.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        http.setValue(contentType, forHTTPHeaderField: "Content-Type")
        http.httpBody = body
        http.timeoutInterval = 60
        return try await textResponse(http)
    }

    private static func textResponse(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SpeechError.message("Transcription refusée (HTTP \(status)).")
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (object?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private static func multipart(fields: [(String, String)], fileURL: URL) throws -> (Data, String) {
        let boundary = "WispadBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        for (name, value) in fields {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }
        let file = try Data(contentsOf: fileURL)
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n")
        body.appendUTF8("Content-Type: audio/wav\r\n\r\n")
        body.append(file)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}

public enum CleanupModel {
    /// DeepSeek V4.1 Flash, sans raisonnement : environ 0,8 s par correction.
    public static let deepSeek = "deepseek-flash"
    public static let deepSeekAccount = "deepseek"
    /// Relais OpenAI quand DeepSeek ne répond pas : moins d'une seconde par correction.
    public static let openAIFallback = "gpt-5.4-mini"
}

public struct CleanupOutcome: Equatable, Sendable {
    public var text: String
    /// Appel de correction effectué (réussi ou non), à compter dans la consommation.
    public var usage: UsageEvent?
    /// Appels qui ont échoué avant celui-ci (service principal muet, par exemple).
    public var failedUsages: [UsageEvent]
    /// Nom du relais qui a corrigé le texte, si ce n'est pas le service principal.
    public var fallback: String?

    public init(text: String, usage: UsageEvent? = nil, failedUsages: [UsageEvent] = [], fallback: String? = nil) {
        self.text = text
        self.usage = usage
        self.failedUsages = failedUsages
        self.fallback = fallback
    }
}

public enum TextCleaner {
    /// Transport substituable dans les tests : aucune clé ni requête réelle n'est nécessaire.
    typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    static let httpTransport: HTTPTransport = { try await URLSession.shared.data(for: $0) }

    /// Chaque requête commencée garde son usage, même si sa réponse n'est pas utilisable.
    /// Les seules données conservées ici sont les compteurs et la destination de l'appel.
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [UsageEvent] = []

        var events: [UsageEvent] { lock.withLock { recorded } }

        func begin(route: Route, fallback: APIFallback?) -> String {
            let usage = TextCleaner.event(route: route, started: Date(), tokens: nil, succeeded: false, fallback: fallback)
            lock.withLock { recorded.append(usage) }
            return usage.id
        }

        func finish(id: String, route: Route, tokens: TokenUsage?, succeeded: Bool) {
            lock.withLock {
                guard let index = recorded.firstIndex(where: { $0.id == id }) else { return }
                let previous = recorded[index]
                var usage = TextCleaner.event(route: route, started: previous.createdAt, tokens: tokens,
                                             succeeded: succeeded, fallback: previous.fallback)
                usage.id = id
                recorded[index] = usage
            }
        }
    }

    /// Une destination possible pour un appel de correction.
    struct Route: Sendable {
        var api: UsageAPI
        var model: String
        var url: URL
        var key: String
        var provider: String
        /// Relais : ne sert que si un service placé avant n'a pas répondu.
        var isFallback: Bool
    }

    /// Ordre des services de correction : DeepSeek, puis OpenAI (gpt-5.4-mini), puis le modèle du fournisseur vocal.
    /// Quand DeepSeek vient d'échouer plusieurs fois, il passe en dernier pour ne pas faire attendre chaque dictée.
    static func routes(_ speech: SpeechRequest) -> [Route] {
        var routes: [Route] = []
        if let key = speech.cleanupKey, !key.isEmpty {
            routes.append(Route(api: .deepSeekCleanup, model: CleanupModel.deepSeek, url: URL(string: "https://api.deepseek.com/chat/completions")!, key: key, provider: "DeepSeek", isFallback: false))
        }
        if let key = speech.fallbackKey, !key.isEmpty {
            routes.append(Route(api: .openAICleanup, model: CleanupModel.openAIFallback, url: URL(string: "https://api.openai.com/v1/chat/completions")!, key: key, provider: "OpenAI", isFallback: !routes.isEmpty))
        } else if !speech.apiKey.isEmpty, routes.isEmpty || speech.provider == .xai {
            let xai = speech.provider == .xai
            routes.append(Route(
                api: xai ? .xaiCleanup : .openAICleanup,
                model: speech.provider.defaultCleanupModel,
                url: URL(string: xai ? "https://api.x.ai/v1/chat/completions" : "https://api.openai.com/v1/chat/completions")!,
                key: speech.apiKey,
                provider: speech.provider.displayName,
                isFallback: !routes.isEmpty
            ))
        }
        if speech.cleanupPrimaryDown, routes.count > 1, routes[0].api == .deepSeekCleanup {
            routes.append(routes.removeFirst())
        }
        return routes
    }

    /// Délai d'un service de correction seul, puis de chacun quand un relais le suit.
    public static let singleRouteSeconds = 4.0
    public static let perRouteSeconds = 2.5

    /// La correction de cette dictée, en clair : services essayés dans l'ordre (« DeepSeek deepseek-flash ») et
    /// attente maximale avant d'insérer le texte brut (hors allongement des longues dictées).
    public static func plan(_ speech: SpeechRequest) -> (steps: [String], maxSeconds: Double) {
        let routes = Array(routes(speech).prefix(2))
        let each = routes.count == 1 ? singleRouteSeconds : perRouteSeconds
        return (routes.map { "\($0.provider) \($0.model)" }, each * Double(routes.count))
    }

    public static func clean(transcript: String, request: CorrectionRequest, speech: SpeechRequest, enabled: Bool) async -> CleanupOutcome {
        await clean(transcript: transcript, request: request, speech: speech, enabled: enabled, transport: httpTransport)
    }

    static func clean(transcript: String, request: CorrectionRequest, speech: SpeechRequest, enabled: Bool, transport: @escaping HTTPTransport) async -> CleanupOutcome {
        if let selection = request.commandSelection {
            return await transform(selection: selection, request: request, speech: speech, enabled: enabled, transport: transport)
        }
        let original = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let locallyFormatted = request.structureDictation ? DictationStructure.format(original) : original
        guard enabled, !original.isEmpty, !Task.isCancelled else { return CleanupOutcome(text: locallyFormatted) }
        let routes = Array(routes(speech).prefix(2))
        guard !routes.isEmpty else { return CleanupOutcome(text: locallyFormatted) }
        let requests = RequestLog()
        // Une longue dictée demande plus de jetons et plus de temps : la correction ne doit jamais la couper.
        let maxTokens = min(4_096, max(400, original.count / 2))
        let extraSeconds = Double(original.count) / 800
        for (index, route) in routes.enumerated() {
            guard !Task.isCancelled else { break }
            let transition = fallback(for: index, routes: routes, speech: speech, stage: .correction)
            // Deux essais au plus : le texte brut reste inséré si aucun service ne répond à temps.
            let base = routes.count == 1 ? singleRouteSeconds : perRouteSeconds
            let timeout = base + extraSeconds
            do {
                let reply = try await withTimeout(seconds: timeout) {
                    try await send(system: CorrectionPrompt.system(for: request), user: CorrectionPrompt.userText(request), route: route, maxTokens: maxTokens, includeReasoning: true, transport: transport, requests: requests, fallback: transition)
                }
                let fallback = index > 0 || route.isFallback ? route.provider : nil
                let corrected = CorrectionPrompt.cleanModelOutput(reply.content, fallback: original)
                let faithful = FidelityGuard.check(
                    transcript: original,
                    corrected: corrected,
                    context: request.nearbyText,
                    dictionary: request.dictionary,
                    previousDictations: request.previousDictations + [request.windowText].compactMap { $0 },
                    alternative: request.alternativeTranscript
                )
                var failed = requests.events
                let usage = failed.popLast()
                let formatted = request.structureDictation ? DictationStructure.format(faithful) : faithful
                let settled = DictationStructure.collapseLoneItem(formatted, transcript: original)
                return CleanupOutcome(text: settled, usage: usage, failedUsages: failed, fallback: fallback)
            } catch {
                if isCancellation(error) { break }
            }
        }
        var failed = requests.events
        let last = failed.popLast()
        return CleanupOutcome(text: locallyFormatted, usage: last, failedUsages: failed)
    }

    /// Commande vocale sur une sélection : mêmes fournisseurs et mêmes relais que la correction, sans garde-fou de
    /// fidélité (c'est une réécriture voulue). Texte vide si personne ne répond : la sélection reste intacte.
    static func transform(selection: String, request: CorrectionRequest, speech: SpeechRequest, enabled: Bool, transport: @escaping HTTPTransport) async -> CleanupOutcome {
        guard enabled, !selection.isEmpty, !request.transcript.isEmpty, !Task.isCancelled else { return CleanupOutcome(text: "") }
        let routes = Array(routes(speech).prefix(2))
        guard !routes.isEmpty else { return CleanupOutcome(text: "") }
        let requests = RequestLog()
        let maxTokens = min(8_192, max(400, selection.count))
        let extraSeconds = Double(selection.count) / 400
        for (index, route) in routes.enumerated() {
            guard !Task.isCancelled else { break }
            let transition = fallback(for: index, routes: routes, speech: speech, stage: .correction)
            let base = routes.count == 1 ? singleRouteSeconds : perRouteSeconds
            do {
                let reply = try await withTimeout(seconds: base * 2 + extraSeconds) {
                    try await send(system: CorrectionPrompt.system(for: request), user: CorrectionPrompt.userText(request), route: route, maxTokens: maxTokens, includeReasoning: true, transport: transport, requests: requests, fallback: transition)
                }
                let text = CorrectionPrompt.cleanModelOutput(reply.content, fallback: selection)
                var failed = requests.events
                let usage = failed.popLast()
                return CleanupOutcome(text: text, usage: usage, failedUsages: failed, fallback: index > 0 || route.isFallback ? route.provider : nil)
            } catch {
                if isCancellation(error) { break }
            }
        }
        var failed = requests.events
        let last = failed.popLast()
        return CleanupOutcome(text: "", usage: last, failedUsages: failed)
    }

    /// La transition appartient à l'appel du relais, qu'il réussisse ou échoue.
    /// Sans clé principale configurée, le premier fournisseur disponible reste la route normale.
    static func fallback(for index: Int, routes: [Route], speech: SpeechRequest, stage: FallbackStage) -> APIFallback? {
        if index > 0 {
            return APIFallback(fromAPI: routes[index - 1].api, stage: stage, reason: .requestFailed)
        }
        if speech.cleanupPrimaryDown, !(speech.cleanupKey ?? "").isEmpty,
           routes[index].isFallback, routes[index].api != .deepSeekCleanup {
            return APIFallback(fromAPI: .deepSeekCleanup, stage: stage, reason: .servicePaused)
        }
        return nil
    }

    static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static func event(route: Route, started: Date, tokens: TokenUsage?, succeeded: Bool? = nil, fallback: APIFallback? = nil) -> UsageEvent {
        let latency = Int(Date().timeIntervalSince(started) * 1_000)
        let succeeded = succeeded ?? (tokens != nil)
        return UsageEvent(
            createdAt: started,
            api: route.api,
            model: route.model,
            tokens: tokens ?? TokenUsage(),
            costUSD: tokens.flatMap { Pricing.tokenCost(model: route.model, tokens: $0, at: started) },
            latencyMs: latency,
            succeeded: succeeded,
            fallback: fallback
        )
    }

    struct Reply: Sendable {
        var content: String
        var tokens: TokenUsage?
    }

    private enum ResponseError: Error {
        case status(Int)
    }

    static func send(system: String, user: String, route: Route, maxTokens: Int, includeReasoning: Bool, allowTruncated: Bool = false,
                     transport: @escaping HTTPTransport = httpTransport, requests: RequestLog = RequestLog(), fallback: APIFallback? = nil) async throws -> Reply {
        do {
            return try await sendAttempt(system: system, user: user, route: route, maxTokens: maxTokens,
                                         includeReasoning: includeReasoning, allowTruncated: allowTruncated,
                                         transport: transport, requests: requests, fallback: fallback)
        } catch ResponseError.status(400) where includeReasoning {
            // Deux requêtes distinctes ; la seconde reste chez le même fournisseur.
            return try await send(system: system, user: user, route: route, maxTokens: maxTokens,
                                  includeReasoning: false, allowTruncated: allowTruncated, transport: transport, requests: requests)
        }
    }

    private static func sendAttempt(system: String, user: String, route: Route, maxTokens: Int, includeReasoning: Bool, allowTruncated: Bool,
                                    transport: @escaping HTTPTransport, requests: RequestLog, fallback: APIFallback?) async throws -> Reply {
        try Task.checkCancellation()
        var body: [String: Any] = [
            "model": route.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        switch route.api {
        case .deepSeekCleanup:
            body["max_tokens"] = maxTokens
            body["temperature"] = 0
            body["thinking"] = ["type": "disabled"]
        case .xaiCleanup:
            body["max_tokens"] = maxTokens
            body["temperature"] = 0
            if includeReasoning { body["reasoning_effort"] = "low" }
        default:
            body["max_completion_tokens"] = maxTokens
            if includeReasoning { body["reasoning_effort"] = "none" }
        }
        var http = URLRequest(url: route.url)
        http.httpMethod = "POST"
        if !route.key.isEmpty {
            http.setValue("Bearer \(route.key)", forHTTPHeaderField: "Authorization")
        }
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.httpBody = try JSONSerialization.data(withJSONObject: body)
        http.timeoutInterval = 8
        try Task.checkCancellation()
        let id = requests.begin(route: route, fallback: fallback)
        var tokens: TokenUsage?
        do {
            let (data, response) = try await transport(http)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // L'usage est valide même quand le texte est tronqué, invalide ou refusé.
            tokens = TokenUsage.parse(object?["usage"] as? [String: Any])
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw ResponseError.status(status) }
            guard let choices = object?["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw SpeechError.message("Réponse de correction vide")
            }
            // Réponse coupée faute de jetons : la garder ferait perdre la fin de la dictée.
            if !allowTruncated, choices.first?["finish_reason"] as? String == "length" {
                throw SpeechError.message("Correction tronquée")
            }
            requests.finish(id: id, route: route, tokens: tokens, succeeded: true)
            return Reply(content: content, tokens: tokens)
        } catch {
            requests.finish(id: id, route: route, tokens: tokens, succeeded: false)
            throw error
        }
    }

    static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SpeechError.message("Correction trop lente")
            }
            guard let value = try await group.next() else {
                throw SpeechError.message("Correction vide")
            }
            group.cancelAll()
            return value
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
