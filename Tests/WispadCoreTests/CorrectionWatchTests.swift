import Testing
@testable import WispadCore

struct CorrectionWatchTests {
    private let inserted = "J'ai testé Sidance hier soir."
    private let corrected = "J'ai testé Seedance hier soir."

    private func sample(_ value: String?, sameElement: Bool = true, sameApplication: Bool = true) -> CorrectionWatch.FocusSample {
        CorrectionWatch.FocusSample(sameApplication: sameApplication, sameElement: sameElement, value: value)
    }

    private func outcome(of step: CorrectionWatch.Step) -> CorrectionWatch.Outcome? {
        if case .stop(let outcome) = step { return outcome }
        return nil
    }

    /// Le champ reste sans la dictée pendant toute la marge : la surveillance conclut à l'envoi.
    private func settle(_ watch: inout CorrectionWatch, on value: String?) -> CorrectionWatch.Outcome? {
        for _ in 1..<CorrectionWatch.graceSamples {
            #expect(watch.observe(sample(value)) == .continueWatching(adoptElement: false))
        }
        return outcome(of: watch.observe(sample(value)))
    }

    /// Champ long qui ne bouge plus : chaque lecture (quatre par seconde pendant 30 s) constate qu'il n'a pas changé,
    /// sans redécouper ses mots. Avant, une lecture coûtait au moins ce découpage (4,7 ms contre 0,15 ms pour un fil
    /// de 33 000 caractères, mesuré sous Linux).
    @Test func unchangedLongFieldIsNotSplitAgainAtEachRead() {
        let thread = (0..<500).map { "Ligne \($0) d'un long fil de discussion, avec quelques mots de plus." }.joined(separator: "\n")
        let value = thread + "\n" + inserted
        var watch = CorrectionWatch(inserted: inserted, known: [])
        #expect(watch.observe(sample(value)) == .continueWatching(adoptElement: false))
        var steps: [CorrectionWatch.Step] = []
        let split = Timing.fastest { _ = CorrectionLearner.words(in: value) }
        let read = Timing.fastest { steps.append(watch.observe(sample(value))) }
        #expect(steps.allSatisfy { $0 == .continueWatching(adoptElement: false) })
        #expect(read < split / 4)
    }

    @Test func correctionThenClearedFieldKeepsTheCandidate() {
        var watch = CorrectionWatch(inserted: inserted, known: [])
        #expect(watch.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        #expect(watch.observe(sample(corrected)) == .continueWatching(adoptElement: false))
        let done = settle(&watch, on: "")
        #expect(done?.stop == .fieldGone)
        #expect(done?.candidates.map(\.corrected) == ["Seedance"])

        let split = "On passe par open router demain."
        var merged = CorrectionWatch(inserted: split, known: [])
        #expect(merged.observe(sample(split)) == .continueWatching(adoptElement: false))
        #expect(merged.observe(sample("On passe par OpenRouter demain.")) == .continueWatching(adoptElement: false))
        let sent = settle(&merged, on: "")
        #expect(sent?.candidates.map(\.corrected) == ["OpenRouter"])
    }

    @Test func correctionThenReplacedFieldKeepsTheCandidate() {
        var watch = CorrectionWatch(inserted: inserted, known: [])
        #expect(watch.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        #expect(watch.observe(sample(corrected)) == .continueWatching(adoptElement: false))
        let done = settle(&watch, on: "On envoie un autre message.")
        #expect(done?.stop == .fieldGone)
        #expect(done?.candidates.map(\.corrected) == ["Seedance"])
    }

    @Test func unchangedFieldLearnsNothing() {
        var watch = CorrectionWatch(inserted: inserted, known: [])
        #expect(watch.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        #expect(watch.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        let done = watch.timeOut()
        #expect(done.stop == .timeout)
        #expect(done.candidates.isEmpty)

        var sent = CorrectionWatch(inserted: inserted, known: [])
        #expect(sent.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        let cleared = settle(&sent, on: "")
        #expect(cleared?.stop == .fieldGone)
        #expect(cleared?.candidates.isEmpty == true)
    }

    @Test func correctionShorterThanThePollIsKeptOnlyIfItWasRead() {
        // 250 ms entre deux lectures, pendant 30 s. Une correction jamais échantillonnée
        // (corrigée puis envoyée avant le relevé) ne peut pas être inventée.
        #expect(CorrectionWatch.pollIntervalNanoseconds == 250_000_000)
        #expect(CorrectionWatch.windowNanoseconds == 30_000_000_000)
        #expect(CorrectionWatch.pollCount == 120)

        var missed = CorrectionWatch(inserted: inserted, known: [])
        #expect(missed.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        let unread = settle(&missed, on: "")
        #expect(unread?.candidates.isEmpty == true)

        var seen = CorrectionWatch(inserted: inserted, known: [])
        #expect(seen.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        #expect(seen.observe(sample(corrected)) == .continueWatching(adoptElement: false))
        let read = settle(&seen, on: "")
        #expect(read?.candidates.map(\.corrected) == ["Seedance"])
    }

    @Test func recreatedElementWithTheSameValueKeepsTheWatch() {
        var watch = CorrectionWatch(inserted: inserted, known: [])
        #expect(watch.observe(sample(inserted, sameElement: true)) == .continueWatching(adoptElement: false))
        #expect(watch.observe(sample(inserted, sameElement: false)) == .continueWatching(adoptElement: true))
        #expect(watch.observe(sample(corrected, sameElement: true)) == .continueWatching(adoptElement: false))
        let done = settle(&watch, on: "")
        #expect(done?.candidates.map(\.corrected) == ["Seedance"])

        var edited = CorrectionWatch(inserted: inserted, known: [])
        #expect(edited.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        #expect(edited.observe(sample(corrected, sameElement: false)) == .continueWatching(adoptElement: true))
        let sent = settle(&edited, on: "")
        #expect(sent?.candidates.map(\.corrected) == ["Seedance"])
    }

    @Test func leavingTheAppUsesTheLastRecognizableValue() {
        var watch = CorrectionWatch(inserted: inserted, known: [])
        #expect(watch.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        #expect(watch.observe(sample(corrected)) == .continueWatching(adoptElement: false))
        let done = outcome(of: watch.observe(sample("ailleurs", sameApplication: false)))
        #expect(done?.stop == .appLeft)
        #expect(done?.candidates.map(\.corrected) == ["Seedance"])
    }

    @Test func extraTypingStillCountsAsTheDictation() {
        var watch = CorrectionWatch(inserted: inserted, known: [])
        let longer = corrected + " Puis on fait le point sur le budget."
        #expect(watch.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        #expect(watch.observe(sample(longer)) == .continueWatching(adoptElement: false))
        let done = watch.timeOut()
        #expect(done.candidates.map(\.corrected) == ["Seedance"])
    }

    @Test func retypingAShortDictationDoesNotEndTheWatch() {
        let short = "Sidance."
        var watch = CorrectionWatch(inserted: short, known: [])
        #expect(watch.observe(sample(short)) == .continueWatching(adoptElement: false))
        // Mot effacé puis retapé : le champ passe moins de 2 s par des états méconnaissables.
        for partial in ["", "S", "See", "Seed"] {
            #expect(watch.observe(sample(partial)) == .continueWatching(adoptElement: false))
        }
        #expect(watch.observe(sample("Seedance.")) == .continueWatching(adoptElement: false))
        let done = settle(&watch, on: "")
        #expect(done?.stop == .fieldGone)
        #expect(done?.candidates.map(\.corrected) == ["Seedance"])
    }

    @Test func briefUnreadableFieldDoesNotEndTheWatch() {
        var watch = CorrectionWatch(inserted: inserted, known: [])
        #expect(watch.observe(sample(inserted)) == .continueWatching(adoptElement: false))
        #expect(watch.observe(sample(nil)) == .continueWatching(adoptElement: false))
        #expect(watch.observe(sample(corrected)) == .continueWatching(adoptElement: false))
        let done = settle(&watch, on: nil)
        #expect(done?.stop == .unreadable)
        #expect(done?.candidates.map(\.corrected) == ["Seedance"])
    }

    @Test func unreadableFieldFromTheStartStopsAtOnce() {
        var watch = CorrectionWatch(inserted: inserted, known: [])
        let done = outcome(of: watch.observe(sample(nil)))
        #expect(done?.stop == .unreadable)
        #expect(done?.candidates.isEmpty == true)
    }
}
