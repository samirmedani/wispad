import Foundation

/// Écriture des nombres, montants et unités (Réglages › Mise en forme). La consigne en reçoit des exemples rendus dans
/// ce format ; `NumberWriter` l'impose ensuite, sans le modèle, aux montants, pourcentages et mesures déjà en chiffres
/// et aux numéros de téléphone. Lecture tolérante champ par champ.
public struct DictationNumberFormat: Codable, Equatable, Sendable {
    /// Séparateur des milliers. `byLanguage` : espace fine en français (12 500), virgule en anglais (12,500).
    public enum Thousands: String, Codable, CaseIterable, Sendable {
        case byLanguage, space, none
    }

    public var thousands: Thousands
    /// Montants et unités avec leur symbole (« 25 € », « 5 km ») ; sinon en toutes lettres (« 25 euros »,
    /// « 5 kilomètres »). Le pourcentage garde toujours « % ».
    public var symbols: Bool
    /// Petits nombres d'une phrase courante en lettres, selon le contexte (« les deux premières barres », « trois fois ») ;
    /// mesures, données et grands nombres restent en chiffres. Faux : tout nombre qui compte s'écrit en chiffres.
    public var smallNumbersInWords: Bool

    public init(thousands: Thousands = .byLanguage, symbols: Bool = true, smallNumbersInWords: Bool = true) {
        self.thousands = thousands
        self.symbols = symbols
        self.smallNumbersInWords = smallNumbersInWords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DictationNumberFormat()
        thousands = (try? container.decodeIfPresent(Thousands.self, forKey: .thousands)) ?? defaults.thousands
        symbols = (try? container.decodeIfPresent(Bool.self, forKey: .symbols)) ?? defaults.symbols
        smallNumbersInWords = (try? container.decodeIfPresent(Bool.self, forKey: .smallNumbersInWords)) ?? defaults.smallNumbersInWords
    }

    /// Espace fine insécable : elle ne coupe jamais un nombre en fin de ligne.
    static let thinSpace = "\u{202F}"
    /// Espace insécable entre un nombre et son unité.
    static let unitSpace = "\u{00A0}"

    func thousandsSeparator(english: Bool) -> String {
        switch thousands {
        case .byLanguage: return english ? "," : Self.thinSpace
        case .space: return " "
        case .none: return ""
        }
    }

    /// Partie entière groupée par trois chiffres : « 12 500 », « 12,500 ».
    func grouped(_ digits: String, english: Bool) -> String {
        let separator = thousandsSeparator(english: english)
        guard digits.count > 3, !separator.isEmpty else { return digits }
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return groups.joined(separator: separator)
    }

    /// Exemples rendus dans ce format : un montant, un prix avec centimes, un pourcentage, une distance.
    public func samples(english: Bool) -> [String] {
        [
            NumberWriter.render(integer: "12500", fraction: nil, unit: .euro, format: self, english: english),
            NumberWriter.render(integer: "3", fraction: "5", unit: english ? .dollar : .euro, format: self, english: english),
            NumberWriter.render(integer: "15", fraction: nil, unit: .percent, format: self, english: english),
            NumberWriter.render(integer: "5", fraction: nil, unit: .kilometer, format: self, english: english),
        ]
    }

    /// Règle des nombres de la consigne : quand écrire en lettres ou en chiffres, puis le format des montants et unités.
    public func instructions(english: Bool) -> String {
        style(english: english) + "\n" + amounts(english: english)
    }

    /// Lettres ou chiffres : décidé par le contexte, comme le ferait un rédacteur, ou toujours en chiffres.
    func style(english: Bool) -> String {
        switch (english, smallNumbersInWords) {
        case (false, true):
            return """
            Nombres en lettres ou en chiffres : décide selon le contexte, comme un rédacteur soigneux. Un nombre de zéro à dix qui compte des choses dans une phrase courante s'écrit en lettres, même quand la transcription l'écrit en chiffres : « les deux premières barres », « trois fois », « il y a deux jours », « attends cinq minutes », « il faut quatre serveurs ». En chiffres : au-delà de dix (« 12 serveurs ») ; les mesures, montants et données techniques, même petits (« 5 secondes de latence », « 60 images par seconde », « 2 Go », « 3 € ») ; les décimales, dates, heures, scores, versions, numéros et références ; et des nombres comparés dans la même phrase s'écrivent pareil (« entre 8 et 12 personnes »). Deux petits nombres qui se suivent donnent une approximation : garde-les tous les deux. « Un » et « une » articles et les expressions figées (« un ou deux », « à deux ») restent en lettres. Exemples fictifs de transcription : « les 2 dernières lignes » → « les deux dernières lignes » ; « on l'a testé 3 fois » → « on l'a testé trois fois » ; « elle a 2 enfants » → « elle a deux enfants » ; « il me faut 2 3 jours » → « il me faut deux, trois jours ». Mais « 5 secondes de latence », « 16 Go » et « 12 serveurs » restent en chiffres.
            """
        case (false, false):
            return """
            Nombres : tout nombre qui compte, mesure, date ou chiffre vraiment quelque chose s'écrit en chiffres : 4 modèles, 5 ou 10 secondes, 20 boîtes, 2 heures de route, 3 fois, 64 Go. Seuls « un » et « une » articles et les expressions figées (« un ou deux », « à deux ») restent en lettres.
            """
        case (true, true):
            return """
            Numbers in words or digits: decide from the context, like a careful editor. A number from zero to nine that counts things in an everyday sentence is spelled out, even when the transcription writes it as digits: "the first two bars", "three times", "two days ago", "wait five minutes", "we need four servers". Use digits above nine ("12 servers"); for measurements, amounts and technical data, even small ones ("5 seconds of latency", "60 frames per second", "2 GB", "$3"); for decimals, dates, times, scores, versions, numbers and references; and numbers compared in the same sentence are written the same way ("between 8 and 12 people"). Two small numbers in a row are an estimate: keep both. Keep "one" as a word when it is a pronoun ("this one", "no one") and in fixed expressions ("one or two"). Fictional transcription examples: "the last 2 lines" → "the last two lines"; "we tested it 3 times" → "we tested it three times"; "she has 2 kids" → "she has two kids"; "it takes 2 3 days" → "it takes two or three days". But "5 seconds of latency", "16 GB" and "12 servers" stay in digits.
            """
        case (true, false):
            return """
            Numbers: write numbers that really count, measure or date something as digits: 4 models, 5 or 10 seconds, 20 boxes, 2 hours of driving, 3 times, 64 GB. Keep "one" as a word when it is a pronoun ("this one", "no one") and in fixed expressions ("one or two").
            """
        }
    }

    private func amounts(english: Bool) -> String {
        func amount(_ integer: String, _ fraction: String? = nil, _ unit: MeasureUnit) -> String {
            NumberWriter.render(integer: integer, fraction: fraction, unit: unit, format: self, english: english)
        }
        let people = grouped("12500", english: english)
        if english {
            return """
            Amounts and units: digits, written this way. Fictional examples: "twenty-five dollars" → "\(amount("25", nil, .dollar))"; "three euros fifty" → "\(amount("3", "50", .euro))"; "fifteen percent" → "\(amount("15", nil, .percent))"; "five kilometers" → "\(amount("5", nil, .kilometer))"; "twelve thousand five hundred people" → "\(people) people"; "two million" → "2 million". E-mail addresses and URLs are one lowercase block: "john dot smith at gmail dot com" → "john.smith@gmail.com". Phone numbers keep exactly the digits spoken. Never group the digits of a year, a zip code, a hardware reference or a version number. A duration keeps its unit in words.
            """
        }
        // « Et demi » reste en lettres ; le nombre devant suit la règle choisie.
        let halves = smallNumbersInWords
            ? "« deux mois et 1/2 » → « deux mois et demi », « une heure et 1/2 » → « une heure et demie »"
            : "« deux mois et demi » → « 2 mois et demi », « une heure et demie » → « 1 heure et demie »"
        return """
        Montants et unités : en chiffres, écrits ainsi. Exemples fictifs : « vingt-cinq euros » → « \(amount("25", nil, .euro)) » ; « trois euros cinquante » → « \(amount("3", "50", .euro)) » ; « quinze pour cent » → « \(amount("15", nil, .percent)) » ; « cinq kilomètres » → « \(amount("5", nil, .kilometer)) » ; « douze mille cinq cents habitants » → « \(people) habitants » ; « deux millions » → « 2 millions », « un milliard et demi » → « 1,5 milliard ». Après un autre mot, « et demi » reste en lettres, jamais « 1/2 » : \(halves). La virgule sépare les décimales : « deux virgule cinq » → « 2,5 ». Un numéro de téléphone s'écrit par paires : « zéro six douze trente-quatre cinquante-six soixante-dix-huit » → « 06 12 34 56 78 » ; « plus trente-trois six douze trente-quatre cinquante-six soixante-dix-huit » → « +33 6 12 34 56 78 ». Une adresse e-mail ou une URL s'écrit d'un seul bloc, en minuscules : « jean point dupont arobase gmail point com » → « jean.dupont@gmail.com ». Ne regroupe jamais les chiffres d'une année, d'un code postal, d'une référence de matériel ou d'un numéro de version. Une durée garde son unité en toutes lettres.
        """
    }
}

/// Unités reconnues après un nombre. Les unités de temps n'y sont pas : une durée reste en lettres.
public enum MeasureUnit: CaseIterable, Sendable {
    case euro, dollar, pound, percent
    case kilometerPerHour, kilometer, meter, centimeter, millimeter, squareMeter, cubicMeter
    case kilogram, gram, milligram, liter, milliliter, centiliter, celsius
    case gigaoctet, megaoctet, teraoctet, gigabyte, megabyte, terabyte, gigahertz, megahertz, kilowattHour, kilowatt

    var symbol: String {
        switch self {
        case .euro: return "€"
        case .dollar: return "$"
        case .pound: return "£"
        case .percent: return "%"
        case .kilometerPerHour: return "km/h"
        case .kilometer: return "km"
        case .meter: return "m"
        case .centimeter: return "cm"
        case .millimeter: return "mm"
        case .squareMeter: return "m²"
        case .cubicMeter: return "m³"
        case .kilogram: return "kg"
        case .gram: return "g"
        case .milligram: return "mg"
        case .liter: return "L"
        case .milliliter: return "mL"
        case .centiliter: return "cL"
        case .celsius: return "°C"
        case .gigaoctet: return "Go"
        case .megaoctet: return "Mo"
        case .teraoctet: return "To"
        case .gigabyte: return "GB"
        case .megabyte: return "MB"
        case .terabyte: return "TB"
        case .gigahertz: return "GHz"
        case .megahertz: return "MHz"
        case .kilowattHour: return "kWh"
        case .kilowatt: return "kW"
        }
    }

    /// Mots dits ou écrits (minuscules, sans accents) qui désignent l'unité juste après un nombre. Les formes orales
    /// (« 16 gigas ») restent telles que dites : seule leur forme écrite complète prend le symbole.
    var spokenForms: [String] {
        switch self {
        case .euro: return ["euros", "euro"]
        case .dollar: return ["dollars", "dollar"]
        case .pound: return ["livres sterling", "livre sterling"]
        case .percent: return ["pour cent", "pourcents", "pourcent", "percent", "per cent"]
        case .kilometerPerHour: return ["kilometres par heure", "kilometres heure", "kilometres-heure", "kilometers per hour", "kilometres per hour",
                                        "kilometre par heure", "kilometre heure", "kilometre-heure", "kilometer per hour", "kilometre per hour"]
        case .kilometer: return ["kilometres", "kilometre", "kilometers", "kilometer"]
        case .meter: return ["metres", "metre", "meters", "meter"]
        case .centimeter: return ["centimetres", "centimetre", "centimeters", "centimeter"]
        case .millimeter: return ["millimetres", "millimetre", "millimeters", "millimeter"]
        case .squareMeter: return ["metres carres", "metre carre", "square meters", "square meter", "square metres"]
        case .cubicMeter: return ["metres cubes", "metre cube", "cubic meters", "cubic meter", "cubic metres"]
        case .kilogram: return ["kilogrammes", "kilogramme", "kilograms", "kilogram"]
        case .gram: return ["grammes", "gramme", "grams", "gram"]
        case .milligram: return ["milligrammes", "milligramme", "milligrams", "milligram"]
        case .liter: return ["litres", "litre", "liters", "liter"]
        case .milliliter: return ["millilitres", "millilitre", "milliliters", "milliliter"]
        case .centiliter: return ["centilitres", "centilitre", "centiliters", "centiliter"]
        case .celsius: return ["degres celsius", "degre celsius", "degrees celsius", "degree celsius"]
        case .gigaoctet: return ["gigaoctets", "gigaoctet"]
        case .megaoctet: return ["megaoctets", "megaoctet"]
        case .teraoctet: return ["teraoctets", "teraoctet"]
        case .gigabyte: return ["gigabytes", "gigabyte"]
        case .megabyte: return ["megabytes", "megabyte"]
        case .terabyte: return ["terabytes", "terabyte"]
        case .gigahertz: return ["gigahertz"]
        case .megahertz: return ["megahertz"]
        case .kilowattHour: return ["kilowattheures", "kilowattheure", "kilowatts-heure", "kilowatt-heure", "kilowatt-hours", "kilowatt-hour",
                                    "kilowatt hours", "kilowatt hour"]
        case .kilowatt: return ["kilowatts", "kilowatt"]
        }
    }

    /// Symboles écrits reconnus, à la casse près pour ceux qui ont un sens courant en minuscules (« go »).
    var writtenSymbols: [String] {
        switch self {
        case .euro: return ["€"]
        case .dollar: return ["$"]
        case .pound: return ["£"]
        case .percent: return ["%"]
        case .kilometerPerHour: return ["km/h", "Km/h", "KM/H"]
        case .kilometer: return ["km", "Km", "KM"]
        case .meter: return ["m"]
        case .centimeter: return ["cm"]
        case .millimeter: return ["mm"]
        case .squareMeter: return ["m²", "m2"]
        case .cubicMeter: return ["m³", "m3"]
        case .kilogram: return ["kg", "Kg", "KG"]
        case .gram: return ["g"]
        case .milligram: return ["mg"]
        case .liter: return ["L", "l"]
        case .milliliter: return ["mL", "ml"]
        case .centiliter: return ["cL", "cl"]
        case .celsius: return ["°C", "° C"]
        case .gigaoctet: return ["Go"]
        case .megaoctet: return ["Mo"]
        case .teraoctet: return ["To"]
        case .gigabyte: return ["GB", "Gb"]
        case .megabyte: return ["MB"]
        case .terabyte: return ["TB"]
        case .gigahertz: return ["GHz", "Ghz", "ghz", "GHZ"]
        case .megahertz: return ["MHz", "Mhz", "mhz", "MHZ"]
        case .kilowattHour: return ["kWh", "KWh", "kwh"]
        case .kilowatt: return ["kW", "KW", "kw"]
        }
    }

    /// Mots écrits quand les symboles sont coupés : singulier, pluriel.
    func words(english: Bool) -> (singular: String, plural: String)? {
        switch self {
        case .euro: return ("euro", "euros")
        case .dollar: return ("dollar", "dollars")
        case .pound: return english ? ("pound", "pounds") : ("livre sterling", "livres sterling")
        case .percent: return nil
        case .kilometerPerHour: return english ? ("kilometer per hour", "kilometers per hour") : ("kilomètre par heure", "kilomètres par heure")
        case .kilometer: return english ? ("kilometer", "kilometers") : ("kilomètre", "kilomètres")
        case .meter: return english ? ("meter", "meters") : ("mètre", "mètres")
        case .centimeter: return english ? ("centimeter", "centimeters") : ("centimètre", "centimètres")
        case .millimeter: return english ? ("millimeter", "millimeters") : ("millimètre", "millimètres")
        case .squareMeter: return english ? ("square meter", "square meters") : ("mètre carré", "mètres carrés")
        case .cubicMeter: return english ? ("cubic meter", "cubic meters") : ("mètre cube", "mètres cubes")
        case .kilogram: return english ? ("kilogram", "kilograms") : ("kilogramme", "kilogrammes")
        case .gram: return english ? ("gram", "grams") : ("gramme", "grammes")
        case .milligram: return english ? ("milligram", "milligrams") : ("milligramme", "milligrammes")
        case .liter: return english ? ("liter", "liters") : ("litre", "litres")
        case .milliliter: return english ? ("milliliter", "milliliters") : ("millilitre", "millilitres")
        case .centiliter: return english ? ("centiliter", "centiliters") : ("centilitre", "centilitres")
        case .celsius: return english ? ("degree Celsius", "degrees Celsius") : ("degré Celsius", "degrés Celsius")
        case .gigaoctet: return ("gigaoctet", "gigaoctets")
        case .megaoctet: return ("mégaoctet", "mégaoctets")
        case .teraoctet: return ("téraoctet", "téraoctets")
        case .gigabyte: return ("gigabyte", "gigabytes")
        case .megabyte: return ("megabyte", "megabytes")
        case .terabyte: return ("terabyte", "terabytes")
        case .gigahertz: return ("gigahertz", "gigahertz")
        case .megahertz: return ("megahertz", "megahertz")
        case .kilowattHour: return english ? ("kilowatt-hour", "kilowatt-hours") : ("kilowattheure", "kilowattheures")
        case .kilowatt: return ("kilowatt", "kilowatts")
        }
    }

    var isCurrency: Bool { self == .euro || self == .dollar || self == .pound }

    /// Une fiche technique écrit « 6000 MHz », « 1024 Go » : ces unités ne regroupent pas les milliers.
    var groupsThousands: Bool {
        switch self {
        case .gigaoctet, .megaoctet, .teraoctet, .gigabyte, .megabyte, .terabyte, .gigahertz, .megahertz: return false
        default: return true
        }
    }

    /// Symbole d'une seule lettre : le récrire en lettres pourrait changer le sens (« 5 m » = 5 millions ?).
    var hasAmbiguousSymbol: Bool { symbol.count == 1 && !isCurrency && self != .percent }
}

/// Montants, pourcentages, mesures et numéros de téléphone déjà en chiffres, récrits dans le format choisi.
/// Ne touche qu'à un nombre directement suivi (ou précédé, pour une devise) d'une unité reconnue, et aux numéros de
/// téléphone français : années, codes, références et versions restent tels quels.
public enum NumberWriter {
    public static func apply(_ text: String, format: DictationNumberFormat, english: Bool) -> String {
        let phones = formatPhones(english ? text : spokenHalves(text))
        let prefixed = rewritePrefixedCurrencies(phones, format: format, english: english)
        return rewriteMeasures(prefixed, format: format, english: english)
    }

    // MARK: Rendu

    static func render(integer: String, fraction: String?, unit: MeasureUnit, format: DictationNumberFormat, english: Bool) -> String {
        var fraction = fraction
        // Un prix a ses centimes sur deux chiffres : « 3,5 € » → « 3,50 € ».
        if unit.isCurrency, let digits = fraction, digits.count == 1 { fraction = digits + "0" }
        let whole = unit.groupsThousands ? format.grouped(integer, english: english) : integer
        let number = fraction.map { whole + (english ? "." : ",") + $0 } ?? whole
        if !format.symbols || unit.symbol.isEmpty, let words = unit.words(english: english) {
            let value = Double(integer + "." + (fraction ?? "0")) ?? 0
            let plural = english ? value != 1 : value >= 2
            return number + " " + (plural ? words.plural : words.singular)
        }
        if english {
            if unit.isCurrency { return unit.symbol + number }
            if unit == .percent { return number + unit.symbol }
        }
        return number + DictationNumberFormat.unitSpace + unit.symbol
    }

    // MARK: Mesures et montants après le nombre

    private static let spaces = "[ \\u00A0\\u202F]"

    /// Nombre entier, groupé ou non, avec ses décimales. Jamais la fin d'un nombre plus long ni d'une référence, ni un
    /// montant déjà précédé de sa devise (« $5m » : cinq millions de dollars, pas des mètres).
    private static func numberPattern(english: Bool) -> String {
        let grouped = english ? "\\d{1,3}(?:[ \\u00A0\\u202F,]\\d{3})+" : "\\d{1,3}(?:[ \\u00A0\\u202F]\\d{3})+"
        return "(?<![\\p{L}\\d.,/€$£])(?<!\\d[ \\u00A0\\u202F])(" + grouped + "|\\d+)(?:([.,])(\\d+))?"
    }

    /// Mots d'unité sans casse (« Celsius », « Euros ») ; symboles à la casse près (« Go » oui, « go » non).
    private static func unitAlternation() -> (pattern: String, lookup: [String: MeasureUnit]) {
        var lookup: [String: MeasureUnit] = [:]
        var forms: [(text: String, spoken: Bool)] = []
        for unit in MeasureUnit.allCases {
            for form in unit.spokenForms where lookup[form] == nil {
                lookup[form] = unit
                forms.append((form, true))
            }
            for symbol in unit.writtenSymbols where lookup[symbol] == nil {
                lookup[symbol] = unit
                forms.append((symbol, false))
            }
        }
        // Le plus long d'abord : « km/h » avant « km », « mètres carrés » avant « mètres ».
        forms.sort { $0.text.count > $1.text.count }
        let pattern = forms.map { form -> String in
            let escaped = NSRegularExpression.escapedPattern(for: form.text).replacingOccurrences(of: " ", with: spaces)
            return form.spoken ? "(?i:" + escaped + ")" : escaped
        }.joined(separator: "|")
        return (pattern, lookup)
    }

    private static let units = unitAlternation()

    private static func measureRegex(english: Bool) -> NSRegularExpression {
        try! NSRegularExpression(pattern: numberPattern(english: english) + spaces + "?(" + units.pattern + ")(?![\\p{L}\\p{N}²³'’])")
    }

    private static let frenchMeasure = measureRegex(english: false)
    private static let englishMeasure = measureRegex(english: true)

    private static func rewriteMeasures(_ text: String, format: DictationNumberFormat, english: Bool) -> String {
        let folded = text.folding(options: [.diacriticInsensitive], locale: nil)
        // Les accents retirés gardent la même longueur en UTF-16 pour le français : sinon on renonce.
        guard (folded as NSString).length == (text as NSString).length else { return text }
        let regex = english ? englishMeasure : frenchMeasure
        let output = NSMutableString(string: text)
        let source = folded as NSString
        for match in regex.matches(in: folded, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let parts = number(match, in: source, english: english),
                  let unitRange = Range(match.range(at: 4), in: folded) else { continue }
            let key = String(folded[unitRange]).replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
            guard let unit = units.lookup[key] ?? units.lookup[key.lowercased()] else { continue }
            // Symboles coupés : une lettre seule (« 5 m ») n'est pas récrite en lettres, son sens n'est pas sûr.
            let typedSymbol = unit.writtenSymbols.contains(key)
            if !format.symbols, typedSymbol, unit.hasAmbiguousSymbol { continue }
            let rendered = render(integer: parts.integer, fraction: parts.fraction, unit: unit, format: format, english: english)
            output.replaceCharacters(in: match.range, with: rendered)
        }
        return output as String
    }

    private static func number(_ match: NSTextCheckingResult, in source: NSString, english: Bool) -> (integer: String, fraction: String?)? {
        let whole = source.substring(with: match.range(at: 1))
        var integer = whole.filter(\.isNumber)
        var fraction: String?
        if match.range(at: 2).location != NSNotFound {
            let separator = source.substring(with: match.range(at: 2))
            let digits = source.substring(with: match.range(at: 3))
            // « 12.500 € » en français : milliers à l'allemande, pas des décimales.
            if !english, separator == ".", digits.count == 3, whole.count <= 3 {
                integer += digits
            } else if english, separator == "," {
                return nil
            } else {
                fraction = digits
            }
        }
        guard !integer.isEmpty else { return nil }
        return (integer, fraction)
    }

    // MARK: Devise devant le nombre (« €25 », « $3.50 »)

    /// Un symbole qui suit déjà un montant (« payé 20 € 3 fois ») n'est pas celui du nombre suivant.
    private static let prefixedCurrency = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\d])(?<!\\d[ \\u00A0\\u202F])([€$£])" + "[ \\u00A0\\u202F]?" + "(\\d{1,3}(?:[ \\u00A0\\u202F,]\\d{3})+|\\d+)(?:([.,])(\\d{1,2}))?(?![\\d\\p{L}])"
    )

    private static func rewritePrefixedCurrencies(_ text: String, format: DictationNumberFormat, english: Bool) -> String {
        let source = text as NSString
        let output = NSMutableString(string: text)
        for match in prefixedCurrency.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let symbol = source.substring(with: match.range(at: 1))
            guard let unit = MeasureUnit.allCases.first(where: { $0.isCurrency && $0.symbol == symbol }) else { continue }
            let integer = source.substring(with: match.range(at: 2)).filter(\.isNumber)
            let fraction = match.range(at: 4).location == NSNotFound ? nil : source.substring(with: match.range(at: 4))
            output.replaceCharacters(in: match.range, with: render(integer: integer, fraction: fraction, unit: unit, format: format, english: english))
        }
        return output as String
    }

    // MARK: « Et demi » en lettres

    /// « 2 mois et 1/2 » (transcription vocale) → « 2 mois et demi » ; « 1 heure et 1/2 » → « 1 heure et demie ».
    /// Seulement après un nombre et un nom : « 1/2 litre » ou un score restent tels quels.
    private static let half = try! NSRegularExpression(
        pattern: "(\\d+(?:,\\d+)?[ \\u00A0\\u202F]+)([\\p{L}][\\p{L}’'\\-]*)([ \\u00A0\\u202F]+et[ \\u00A0\\u202F]+)(?:1/2|½)(?![\\d/\\p{L}])"
    )

    /// Noms féminins courants après lesquels on écrit « et demie ». Les autres prennent « et demi ».
    private static let feminineNouns: Set<String> = [
        "heure", "minute", "seconde", "semaine", "annee", "journee", "soiree", "matinee", "nuit", "livre", "tasse",
        "cuillere", "cuilleree", "bouteille", "part", "page", "fois", "tranche", "boite", "pinte", "douzaine",
        "centaine", "dizaine", "saison", "etape", "seance", "portion", "mesure", "dose", "pizza", "baguette",
    ]

    static func spokenHalves(_ text: String) -> String {
        let source = text as NSString
        let output = NSMutableString(string: text)
        for match in half.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let noun = source.substring(with: match.range(at: 2))
            var key = noun.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            if key.hasSuffix("s"), key != "fois" { key.removeLast() }
            let word = feminineNouns.contains(key) ? "demie" : "demi"
            output.replaceCharacters(in: match.range, with: source.substring(with: match.range(at: 1)) + noun
                                     + source.substring(with: match.range(at: 3)) + word)
        }
        return output as String
    }

    // MARK: Téléphones français

    private static let phoneSeparator = "[ .\\-\\u00A0\\u202F]?"
    private static let nationalPhone = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\d+@/:.\\-_])0[1-9](?:" + phoneSeparator + "\\d){8}(?!" + phoneSeparator + "\\d)(?![\\p{L}@/_])"
    )
    private static let internationalPhone = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\d@/:._])\\+33" + phoneSeparator + "(?:\\(0\\)" + phoneSeparator + ")?[1-9](?:" + phoneSeparator + "\\d){8}(?!" + phoneSeparator + "\\d)(?![\\p{L}@/_])"
    )

    /// « 0612345678 », « 06.12.34.56.78 » → « 06 12 34 56 78 » ; « +33612345678 » → « +33 6 12 34 56 78 ».
    static func formatPhones(_ text: String) -> String {
        var result = text
        for (regex, international) in [(internationalPhone, true), (nationalPhone, false)] {
            let source = result as NSString
            let output = NSMutableString(string: result)
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)).reversed() {
                var digits = source.substring(with: match.range).filter(\.isNumber)
                if international {
                    digits.removeFirst(2)
                    if digits.count == 10, digits.first == "0" { digits.removeFirst() }
                    guard digits.count == 9 else { continue }
                    let pairs = stride(from: 1, to: 9, by: 2).map { offset -> String in
                        let start = digits.index(digits.startIndex, offsetBy: offset)
                        return String(digits[start..<digits.index(start, offsetBy: 2)])
                    }
                    output.replaceCharacters(in: match.range, with: "+33 " + String(digits.first!) + " " + pairs.joined(separator: " "))
                } else {
                    guard digits.count == 10 else { continue }
                    let pairs = stride(from: 0, to: 10, by: 2).map { offset -> String in
                        let start = digits.index(digits.startIndex, offsetBy: offset)
                        return String(digits[start..<digits.index(start, offsetBy: 2)])
                    }
                    output.replaceCharacters(in: match.range, with: pairs.joined(separator: " "))
                }
            }
            result = output as String
        }
        return result
    }
}
