import Foundation
import XCTest
@testable import WispadCore

final class UsagePricingAccuracyTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")!

    func testMissingAndIncompleteUsageDoesNotInventZeroCounters() {
        XCTAssertNil(TokenUsage.parse(nil))
        let incompleteUsage: [[String: Any]] = [
            [:], ["prompt_tokens": 10], ["completion_tokens": 5],
            ["total_tokens": 15], ["prompt_tokens": NSNull(), "completion_tokens": 5],
            ["prompt_tokens": 10, "completion_tokens": NSNull()]
        ]
        for incomplete in incompleteUsage {
            XCTAssertNil(TokenUsage.parse(incomplete))
        }
        XCTAssertEqual(TokenUsage.parse(["prompt_tokens": 0, "completion_tokens": 0]), TokenUsage())
    }

    func testValidUsageSeparatesCacheAndOptionalCacheDefaultsToZero() {
        XCTAssertEqual(
            TokenUsage.parse(["prompt_tokens": 100, "completion_tokens": 10]),
            TokenUsage(input: 100, output: 10)
        )
        XCTAssertEqual(
            TokenUsage.parse(["prompt_tokens": 100, "completion_tokens": 10, "prompt_cache_hit_tokens": 75]),
            TokenUsage(input: 25, cachedInput: 75, output: 10)
        )
        XCTAssertEqual(
            TokenUsage.parse(["prompt_tokens": 100, "completion_tokens": 10, "prompt_tokens_details": ["cached_tokens": 100]]),
            TokenUsage(input: 0, cachedInput: 100, output: 10)
        )
    }

    func testInvalidCountersAndCacheCannotProduceAnEstimatedCost() throws {
        let invalid: [Any] = [-1, 1.5, true, "10", NSNull(), Double.infinity, NSNumber(value: UInt64.max)]
        for value in invalid {
            XCTAssertNil(TokenUsage.parse(["prompt_tokens": value, "completion_tokens": 5]))
            XCTAssertNil(TokenUsage.parse(["prompt_tokens": 10, "completion_tokens": value]))
            XCTAssertNil(TokenUsage.parse(["prompt_tokens": 10, "completion_tokens": 5, "prompt_cache_hit_tokens": value]))
        }
        XCTAssertNil(TokenUsage.parse(["prompt_tokens": 10, "completion_tokens": 5, "prompt_cache_hit_tokens": 11]))
        XCTAssertNil(TokenUsage.parse(["prompt_tokens": 10, "completion_tokens": 5, "prompt_tokens_details": ["cached_tokens": 11]]))
        // Les booléens de JSONSerialization sont des NSNumber, et doivent rester refusés.
        let object = try JSONSerialization.jsonObject(with: Data(#"{"prompt_tokens":true,"completion_tokens":5}"#.utf8)) as! [String: Any]
        XCTAssertNil(TokenUsage.parse(object))
        XCTAssertEqual(TokenUsage.nonnegativeInteger(NSNumber(value: Int.max)), Int.max)
    }

    func testFailedAudioAttemptHasUnknownCostAndSummaryStaysIncomplete() {
        let failed = UsageEvent.transcription(
            provider: .xai, streaming: true, model: "grok-voice-transcribe-2.0",
            audioSeconds: 60, succeeded: false, at: date
        )
        XCTAssertNil(failed.costUSD)
        let summary = UsageSummary.make(events: [failed], period: .all, now: date)
        XCTAssertTrue(summary.hasUnpricedCalls)
        XCTAssertTrue(summary.rows.first!.hasUnpricedCalls)
        XCTAssertEqual(summary.rows.first!.failures, 1)
    }

    func testInvalidAudioDurationsAreUnknownRatherThanFreeOrNonfinite() {
        for duration in [-1.0, Double.nan, Double.infinity] {
            XCTAssertNil(Pricing.audioCost(provider: .xai, model: "grok-voice-transcribe-2.0", streaming: true, seconds: duration))
        }
        XCTAssertEqual(Pricing.audioCost(provider: .xai, model: "grok-voice-transcribe-2.0", streaming: true, seconds: 0), 0)
    }

    func testConfiguredLunaAndVersionedMiniUsePublishedRates() {
        let luna = Pricing.tokenRate(model: "gpt-5.6-luna", at: date)
        XCTAssertEqual(luna?.input, 0.20)
        XCTAssertEqual(luna?.cachedInput, 0.02)
        XCTAssertEqual(luna?.output, 1.20)
        XCTAssertEqual(
            Pricing.tokenCost(model: "gpt-5.6-luna", tokens: TokenUsage(input: 2_000, cachedInput: 1_000, output: 500), at: date)!,
            0.00102, accuracy: 1e-12
        )
        XCTAssertEqual(
            Pricing.tokenRate(model: "gpt-5.4-mini-2026-03-17", at: date),
            Pricing.tokenRate(model: CleanupModel.openAIFallback, at: date)
        )
        XCTAssertNil(Pricing.tokenRate(model: "gpt-5.4-mini-2099-01-01", at: date))
    }

    func testLunaLongContextIncludesCachedInputAndKeepsThresholdStrict() {
        let atThreshold = TokenUsage(input: 200_000, cachedInput: 72_000, output: 10_000)
        let aboveThreshold = TokenUsage(input: 200_001, cachedInput: 72_000, output: 10_000)
        XCTAssertEqual(
            Pricing.tokenCost(model: "gpt-5.6-luna", tokens: atThreshold, at: date)!,
            0.05344, accuracy: 1e-12
        )
        XCTAssertEqual(
            Pricing.tokenCost(model: "gpt-5.6-luna", tokens: aboveThreshold, at: date)!,
            0.1008804, accuracy: 1e-12
        )
    }

    func testGrokLongContextIncludesCacheAndStartsAtTwoHundredThousand() {
        for model in ["grok-4.7", "grok-4.6"] {
            XCTAssertEqual(
                Pricing.tokenCost(model: model, tokens: TokenUsage(input: 199_999, output: 1_000), at: date)!,
                0.405998, accuracy: 1e-12
            )
            XCTAssertEqual(
                Pricing.tokenCost(model: model, tokens: TokenUsage(input: 100_000, cachedInput: 100_000, output: 1_000), at: date)!,
                0.512, accuracy: 1e-12
            )
        }
    }

    func testTokenCostRejectsNegativeCountersAndDoesNotOverflowTheirSum() {
        for usage in [TokenUsage(input: -1), TokenUsage(cachedInput: -1), TokenUsage(output: -1)] {
            XCTAssertNil(Pricing.tokenCost(model: "grok-4.7", tokens: usage, at: date))
        }
        let veryLarge = TokenUsage(input: Int.max, cachedInput: Int.max, output: Int.max)
        let cost = Pricing.tokenCost(model: "grok-4.7", tokens: veryLarge, at: date)!
        XCTAssertTrue(cost.isFinite)
        XCTAssertGreaterThan(cost, 0)
        XCTAssertEqual(cost, Double(Int.max) * 17 / 1_000_000, accuracy: 0.1)
    }

    func testAllThirtyThreeOfficialHolidayDaysAreOffPeak() {
        let ranges = [(1, 1...3), (2, 15...23), (4, 4...6), (5, 1...5), (6, 19...21), (9, 25...27), (10, 1...7)]
        var checked = 0
        for (month, days) in ranges {
            for day in days {
                let instant = utc(String(format: "2026-%02d-%02dT08:00:00Z", month, day))
                XCTAssertEqual(ChinesePublicHolidays.isHoliday(instant), true)
                XCTAssertEqual(Pricing.deepSeekPeakStatus(instant), false)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 33)
        XCTAssertEqual(Pricing.deepSeekPeakStatus(utc("2026-01-05T08:00:00Z")), true)
        XCTAssertEqual(Pricing.deepSeekPeakStatus(utc("2026-02-24T08:00:00Z")), true)
        XCTAssertEqual(Pricing.deepSeekPeakStatus(utc("2026-10-08T08:00:00Z")), true)
    }

    func testDeepSeekHolidayPriceIsHalfAnOrdinaryWeekdayPeak() {
        let tokens = TokenUsage(input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(
            Pricing.tokenCost(model: CleanupModel.deepSeek, tokens: tokens, at: utc("2026-10-01T08:00:00Z"))!,
            0.75, accuracy: 1e-12
        )
        XCTAssertEqual(
            Pricing.tokenCost(model: CleanupModel.deepSeek, tokens: tokens, at: utc("2026-09-30T08:00:00Z"))!,
            1.5, accuracy: 1e-12
        )
    }

    func testDeepSeekPeakWindowBoundariesStayExactInUTC() {
        for time in ["01:00:00", "03:59:59", "06:00:00", "09:59:59"] {
            XCTAssertEqual(Pricing.deepSeekPeakStatus(utc("2026-09-30T\(time)Z")), true)
        }
        for time in ["00:59:59", "04:00:00", "05:59:59", "10:00:00"] {
            XCTAssertEqual(Pricing.deepSeekPeakStatus(utc("2026-09-30T\(time)Z")), false)
        }
    }

    func testHolidayDayChangesAtBeijingMidnight() {
        XCTAssertEqual(ChinesePublicHolidays.isHoliday(utc("2026-09-24T15:59:59Z")), false)
        XCTAssertEqual(ChinesePublicHolidays.isHoliday(utc("2026-09-24T16:00:00Z")), true)
        XCTAssertEqual(ChinesePublicHolidays.isHoliday(utc("2026-10-07T15:59:59Z")), true)
        XCTAssertEqual(ChinesePublicHolidays.isHoliday(utc("2026-10-07T16:00:00Z")), false)
    }

    func testCompensatoryWorkingWeekendsStillUseOffPeakRates() {
        for day in ["2026-01-04", "2026-02-14", "2026-02-28", "2026-05-09", "2026-09-20", "2026-10-10"] {
            XCTAssertEqual(Pricing.deepSeekPeakStatus(utc("\(day)T08:00:00Z")), false)
        }
    }

    func testUncoveredYearsAreUnknownOnlyWhereAHolidayCouldChangePricing() {
        let potentialPeak = utc("2027-01-04T08:00:00Z")
        XCTAssertNil(ChinesePublicHolidays.isHoliday(potentialPeak))
        XCTAssertNil(Pricing.deepSeekPeakStatus(potentialPeak))
        XCTAssertNil(Pricing.tokenRate(model: CleanupModel.deepSeek, at: potentialPeak))
        XCTAssertNil(Pricing.tokenCost(model: CleanupModel.deepSeek, tokens: TokenUsage(input: 100), at: potentialPeak))
        XCTAssertFalse(Pricing.isDeepSeekPeak(potentialPeak))
        XCTAssertEqual(Pricing.deepSeekPeakStatus(utc("2027-01-03T08:00:00Z")), false)
        XCTAssertEqual(Pricing.deepSeekPeakStatus(utc("2027-01-04T12:00:00Z")), false)
        XCTAssertNotNil(Pricing.tokenRate(model: CleanupModel.deepSeek, at: utc("2027-01-04T12:00:00Z")))
        XCTAssertNil(Pricing.deepSeekPeakStatus(utc("2025-12-31T08:00:00Z")))
    }

    private func utc(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
