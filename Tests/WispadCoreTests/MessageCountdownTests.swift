import Foundation
import Testing
@testable import WispadCore

struct MessageCountdownTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func runsDownLinearlyAndStopsAtZero() {
        let countdown = MessageCountdown(duration: 4, start: start)
        #expect(!countdown.isPaused)
        #expect(countdown.remaining(at: start) == 4)
        #expect(countdown.fraction(at: start.addingTimeInterval(1)) == 0.75)
        #expect(countdown.remaining(at: start.addingTimeInterval(9)) == 0)
        #expect(countdown.fraction(at: start.addingTimeInterval(9)) == 0)
    }

    @Test func pauseFreezesTheRemainingTimeUntilResume() {
        var countdown = MessageCountdown(duration: 4, start: start)
        countdown.pause(at: start.addingTimeInterval(1))
        #expect(countdown.isPaused)
        // Le survol dure longtemps : rien ne s'écoule.
        #expect(countdown.remaining(at: start.addingTimeInterval(60)) == 3)
        countdown.resume(at: start.addingTimeInterval(60))
        #expect(countdown.remaining(at: start.addingTimeInterval(61)) == 2)
        #expect(countdown.remaining(at: start.addingTimeInterval(63)) == 0)
    }

    @Test func repeatedPauseOrResumeChangesNothing() {
        var countdown = MessageCountdown(duration: 4, start: start)
        countdown.pause(at: start.addingTimeInterval(1))
        countdown.pause(at: start.addingTimeInterval(3))
        #expect(countdown.remaining(at: start.addingTimeInterval(3)) == 3)
        countdown.resume(at: start.addingTimeInterval(3))
        countdown.resume(at: start.addingTimeInterval(5))
        #expect(countdown.remaining(at: start.addingTimeInterval(4)) == 2)
    }

    @Test func aMessageShownUnderThePointerStartsPaused() {
        let countdown = MessageCountdown(duration: 1.5, start: start, paused: true)
        #expect(countdown.isPaused)
        #expect(countdown.remaining(at: start.addingTimeInterval(10)) == 1.5)
        #expect(countdown.fraction(at: start.addingTimeInterval(10)) == 1)
    }

    @Test func emptyDurationIsAlreadyOver() {
        let countdown = MessageCountdown(duration: -1, start: start)
        #expect(countdown.duration == 0)
        #expect(countdown.fraction(at: start) == 0)
    }
}
