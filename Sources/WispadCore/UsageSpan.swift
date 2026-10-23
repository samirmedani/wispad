import Foundation

/// Durée d'utilisation montrée sur la période « Tout » : du premier jour d'usage à aujourd'hui, les deux compris.
public struct UsageSpan: Equatable, Sendable {
    /// Premier jour d'utilisation (début de journée).
    public var firstDay: Date
    /// Jours calendaires comptés, premier jour et aujourd'hui compris : 1 le jour même.
    public var days: Int
    /// La même durée en années, mois et jours restants, pour la dire en mois au-delà d'un mois.
    public var years: Int
    public var months: Int
    public var remainingDays: Int

    /// Moins d'un mois : la durée se dit en jours ; au-delà, en mois (et années) et jours.
    public var isUnderAMonth: Bool { years == 0 && months == 0 }

    /// Une date future (horloge décalée) compte comme aujourd'hui.
    public static func make(firstUse: Date, now: Date, calendar: Calendar = .current) -> UsageSpan {
        let first = calendar.startOfDay(for: min(firstUse, now))
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let days = max(1, calendar.dateComponents([.day], from: first, to: end).day ?? 1)
        let parts = calendar.dateComponents([.year, .month, .day], from: first, to: end)
        return UsageSpan(firstDay: first, days: days, years: max(0, parts.year ?? 0),
                         months: max(0, parts.month ?? 0), remainingDays: max(0, parts.day ?? 0))
    }
}

/// Dépense ramenée à un mois, taxe comprise (Consommation, toutes périodes).
public enum MonthlyCost {
    /// Longueur moyenne d'un mois du calendrier grégorien.
    public static let averageMonthDays = 365.2425 / 12

    /// Moyenne par mois d'après les jours d'utilisation comptés.
    public static func perMonth(total: Double, days: Int) -> Double {
        guard days > 0 else { return 0 }
        return total / Double(days) * averageMonthDays
    }

    /// Jours sur lesquels ramener à un mois la dépense d'une période : un pour aujourd'hui, 7 ou 30 pour les derniers
    /// jours, sans dépasser les jours d'utilisation (une semaine d'usage ne se divise pas par 30), tous pour « Tout ».
    public static func days(for period: StatsPeriod, usedDays: Int) -> Int {
        let used = max(1, usedDays)
        switch period {
        case .today: return 1
        case .days7: return min(7, used)
        case .days30: return min(30, used)
        case .all: return used
        }
    }

    /// Montant taxe comprise ; `rate` en pourcentage (20 = 20 %).
    public static func withTax(_ amount: Double, rate: Double) -> Double {
        amount * (1 + max(0, rate) / 100)
    }
}

/// Taux normal de la taxe à la consommation (TVA, GST) d'un pays de repère.
public struct TaxReference: Equatable, Sendable {
    /// Code ISO 3166-1 du pays : son drapeau et son nom viennent de la langue de l'utilisateur.
    public var region: String
    /// Taux en pourcentage.
    public var rate: Double

    public init(region: String, rate: Double) {
        self.region = region
        self.rate = rate
    }
}

/// Curseur de taxe de Consommation : les prix publiés sont hors taxes, la taxe s'ajoute des deux côtés.
public enum SalesTax {
    /// Par défaut, la TVA française.
    public static let defaultRate = 20.0
    public static let range: ClosedRange<Double> = 0...27
    /// À moins de cette distance d'un taux de repère, le curseur s'y place exactement.
    public static let snapDistance = 0.3

    /// Taux normaux relevés le 16 octobre 2026 aux sources officielles (FTA, gouvernement thaï, AFC, IRAS, NTA, IRD,
    /// SAT, Commission européenne, Vero). Thaïlande : 7 % prolongés jusqu'au 30 septembre 2027.
    public static let references: [TaxReference] = [
        TaxReference(region: "AE", rate: 5),
        TaxReference(region: "TH", rate: 7),
        TaxReference(region: "CH", rate: 8.1),
        TaxReference(region: "SG", rate: 9),
        TaxReference(region: "JP", rate: 10),
        TaxReference(region: "NZ", rate: 15),
        TaxReference(region: "MX", rate: 16),
        TaxReference(region: "FR", rate: 20),
        TaxReference(region: "RO", rate: 21),
        TaxReference(region: "SK", rate: 23),
        TaxReference(region: "EE", rate: 24),
        TaxReference(region: "FI", rate: 25.5),
    ]

    /// Pays de repère au taux le plus proche ; nil sans taxe. À égalité, le taux le plus bas.
    public static func closest(to rate: Double) -> TaxReference? {
        guard rate >= 0.05 else { return nil }
        return references.min { abs($0.rate - rate) < abs($1.rate - rate) }
    }

    /// Valeur retenue pour une position du curseur : bornée, aimantée par un taux de repère proche, sinon arrondie au
    /// dixième.
    public static func snapped(_ rate: Double) -> Double {
        let clamped = min(max(rate, range.lowerBound), range.upperBound)
        if let near = references.first(where: { abs($0.rate - clamped) < snapDistance }) { return near.rate }
        return (clamped * 10).rounded() / 10
    }
}

/// Abonnement de dictée concurrent, au tarif public hors taxes, pour situer le coût de Wispad.
public struct SubscriptionReference: Identifiable, Equatable, Sendable {
    public var name: String
    public var plan: String
    /// Facturé au mois, hors taxes.
    public var monthlyUSD: Double
    /// Prix par mois en formule annuelle, hors taxes, s'il existe.
    public var yearlyMonthlyUSD: Double?
    public var url: URL

    public var id: String { name }

    /// Tarifs publics relevés le 16 octobre 2026.
    public static let checkedOn = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "Europe/Paris"),
                                                 year: 2026, month: 10, day: 16, hour: 12).date ?? Date(timeIntervalSince1970: 1_792_144_800)

    public static let all: [SubscriptionReference] = [
        SubscriptionReference(name: "Wispr Flow", plan: "Pro", monthlyUSD: 15, yearlyMonthlyUSD: 12,
                              url: URL(string: "https://wisprflow.ai/pricing")!),
        SubscriptionReference(name: "Willow Voice", plan: "Pro", monthlyUSD: 15, yearlyMonthlyUSD: 12,
                              url: URL(string: "https://willowvoice.com/pricing")!),
        SubscriptionReference(name: "Superwhisper", plan: "Pro", monthlyUSD: 8.49, yearlyMonthlyUSD: 84.99 / 12,
                              url: URL(string: "https://superwhisper.com/")!),
    ]
}
