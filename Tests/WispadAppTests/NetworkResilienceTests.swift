import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Micro simulé : un court enregistrement, sans vrai micro.
private final class ResilienceAudio: AudioRecording, @unchecked Sendable {
    var onPCM: (@Sendable (Data) -> Void)?
    let bands = Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)
    private var url: URL?

    func start(directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 128).write(to: url)
        self.url = url
        onPCM?(Data(repeating: 0, count: 1_024))
        return url
    }

    func stop() -> (url: URL?, duration: Double) { (url, 2) }
}

/// Flux simulé : refusé à l'ouverture (hors connexion, 429 au handshake), coupé avant son texte final (fermeture
/// inattendue du WebSocket), ou réussi.
private final class ResilienceStream: SpeechStreaming, @unchecked Sendable {
    enum Failure: Sendable {
        case start
        case finish
    }

    var onPartial: (@Sendable (String) -> Void)?
    var onSettled: (@Sendable (String) -> Void)?
    let failure: Failure?
    let text: String

    init(failure: Failure?, text: String) {
        self.failure = failure
        self.text = text
    }

    func start() async throws {
        if failure == .start { throw URLError(.notConnectedToInternet) }
    }

    func send(_ data: Data) {}

    func finish() async throws -> StreamFinish {
        if failure == .finish { throw URLError(.networkConnectionLost) }
        return StreamFinish(text: text, endingFinalized: true)
    }

    func cancel() {}
}

/// Micro, flux, fichier, correction, contrôles des services, vérification des clés et collage simulés ; la connexion
/// se coupe et revient à la demande. Aucun réseau, aucune vraie clé.
@MainActor
private final class ResilienceFixture {
    let directory: URL
    let audio = ResilienceAudio()
    let text = "Phrase de test."
    var online = true
    /// Flux refusé ou coupé, par fournisseur. Hors connexion, le flux ne s'ouvre jamais.
    var streamFailures: [ProviderID: ResilienceStream.Failure] = [:]
    /// Erreur du fichier, par fournisseur (429, 5xx…). Hors connexion, le fichier échoue toujours.
    var fileErrors: [ProviderID: any Error] = [:]
    /// Réponse de la vérification d'une clé ; nil : réseau indisponible.
    var keyStatus: Int? = 200
    var streams: [ResilienceStream] = []
    var streamedProviders: [ProviderID] = []
    var fileProviders: [ProviderID] = []
    /// Chaque demande de correction : vrai si elle peut partir chez un fournisseur, faux si elle est sautée.
    var cleanCalls: [Bool] = []
    var keyChecks: [URLRequest] = []
    var inserted: [String] = []
    var deepSeekProbes = 0
    var voiceProbes: [ProviderID] = []
    var model: AppModel!

    init(cleanupEnabled: Bool = false, verifyWithFile: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-resilience-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var deps = AppDependencies()
        deps.copyText = { _ in }
        deps.loadKey = { "fixture-" + $0 }
        deps.saveKey = { _, _ in true }
        deps.refreshKeys = { true }
        deps.requestMicrophone = { true }
        deps.captureContext = {
            let context = DictationContext()
            context.pid = 4_242
            return (context, Task { nil })
        }
        deps.readWindow = { _ in nil }
        deps.makeCapture = { [audio] in audio }
        deps.makeSession = { [weak self] speech in
            let failure: ResilienceStream.Failure? = self?.online == false
                ? ResilienceStream.Failure.start
                : self?.streamFailures[speech.provider]
            let stream = ResilienceStream(failure: failure, text: self?.text ?? "")
            self?.streamedProviders.append(speech.provider)
            self?.streams.append(stream)
            return stream
        }
        deps.transcribe = { [weak self] _, speech in
            self?.fileProviders.append(speech.provider)
            if self?.online == false { throw URLError(.notConnectedToInternet) }
            if let error = self?.fileErrors[speech.provider] { throw error }
            return self?.text ?? ""
        }
        deps.isOnline = { [weak self] in self?.online ?? true }
        deps.clean = { [weak self] text, _, _, enabled in
            self?.cleanCalls.append(enabled)
            guard enabled else { return CleanupOutcome(text: text) }
            // Hors connexion, l'appel échoue comme un vrai : le texte reste tel quel et l'essai est compté.
            guard self?.online == true else {
                let failed = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: nil, succeeded: false)
                return CleanupOutcome(text: text, usage: failed)
            }
            let usage = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.00001)
            return CleanupOutcome(text: text, usage: usage)
        }
        deps.probeDeepSeek = { [weak self] _ in
            self?.deepSeekProbes += 1
            return UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.000001)
        }
        deps.probeVoice = { [weak self] provider, _ in
            self?.voiceProbes.append(provider)
            return true
        }
        deps.validateKey = { [weak self] request in
            self?.keyChecks.append(request)
            guard let status = self?.keyStatus else { throw URLError(.notConnectedToInternet) }
            return status
        }
        deps.playCue = { _ in }
        deps.muteOutput = { _, _ in }
        deps.restoreOutput = {}
        deps.watchCorrections = { _, _, _, _ in }
        deps.judgeTerms = { _, _, _ in TermJudgement(kept: []) }
        deps.insert = { [weak self] text, _, shouldProceed, _ in
            guard shouldProceed() else { return .cancelled }
            self?.inserted.append(text)
            return .inserted
        }
        var settings = AppSettings()
        settings.cleanupEnabled = cleanupEnabled
        settings.verifyWithFile = verifyWithFile
        settings.learnCorrections = false
        settings.soundsEnabled = false
        settings.muteWhileDictating = false
        settings.structureDictation = false
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: deps)
        model.overlay.displaysPanel = false
    }

    /// Appels passés chez un autre fournisseur que le principal (bascules).
    var switches: [UsageEvent] { model.usage.filter { $0.fallback != nil } }

    func calls(_ api: UsageAPI) -> Int {
        model.usage.filter { $0.api == api }.count
    }

    func pause(_ service: String) {
        for _ in 0..<ServiceHealth.failuresBeforePause {
            model.health.record(service, succeeded: false)
        }
    }

    func dictate() async {
        await model.coordinator.begin(.toggle)
        await model.coordinator.end()
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Réseau des fournisseurs sans surprise : panne, lenteur, coupure ou absence de connexion ne bloquent pas la dictée,
/// ne relancent rien en rafale, ne comptent rien deux fois, et la bascule vers l'autre fournisseur ne se fait que
/// lorsqu'elle peut servir.
@MainActor
@Suite(.serialized)
struct NetworkResilienceTests {
    /// Hors connexion, le relais échouerait de même : il n'est pas tenté, ni compté comme une bascule ratée.
    @Test(arguments: [true, false])
    func offlineDictationKeepsTheAudioWithoutTryingTheRelay(verifyWithFile: Bool) async throws {
        let f = try ResilienceFixture(verifyWithFile: verifyWithFile)
        defer { f.dispose() }
        f.online = false
        await f.dictate()

        #expect(f.streamedProviders == [.xai])
        #expect(f.fileProviders == [.xai])
        #expect(f.switches.isEmpty)
        #expect(FallbackSummary.make(events: f.model.usage, period: .all).total == 0)
        #expect(f.inserted.isEmpty)
        let record = try #require(f.model.history.first)
        #expect(record.insertionStatus == InsertionStatus.transcriptionFailed.rawValue)
        #expect(f.model.coordinator.finishingCount == 0)
    }

    /// Une dictée hors connexion ne dit rien du fournisseur : connexion revenue, la suivante repart chez lui, sans
    /// bascule ni couleur de relais.
    @Test(arguments: [true, false])
    func offlineFailuresDoNotSendTheNextDictationToTheRelay(verifyWithFile: Bool) async throws {
        let f = try ResilienceFixture(verifyWithFile: verifyWithFile)
        defer { f.dispose() }
        f.online = false
        await f.dictate()
        #expect(!f.model.health.isDown(ServiceHealth.voice(.xai)))
        #expect(f.model.relayLines().isEmpty)

        f.online = true
        await f.dictate()
        #expect(f.streamedProviders == [.xai, .xai])
        #expect(f.inserted == [f.text])
        #expect(f.switches.isEmpty)
        #expect(f.model.coordinator.relay == nil)
    }

    /// Service déjà mis de côté, puis connexion coupée : la dictée hors connexion ne compte aucune bascule ratée.
    /// Connexion revenue, le relais reprend sa place.
    @Test func offlineDictationWithAPausedProviderCountsNoSwitch() async throws {
        let f = try ResilienceFixture()
        defer { f.dispose() }
        f.pause(ServiceHealth.voice(.xai))
        f.online = false
        await f.dictate()
        #expect(f.switches.isEmpty)
        #expect(f.fileProviders.count == 1)

        f.online = true
        await f.dictate()
        #expect(f.streamedProviders.last == .openAI)
        #expect(f.inserted == [f.text])
        #expect(f.switches.count == 1)
        #expect(f.switches.first?.fallback?.reason == .servicePaused)
    }

    /// Connexion perdue juste avant l'arrêt : aucune correction n'est envoyée (elle échouerait et compterait un échec
    /// de DeepSeek) ; le texte entendu est collé tel quel, comme sans correction.
    @Test func connectionLostBeforeReleaseSendsNoCorrection() async throws {
        let f = try ResilienceFixture(cleanupEnabled: true)
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        let stream = try #require(f.streams.last)
        stream.onPartial?(f.text)
        // Le texte entendu passe par le fil principal avant l'arrêt.
        try await Task.sleep(nanoseconds: 500_000_000)
        f.online = false
        await f.model.coordinator.end()

        #expect(f.cleanCalls.allSatisfy { !$0 })
        #expect(f.calls(.deepSeekCleanup) == 0)
        #expect(!f.model.health.isDown(ServiceHealth.deepSeek))
        #expect(f.inserted == [f.text])
    }

    /// Connexion perdue pendant une pause de la parole : la correction préparée n'est pas lancée, ni à l'arrêt.
    @Test func connectionLostDuringAPauseSendsNoPreparedCorrection() async throws {
        let f = try ResilienceFixture(cleanupEnabled: true)
        defer { f.dispose() }
        await f.model.coordinator.begin(.toggle)
        let stream = try #require(f.streams.last)
        stream.onPartial?(f.text)
        stream.onSettled?(f.text)
        f.online = false
        // Une correction préparée partirait 0,25 s après la pause.
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(f.cleanCalls.isEmpty)
        await f.model.coordinator.end()

        #expect(f.cleanCalls.allSatisfy { !$0 })
        #expect(f.calls(.deepSeekCleanup) == 0)
        #expect(f.inserted == [f.text])
    }

    /// Hors connexion, aucun contrôle des services mis de côté : il ne dirait rien d'eux, et chaque essai raté
    /// s'ajouterait à Consommation. Connexion revenue, chacun est contrôlé une fois et repris.
    @Test func pausedServicesAreNotProbedOffline() async throws {
        let f = try ResilienceFixture(cleanupEnabled: true)
        defer { f.dispose() }
        f.pause(ServiceHealth.deepSeek)
        f.pause(ServiceHealth.voice(.xai))
        f.online = false
        await f.model.checkDownServices()
        #expect(f.deepSeekProbes == 0)
        #expect(f.voiceProbes.isEmpty)
        #expect(f.model.usage.isEmpty)
        #expect(f.model.health.isDown(ServiceHealth.deepSeek))
        #expect(f.model.health.isDown(ServiceHealth.voice(.xai)))

        f.online = true
        await f.model.checkDownServices()
        #expect(f.deepSeekProbes == 1)
        #expect(f.voiceProbes == [.xai])
        #expect(f.model.health.downServices().isEmpty)
    }

    /// Panne du fournisseur de voix (429 au flux et au fichier) sur trois dictées : il est essayé une fois, le relais
    /// prend la suite, puis les dictées partent directement chez le relais. Jamais de rafale, une bascule par dictée.
    @Test func providerOutageIsNeverRetriedInABurst() async throws {
        let f = try ResilienceFixture()
        defer { f.dispose() }
        f.streamFailures[.xai] = .start
        f.fileErrors[.xai] = SpeechError.message("Transcription refusée (HTTP 429).")
        await f.dictate()
        await f.dictate()
        await f.dictate()

        #expect(f.inserted == [f.text, f.text, f.text])
        #expect(f.streamedProviders == [.xai, .openAI, .openAI])
        #expect(f.fileProviders.filter { $0 == .xai }.count == 1)
        #expect(f.calls(.xaiStreaming) == 1)
        #expect(f.calls(.xaiFile) == 1)
        #expect(f.switches.count == 3)
        #expect(f.switches.filter { $0.fallback?.reason == .requestFailed }.count == 1)
        #expect(f.switches.filter { $0.fallback?.reason == .servicePaused }.count == 2)
    }

    /// Flux coupé en pleine dictée (fermeture inattendue du WebSocket, connexion perdue puis revenue) : le fichier
    /// donne le texte, chaque appel est compté une fois, et la dictée suivante reste chez le même fournisseur.
    @Test(arguments: [true, false])
    func streamCutUsesTheFileOnceAndDoesNotSwitch(verifyWithFile: Bool) async throws {
        let f = try ResilienceFixture(verifyWithFile: verifyWithFile)
        defer { f.dispose() }
        f.streamFailures[.xai] = .finish
        await f.dictate()
        f.streamFailures[.xai] = nil
        await f.dictate()

        let files: [ProviderID] = verifyWithFile ? [.xai, .xai] : [.xai]
        #expect(f.inserted == [f.text, f.text])
        #expect(f.streamedProviders == [.xai, .xai])
        #expect(f.fileProviders == files)
        #expect(f.calls(.xaiStreaming) == 2)
        #expect(f.calls(.xaiFile) == files.count)
        #expect(f.switches.isEmpty)
        #expect(!f.model.health.isDown(ServiceHealth.voice(.xai)))
    }

    /// Vérification d'une clé : une demande bornée, une seule par clic, et des messages qui ne citent jamais la clé,
    /// quelle que soit la réponse (quota, panne, refus, réseau absent).
    @Test func keyCheckIsBoundedAndItsMessagesNeverShowTheKey() async throws {
        let f = try ResilienceFixture()
        defer { f.dispose() }
        let secret = "fixture-secret-to-hide"
        let statuses: [Int?] = [429, 500, 503, 401, nil]
        for status in statuses {
            f.keyStatus = status
            f.model.keyDrafts["openai"] = secret
            await f.model.verifyAndStoreKey("openai")
            let message = try #require(f.model.keyMessages["openai"])
            #expect(!message.contains(secret))
        }
        #expect(f.keyChecks.count == statuses.count)
        #expect(f.keyChecks.allSatisfy { $0.timeoutInterval > 0 && $0.timeoutInterval <= 15 })
        #expect(f.keyChecks.allSatisfy { $0.url?.absoluteString.contains(secret) == false })
        #expect(f.model.keyMessages["openai"] == "Réseau indisponible : clé non vérifiée, non enregistrée.")
    }
}
