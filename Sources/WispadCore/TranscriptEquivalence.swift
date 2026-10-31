import Foundation

/// Compare deux transcriptions sans tenir compte de l'écriture : casse, accents,
/// ponctuation, hésitations et nombres dits en lettres ou en chiffres, en français comme en anglais.
/// Une fonction pure, distincte du garde-fou : elle ne décide pas si une correction est fidèle.
public enum TranscriptEquivalence {
    /// Attente du fichier depuis le début de la fin de dictée : assez large pour le cas mesuré,
    /// jamais au-delà de 4 s. Le flux reste le secours si le fichier dépasse cette borne.
    public static func fileWaitSeconds(audioDuration: Double) -> Double {
        let seconds = audioDuration.isFinite ? max(0, audioDuration) : 0
        return min(4, 1.2 + 0.06 * seconds)
    }

    public static func equivalent(_ left: String, _ right: String) -> Bool {
        normalize(left) == normalize(right)
    }

    /// Mots qui diffèrent entre deux écoutes, après normalisation : le plus long des deux textes moins leur plus
    /// longue sous-suite commune. 0 pour deux écoutes équivalentes. Sert aux traces, jamais au texte.
    public static func differingWords(_ left: String, _ right: String) -> Int {
        let a = normalize(left).split(separator: " "), b = normalize(right).split(separator: " ")
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 250_000 else { return max(a.count, b.count) }
        var previous = Array(repeating: 0, count: b.count + 1)
        for word in a {
            var row = Array(repeating: 0, count: b.count + 1)
            for (j, other) in b.enumerated() {
                row[j + 1] = word == other ? previous[j] + 1 : max(previous[j + 1], row[j])
            }
            previous = row
        }
        return max(a.count, b.count) - previous[b.count]
    }

    public static func normalize(_ text: String) -> String {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        let separated = String(folded.map { $0.isPunctuation ? " " : $0 })
        var tokens = separated.split(whereSeparator: \.isWhitespace).map(String.init)
        tokens.removeAll { fillers.contains($0) }
        return glueDigitGroups(SpokenNumbers.spell(canonicalForms(tokens))).joined(separator: " ")
    }

    static let fillers: Set<String> = [
        "euh", "heu", "bah", "ben", "hum", "mmh", "mh", "hm",
        "um", "umm", "uh", "uhm", "erm", "er", "hmm", "mm",
    ]

    /// Même mot, autre écriture : unité abrégée ou non (« MHz » / « mégahertz », « Go » / « gigas »),
    /// élision (« d'faire » / « de faire »), « et cetera » / « etc. ». Mesuré sur de vraies dictées,
    /// ces seuls écarts relançaient une correction pour rien.
    private static let synonyms: [String: String] = [
        "megahertz": "mhz", "mega": "mhz", "megas": "mhz", "gigahertz": "ghz",
        "giga": "go", "gigas": "go", "gigaoctet": "go", "gigaoctets": "go",
        "megaoctet": "mo", "megaoctets": "mo", "tera": "to", "teras": "to", "teraoctet": "to", "teraoctets": "to",
        "d": "de", "j": "je", "l": "le", "s": "se", "qu": "que", "c": "ce", "m": "me", "n": "ne",
        "gigabyte": "go", "gigabytes": "go", "gig": "go", "gigs": "go",
        "megabyte": "mo", "megabytes": "mo", "terabyte": "to", "terabytes": "to",
        "gb": "go", "mb": "mo", "tb": "to",
        "okay": "ok",
    ]

    private static func canonicalForms(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            if tokens[index] == "et", index + 1 < tokens.count, tokens[index + 1] == "cetera" {
                result.append("etc")
                index += 2
                continue
            }
            // « 20 % » perd son signe avec la ponctuation : « pour cent » et « percent » aussi.
            if tokens[index] == "pour", index + 1 < tokens.count, tokens[index + 1] == "cent" {
                index += 2
                continue
            }
            if tokens[index] == "percent" {
                index += 1
                continue
            }
            result.append(synonyms[tokens[index]] ?? tokens[index])
            index += 1
        }
        return result
    }

    /// « 2 666 » et « 12 345 678 » : un nombre suivi de groupes de trois chiffres.
    private static func glueDigitGroups(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            var token = tokens[index]
            index += 1
            if token.allSatisfy(\.isNumber) {
                while index < tokens.count, tokens[index].count == 3, tokens[index].allSatisfy(\.isNumber) {
                    token += tokens[index]
                    index += 1
                }
            }
            result.append(token)
        }
        return result
    }
}
