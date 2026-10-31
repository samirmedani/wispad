import AVFoundation
import CoreMedia
import Foundation
import Speech
import WispadCore
import os

/// Seconde écoute du même audio par le moteur de dictée d'Apple, entièrement sur le Mac, pendant qu'on parle.
/// Elle ne remplace jamais la transcription : seuls ses passages divergents vont à la correction (`LocalHearing`).
/// Rien n'est demandé à l'utilisateur ni téléchargé : sans macOS 26 ou sans le modèle de la langue déjà installé,
/// Wispad dicte exactement comme avant.
protocol LocalHearingSession: AnyObject, Sendable {
    /// Paquet du micro, PCM 16 bits mono à 16 kHz, appelé sur le fil du micro.
    func feed(_ pcm: Data)
    /// Texte définitif entendu jusqu'ici (les phrases déjà closes), sans attendre.
    var text: String { get }
    /// Fin du son : la dernière phrase se clôt (une centaine de millisecondes, mesuré le 31 octobre 2026).
    func finish()
    /// Tout le texte une fois la dernière phrase close, ou ce qui est prêt au bout de `limit` secondes.
    func finalText(within limit: Double) async -> String
    func stop()
}

enum LocalHearingEngine {
    private static let log = Logger.wispad("seconde-ecoute")
    /// Langues dont le modèle est déjà sur ce Mac, lues une fois au lancement (`prepare`).
    private static let installed = OSAllocatedUnfairLock<Set<DictationLanguage>>(initialState: [])

    /// Au lancement, sans rien installer ni demander : quelles langues la seconde écoute peut suivre.
    static func prepare() {
        guard #available(macOS 26.0, *) else { return }
        Task.detached(priority: .utility) {
            let locales = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
            var languages: Set<DictationLanguage> = []
            if locales.contains(where: { $0.hasPrefix("fr") }) { languages.insert(.french) }
            if locales.contains(where: { $0.hasPrefix("en") }) { languages.insert(.english) }
            let found = languages
            installed.withLock { $0 = found }
            log.notice("seconde écoute : \(found.count, privacy: .public) langue(s) disponible(s)")
        }
    }

    static func make(language: DictationLanguage) -> (any LocalHearingSession)? {
        guard #available(macOS 26.0, *), installed.withLock({ $0.contains(language) }) else { return nil }
        return AppleLocalHearing(locale: Locale(identifier: language == .english ? "en-US" : "fr-FR"))
    }
}

@available(macOS 26.0, *)
private final class AppleLocalHearing: LocalHearingSession, @unchecked Sendable {
    private struct State {
        var finished = ""
        var closed = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }
    /// Pauses suivies sur le fil du micro : chaque pause clôt les phrases déjà dites.
    private struct Pauses {
        var fed = 0.0
        var quiet = 0.0
        var spoke = false
        var closedThrough = 0.0
    }
    private let pauses = OSAllocatedUnfairLock(initialState: Pauses())
    /// Sous ce niveau (environ -40 dBFS), le paquet est un silence ; mesuré : voix vers -25 dB, pauses sous -50 dB.
    private static let quietLevel = 0.01
    /// Une pause de ce temps après de la voix clôt les phrases ; jamais deux clôtures à moins de 1,5 s.
    private static let pauseSeconds = 0.3
    private static let closeSpacing = 1.5
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let converter = OSAllocatedUnfairLock<(AVAudioConverter?, AVAudioFormat?)>(initialState: (nil, nil))
    private var work: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?

    private static func close(_ state: OSAllocatedUnfairLock<State>) {
        let waiting = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.closed = true
            defer { current.waiters.removeAll() }
            return Array(current.waiters.values)
        }
        waiting.forEach { $0.resume() }
    }

    init(locale: Locale) {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        // Résultats définitifs seulement : le préréglage progressif, plus réactif, entendait « Il faut des
        // développeurs » là où celui-ci entend « Frérot, t'es développeur » (même audio, 31 octobre 2026).
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let state = state
        let analyzerBox = analyzer
        self.analyzer = analyzerBox
        work = Task.detached(priority: .userInitiated) { [weak self] in
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            self?.useFormat(format)
            let results = Task {
                do {
                    for try await result in transcriber.results where result.isFinal {
                        let words = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !words.isEmpty else { continue }
                        state.withLock { $0.finished += ($0.finished.isEmpty ? "" : " ") + words }
                    }
                } catch {}
                Self.close(state)
            }
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                results.cancel()
                return
            }
            await withTaskCancellationHandler {
                _ = await results.value
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        }
    }

    private func useFormat(_ format: AVAudioFormat?) {
        let target = format ?? source
        converter.withLock { $0 = (target == source ? nil : AVAudioConverter(from: source, to: target), target) }
    }

    func feed(_ pcm: Data) {
        defer { notePause(pcm) }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let channel = buffer.int16ChannelData {
                channel[0].update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
            }
        }
        let (converter, target) = converter.withLock { $0 }
        guard let target else { return }
        guard let converter else { input.yield(AnalyzerInput(buffer: buffer)); return }
        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / source.sampleRate + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
    }

    /// Le réglage précis d'Apple garde tout pour la fin (0,44 s pour 22 s de voix) : clore à chaque pause ne laisse
    /// que la dernière phrase au relâchement (0,14 s), sans perdre en précision (mesuré le 31 octobre 2026).
    private func notePause(_ pcm: Data) {
        let seconds = Double(pcm.count / 2) / 16_000
        let level = VoiceTail.rms(pcm16: pcm)
        let through: Double? = pauses.withLock { current in
            current.fed += seconds
            if level < Self.quietLevel { current.quiet += seconds } else { current.quiet = 0; current.spoke = true }
            guard current.spoke, current.quiet >= Self.pauseSeconds,
                  current.fed - current.closedThrough >= Self.closeSpacing else { return nil }
            current.spoke = false
            current.closedThrough = current.fed
            return current.fed - 0.15
        }
        guard let through, let analyzer else { return }
        Task.detached(priority: .utility) {
            try? await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 16_000))
        }
    }

    var text: String {
        state.withLock { $0.finished.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func finish() {
        input.finish()
        guard let analyzer else { return }
        let state = state
        Task.detached(priority: .userInitiated) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            Self.close(state)
        }
    }

    func finalText(within limit: Double) async -> String {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let closed = state.withLock { current -> Bool in
                if current.closed { return true }
                current.waiters[id] = continuation
                return false
            }
            if closed { continuation.resume(); return }
            let state = state
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, limit) * 1_000_000_000))
                state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
            }
        }
        return text
    }

    func stop() {
        input.finish()
        work?.cancel()
        Self.close(state)
    }
}
