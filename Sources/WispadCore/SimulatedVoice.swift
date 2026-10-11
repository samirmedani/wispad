import Foundation

/// Voix simulée pour montrer la bulle sans micro ni réseau (premier lancement) : une phrase en boucle,
/// syllabes avec attaque et retombée, courtes pauses entre les mots, plus longue en fin de phrase.
/// Déterministe : un même instant donne toujours les mêmes niveaux.
public enum SimulatedVoice {
    struct Syllable: Sendable {
        var start: Double
        var duration: Double
        var peak: Double
        /// 0 : voyelle sombre, l'énergie reste dans les graves ; 1 : plus d'aigus.
        var brightness: Double
    }

    /// Mots de la phrase, en nombre de syllabes ; 0 marque une virgule (respiration).
    static let words = [1, 2, 0, 2, 2, 1, 2, 0, 3, 1, 2]
    /// Montée d'une syllabe, comme la montée de la vraie bulle (~50 ms).
    static let attack = 0.045
    /// Retombée après la syllabe, comme celle de la vraie bulle (~150 ms pour l'essentiel).
    static let release = 0.11
    static let lead = 0.25
    static let commaPause = 0.3
    static let sentencePause = 0.7
    /// Petites variations par bande, à des fréquences différentes : aucune barre ne bouge en bloc.
    static let flutter: [Double] = [3.1, 4.3, 5.2, 6.7, 7.9, 9.4]

    static let script: (syllables: [Syllable], period: Double) = {
        var syllables: [Syllable] = []
        var time = lead
        var index = 0
        for (word, count) in words.enumerated() {
            guard count > 0 else {
                time += commaPause
                continue
            }
            for position in 0..<count {
                // Accent du français sur la dernière syllabe du mot : plus longue et plus forte.
                let stressed = position == count - 1
                var duration = 0.15 + 0.09 * unit(index, 1)
                if stressed { duration *= 1.25 }
                let peak = (stressed ? 0.82 : 0.58) + 0.12 * unit(index, 2)
                syllables.append(Syllable(start: time, duration: duration, peak: peak, brightness: unit(index, 3)))
                time += duration
                index += 1
            }
            time += 0.05 + 0.09 * unit(word, 4)
        }
        return (syllables, time + sentencePause)
    }()

    /// Durée d'une phrase ; la voix se répète ensuite à l'identique.
    public static var period: Double { script.period }

    /// Niveau 0…1 par bande, du grave à l'aigu, comme `SpectrumAnalyzer.bands`.
    public static func bands(at time: Double) -> [Float] {
        let local = time - (time / period).rounded(.down) * period
        var energy = Array(repeating: 0.0, count: SpectrumAnalyzer.bandCount)
        for syllable in script.syllables {
            let level = envelope(syllable, at: local)
            guard level > 0 else { continue }
            let falloff = 0.78 + 0.12 * syllable.brightness
            for band in energy.indices {
                energy[band] = max(energy[band], level * pow(falloff, Double(band)))
            }
        }
        return energy.indices.map { band in
            let wobble = 1 + 0.12 * sin(2 * .pi * flutter[band] * local + Double(band) * 1.7)
            return Float(min(1, max(0, energy[band] * wobble)))
        }
    }

    /// Barres de la bulle à cet instant : graves au centre, aigus sur les bords, comme la vraie bulle.
    public static func levels(at time: Double) -> [Float] {
        SpectrumAnalyzer.mirrored(bands(at: time))
    }

    /// Image fixe pour « réduire les animations » : le sommet d'une syllabe accentuée.
    public static var stillLevels: [Float] {
        let syllable = script.syllables[2]
        return levels(at: syllable.start + attack)
    }

    /// Enveloppe continue d'une syllabe : montée douce, léger affaiblissement, puis retombée exponentielle.
    static func envelope(_ syllable: Syllable, at time: Double) -> Double {
        let elapsed = time - syllable.start
        guard elapsed > 0 else { return 0 }
        if elapsed < attack {
            let progress = elapsed / attack
            return syllable.peak * progress * progress * (3 - 2 * progress)
        }
        let held = min(elapsed, syllable.duration)
        let body = syllable.peak * (1 - 0.3 * (held - attack) / (syllable.duration - attack))
        guard elapsed > syllable.duration else { return body }
        return body * exp(-(elapsed - syllable.duration) / release)
    }

    /// Nombre pseudo-aléatoire fixe dans 0..<1 (mélange de splitmix64).
    static func unit(_ index: Int, _ salt: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
            &+ UInt64(truncatingIfNeeded: salt) &* 0xBF58_476D_1CE4_E5B9
            &+ 0x94D0_49BB_1331_11EB
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}
