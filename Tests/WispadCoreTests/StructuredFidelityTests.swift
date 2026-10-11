import Foundation
import Testing
@testable import WispadCore

struct StructuredFidelityTests {
    private let items = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa"]

    @Test(arguments: ["-", "•", "*"])
    func shortListMarkersDoNotLookLikeInventedWords(marker: String) {
        let raw = items.joined(separator: " ")
        let list = items.map { "\(marker) \($0)" }.joined(separator: "\n")
        #expect(FidelityGuard.check(transcript: raw, corrected: list, context: nil) == list)
    }

    @Test(arguments: [".", ")"])
    func shortNumberedListDoesNotLookLikeInventedWords(suffix: String) {
        let raw = items.joined(separator: " ")
        let list = items.enumerated().map { "\($0.offset + 1)\(suffix) \($0.element)" }.joined(separator: "\n")
        #expect(FidelityGuard.check(transcript: raw, corrected: list, context: nil) == list)
    }

    @Test func numericContentRemainsInTheList() {
        let raw = "Prix 12.50 € Stock 25 Date 2026-10-03 Référence i5-13600K Valeur -12"
        let list = "- Prix 12.50 €\n- Stock 25\n- Date 2026-10-03\n- Référence i5-13600K\n- Valeur -12"
        #expect(FidelityGuard.check(transcript: raw, corrected: list, context: nil) == list)
    }

    @Test func genuineAddedWordsStillTriggerTheExistingLimit() {
        let raw = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
        let list = items.map { "- \($0)" }.joined(separator: "\n") + "\n\nDes détails totalement inventés par le modèle."
        #expect(FidelityGuard.check(transcript: raw, corrected: list, context: nil) == raw)
    }

    @Test func contextCopyStillFailsAfterFormattingChanges() {
        let raw = "alpha beta gamma delta epsilon zeta eta theta iota kappa lundi mardi mercredi jeudi vendredi samedi dimanche"
        let context = "Un fournisseur extérieur possède une archive personnelle complète."
        let copied = "- alpha\n- Un fournisseur extérieur possède une archive personnelle complète."
        #expect(FidelityGuard.check(transcript: raw, corrected: copied, context: context) == raw)
    }

    @Test func translatedTermsAreRestoredWithoutFlatteningParagraphsOrLists() {
        let raw = "Introduction.\nLes outils.\nLes réglages.\nLe débit.\nConclusion."
        let corrected = "Introduction.\n\n  - Les tools.\n\t• Les settings.\n\t* Le throughput.\n\nConclusion."
        let expected = "Introduction.\n\n  - Les outils.\n\t• Les réglages.\n\t* Le débit.\n\nConclusion."
        #expect(FidelityGuard.check(transcript: raw, corrected: corrected, context: nil) == expected)
    }

    @Test func adjacentTranslatedTermsRetainEverySeparator() {
        let corrected = "\t1) tools\r\n  2) settings"
        let expected = "\t1) outils\r\n  2) réglages"
        #expect(FidelityGuard.check(transcript: "outils réglages", corrected: corrected, context: nil) == expected)
    }

    @Test func translatedTermsKeepTheirOriginalPunctuation() {
        let raw = "Les «outils», puis (les réglages)."
        let corrected = "- Les «tools», puis (les settings)."
        let expected = "- Les «outils», puis (les réglages)."
        #expect(FidelityGuard.check(transcript: raw, corrected: corrected, context: nil) == expected)
    }

    @Test func punctuationAddedToANeighborDoesNotMaskATranslation() {
        let raw = "L'agent sélectionne le bon tool. Ensuite il vérifie le build. On publie demain."
        let corrected = "- L'agent sélectionne le bon outil.\n- Ensuite, il vérifie le build.\n\nOn publie demain."
        let expected = "- L'agent sélectionne le bon tool.\n- Ensuite, il vérifie le build.\n\nOn publie demain."
        #expect(FidelityGuard.check(transcript: raw, corrected: corrected, context: nil) == expected)
    }

    @Test func similarHearingCorrectionsKeepTheExistingThreshold() {
        let raw = "La latence est faible."
        let corrected = "- La latency est faible."
        // Ce couple phonétiquement proche ne prouve pas assez une traduction avec le seuil existant.
        #expect(FidelityGuard.check(transcript: raw, corrected: corrected, context: nil) == corrected)
    }

    @Test func changedWordCountWithinOneLineKeepsSurroundingStructure() {
        let corrected = "Introduction.\n\n\t• Les environment variables.\n\nConclusion."
        let expected = "Introduction.\n\n\t• Les outils.\n\nConclusion."
        #expect(FidelityGuard.check(transcript: "Introduction. Les outils. Conclusion.", corrected: corrected, context: nil) == expected)
    }

    @Test func unchangedTextIsReturnedVerbatim() {
        let corrected = "Intro.\r\n\r\n  - OAuth 2.0\n\t- https://example.test/api?q=1\n\nFin.  "
        #expect(FidelityGuard.check(transcript: corrected, corrected: corrected, context: nil) == corrected)
    }

    @Test func minusSignsAndDecimalNumbersRemainSignificant() {
        let raw = "-12 -24 3.14"
        let corrected = "-12 -24 3.14 alpha beta gamma delta epsilon"
        #expect(FidelityGuard.check(transcript: raw, corrected: corrected, context: nil) == raw)
        let list = "- -12\n- -24\n- 3.14"
        #expect(FidelityGuard.check(transcript: raw, corrected: list, context: nil) == list)
    }

    @Test func translationRepairNeverRewritesAnAdjacentNumericToken() {
        let corrected = "- tools -24"
        let result = FidelityGuard.check(transcript: "outils -12", corrected: corrected, context: nil)
        #expect(result.hasSuffix(" -24"))
        #expect(!result.contains("--24"))
        #expect(!result.hasSuffix(" 12"))
    }

    @Test func fencedCodeMarkersAreNotPresentation() {
        let raw = "```text\n-\talpha\n-\tbeta\n```"
        // Ces marqueurs appartiennent au code : ils restent présents, avec les tabulations.
        #expect(FidelityGuard.check(transcript: raw, corrected: raw, context: nil) == raw)
        let corrected = raw + "\nextra1 extra2 extra3 extra4 extra5"
        #expect(FidelityGuard.check(transcript: raw, corrected: corrected, context: nil) == raw)
        let tildeCode = "~~~text\n1) alpha\n2) beta\n~~~"
        #expect(FidelityGuard.check(transcript: tildeCode, corrected: tildeCode, context: nil) == tildeCode)
    }
}
