import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// La carte des bascules dit en clair ce qui s'est passé, à partir des seuls appels enregistrés.
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

    private func summary(_ events: [UsageEvent]) -> FallbackSummary {
        FallbackSummary.make(events: events, period: .all, now: now, calendar: calendar)
    }

    @Test func noFallbackSaysThePrimaryProvidersAlwaysAnswered() {
        let status = FallbackPresentation.status(summary([]))
        #expect(status.level == .clear)
        #expect(status.message == "Aucune bascule : tes fournisseurs principaux ont toujours répondu.")
    }

    @Test func successfulBackupsAreNormal() {
        let status = FallbackPresentation.status(summary([fallback(), fallback()]))
        #expect(status.level == .normal)
        #expect(status.message.hasPrefix("Le secours a pris le relais à chaque fois."))
    }

    @Test func aFailedBackupComesFirstAndCountsItsFailures() {
        let one = FallbackPresentation.status(summary([fallback(succeeded: false), fallback(reason: .servicePaused)]))
        #expect(one.level == .watch)
        #expect(one.message.hasPrefix("Le fournisseur de secours a lui aussi échoué 1 fois."))
        let two = FallbackPresentation.status(summary([fallback(succeeded: false), fallback(succeeded: false)]))
        #expect(two.message.hasPrefix("Le fournisseur de secours a lui aussi échoué 2 fois."))
    }

    @Test func aPausedPrimaryProviderIsWorthWatching() {
        let status = FallbackPresentation.status(summary([fallback(), fallback(reason: .servicePaused)]))
        #expect(status.level == .watch)
        #expect(status.message.contains("mis de côté"))
    }

    @Test func stagesShowTheirCountAndDirection() {
        let events = [
            fallback(), fallback(),
            fallback(from: .openAIFile, to: .xaiFile),
            fallback(from: .deepSeekCleanup, to: .openAICleanup, stage: .correction),
            fallback(from: .typesafeJudge, to: .xaiCleanup, stage: .dictionary),
            fallback(from: .xaiCleanup, to: .openAICleanup, stage: .correction)
        ]
        let result = summary(events)
        #expect(FallbackPresentation.times(result.count(for: .transcription)) == "3 fois")
        #expect(FallbackPresentation.times(1) == "1 fois")
        #expect(FallbackPresentation.count(1) == "1 bascule")
        #expect(FallbackPresentation.count(result.total) == "6 bascules")
        #expect(FallbackPresentation.routes(result, stage: .transcription) == "xAI → OpenAI (2), OpenAI → xAI (1)")
        #expect(FallbackPresentation.routes(result, stage: .dictionary) == "Jev → xAI")
        #expect(FallbackPresentation.routes(result, stage: .correction) == "DeepSeek → OpenAI (1), xAI → OpenAI (1)")
        for stage in FallbackStage.allCases { #expect(!FallbackPresentation.meaning(stage).isEmpty) }
    }

    @Test func recordedReasonsHaveShortWords() {
        #expect(FallbackPresentation.reason(.requestFailed) == "échec ou délai dépassé")
        #expect(FallbackPresentation.reason(.servicePaused) == "principal mis de côté")
    }

    @Test func trackingStartIsShownOnlyWhenThePeriodBeginsBeforeIt() {
        let recentStart = now.addingTimeInterval(-3_600)
        #expect(FallbackPresentation.trackingNoteDate(trackingStartedAt: recentStart, period: .all, now: now, calendar: calendar) == recentStart)
        #expect(FallbackPresentation.trackingNoteDate(trackingStartedAt: recentStart, period: .days7, now: now, calendar: calendar) == recentStart)
        let oldStart = now.addingTimeInterval(-86_400 * 60)
        #expect(FallbackPresentation.trackingNoteDate(trackingStartedAt: oldStart, period: .days30, now: now, calendar: calendar) == nil)
        #expect(FallbackPresentation.trackingNoteDate(trackingStartedAt: oldStart, period: .all, now: now, calendar: calendar) == oldStart)
    }
}
