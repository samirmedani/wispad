import Foundation
import Testing
@testable import WispadCore

struct JevUsageAccuracyTests {
    private let candidates = [CorrectionLearner.Candidate(heard: "fixture", corrected: "Fixture")]

    private func request(_ json: String) async -> ([Double]?, UsageEvent) {
        let data = Data(json.utf8)
        return await JevJudge.scores(candidates, dictated: "Fixture", key: "fixture-key") { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func validVerdictWithoutUsageKeepsCostUnknown() async {
        let (scores, event) = await request(#"{"answers":{"c0":{"noul":0.9}}}"#)
        #expect(scores == [0.9])
        #expect(event.succeeded)
        #expect(event.costUSD == nil)
    }

    @Test func emptyAndNegativeCountersNeverMeanFree() async {
        for usage in [#"{}"#, #"{"input_tokens":-1}"#] {
            let (_, event) = await request("{\"answers\":{\"c0\":{\"noul\":0.9}},\"usage\":\(usage)}")
            #expect(event.costUSD == nil)
        }
    }

    @Test func invalidVerdictPreservesKnownConsumption() async throws {
        let (scores, event) = await request(#"{"model":"jev-1.13.0","answers":{},"usage":{"input_tokens":500}}"#)
        #expect(scores == nil)
        #expect(!event.succeeded)
        #expect(event.tokens.input == 500)
        let cost = try #require(event.costUSD)
        #expect(abs(cost - 0.000021) < 1e-12)
    }

    @Test func explicitZeroIsAcceptedAsKnown() async {
        let (_, event) = await request(#"{"answers":{"c0":{"noul":0.9}},"usage":{"input_tokens":0}}"#)
        #expect(event.costUSD == 0)
    }

    @Test func booleanVerdictIsRejectedWithoutDroppingItsConsumption() async throws {
        for value in ["true", "false"] {
            let (scores, event) = await request("{\"answers\":{\"c0\":{\"noul\":\(value)}},\"usage\":{\"input_tokens\":500}}")
            #expect(scores == nil)
            #expect(!event.succeeded)
            #expect(event.tokens.input == 500)
            let cost = try #require(event.costUSD)
            #expect(abs(cost - 0.000021) < 1e-12)
        }
    }

    @Test func transportFailureDoesNotClaimFreeConsumption() async {
        let (scores, event) = await JevJudge.scores(candidates, dictated: "Fixture", key: "fixture-key") { _ in
            throw URLError(.timedOut)
        }
        #expect(scores == nil)
        #expect(!event.succeeded)
        #expect(event.costUSD == nil)
    }
}
