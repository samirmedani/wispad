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
        try await withCheckedThrowingContinuation { continuation in
            control.async {
                do { continuation.resume(returning: try self.startAudio(directory: directory)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func startAudio(directory: URL) throws -> URL {
        // Micro choisi et toujours branché ; sinon celui du système. Sans choix, rien n'est lu ni changé.
        let wanted = inputDeviceUID.flatMap { InputDeviceChoice.effectiveUID(saved: $0, available: AudioInputDevices.all().map(\.uid)) }
        if wanted != appliedInput {
            // Autre micro : un moteur neuf, réglé avant de lire son format.
            self.engine = nil
        }
        let reused = self.engine != nil
        let engine = self.engine ?? AVAudioEngine()
        self.engine = engine
        if !reused, let wanted { AudioInputDevices.use(wanted, in: engine) }
        appliedInput = wanted
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw AudioCaptureError.noInput
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
            throw AudioCaptureError.engine(String(localized: "Format audio 16 kHz indisponible."))
        }
        converter = AVAudioConverter(from: hardware, to: target)
        analyzer = SpectrumAnalyzer()
        state.withLock { $0 = CaptureState() }
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let writer = try WAVStream(url: url, sampleRate: 16_000)
        wav = writer
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: hardware) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            _ = stopAudio()
            self.engine = nil
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.engine(error.localizedDescription)
        }
        return url
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

private struct CaptureState {
    var timeline = BandTimeline()
}
