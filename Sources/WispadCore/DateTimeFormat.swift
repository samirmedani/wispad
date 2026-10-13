import Foundation

// MARK: - Format choisi

/// Format des dates et des heures écrites par la correction (Réglages › Mise en forme). La consigne en reçoit des
/// exemples rendus dans ce format ; `DateTimeWriter` l'impose ensuite, sans le modèle, aux dates et aux heures déjà
/// en chiffres. Lecture tolérante champ par champ : un champ illisible reprend seul sa valeur par défaut.
public struct DictationDateFormat: Codable, Equatable, Sendable {
    /// Ordre du jour, du mois et de l'année.
    public enum Order: String, Codable, CaseIterable, Sendable {
        /// 24/10/2026
        case dayMonthYear
        /// 10/24/2026
        case monthDayYear
        /// 2026-10-24 (ISO 8601) : tirets, année sur quatre chiffres et zéros imposés.
        case iso
    }

    public enum Separator: String, Codable, CaseIterable, Sendable {
        case slash, dot, hyphen, space

        public var character: String {
            switch self {
            case .slash: return "/"
            case .dot: return "."
            case .hyphen: return "-"
            case .space: return " "
            }
        }
    }

    /// Horloge. `byLanguage` : 24 h en français, 12 h (AM/PM) en anglais.
    public enum Clock: String, Codable, CaseIterable, Sendable {
        case byLanguage, twentyFourHour, twelveHour
    }

    /// Écriture d'une heure sur 24 h en français ; l'anglais écrit toujours « 14:30 ».
    public enum TimeStyle: String, Codable, CaseIterable, Sendable {
        /// 14h30 : l'écriture courante, d'un seul bloc, par défaut dans l'app (choix du 13 octobre 2026).
        case compact
        /// 14 h 30, typographie française (format de référence de la consigne et des tests).
        case spaced
        /// 14:30
        case colon
    }

    public var order: Order
    public var separator: Separator
    public var fourDigitYear: Bool
    /// « 03/11 » plutôt que « 3/11 ».
    public var leadingZero: Bool
    /// « 24 octobre 2026 » : mois en lettres, jour et année en chiffres.
    public var monthInWords: Bool
    public var clock: Clock
    public var timeStyle: TimeStyle

    public init(order: Order = .dayMonthYear, separator: Separator = .slash, fourDigitYear: Bool = true,
                leadingZero: Bool = true, monthInWords: Bool = false, clock: Clock = .byLanguage,
                timeStyle: TimeStyle = .spaced) {
        self.order = order
        self.separator = separator
        self.fourDigitYear = fourDigitYear
        self.leadingZero = leadingZero
        self.monthInWords = monthInWords
        self.clock = clock
        self.timeStyle = timeStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = DictationDateFormat()
        order = value(.order, defaults.order)
        separator = value(.separator, defaults.separator)
        fourDigitYear = value(.fourDigitYear, defaults.fourDigitYear)
        leadingZero = value(.leadingZero, defaults.leadingZero)
        monthInWords = value(.monthInWords, defaults.monthInWords)
        clock = value(.clock, defaults.clock)
        timeStyle = value(.timeStyle, defaults.timeStyle)
    }

    /// Heures sur 12 h (AM/PM) dans cette langue.
    public func usesTwelveHour(english: Bool) -> Bool {
        switch clock {
        case .byLanguage: return english
        case .twentyFourHour: return false
        case .twelveHour: return true
        }
    }

    /// Une date dans ce format ; sans année (`year` nil), une date partielle : « 03/11 », « 3 novembre ».
    public func date(day: Int, month: Int, year: Int?, english: Bool) -> String {
        if monthInWords { return wordDate(day: day, month: month, year: year, english: english) }
        if order == .iso {
            let monthDay = Self.twoDigits(month) + "-" + Self.twoDigits(day)
            return year.map { String($0) + "-" + monthDay } ?? monthDay
        }
        let dayText = leadingZero ? Self.twoDigits(day) : String(day)
        let monthText = leadingZero ? Self.twoDigits(month) : String(month)
        let pair = order == .monthDayYear ? [monthText, dayText] : [dayText, monthText]
        guard let year else { return pair.joined(separator: separator.character) }
        let yearText = fourDigitYear ? String(year) : Self.twoDigits(year % 100)
        return (pair + [yearText]).joined(separator: separator.character)
    }

    /// Une heure dans ce format : « 14 h 30 », « 14h30 », « 14:30 », « 2:30 PM » ; sans minutes, « 14 h », « 2 PM ».
    public func time(hour: Int, minute: Int, english: Bool) -> String {
        if usesTwelveHour(english: english) {
            let shown = hour % 12 == 0 ? 12 : hour % 12
            let suffix = hour < 12 ? "AM" : "PM"
            return minute == 0 ? "\(shown) \(suffix)" : "\(shown):\(Self.twoDigits(minute)) \(suffix)"
        }
        if english { return "\(hour):\(Self.twoDigits(minute))" }
        switch timeStyle {
        case .spaced: return minute == 0 ? "\(hour) h" : "\(hour) h \(Self.twoDigits(minute))"
        case .compact: return minute == 0 ? "\(hour)h" : "\(hour)h\(Self.twoDigits(minute))"
        case .colon: return "\(hour):\(Self.twoDigits(minute))"
        }
    }

    /// Exemples de l'aperçu : date complète, date sans année, heure.
    public func samples(english: Bool) -> [String] {
        [date(day: 24, month: 10, year: 2026, english: english), date(day: 3, month: 11, year: nil, english: english),
         time(hour: 14, minute: 30, english: english)]
    }

    /// Règle de la consigne, avec des exemples rendus dans ce format.
    public func instructions(english: Bool) -> String {
        let full = date(day: 24, month: 10, year: 2026, english: english)
        let partial = date(day: 3, month: 11, year: nil, english: english)
        let first = date(day: 1, month: 5, year: nil, english: english)
        let rangeEnd = date(day: 5, month: 11, year: nil, english: english)
        let halfPast = time(hour: 14, minute: 30, english: english)
        let afternoon = time(hour: 14, minute: 0, english: english)
        if english {
            let range = monthInWords ? "" : "; \"from November third to fifth\" → \"from \(partial) to \(rangeEnd)\""
            return """
            Dates and times: when the context clearly shows a date (day and month, or a full date) or a clock time (the time of an appointment or a schedule), write it in this format, with only the numbers that were spoken. Fictional examples: "October twenty-fourth twenty twenty-six" → "\(full)"; "November third" or "the third of November" → "\(partial)"; "May first" → "\(first)"\(range); "the meeting is at two thirty in the afternoon" → "the meeting is at \(halfPast)"; "at fourteen hundred" → "at \(afternoon)".
            Never invent a year that was not spoken: a date without a year stays without a year. A weekday alone stays a word ("Tuesday", "next Tuesday"); a year alone, a month alone, an age or a quantity are not dates. A duration stays a duration, with its unit in words: "two hours of driving" → "2 hours of driving", "in three hours" → "in 3 hours". When in doubt, keep the spoken form.
            """
        }
        let range = monthInWords ? "" : " ; « du 3 au 5 novembre » → « du \(partial) au \(rangeEnd) »"
        return """
        Dates et heures : quand le contexte montre sans ambiguïté une date (jour et mois, ou date complète) ou une heure (heure d'un rendez-vous, d'un horaire), écris-la dans ce format, avec les seuls nombres prononcés. Exemples fictifs : « le vingt-quatre octobre deux mille vingt-six » → « le \(full) » ; « le trois novembre » ou « le 3 du 11 » → « le \(partial) » ; « le premier mai » → « le \(first) »\(range) ; « rendez-vous à quatorze heures trente » → « rendez-vous à \(halfPast) » ; « à deux heures de l'après-midi » → « à \(afternoon) ».
        N'invente jamais une année qui n'a pas été dite : une date sans année reste sans année. Un jour de la semaine seul reste en lettres (« mardi », « mardi prochain ») ; une année seule, un mois seul, un âge ou une quantité ne sont pas des dates. Une durée reste une durée, avec son unité en toutes lettres : « deux heures de route » → « 2 heures de route », « dans trois heures » → « dans 3 heures ». Dans le doute, garde la forme dictée.
        """
    }

    private func wordDate(day: Int, month: Int, year: Int?, english: Bool) -> String {
        if english {
            let name = Self.englishMonths[month - 1]
            if order == .monthDayYear { return year.map { "\(name) \(day), \($0)" } ?? "\(name) \(day)" }
            return year.map { "\(day) \(name) \($0)" } ?? "\(day) \(name)"
        }
        let dayText = day == 1 ? "1er" : String(day)
        let name = Self.frenchMonths[month - 1]
        return year.map { "\(dayText) \(name) \($0)" } ?? "\(dayText) \(name)"
    }

    static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    static let frenchMonths = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre",
                               "octobre", "novembre", "décembre"]
    static let englishMonths = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                "October", "November", "December"]
}

// MARK: - Post-traitement

/// Post-traitement déterministe du texte corrigé : une date ou une heure déjà écrite en chiffres (ou au mois en
/// lettres) prend le format choisi, sans dépendre du modèle. Seul ce qui est sans ambiguïté change :
/// - une date complète (« 3/11/2026 », « 2026-11-03 », « 3 novembre 2026 », « November 3, 2026 ») ;
/// - une date sans année au mois en lettres (« 3 novembre », « du 3 au 5 novembre »), ou en chiffres après « le »,
///   « du », « au » ou un jour de la semaine (« le 3/11 », « le 3 du 11 ») ;
/// - une heure suivie de AM/PM, de « du matin », « de l'après-midi » ou « du soir », ou précédée de « à », « vers »,
///   « dès », « jusqu'à », « à partir de », « il est », d'un jour de la semaine ou de « demain » (anglais : at, around,
///   by, until, before, after, from, between), ou reliée à une telle heure (« de 14 h à 16 h », « à 8 h, 12 h et 20 h »).
/// Jamais une durée (« 2 heures de route », « à 2 h de Paris »), une fraction (« 8/10 »), une version (« 1.12.20 »),
/// un numéro, une adresse ni du code. Rendre deux fois le même texte ne change plus rien.
public enum DateTimeWriter {
    public static var currentYear: Int {
        Calendar(identifier: .gregorian).component(.year, from: Date())
    }

    /// `english` : langue de la consigne (noms des mois, écriture des heures). `referenceYear` situe une année dite
    /// sur deux chiffres (« 26 » → 2026, « 85 » → 1985).
    public static func apply(_ text: String, format: DictationDateFormat, english: Bool, referenceYear: Int = currentYear) -> String {
        guard text.contains(where: { $0.isASCII && $0.isNumber }) else { return text }
        var pass = Pass(text)
        let dayFirst = format.order == .dayMonthYear || (format.order == .iso && !english)
        func render(day: Int, month: Int, year: Int?) -> String {
            format.date(day: day, month: month, year: year, english: english)
        }

        if !english {
            // « du 3 au 5 novembre » : le mois vaut pour les deux jours.
            for match in frenchMonthRange.matches(in: text, range: pass.whole) where pass.isFree(match.range) {
                guard let first = day(pass.group(match, 1)), let second = day(pass.group(match, 3)),
                      let month = monthNumber(pass.group(match, 4)) else { continue }
                let yearText = pass.group(match, 5)
                let year = yearText.flatMap { fullYear($0, reference: referenceYear) }
                guard yearText == nil || year != nil, first < second, isValid(day: second, month: month, year: year),
                      year != nil || followsCleanly(pass, after: match.range) else { continue }
                let link = pass.group(match, 2) ?? " "
                pass.claim(match.range, with: format.monthInWords ? nil
                    : render(day: first, month: month, year: year) + link + render(day: second, month: month, year: year))
            }
            // « 3 novembre », « 1er novembre 2026 ».
            for match in frenchMonthDate.matches(in: text, range: pass.whole) where pass.isFree(match.range) {
                guard let day = day(pass.group(match, 1)), let month = monthNumber(pass.group(match, 2)) else { continue }
                let yearText = pass.group(match, 3)
                let year = yearText.flatMap { fullYear($0, reference: referenceYear) }
                guard yearText == nil || year != nil, isValid(day: day, month: month, year: year),
                      year != nil || followsCleanly(pass, after: match.range) else { continue }
                pass.claim(match.range, with: render(day: day, month: month, year: year))
            }
            // « le 3 du 11 » : le mois dit par son numéro.
            for match in frenchDayOfMonth.matches(in: text, range: pass.whole) {
                let dateRange = NSRange(location: match.range(at: 3).location,
                                        length: NSMaxRange(match.range(at: 4)) - match.range(at: 3).location)
                guard pass.isFree(dateRange), let day = day(pass.group(match, 3)), let month = pass.group(match, 4).flatMap({ Int($0) }),
                      isValid(day: day, month: month, year: nil), followsCleanly(pass, after: dateRange) else { continue }
                pass.claim(dateRange, with: render(day: day, month: month, year: nil))
            }
        } else {
            // « October 24, 2026 », « October 24th », « 24 October 2026 », « the 24th of October ». Deux lectures qui se
            // chevauchent : la première dans le texte l'emporte (« on 3 May 8 people came » : le 3 mai, pas le 8).
            let monthFirst = englishMonthFirst.matches(in: text, range: pass.whole).map { (match: $0, month: 1, day: 2, year: 4) }
            let dayFirst = englishDayFirst.matches(in: text, range: pass.whole).map { (match: $0, month: 2, day: 1, year: 3) }
            for reading in (monthFirst + dayFirst).sorted(by: { $0.match.range.location < $1.match.range.location })
            where pass.isFree(reading.match.range) {
                let match = reading.match
                guard let month = monthNumber(pass.group(match, reading.month)), let day = day(pass.group(match, reading.day)) else { continue }
                let yearText = pass.group(match, reading.year)
                let year = yearText.flatMap { fullYear($0, reference: referenceYear) }
                guard yearText == nil || year != nil, isValid(day: day, month: month, year: year) else { continue }
                pass.claim(match.range, with: render(day: day, month: month, year: year))
            }
        }

        // « 2026-11-03 », « 2026/11/03 ».
        for match in yearFirstDate.matches(in: text, range: pass.whole) where pass.isFree(match.range) {
            guard let year = pass.group(match, 1).flatMap({ fullYear($0, reference: referenceYear) }),
                  let month = pass.group(match, 3).flatMap({ Int($0) }), let day = pass.group(match, 4).flatMap({ Int($0) }),
                  isValid(day: day, month: month, year: year) else { continue }
            pass.claim(match.range, with: render(day: day, month: month, year: year))
        }
        // « 03/11/2026 », « 3.11.2026 », « 03/11/26 » : l'ordre réglé d'abord, l'autre s'il est seul possible.
        for match in yearLastDate.matches(in: text, range: pass.whole) where pass.isFree(match.range) {
            guard let separator = pass.group(match, 2), let yearText = pass.group(match, 4),
                  separator == "/" || yearText.count == 4,
                  let year = fullYear(yearText, reference: referenceYear),
                  let first = pass.group(match, 1).flatMap({ Int($0) }), let second = pass.group(match, 3).flatMap({ Int($0) }),
                  let (day, month) = dayAndMonth(first, second, dayFirst: dayFirst, year: year) else { continue }
            pass.claim(match.range, with: render(day: day, month: month, year: year))
        }
        // « le 3/11 », « mardi 03/11 », « on 11/3 ».
        for match in (english ? englishCuedDayMonth : frenchCuedDayMonth).matches(in: text, range: pass.whole) {
            let dateRange = NSRange(location: match.range(at: 3).location,
                                    length: NSMaxRange(match.range(at: 4)) - match.range(at: 3).location)
            guard pass.isFree(dateRange),
                  let first = pass.group(match, 3).flatMap({ Int($0) }), let second = pass.group(match, 4).flatMap({ Int($0) }),
                  let (day, month) = dayAndMonth(first, second, dayFirst: dayFirst, year: nil) else { continue }
            pass.claim(dateRange, with: render(day: day, month: month, year: nil))
        }

        formatTimes(&pass, format: format, english: english)
        return pass.result
    }

    /// Dates complètes dont l'année n'a pas été dite : l'année est retirée (« 03/11/2026 » → « 03/11 », « 3 novembre
    /// 2026 » → « 3 novembre »). `heard` : mots entendus (transcription, autre écoute). Une année dite en chiffres, en
    /// lettres (« deux mille vingt-six », « twenty twenty-six ») ou sur deux chiffres (« vingt-six ») reste.
    static func removingUnspokenYears(from text: String, heard: [String]) -> String {
        guard text.contains(where: { $0.isASCII && $0.isNumber }) else { return text }
        let said = MomentReading.numbers(in: heard)
        var pass = Pass(text)
        /// `day` et `month` dans un ordre ou dans l'autre : tous deux se retirent de ce qui a été dit.
        func check(_ match: NSTextCheckingResult, day: Int?, month: Int?, year: Int?, kept: NSRange) {
            guard let day, let month, let year,
                  isValid(day: day, month: month, year: nil) || isValid(day: month, month: day, year: nil) else { return }
            let spoken = MomentReading.yearWasSaid(year, day: day, month: month, in: said)
            pass.claim(match.range, with: spoken ? nil : (text as NSString).substring(with: kept))
        }
        for match in yearFirstDate.matches(in: text, range: pass.whole) where pass.isFree(match.range) {
            let kept = NSRange(location: match.range(at: 3).location, length: NSMaxRange(match.range) - match.range(at: 3).location)
            check(match, day: pass.group(match, 4).flatMap { Int($0) }, month: pass.group(match, 3).flatMap { Int($0) },
                  year: pass.group(match, 1).flatMap { Int($0) }, kept: kept)
        }
        for match in yearLastDate.matches(in: text, range: pass.whole) where pass.isFree(match.range) {
            // « 1.12.20 » est une version : une année sur deux chiffres ne suit qu'une barre oblique.
            guard pass.group(match, 2) == "/" || pass.group(match, 4)?.count == 4 else { continue }
            let kept = NSRange(location: match.range.location, length: NSMaxRange(match.range(at: 3)) - match.range.location)
            check(match, day: pass.group(match, 1).flatMap { Int($0) }, month: pass.group(match, 3).flatMap { Int($0) },
                  year: pass.group(match, 4).flatMap { Int($0) }, kept: kept)
        }
        for match in frenchMonthDate.matches(in: text, range: pass.whole) where pass.isFree(match.range) && match.range(at: 3).location != NSNotFound {
            let kept = NSRange(location: match.range.location, length: NSMaxRange(match.range(at: 2)) - match.range.location)
            check(match, day: day(pass.group(match, 1)), month: monthNumber(pass.group(match, 2)),
                  year: pass.group(match, 3).flatMap { Int($0) }, kept: kept)
        }
        for match in englishMonthFirst.matches(in: text, range: pass.whole) where pass.isFree(match.range) && match.range(at: 4).location != NSNotFound {
            let kept = NSRange(location: match.range.location, length: NSMaxRange(match.range(at: 3)) - match.range.location)
            check(match, day: day(pass.group(match, 2)), month: monthNumber(pass.group(match, 1)),
                  year: pass.group(match, 4).flatMap { Int($0) }, kept: kept)
        }
        for match in englishDayFirst.matches(in: text, range: pass.whole) where pass.isFree(match.range) && match.range(at: 3).location != NSNotFound {
            let kept = NSRange(location: match.range.location, length: NSMaxRange(match.range(at: 2)) - match.range.location)
            check(match, day: day(pass.group(match, 1)), month: monthNumber(pass.group(match, 2)),
                  year: pass.group(match, 3).flatMap { Int($0) }, kept: kept)
        }
        return pass.result
    }

    // MARK: Heures

    private struct ClockTime {
        var range: NSRange
        var hour: Int
        var minute: Int
        /// AM/PM écrit, ou « du matin », « de l'après-midi », « du soir » : l'heure ne peut pas être une autre.
        var settled: Bool
        /// Point final avalé avec « p.m. » : il revient après l'heure.
        var period = false
        var cued = false
        var opens = false
        var lasts = false
    }

    private static func formatTimes(_ pass: inout Pass, format: DictationDateFormat, english: Bool) {
        let text = pass.text
        var times: [ClockTime] = []
        for match in meridiemTime.matches(in: text, range: pass.whole) where pass.isFree(match.range) {
            guard let hour = pass.group(match, 1).flatMap({ Int($0) }), (1...12).contains(hour) else { continue }
            let minute = pass.group(match, 2).flatMap { Int($0) } ?? 0
            guard minute < 60 else { continue }
            let afternoon = pass.group(match, 3)?.lowercased() == "p"
            let value = afternoon ? (hour == 12 ? 12 : hour + 12) : (hour == 12 ? 0 : hour)
            // « at 2 p.m. Then… » : le point de « p.m. » finissait aussi la phrase.
            let period = pass.group(match, 4) == "." && endsSentence(pass, after: match.range)
            times.append(ClockTime(range: match.range, hour: value, minute: minute, settled: true, period: period))
        }
        let clock = english ? englishClock : frenchClock
        for match in clock.matches(in: text, range: pass.whole) where pass.isFree(match.range) && !times.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
            guard let hour = pass.group(match, 1).flatMap({ Int($0) }), hour < 24 else { continue }
            let minuteText = english ? pass.group(match, 2) : (pass.group(match, 3) ?? pass.group(match, 4))
            let minute = minuteText.flatMap { Int($0) } ?? 0
            guard minute < 60 else { continue }
            let spelled = !english && (pass.group(match, 2)?.count ?? 0) > 1
            let after = pass.following(match.range)
            if let qualifier = (english ? englishQualifier : frenchQualifier).firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) {
                let word = (after as NSString).substring(with: qualifier.range(at: 1)).lowercased()
                guard let value = qualified(hour, by: word) else { continue }
                let range = NSRange(location: match.range.location, length: match.range.length + qualifier.range.length)
                times.append(ClockTime(range: range, hour: value, minute: minute, settled: true))
                continue
            }
            let before = pass.preceding(match.range)
            let cue = english ? englishCue : (spelled ? frenchSpelledCue : frenchCue)
            var time = ClockTime(range: match.range, hour: hour, minute: minute, settled: false)
            // « de 2 à 3 heures » : « à » relie deux quantités, pas une heure ; « le 24 à 14 h » reste une heure.
            let quantities = !english && matches(numberRange, before) && !matches(dayThenTime, before)
            time.cued = matches(cue, before) && !quantities
            time.opens = matches(english ? englishOpener : frenchOpener, before)
            time.lasts = matches(english ? englishDuration : frenchDuration, after)
            times.append(time)
        }
        times.sort { $0.range.location < $1.range.location }
        // Deux heures reliées (« de 14 h à 16 h », « 14h-16h ») : l'une situe l'autre, une durée les écarte toutes deux.
        var linked = Array(repeating: false, count: times.count)
        for index in times.indices.dropLast() {
            let current = times[index], next = times[index + 1]
            let start = NSMaxRange(current.range)
            guard next.range.location >= start else { continue }
            let gap = pass.source.substring(with: NSRange(location: start, length: next.range.location - start))
            guard matches(english ? englishLink : frenchLink, gap), !current.settled || !next.settled else { continue }
            let anchored = linked[index] || current.cued || current.opens || current.settled || next.cued || next.settled
            if anchored, !next.lasts {
                linked[index] = true
                linked[index + 1] = true
            } else if next.lasts, gap.trimmingCharacters(in: .whitespaces) != "," {
                // « de 2 h à 3 h de route » : toute la plage est une durée ; une virgule sépare deux idées.
                times[index].lasts = true
            }
        }
        // Sur 12 h, « à 2 h » peut être 2 h ou 14 h : seule une heure sûre passe en AM/PM, ou une heure reliée à une
        // heure sûre (« de 9 h à 17 h » est écrit sur 24 h).
        var sure = times.map { $0.settled || !(1...11).contains($0.hour) }
        for index in Array(times.indices.dropLast()) + times.indices.dropLast().reversed()
        where linked[index] && linked[index + 1] && (sure[index] || sure[index + 1]) {
            sure[index] = true
            sure[index + 1] = true
        }
        for (index, time) in times.enumerated() {
            guard time.settled || ((time.cued || linked[index]) && !time.lasts) else { continue }
            if format.usesTwelveHour(english: english), !sure[index] { continue }
            pass.claim(time.range, with: format.time(hour: time.hour, minute: time.minute, english: english) + (time.period ? "." : ""))
        }
    }

    /// Heure sur 24 h d'après « du matin », « de l'après-midi », « du soir », « de la nuit » (anglais : in the morning,
    /// in the afternoon, in the evening, at night) ; nil si l'ensemble n'a pas de sens (« 12 h du soir »).
    private static func qualified(_ hour: Int, by word: String) -> Int? {
        let folded = fold(word)
        if ["apres-midi", "aprem", "afternoon"].contains(where: folded.contains) {
            if hour >= 12 { return hour }
            return (1...7).contains(hour) ? hour + 12 : nil
        }
        if ["soir", "evening"].contains(where: folded.contains) {
            if hour >= 13 { return hour }
            return (4...11).contains(hour) ? hour + 12 : nil
        }
        if ["nuit", "night"].contains(where: folded.contains) {
            if hour == 0 || (1...5).contains(hour) || hour >= 20 { return hour }
            if (8...11).contains(hour) { return hour + 12 }
            return hour == 12 ? 0 : nil
        }
        // Matin, matinée, morning.
        return hour <= 11 ? hour : nil
    }

    // MARK: Lecture

    /// Jour écrit : « 3 », « 03 », « 1er ».
    private static func day(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int(text.prefix { $0.isASCII && $0.isNumber })
    }

    static func monthNumber(_ name: String?) -> Int? {
        guard let name else { return nil }
        return monthsByName[fold(name)]
    }

    static let monthsByName: [String: Int] = {
        var names: [String: Int] = [:]
        for (index, name) in DictationDateFormat.frenchMonths.enumerated() { names[fold(name)] = index + 1 }
        for (index, name) in DictationDateFormat.englishMonths.enumerated() { names[fold(name)] = index + 1 }
        return names
    }()

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// Année écrite sur quatre chiffres, ou sur deux située au plus près (« 26 » → 2026, « 85 » → 1985).
    private static func fullYear(_ text: String, reference: Int) -> Int? {
        guard let value = Int(text) else { return nil }
        if text.count == 4 { return (1000...2999).contains(value) ? value : nil }
        guard text.count == 2 else { return nil }
        return 2000 + value <= reference + 20 ? 2000 + value : 1900 + value
    }

    private static func isValid(day: Int, month: Int, year: Int?) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        switch month {
        case 2:
            let leap = year.map { $0 % 4 == 0 && ($0 % 100 != 0 || $0 % 400 == 0) } ?? true
            return day <= (leap ? 29 : 28)
        case 4, 6, 9, 11: return day <= 30
        default: return day <= 31
        }
    }

    /// Jour et mois de deux nombres : dans l'ordre réglé s'il est valable, sinon dans l'autre.
    private static func dayAndMonth(_ first: Int, _ second: Int, dayFirst: Bool, year: Int?) -> (Int, Int)? {
        let preferred = dayFirst ? (first, second) : (second, first)
        if isValid(day: preferred.0, month: preferred.1, year: year) { return preferred }
        let other = (preferred.1, preferred.0)
        return isValid(day: other.0, month: other.1, year: year) ? other : nil
    }

    /// Une date sans année n'est pas suivie d'un nombre qui pourrait en être une (« le 24 octobre 26 »).
    private static func followsCleanly(_ pass: Pass, after range: NSRange) -> Bool {
        let after = pass.following(range)
        return !matches(trailingNumber, after) || matches(frenchClock, after.trimmingCharacters(in: .whitespaces), anchored: true)
    }

    private static func endsSentence(_ pass: Pass, after range: NSRange) -> Bool {
        let after = pass.following(range)
        guard let first = after.first else { return true }
        if first.isNewline { return true }
        guard first.isWhitespace, let next = after.dropFirst().first(where: { !$0.isWhitespace }) else { return after.allSatisfy(\.isWhitespace) }
        return next.isUppercase
    }

    // MARK: Expressions

    private static let space = #"[ \x{00A0}\x{202F}]"#
    private static let frenchMonthNames = "janvier|février|fevrier|mars|avril|mai|juin|juillet|août|aout|septembre|octobre|novembre|décembre|decembre"
    private static let englishMonthNames = "January|February|March|April|May|June|July|August|September|October|November|December"
    private static let numberStart = #"(?<![\p{L}\p{N}_/.:\-])"#
    private static let numberEnd = #"(?![\p{L}\p{N}_]|[/.:\-]\p{N})"#

    /// « 3 novembre », « 1er novembre 2026 ».
    static let frenchMonthDate = expression(
        "(?i)" + numberStart + "(1er|\\d{1,2})" + space + "+(" + frenchMonthNames + ")(?:" + space + "+(\\d{4}))?" + #"(?![\p{L}\p{N}_])"#
    )
    /// « du 3 au 5 novembre », « entre le 3 et le 5 novembre », « les 3 et 4 novembre », « 3-5 novembre ».
    static let frenchMonthRange = expression(
        "(?i)" + numberStart + "(1er|\\d{1,2})(" + space + "+(?:au|et|ou|à)" + space + "+(?:le" + space + "+)?|" + space + "*[-–]" + space + "*)"
            + "(\\d{1,2})" + space + "+(" + frenchMonthNames + ")(?:" + space + "+(\\d{4}))?" + #"(?![\p{L}\p{N}_])"#
    )
    /// « October 24 », « October 24th, 2026 ». Pas « May 14/15 » ni « May 4-5 » : deux jours, pas une date seule.
    static let englishMonthFirst = expression(
        #"(?<![\p{L}\p{N}_])("# + englishMonthNames + ")" + space + #"+(\d{1,2})((?:st|nd|rd|th)?)(?:,?"# + space + #"+(\d{4}))?(?![\p{L}\p{N}_]|[/.:\-–]\p{N})"#
    )
    /// « 24 October 2026 », « the 24th of October ». « the » ne fait partie de la date que devant un ordinal ou « of » :
    /// « the 31 May deadline » le garde.
    static let englishDayFirst = expression(
        numberStart + "(?:[Tt]he" + space + "+(?=" + #"\d{1,2}(?:st|nd|rd|th|"# + space + "+of" + space + "))" + #")?(\d{1,2})(?:st|nd|rd|th)?"# + space + "+(?:of" + space + "+)?(" + englishMonthNames + ")(?:,?" + space + #"+(\d{4}))?(?![\p{L}\p{N}_])"#
    )
    /// « 2026-11-03 », « 2026/11/03 ».
    static let yearFirstDate = expression(numberStart + #"(\d{4})([/.\-])(\d{1,2})\2(\d{1,2})"# + numberEnd)
    /// « 03/11/2026 », « 3.11.2026 », « 03/11/26 ».
    static let yearLastDate = expression(numberStart + #"(\d{1,2})([/.\-])(\d{1,2})\2(\d{4}|\d{2})"# + numberEnd)
    /// « le 3 du 11 », « mardi 3 du 11 ».
    private static let frenchDayOfMonth = expression(
        #"(?i)(?<![\p{L}\p{N}_])(le|du|au|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)("# + space + "+)(1er|\\d{1,2})" + space + "+du" + space
            + #"+(\d{1,2})(?![\p{L}\p{N}_]|[/.:,\-]\p{N})"#
    )
    /// « le 3/11 », « mardi 03/11 » : sans repère, « 8/10 » reste une note ou une fraction.
    private static let frenchCuedDayMonth = expression(
        #"(?i)(?<![\p{L}\p{N}_])(le|du|au|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)("# + space + #"+)(\d{1,2})/(\d{1,2})(?![\p{L}\p{N}_]|[/.:,\-]\p{N})"#
    )
    private static let englishCuedDayMonth = expression(
        #"(?i)(?<![\p{L}\p{N}_])(on|until|since|monday|tuesday|wednesday|thursday|friday|saturday|sunday)("# + space + #"+)(\d{1,2})/(\d{1,2})(?![\p{L}\p{N}_]|[/.:,\-]\p{N})"#
    )
    /// Un nombre juste après une date sans année.
    private static let trailingNumber = expression("^" + space + #"+\d"#)

    /// « 2 PM », « 2:30 p.m. », « 11am ».
    private static let meridiemTime = expression(
        #"(?<![\p{L}\p{N}_/.:,])(\d{1,2})(?::(\d{2}))?"# + space + #"?([AaPp])\.?"# + space + #"?[Mm](\.?)(?![\p{L}\p{N}_])"#
    )
    /// « 14 h 30 », « 14h30 », « 14 h », « 14 heures », « 14:30 ».
    private static let frenchClock = expression(
        #"(?<![\p{L}\p{N}_/.:,])(\d{1,2})(?:"# + space + "?((?i:heures?|h))(?:" + space + #"?(\d{2}))?|:(\d{2}))(?![\p{L}\p{N}_]|[:.,]\p{N})"#
    )
    /// « 14:30 », « 3 o'clock ».
    private static let englishClock = expression(
        #"(?<![\p{L}\p{N}_/.:,])(\d{1,2})(?::(\d{2})|"# + space + #"?o['’]clock)(?![\p{L}\p{N}_]|[:.,]\p{N})"#
    )
    private static let frenchQualifier = expression(
        "^" + space + #"+(?i:(du matin|de la matinée|de l['’]après-midi|de l['’]apres-midi|de l['’]aprèm|de l['’]aprem|du soir|de la nuit))(?![\p{L}\p{N}_-])"#
    )
    private static let englishQualifier = expression(
        "^" + space + #"+(?i:(in the morning|in the afternoon|in the evening|at night))(?![\p{L}\p{N}_])"#
    )
    /// Repères d'une heure. « jusqu'à 3 heures » peut être une durée : seul « h » ou « : » s'y lit comme une heure.
    private static let frenchCue = expression(
        #"(?i)(?:^|[^\p{L}])(?:à|vers|dès|jusqu['’]à|à partir de|il est|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|"#
            + #"demain|aujourd['’]hui|ce matin|ce soir|cet après-midi)"# + space + "+$"
    )
    private static let frenchSpelledCue = expression(#"(?i)(?:^|[^\p{L}'’])(?:à|vers|dès|à partir de|il est)"# + space + "+$")
    private static let englishCue = expression(#"(?i)(?:^|[^\p{L}])(?:at|around|by|until|till|before|after|from|between)"# + space + "+$")
    private static let numberRange = expression(#"(?<![\p{L}\p{N}_/.:,])\d{1,2}"# + space + "+(?i:à|et|ou)" + space + "+$")
    private static let dayThenTime = expression(
        #"(?i)(?:^|[^\p{L}])(?:le|du|au|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)"# + space + #"+\d{1,2}"# + space + "+(?:à|et|ou)" + space + "+$"
    )
    private static let frenchOpener = expression(#"(?i)(?:^|[^\p{L}])(?:de|du|entre)"# + space + "+$")
    private static let englishOpener = expression(#"(?i)(?:^|[^\p{L}])(?:from|between)"# + space + "+$")
    private static let frenchLink = expression(
        "^(?:" + space + "+(?i:(?:et|ou)" + space + "+(?:à|vers|dès)|à|et|ou|au|jusqu['’]à)" + space + "+|" + space + "*[-–,]" + space + "*)$"
    )
    private static let englishLink = expression(
        "^(?:" + space + "+(?i:(?:and|or)" + space + "+(?:at|around|by)|to|and|or|until|till|through)" + space + "+|" + space + "*[-–,]" + space + "*)$"
    )
    /// Ce qui suit une durée ou une distance : « à 2 h de Paris », « 1 h 30 de route », « à 2 h près », « 2 heures plus
    /// tard ». « du lundi au samedi », « du 3 au 5 » suivent une heure.
    private static let frenchDuration = expression(
        "^" + space + "+(?i:(?:(?:de|du|des)" + space + #"+|d['’])(?!lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|chaque|tous|toutes|\d)|"#
            + #"(?:près|plus tard)(?![\p{L}]))"#
    )
    private static let englishDuration = expression("^" + space + #"+(?i:of|later|long|ago)(?![\p{L}])"#)
    /// Code, adresses web et e-mails : jamais retouchés.
    private static let untouchable = expression(#"```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\n]+`|(?i:\b(?:https?://|www\.)\S+)|\S+@\S+\.\S+"#)

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // Expressions fixes écrites ici.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String, anchored: Bool = false) -> Bool {
        regex.firstMatch(in: text, options: anchored ? .anchored : [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Un passage sur le texte : chaque plage n'est retouchée qu'une fois, le code et les adresses jamais.
    private struct Pass {
        let text: String
        let source: NSString
        private var taken: [NSRange]
        private var edits: [(range: NSRange, text: String)] = []

        init(_ text: String) {
            self.text = text
            source = text as NSString
            taken = DateTimeWriter.untouchable.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        }

        var whole: NSRange { NSRange(location: 0, length: source.length) }

        func isFree(_ range: NSRange) -> Bool {
            !taken.contains { NSIntersectionRange($0, range).length > 0 }
        }

        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }

        /// Quelques caractères avant ou après une plage, pour lire ses repères.
        func preceding(_ range: NSRange, length: Int = 32) -> String {
            let start = max(0, range.location - length)
            return source.substring(with: NSRange(location: start, length: range.location - start))
        }

        func following(_ range: NSRange, length: Int = 40) -> String {
            let start = NSMaxRange(range)
            return source.substring(with: NSRange(location: start, length: min(length, source.length - start)))
        }

        /// Plage retenue ; `replacement` nil ou identique : elle reste telle quelle mais n'est plus relue.
        mutating func claim(_ range: NSRange, with replacement: String?) {
            taken.append(range)
            guard let replacement, source.substring(with: range) != replacement else { return }
            edits.append((range, replacement))
        }

        var result: String {
            let output = NSMutableString(string: text)
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                output.replaceCharacters(in: edit.range, with: edit.text)
            }
            return output as String
        }
    }
}

// MARK: - Nombres d'une date ou d'une heure

/// Nombres d'une date ou d'une heure, écrite (« 24/10/2026 », « 14h30 », « 2:30 PM », « November 3 ») ou dite
/// (« vingt-quatre octobre deux mille vingt-six », « quatorze heures trente », « two thirty in the afternoon »), pour
/// reconnaître la même date ou la même heure autrement écrite. L'après-midi et le soir sont comptés sur 24 h.
enum MomentReading {
    /// Ordinaux lus comme leur nombre : « twenty-fourth » → 24, « premier » → 1.
    private static let ordinals: [String: String] = [
        "first": "one", "second": "two", "third": "three", "fourth": "four", "fifth": "five", "sixth": "six",
        "seventh": "seven", "eighth": "eight", "ninth": "nine", "tenth": "ten", "eleventh": "eleven", "twelfth": "twelve",
        "thirteenth": "thirteen", "fourteenth": "fourteen", "fifteenth": "fifteen", "sixteenth": "sixteen",
        "seventeenth": "seventeen", "eighteenth": "eighteen", "nineteenth": "nineteen", "twentieth": "twenty",
        "thirtieth": "thirty", "premier": "un", "premiere": "une",
    ]

    /// Nombres dans l'ordre : chiffres, nombres en lettres, mois (numéro), « midi », « et demie » (30), « et quart » (15).
    static func numbers(in words: [String]) -> [Int] {
        let parts = atoms(words).map { ordinals[$0] ?? $0 }
        var values: [Int] = []
        var hourIndex: Int?
        var runStart: Int?
        var afterNumber = false
        func push(_ value: Int) {
            if !afterNumber { runStart = values.count }
            values.append(value)
            afterNumber = true
        }
        /// L'heure qui précède : celle suivie de « h » ou « heures », sinon le premier nombre d'une suite (« two thirty »).
        func meridiem(afternoon: Bool) {
            guard let target = hourIndex ?? runStart, values.indices.contains(target) else { return }
            if afternoon, values[target] < 12 { values[target] += 12 }
            if !afternoon, values[target] == 12 { values[target] = 0 }
        }
        var index = 0
        while index < parts.count {
            let atom = parts[index]
            let next = index + 1 < parts.count ? parts[index + 1] : nil
            if atom.allSatisfy({ $0.isASCII && $0.isNumber }) {
                if atom.count <= 4, let value = Int(atom) { push(value) } else { afterNumber = false }
                index += 1
                continue
            }
            if atom == "apres", next == "midi" {
                meridiem(afternoon: true)
                afterNumber = false
                index += 2
                continue
            }
            if (atom == "p" || atom == "a"), next == "m", afterNumber {
                meridiem(afternoon: atom == "p")
                afterNumber = false
                index += 2
                continue
            }
            if let month = DateTimeWriter.monthsByName[atom] {
                values.append(month)
                afterNumber = false
                index += 1
                continue
            }
            switch atom {
            case "h", "heure", "heures", "hour", "hours", "clock":
                if afterNumber { hourIndex = values.count - 1 }
                afterNumber = false
            case "pm", "am":
                if afterNumber { meridiem(afternoon: atom == "pm") }
                afterNumber = false
            case "soir", "aprem", "afternoon", "evening":
                meridiem(afternoon: true)
                afterNumber = false
            case "matin", "matinee", "morning", "nuit", "night":
                meridiem(afternoon: false)
                afterNumber = false
            case "midi", "noon", "minuit", "midnight":
                push(atom == "midi" || atom == "noon" ? 12 : 0)
                hourIndex = values.count - 1
                afterNumber = false
            case "demi", "demie", "half":
                push(30)
            case "quart", "quarter":
                push(15)
            default:
                if let (value, end) = SpokenNumbers.parse(parts, from: index), end > index {
                    push(value)
                    index = end
                    continue
                }
                afterNumber = false
            }
            index += 1
        }
        return values
    }

    /// La même date ou la même heure, autrement écrite : chaque nombre écrit vient de ce qui a été dit, et rien de ce
    /// qui a été dit n'est perdu. Une année se dit aussi en deux morceaux (« twenty twenty-six ») ou sur deux chiffres,
    /// une heure de l'après-midi aussi sur 12 h (« deux heures et demie » → « 14h30 »).
    static func sameMoment(written: [String], heard: [String]) -> Bool {
        guard written.contains(where: looksLikeMoment) else { return false }
        let shown = numbers(in: written)
        var pool = numbers(in: heard)
        guard !shown.isEmpty, !pool.isEmpty else { return false }
        func take(_ value: Int) -> Bool {
            guard let index = pool.firstIndex(of: value) else { return false }
            pool.remove(at: index)
            return true
        }
        for value in shown {
            if take(value) { continue }
            if value >= 1000, let index = pool.indices.dropLast().first(where: { (10...99).contains(pool[$0]) && pool[$0] * 100 + pool[$0 + 1] == value }) {
                pool.removeSubrange(index...(index + 1))
                continue
            }
            if value >= 1000, take(value % 100) { continue }
            if value < 100, let index = pool.firstIndex(where: { $0 >= 1000 && $0 % 100 == value }) {
                pool.remove(at: index)
                continue
            }
            if (13...23).contains(value), take(value - 12) { continue }
            return false
        }
        return pool.isEmpty
    }

    /// L'année d'une date a été dite, une fois retirés son jour et son mois de ce qui a été dit.
    static func yearWasSaid(_ year: Int, day: Int, month: Int, in said: [Int]) -> Bool {
        var pool = said
        for part in [day, month] {
            if let index = pool.firstIndex(of: part) { pool.remove(at: index) }
        }
        if pool.contains(year) { return true }
        if year >= 1000 {
            if pool.contains(year % 100) { return true }
            return zip(pool, pool.dropFirst()).contains { (10...99).contains($0) && $0 * 100 + $1 == year }
        }
        return pool.contains { $0 >= 1000 && $0 % 100 == year }
    }

    /// Un mot qui a la forme d'une date ou d'une heure : « 03/11 », « 14h30 », « h », « 2:30 », « PM », « 1er », « novembre ».
    static func looksLikeMoment(_ word: String) -> Bool {
        var core = Substring(word)
        while let first = core.first, !(first.isLetter || first.isNumber) { core.removeFirst() }
        while let last = core.last, !(last.isLetter || last.isNumber) { core.removeLast() }
        let text = String(core)
        if DateTimeWriter.monthNumber(text) != nil { return true }
        return momentShape.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static let momentShape = try! NSRegularExpression(
        pattern: #"^(?:\d{1,4}[/.\-]\d{1,2}(?:[/.\-]\d{1,4})?|\d{1,2}(?:[hH]\d{0,2}|:\d{2})|[hH]|\d{1,2}(?:er|st|nd|rd|th)|\d{1,2}(?i:[ap]\.?m\.?)|(?i:[ap]\.?m\.?))$"#
    )

    /// Suites de lettres ou de chiffres, sans casse ni accents : « 14h30 » → 14, h, 30 ; « l'après-midi » → l, apres, midi.
    private static func atoms(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words {
            var current = ""
            var digits = false
            for character in DateTimeWriter.fold(word) {
                let isDigit = character.isASCII && character.isNumber
                guard isDigit || character.isLetter else {
                    if !current.isEmpty { result.append(current) }
                    current = ""
                    continue
                }
                if !current.isEmpty, isDigit != digits {
                    result.append(current)
                    current = ""
                }
                current.append(character)
                digits = isDigit
            }
            if !current.isEmpty { result.append(current) }
        }
        return result
    }
}
