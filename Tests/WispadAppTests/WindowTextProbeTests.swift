import Testing
@testable import WispadApp

struct WindowTextProbeTests {
    @Test func diagnosticLinePrintsOnlyNumbers() {
        let line = WindowTextSnapshot(
            context: "Ne jamais imprimer ce texte Seedance",
            nodesVisited: 12,
            fragmentsKept: 3,
            characterCount: 48,
            candidateTermCount: 2,
            durationMilliseconds: 17,
            stoppedOnBudget: true
        ).diagnosticNumbers
        #expect(line == "12 3 48 2 17 1")
        #expect(line.allSatisfy { $0.isNumber || $0 == " " })
    }
}
