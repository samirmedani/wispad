import AVFoundation
import Foundation
import WispadCore

/// Test du micro du premier lancement : un vumètre et rien d'autre. Seul le niveau de chaque paquet sort d'ici ;
/// l'audio n'est ni écrit, ni gardé, ni envoyé.
protocol MicrophoneMetering: AnyObject, Sendable {
    /// `onLevel` reçoit le niveau (dBFS) et la durée du paquet, sur le fil principal.
    func start(deviceUID: String?, onLevel: @escaping @MainActor @Sendable (Double, Double) -> Void) async throws
    func stop()
}

final class MicrophoneMeter: MicrophoneMetering, @unchecked Sendable {
    /// Seule file qui touche au moteur : démarrage et arrêt s'y suivent dans l'ordre demandé.
    private let queue: DispatchQueue
    private var engine: AVAudioEngine?

    init(queue: DispatchQueue = DispatchQueue(label: "com.yatofix.wispad.vumetre", qos: .userInitiated)) {
        self.queue = queue
    }

    func start(deviceUID: String?, onLevel: @escaping @MainActor @Sendable (Double, Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startEngine(deviceUID: deviceUID, onLevel: onLevel)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startEngine(deviceUID: String?, onLevel: @escaping @MainActor @Sendable (Double, Double) -> Void) throws {
        stopEngine()
        let engine = AVAudioEngine()
        if let deviceUID { AudioInputDevices.use(deviceUID, in: engine) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInput }
        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let frames = Int(buffer.frameLength)
            let level = SignalLevel.decibels(samples: UnsafeBufferPointer(start: channel[0], count: frames))
            let seconds = Double(frames) / sampleRate
            Task { @MainActor in onLevel(level, seconds) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engine(error.localizedDescription)
        }
        self.engine = engine
    }

    /// Sans attendre la file : un démarrage qui ne rend pas la main (micro bloqué, moteur qui ne répond plus) y est
    /// peut-être encore, et l'attendre figerait Wispad (Réessayer, Continuer, fenêtre fermée). L'arrêt passe après lui.
    func stop() {
        queue.async { self.stopEngine() }
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
