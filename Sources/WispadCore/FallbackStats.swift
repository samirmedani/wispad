import Foundation

public enum FallbackStage: String, CaseIterable, Sendable {
    case transcription
    case correction
    case dictionary

    public var titleFR: String {
        switch self {
        case .transcription: return "Transcription"
        case .correction: return "Correction"
        case .dictionary: return "Dictionnaire"
        }
    }
}

public enum FallbackReason: String, Sendable {
    case requestFailed
    case servicePaused
}

/// Décrit le transfert vers l'API de l'événement qui porte cette métadonnée.
/// Aucun texte dicté ni contenu d'erreur fournisseur n'est conservé ici.
public struct APIFallback: Equatable, Sendable {
    public var fromAPI: UsageAPI
    public var stage: FallbackStage
    public var reason: FallbackReason

    public init(fromAPI: UsageAPI, stage: FallbackStage, reason: FallbackReason) {
        self.fromAPI = fromAPI
        self.stage = stage
        self.reason = reason
    }
}

public struct FallbackRouteSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var fromProvider: String
    public var toProvider: String
    public var stage: FallbackStage
    public var total: Int
    public var successes: Int
    public var failures: Int
}

/// Une bascule enregistrée, pour le détail des dernières : rien d'autre que ce que porte l'appel du relais.
public struct FallbackEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var date: Date
    public var stage: FallbackStage
    public var fromProvider: String
    public var toProvider: String
    public var reason: FallbackReason
    public var succeeded: Bool
    /// Cause de l'échec du service principal juste avant cette bascule, quand elle est connue.
    public var cause: APIFailureCause? = nil
}

public struct FallbackSummary: Equatable, Sendable {
    public var total: Int
    public var successes: Int
    public var failures: Int
    public var afterFailureCount: Int
    public var servicePausedCount: Int
    public var routes: [FallbackRouteSummary]
    /// Les plus récentes d'abord, `recentLimit` au plus.
    public var recent: [FallbackEntry]

    public func count(for stage: FallbackStage) -> Int {
        routes.lazy.filter { $0.stage == stage }.reduce(0) { $0 + $1.total }
    }

    public static func make(
        events: [UsageEvent],
        period: StatsPeriod,
        now: Date = Date(),
        calendar: Calendar = .current,
        recentLimit: Int = 5
    ) -> FallbackSummary {
        let start = period.startDate(now: now, calendar: calendar)
        var seenIDs = Set<String>()
        var routes: [String: FallbackRouteSummary] = [:]
        var entries: [FallbackEntry] = []
        var afterFailure = 0
        var servicePaused = 0
        // Appels ratés par API, du plus ancien au plus récent : la bascule suit l'échec du service qu'elle remplace.
        var failedByAPI: [UsageAPI: [UsageEvent]] = [:]
        for event in events where !event.succeeded { failedByAPI[event.api, default: []].append(event) }
        for api in failedByAPI.keys { failedByAPI[api]?.sort { $0.createdAt < $1.createdAt } }
        func primaryCause(of fallback: APIFallback, before date: Date) -> APIFailureCause? {
            guard fallback.reason == .requestFailed else { return nil }
            return failedByAPI[fallback.fromAPI]?.last {
                $0.createdAt <= date && date.timeIntervalSince($0.createdAt) <= primaryFailureWindow
            }?.failureCause
        }

        for event in events {
            guard start == nil || event.createdAt >= start!,
                  let fallback = event.fallback,
                  fallback.fromAPI.provider != event.api.provider,
                  seenIDs.insert(event.id).inserted else { continue }

            let source = fallback.fromAPI.provider
            let destination = event.api.provider
            let id = "\(fallback.stage.rawValue):\(source):\(destination)"
            var route = routes[id] ?? FallbackRouteSummary(
                id: id,
                fromProvider: source,
                toProvider: destination,
                stage: fallback.stage,
                total: 0,
                successes: 0,
                failures: 0
            )
            route.total += 1
            if event.succeeded { route.successes += 1 } else { route.failures += 1 }
            routes[id] = route
            entries.append(FallbackEntry(
                id: event.id, date: event.createdAt, stage: fallback.stage, fromProvider: source,
                toProvider: destination, reason: fallback.reason, succeeded: event.succeeded,
                cause: primaryCause(of: fallback, before: event.createdAt)
            ))
            switch fallback.reason {
            case .requestFailed: afterFailure += 1
            case .servicePaused: servicePaused += 1
            }
        }

        let sorted = routes.values.sorted {
            $0.total == $1.total ? $0.id < $1.id : $0.total > $1.total
        }
        return FallbackSummary(
            total: sorted.reduce(0) { $0 + $1.total },
            successes: sorted.reduce(0) { $0 + $1.successes },
            failures: sorted.reduce(0) { $0 + $1.failures },
            afterFailureCount: afterFailure,
            servicePausedCount: servicePaused,
            routes: sorted,
            recent: Array(entries.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.prefix(recentLimit))
        )
    }

    /// Écart maximal entre l'échec du service principal et l'appel de secours qui le remplace.
    static let primaryFailureWindow: TimeInterval = 30
}
