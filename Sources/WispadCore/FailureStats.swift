import Foundation

/// Pourquoi un appel à un fournisseur n'a pas abouti, lu dans l'erreur reçue (code HTTP, erreur réseau du Mac, délai).
/// Seule la catégorie est gardée : jamais le texte de l'erreur, ni la demande, ni la réponse.
public enum APIFailureCause: String, CaseIterable, Codable, Sendable {
    /// Le Mac n'avait pas internet : aucune connexion, connexion perdue, nom du service introuvable.
    case offline
    /// Le fournisseur n'a pas répondu à temps.
    case timeout
    /// Service en panne ou injoignable : erreur 5xx, connexion refusée par le serveur.
    case serverError
    /// Limite de requêtes ou quota atteint : erreur 429.
    case rateLimited
    /// Clé refusée, crédit épuisé ou accès interdit : erreurs 401, 402, 403.
    case keyRejected
    /// Demande refusée pour une autre raison : autre erreur 4xx, erreur annoncée dans le flux.
    case refused
    /// Réponse vide, tronquée ou illisible.
    case badResponse
    /// Arrêté par Wispad ou par l'utilisateur (dictée annulée, trop courte) : pas un échec du fournisseur.
    case cancelled

    /// De quel côté vient l'échec : la connexion du Mac, le fournisseur, ou la clé du compte.
    public enum Side: String, CaseIterable, Sendable {
        case connection, provider, account, undetermined
    }

    /// Côté de l'échec ; nil pour une annulation. Un délai dépassé se départage avec les appels voisins
    /// (`FailureBreakdown`) : ici, il compte pour le fournisseur.
    public var side: Side? {
        switch self {
        case .offline: return .connection
        case .keyRejected: return .account
        case .cancelled: return nil
        case .timeout, .serverError, .rateLimited, .refused, .badResponse: return .provider
        }
    }

    public static func status(_ code: Int) -> APIFailureCause {
        switch code {
        case 401, 402, 403: return .keyRejected
        case 408: return .timeout
        case 429: return .rateLimited
        case 500...599: return .serverError
        case 400...499: return .refused
        default: return .badResponse
        }
    }

    public static func classify(_ error: Error) -> APIFailureCause {
        if let speech = error as? SpeechError, case .failure(let cause, _) = speech { return cause }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError { return classify(url.code) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return classify(URLError.Code(rawValue: ns.code)) }
        return .badResponse
    }

    static func classify(_ code: URLError.Code) -> APIFailureCause {
        switch code {
        case .cancelled: return .cancelled
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .cannotFindHost, .dnsLookupFailed, .callIsActive:
            return .offline
        case .cannotConnectToHost, .badServerResponse, .secureConnectionFailed: return .serverError
        case .userAuthenticationRequired, .userCancelledAuthentication: return .keyRejected
        default: return .badResponse
        }
    }
}

/// Échecs d'appels sur une période, par fournisseur et par cause, pour dire d'où viennent les bascules : la connexion
/// du Mac, le fournisseur, ou une clé refusée. Valable pour tout fournisseur : rien n'est propre à un nom.
public struct FailureBreakdown: Equatable, Sendable {
    public struct Provider: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public var name: String
        /// Échecs par cause, annulations exclues.
        public var causes: [APIFailureCause: Int]
        /// Délais dépassés sans aucun autre appel réussi autour : la connexion du Mac peut être en cause.
        public var undeterminedTimeouts: Int
        /// Fois où ce fournisseur, mis de côté après des échecs répétés, a été sauté au profit d'un autre.
        public var paused: Int

        public var failures: Int { causes.values.reduce(0, +) }
    }

    public var providers: [Provider]
    public var sides: [APIFailureCause.Side: Int]

    public var failures: Int { providers.reduce(0) { $0 + $1.failures } }
    public func count(_ side: APIFailureCause.Side) -> Int { sides[side] ?? 0 }

    /// Un délai dépassé est imputé au fournisseur si un autre appel a réussi dans cette fenêtre autour de lui : la
    /// connexion du Mac marchait à ce moment-là.
    public static let connectionProofWindow: TimeInterval = 60

    public static func make(events: [UsageEvent], period: StatsPeriod, now: Date = Date(),
                            calendar: Calendar = .current) -> FailureBreakdown {
        let start = period.startDate(now: now, calendar: calendar)
        let inPeriod = events.filter { start == nil || $0.createdAt >= start! }
        let successes = inPeriod.filter(\.succeeded).map(\.createdAt).sorted()
        var providers: [String: Provider] = [:]
        var sides: [APIFailureCause.Side: Int] = [:]
        var seen = Set<String>()
        func provider(_ name: String) -> Provider {
            providers[name] ?? Provider(name: name, causes: [:], undeterminedTimeouts: 0, paused: 0)
        }
        for event in inPeriod where seen.insert(event.id).inserted {
            if let fallback = event.fallback, fallback.reason == .servicePaused,
               fallback.fromAPI.provider != event.api.provider {
                var paused = provider(fallback.fromAPI.provider)
                paused.paused += 1
                providers[paused.name] = paused
            }
            guard !event.succeeded, let cause = event.failureCause, var side = cause.side else { continue }
            var entry = provider(event.api.provider)
            entry.causes[cause, default: 0] += 1
            if cause == .timeout, !hasSuccess(near: event.createdAt, in: successes) {
                side = .undetermined
                entry.undeterminedTimeouts += 1
            }
            sides[side, default: 0] += 1
            providers[entry.name] = entry
        }
        let sorted = providers.values
            .filter { $0.failures > 0 || $0.paused > 0 }
            .sorted { ($0.failures + $0.paused, $1.name) > ($1.failures + $1.paused, $0.name) }
        return FailureBreakdown(providers: sorted, sides: sides)
    }

    static func hasSuccess(near date: Date, in sortedDates: [Date]) -> Bool {
        let low = date.addingTimeInterval(-connectionProofWindow)
        let high = date.addingTimeInterval(connectionProofWindow)
        var lower = 0, upper = sortedDates.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sortedDates[middle] < low { lower = middle + 1 } else { upper = middle }
        }
        return lower < sortedDates.count && sortedDates[lower] <= high
    }
}
