import Foundation

/// Garde seulement l'énergie récente du micro, jamais les échantillons ni les mots.
/// Une fin encore parlée peut recevoir quelques paquets de plus avant de fermer le micro.
public struct VoiceTail: Sendable {
    public static let maximumWait: TimeInterval = 0.18
    public static let quietSeconds: TimeInterval = 0.03
    private static let freshSeconds: TimeInterval = 0.10
    private static let minimumRMS = 0.0015
    private var peak = 0.0
    private var noise = 0.0
    private var lastAudioAt: TimeInterval?
    private var lastVoiceAt: TimeInterval?

    public init() {}

    /// L'énergie est comparée à un plancher et au pic récent : un fond faible ne prolonge pas une pause.
    public mutating func note(rms: Double, at now: TimeInterval) {
        guard rms.isFinite, rms >= 0, now.isFinite,
              lastAudioAt.map({ now >= $0 }) ?? true else { return }
        let elapsed = lastAudioAt.map { now - $0 } ?? 0
        peak = max(rms, peak * exp(-elapsed / 0.8))
        // Le fond observé pendant les passages faibles reste du bruit, même quand le pic vocal décroît.
        // Sinon une longue pause redevient artificiellement de la parole après quelques secondes.
        if rms < max(Self.minimumRMS, noise * 2, peak * 0.2) {
            let retained = exp(-elapsed / 0.2)
            noise = noise == 0 ? rms : noise * retained + rms * (1 - retained)
        }
        lastAudioAt = now
        if rms >= max(Self.minimumRMS, noise * 2, peak * 0.2) { lastVoiceAt = now }
    }

    /// Pas d'attente au repos, après une pause, ou si le micro ne livre plus de paquet récent.
    public func needsMoreAudio(at now: TimeInterval) -> Bool {
        guard now.isFinite, let lastAudioAt, let lastVoiceAt,
              now >= lastAudioAt, now - lastAudioAt <= Self.freshSeconds else { return false }
        // L'absence de paquet pendant l'attente n'est pas un silence : un tap peut livrer de plus gros blocs.
        // Seuls les paquets réellement observés peuvent attester la retombée de la voix.
        return lastAudioAt - lastVoiceAt < Self.quietSeconds
    }

    /// RMS du PCM16 mono déjà produit pour le fichier et le flux. Aucun tampon supplémentaire.
    public static func rms(pcm16 data: Data) -> Double {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }
        return data.withUnsafeBytes { raw in
            var sum = 0.0
            for index in 0..<count {
                let value = Double(raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)) / 32_768
                sum += value * value
            }
            return sqrt(sum / Double(count))
        }
    }
}
