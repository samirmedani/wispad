import Foundation
import Testing
@testable import WispadCore

/// Filet anti-régression de `DateTimeWriter` et `DictationDateFormat` : défauts corrigés, cas limites, propriétés sur des
/// phrases et des réglages tirés au hasard.
struct DateTimeWriterPropertyTests {
    /// Les 864 combinaisons de Réglages › Mise en forme.
    static let formats: [DictationDateFormat] = DictationDateFormat.Order.allCases.flatMap { order in
        DictationDateFormat.Separator.allCases.flatMap { separator in
            [true, false].flatMap { fourDigitYear in
                [true, false].flatMap { leadingZero in
                    [true, false].flatMap { monthInWords in
                        DictationDateFormat.Clock.allCases.flatMap { clock in
                            DictationDateFormat.TimeStyle.allCases.map { timeStyle in
                                DictationDateFormat(order: order, separator: separator, fourDigitYear: fourDigitYear,
                                                    leadingZero: leadingZero, monthInWords: monthInWords, clock: clock,
                                                    timeStyle: timeStyle)
                            }
                        }
                    }
                }
            }
        }
    }

    private func english(_ text: String, _ format: DictationDateFormat = DictationDateFormat()) -> String {
        DateTimeWriter.apply(text, format: format, english: true, referenceYear: 2026)
    }

    private func french(_ text: String, _ format: DictationDateFormat = DictationDateFormat()) -> String {
        DateTimeWriter.apply(text, format: format, english: false, referenceYear: 2026)
    }

    // MARK: Défauts corrigés

    /// Un jour devant le mois (« 3 May ») et un nombre après lui : la date est le 3 mai. Le mois était pris par le nombre
    /// suivant (« On 3 May 8 people came » → « On 3 08/05 people came »), le jour restait seul.
    @Test func theDayBeforeTheMonthIsNotTakenByTheNextNumber() {
        #expect(english("On 3 May 8 people came.") == "On 03/05 8 people came.")
        #expect(english("Since 3 May 15 users joined.") == "Since 03/05 15 users joined.")
        #expect(english("On the 3rd of May 10 people came.") == "On 03/05 10 people came.")
        #expect(english("On 3 May 8 people came.", DictationDateFormat(monthInWords: true)) == "On 3 May 8 people came.")
        // Le mois d'abord, le nombre ensuite : rien ne change.
        #expect(english("On May 3 8 people came.") == "On 03/05 8 people came.")
        #expect(english("May 3 June 4") == "03/05 04/06")
        #expect(english("May 3, June 4") == "03/05, 04/06")
    }

    /// « the » n'appartient à la date que devant un ordinal ou « of » : « The 3 May meeting » perdait son article
    /// (« 03/05 meeting is cancelled »).
    @Test func theArticleStaysUnlessItIntroducesAnOrdinal() {
        #expect(english("The 3 May meeting is cancelled.") == "The 03/05 meeting is cancelled.")
        #expect(english("Submit before the 31 May deadline.") == "Submit before the 31/05 deadline.")
        #expect(english("Submit before the 31 May deadline.", DictationDateFormat(monthInWords: true)) == "Submit before the 31 May deadline.")
        // Avec un ordinal ou « of », toute la tournure est la date, comme avant.
        #expect(english("We leave on the 3rd of November.") == "We leave on 03/11.")
        #expect(english("We leave on the 24th October.") == "We leave on 24/10.")
        #expect(english("We leave on the 24 of October.") == "We leave on 24/10.")
    }

    /// « May 14/15 » ou « May 4-5 » : deux jours. Le premier seul devenait une date et le second s'y collait
    /// (« 14/05/15 », relu ensuite comme le 14 mai 2015).
    @Test func twoDaysAfterAMonthAreNotADate() {
        for text in ["We're away May 14/15.", "We're away May 4-5.", "We're away May 4–5.", "Closed May 1.5 days."] {
            for format in [DictationDateFormat(), DictationDateFormat(order: .monthDayYear), DictationDateFormat(monthInWords: true)] {
                #expect(english(text, format) == text, "« \(text) »")
            }
        }
        #expect(english("We're away on May 14.") == "We're away on 14/05.")
    }

    /// Ces trois écritures étaient relues autrement à la passe suivante (« 3 May 8 » → « 3 8 May »).
    @Test func rewrittenEnglishDatesStaySettled() {
        let words = DictationDateFormat(monthInWords: true)
        for text in ["We met on May 3 8 people.", "We met on the May 31 deadline.", "Away May 14/00.", "the 29/11/80 report"] {
            for format in [words, DictationDateFormat(order: .monthDayYear), DictationDateFormat()] {
                let once = english(text, format)
                #expect(english(once, format) == once, "« \(text) » → « \(once) »")
            }
        }
    }

    // MARK: Cas limites

    @Test func calendarLimits() {
        // Années bissextiles : le 29 février n'existe que certaines années.
        #expect(french("Le 29/02/2024 et le 29/02/2026.") == "Le 29/02/2024 et le 29/02/2026.")
        #expect(french("Le 29/2/2024.") == "Le 29/02/2024.")
        #expect(french("Le 29/2/2026.") == "Le 29/2/2026.")
        #expect(french("Le 29/2/2000 et le 29/2/1900.") == "Le 29/02/2000 et le 29/2/1900.")
        // Trente jours en avril, juin, septembre et novembre.
        #expect(french("Le 31/4/2026 et le 30/4/2026.") == "Le 31/4/2026 et le 30/04/2026.")
        // Jour ou mois nuls, années hors des bornes de lecture.
        #expect(french("Le 0/5/2026 et le 5/0/2026.") == "Le 0/5/2026 et le 5/0/2026.")
        #expect(french("Le 3/5/0999 et le 3/5/3000.") == "Le 3/5/0999 et le 3/5/3000.")
        // Une année sur deux chiffres se situe au plus près de l'année de référence, vingt ans d'avance au plus.
        #expect(french("Le 3/5/46.") == "Le 03/05/2046.")
        #expect(french("Le 3/5/47.") == "Le 03/05/1947.")
    }

    @Test func clockLimits() {
        #expect(french("Rendez-vous à 0 h.") == "Rendez-vous à 0 h.")
        #expect(french("Rendez-vous à 0h30.") == "Rendez-vous à 0 h 30.")
        #expect(french("Rendez-vous à 23h59.") == "Rendez-vous à 23 h 59.")
        #expect(french("Rendez-vous à 24h00 ou à 12h60.") == "Rendez-vous à 24h00 ou à 12h60.")
        // Midi et minuit sur 12 h.
        #expect(english("At 12 PM and at 12 AM.", DictationDateFormat(clock: .twentyFourHour)) == "At 12:00 and at 0:00.")
        #expect(french("À 12 AM, puis à 12 PM.") == "À 0 h, puis à 12 h.")
        #expect(english("At 13 PM.") == "At 13 PM.")
    }

    @Test func emptyAndMarkupOnlyTexts() {
        for format in [DictationDateFormat(), DictationDateFormat(order: .iso, monthInWords: true, clock: .twelveHour)] {
            for english in [false, true] {
                for text in ["", " ", "\n", "0", "/", "1/", "/1", "h", "PM", "le", "on", "le 3", "à 3", "at 3", "```", "`3/11`", "1:2:3"] {
                    #expect(DateTimeWriter.apply(text, format: format, english: english, referenceYear: 2026) == text, "« \(text) »")
                }
            }
        }
    }

    // MARK: Propriétés

    /// Repasser sur un texte déjà mis au format ne change plus rien (docs/COMPORTEMENT.md, « Dates et heures »).
    @Test func applyingTwiceChangesNothingMore() {
        forAll(1_500, seed: 0x4441_5431, { g in
            let english = g.chance(50)
            return (text: SampleText.sentence(&g, english: english), format: g.pick(Self.formats), english: english)
        }) { sample in
            let once = DateTimeWriter.apply(sample.text, format: sample.format, english: sample.english, referenceYear: 2026)
            let twice = DateTimeWriter.apply(once, format: sample.format, english: sample.english, referenceYear: 2026)
            return twice == once ? nil : "« \(sample.text) » → « \(once) » → « \(twice) » (\(sample.format), anglais : \(sample.english))"
        }
    }

    /// Sans chiffre, rien ne bouge : mois, jours de la semaine, « h » ou « PM » seuls ne sont pas des dates.
    @Test func textWithoutDigitsIsLeftAlone() {
        forAll(1_500, seed: 0x4441_5432, { g in
            (text: g.chance(70) ? SampleText.digitless(&g) : SampleText.unicode(&g), format: g.pick(Self.formats), english: g.chance(50))
        }) { sample in
            guard !sample.text.contains(where: { $0.isASCII && $0.isNumber }) else { return nil }
            let output = DateTimeWriter.apply(sample.text, format: sample.format, english: sample.english, referenceYear: 2026)
            return output == sample.text ? nil : "« \(sample.text) » → « \(output) »"
        }
    }

    /// Code, adresse web et e-mail ne sont jamais retouchés, même pleins de dates et d'heures.
    @Test func codeAndAddressesAreNeverTouched() {
        forAll(1_000, seed: 0x4441_5433, { g in
            let english = g.chance(50)
            let inner = SampleText.sentence(&g, english: english).replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "\n", with: " ")
            let wrapped: String
            switch g.int(0...2) {
            case 0: wrapped = "`" + inner + "`"
            case 1: wrapped = "```\n" + inner + "\n```"
            default: wrapped = "https://exemple.fr/" + inner.unicodeScalars.map { $0.properties.isWhitespace ? "-" : String($0) }.joined()
            }
            return (wrapped: wrapped, format: g.pick(Self.formats), english: english)
        }) { sample in
            let text = "Voir " + sample.wrapped + " ici"
            let output = DateTimeWriter.apply(text, format: sample.format, english: sample.english, referenceYear: 2026)
            return output == text ? nil : "« \(text) » → « \(output) »"
        }
    }

    /// Longueur bornée : une date ou une heure s'allonge au plus de son mois en toutes lettres.
    @Test func lengthGrowsBoundedly() {
        forAll(1_500, seed: 0x4441_5434, { g in
            let english = g.chance(50)
            return (text: SampleText.sentence(&g, english: english), format: g.pick(Self.formats), english: english)
        }) { sample in
            let output = DateTimeWriter.apply(sample.text, format: sample.format, english: sample.english, referenceYear: 2026)
            let numbers = sample.text.split(whereSeparator: { !$0.isNumber }).count
            let bound = sample.text.count + 12 * numbers
            return output.count <= bound ? nil : "« \(sample.text) » → « \(output) » (\(output.count) > \(bound))"
        }
    }

    /// Tout ce que le format écrit, le post-traitement le laisse tel quel : une date ou une heure déjà rendue dans ce
    /// format, après son repère, est un point fixe. Les exemples de la consigne en font partie.
    @Test func renderedDatesAndTimesAreFixedPoints() {
        forAll(3_000, seed: 0x4441_5435, { g in
            let english = g.chance(50)
            let format = g.pick(Self.formats)
            let date = format.date(day: g.int(1...28), month: g.int(1...12), year: g.chance(50) ? g.int(1950...2070) : nil, english: english)
            let time = format.time(hour: g.int(0...23), minute: g.chance(50) ? 0 : g.int(1...59), english: english)
            let dateCue = english ? g.pick(["on ", "until ", "Monday "]) : g.pick(["le ", "du ", "mardi "])
            let timeCue = english ? g.pick(["at ", "until ", "from "]) : g.pick(["à ", "vers ", "dès "])
            return (text: dateCue + date + g.pick(["", ".", ", ok"]) + " " + timeCue + time + g.pick(["", ".", " ok"]), format: format, english: english)
        }) { sample in
            let output = DateTimeWriter.apply(sample.text, format: sample.format, english: sample.english, referenceYear: 2026)
            return output == sample.text ? nil : "« \(sample.text) » → « \(output) » (\(sample.format))"
        }
        let examples = Self.formats.flatMap { format in
            [false, true].flatMap { english -> [(text: String, format: DictationDateFormat, english: Bool)] in
                let samples = format.samples(english: english)
                let texts = english ? ["on " + samples[0], "on " + samples[1], "at " + samples[2]] : ["le " + samples[0], "le " + samples[1], "à " + samples[2]]
                return texts.map { (text: $0, format: format, english: english) }
            }
        }
        let rewritten = examples.first { DateTimeWriter.apply($0.text, format: $0.format, english: $0.english, referenceYear: 2026) != $0.text }
        #expect(rewritten == nil, "exemple de la consigne réécrit : « \(rewritten?.text ?? "") » (\(String(describing: rewritten?.format)))")
    }

    /// Une année que personne n'a dite est retirée, une année dite reste ; le texte n'est jamais allongé.
    @Test func unspokenYearsOnlyShrinkTheText() {
        forAll(1_500, seed: 0x4441_5436, { g in
            let english = g.chance(50)
            return (written: SampleText.sentence(&g, english: english), heard: SampleText.sentence(&g, english: english))
        }) { sample in
            let heard = sample.heard.split(separator: " ").map(String.init)
            let output = DateTimeWriter.removingUnspokenYears(from: sample.written, heard: heard)
            guard output.count <= sample.written.count else { return "« \(sample.written) » → « \(output) »" }
            // Tout ce qui a été dit, mot pour mot, ne perd jamais son année.
            let written = sample.written.split(separator: " ").map(String.init)
            let kept = DateTimeWriter.removingUnspokenYears(from: sample.written, heard: written)
            return kept == sample.written ? nil : "« \(sample.written) » perd une année dite : « \(kept) »"
        }
    }

    /// Aucune entrée, même faite de caractères quelconques, ne fait planter le post-traitement ni le garde-fou des années.
    @Test func arbitraryTextNeverCrashes() {
        forAll(2_000, seed: 0x4441_5437, { g in
            let english = g.chance(50)
            let text = g.chance(50) ? SampleText.unicode(&g, length: 0...80)
                : SampleText.unicode(&g) + SampleText.fragment(&g, english: english) + SampleText.unicode(&g)
            return (text: text, format: g.pick(Self.formats), english: english, heard: SampleText.unicode(&g))
        }) { sample in
            _ = DateTimeWriter.apply(sample.text, format: sample.format, english: sample.english, referenceYear: 2026)
            _ = DateTimeWriter.removingUnspokenYears(from: sample.text, heard: sample.heard.split(separator: " ").map(String.init))
            _ = MomentReading.sameMoment(written: sample.text.split(separator: " ").map(String.init),
                                         heard: sample.heard.split(separator: " ").map(String.init))
            return nil
        }
    }
}
