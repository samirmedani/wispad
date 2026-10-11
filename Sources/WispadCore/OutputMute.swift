import Foundation

/// Quand couper le son du Mac pendant une dictée.
public enum OutputMuteMode: String, Codable, CaseIterable, Sendable {
    /// Seulement si le son sort par des haut-parleurs : avec un casque ou des AirPods, rien n'est coupé.
    case speakersOnly
    /// Toujours, casque compris.
    case always

    public var title: String {
        switch self {
        case .speakersOnly: return "Haut-parleurs seulement"
        case .always: return "Toujours, casque compris"
        }
    }
}

public enum OutputMutePolicy {
    /// Faut-il couper la sortie audio actuelle ?
    public static func shouldMute(enabled: Bool, mode: OutputMuteMode, outputIsHeadphones: Bool, alreadyMuted: Bool) -> Bool {
        guard enabled, !alreadyMuted else { return false }
        return mode == .always || !outputIsHeadphones
    }
}
