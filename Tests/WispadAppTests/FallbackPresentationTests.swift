import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// La carte des relais dit en clair ce qui s'est passé, à partir des seuls appels enregistrés : combien de demandes le
/// relais a sauvées, vers quel service, pourquoi et quand.
@MainActor
struct FallbackPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_791_028_800)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func fallback(from: UsageAPI = .xaiFile, to: UsageAPI = .openAIFile, stage: FallbackStage = .transcription,
                          reason: FallbackReason = .requestFailed, succeeded: Bool = true) -> UsageEvent {
        UsageEvent(createdAt: now, api: to, model: "fixture", costUSD: 0, succeeded: succeeded,
                   fallback: APIFallback(fromAPI: from, stage: stage, reason: reason))
    }

    private func failure(_ api: UsageAPI = .deepSeekCleanup, cause: APIFailureCause = .timeout, at offset: TimeInterval = 0) -> UsageEvent {
        UsageEvent(createdAt: now.addingTimeInterval(offset), api: api, model: "fixture", costUSD: nil, succeeded: false,
                   failureCause: cause)
    }

    private func summary(_ events: [UsageEvent]) -> FallbackSummary {
        FallbackSummary.make(events: events, period: .all, now: now, calendar: calendar)
    }

    private func breakdown(_ events: [UsageEvent]) -> FailureBreakdown {
        FailureBreakdown.make(events: events, period: .all, now: now, calendar: calendar)
    }

    @Test func noRelayAndNoFailureMeansNothingWasNeeded() {
        let status = FallbackPresentation.status(summary([]), failures: breakdown([]))
        #expect(status.level == .clear)
        #expect(status.title == "Aucun relais nécessaire")
        #expect(status.message == "Tes services principaux ont toujours répondu.")
    }

    @Test func failuresWithoutRelaySayNoOtherServiceTookOver() {
        let failed = [failure(), failure(.xaiFile, cause: .serverError)]
        let status = FallbackPresentation.status(summary(failed), failures: breakdown(failed))
        #expect(status.level == .watch)
        #expect(status.title == "2 appels en échec, sans relais")
        #expect(status.message.hasPrefix("Aucun autre service n'a pris la suite."))
        // Sans internet, aucun relais n'aurait pu aider : la phrase le dit.
        let offline = [failure(cause: .offline)]
        let alone = FallbackPresentation.status(summary(offline), failures: breakdown(offline))
        #expect(alone.title == "1 appel en échec, sans relais")
        #expect(alone.message.hasPrefix("Ce Mac n'avait pas internet"))
    }

    @Test func successfulRelaysCountTheSavedRequests() {
        let status = FallbackPresentation.status(summary([fallback(), fallback()]))
        #expect(status.level == .normal)
        #expect(status.title == "2 demandes sauvées par le relais")
        #expect(status.message.hasPrefix("Un relais de temps en temps, c'est normal."))
        #expect(FallbackPresentation.status(summary([fallback()])).title == "1 demande sauvée par le relais")
    }

    @Test func aFailedRelayComesFirstAndCountsWhatWasSaved() {
        let one = FallbackPresentation.status(summary([fallback(succeeded: false), fallback(reason: .servicePaused)]))
        #expect(one.level == .watch)
        #expect(one.title == "1 demande sauvée sur 2")
        #expect(one.message.hasPrefix("1 fois, le relais a échoué lui aussi"))
        let two = FallbackPresentation.status(summary([fallback(succeeded: false), fallback(succeeded: false)]))
        #expect(two.title == "Aucune demande sauvée sur 2")
        #expect(two.message.hasPrefix("2 fois, le relais a échoué lui aussi"))
    }

    @Test func aPausedPrimaryServiceIsWorthWatching() {
        let status = FallbackPresentation.status(summary([fallback(), fallback(reason: .servicePaused)]))
        #expect(status.level == .watch)
        #expect(status.message.contains("mis de côté"))
    }

    @Test func eachRouteSaysItsStageAndOutcome() {
        let result = summary([
            fallback(), fallback(), fallback(from: .openAIFile, to: .xaiFile),
            fallback(from: .deepSeekCleanup, to: .openAICleanup, stage: .correction, succeeded: false),
            fallback(from: .deepSeekCleanup, to: .openAICleanup, stage: .correction),
            fallback(from: .typesafeJudge, to: .xaiCleanup, stage: .dictionary)
        ])
        let outcomes = Dictionary(uniqueKeysWithValues: result.routes.map { ($0.id, FallbackPresentation.outcome($0)) })
        #expect(outcomes["transcription:xAI:OpenAI"] == "2 fois · tous réussis")
        #expect(outcomes["transcription:OpenAI:xAI"] == "1 fois · réussi")
        #expect(outcomes["correction:DeepSeek:OpenAI"] == "2 fois · 1 en échec")
        #expect(FallbackPresentation.route(from: "TypeSafe", to: "xAI") == "Jev → xAI")
        #expect(FallbackStage.allCases.map(FallbackPresentation.stageName) == ["Voix", "Correction", "Dictionnaire"])
        for stage in FallbackStage.allCases { #expect(!FallbackPresentation.meaning(stage).isEmpty) }
        #expect(FallbackPresentation.recentCaption(shown: 5, total: 12) == "les 5 plus récents sur 12")
        #expect(FallbackPresentation.recentCaption(shown: 3, total: 3) == nil)
    }

    @Test func recordedReasonsHaveShortWords() {
        #expect(FallbackPresentation.reason(.requestFailed) == "échec ou délai dépassé")
        #expect(FallbackPresentation.reason(.servicePaused) == "principal mis de côté")
    }

    @Test func whyNamesTheMostFrequentCauseAndThePausedServices() {
        // Un appel réussi juste à côté : les délais comptent pour le fournisseur, pas pour la connexion.
        let success = UsageEvent(createdAt: now, api: .xaiStreaming, model: "fixture", costUSD: 0)
        let events = [success, failure(at: -1), failure(at: -2), failure(.xaiFile, cause: .offline),
                      fallback(from: .deepSeekCleanup, to: .openAICleanup, stage: .correction, reason: .servicePaused)]
        let result = breakdown(events)
        #expect(FailurePresentation.topCause(result) == "Le plus souvent : DeepSeek, pas de réponse à temps (2 fois).")
        #expect(FailurePresentation.pausedLines(result) == ["DeepSeek a été mis de côté 1 fois après des échecs répétés : le relais a répondu directement."])
        #expect(FailurePresentation.hasDetails(result))
        #expect(FailurePresentation.shownSides(result) == [.connection, .provider])
        let single = breakdown([success, failure(.typesafeJudge, cause: .keyRejected)])
        #expect(FailurePresentation.topCause(single) == "Jev : clé refusée.")
        #expect(FailurePresentation.shownSides(single) == [.connection, .provider, .account])
        #expect(FailurePresentation.topCause(breakdown([success])) == nil)
        #expect(!FailurePresentation.hasDetails(breakdown([success])))
    }

    @Test func trackingStartIsShownOnlyWhenThePeriodBeginsBeforeIt() {
        let recentStart = now.addingTimeInterval(-3_600)
        #expect(FallbackPresentation.trackingNoteDate(trackingStartedAt: recentStart, period: .all, now: now, calendar: calendar) == recentStart)
        #expect(FallbackPresentation.trackingNoteDate(trackingStartedAt: recentStart, period: .days7, now: now, calendar: calendar) == recentStart)
        let oldStart = now.addingTimeInterval(-86_400 * 60)
        #expect(FallbackPresentation.trackingNoteDate(trackingStartedAt: oldStart, period: .days30, now: now, calendar: calendar) == nil)
        #expect(FallbackPresentation.trackingNoteDate(trackingStartedAt: oldStart, period: .all, now: now, calendar: calendar) == oldStart)
    }

    @Test func trackingNotesMergeWhenBothStartedTheSameDay() {
        let sameDay = FallbackPresentation.trackingNotes(relays: now, causes: now.addingTimeInterval(60), calendar: calendar)
        #expect(sameDay.count == 1)
        #expect(sameDay.first?.hasPrefix("Relais et causes des échecs notés depuis le ") == true)
        let apart = FallbackPresentation.trackingNotes(relays: now.addingTimeInterval(-86_400 * 3), causes: now, calendar: calendar)
        #expect(apart.count == 2)
        #expect(FallbackPresentation.trackingNotes(relays: nil, causes: nil, calendar: calendar).isEmpty)
    }
}
