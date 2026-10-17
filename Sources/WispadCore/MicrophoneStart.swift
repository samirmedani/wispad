import Foundation

/// Démarrage du micro surveillé : une dictée ne reste jamais en écoute muette.
///
/// Au premier démarrage du moteur audio après un lancement, macOS peut reconfigurer l'entrée (micro Bluetooth qui
/// change de profil, fréquence d'échantillonnage, micro par défaut qui se stabilise). Le moteur s'arrête alors seul
/// et plus aucun paquet n'arrive, ou son démarrage tarde. Cette règle dit quoi faire quand le premier paquet se
/// fait attendre : patienter, redémarrer le micro une fois sur un moteur neuf, puis abandonner la dictée.
public struct MicrophoneStartWatch: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Le premier paquet est arrivé : plus rien à surveiller.
        case done
        /// Redémarrer le micro sur un moteur neuf, puis attendre de nouveau `firstPacketLimit`.
        case restart
        /// Abandonner la dictée : la bulle le dit et Wispad revient prêt.
        case fail
    }

    /// Le démarrage du moteur doit rendre la main avant ce délai (secondes), sinon la dictée est abandonnée.
    /// Un démarrage à froid normal prend moins d'une seconde, Bluetooth compris, une fois la liste des composants
    /// audio de macOS chargée (au lancement de l'app) ; sans elle, son service système peut ajouter 2 à 3 s.
    public static let startLimit = 4.0
    /// Délai (secondes) entre le démarrage du moteur et le premier paquet audio. Un paquet arrive toutes les 10 à
    /// 30 ms : au-delà, le moteur est muet.
    public static let firstPacketLimit = 1.5
    /// Redémarrages tentés avant d'abandonner.
    public static let maxRestarts = 1

    public private(set) var restarts = 0
    public private(set) var finished = false

    public init() {}

    /// Délai écoulé depuis le dernier démarrage, avec ou sans premier paquet reçu.
    public mutating func deadlinePassed(packetReceived: Bool) -> Step {
        guard !finished else { return .done }
        if packetReceived {
            finished = true
            return .done
        }
        if restarts < Self.maxRestarts {
            restarts += 1
            return .restart
        }
        finished = true
        return .fail
    }

    /// Le redémarrage lui-même a échoué : inutile d'attendre un paquet.
    public mutating func restartFailed() -> Step {
        finished = true
        return .fail
    }
}
