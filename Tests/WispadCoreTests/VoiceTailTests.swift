import Foundation
import Testing
@testable import WispadCore

struct VoiceTailTests {
    private func pcm(_ values: [Int16]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    @Test func anUnusedOrSilentMicrophoneNeedsNoTail() {
        var tail = VoiceTail()
        #expect(!tail.needsMoreAudio(at: 0))
        tail.note(rms: VoiceTail.rms(pcm16: pcm(Array(repeating: 0, count: 160))), at: 1)
        #expect(!tail.needsMoreAudio(at: 1))
    }

    @Test func aVoicedLastPacketGetsItsNaturalEnding() {
        var tail = VoiceTail()
        let voiced = pcm(Array(repeating: Int16(3_000), count: 160))
        tail.note(rms: VoiceTail.rms(pcm16: voiced), at: 1)
        #expect(tail.needsMoreAudio(at: 1))
        tail.note(rms: 0, at: 1.01)
        #expect(tail.needsMoreAudio(at: 1.01))
        tail.note(rms: 0, at: 1.02)
        #expect(tail.needsMoreAudio(at: 1.02))
        tail.note(rms: 0, at: 1.04)
        #expect(!tail.needsMoreAudio(at: 1.04))
    }

    @Test func aLongFinalPauseAddsNoWait() {
        var tail = VoiceTail()
        tail.note(rms: 0.1, at: 1)
        tail.note(rms: 0, at: 1.2)
        #expect(!tail.needsMoreAudio(at: 1.2))
    }

    @Test func aStoppedMicrophoneCannotKeepTheTailWaiting() {
        var tail = VoiceTail()
        tail.note(rms: 0.1, at: 1)
        #expect(!tail.needsMoreAudio(at: 1.11))
    }

    @Test func waitingWithoutANewPacketIsNotProofOfSilence() {
        var tail = VoiceTail()
        tail.note(rms: 0.1, at: 1)
        #expect(tail.needsMoreAudio(at: 1.05))
        tail.note(rms: 0.1, at: 1.08)
        #expect(tail.needsMoreAudio(at: 1.09))
    }

    @Test(arguments: [0.002, 0.004]) func quietRoomNoiseAfterSpeechDoesNotReopenTheTail(noise: Double) {
        var tail = VoiceTail()
        tail.note(rms: 0.1, at: 1)
        for index in 1...500 { tail.note(rms: noise, at: 1 + Double(index) / 100) }
        #expect(!tail.needsMoreAudio(at: 6))
        tail.note(rms: noise * 3, at: 6.01)
        #expect(tail.needsMoreAudio(at: 6.01))
    }

    @Test func thePeakAdaptsAfterTheSpeakerGetsQuieter() {
        var tail = VoiceTail()
        tail.note(rms: 0.5, at: 1)
        tail.note(rms: 0.005, at: 6)
        #expect(tail.needsMoreAudio(at: 6))
    }

    @Test func rmsIsSignedSymmetricAndHandlesEmptyBuffers() {
        #expect(VoiceTail.rms(pcm16: Data()) == 0)
        #expect(VoiceTail.rms(pcm16: Data([1])) == 0)
        #expect(abs(VoiceTail.rms(pcm16: pcm([3_000, -3_000])) - 3_000.0 / 32_768) < 0.000_001)
    }

    @Test func invalidOrOutOfOrderObservationsCannotExtendTheTail() {
        var tail = VoiceTail()
        tail.note(rms: 0.1, at: 1)
        tail.note(rms: .infinity, at: 2)
        tail.note(rms: 0.2, at: 0)
        #expect(!tail.needsMoreAudio(at: 2))
        #expect(!tail.needsMoreAudio(at: .nan))
    }
}
