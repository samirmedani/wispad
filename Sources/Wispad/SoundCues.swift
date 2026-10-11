import AppKit
import Foundation
import WispadCore

enum SoundCues {
    @MainActor private static var sounds: [DictationCue: NSSound] = [:]

    /// Charge les sons avant la première dictée, sans les jouer et sans ouvrir le microphone.
    @MainActor static func prepare() {
        guard sounds.isEmpty else { return }
        if let start = NSSound(data: startSignalData()) {
            start.volume = 0.7
            sounds[.start] = start
        }
        for (cue, name) in [(DictationCue.stop, "Pop"), (.cancel, "Bottle")] {
            guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { continue }
            sound.volume = 0.25
            sounds[cue] = sound
        }
    }

    /// Deux notes montantes (160 ms), entièrement en mémoire et terminées avant la coupure du son du Mac.
    static func startSignalData() -> Data {
        let sampleRate = 24_000
        let count = sampleRate * 160 / 1000
        var data = WAVHeader.make(dataBytes: count * 2, sampleRate: sampleRate)
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let second = time >= 0.08
            let local = second ? time - 0.08 : time
            let duration = second ? 0.08 : 0.07
            let envelope = local < duration ? pow(sin(.pi * local / duration), 2) : 0
            let value = 0.45 * envelope * sin(2 * .pi * (second ? 990 : 740) * local)
            var sample = Int16(value * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    @MainActor static func play(_ cue: DictationCue) {
        prepare()
        guard let sound = sounds[cue] else { return }
        sound.stop()
        sound.play()
    }
}
