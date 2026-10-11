import Foundation
import Testing
@testable import WispadApp

@MainActor
private final class FakeHistoryAudioPlayback: HistoryAudioPlayback {
    var duration: TimeInterval = 30
    var currentTime: TimeInterval = 0
    var onCompletion: (@MainActor (Bool) -> Void)?
    var playSucceeds = true
    var isPlaying = false
    var playCount = 0
    var stopCount = 0

    func play() -> Bool {
        playCount += 1
        isPlaying = playSucceeds
        return playSucceeds
    }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; stopCount += 1 }
    func finish(successfully success: Bool = true) {
        isPlaying = false
        currentTime = 0 // AVAudioPlayer peut remettre sa position à zéro en fin de fichier.
        onCompletion?(success)
    }
}

@MainActor
struct HistoryAudioPlayerTests {
    private let firstURL = URL(fileURLWithPath: "/fixture/first.wav")
    private let secondURL = URL(fileURLWithPath: "/fixture/second.wav")

    @Test func sameRecordTogglesWithoutReloadingAndStopCanReplay() throws {
        let backend = FakeHistoryAudioPlayback()
        var loads = 0
        let player = HistoryAudioPlayer { _ in loads += 1; return backend }
        defer { player.close() }

        try player.play(recordID: "first", url: firstURL)
        #expect(player.isPlaying)
        backend.currentTime = 7
        try player.play(recordID: "first", url: firstURL)
        #expect(!player.isPlaying)
        #expect(player.position == 7)
        #expect(!backend.isPlaying)

        player.togglePlayPause()
        #expect(player.isPlaying)
        #expect(backend.currentTime == 7)
        #expect(loads == 1)

        player.stop()
        #expect(!player.isPlaying)
        #expect(player.position == 0)
        #expect(backend.currentTime == 0)
        #expect(player.recordID == "first")
        #expect(player.duration == 30)
        player.togglePlayPause()
        #expect(player.isPlaying)
        #expect(backend.currentTime == 0)
    }

    @Test func seekAndTenSecondJumpsAreBoundedAndKeepPauseState() throws {
        let backend = FakeHistoryAudioPlayback()
        let player = HistoryAudioPlayer { _ in backend }
        defer { player.close() }
        try player.play(recordID: "first", url: firstURL)

        backend.currentTime = 4
        player.skip(by: 10)
        #expect(player.position == 14)
        #expect(backend.currentTime == 14)
        #expect(player.isPlaying)

        player.togglePlayPause()
        player.skip(by: -10)
        #expect(player.position == 4)
        #expect(!player.isPlaying)
        player.skip(by: -10)
        #expect(player.position == 0)
        player.seek(to: 100)
        #expect(player.position == 30)
        #expect(backend.currentTime == 30)
        #expect(!player.isPlaying)
        player.seek(to: -.infinity)
        #expect(player.position == 0)
        player.seek(to: .nan)
        #expect(player.position == 0)
        player.seek(to: .infinity)
        #expect(player.position == 30)
    }

    @Test func scrubbingPausesProgressAndResumesOnlyPreviouslyPlayingAudio() throws {
        let backend = FakeHistoryAudioPlayback()
        let player = HistoryAudioPlayer { _ in backend }
        defer { player.close() }
        try player.play(recordID: "first", url: firstURL)
        backend.currentTime = 3

        player.beginSeeking()
        player.beginSeeking() // Les événements répétés ne perdent pas l'intention de reprise.
        #expect(!player.isPlaying)
        #expect(!backend.isPlaying)
        player.seek(to: 12)
        backend.currentTime = 4
        player.refreshProgress()
        #expect(player.position == 12)
        backend.currentTime = 12
        player.endSeeking()
        #expect(player.isPlaying)
        #expect(backend.currentTime == 12)

        player.togglePlayPause()
        player.beginSeeking()
        player.seek(to: 8)
        player.endSeeking()
        #expect(!player.isPlaying)
        #expect(backend.currentTime == 8)
    }

    @Test func reachingTheEndByScrubbingOrSkippingStopsUntilReplay() throws {
        let backend = FakeHistoryAudioPlayback()
        let player = HistoryAudioPlayer { _ in backend }
        defer { player.close() }
        try player.play(recordID: "first", url: firstURL)

        player.beginSeeking()
        player.seek(to: 30)
        player.endSeeking()
        #expect(!player.isPlaying)
        #expect(player.position == 30)
        player.togglePlayPause()
        #expect(player.isPlaying)
        #expect(player.position == 0)

        backend.currentTime = 28
        player.skip(by: 10)
        #expect(!player.isPlaying)
        #expect(!backend.isPlaying)
        #expect(player.position == 30)
    }

    @Test func naturalCompletionKeepsDurationAndReplaysFromTheBeginning() throws {
        let backend = FakeHistoryAudioPlayback()
        let player = HistoryAudioPlayer { _ in backend }
        defer { player.close() }
        try player.play(recordID: "first", url: firstURL)
        backend.finish()

        #expect(!player.isPlaying)
        #expect(player.recordID == "first")
        #expect(player.position == 30)
        #expect(player.errorMessage == nil)
        player.togglePlayPause()
        #expect(player.isPlaying)
        #expect(player.position == 0)
        #expect(backend.currentTime == 0)
    }

    @Test func switchingFilesStopsPreviousAudioAndIgnoresItsLateCompletion() throws {
        let first = FakeHistoryAudioPlayback()
        let second = FakeHistoryAudioPlayback()
        second.duration = 45
        let player = HistoryAudioPlayer { url in url == firstURL ? first : second }
        defer { player.close() }
        try player.play(recordID: "first", url: firstURL)
        let lateCompletion = first.onCompletion

        // Même identifiant, mais fichier régénéré : ce n'est pas la même piste.
        try player.play(recordID: "first", url: secondURL)
        #expect(first.stopCount == 1)
        #expect(!first.isPlaying)
        #expect(first.onCompletion == nil)
        #expect(player.duration == 45)
        #expect(second.isPlaying)
        lateCompletion?(true)
        #expect(player.isPlaying)
        #expect(player.position == 0)

        player.close()
        #expect(second.stopCount == 1)
        #expect(!second.isPlaying)
        #expect(player.recordID == nil)
        #expect(player.position == 0)
        #expect(player.duration == 0)
    }

    @Test func stopDuringScrubbingPreventsResumeAndStaleCompletion() throws {
        let backend = FakeHistoryAudioPlayback()
        let player = HistoryAudioPlayer { _ in backend }
        defer { player.close() }
        try player.play(recordID: "first", url: firstURL)
        let lateCompletion = backend.onCompletion
        player.beginSeeking()
        player.seek(to: 20)
        player.stop()
        player.endSeeking()
        lateCompletion?(true)

        #expect(!player.isPlaying)
        #expect(player.position == 0)
        #expect(backend.currentTime == 0)
        #expect(backend.playCount == 1)
    }

    @Test func oldCompletionCannotFinishANewReplayOfTheSameBackend() throws {
        let backend = FakeHistoryAudioPlayback()
        let player = HistoryAudioPlayer { _ in backend }
        defer { player.close() }
        try player.play(recordID: "first", url: firstURL)
        let lateCompletion = backend.onCompletion
        player.stop()
        player.togglePlayPause()
        lateCompletion?(true)

        #expect(player.isPlaying)
        #expect(backend.isPlaying)
        #expect(player.position == 0)
    }

    @Test func loadAndPlayFailuresClearSelectionAndNeverExposeSourcePaths() throws {
        struct FixtureError: LocalizedError {
            var errorDescription: String? { "Private path /fixture/secret.wav" }
        }
        let loadFailure = HistoryAudioPlayer { _ in throw FixtureError() }
        #expect(throws: HistoryAudioPlayer.PlaybackError.self) {
            try loadFailure.play(recordID: "first", url: firstURL)
        }
        #expect(loadFailure.recordID == nil)
        #expect(!loadFailure.isPlaying)
        #expect(loadFailure.errorMessage == "Impossible de lire cet audio.")

        let backend = FakeHistoryAudioPlayback()
        backend.playSucceeds = false
        let playFailure = HistoryAudioPlayer { _ in backend }
        #expect(throws: HistoryAudioPlayer.PlaybackError.self) {
            try playFailure.play(recordID: "first", url: firstURL)
        }
        #expect(playFailure.recordID == nil)
        #expect(playFailure.position == 0)
        #expect(playFailure.duration == 0)
        #expect(!playFailure.isPlaying)
        #expect(backend.stopCount == 1)
    }

    @Test func resumeAndDecodeFailuresRemainVisibleAndRecoverable() throws {
        let backend = FakeHistoryAudioPlayback()
        let player = HistoryAudioPlayer { _ in backend }
        defer { player.close() }
        try player.play(recordID: "first", url: firstURL)
        player.togglePlayPause()
        backend.playSucceeds = false
        player.togglePlayPause()
        #expect(!player.isPlaying)
        #expect(player.errorMessage == "Impossible de lire cet audio.")
        #expect(player.recordID == "first")

        backend.playSucceeds = true
        player.togglePlayPause()
        #expect(player.isPlaying)
        #expect(player.errorMessage == nil)
        backend.finish(successfully: false)
        #expect(!player.isPlaying)
        #expect(player.errorMessage == "Impossible de lire cet audio.")
    }

    @Test func invalidDurationCannotStartPlayback() {
        let durations: [TimeInterval] = [0, -.infinity, .infinity, .nan, -1]
        for duration in durations {
            let backend = FakeHistoryAudioPlayback()
            backend.duration = duration
            let player = HistoryAudioPlayer { _ in backend }
            #expect(throws: HistoryAudioPlayer.PlaybackError.self) {
                try player.play(recordID: "first", url: firstURL)
            }
            #expect(backend.playCount == 0)
            #expect(backend.stopCount == 1)
            #expect(player.recordID == nil)
        }
    }

    @Test func progressTracksTheBackendWithoutRetainingTheOwner() async throws {
        let backend = FakeHistoryAudioPlayback()
        var player: HistoryAudioPlayer? = HistoryAudioPlayer { _ in backend }
        weak let weakPlayer = player
        try player?.play(recordID: "first", url: firstURL)
        backend.currentTime = 9.25
        player?.refreshProgress()
        #expect(player?.position == 9.25)
        player = nil
        #expect(weakPlayer == nil)
        await Task.yield()
        #expect(!backend.isPlaying)
        #expect(backend.stopCount == 1)
    }
}
