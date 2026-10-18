import Foundation

/// Ordinaux en chiffres de la mise en forme française d'xAI, rendus tels qu'ils ont été dits. Le fichier complet écrit
/// « 1ᵉʳ », « 1ʳᵉ », « 2ᵈ », « 2ᵈᵉ », « 3ᵉ » : le suffixe dit le mot prononcé, et « 2ᵈᵉ » est presque toujours l'unité de
/// temps (« 60 images par 2ᵈᵉ », « 5 2ᵈᵉˢ » : 17 cas sur 17 dans de vraies dictées d'octobre 2026). Le flux en direct
/// écrit ces mots en lettres : rendus ainsi, flux et fichier se comparent mot pour mot, puis la correction et la mise
/// en forme décident (« le premier mai » → « le 1er mai »). Au-delà de dix (« 21ᵉ siècle »), l'abréviation reste.
public enum SpokenOrdinals {
    /// Chiffres collés à un suffixe en lettres d'exposant, « ˢ » au pluriel ; jamais au milieu d'un mot ou d'un nombre.
    private static let ordinal = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_.,])([0-9]{1,3})(ᵉʳ|ʳᵉ|ⁿᵈᵉ|ᵈᵉ|ⁿᵈ|ᵈ|ᵉ)(ˢ)?(?![\p{L}\p{N}_])"#
    )
    private static let fromSecond = ["deuxième", "troisième", "quatrième", "cinquième", "sixième", "septième", "huitième",
                                     "neuvième", "dixième"]

    public static func restore(_ text: String) -> String {
        // Tous les suffixes contiennent « ᵉ » ou « ᵈ » : sans eux, rien à chercher.
        guard text.unicodeScalars.contains(where: { $0 == "\u{1D49}" || $0 == "\u{1D48}" }) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in ordinal.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let number = Int(source.substring(with: match.range(at: 1))),
                  var word = word(number, suffix: source.substring(with: match.range(at: 2))) else { continue }
            if match.range(at: 3).location != NSNotFound { word += "s" }
            if startsSentence(before: match.range.location, in: source) {
                word = word.prefix(1).uppercased() + word.dropFirst()
            }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + word
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }

    /// Le mot dit, d'après le nombre et son suffixe ; nil si le suffixe ne va pas avec le nombre ou au-delà de dix.
    static func word(_ number: Int, suffix: String) -> String? {
        switch (number, suffix) {
        case (1, "ᵉʳ"): return "premier"
        case (1, "ʳᵉ"): return "première"
        case (2, "ᵈ"), (2, "ⁿᵈ"): return "second"
        case (2, "ᵈᵉ"), (2, "ⁿᵈᵉ"): return "seconde"
        case (2...10, "ᵉ"): return fromSecond[number - 2]
        default: return nil
        }
    }

    /// Début de texte, de ligne ou de phrase, guillemet ou parenthèse ouvrants compris.
    private static func startsSentence(before location: Int, in source: NSString) -> Bool {
        var index = location - 1
        while index >= 0 {
            guard let scalar = Unicode.Scalar(source.character(at: index)) else { return false }
            if scalar == "\n" { return true }
            if CharacterSet.whitespaces.contains(scalar) || "«\"“(".unicodeScalars.contains(scalar) {
                index -= 1
                continue
            }
            return ".!?…".unicodeScalars.contains(scalar)
        }
        return true
    }
}
