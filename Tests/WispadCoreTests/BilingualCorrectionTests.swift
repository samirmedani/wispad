import Testing
@testable import WispadCore

/// Autocorrections orales et dictée en anglais : consigne, garde-fou, comparaison flux/fichier. Sans réseau.
struct BilingualCorrectionTests {
    // MARK: Autocorrections orales

    @Test(arguments: [
        ("On se voit mardi, ah non, mercredi.", "On se voit mercredi."),
        ("Envoie-le à Paul, non pardon, à Julie.", "Envoie-le à Julie."),
        ("Il faut trois, enfin quatre serveurs.", "Il faut 4 serveurs."),
        ("Je je je pense que c'est bon.", "Je pense que c'est bon."),
        ("Déploie sur Vercel, non non, sur Netlify.", "Déploie sur Netlify."),
        ("Prends un i9, non pardon, un i7.", "Prends un i7."),
        // Transcriptions brutes, comme le flux les rend : le modèle lie les mots par un trait d'union.
        ("envoie le à paul non pardon à julie", "Envoie-le à Julie."),
        ("mets le dans le dossier factures non attends dans le dossier devis", "Mets-le dans le dossier devis."),
        ("c'est à dire qu'on part demain", "C'est-à-dire qu'on part demain."),
        ("Let's meet on Tuesday, no wait, Wednesday.", "Let's meet on Wednesday."),
        ("Send it to Mark, sorry, I mean Julia.", "Send it to Julia."),
        ("We need three, actually four servers.", "We need 4 servers."),
        ("The deploy, no, the build failed.", "The build failed."),
    ])
    func guardKeepsASpokenSelfCorrection(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == corrected)
    }

    @Test func bothPromptsTeachSelfCorrectionsWithExamplesAndKeepContentNo() {
        let french = CorrectionPrompt.system(for: CorrectionRequest(transcript: "x", language: .french))
        #expect(french.contains("« On se voit mardi, ah non, mercredi » → « On se voit mercredi. »"))
        #expect(french.contains("« Je lui ai dit non, pas question »"))
        let english = CorrectionPrompt.system(for: CorrectionRequest(transcript: "x", language: .english))
        #expect(english.contains("\"Let's meet on Tuesday, no wait, Wednesday\" → \"Let's meet on Wednesday.\""))
        #expect(english.contains("\"I told him no, not today\""))
    }

    // MARK: Dictée en anglais

    @Test func englishDictationGetsTheEnglishPromptAndLabels() {
        let request = CorrectionRequest(transcript: "I pushed the fix", dictionary: ["Wispad"], appName: "Slack",
                                        previousDictations: ["The build is green."], language: .english)
        let system = CorrectionPrompt.system(for: request)
        #expect(system.hasPrefix("You clean up a voice dictation."))
        #expect(system.contains("\"new paragraph\""))
        #expect(!system.contains("Tu corriges"))
        let user = CorrectionPrompt.userText(request)
        #expect(user.contains("Previous dictations in this app"))
        #expect(user.contains("Dictionary: Wispad"))
        #expect(user.hasSuffix("Transcription: I pushed the fix"))
        #expect(!user.contains("Dictées précédentes"))
    }

    @Test func frenchStaysTheDefaultPrompt() {
        let system = CorrectionPrompt.system(for: CorrectionRequest(transcript: "j'ai push le fix"))
        #expect(system.hasPrefix("Tu corriges une dictée vocale."))
        #expect(CorrectionPrompt.userText(CorrectionRequest(transcript: "x")).contains("Vocabulaire technique"))
    }

    @Test(arguments: [
        ("I pushed the fix to the main branch and it works", DictationLanguage.english),
        ("j'ai push le fix sur la branch main et ça marche", .french),
        ("le deploy Vercel a fail, je relance le build", .french),
        ("can you check the logs for this one", .english),
        ("ok", .french),
    ])
    func automaticModeFollowsTheTranscriptLanguage(text: String, expected: DictationLanguage) {
        #expect(TranscriptLanguage.guess(text) == expected)
        let request = CorrectionRequest(transcript: text, language: .auto)
        #expect(CorrectionPrompt.language(for: request) == expected)
    }

    @Test func newInstallDictatesInTheSystemLanguage() {
        #expect(DictationLanguage.preferred(["fr-FR", "en-US"]) == .french)
        #expect(DictationLanguage.preferred(["en-GB"]) == .english)
        #expect(DictationLanguage.preferred(["de-DE"]) == .english)
        #expect(DictationLanguage.preferred([]) == .english)
    }

    @Test func recognitionPromptFollowsTheLanguage() {
        #expect(CorrectionPrompt.recognitionPrompt(appName: "Mail", nearby: "Hi", language: .english)
            == "Dictation. Keep proper nouns and technical terms.\nApplication: Mail\nContext: Hi")
        #expect(CorrectionPrompt.recognitionPrompt(appName: nil, nearby: nil).hasPrefix("Dictée."))
    }

    // MARK: Nombres dits, en français et en anglais

    @Test(arguments: [
        ("deux mille six cent soixante six", 2666),
        ("quatre vingt quinze", 95),
        ("soixante et onze", 71),
        ("cent quatre vingt", 180),
        ("two thousand six hundred sixty six", 2666),
        ("one hundred and five", 105),
        ("twenty one", 21),
        ("ninety nine", 99),
    ])
    func spokenNumbersAreRead(words: String, value: Int) {
        let tokens = words.split(separator: " ").map(String.init)
        let parsed = SpokenNumbers.parse(tokens, from: 0)
        #expect(parsed?.value == value)
        #expect(parsed?.next == tokens.count)
    }

    @Test func andOnlyJoinsAHundredOrAThousand() {
        #expect(SpokenNumbers.spell(["two", "and", "three"]) == ["2", "and", "3"])
        #expect(SpokenNumbers.spell(["rock", "and", "roll"]) == ["rock", "and", "roll"])
    }

    @Test(arguments: [
        ("I have twenty one servers, um, running", "I have 21 servers running."),
        ("two thousand six hundred sixty six megahertz", "2666 MHz"),
        ("sixteen gigs of RAM", "16 GB of RAM"),
        ("twenty percent", "20%"),
        ("vingt pour cent", "20 %"),
    ])
    func englishWritingDifferencesAreEquivalent(left: String, right: String) {
        #expect(TranscriptEquivalence.equivalent(left, right))
    }

    @Test func differentEnglishNumbersStayDifferent() {
        #expect(!TranscriptEquivalence.equivalent("sixteen gigs", "six gigs"))
        #expect(!TranscriptEquivalence.equivalent("three servers", "four servers"))
    }

    @Test func englishSpokenReferenceIsNotReverted() {
        #expect(FidelityGuard.check(transcript: "I have DDR four RAM", corrected: "I have DDR4 RAM.") == "I have DDR4 RAM.")
        #expect(FidelityGuard.check(transcript: "an RTX five thousand seventy", corrected: "an RTX 5070.") == "an RTX 5070.")
    }
}
