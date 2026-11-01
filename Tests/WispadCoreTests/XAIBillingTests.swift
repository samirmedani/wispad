import Foundation
import Testing
@testable import WispadCore

/// Solde xAI lu avec la clé de gestion. Réponses relevées le 1er novembre 2026, identifiants retirés.
struct XAIBillingTests {
    private func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /// Aperçu du mois en cours : 8,43 $ de crédit au début du mois, de la voix pas encore facturée.
    private var preview: [String: Any] {
        object(#"""
        {"coreInvoice":{"lines":[
          {"description":"API Speech-to-Text","unitType":"Input audio seconds","unitPrice":"277778","numUnits":"51","amount":"0"},
          {"description":"API Speech-to-Text (WebSocket)","unitType":"Input audio seconds","unitPrice":"555556","numUnits":"3600","amount":"20"}],
          "prepaidCredits":{"val":"-843"},"prepaidCreditsUsed":{"val":"0"}},
         "billingCycle":{"year":2026,"month":11}}
        """#)
    }

    @Test func theCreditDeductsTheUsageNotYetInvoiced() throws {
        let cycle = try #require(XAIBilling.cycle(preview: preview))
        // 51 s de fichier (0,10 $/h) et une heure en direct (0,20 $/h), au prix exact plutôt qu'au centime arrondi.
        #expect(abs(cycle.spentUSD - (51 * 0.0000277778 + 0.2000002)) < 0.000001)
        #expect(abs(cycle.remainingUSD - (8.43 - cycle.spentUSD)) < 0.000001)
    }

    @Test func aPreviewWithoutCreditIsUnreadable() {
        #expect(XAIBilling.cycle(preview: object(#"{"coreInvoice":{"lines":[]}}"#)) == nil)
        #expect(XAIBilling.cycle(preview: [:]) == nil)
    }

    @Test func recentUsageAddsUpByKeyAndByService() {
        let usage = object(#"""
        {"timeSeries":[
          {"groupLabels":["wispad (xai-...vRwk)","API Speech-to-Text"],"dataPoints":[{"values":[1.46]}]},
          {"groupLabels":["wispad (xai-...vRwk)","API Speech-to-Text (WebSocket)"],"dataPoints":[{"values":[3.22]}]},
          {"groupLabels":["wispad-test (xai-...cs0Y)","API grok-4.7"],"dataPoints":[{"values":[1.34]}]},
          {"groupLabels":["wispad-test (xai-...cs0Y)","API Speech-to-Text"],"dataPoints":[{"values":[0.14]},{"values":[0.001]}]},
          {"groupLabels":["Rotate (xai-...xi5r)","API Text-to-Speech"],"dataPoints":[{"values":[0.001]}]}]}
        """#)
        let keys = XAIBilling.shares(usage: usage, level: 0)
        #expect(keys.map(\.name) == ["wispad", "wispad-test"])
        #expect(abs(keys[0].usd - 4.68) < 0.0001 && abs(keys[1].usd - 1.481) < 0.0001)
        let services = XAIBilling.shares(usage: usage, level: 1)
        #expect(services.map(\.name) == ["Speech-to-Text (WebSocket)", "Speech-to-Text", "grok-4.7"])
    }

    @Test func theLastPaidTopUpIsKeptFailuresAndSpendAreIgnored() throws {
        let balance = object(#"""
        {"changes":[
          {"changeOrigin":"PURCHASE","topupStatus":"FAILED_TO_CHARGE","amount":{"val":"-500"},"createTs":"2026-10-30T14:21:37.904802Z"},
          {"changeOrigin":"PURCHASE","topupStatus":"SUCCEEDED","amount":{"val":"-500"},"createTs":"2026-09-24T16:04:07.881313Z"},
          {"changeOrigin":"SPEND","amount":{"val":"3"},"createTs":"2026-10-31T10:10:28.686391Z"},
          {"changeOrigin":"AUTO_PURCHASE","topupStatus":"SUCCEEDED","amount":{"val":"-500"},"createTs":"2026-10-26T14:09:29.329752Z"}],
         "total":{"val":"-1497"}}
        """#)
        let topUp = try #require(XAIBilling.lastTopUp(balance: balance))
        #expect(topUp.automatic)
        #expect(topUp.usd == 5)
        #expect(topUp.date == XAIBilling.timestamp("2026-10-26T14:09:29Z"))
    }

    @Test func daysLeftFollowTheLastThirtyDays() {
        let billing = XAIBilling(remainingUSD: 8.4, cycleSpentUSD: 0,
                                 recentByKey: [XAIBilling.Share(name: "wispad", usd: 6.3)])
        #expect(billing.daysLeft == 40)
        #expect(XAIBilling(remainingUSD: 8.4, cycleSpentUSD: 0).daysLeft == nil)
    }
}
