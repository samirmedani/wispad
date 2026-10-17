import Foundation
import Testing
@testable import WispadCore

/// Suggestions du dictionnaire tirées de l'historique, sur des dictées inventées : noms réparés par la correction,
/// écriture d'une entrée, nom écrit de plusieurs façons, usage de chaque entrée.
struct DictionaryInsightsTests {
    private let now = Date(timeIntervalSince1970: 1_791_028_800)

    private func dictation(_ id: String, raw: String, final: String? = nil, daysAgo: Double = 1) -> DictionaryInsights.Dictation {
        DictionaryInsights.Dictation(id: id, date: now.addingTimeInterval(-daysAgo * 86_400), raw: raw, final: final ?? raw)
    }

    private func written(_ raw: String, _ final: String) -> [String] {
        DictionaryInsights.fixes(raw: raw, final: final).map(\.written)
    }

    // MARK: Réparations d'une dictée

    @Test func misheardNamesRepairedByTheCorrectionAreFound() {
        #expect(DictionaryInsights.fixes(raw: "on branche sentri sur l'app mobile", final: "On branche Sentry sur l'app mobile.")
                == [DictionaryInsights.Fix(heard: "sentri", written: "Sentry")])
        #expect(DictionaryInsights.fixes(raw: "les mails partent avec ri send", final: "Les mails partent avec Resend.")
                == [DictionaryInsights.Fix(heard: "ri send", written: "Resend")])
        #expect(written("je regarde la doc de zoo stand ce soir", "Je regarde la doc de Zustand ce soir.") == ["Zustand"])
        #expect(written("c'est sur versel", "C'est sur Vercel.") == ["Vercel"])
    }

    @Test func caseOnlyChangesNeedADistinctiveSpelling() {
        #expect(written("on passe par openai demain", "On passe par OpenAI demain.") == ["OpenAI"])
        #expect(written("je lance le cli ce soir", "Je lance le CLI ce soir.") == ["CLI"])
        #expect(written("on ouvre photo prism", "On ouvre PhotoPrism.") == ["PhotoPrism"])
        // Une majuscule de début de phrase, un mot courant ou une espace retirée ne disent rien d'un nom.
        #expect(written("la réunion de lundi", "La réunion de lundi.") == [])
        #expect(written("ok donc on y va", "OK, donc on y va.") == [])
        #expect(written("il est 12 h pile", "Il est 12h pile.") == [])
    }

    @Test func grammarPunctuationAndElisionAreIgnored() {
        #expect(written("je pense que Opus répond vite", "Je pense qu'Opus répond vite.") == [])
        #expect(written("j'essaye demain matin", "J'essaie demain matin.") == [])
        #expect(written("voilà euh mais je pense que oui", "Voilà. Mais je pense que oui.") == [])
        #expect(written("c'est bon donc on y va", "C'est bon. Donc on y va.") == [])
        #expect(written("les download sont prêts", "Les Downloads sont prêts.") == [])
        #expect(written("on pense Comme Grenoble quoi", "On pense comme Grenoble.") == [])
    }

    @Test func numbersMustStayTheSame() {
        #expect(written("la carte RTX4090 chauffe", "La carte RTX5090 chauffe.") == [])
        #expect(written("on passe en ddr trois", "On passe en DDR3.") == [])
    }

    @Test func aRewrittenDictationSaysNothing() {
        #expect(DictionaryInsights.fixes(raw: "traduis ça en anglais stp", final: "Please translate this into English Sentry") == [])
    }

    @Test func sameLengthBlocksAreComparedWordByWord() {
        #expect(written("le harness cloud tourne", "Le harnais Claude tourne.") == ["Claude"])
    }

    // MARK: Suggestions

    @Test func aNameRepairedInTwoDictationsIsSuggested() {
        let once = [dictation("a", raw: "on branche sentri sur l'app", final: "On branche Sentry sur l'app.")]
        #expect(DictionaryInsights.analyze(once, dictionary: [], refused: [], now: now).report.suggestions.isEmpty)
        let twice = once + [dictation("b", raw: "l'erreur est dans sentri ce matin", final: "L'erreur est dans Sentry ce matin.")]
        let suggestions = DictionaryInsights.analyze(twice, dictionary: [], refused: [], now: now).report.suggestions
        #expect(suggestions == [DictionaryInsights.Suggestion(term: "Sentry", reason: .repeatedFix(heard: ["sentri"], dictations: 2))])
        #expect(suggestions.first?.id == "fix:sentry")
    }

    @Test func knownRefusedBuiltInAndOldNamesAreNotSuggested() {
        let dictations = [
            dictation("a", raw: "on branche sentri sur l'app", final: "On branche Sentry sur l'app."),
            dictation("b", raw: "l'erreur est dans sentri ce matin", final: "L'erreur est dans Sentry ce matin."),
            dictation("c", raw: "c'est sur versel", final: "C'est sur Vercel."),
            dictation("d", raw: "on déploie sur versel", final: "On déploie sur Vercel.")
        ]
        func terms(_ entries: [DictionaryEntry] = [], refused: [String] = [], at date: Date? = nil) -> [String] {
            DictionaryInsights.analyze(dictations, dictionary: entries, refused: refused, now: date ?? now).report.suggestions.map(\.term)
        }
        // Vercel fait partie du vocabulaire intégré : il part déjà à chaque dictée.
        #expect(terms() == ["Sentry"])
        #expect(terms([DictionaryEntry(term: "sentry", origin: .user)]).isEmpty)
        #expect(terms(refused: ["SENTRY"]).isEmpty)
        #expect(terms(at: now.addingTimeInterval(DictionaryInsights.window + 2 * 86_400)).isEmpty)
    }

    @Test func aWordOfAKnownPhraseIsNotSuggestedAlone() {
        let dictations = [
            dictation("a", raw: "j'ouvre visual stoudio code", final: "J'ouvre Visual Studio Code."),
            dictation("b", raw: "le thème de visual stoudio code", final: "Le thème de Visual Studio Code.")
        ]
        #expect(DictionaryInsights.analyze(dictations, dictionary: [], refused: [], now: now).report.suggestions.map(\.term) == ["Studio"])
        let phrase = DictionaryEntry(term: "Visual Studio Code", origin: .user)
        #expect(DictionaryInsights.analyze(dictations, dictionary: [phrase], refused: [], now: now).report.suggestions.isEmpty)
    }

    @Test func anEntryWrittenOtherwiseInMostDictationsIsRespelled() {
        let entry = DictionaryEntry(id: "entry", term: "posthog", origin: .user)
        let three = (0..<3).map { dictation("p\($0)", raw: "Les chiffres arrivent dans PostHog chaque jour \($0).") }
        let suggestions = DictionaryInsights.analyze(three, dictionary: [entry], refused: [], now: now).report.suggestions
        #expect(suggestions == [DictionaryInsights.Suggestion(term: "PostHog", reason: .respell(entryID: "entry", current: "posthog", dictations: 3, total: 3))])
        // Trop peu de dictées, écritures partagées, ou suggestion déjà ignorée : rien.
        #expect(DictionaryInsights.analyze(Array(three.prefix(2)), dictionary: [entry], refused: [], now: now).report.suggestions.isEmpty)
        let mixed = three + (0..<2).map { dictation("q\($0)", raw: "On regarde posthog ensemble \($0).") }
        #expect(DictionaryInsights.analyze(mixed, dictionary: [entry], refused: [], now: now).report.suggestions.isEmpty)
        #expect(DictionaryInsights.analyze(three, dictionary: [entry], refused: ["PostHog"], now: now).report.suggestions.isEmpty)
    }

    @Test func aNameWrittenSeveralWaysSuggestsItsDistinctiveSpelling() {
        let dictations = [
            dictation("a", raw: "La build part sur TestFlight ce soir."),
            dictation("b", raw: "Les testeurs ont reçu TestFlight hier."),
            dictation("c", raw: "On attend la revue TestFlight."),
            dictation("d", raw: "Je relance Testflight demain."),
            dictation("e", raw: "Le lien Testflight a expiré."),
            // En début de phrase, la majuscule ne dit rien : cette écriture ne compte pas.
            dictation("f", raw: "Testflight est lent aujourd'hui.")
        ]
        let suggestions = DictionaryInsights.analyze(dictations, dictionary: [], refused: [], now: now).report.suggestions
        #expect(suggestions == [DictionaryInsights.Suggestion(term: "TestFlight", reason: .spellings([
            .init(text: "TestFlight", dictations: 3), .init(text: "Testflight", dictations: 2)
        ]))])
        // Deux écritures sans graphie marquée (« Paris » / « paris ») : aucune à préférer.
        let plain = [dictation("g", raw: "On part à Paris lundi."), dictation("h", raw: "On revient de Paris mardi."),
                     dictation("i", raw: "Le pari paris tient."), dictation("j", raw: "Un autre pari paris encore.")]
        #expect(DictionaryInsights.analyze(plain, dictionary: [], refused: [], now: now).report.suggestions.isEmpty)
    }

    // MARK: Usage

    @Test func usageCountsWholeWordsWithoutCaseAccentsOrPunctuation() {
        let entries = [DictionaryEntry(id: "seed", term: "Seedance"), DictionaryEntry(id: "next", term: "Next.js"),
                       DictionaryEntry(id: "phrase", term: "Visual Studio Code"), DictionaryEntry(id: "opus", term: "Opus"),
                       DictionaryEntry(id: "kbis", term: "Kbis")]
        let texts = ["J'ai testé seedance hier.", "Seedance, encore Seedance !", "Le site Next.js tourne.",
                     "Ouvre Visual Studio Code.", "Un opuscule rare.", "Visual Studio est ouvert."]
        #expect(DictionaryInsights.usage(of: entries, in: texts) == ["seed": 2, "next": 1, "phrase": 1])
    }

    // MARK: Apprentissage

    @Test func aRepairIsLearnableOnlyOnceItRepeats() {
        let current = [DictionaryInsights.Fix(heard: "sentri", written: "Sentry")]
        let earlier = dictation("old", raw: "on branche sentri sur l'app", final: "On branche Sentry sur l'app.")
        let latest = dictation("new", raw: "l'erreur est dans sentri", final: "L'erreur est dans Sentry.")
        let index = DictionaryInsights.fixIndex([earlier])
        #expect(DictionaryInsights.learnable(current, currentID: "new", recent: [latest], fixes: [:], dictionary: [], refused: []).isEmpty)
        #expect(DictionaryInsights.learnable(current, currentID: "new", recent: [earlier, latest], fixes: index, dictionary: [], refused: [])
                == current)
        #expect(DictionaryInsights.learnable(current, currentID: "new", recent: [earlier, latest], fixes: index,
                                             dictionary: [DictionaryEntry(term: "Sentry")], refused: []).isEmpty)
        #expect(DictionaryInsights.learnable(current, currentID: "new", recent: [earlier, latest], fixes: index, dictionary: [], refused: ["sentry"]).isEmpty)
        // La même dictée analysée deux fois ne compte qu'une fois.
        #expect(DictionaryInsights.learnable(current, currentID: "old", recent: [earlier], fixes: index, dictionary: [], refused: []).isEmpty)
    }

    @Test func cachedRepairsAreReusedAndOldOnesDropped() {
        let recent = dictation("recent", raw: "on branche sentri", final: "On branche Sentry.")
        let old = dictation("old", raw: "on branche sentri", final: "On branche Sentry.", daysAgo: 200)
        let known = ["recent": [DictionaryInsights.Fix(heard: "cache", written: "Cache")]]
        let fixes = DictionaryInsights.analyze([recent, old], dictionary: [], refused: [], now: now, known: known).fixes
        #expect(fixes == known)
    }
}

