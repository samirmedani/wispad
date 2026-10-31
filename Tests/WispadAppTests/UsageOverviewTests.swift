import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// En tête de Consommation : la part de chaque fournisseur et la phrase qui résume la période restent exactes.
@MainActor
struct UsageOverviewTests {
    private let now = Date(timeIntervalSince1970: 1_793_450_401)

    private func call(_ api: UsageAPI, cost: Double?, succeeded: Bool = true, cause: APIFailureCause? = nil,
                      fallback: APIFallback? = nil) -> UsageEvent {
        UsageEvent(createdAt: now, api: api, model: "fixture", costUSD: cost, succeeded: succeeded, fallback: fallback,
                   failureCause: cause)
    }

    private func relay(succeeded: Bool = true, reason: FallbackReason = .requestFailed) -> UsageEvent {
        call(.openAIFile, cost: succeeded ? 0.001 : nil, succeeded: succeeded, cause: succeeded ? nil : .timeout,
             fallback: APIFallback(fromAPI: .xaiFile, stage: .transcription, reason: reason))
    }

    private func fallbacks(_ events: [UsageEvent]) -> FallbackSummary {
        FallbackSummary.make(events: events, period: .all, now: now)
    }

    @Test func eachProviderShowsWhatItDidItsAmountAndItsShare() {
        let events = [
            call(.xaiStreaming, cost: 0.02), call(.xaiCleanup, cost: 0.005),
            call(.openAICleanup, cost: 0.03),
            call(.deepSeekCleanup, cost: nil),
            call(.typesafeJudge, cost: 0.001)
        ]
        let summary = UsageSummary.make(events: events, period: .all, now: now)
        let shares = UsagePresentation.providerShares(summary)
        #expect(shares.map(\.name) == ["OpenAI", "xAI", "Jev", "DeepSeek"])
        #expect(shares.map(\.tasks) == ["correction", "voix, correction", "dictionnaire", "correction"])
        #expect(abs(shares.reduce(0) { $0 + $1.fraction } - 1) < 1e-9)
        #expect(shares[1].amount == MoneyFormat.usd(0.025))
        // Un coût inconnu fait du montant un minimum, et seulement pour ce fournisseur.
        #expect(shares[3].amount == "≥ " + MoneyFormat.usd(0))
        #expect(!shares[0].amount.hasPrefix("≥"))
        #expect(shares[2].percent == UsagePresentation.percent(0.001 / 0.056))
        #expect(UsagePresentation.percent(0.001).hasPrefix("< "))
        // Consommation qui n'a pas pu être relue : tout devient un minimum.
        #expect(UsagePresentation.providerShares(summary, storageIncomplete: true).allSatisfy { $0.amount.hasPrefix("≥ ") })
    }

    @Test func nothingSpentShowsNoShare() {
        let summary = UsageSummary.make(events: [call(.localCleanup, cost: 0)], period: .all, now: now)
        let shares = UsagePresentation.providerShares(summary)
        #expect(shares.map(\.name) == ["Modèle local"])
        #expect(shares.first?.fraction == 0)
        #expect(shares.first?.percent == "")
    }

    @Test func theSummarySentenceCountsFailuresAndWhatTheRelayCaught() {
        let calm = [call(.xaiStreaming, cost: 0.01), call(.deepSeekCleanup, cost: 0.01)]
        #expect(UsagePresentation.health(events: calm, fallbacks: fallbacks(calm)) ==
            .init(level: .clear, message: "Tous les appels ont abouti."))
        #expect(UsagePresentation.health(events: [calm[0]], fallbacks: fallbacks([calm[0]])).message == "L'appel a abouti.")

        // Une dictée annulée n'est pas un échec.
        let cancelled = calm + [call(.xaiStreaming, cost: nil, succeeded: false, cause: .cancelled)]
        #expect(UsagePresentation.health(events: cancelled, fallbacks: fallbacks(cancelled)).message == "Tous les appels ont abouti.")

        let caught = [call(.xaiFile, cost: nil, succeeded: false, cause: .timeout), relay()]
        #expect(UsagePresentation.health(events: caught, fallbacks: fallbacks(caught)) ==
            .init(level: .normal, message: "1 appel n'a pas abouti. Le relais a pris la suite, avec succès."))

        let alone = [call(.xaiFile, cost: nil, succeeded: false, cause: .timeout), call(.deepSeekCleanup, cost: nil, succeeded: false, cause: .serverError)]
        #expect(UsagePresentation.health(events: alone, fallbacks: fallbacks(alone)) ==
            .init(level: .watch, message: "2 appels n'ont pas abouti. Aucun relais n'a pris la suite."))

        let mixed = [call(.xaiFile, cost: nil, succeeded: false, cause: .timeout), relay(), relay(succeeded: false)]
        #expect(UsagePresentation.health(events: mixed, fallbacks: fallbacks(mixed)) ==
            .init(level: .watch, message: "2 appels n'ont pas abouti. Le relais a réussi 1 fois sur 2."))

        // Service mis de côté : le relais répond directement, sans échec sur la période.
        let paused = [relay(reason: .servicePaused)]
        #expect(UsagePresentation.health(events: paused, fallbacks: fallbacks(paused)) ==
            .init(level: .normal, message: "Tous les appels ont abouti, dont 1 grâce au relais."))
    }

    @Test func aMinimumAlwaysSaysWhy() {
        #expect(UsagePresentation.minimumNote(unknownCosts: 0, storageIncomplete: false) == nil)
        #expect(UsagePresentation.minimumNote(unknownCosts: 1, storageIncomplete: false) == "≥ veut dire « au moins » : le coût d'un appel est inconnu.")
        #expect(UsagePresentation.minimumNote(unknownCosts: 9, storageIncomplete: false) == "≥ veut dire « au moins » : le coût de 9 appels est inconnu.")
        #expect(UsagePresentation.minimumNote(unknownCosts: 0, storageIncomplete: true)?.contains("n'a pas pu être relue") == true)
        #expect(UsagePresentation.chartNote(unknownCosts: 2, storageIncomplete: false) == "Sans les 2 appels au coût inconnu.")
        #expect(UsagePresentation.callsCaption(0, period: .today) == "Aucun appel aujourd'hui : rien à payer.")
        #expect(UsagePresentation.callsCaption(1, period: .all) == "1 appel aux services de dictée")
    }

    @Test func chartTitlesNameTheirBars() {
        #expect(UsagePresentation.chartTitle(.hour) == "Dépense par heure")
        #expect(UsagePresentation.chartTitle(.day) == "Dépense par jour")
        #expect(UsagePresentation.chartTitle(.weekOfYear) == "Dépense par semaine")
        #expect(UsagePresentation.chartTitle(.month) == "Dépense par mois")
    }
}
