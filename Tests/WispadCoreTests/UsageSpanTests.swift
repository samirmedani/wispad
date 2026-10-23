import Foundation
import Testing
@testable import WispadCore

/// Période « Tout » : durée d'utilisation, coût ramené au mois, taxe et abonnements de référence.
struct UsageSpanTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func theFirstDayCountsAsOneDay() {
        let span = UsageSpan.make(firstUse: date(2026, 10, 16, 9), now: date(2026, 10, 16, 23), calendar: calendar)
        #expect(span.days == 1)
        #expect(span.isUnderAMonth)
    }

    @Test func daysAreCountedFirstDayAndTodayIncludedAcrossTimeChanges() {
        let span = UsageSpan.make(firstUse: date(2026, 10, 1, 23), now: date(2026, 10, 16, 1), calendar: calendar)
        #expect(span.days == 16)
        #expect(span.isUnderAMonth)
        // Passage à l'heure d'été le 29 mars 2026 : un jour de 23 heures compte toujours pour un jour.
        #expect(UsageSpan.make(firstUse: date(2026, 3, 20), now: date(2026, 4, 5), calendar: calendar).days == 17)
    }

    @Test func beyondAMonthTheSpanSplitsIntoMonthsAndDays() {
        let span = UsageSpan.make(firstUse: date(2026, 9, 12), now: date(2026, 10, 16), calendar: calendar)
        #expect(!span.isUnderAMonth)
        #expect(span.days == 35)
        #expect(span.years == 0 && span.months == 1 && span.remainingDays == 5)
        let long = UsageSpan.make(firstUse: date(2025, 7, 16), now: date(2026, 10, 18), calendar: calendar)
        #expect(long.years == 1 && long.months == 3 && long.remainingDays == 3)
    }

    @Test func aFirstUseInTheFutureCountsAsToday() {
        let span = UsageSpan.make(firstUse: date(2026, 10, 19), now: date(2026, 10, 16), calendar: calendar)
        #expect(span.days == 1)
    }

    @Test func monthlyCostAveragesTheSpendOverTheDaysOfUse() {
        #expect(abs(MonthlyCost.perMonth(total: 1, days: 16) - 30.436875 / 16) < 1e-9)
        #expect(MonthlyCost.perMonth(total: 1, days: 0) == 0)
        #expect(abs(MonthlyCost.withTax(15, rate: 20) - 18) < 1e-9)
        #expect(MonthlyCost.withTax(15, rate: 0) == 15)
    }

    /// Chaque période se ramène à un mois sur ses propres jours, sans dépasser les jours d'utilisation.
    @Test func eachPeriodIsAveragedOverItsOwnDays() {
        #expect(MonthlyCost.days(for: .today, usedDays: 23) == 1)
        #expect(MonthlyCost.days(for: .days7, usedDays: 23) == 7)
        #expect(MonthlyCost.days(for: .days30, usedDays: 23) == 23)
        #expect(MonthlyCost.days(for: .days30, usedDays: 45) == 30)
        #expect(MonthlyCost.days(for: .days7, usedDays: 3) == 3)
        #expect(MonthlyCost.days(for: .all, usedDays: 23) == 23)
        #expect(MonthlyCost.days(for: .all, usedDays: 0) == 1)
    }

    @Test func theTaxSliderNamesTheClosestReferenceCountry() {
        #expect(SalesTax.closest(to: 0) == nil)
        #expect(SalesTax.closest(to: 20)?.region == "FR")
        #expect(SalesTax.closest(to: 8.1)?.region == "CH")
        #expect(SalesTax.closest(to: 25)?.region == "FI")
        // À égale distance de deux pays, le taux le plus bas.
        #expect(SalesTax.closest(to: 12.5)?.region == "JP")
        #expect(SalesTax.closest(to: 27)?.region == "FI")
    }

    @Test func theSliderSnapsToReferenceRatesAndStaysInRange() {
        #expect(SalesTax.snapped(19.8) == 20)
        #expect(SalesTax.snapped(8) == 8.1)
        #expect(SalesTax.snapped(12.34) == 12.3)
        #expect(SalesTax.snapped(-4) == 0)
        #expect(SalesTax.snapped(40) == 27)
        #expect(SalesTax.references.map(\.rate) == SalesTax.references.map(\.rate).sorted())
        #expect(SalesTax.references.allSatisfy { SalesTax.range.contains($0.rate) })
    }

    @Test func subscriptionsStartWithTheMainCompetitorAndYearlyPlansCostLess() {
        #expect(SubscriptionReference.all.first?.name == "Wispr Flow")
        for reference in SubscriptionReference.all {
            if let yearly = reference.yearlyMonthlyUSD { #expect(yearly < reference.monthlyUSD) }
        }
    }
}

