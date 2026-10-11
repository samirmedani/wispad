import Foundation

/// Santé des services distants : après deux échecs de suite, un service est mis de côté et les dictées
/// passent directement par le relais. Un contrôle en arrière-plan (`HealthProbe`, toutes les minutes)
/// le rétablit dès qu'il répond ; la mise de côté expire quand même au bout de 30 minutes.
public struct ServiceHealth: Equatable, Sendable {
    public static let failuresBeforePause = 2
    public static let pauseSeconds: TimeInterval = 1_800

    public static let deepSeek = "DeepSeek"
    public static func voice(_ provider: ProviderID) -> String { "voice." + provider.rawValue }

    private var streaks: [String: Int] = [:]
    private var lastFailure: [String: Date] = [:]

    public init() {}

    public mutating func record(_ service: String, succeeded: Bool, at date: Date = Date()) {
        if succeeded {
            streaks[service] = 0
        } else {
            streaks[service, default: 0] += 1
            lastFailure[service] = date
        }
    }

    /// Services actuellement mis de côté.
    public func downServices(now: Date = Date()) -> [String] {
        streaks.keys.filter { isDown($0, now: now) }.sorted()
    }

    public func isDown(_ service: String, now: Date = Date()) -> Bool {
        guard (streaks[service] ?? 0) >= Self.failuresBeforePause, let last = lastFailure[service] else { return false }
        return now.timeIntervalSince(last) < Self.pauseSeconds
    }
}
