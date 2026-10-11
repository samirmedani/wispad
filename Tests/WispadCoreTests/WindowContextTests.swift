import Foundation
import Testing
@testable import WispadCore

struct WindowContextTests {
    private func fragment(
        _ text: String,
        role: String = "AXStaticText",
        focused: Bool = false,
        secure: Bool = false
    ) -> WindowTextFragment {
        WindowTextFragment(text: text, role: role, isFocusedField: focused, isSecure: secure)
    }

    @Test func focusedAndSecureFieldsAreLeftOut() {
        let text = WindowContext.assemble([
            fragment("MotDePasse9 secret du champ.", role: "AXTextField", secure: true),
            fragment("Brouillon ZX9000 encore dans le champ.", role: "AXTextArea", focused: true),
            fragment("On parle de Vercel dans le fil."),
        ])
        #expect(text == "On parle de Vercel dans le fil.")
        #expect(WindowContext.candidateTerms(in: text) == ["Vercel"])
    }

    @Test func interfaceLabelsTimestampsAndCountersAreLeftOut() {
        let text = WindowContext.assemble([
            fragment("Copier"),
            fragment("Envoyer."),
            fragment("Ouvrir le menu des options avancées", role: "AXMenuItem"),
            fragment("14:32"),
            fragment("2:05 PM"),
            fragment("il y a 3 min"),
            fragment("12"),
            fragment("(4)"),
            fragment("3 messages"),
            fragment("On corrige le déploiement Vercel ce soir."),
        ])
        #expect(text == "On corrige le déploiement Vercel ce soir.")
    }

    @Test func repeatedParentAndChildTextIsKeptOnce() {
        let text = WindowContext.assemble([
            fragment("On   déploie\tsur   Vercel demain."),
            fragment("Copier", role: "AXButton"),
            fragment("On déploie sur Vercel demain."),
            fragment("On déploie"),
            fragment("sur Vercel demain."),
            fragment("Le retour du modèle tient en une phrase."),
        ])
        #expect(text == "On déploie sur Vercel demain.\nLe retour du modèle tient en une phrase.")
    }

    @Test func tailFitsTheLimitWithoutCuttingAWord() {
        let text = WindowContext.assemble([
            fragment("ancien message trop long pour rester"),
            fragment("message récent conservé ici"),
        ], characterLimit: 40)
        #expect(text == "pour rester\nmessage récent conservé ici")
        #expect((text?.count ?? 0) <= 40)

        let tooSmall = WindowContext.assemble([
            fragment("Anticonstitutionnellement voilà."),
        ], characterLimit: 4)
        #expect(tooSmall == nil)
    }

    @Test func readingOrderIsPreserved() {
        let text = WindowContext.assemble([
            fragment("Première phrase du sujet en cours."),
            fragment("Deuxième phrase avec Seedance."),
            fragment("Troisième phrase en bas de fenêtre."),
        ])
        #expect(text == """
        Première phrase du sujet en cours.
        Deuxième phrase avec Seedance.
        Troisième phrase en bas de fenêtre.
        """)
    }

    @Test func emptyWindowYieldsNoContext() {
        #expect(WindowContext.assemble([]) == nil)
        #expect(WindowContext.assemble([
            fragment("   \n\t  "),
            fragment("secret", secure: true),
            fragment("brouillon du champ actif.", focused: true),
            fragment("OK", role: "AXButton"),
        ]) == nil)
    }

    @Test func defaultLimitKeepsTheEnd() {
        let stale = "Ancien paragraphe à oublier parce qu'il est tout en haut de la fenêtre visible."
        let recent = "Message récent avec Seedance tout en bas de la conversation visible."
        var fragments = [fragment(stale)]
        for index in 0..<80 {
            fragments.append(fragment("Remplissage \(index) du milieu de la conversation visible ici."))
        }
        fragments.append(fragment(recent))
        let text = WindowContext.assemble(fragments)
        #expect(text?.count ?? Int.max <= WindowContext.defaultCharacterLimit)
        #expect(WindowContext.defaultCharacterLimit == 2_000)
        #expect(text?.hasSuffix(recent) == true)
        #expect(text?.contains("Ancien paragraphe") == false)
    }

    @Test func candidateTermsComeFromTheKeptContext() {
        let text = WindowContext.assemble([
            fragment("Copier"),
            fragment("Je déploie sur Vercel avec OAuth2 et Seedance demain."),
        ])
        #expect(WindowContext.candidateTerms(in: text) == ["Vercel", "OAuth2", "Seedance"])
        #expect(WindowContext.candidateTerms(in: nil).isEmpty)
        #expect(WindowContext.candidateTerms(in: "").isEmpty)
    }
}

struct WindowTreeWalkTests {
    private struct Node {
        var id: String
        var children: [Node] = []
    }

    private func chain(_ ids: [String]) -> Node {
        var node = Node(id: ids[ids.count - 1])
        for id in ids.dropLast().reversed() {
            node = Node(id: id, children: [node])
        }
        return node
    }

    @Test func windowReadingBoundsMatchTheProbe() {
        #expect(WindowWalkLimits.windowReading.maxNodes == 4_000)
        #expect(WindowWalkLimits.windowReading.maxDepth == 60)
        #expect(WindowWalkLimits.windowReading.budget == .milliseconds(300))
    }

    @Test func walkStopsAfterTheNodeBudgetInDepthFirstOrder() {
        let root = Node(id: "a", children: [
            Node(id: "b", children: [Node(id: "d"), Node(id: "e")]),
            Node(id: "c"),
        ])
        let stopped = WindowTreeWalk.collect(
            root: root,
            limits: WindowWalkLimits(maxNodes: 3, maxDepth: 60, budget: .seconds(5)),
            children: { $0.children },
            value: { $0.id }
        )
        #expect(stopped.values == ["a", "b", "d"])
        #expect(stopped.nodesVisited == 3)
        #expect(stopped.stoppedOnBudget)

        let finished = WindowTreeWalk.collect(
            root: root,
            limits: WindowWalkLimits(maxNodes: 10, maxDepth: 60, budget: .seconds(5)),
            children: { $0.children },
            value: { $0.id }
        )
        #expect(finished.values == ["a", "b", "d", "e", "c"])
        #expect(finished.nodesVisited == 5)
        #expect(!finished.stoppedOnBudget)
    }

    @Test func walkDoesNotDescendBeyondTheDepthLimit() {
        let result = WindowTreeWalk.collect(
            root: chain(["0", "1", "2", "3", "4"]),
            limits: WindowWalkLimits(maxNodes: 100, maxDepth: 3, budget: .seconds(5)),
            children: { $0.children },
            value: { $0.id }
        )
        #expect(result.values == ["0", "1", "2"])
        #expect(result.nodesVisited == 3)
        #expect(!result.stoppedOnBudget)
    }

    @Test func walkStopsWhenTheTimeBudgetIsSpent() {
        let origin = ContinuousClock.now
        var ticks = 0
        let result = WindowTreeWalk.collect(
            root: chain(["a", "b", "c", "d"]),
            limits: WindowWalkLimits(maxNodes: 100, maxDepth: 60, budget: .milliseconds(300)),
            now: {
                ticks += 1
                return ticks <= 3 ? origin : origin.advanced(by: .milliseconds(300))
            },
            children: { $0.children },
            value: { $0.id }
        )
        #expect(result.values == ["a", "b"])
        #expect(result.nodesVisited == 2)
        #expect(result.stoppedOnBudget)
    }
}
