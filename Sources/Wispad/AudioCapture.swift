import AVFoundation
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
    private var wav: WAVStream?
    private var analyzer = SpectrumAnalyzer()
    private let inputChoice = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// Micro réellement réglé sur le moteur (file `control` seulement) ; nil : celui du système.
    private var appliedInput: String?
    /// Écoute des reconfigurations du moteur actuel (file `control` seulement).
    private var configurationObserver: NSObjectProtocol?
    /// Démarrages demandés et abandonnés (délai dépassé) : un démarrage abandonné se referme seul.
    private let tickets = OSAllocatedUnfairLock(initialState: StartTickets())
    /// Redémarrages sur reconfiguration pendant l'écoute en cours : bornés, pour ne jamais boucler.
    private var reconfigurations = 0
    private static let maxReconfigurations = 3
    private static let log = Logger.wispad("audio")

    /// Micro voulu pour la prochaine écoute (identifiant CoreAudio) ; nil : celui du système.
    var inputDeviceUID: String? {
        get { inputChoice.withLock { $0 } }
        set { inputChoice.withLock { $0 = newValue } }
    }

    var onPCM: (@Sendable (Data) -> Void)?
    var isRunning: Bool { control.sync { engine?.isRunning == true } }

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

    /// La dictée n'attend plus les démarrages en cours : chacun se referme dès qu'il rend la main.
    func abandonStart() {
        tickets.withLock { $0.abandoned = $0.issued }
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
    private func runEngine(fresh: Bool) throws {
        // Micro choisi et toujours branché ; sinon celui du système. Sans choix, rien n'est lu ni changé.
        let wanted = inputDeviceUID.flatMap { InputDeviceChoice.effectiveUID(saved: $0, available: AudioInputDevices.all().map(\.uid)) }
        if fresh || wanted != appliedInput {
            // Autre micro ou moteur muet : un moteur neuf, réglé avant de lire son format.
            dropEngine()
        }
        let reused = self.engine != nil
        let engine = self.engine ?? AVAudioEngine()
        if !reused {
            self.engine = engine
            observeConfiguration(of: engine)
            if let wanted { AudioInputDevices.use(wanted, in: engine) }
        }
        appliedInput = wanted
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            dropEngine()
            throw AudioCaptureError.noInput
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
            throw AudioCaptureError.engine(String(localized: "Format audio 16 kHz indisponible."))
        }
        let next = AVAudioConverter(from: hardware, to: target)
        processingLock.lock()
        converter = next
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
            throw AudioCaptureError.engine(error.localizedDescription)
        }
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
            dropEngine()
            return
        }
        guard reconfigurations < Self.maxReconfigurations else { return }
        reconfigurations += 1
        Self.log.notice("entrée audio reconfigurée pendant l'écoute : moteur redémarré")
        do {
            try runEngine(fresh: true)
        } catch {
            Self.log.error("redémarrage du micro impossible après reconfiguration")
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
        guard let converter else { return }
        let ratio = 16_000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
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
        guard error == nil, let channel = output.int16ChannelData else { return }
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        let data = Data(bytes: channel[0], count: count * MemoryLayout<Int16>.size)
        wav?.append(data)
        let frames = analyzer.frames(pcm16: data, hop: 256)
        let arrival = CACurrentMediaTime()
        state.withLock {
            $0.timeline.push(frames, arrival: arrival, hopSeconds: 256.0 / 16_000)
        }
        onPCM?(data)
    }
}

private struct StartTickets {
    var issued = 0
    var abandoned = 0
}

private struct CaptureState {
    var timeline = BandTimeline()
}
