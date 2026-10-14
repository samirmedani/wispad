import Accelerate
import Foundation

/// Énergie par bande de fréquence, pour l'affichage du spectre pendant la dictée.
/// Les échantillons ne servent qu'au calcul et ne sont jamais conservés au-delà de la fenêtre.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let bandCount = 6

    private static let size = 512
    private static let log2n: vDSP_Length = 9
    private static let sampleRate = 16_000.0

    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var samples: [Float] = []
    /// Tampons du calcul, entièrement réécrits à chaque tranche : la boucle audio (une tranche toutes les 16 ms)
    /// n'alloue plus quatre tableaux par tranche.
    private var windowed = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private var real = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var imaginary = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    private var magnitudes = [Float](repeating: 0, count: SpectrumAnalyzer.size / 2)
    /// Moins d'un hop, reporté au paquet suivant pour ne pas allonger artificiellement le spectre.
    private var frameRemainder = Data()
    private let edges: [Int]

    public init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        // Bandes logarithmiques de 150 Hz à 5 kHz : la voix occupe surtout le bas du spectre.
        let binWidth = Self.sampleRate / Double(Self.size)
        edges = (0...Self.bandCount).map { index in
            let frequency = 150 * pow(5_000.0 / 150.0, Double(index) / Double(Self.bandCount))
            return max(1, Int(frequency / binWidth))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// PCM 16 bits mono 16 kHz → niveau 0…1 par bande, du grave à l'aigu.
    public func bands(pcm16 data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            samples.append(contentsOf: values.lazy.map { Float($0) / 32_768 })
        }
        if samples.count > Self.size {
            samples.removeFirst(samples.count - Self.size)
        }
        guard samples.count == Self.size else {
            return Array(repeating: 0, count: Self.bandCount)
        }
        let half = Self.size / 2
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        return (0..<Self.bandCount).map { band in
            let low = edges[band]
            let high = min(half, max(edges[band + 1], low + 1))
            let slice = magnitudes[low..<high]
            let peak = (slice.max() ?? 0) / Float(Self.size)
            // Les aigus portent moins d'énergie : +4 dB par bande pour garder un spectre lisible.
            let decibels = 20 * log10(max(peak, 1e-9)) + Float(band) * 4
            // Bruit de fond d'un micro vers -85 dB ; une voix normale (-32 dBFS) remplit les graves.
            return min(1, max(0, (decibels + 78) / 50))
        }
    }
}

public extension SpectrumAnalyzer {
    /// Bandes (grave → aigu) disposées en barres symétriques : graves au centre, aigus sur les bords.
    static func mirrored(_ bands: [Float]) -> [Float] {
        Array(bands.reversed() + bands.dropFirst())
    }

    /// Une image par tranche complète de `hop` échantillons. Le reliquat attend le paquet suivant :
    /// des petits paquets micro ne créent ainsi ni image supplémentaire ni retard d'affichage.
    func frames(pcm16 data: Data, hop: Int = 256) -> [[Float]] {
        guard hop > 0 else { return [] }
        let bytesPerHop = hop * MemoryLayout<Int16>.size
        var input = frameRemainder
        input.append(data)
        let completeBytes = input.count / bytesPerHop * bytesPerHop
        var frames: [[Float]] = []
        frames.reserveCapacity(completeBytes / bytesPerHop)
        for offset in stride(from: 0, to: completeBytes, by: bytesPerHop) {
            frames.append(bands(pcm16: input[offset..<(offset + bytesPerHop)]))
        }
        // Une copie bornée évite de conserver le stockage du paquet entier derrière une tranche.
        frameRemainder = input.subdata(in: completeBytes..<input.count)
        return frames
    }
}

/// Rejoue les images du spectre à l'heure où leur son a été capté, avec un retard d'un paquet micro.
/// Sans cela, l'affichage saute à chaque paquet (~10 par seconde) au lieu de suivre la voix.
public struct BandTimeline: Sendable {
    /// Au-delà, le retard s'accumule : on repart de l'instant présent.
    public static let maxBacklog = 0.2
    /// Image passée depuis plus longtemps à l'arrivée d'un paquet : plus rien ne la lira (écran en veille ou
    /// débranché pendant l'écoute, le spectre n'est plus redessiné).
    public static let staleAfter = 1.0

    private var queue: [(time: Double, bands: [Float])] = []
    private var latest: [Float]
    private var lastScheduled = -Double.infinity

    /// Images gardées pour l'affichage.
    var pendingFrames: Int { queue.count }

    public init(bandCount: Int = SpectrumAnalyzer.bandCount) {
        latest = Array(repeating: 0, count: bandCount)
    }

    public mutating func push(_ frames: [[Float]], arrival: Double, hopSeconds: Double) {
        guard !frames.isEmpty else { return }
        // Sans lecture du spectre, les images s'empilaient pendant toute l'écoute (62 par seconde). Seule la dernière
        // des images passées compte, comme dans `current(at:)` : les autres sont oubliées.
        let stale = queue.prefix(while: { $0.time <= arrival - Self.staleAfter }).count
        if stale > 0 {
            latest = queue[stale - 1].bands
            queue.removeFirst(stale)
        }
        var start = max(arrival, lastScheduled + hopSeconds)
        if start - arrival > Self.maxBacklog {
            start = arrival
            queue.removeAll()
        }
        for (index, frame) in frames.enumerated() {
            queue.append((start + Double(index) * hopSeconds, frame))
        }
        lastScheduled = start + Double(frames.count - 1) * hopSeconds
    }

    /// Dernière image due à cet instant.
    public mutating func current(at time: Double) -> [Float] {
        while let first = queue.first, first.time <= time {
            latest = first.bands
            queue.removeFirst()
        }
        return latest
    }
}
