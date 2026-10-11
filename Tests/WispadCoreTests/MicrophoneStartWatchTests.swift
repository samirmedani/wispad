import Testing
@testable import WispadCore

struct MicrophoneStartWatchTests {
    @Test func firstPacketInTimeEndsTheWatch() {
        var watch = MicrophoneStartWatch()
        #expect(watch.deadlinePassed(packetReceived: true) == .done)
        #expect(watch.restarts == 0)
        #expect(watch.deadlinePassed(packetReceived: false) == .done)
    }

    @Test func silentMicrophoneRestartsOnceThenFails() {
        var watch = MicrophoneStartWatch()
        #expect(watch.deadlinePassed(packetReceived: false) == .restart)
        #expect(watch.restarts == 1)
        #expect(watch.deadlinePassed(packetReceived: false) == .fail)
        // Abandonnée, la dictée n'est jamais relancée ensuite.
        #expect(watch.deadlinePassed(packetReceived: false) == .done)
        #expect(watch.restarts == MicrophoneStartWatch.maxRestarts)
    }

    @Test func packetAfterRestartRecovers() {
        var watch = MicrophoneStartWatch()
        #expect(watch.deadlinePassed(packetReceived: false) == .restart)
        #expect(watch.deadlinePassed(packetReceived: true) == .done)
        #expect(watch.finished)
    }

    @Test func failedRestartFailsAtOnce() {
        var watch = MicrophoneStartWatch()
        #expect(watch.deadlinePassed(packetReceived: false) == .restart)
        #expect(watch.restartFailed() == .fail)
        #expect(watch.deadlinePassed(packetReceived: false) == .done)
    }

    @Test func limitsLeaveRoomForAColdStartButNeverAFrozenBubble() {
        // Un démarrage à froid normal (Bluetooth compris) tient sous la seconde ; la bulle ne reste jamais
        // plus de quelques secondes sans audio ni message.
        #expect(MicrophoneStartWatch.startLimit >= 2 && MicrophoneStartWatch.startLimit <= 5)
        #expect(MicrophoneStartWatch.firstPacketLimit >= 0.5 && MicrophoneStartWatch.firstPacketLimit <= 2)
        let worstSilence = MicrophoneStartWatch.firstPacketLimit * Double(MicrophoneStartWatch.maxRestarts + 1)
        #expect(worstSilence <= 4)
    }
}
