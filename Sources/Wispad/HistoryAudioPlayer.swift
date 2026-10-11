import AVFoundation
import Foundation
import Observation

/// Backend isolé pour vérifier le lecteur sans ouvrir de périphérique audio.
@MainActor
protocol HistoryAudioPlayback: AnyObject, Sendable {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    var onCompletion: (@MainActor (Bool) -> Void)? { get set }
    func play() -> Bool
    func pause()
    func stop()
}

@MainActor
private final class SystemHistoryAudioPlayback: NSObject, HistoryAudioPlayback, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onCompletion: (@MainActor (Bool) -> Void)?

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        guard player.prepareToPlay() else { throw HistoryAudioPlayer.PlaybackError.unavailable }
    }

    var duration: TimeInterval { player.duration }
    var isPlaying: Bool { player.isPlaying }
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onCompletion?(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.onCompletion?(false) }
    }
}

/// Un seul audio sélectionné. Le rafraîchissement s'arrête dès que la lecture s'arrête.
@MainActor
@Observable
final class HistoryAudioPlayer {
    enum PlaybackError: LocalizedError {
        case unavailable
        var errorDescription: String? { String(localized: "Impossible de lire cet audio.") }
    }

    typealias PlaybackFactory = @MainActor (URL) throws -> any HistoryAudioPlayback

    private(set) var recordID: String?
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let makePlayback: PlaybackFactory
    @ObservationIgnored private var playback: (any HistoryAudioPlayback)?
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var resumeAfterSeeking = false

    init(makePlayback: PlaybackFactory? = nil) {
        self.makePlayback = makePlayback ?? { try SystemHistoryAudioPlayback(url: $0) }
    }

    deinit {
        progressTask?.cancel()
        if let playback {
            Task { @MainActor in
                playback.onCompletion = nil
                playback.stop()
            }
        }
    }

    func play(recordID: String, url: URL) throws {
        if self.recordID == recordID, sourceURL == url, playback != nil {
            if isPlaying || isSeeking { togglePlayPause() }
            else { try startPlayback() }
            return
        }

        close()
        do {
            let next = try makePlayback(url)
            guard next.duration.isFinite, next.duration > 0 else {
                next.stop()
                throw PlaybackError.unavailable
            }
            playback = next
            sourceURL = url
            self.recordID = recordID
            duration = next.duration
            next.onCompletion = { [weak self, weak next] success in
                guard let self, let next, self.playback === next else { return }
                self.finish(successfully: success)
            }
            try startPlayback()
        } catch {
            close()
            errorMessage = PlaybackError.unavailable.localizedDescription
            // Le message d'un décodeur peut contenir le chemin d'un enregistrement.
            throw PlaybackError.unavailable
        }
    }

    func togglePlayPause() {
        guard playback != nil else { return }
        if isSeeking {
            resumeAfterSeeking.toggle()
        } else if isPlaying {
            pausePlayback()
        } else {
            try? startPlayback()
        }
    }

    /// Arrêter conserve la piste dans le lecteur et permet de la rejouer.
    func stop() {
        stopProgressUpdates()
        isSeeking = false
        resumeAfterSeeking = false
        playback?.stop()
        playback?.currentTime = 0
        position = 0
        isPlaying = false
        errorMessage = nil
    }

    func close() {
        playback?.onCompletion = nil
        stop()
        playback = nil
        sourceURL = nil
        recordID = nil
        duration = 0
    }

    func skip(by interval: TimeInterval) {
        guard interval.isFinite else { return }
        if !isSeeking, isPlaying { refreshProgress() }
        seek(to: position + interval)
    }

    func seek(to time: TimeInterval) {
        guard let playback, !time.isNaN else { return }
        let bounded = min(max(0, time), duration)
        playback.currentTime = bounded
        position = bounded
        if bounded >= duration, isPlaying {
            playback.pause()
            isPlaying = false
            stopProgressUpdates()
        }
    }

    func beginSeeking() {
        guard playback != nil, !isSeeking else { return }
        resumeAfterSeeking = isPlaying
        if isPlaying { pausePlayback() }
        isSeeking = true
    }

    func endSeeking() {
        guard isSeeking else { return }
        isSeeking = false
        let shouldResume = resumeAfterSeeking && position < duration
        resumeAfterSeeking = false
        if shouldResume { try? startPlayback() }
    }

    private func startPlayback() throws {
        guard let playback else { return }
        if position >= duration {
            playback.currentTime = 0
            position = 0
        }
        guard playback.play() else {
            isPlaying = false
            stopProgressUpdates()
            errorMessage = PlaybackError.unavailable.localizedDescription
            throw PlaybackError.unavailable
        }
        errorMessage = nil
        isPlaying = true
        startProgressUpdates()
    }

    private func pausePlayback() {
        playback?.pause()
        refreshProgress()
        isPlaying = false
        stopProgressUpdates()
    }

    private func finish(successfully success: Bool) {
        // Un délégué déjà en file d'attente ne doit pas annuler un arrêt ou un glisser.
        guard isPlaying, !isSeeking, playback?.isPlaying == false else { return }
        stopProgressUpdates()
        isPlaying = false
        isSeeking = false
        resumeAfterSeeking = false
        if success {
            position = duration
        } else {
            refreshProgress()
            playback?.pause()
            errorMessage = PlaybackError.unavailable.localizedDescription
        }
    }

    /// Séparé de l'horloge pour tester la progression de façon déterministe.
    func refreshProgress() {
        guard !isSeeking, let playback, playback.currentTime.isFinite else { return }
        position = min(max(0, playback.currentTime), duration)
    }

    private func startProgressUpdates() {
        stopProgressUpdates()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self, self.isPlaying else { return }
                self.refreshProgress()
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }
}
