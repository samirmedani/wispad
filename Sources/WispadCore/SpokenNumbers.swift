import Foundation

/// Nombres dits en toutes lettres, en français et en anglais : « deux mille six cent soixante-six »,
/// « quatre-vingt-quinze », « two thousand six hundred sixty six », « one hundred and five ».
/// Les mots arrivent déjà séparés (tirets compris), en minuscules et sans accents.
enum SpokenNumbers {
    private static let units: [String: Int] = [
        // Français
        "zero": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
        "six": 6, "sept": 7, "huit": 8, "neuf": 9, "dix": 10, "onze": 11, "douze": 12,
        "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16, "vingt": 20, "vingts": 20,
        "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60,
        // Anglais
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]

    /// Valeur du nombre qui commence à `start` et indice du premier mot qui le suit.
    /// Une suite démesurée (« cent cent cent… », dite ou mal transcrite) s'arrête avant le mot qui ferait déborder
    /// sa valeur : ce mot commence le nombre suivant, au lieu d'arrêter l'app.
    static func parse(_ tokens: [String], from start: Int) -> (value: Int, next: Int)? {
        var total = 0
        var current = 0
        var index = start
        var consumed = false
        var afterMultiplier = false
        while index < tokens.count {
            let token = tokens[index]
            // « vingt et un », « soixante et onze » : « et » relie seulement une unité à une dizaine.
            if token == "et" {
                guard consumed, index + 1 < tokens.count, let small = units[tokens[index + 1]], small < 20,
                      isTens(current % 100), let next = sum(current, small), sum(total, next) != nil else { break }
                current = next
                index += 2
                afterMultiplier = false
                continue
            }
            // « one hundred and five » : « and » ne suit qu'une centaine ou un millier.
            if token == "and" {
                guard afterMultiplier, index + 1 < tokens.count, units[tokens[index + 1]] != nil else { break }
                index += 1
                afterMultiplier = false
                continue
            }
            if token == "mille" || token == "thousand" {
                guard let scaled = product(max(current, 1), 1_000), let next = sum(total, scaled) else { break }
                total = next
                current = 0
                consumed = true
                afterMultiplier = true
                index += 1
                continue
            }
            if token == "cent" || token == "cents" || token == "hundred" {
                guard let next = product(max(current, 1), 100), sum(total, next) != nil else { break }
                current = next
                consumed = true
                afterMultiplier = true
                index += 1
                continue
            }
            // « quatre-vingt » : le « quatre » déjà lu vaut 80, pas 4 + 20.
            if (token == "vingt" || token == "vingts"), current % 100 == 4 {
                guard let next = sum(current, 76), sum(total, next) != nil else { break }
                current = next
                consumed = true
                afterMultiplier = false
                index += 1
                continue
            }
            guard let value = units[token], canFollow(current % 100, with: value),
                  let next = sum(current, value), sum(total, next) != nil else { break }
            current = next
            consumed = true
            afterMultiplier = false
            index += 1
        }
        guard consumed else { return nil }
        return (total + current, index)
    }

    /// `a + b`, ou nil s'il déborde d'un `Int`.
    private static func sum(_ a: Int, _ b: Int) -> Int? {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : value
    }

    /// `a × b`, ou nil s'il déborde d'un `Int`.
    private static func product(_ a: Int, _ b: Int) -> Int? {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? nil : value
    }

    /// Une dizaine seule (vingt à quatre-vingt-dix) : « et » peut y joindre une unité.
    private static func isTens(_ low: Int) -> Bool {
        low >= 20 && low % 10 == 0
    }

    /// Un mot ne prolonge le nombre que s'il en complète la dizaine : « vingt-deux », « dix-sept »,
    /// « soixante-dix », « cent deux ». Deux unités de suite (« deux trois ») sont deux nombres.
    private static func canFollow(_ low: Int, with value: Int) -> Bool {
        if low == 0 { return true }
        if value < 10 { return low % 10 == 0 }
        if value < 20 { return low == 60 || low == 80 }
        return false
    }

    /// Chaque nombre dit en lettres devient ses chiffres ; les autres mots restent.
    static func spell(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            if let (value, next) = parse(tokens, from: index), next > index {
                result.append(String(value))
                index = next
            } else {
                result.append(tokens[index])
                index += 1
            }
        }
        return result
    }
}
