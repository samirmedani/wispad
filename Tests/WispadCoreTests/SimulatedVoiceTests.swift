import XCTest
@testable import WispadCore

final class SimulatedVoiceTests: XCTestCase {
    private let barCount = SpectrumAnalyzer.bandCount * 2 - 1
    private let frame = 1.0 / 120

    /// Une phrase complète, image par image à 120 Hz.
    private func sentence(from origin: Double = 0) -> [[Float]] {
        (0..<Int(SimulatedVoice.period / frame)).map { SimulatedVoice.levels(at: origin + Double($0) * frame) }
    }

    func testLevelsAreBoundedSymmetricAndShapedLikeTheBubble() {
        for levels in sentence() {
            XCTAssertEqual(levels.count, barCount)
            XCTAssertEqual(levels, Array(levels.reversed()), "Graves au centre, aigus sur les bords")
            for level in levels {
                XCTAssertGreaterThanOrEqual(level, 0)
                XCTAssertLessThanOrEqual(level, 1)
            }
        }
        XCTAssertEqual(SimulatedVoice.bands(at: 1).count, SpectrumAnalyzer.bandCount)
        XCTAssertEqual(SpectrumAnalyzer.mirrored([1, 2, 3]), [3, 2, 1, 2, 3])
    }

    func testDeterministicAndRepeatsEachSentence() {
        let period = SimulatedVoice.period
        XCTAssertGreaterThan(period, 3)
        XCTAssertLessThan(period, 10)
        for time in stride(from: 0.0, to: period, by: 0.137) {
            XCTAssertEqual(SimulatedVoice.levels(at: time), SimulatedVoice.levels(at: time))
            let later = SimulatedVoice.levels(at: time + 1_000 * period)
            for (value, expected) in zip(later, SimulatedVoice.levels(at: time)) {
                XCTAssertEqual(value, expected, accuracy: 1e-4)
            }
        }
    }

    func testNoBarStaysStill() {
        let frames = sentence()
        for bar in 0..<barCount {
            let values = frames.map { $0[bar] }
            XCTAssertGreaterThan(values.max()! - values.min()!, 0.4, "Barre \(bar) presque figée")
        }
    }

    func testEnergyIsStrongestInTheCentreAndFadesTowardTheEdges() {
        let frames = sentence()
        let means = (0..<barCount).map { bar in frames.reduce(0) { $0 + Double($1[bar]) } / Double(frames.count) }
        let centre = barCount / 2
        for bar in 0..<centre {
            XCTAssertLessThan(means[bar], means[bar + 1], "Énergie croissante vers le centre")
        }
        XCTAssertLessThan(means[0], means[centre] * 0.6)
    }

    func testSyllablesAndPausesLikeSpeech() {
        let centre = sentence().map { $0[barCount / 2] }
        // Attaques : le centre franchit 0,4 en montant, une fois par syllabe ou presque.
        let onsets = zip(centre, centre.dropFirst()).filter { pair in pair.0 < 0.4 && pair.1 >= 0.4 }.count
        XCTAssertGreaterThanOrEqual(onsets, 8)
        // Silences : respirations et fin de phrase, sans que la voix se taise la plupart du temps.
        let silent = sentence().filter { $0.max()! < 0.05 }.count
        let share = Double(silent) / Double(centre.count)
        XCTAssertGreaterThan(share, 0.05)
        XCTAssertLessThan(share, 0.4)
        XCTAssertGreaterThan(centre.max()!, 0.8)
    }

    func testMovesSmoothlyFromFrameToFrame() {
        let frames = sentence(from: 0.5) + [SimulatedVoice.levels(at: 0.5 + SimulatedVoice.period)]
        for (previous, next) in zip(frames, frames.dropFirst()) {
            for (before, after) in zip(previous, next) {
                XCTAssertLessThan(abs(after - before), 0.3, "Saut d'une image à l'autre")
            }
        }
    }

    func testStillFrameShowsSpeechForReducedMotion() {
        let still = SimulatedVoice.stillLevels
        XCTAssertEqual(still.count, barCount)
        XCTAssertEqual(still, Array(still.reversed()))
        XCTAssertGreaterThan(still[barCount / 2], 0.6)
        XCTAssertGreaterThan(still[barCount / 2], still[0])
        XCTAssertGreaterThan(still[0], 0.1)
    }
}
