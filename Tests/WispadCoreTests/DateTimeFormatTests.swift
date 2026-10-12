import Foundation
import Testing
@testable import WispadCore

/// Format des dates et des heures : rendu de chaque réglage, consigne, post-traitement déterministe (formes reconnues,
/// cas ambigus laissés tels quels, durées, heures sur 12 ou 24 h) et garde-fou. Phrases inventées, sans réseau.
/// Le banc réseau correspondant : cas d de `scripts/franglais-bench.sh`.
struct DateTimeFormatTests {
    private static func apply(_ text: String, _ format: DictationDateFormat = DictationDateFormat(), english: Bool = false) -> String {
        DateTimeWriter.apply(text, format: format, english: english, referenceYear: 2026)
    }

    // MARK: Rendu

    @Test func defaultsWriteFrenchDatesAndTypographicTimes() {
        let format = DictationDateFormat()
        #expect(format.date(day: 24, month: 10, year: 2026, english: false) == "24/10/2026")
        #expect(format.date(day: 3, month: 11, year: nil, english: false) == "03/11")
        #expect(format.time(hour: 14, minute: 30, english: false) == "14 h 30")
        #expect(format.time(hour: 14, minute: 0, english: false) == "14 h")
        #expect(format.time(hour: 9, minute: 5, english: false) == "9 h 05")
        // En anglais, l'horloge suit la langue : 12 h.
        #expect(format.time(hour: 14, minute: 30, english: true) == "2:30 PM")
        #expect(format.time(hour: 14, minute: 0, english: true) == "2 PM")
        #expect(format.time(hour: 0, minute: 30, english: true) == "12:30 AM")
        #expect(format.time(hour: 12, minute: 0, english: true) == "12 PM")
        #expect(format.samples(english: false) == ["24/10/2026", "03/11", "14 h 30"])
        #expect(format.samples(english: true) == ["24/10/2026", "03/11", "2:30 PM"])
    }

    @Test(arguments: [
        (DictationDateFormat(order: .monthDayYear), "10/24/2026", "11/03"),
        (DictationDateFormat(order: .iso), "2026-10-24", "11-03"),
        // ISO impose les tirets, l'année sur quatre chiffres et les zéros.
        (DictationDateFormat(order: .iso, separator: .dot, fourDigitYear: false, leadingZero: false), "2026-10-24", "11-03"),
        (DictationDateFormat(separator: .dot), "24.10.2026", "03.11"),
        (DictationDateFormat(separator: .hyphen), "24-10-2026", "03-11"),
        (DictationDateFormat(separator: .space), "24 10 2026", "03 11"),
        (DictationDateFormat(fourDigitYear: false), "24/10/26", "03/11"),
        (DictationDateFormat(leadingZero: false), "24/10/2026", "3/11"),
        (DictationDateFormat(order: .monthDayYear, leadingZero: false), "10/24/2026", "11/3"),
        (DictationDateFormat(monthInWords: true), "24 octobre 2026", "3 novembre"),
    ])
    func everyDateSettingIsRendered(format: DictationDateFormat, full: String, partial: String) {
        #expect(format.date(day: 24, month: 10, year: 2026, english: false) == full)
        #expect(format.date(day: 3, month: 11, year: nil, english: false) == partial)
    }

    @Test func monthsInWordsKeepDayAndYearInDigits() {
        let words = DictationDateFormat(monthInWords: true)
        #expect(words.date(day: 1, month: 5, year: nil, english: false) == "1er mai")
        #expect(words.date(day: 15, month: 8, year: 2027, english: false) == "15 août 2027")
        #expect(words.date(day: 24, month: 10, year: 2026, english: true) == "24 October 2026")
        let american = DictationDateFormat(order: .monthDayYear, monthInWords: true)
        #expect(american.date(day: 24, month: 10, year: 2026, english: true) == "October 24, 2026")
        #expect(american.date(day: 3, month: 11, year: nil, english: true) == "November 3")
        #expect(DictationDateFormat(fourDigitYear: false).date(day: 2, month: 1, year: 2005, english: false) == "02/01/05")
    }

    @Test(arguments: [
        (DictationDateFormat(timeStyle: .compact), false, "14h30", "14h"),
        (DictationDateFormat(timeStyle: .colon), false, "14:30", "14:00"),
        (DictationDateFormat(clock: .twelveHour), false, "2:30 PM", "2 PM"),
        // En anglais, sur 24 h, toujours deux-points ; « Selon la langue » donne 12 h.
        (DictationDateFormat(clock: .twentyFourHour, timeStyle: .spaced), true, "14:30", "14:00"),
        (DictationDateFormat(clock: .byLanguage), true, "2:30 PM", "2 PM"),
        (DictationDateFormat(clock: .twelveHour), true, "2:30 PM", "2 PM"),
    ])
    func everyTimeSettingIsRendered(format: DictationDateFormat, english: Bool, halfPast: String, sharp: String) {
        #expect(format.time(hour: 14, minute: 30, english: english) == halfPast)
        #expect(format.time(hour: 14, minute: 0, english: english) == sharp)
    }

    // MARK: Réglage enregistré

    @Test func unreadableFieldsOnlyResetThemselves() throws {
        let stored = #"{"order": "iso", "separator": "virgule", "fourDigitYear": "oui", "clock": "twelveHour", "monthInWords": true, "futur": 1}"#
        let format = try JSONDecoder().decode(DictationDateFormat.self, from: Data(stored.utf8))
        #expect(format.order == .iso)
        #expect(format.separator == .slash)
        #expect(format.fourDigitYear)
        #expect(format.clock == .twelveHour)
        #expect(format.monthInWords)
        #expect(format.leadingZero)
        #expect(format.timeStyle == .spaced)
        #expect(try JSONDecoder().decode(DictationDateFormat.self, from: Data("{}".utf8)) == DictationDateFormat())
        let changed = DictationDateFormat(order: .monthDayYear, separator: .space, fourDigitYear: false, leadingZero: false,
                                          monthInWords: true, clock: .twentyFourHour, timeStyle: .colon)
        #expect(try JSONDecoder().decode(DictationDateFormat.self, from: JSONEncoder().encode(changed)) == changed)
    }

    // MARK: Consigne

    @Test func promptGivesExamplesInTheChosenFormat() {
        let french = CorrectionPrompt.system(for: CorrectionRequest(transcript: "x"))
        #expect(french.contains("Dates et heures : quand le contexte montre sans ambiguïté une date"))
        #expect(french.contains("« le vingt-quatre octobre deux mille vingt-six » → « le 24/10/2026 »"))
        #expect(french.contains("« le trois novembre » ou « le 3 du 11 » → « le 03/11 »"))
        #expect(french.contains("« du 3 au 5 novembre » → « du 03/11 au 05/11 »"))
        #expect(french.contains("« rendez-vous à quatorze heures trente » → « rendez-vous à 14 h 30 »"))
        #expect(french.contains("« à deux heures de l'après-midi » → « à 14 h »"))
        #expect(french.contains("N'invente jamais une année qui n'a pas été dite"))
        #expect(french.contains("Un jour de la semaine seul reste en lettres (« mardi », « mardi prochain »)"))
        #expect(french.contains("« deux heures de route » → « 2 heures de route »"))
        #expect(french.contains("les dates et les heures suivent la règle « Dates et heures » plus bas"))
        #expect(!french.contains("Écris dates,"))

        var request = CorrectionRequest(transcript: "x")
        request.dateFormat = DictationDateFormat(order: .monthDayYear, clock: .twelveHour, timeStyle: .compact)
        let american = CorrectionPrompt.system(for: request)
        #expect(american.contains("→ « le 10/24/2026 »"))
        #expect(american.contains("→ « rendez-vous à 2:30 PM »"))
        request.dateFormat = DictationDateFormat(monthInWords: true)
        let words = CorrectionPrompt.system(for: request)
        #expect(words.contains("→ « le 24 octobre 2026 »"))
        #expect(words.contains("« le premier mai » → « le 1er mai »"))
        #expect(!words.contains("« du 3 au 5 novembre »"))

        request.language = .english
        request.dateFormat = DictationDateFormat()
        let english = CorrectionPrompt.system(for: request)
        #expect(english.contains("Dates and times: when the context clearly shows a date"))
        #expect(english.contains("\"the meeting is at two thirty in the afternoon\" → \"the meeting is at 2:30 PM\""))
        #expect(english.contains("Never invent a year that was not spoken"))
        #expect(english.contains("\"two hours of driving\" → \"2 hours of driving\""))
        #expect(!english.contains("Dates et heures"))
        // Le ton reste la dernière consigne.
        request.tone = .casual
        #expect(CorrectionPrompt.system(for: request).hasSuffix(DictationTone.casual.instructions(english: true)))
    }

    // MARK: Post-traitement

    @Test(arguments: [
        // Dates complètes, quelle que soit leur écriture.
        ("Rendez-vous le 24 octobre 2026.", "Rendez-vous le 24/10/2026."),
        ("Rendez-vous le 3/11/2026.", "Rendez-vous le 03/11/2026."),
        ("Rendez-vous le 3.11.2026.", "Rendez-vous le 03/11/2026."),
        ("Rendez-vous le 2026-11-03.", "Rendez-vous le 03/11/2026."),
        ("Le contrat date du 24/10/26.", "Le contrat date du 24/10/2026."),
        ("Il est né le 12/05/85.", "Il est né le 12/05/1985."),
        // Dates sans année.
        ("On se voit le 3 novembre.", "On se voit le 03/11."),
        ("On se voit le 3 du 11.", "On se voit le 03/11."),
        ("On se voit mardi 3 novembre.", "On se voit mardi 03/11."),
        ("Livraison le 1er mai.", "Livraison le 01/05."),
        ("On se voit le 3/11.", "On se voit le 03/11."),
        ("Congés du 3 au 5 novembre.", "Congés du 03/11 au 05/11."),
        ("Les 3 et 4 novembre 2026, c'est fermé.", "Les 03/11/2026 et 04/11/2026, c'est fermé."),
        // Heures d'un rendez-vous.
        ("Rendez-vous à 14h30.", "Rendez-vous à 14 h 30."),
        ("Rendez-vous à 14 heures.", "Rendez-vous à 14 h."),
        ("Rendez-vous à 14:30.", "Rendez-vous à 14 h 30."),
        ("On part vers 9h.", "On part vers 9 h."),
        ("Ouvert jusqu'à 18h.", "Ouvert jusqu'à 18 h."),
        ("On commence à partir de 8h30.", "On commence à partir de 8 h 30."),
        ("J'arrive à 2 h de l'après-midi.", "J'arrive à 14 h."),
        ("Le dîner est à 8 heures du soir.", "Le dîner est à 20 h."),
        ("Le train part à 6 h 15 du matin.", "Le train part à 6 h 15."),
        ("La réunion se tient de 14h à 16h.", "La réunion se tient de 14 h à 16 h."),
        ("Je suis libre entre 9h et 11h.", "Je suis libre entre 9 h et 11 h."),
        ("Le cours a lieu le 3 novembre 2026 à 9h.", "Le cours a lieu le 03/11/2026 à 9 h."),
        ("On se voit le 24 à 14h.", "On se voit le 24 à 14 h."),
        ("La boutique ouvre de 9h30 à 19h du lundi au samedi.", "La boutique ouvre de 9 h 30 à 19 h du lundi au samedi."),
        ("Prends-le à 8 heures, 12 heures et 20 heures.", "Prends-le à 8 h, 12 h et 20 h."),
        ("Réunion lundi 9h-10h.", "Réunion lundi 9 h-10 h."),
        ("On décolle demain 6h45.", "On décolle demain 6 h 45."),
        ("Rendez-vous vendredi 13 à 20h, 20h15 max.", "Rendez-vous vendredi 13 à 20 h, 20 h 15 max."),
        ("J'arrive à 14h environ.", "J'arrive à 14 h environ."),
    ])
    func frenchDatesAndTimesTakeTheDefaultFormat(text: String, expected: String) {
        #expect(Self.apply(text) == expected)
    }

    @Test(arguments: [
        ("The meeting is on October 24, 2026 at 2:30 pm.", "The meeting is on 24/10/2026 at 2:30 PM."),
        ("See you at 2 p.m. Then we leave.", "See you at 2 PM. Then we leave."),
        ("See you at 2 p.m. and then we leave.", "See you at 2 PM and then we leave."),
        ("We leave on the 3rd of November.", "We leave on 03/11."),
        ("The shop opens at 14:30.", "The shop opens at 2:30 PM."),
        ("It ends at 5 o'clock in the afternoon.", "It ends at 5 PM."),
        ("We work from 9:00 to 17:00.", "We work from 9 AM to 5 PM."),
        ("Call me on 24/10.", "Call me on 24/10."),
    ])
    func englishDatesAndTimesTakeTheDefaultFormat(text: String, expected: String) {
        #expect(Self.apply(text, english: true) == expected)
    }

    @Test func everyFormatIsAppliedToTheSameSentence() {
        let text = "Rendez-vous le 3 novembre 2026 à 14h30, puis le 1er mai à 9 h."
        #expect(Self.apply(text, DictationDateFormat(order: .monthDayYear)) == "Rendez-vous le 11/03/2026 à 14 h 30, puis le 05/01 à 9 h.")
        #expect(Self.apply(text, DictationDateFormat(order: .iso)) == "Rendez-vous le 2026-11-03 à 14 h 30, puis le 05-01 à 9 h.")
        #expect(Self.apply(text, DictationDateFormat(separator: .dot, fourDigitYear: false, leadingZero: false))
            == "Rendez-vous le 3.11.26 à 14 h 30, puis le 1.5 à 9 h.")
        #expect(Self.apply(text, DictationDateFormat(monthInWords: true, timeStyle: .compact))
            == "Rendez-vous le 3 novembre 2026 à 14h30, puis le 1er mai à 9h.")
        #expect(Self.apply(text, DictationDateFormat(timeStyle: .colon)) == "Rendez-vous le 03/11/2026 à 14:30, puis le 01/05 à 9:00.")
        // Sur 12 h, « à 9 h » peut être le matin ou le soir : il reste tel quel.
        #expect(Self.apply(text, DictationDateFormat(clock: .twelveHour)) == "Rendez-vous le 03/11/2026 à 2:30 PM, puis le 01/05 à 9 h.")
        #expect(Self.apply("Le 24/10/2026, puis le 3/11.", DictationDateFormat(monthInWords: true)) == "Le 24 octobre 2026, puis le 3 novembre.")
        #expect(Self.apply("Le 1/11.", DictationDateFormat(monthInWords: true)) == "Le 1er novembre.")
        #expect(Self.apply("On 10/24/2026.", DictationDateFormat(order: .monthDayYear, monthInWords: true), english: true) == "On October 24, 2026.")
        #expect(Self.apply("On October 24, 2026.", DictationDateFormat(monthInWords: true), english: true) == "On 24 October 2026.")
        // Une date que l'ordre réglé ne peut pas lire se lit dans l'autre.
        #expect(Self.apply("Le 24/10/2026.", DictationDateFormat(order: .monthDayYear)) == "Le 10/24/2026.")
        #expect(Self.apply("De 9 h à 17 h.", DictationDateFormat(clock: .twelveHour)) == "De 9 AM à 5 PM.")
        #expect(Self.apply("Un cachet à 8 h et à 20 h.", DictationDateFormat(clock: .twelveHour)) == "Un cachet à 8 AM et à 8 PM.")
        #expect(Self.apply("À 8 h, 9 h et 20 h.", DictationDateFormat(clock: .twelveHour)) == "À 8 AM, 9 AM et 8 PM.")
    }

    @Test(arguments: [
        // Un jour seul, un mois seul, une année seule.
        "On se voit mardi.", "On se voit mardi prochain.", "C'était en octobre 2026.", "En 2026, tout change.",
        // Durées et distances.
        "Il y a 2 heures de route.", "Il reste 1h30 de trajet.", "On habite à 2 h de Paris.", "Ça peut durer jusqu'à 3 heures.",
        "Le film dure 2 h 15.", "Rappelle-moi dans 3 heures.", "J'ai dormi 8 h.", "Le trajet prend de 2 à 3 heures.", "Compte 2 à 3 h.", "C'est ouvert 24h/24.", "À 2 h près, c'était bon.",
        // Fractions, notes, versions, numéros, adresses.
        "Il a eu 8/10 au contrôle.", "Les 3/4 des gens sont venus.", "Passe à la version 1.12.20.", "L'adresse est 10.0.0.24.",
        "Appelle le 06-12-34-56-78.", "Le score final est 21-15.", "Le format est 16:9.", "Lis Jean 3:16.", "Il est arrivé à 8 h, 2 heures plus tard il repartait.",
        "Il fait cuire 20 min à 180 degrés, puis 1h à 150.", "On a mené 2 à 1 à la mi-temps.",
        "Le lien https://exemple.fr/2026/10/24 marche.", "Écris `date 2026-10-24` dans le terminal.", "Le journal 2026-10-24T14:30 est plein.",
        // Dates impossibles.
        "Le 31 février 2026 n'existe pas.", "Le 32/13/2026 non plus.",
    ])
    func ambiguousTextIsLeftAlone(text: String) {
        for format in [DictationDateFormat(), DictationDateFormat(order: .iso, clock: .twelveHour, timeStyle: .colon)] {
            #expect(Self.apply(text, format) == text, "\(text)")
        }
    }

    @Test func applyingTwiceChangesNothingMore() {
        let texts = [
            "Rendez-vous le 3 novembre 2026 à 14h30, puis le 1er mai à 9 h.",
            "Le 24/10/26 et le 2026-10-24 à 2 h de l'après-midi.",
            "Du 3 au 5 novembre, de 14h à 16h, à 8 heures du soir.",
            "See you at 2 p.m. on October 24, 2026, from 9:00 to 17:00.",
        ]
        let formats = [
            DictationDateFormat(), DictationDateFormat(order: .monthDayYear, separator: .dot, fourDigitYear: false, leadingZero: false),
            DictationDateFormat(order: .iso, clock: .twelveHour), DictationDateFormat(separator: .hyphen, timeStyle: .compact),
            DictationDateFormat(separator: .space, timeStyle: .colon), DictationDateFormat(monthInWords: true, clock: .twentyFourHour),
            DictationDateFormat(order: .monthDayYear, monthInWords: true, clock: .twelveHour),
        ]
        for text in texts {
            for format in formats {
                for english in [false, true] {
                    let once = DateTimeWriter.apply(text, format: format, english: english, referenceYear: 2026)
                    #expect(DateTimeWriter.apply(once, format: format, english: english, referenceYear: 2026) == once, "\(text) → \(once)")
                }
            }
        }
    }

    // MARK: Garde-fou

    @Test(arguments: [
        // Même date ou même heure, autre écriture : rien d'inventé.
        ("rendez-vous à quatorze heures trente", "Rendez-vous à 14h30."),
        ("rendez-vous à quatorze heures trente", "Rendez-vous à 14 h 30."),
        ("on se voit le vingt-quatre octobre deux mille vingt-six", "On se voit le 24/10/2026."),
        ("on se voit le 3 du 11 pour le bilan", "On se voit le 03/11 pour le bilan."),
        ("j'arrive à deux heures de l'après-midi", "J'arrive à 14h."),
        ("on se voit à deux heures et demie cet après-midi", "On se voit à 14h30 cet après-midi."),
        ("livraison le premier mai", "Livraison le 1er mai."),
        ("the meeting is at two thirty in the afternoon", "The meeting is at 2:30 PM."),
        ("we leave on november third twenty twenty-six", "We leave on November 3, 2026."),
        ("we leave on the third of the eleventh", "We leave on November 3."),
        ("à quatorze heures", "À 14h."),
        // L'heure dite en chiffres est hors du bloc remplacé : seul « PM » remplace « in the afternoon ».
        ("the meeting is at 2 in the afternoon", "The meeting is at 2 PM."),
        ("the meeting is at 2:30 in the afternoon", "The meeting is at 2:30 PM."),
    ])
    func rewrittenDatesAndTimesAreKept(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == corrected)
    }

    @Test func anInventedYearIsRemoved() {
        #expect(FidelityGuard.check(transcript: "on se voit le trois novembre", corrected: "On se voit le 03/11/2026.") == "On se voit le 03/11.")
        #expect(FidelityGuard.check(transcript: "rendez-vous le 3 novembre", corrected: "Rendez-vous le 3 novembre 2026.") == "Rendez-vous le 3 novembre.")
        #expect(FidelityGuard.check(transcript: "on part le vingt-six octobre", corrected: "On part le 26/10/2026.") == "On part le 26/10.")
        #expect(FidelityGuard.check(transcript: "we leave on november third", corrected: "We leave on November 3, 2026.") == "We leave on November 3.")
        #expect(FidelityGuard.check(transcript: "on se voit le trois novembre", corrected: "On se voit le 2026-11-03.") == "On se voit le 11-03.")
        // L'année dite reste, en chiffres, en lettres ou sur deux chiffres.
        for (heard, corrected) in [
            ("on se voit le trois novembre deux mille vingt-six", "On se voit le 03/11/2026."),
            ("on se voit le trois novembre 2026", "On se voit le 03/11/2026."),
            ("on se voit le trois novembre vingt-six", "On se voit le 03/11/2026."),
            ("on part le vingt-six octobre vingt-six", "On part le 26/10/26."),
            ("we leave on november third twenty twenty-six", "We leave on 11/03/2026."),
        ] {
            #expect(FidelityGuard.check(transcript: heard, corrected: corrected) == corrected, "\(heard)")
        }
    }

    @Test func anotherDateOrTimeIsNotTheSameMoment() {
        // Sans l'heure dite, « PM » reste une invention : les mots entendus reviennent.
        #expect(FidelityGuard.check(transcript: "the meeting is in the afternoon", corrected: "The meeting is PM.")
            == "The meeting is in the afternoon.")
        #expect(!MomentReading.sameMoment(written: ["03/11/2026"], heard: ["trois", "novembre"]))
        #expect(!MomentReading.sameMoment(written: ["14h30"], heard: ["seize", "heures", "trente"]))
        #expect(!MomentReading.sameMoment(written: ["DDR4"], heard: ["DDR", "quatre"]))
    }

    @Test func spokenNumbersOfADateOrATimeAreRead() {
        #expect(MomentReading.numbers(in: ["le", "vingt-quatre", "octobre", "deux", "mille", "vingt-six"]) == [24, 10, 2026])
        #expect(MomentReading.numbers(in: ["24/10/2026"]) == [24, 10, 2026])
        #expect(MomentReading.numbers(in: ["quatorze", "heures", "trente"]) == [14, 30])
        #expect(MomentReading.numbers(in: ["deux", "heures", "et", "demie", "de", "l'après-midi"]) == [14, 30])
        #expect(MomentReading.numbers(in: ["two", "thirty", "in", "the", "afternoon"]) == [14, 30])
        #expect(MomentReading.numbers(in: ["2:30", "p.m."]) == [14, 30])
        #expect(MomentReading.numbers(in: ["October", "twenty-fourth", "twenty", "twenty-six"]) == [10, 24, 20, 26])
        #expect(MomentReading.numbers(in: ["minuit", "et", "quart"]) == [0, 15])
    }

    // MARK: Chaîne complète

    @Test func theCorrectionOutputTakesTheFormatAfterTheGuard() async {
        let stub = DateFormatHTTPStub(reply: "Rendez-vous le 3/11/2026 à 14h30, puis le 1er mai à 9 h.")
        var request = CorrectionRequest(transcript: "rendez-vous le trois novembre deux mille vingt-six à quatorze heures trente puis le premier mai à neuf heures")
        request.dateFormat = DictationDateFormat(order: .iso, timeStyle: .colon)
        let speech = SpeechRequest(provider: .xai, liveModel: "fixture", fileModel: "fixture", apiKey: "fixture-vocal",
                                   language: .french, keyterms: [], prompt: "", cleanupKey: "fixture-primary")
        let outcome = await TextCleaner.clean(transcript: request.transcript, request: request, speech: speech, enabled: true,
                                              transport: { try await stub.request($0) })
        #expect(outcome.text == "Rendez-vous le 2026-11-03 à 14:30, puis le 05-01 à 9:00.")
        #expect(await stub.system.contains("→ « le 2026-10-24 »"))
    }
}

/// Correction simulée : aucune clé réelle ni réseau.
private actor DateFormatHTTPStub {
    let reply: String
    private(set) var system = ""

    init(reply: String) { self.reply = reply }

    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let messages = body?["messages"] as? [[String: String]] ?? []
        system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        let payload: [String: Any] = [
            "choices": [["message": ["content": reply], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5],
        ]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: payload), response)
    }
}
