import Foundation
import XCTest
@testable import WispadCore

final class SpectrumLatencyTests: XCTestCase {
    func testSmallAndLargePacketsProduceIdenticalFrames() {
        let pcm = tone(sampleCount: 32_237)
        let reference = SpectrumAnalyzer().frames(pcm16: pcm)

        for packetSamples in [171, 2_048] {
            let analyzer = SpectrumAnalyzer()
            var frames: [[Float]] = []
            for offset in stride(from: 0, to: pcm.count, by: packetSamples * 2) {
                let end = min(offset + packetSamples * 2, pcm.count)
                frames += analyzer.frames(pcm16: pcm[offset..<end])
            }
            XCTAssertEqual(frames, reference, "Paquets de \(packetSamples) échantillons")
        }
        XCTAssertEqual(reference.count, 32_237 / 256)
    }

    func testPartialHopWaitsAndFFTStillNeeds512Samples() {
        let analyzer = SpectrumAnalyzer()
        let pcm = tone(sampleCount: 512)
        XCTAssertTrue(analyzer.frames(pcm16: pcm[0..<510]).isEmpty)

        let firstHop = analyzer.frames(pcm16: pcm[510..<512])
        XCTAssertEqual(firstHop, [Array(repeating: Float(0), count: SpectrumAnalyzer.bandCount)])

        let secondHop = analyzer.frames(pcm16: pcm[512..<1_024])
        XCTAssertEqual(secondHop.count, 1)
        XCTAssertTrue(secondHop[0].contains { $0 > 0 })
        XCTAssertTrue(analyzer.frames(pcm16: Data()).isEmpty)
    }

    func testSmallPacketsDoNotAccumulateExtraDisplayTime() {
        let analyzer = SpectrumAnalyzer()
        let pcm = tone(sampleCount: 160_000)
        var frameCount = 0
        for offset in stride(from: 0, to: pcm.count, by: 171 * 2) {
            let end = min(offset + 171 * 2, pcm.count)
            frameCount += analyzer.frames(pcm16: pcm[offset..<end]).count
            // Le reliquat est toujours inférieur à un hop, même après dix secondes de petits paquets.
            XCTAssertEqual(frameCount, end / (256 * 2))
        }
        XCTAssertEqual(Double(frameCount) * 0.016, 10, accuracy: 0.000_001)
    }

    private func tone(sampleCount: Int) -> Data {
        let samples = (0..<sampleCount).map { index in
            Int16(3_000 * sin(Double(index) * 2 * .pi * 250 / 16_000))
        }
        return samples.withUnsafeBytes { Data($0) }
    }
}
