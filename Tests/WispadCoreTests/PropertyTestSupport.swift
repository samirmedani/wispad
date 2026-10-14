import Foundation
import Testing

/// Générateur pseudo-aléatoire à graine fixe (SplitMix64). Les tests de propriétés tirent toujours les mêmes cas, d'une
/// machine ou d'une version de Swift à l'autre : rien ne passe par l'aléatoire de la bibliothèque standard, dont
/// l'algorithme peut changer.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    /// Vrai `percent` fois sur cent.
    mutating func chance(_ percent: Int) -> Bool {
        int(0...99) < percent
    }

    mutating func pick<Element>(_ items: [Element]) -> Element {
        items[int(0...(items.count - 1))]
    }

    /// Nombre réel dans l'intervalle.
    mutating func double(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}

/// Vérifie une propriété sur des cas tirés d'une graine fixe. `property` rend nil si elle tient, sinon la
/// description du contre-exemple : seul le premier est signalé, avec son numéro de tirage, pour rester lisible.
/// Par défaut, un quart des `count` tirages (25 au moins) : tous les tests tournent ensemble, et une machine de CI à
/// trois cœurs saturée retardait les tests qui mesurent un délai réel (micro ouvert en moins d'une seconde). Les
/// `count` tirages avec `WISPAD_PROPERTY_RUNS=full`. La graine fixe garde toujours les mêmes premiers tirages.
func forAll<Case>(
    _ count: Int,
    seed: UInt64,
    _ generate: (inout SeededGenerator) -> Case,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ property: (Case) -> String?
) {
    var generator = SeededGenerator(seed: seed)
    let runs = ProcessInfo.processInfo.environment["WISPAD_PROPERTY_RUNS"] == "full" ? count : max(min(count, 25), count / 4)
    for index in 0..<runs {
        let input = generate(&generator)
        if let failure = property(input) {
            Issue.record("Tirage \(index) (graine \(seed)) : \(failure)", sourceLocation: sourceLocation)
            return
        }
    }
}

/// Textes de dictée tirés au hasard. Une phrase mêle des mots ordinaires et des fragments bien formés (montant, mesure,
/// téléphone, date, heure, code, adresse), toujours séparés par au moins un mot : deux fragments collés (« £$8 »,
/// « May July 1 ») ne sont pas une dictée plausible et ne disent rien du comportement attendu.
enum SampleText {
    /// Mots sans chiffre, ni nom de mois (seuls les fragments de date en portent), ni « heure » qui ferait d'une
    /// distance une vitesse (« 5 km heure »).
    static let frenchWords = [
        "le", "la", "les", "un", "une", "de", "du", "des", "et", "ou", "à", "au", "pour", "avec", "chez", "sur",
        "dans", "rendez-vous", "réunion", "train", "loyer", "café", "prix", "appelle", "envoie", "demain", "lundi",
        "mardi", "matin", "soir", "minutes", "route", "Paris", "Marie", "il", "elle", "est", "c'est", "j'ai", "on",
        "se", "voit", "fait", "coûte", "dure", "semaine", "année", "vers", "dès", "jusqu'à", "entre", "l'après-midi",
        "ça", "y", "a", "pas", "ne", "plus", "tard", "près", "école", "Été", "Œuvre", "garçon",
    ]
    static let englishWords = [
        "the", "a", "at", "on", "in", "to", "and", "or", "from", "until", "by", "around", "meeting", "train", "rent",
        "coffee", "price", "call", "send", "tomorrow", "Monday", "morning", "evening", "afternoon", "night",
        "minutes", "of", "later", "ago", "is", "it", "we", "leave", "costs", "between", "people", "came",
    ]
    static let punctuation = [",", ".", " :", " ;", " !", " ?", "…"]
    static let units = [
        "€", "$", "£", "%", "euros", "euro", "dollars", "pour cent", "percent", "km", "Km", "kilomètres", "kilometers",
        "km/h", "kilomètres par heure", "kilomètre par heure", "kilometers per hour", "m", "mètres", "m2", "m²", "m3",
        "mètres carrés", "cm", "mm", "kg", "g", "grammes", "mg", "L", "l", "litres", "mL", "cl", "°C", "° C",
        "degrés Celsius", "Go", "Mo", "To", "GB", "MB", "TB", "GHz", "MHz", "kWh", "kW", "kilowatt-hours",
        "kilowattheures", "gigas", "gigaoctets", "EUROS", "Pour Cent", "min", "ms",
    ]
    static let frenchMonths = [
        "janvier", "février", "fevrier", "mars", "avril", "mai", "juin", "juillet", "août", "aout", "septembre",
        "octobre", "novembre", "décembre", "decembre", "Novembre",
    ]
    static let englishMonths = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
        "November", "December",
    ]

    static func digits(_ g: inout SeededGenerator, count: Int) -> String {
        String((0..<count).map { _ in Character(String(g.int(0...9))) })
    }

    static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }

    /// Nombre seul : entier, groupé (« 12 500 », « 12,500 »), décimal, très long, ou commençant par zéro.
    static func number(_ g: inout SeededGenerator) -> String {
        switch g.int(0...7) {
        case 0: return String(g.int(0...9))
        case 1: return String(g.int(10...999))
        case 2: return String(g.int(1000...99_999))
        case 3: return String(g.int(1...999)) + g.pick([" ", "\u{202F}", "\u{00A0}", ",", "."]) + digits(&g, count: 3)
        case 4: return String(g.int(0...999)) + g.pick([",", "."]) + digits(&g, count: g.int(1...3))
        case 5: return digits(&g, count: g.int(12...25))
        case 6: return String(g.int(1...9)) + g.pick([" 000 000", "000000", ",000,000", " 500 000"])
        default: return String(g.int(1...31))
        }
    }

    /// Montant, pourcentage ou mesure, l'unité collée, après une espace ou devant (devise).
    static func amount(_ g: inout SeededGenerator) -> String {
        if g.chance(25) { return g.pick(["€", "$", "£"]) + g.pick(["", " "]) + number(&g) }
        return number(&g) + g.pick([" ", "\u{00A0}", ""]) + g.pick(units)
    }

    /// Téléphone français, bien formé ou d'une longueur qui n'en fait pas un.
    static func phone(_ g: inout SeededGenerator) -> String {
        let separator = g.pick(["", " ", ".", "-", "\u{00A0}"])
        let pairs = (0..<4).map { _ in digits(&g, count: 2) }.joined(separator: separator)
        switch g.int(0...2) {
        case 0: return "0" + String(g.int(1...9)) + separator + pairs
        case 1: return "+33" + g.pick(["", " "]) + g.pick(["", "(0)", "(0) "]) + String(g.int(1...9)) + separator + pairs
        default: return "0" + digits(&g, count: g.pick([7, 8, 10, 11]))
        }
    }

    /// Date sous toutes ses formes, valide ou non : chiffres, mois en lettres, plages, repères (« le », « on »).
    static func date(_ g: inout SeededGenerator, english: Bool) -> String {
        let day = g.int(0...33), month = g.int(0...13)
        let year = g.pick([String(g.int(1990...2035)), twoDigits(g.int(0...99)), String(g.int(1000...2999))])
        let separator = g.pick(["/", ".", "-"])
        let d = g.chance(50) ? String(day) : twoDigits(day)
        let m = g.chance(50) ? String(month) : twoDigits(month)
        switch g.int(0...7) {
        case 0: return d + separator + m + separator + year
        case 1: return year + separator + m + separator + d
        case 2: return (english ? g.pick(["on ", "until ", "Monday "]) : g.pick(["le ", "du ", "au ", "mardi "])) + d + "/" + m
        case 3 where !english:
            return (day == 1 && g.chance(50) ? "1er" : d) + " " + g.pick(frenchMonths) + (g.chance(50) ? " " + year : "")
        case 3:
            return g.pick(englishMonths) + " " + d + g.pick(["", "st", "nd", "rd", "th"]) + (g.chance(50) ? g.pick([", ", " "]) + year : "")
        case 4 where !english:
            return "du " + d + g.pick([" au ", " et ", "-", " – "]) + String(g.int(0...33)) + " " + g.pick(frenchMonths)
        case 4:
            return g.pick(["the ", ""]) + d + g.pick(["", "st", "th"]) + g.pick([" of ", " "]) + g.pick(englishMonths)
                + (g.chance(30) ? " " + year : "")
        case 5: return english ? "on " + d + "/" + m : g.pick(["le ", "mardi "]) + d + " du " + m
        case 6: return d + "/" + m
        default: return year
        }
    }

    /// Heure ou durée, avec ou sans repère, parfois reliée à une seconde heure (« de 14 h à 16 h »).
    static func time(_ g: inout SeededGenerator, english: Bool, linked: Bool = true) -> String {
        let hour = g.int(0...26), minute = g.int(0...62)
        let cue = english
            ? g.pick(["at ", "around ", "by ", "until ", "from ", "between ", ""])
            : g.pick(["à ", "vers ", "dès ", "jusqu'à ", "à partir de ", "il est ", "demain ", "lundi ", "de ", "entre ", ""])
        let core: String
        switch g.int(0...8) {
        case 0: core = "\(hour)h\(twoDigits(minute))"
        case 1: core = "\(hour) h \(twoDigits(minute))"
        case 2: core = "\(hour) h"
        case 3: core = "\(hour) heures"
        case 4: core = "\(hour):\(twoDigits(minute))"
        case 5: core = "\(hour % 13)" + g.pick([" ", ""]) + g.pick(["AM", "PM", "am", "pm", "a.m.", "p.m."])
        case 6: core = "\(hour % 13):\(twoDigits(minute))" + g.pick([" ", ""]) + g.pick(["AM", "PM", "p.m."])
        case 7: core = "\(hour)" + g.pick([" o'clock", " o’clock"])
        default:
            core = "\(hour) h" + g.pick([" du matin", " de l'après-midi", " du soir", " de la nuit", " de route", " plus tard", " près"])
        }
        let link = english ? [" to ", " and ", "-", ", "] : [" à ", " et ", "-", ", "]
        let tail = linked && g.chance(25) ? g.pick(link) + time(&g, english: english, linked: false) : ""
        return cue + core + tail
    }

    /// Code, adresse web ou e-mail : jamais retouchés.
    static func untouchable(_ g: inout SeededGenerator) -> String {
        switch g.int(0...3) {
        case 0: return "`" + g.pick(["let x = 3", "2026-11-03", "14h30", "25 €", "06 12 34 56 78"]) + "`"
        case 1: return "https://exemple.fr/" + g.pick(["2026-11-03", "prix/25-euros", "a?b=14h30"])
        case 2: return g.pick(["jean.dupont", "a.b", "x"]) + "@" + g.pick(["exemple.fr", "mail.com"])
        default: return "```\n" + g.pick(["let date = \"03/11/2026\"", "price = 25 €"]) + "\n```"
        }
    }

    static func fragment(_ g: inout SeededGenerator, english: Bool) -> String {
        switch g.int(0...6) {
        case 0, 1: return amount(&g)
        case 2: return phone(&g)
        case 3: return date(&g, english: english)
        case 4: return time(&g, english: english)
        case 5: return untouchable(&g)
        default: return g.pick(["2 mois et 1/2", "1 heure et ½", "3 semaines et 1/2", "3/4", "8/10", "v1.2.3", "1.12.20", "16:9"])
        }
    }

    /// Phrase plausible : mots et fragments, jamais deux fragments de suite.
    static func sentence(_ g: inout SeededGenerator, english: Bool, words: ClosedRange<Int> = 1...10) -> String {
        var parts: [String] = []
        var afterFragment = true
        for _ in 0..<g.int(words) {
            if !afterFragment, g.chance(45) {
                parts.append(fragment(&g, english: english))
                afterFragment = true
            } else {
                parts.append(g.pick(english ? englishWords : frenchWords) + (g.chance(15) ? g.pick(punctuation) : ""))
                afterFragment = false
            }
        }
        return parts.joined(separator: " ")
    }

    /// Texte sans aucun chiffre : mots, mois, unités, ponctuation, emoji, lettres accentuées.
    static func digitless(_ g: inout SeededGenerator) -> String {
        let pool = frenchWords + englishWords + frenchMonths + englishMonths + units.filter { !$0.contains(where: \.isNumber) }
            + ["h", "heures", "PM", "a.m.", "o'clock", "premier", "et demi", "½", "🙂", "👍🏽", "🇫🇷", "ß", "Ω", "中文", "€€"]
        var text = ""
        for index in 0..<g.int(0...20) {
            if index > 0 { text += g.pick([" ", " ", "\u{00A0}", "\u{202F}", "\n", "\t"]) }
            text += g.pick(pool) + (g.chance(20) ? g.pick(punctuation) : "")
        }
        return text
    }

    /// Suite de caractères quelconques (contrôle, symboles, marques combinantes, emoji, écritures non latines) : seule
    /// l'absence de plantage s'y vérifie.
    static func unicode(_ g: inout SeededGenerator, length: ClosedRange<Int> = 0...40) -> String {
        var scalars = String.UnicodeScalarView()
        for _ in 0..<g.int(length) {
            let value: Int
            switch g.int(0...7) {
            case 0: value = g.int(0x20...0x7E)
            case 1: value = g.int(0...0x1F)
            case 2: value = g.int(0xA0...0x2FF)
            case 3: value = g.int(0x300...0x36F)
            case 4: value = g.int(0x2000...0x206F)
            case 5: value = g.int(0x0600...0x06FF)
            case 6: value = g.int(0x1F300...0x1F6FF)
            default: value = g.pick([0x00A0, 0x202F, 0x20AC, 0x24, 0xA3, 0x25, 0xB2, 0xB3, 0xBD, 0x2D, 0x2F, 0x3A])
            }
            if let scalar = Unicode.Scalar(UInt32(value)) { scalars.append(scalar) }
        }
        return String(scalars)
    }
}
