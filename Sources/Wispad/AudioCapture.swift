import AVFoundation
import AudioToolbox
import QuartzCore
import Foundation
import WispadCore
import os

enum AudioCaptureError: LocalizedError {
    case noInput
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .noInput:
            return String(localized: "Aucun microphone n'est disponible.")
        case .engine(let message):
            return message
        }
    }
}

final class AudioCapture: @unchecked Sendable {
    /// Réutilise le moteur arrêté entre deux dictées ; aucun moteur ni micro n'est ouvert au repos initial.
    static let shared = AudioCapture()
    private let control = DispatchQueue(label: "com.yatofix.wispad.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private let state = OSAllocatedUnfairLock(initialState: CaptureState())
    private let processingLock = NSLock()
    private var converter: AVAudioConverter?
    /// Plus aucune voie à choisir pour ce convertisseur (sous `processingLock`) : une seule voie, voie déjà retenue,
    /// ou mélange en mono vérifié non muet.
    private var channelSettled = true
    private var wav: WAVStream?
    private var analyzer = SpectrumAnalyzer()
    private let inputChoice = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let isolationChoice = OSAllocatedUnfairLock(initialState: false)
    /// Le traitement de la voix a refusé de démarrer : micro standard jusqu'à ce que le réglage change.
    private let isolationRefusal = OSAllocatedUnfairLock(initialState: false)
    private let pcmSink = OSAllocatedUnfairLock<(@Sendable (Data) -> Void)?>(initialState: nil)
    private let interruptionSink = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    /// Micro réellement réglé sur le moteur (file `control` seulement) ; nil : celui du système.
    private var appliedInput: String?
    /// Traitement de la voix réellement actif sur le moteur (file `control` seulement).
    private var appliedIsolation = false
    /// Écoute des reconfigurations du moteur actuel (file `control` seulement).
    private var configurationObserver: NSObjectProtocol?
    /// Démarrages demandés et abandonnés (délai dépassé) : un démarrage abandonné se referme seul.
    private let tickets = OSAllocatedUnfairLock(initialState: StartTickets())
    /// Redémarrages sur reconfiguration pendant l'écoute en cours : bornés, pour ne jamais boucler.
    private var reconfigurations = 0
    private static let maxReconfigurations = 3
    /// L'arrêt de l'écoute en cours a déjà été signalé (file `control` seulement).
    private var interruptionSignaled = false
    private static let log = Logger.wispad("audio")

    /// Micro voulu pour la prochaine écoute (identifiant CoreAudio) ; nil : celui du système.
    var inputDeviceUID: String? {
        get { inputChoice.withLock { $0 } }
        set { inputChoice.withLock { $0 = newValue } }
    }

    /// Réduire le bruit et l'écho (Réglages) pour la prochaine écoute : traitement de la voix de macOS, celui des
    /// appels FaceTime. Changer ce choix redonne sa chance à un traitement refusé.
    var voiceIsolation: Bool {
        get { isolationChoice.withLock { $0 } }
        set {
            let changed = isolationChoice.withLock { current -> Bool in
                defer { current = newValue }
                return current != newValue
            }
            if changed { isolationRefusal.withLock { $0 = false } }
        }
    }

    /// Le traitement de la voix n'a pas démarré avec ce micro : les dictées passent par le micro standard.
    var voiceIsolationRefused: Bool { isolationRefusal.withLock { $0 } }

    /// Posé sur le fil principal, appelé sur le fil du micro : sous verrou, car un démarrage abandonné (micro trop
    /// lent) peut encore livrer un paquet pendant que la dictée suivante pose le sien.
    var onPCM: (@Sendable (Data) -> Void)? {
        get { pcmSink.withLock { $0 } }
        set { pcmSink.withLock { $0 = newValue } }
    }
    /// Posé sur le fil principal, appelé sur la file `control` : sous verrou, comme `onPCM`. Ne doit rien y attendre
    /// (jamais `stop()`), seulement prévenir la dictée.
    var onInterruption: (@Sendable () -> Void)? {
        get { interruptionSink.withLock { $0 } }
        set { interruptionSink.withLock { $0 = newValue } }
    }
    var isRunning: Bool { control.sync { engine?.isRunning == true } }

    /// Lancement de Wispad : charge la liste des composants audio de macOS, sans créer de moteur ni toucher au micro.
    ///
    /// Le service système qui la fournit (`AudioComponentRegistrar`) s'arrête seul au repos ; relancé, il refait sa
    /// recherche de composants et peut mettre 2 à 3 s à répondre. Le 16 octobre 2026, le micro de la première dictée
    /// après une installation s'est ainsi ouvert 3,2 s après l'appui, bulle figée (7 cas du 3 au 16 octobre, de 2,2 à
    /// 3,2 s). Une fois chargée, la liste reste dans Wispad : un moteur neuf se crée ensuite en 0,1 s, même service
    /// arrêté ou figé (mesuré le 16 octobre). Sur sa propre file, jamais celle du micro : une dictée lancée pendant ce
    /// chargement attend la même liste, ni plus ni moins qu'avant.
    static func preloadComponents() {
        DispatchQueue(label: "com.yatofix.wispad.audio-preload", qos: .userInitiated).async {
            let started = CACurrentMediaTime()
            var output = AudioComponentDescription(
                componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
            )
            let found = AudioComponentFindNext(nil, &output) != nil
            let elapsed = Int((CACurrentMediaTime() - started) * 1_000)
            log.notice("composants audio chargés en \(elapsed, privacy: .public) ms (sortie trouvée : \(found, privacy: .public))")
        }
    }

    /// Bandes à afficher maintenant : rejouées tranche par tranche entre deux paquets micro.
    var bands: [Float] {
        let now = CACurrentMediaTime()
        return state.withLock { $0.timeline.current(at: now) }
    }

    func start(directory: URL) async throws -> URL {
        let ticket = tickets.withLock { tickets -> Int in
            tickets.issued += 1
            return tickets.issued
        }
        return try await withCheckedThrowingContinuation { continuation in
            control.async {
                // Démarrage abandonné par la dictée avant même son tour : rien n'est ouvert.
                guard !self.isAbandoned(ticket) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let url = try self.startAudio(directory: directory)
                    // Abandonné pendant le démarrage (trop lent) : refermé ici, dans l'ordre de la file, pour ne
                    // jamais arrêter le micro d'une dictée suivante.
                    if self.isAbandoned(ticket) {
                        _ = self.stopAudio()
                        try? FileManager.default.removeItem(at: url)
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// La dictée n'attend plus les démarrages en cours : chacun se referme dès qu'il rend la main. L'écoute qu'un
    /// démarrage (ou un redémarrage) aurait ouverte juste avant l'abandon se referme aussi, à son tour dans la file :
    /// jamais celle d'une dictée suivante, demandée après.
    func abandonStart() {
        tickets.withLock { $0.abandoned = $0.issued }
        control.async {
            guard self.wav != nil else { return }
            let stopped = self.stopAudio()
            if let url = stopped.url { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func isAbandoned(_ ticket: Int) -> Bool {
        tickets.withLock { ticket <= $0.abandoned }
    }

    /// Moteur muet : un moteur neuf, même micro voulu, même fichier. Sans écoute en cours, rien n'est ouvert.
    func restart() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    try self.restartEngine()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startAudio(directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let writer = try WAVStream(url: url, sampleRate: 16_000)
        wav = writer
        reconfigurations = 0
        interruptionSignaled = false
        analyzer = SpectrumAnalyzer()
        state.withLock { $0 = CaptureState() }
        do {
            try runEngine(fresh: false)
        } catch {
            _ = stopAudio()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// File `control` : redémarre l'écoute en cours sur un moteur neuf.
    private func restartEngine() throws {
        guard wav != nil else { return }
        do {
            try runEngine(fresh: true)
        } catch {
            _ = stopAudio()
            throw error
        }
    }

    /// File `control` : règle le micro, lit son format, branche la conversion et démarre le moteur.
    /// `retried` : un moteur neuf a déjà remplacé un moteur préparé qui refusait de démarrer.
    private func runEngine(fresh: Bool, retried: Bool = false) throws {
        // Micro choisi et toujours branché ; sinon celui du système. Sans choix, rien n'est lu ni changé.
        let wanted = inputDeviceUID.flatMap { InputDeviceChoice.effectiveUID(saved: $0, available: AudioInputDevices.all().map(\.uid)) }
        let isolate = isolationApplies(to: wanted)
        if fresh || wanted != appliedInput || isolate != appliedIsolation {
            // Autre micro, autre traitement ou moteur muet : un moteur neuf, réglé avant de lire son format.
            dropEngine()
        }
        let reused = self.engine != nil
        let engine = self.engine ?? AVAudioEngine()
        if !reused {
            self.engine = engine
            if isolate {
                do {
                    try Self.enableVoiceProcessing(on: engine)
                } catch {
                    return try fallBackWithoutIsolation()
                }
                // Après l'activation : le changement de configuration qu'elle provoque n'est pas une panne.
                observeConfiguration(of: engine)
            } else {
                observeConfiguration(of: engine)
                if let wanted { AudioInputDevices.use(wanted, in: engine) }
            }
        }
        appliedInput = wanted
        appliedIsolation = isolate
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            dropEngine()
            if isolate { return try fallBackWithoutIsolation() }
            throw AudioCaptureError.noInput
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
            throw AudioCaptureError.engine(String(localized: "Format audio 16 kHz indisponible."))
        }
        let next = AVAudioConverter(from: hardware, to: target)
        // Le traitement de la voix rend la même voix traitée sur plusieurs voies (9 sur un MacBook Pro, mesuré le
        // 17 octobre 2026) : une seule est gardée, jamais leur somme. Sans lui, les voies restent mêlées comme avant.
        if isolate, hardware.channelCount > 1 { next?.channelMap = [0] }
        processingLock.lock()
        converter = next
        channelSettled = isolate || hardware.channelCount < 2
        processingLock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: hardware) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            dropEngine()
            if isolate {
                // Moteur préparé devenu inutilisable (sortie changée entre-temps…) : un moteur neuf, puis le micro standard.
                if reused, !retried { return try runEngine(fresh: true, retried: true) }
                return try fallBackWithoutIsolation()
            }
            throw AudioCaptureError.engine(error.localizedDescription)
        }
    }

    /// Traitement de la voix de macOS : bruit et écho réduits, gain automatique. Les autres sons du Mac ne baissent
    /// pas pendant la dictée (« Couper le son du Mac » s'en charge s'il est réglé). La sortie du moteur reste
    /// débranchée : branchée, elle empêche le démarrage (erreur -10875, mesurée le 17 octobre 2026).
    /// L'activation change une fois la configuration de l'entrée, environ 0,3 s après (mesuré le 17 octobre 2026) ; le
    /// moteur reste utilisable. On attend ce changement (1 s au plus) avant d'écouter : arrivé pendant l'écoute, il
    /// la ferait redémarrer sur un moteur neuf, qui le provoquerait à son tour.
    private static func enableVoiceProcessing(on engine: AVAudioEngine) throws {
        let settled = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in settled.signal() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false, duckingLevel: .min
        )
        engine.prepare()
        _ = settled.wait(timeout: .now() + 1)
    }

    /// Le traitement de la voix vaut pour le micro du système seulement. Un autre micro choisi dans Wispad reste en
    /// micro standard : ce traitement règle aussi la sortie du Mac, et y choisir un micro n'est pas sûr.
    private func isolationApplies(to wanted: String?) -> Bool {
        guard voiceIsolation, !voiceIsolationRefused else { return false }
        guard let wanted else { return true }
        return wanted == AudioInputDevices.systemDefault()?.uid
    }

    /// Au repos, prépare le traitement de la voix sans ouvrir le micro (le voyant ne s'allume pas) : son activation,
    /// environ 0,7 s, ne retarde plus le début de la dictée suivante, qui démarre alors en 0,2 s. Rien sans le
    /// réglage, sans l'accès au micro déjà accordé (aucune demande d'autorisation ici), ni pendant une écoute.
    func prepareVoiceIsolation() {
        guard voiceIsolation, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        control.async {
            guard self.wav == nil, self.engine == nil else { return }
            let wanted = self.inputDeviceUID.flatMap {
                InputDeviceChoice.effectiveUID(saved: $0, available: AudioInputDevices.all().map(\.uid))
            }
            guard self.isolationApplies(to: wanted) else { return }
            let engine = AVAudioEngine()
            do {
                try Self.enableVoiceProcessing(on: engine)
            } catch {
                Self.log.error("traitement de la voix refusé : micro standard")
                self.isolationRefusal.withLock { $0 = true }
                return
            }
            self.engine = engine
            self.observeConfiguration(of: engine)
            self.appliedInput = wanted
            self.appliedIsolation = true
        }
    }

    /// File `control` : le traitement de la voix n'a pas démarré avec ce micro. La dictée continue au micro standard,
    /// sur un moteur neuf, et le traitement reste de côté jusqu'à ce que le réglage change.
    private func fallBackWithoutIsolation() throws {
        Self.log.error("traitement de la voix refusé : micro standard")
        isolationRefusal.withLock { $0 = true }
        dropEngine()
        try runEngine(fresh: true)
    }

    /// File `control` : oublie le moteur actuel (arrêté), pour en créer un neuf au prochain démarrage.
    private func dropEngine() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        appliedInput = nil
        appliedIsolation = false
    }

    /// macOS a reconfiguré l'entrée (micro Bluetooth qui change de profil, autre fréquence, micro débranché) :
    /// AVAudioEngine s'est arrêté seul et n'enverrait plus rien. Pendant une écoute, il repart aussitôt sur un
    /// moteur neuf, dans le même fichier ; au repos, le moteur est seulement oublié.
    private func observeConfiguration(of engine: AVAudioEngine) {
        let observed = ObjectIdentifier(engine)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.control.async { self.engineReconfigured(observed) }
        }
    }

    /// File `control`.
    private func engineReconfigured(_ observed: ObjectIdentifier) {
        guard let engine, ObjectIdentifier(engine) == observed else { return }
        guard wav != nil else {
            // Au repos, un moteur du traitement de la voix reste prêt : il se reconfigure au prochain démarrage, et
            // le refaire coûterait son activation au début de la dictée suivante.
            if appliedIsolation { return }
            dropEngine()
            return
        }
        // Le traitement de la voix peut signaler un changement sans s'arrêter : l'écoute continue telle quelle.
        if appliedIsolation, engine.isRunning { return }
        guard reconfigurations < Self.maxReconfigurations else {
            // Arrêté par cette reconfiguration, le moteur ne sera plus relancé : la dictée doit le savoir.
            guard !engine.isRunning else { return }
            Self.log.error("reconfigurations répétées pendant l'écoute : micro arrêté")
            signalInterruption()
            return
        }
        reconfigurations += 1
        Self.log.notice("entrée audio reconfigurée pendant l'écoute : moteur redémarré")
        do {
            try runEngine(fresh: true)
        } catch {
            Self.log.error("redémarrage du micro impossible après reconfiguration")
            signalInterruption()
        }
    }

    /// File `control` : l'écoute en cours ne reçoit plus rien et ne repartira pas (micro disparu sans autre
    /// micro, moteur refusé). Signalé une fois par écoute : la dictée s'arrête avec l'audio déjà reçu.
    private func signalInterruption() {
        guard wav != nil, !interruptionSignaled else { return }
        interruptionSignaled = true
        onInterruption?()
    }

    /// Fin encore parlée : attendre sa retombée, sans jamais ajouter une attente à une pause déjà silencieuse.
    var needsVoiceTail: Bool {
        state.withLock { $0.voiceTail.needsMoreAudio(at: CACurrentMediaTime()) }
    }

    /// Ne ferme rien : l'appelant garde l'écoute exclusive puis appelle `stop()`, ou l'annule immédiatement.
    func finishVoiceTail() async {
        guard needsVoiceTail else { return }
        let deadline = CACurrentMediaTime() + VoiceTail.maximumWait
        while !Task.isCancelled, CACurrentMediaTime() < deadline, needsVoiceTail {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
    }

    func stop() -> (url: URL?, duration: Double) {
        control.sync { stopAudio() }
    }

    private func stopAudio() -> (url: URL?, duration: Double) {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        processingLock.lock()
        defer { processingLock.unlock() }
        let duration = wav?.durationSeconds ?? 0
        let url = wav?.url
        wav?.close()
        wav = nil
        converter = nil
        return (url, duration)
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        processingLock.lock()
        defer { processingLock.unlock() }
        guard let converter, var output = Self.convert(buffer, with: converter) else { return }
        if !channelSettled {
            // Une autre app active le traitement de la voix sur le micro intégré : macOS reconfigure l'entrée et livre
            // ses capsules en voies discrètes, que le mélange en mono rend en zéros parfaits (spectre figé, voix perdue
            // jusqu'à la fin de l'écoute ; reproduit le 30 octobre 2026). La voie qui capte le plus est alors gardée.
            if output.contains(where: { $0 != 0 }) {
                channelSettled = true
            } else if let loudest = Self.loudestChannel(of: buffer),
                      let remapped = AVAudioConverter(from: buffer.format, to: converter.outputFormat) {
                remapped.channelMap = [NSNumber(value: loudest)]
                self.converter = remapped
                channelSettled = true
                Self.log.notice("mélange des voies muet : voie \(loudest, privacy: .public) sur \(buffer.format.channelCount, privacy: .public) retenue")
                guard let rescued = Self.convert(buffer, with: remapped) else { return }
                output = rescued
            }
        }
        guard !output.isEmpty else { return }
        let data = output.withUnsafeBufferPointer { Data(buffer: $0) }
        wav?.append(data)
        let frames = analyzer.frames(pcm16: data, hop: 256)
        let arrival = CACurrentMediaTime()
        let rms = VoiceTail.rms(pcm16: data)
        state.withLock {
            $0.timeline.push(frames, arrival: arrival, hopSeconds: 256.0 / 16_000)
            $0.voiceTail.note(rms: rms, at: arrival)
        }
        onPCM?(data)
    }

    /// Un paquet du micro, en mono 16 kHz.
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Int16]? {
        let ratio = 16_000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// Voie la plus forte d'un paquet à plusieurs voies ; nil si aucune ne capte (silence réel) ou format non lu.
    private static func loudestChannel(of buffer: AVAudioPCMBuffer) -> Int? {
        guard let samples = buffer.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let interleaved = buffer.format.isInterleaved
        var best: (index: Int, peak: Float)?
        for index in 0..<channels {
            var peak: Float = 0
            for frame in 0..<frames {
                peak = max(peak, abs(interleaved ? samples[0][frame * channels + index] : samples[index][frame]))
            }
            if peak > (best?.peak ?? 0) { best = (index, peak) }
        }
        return best?.index
    }
}

private struct StartTickets {
    var issued = 0
    var abandoned = 0
}

private struct CaptureState {
    var timeline = BandTimeline()
    var voiceTail = VoiceTail()
}
