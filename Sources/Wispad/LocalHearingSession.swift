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
    /// Langues dont le modèle est déjà sur ce Mac, avec la locale exacte installée (`fr-FR`, `fr-CA`, `en-US`, `en-GB`…).
    private static let installed = OSAllocatedUnfairLock<[DictationLanguage: String]>(initialState: [:])

    /// Au lancement, sans rien installer ni demander : quelles langues la seconde écoute peut suivre.
    static func prepare() {
        guard #available(macOS 26.0, *) else { return }
        Task.detached(priority: .utility) {
            let locales = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
            var languages: [DictationLanguage: String] = [:]
            if let fr = locales.first(where: { $0.lowercased() == "fr-fr" }) ?? locales.first(where: { $0.lowercased().hasPrefix("fr") }) {
                languages[.french] = fr
            }
            if let en = locales.first(where: { $0.lowercased() == "en-us" }) ?? locales.first(where: { $0.lowercased().hasPrefix("en") }) {
                languages[.english] = en
            }
            let found = languages
            installed.withLock { $0 = found }
            log.notice("seconde écoute : \(found.count, privacy: .public) langue(s) disponible(s)")
        }
    }

    static func make(language: DictationLanguage) -> (any LocalHearingSession)? {
        guard #available(macOS 26.0, *) else { return nil }
        let localeID: String? = installed.withLock { map in
            if language != .auto { return map[language] }
            // Langue automatique : suivre la langue préférée du système si son modèle est installé, sinon français puis anglais.
            for preferred in Locale.preferredLanguages {
                let lower = preferred.lowercased()
                if lower.hasPrefix("fr"), let fr = map[.french] { return fr }
                if lower.hasPrefix("en"), let en = map[.english] { return en }
            }
            return map[.french] ?? map[.english]
        }
        guard let localeID else { return nil }
        return AppleLocalHearing(locale: Locale(identifier: localeID))
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
    private struct FormatState {
        var converter: AVAudioConverter?
        var target: AVAudioFormat?
        /// Paquets arrivés avant la fin de `bestAvailableAudioFormat` : mis en attente (2 s max) au lieu d'être perdus.
        var buffered: [Data] = []
        var closed = false
    }
    private let pauses = OSAllocatedUnfairLock(initialState: Pauses())
    /// Sous ce niveau (environ -40 dBFS), le paquet est un silence ; mesuré : voix vers -25 dB, pauses sous -50 dB.
    private static let quietLevel = 0.01
    /// Une pause de ce temps après de la voix clôt les phrases ; jamais deux clôtures à moins de 1,5 s.
    private static let pauseSeconds = 0.3
    private static let closeSpacing = 1.5
    private static let maxBufferedBytes = 64_000
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let formatState = OSAllocatedUnfairLock(initialState: FormatState())
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
        // Résultats définitifs seulement : le préréglage progressif, plus réactif, se trompait sur des phrases que
        // celui-ci entend juste (même audio, mesuré le 31 octobre 2026).
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
                Self.close(state)
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
        let converter = target == source ? nil : AVAudioConverter(from: source, to: target)
        let (pending, shouldFinish): ([Data], Bool) = formatState.withLock { current in
            current.converter = converter
            current.target = target
            let queued = current.buffered
            current.buffered.removeAll()
            return (queued, current.closed)
        }
        for chunk in pending {
            deliver(chunk, converter: converter, target: target)
        }
        if shouldFinish { input.finish() }
    }

    func feed(_ pcm: Data) {
        let ready: (AVAudioConverter?, AVAudioFormat)? = formatState.withLock { current in
            guard !current.closed else { return nil }
            if let target = current.target { return (current.converter, target) }
            let queuedBytes = current.buffered.reduce(0) { $0 + $1.count }
            if queuedBytes + pcm.count <= Self.maxBufferedBytes {
                current.buffered.append(pcm)
            }
            return nil
        }
        guard let (converter, target) = ready else { return }
        deliver(pcm, converter: converter, target: target)
    }

    private func deliver(_ pcm: Data, converter: AVAudioConverter?, target: AVAudioFormat) {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let channel = buffer.int16ChannelData {
                channel[0].update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
            }
        }
        if let converter {
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
            guard error == nil, output.frameLength > 0 else { return }
            input.yield(AnalyzerInput(buffer: output))
        } else {
            input.yield(AnalyzerInput(buffer: buffer))
        }
        notePause(pcm)
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
        let readyNow = formatState.withLock { current -> Bool in
            current.closed = true
            return current.target != nil
        }
        if readyNow { input.finish() }
        guard let analyzer else { Self.close(state); return }
        let workTask = work
        let state = state
        Task.detached(priority: .userInitiated) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            // Laisser la boucle `transcriber.results` finir de consommer la dernière phrase avant de réveiller `finalText`.
            await workTask?.value
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
