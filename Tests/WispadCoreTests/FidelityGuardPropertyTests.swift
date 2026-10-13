import Foundation
import Testing
@testable import WispadCore

/// Filet anti-régression de `FidelityGuard` : défauts corrigés, cas limites, propriétés sur des corrections simulées.
struct FidelityGuardPropertyTests {
    /// Ce qu'un modèle de correction fait d'une dictée : majuscules, ponctuation, mots retirés, termes techniques,
    /// traductions, références ou années inventées, guillemets, puces.
    static let insertions = [
        "Vercel", "OAuth", "DDR4", "DDR5", "i9", "RTX4090", "G.Skill", "tools", "outils", "Claude", "Seedance", "M-E-L",
        "C-E-S", "« bonjour »", "\"oui\"", "-", "—", ":", "2026", "03/11/2026", "14h30", "2:30 PM", "25 €", "16 Go",
        "6000 MHz", "Envoie-le", "c'est-à-dire", "IA", "AI", "le 3 novembre 2026", "November 3, 2026",
    ]

    static func correction(of transcript: String, _ g: inout SeededGenerator, changes: ClosedRange<Int> = 0...4) -> String {
        var words = transcript.components(separatedBy: " ")
        for _ in 0..<g.int(changes) {
            switch g.int(0...6) {
            case 0 where !words.isEmpty: words[g.int(0...(words.count - 1))] = g.pick(insertions)
            case 1 where words.count > 1: words.remove(at: g.int(0...(words.count - 1)))
            case 2: words.insert(g.pick(insertions + SampleText.frenchWords), at: g.int(0...words.count))
            case 3 where !words.isEmpty:
                let index = g.int(0...(words.count - 1))
                words[index] = words[index].capitalized + g.pick([".", ",", "", "!", " :"])
            case 4 where !words.isEmpty:
                let index = g.int(0...(words.count - 1))
                words[index] = "« " + words[index] + " »"
            case 5: words.insert(g.pick(["\n- ", "\n1. ", "\n"]), at: g.int(0...words.count))
            default: break
            }
        }
        return words.joined(separator: " ")
    }

    /// Une dictée et son contexte : transcription, correction proposée, texte voisin, dictionnaire, autre écoute.
    struct Dictation {
        var transcript: String
        var corrected: String
        var context: String?
        var dictionary: [String]
        var previous: [String]
        var alternative: String?

        func check(_ corrected: String? = nil) -> String {
            FidelityGuard.check(transcript: transcript, corrected: corrected ?? self.corrected, context: context,
                                dictionary: dictionary, previousDictations: previous, alternative: alternative)
        }
    }

    static func dictation(_ g: inout SeededGenerator, changes: ClosedRange<Int> = 0...4) -> Dictation {
        let english = g.chance(30)
        let transcript = SampleText.sentence(&g, english: english, words: 1...12)
        return Dictation(
            transcript: transcript,
            corrected: correction(of: transcript, &g, changes: changes),
            context: g.chance(30) ? SampleText.sentence(&g, english: english, words: 5...20) : nil,
            dictionary: g.chance(20) ? [g.pick(insertions)] : [],
            previous: g.chance(20) ? [SampleText.sentence(&g, english: english, words: 8...12)] : [],
            alternative: g.chance(20) ? correction(of: transcript, &g) : nil
        )
    }

    /// Mots séparés par les blancs, scalaire par scalaire : une marque combinante après une espace ne soude pas deux mots.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !current.isEmpty { tokens.append(String(current)) }
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }

    // MARK: Défauts corrigés

    /// Une transcription sans mot (« … », « ? ») dont la correction n'était qu'une référence inventée : la référence
    /// retirée, il ne restait rien, et une dictée non vide aurait collé un texte vide.
    @Test func aDictationNeverBecomesBlank() {
        #expect(FidelityGuard.check(transcript: "…", corrected: "RTX4090") == "…")
        #expect(FidelityGuard.check(transcript: "?", corrected: "i9") == "?")
        #expect(FidelityGuard.check(transcript: "#", corrected: "DDR5") == "#")
        // Une correction faite seulement de blancs n'est pas une correction.
        #expect(FidelityGuard.check(transcript: "bonjour", corrected: "\n") == "bonjour")
        #expect(FidelityGuard.check(transcript: "bonjour", corrected: "   ") == "bonjour")
        // Inchangé : correction vide, ou transcription sans mot avec une correction fidèle.
        #expect(FidelityGuard.check(transcript: "bonjour", corrected: "") == "bonjour")
        #expect(FidelityGuard.check(transcript: "…", corrected: "…") == "…")
    }

    // MARK: Cas limites

    @Test func emptyAndPunctuationOnlyInputs() {
        #expect(FidelityGuard.check(transcript: "", corrected: "") == "")
        #expect(FidelityGuard.check(transcript: "", corrected: "Bonjour.") == "Bonjour.")
        #expect(FidelityGuard.check(transcript: "…", corrected: "Bonjour.") == "Bonjour.")
        #expect(FidelityGuard.check(transcript: "bonjour", corrected: "Bonjour.", context: "", dictionary: [""], previousDictations: [""], alternative: "") == "Bonjour.")
    }

    /// Une longue dictée (plus de 250 000 paires de mots pour le diff) reste contrôlée sur sa longueur et sur la copie du
    /// contexte ; une correction fidèle passe telle quelle.
    @Test func longDictationsAreStillGuarded() {
        let sentence = "je pense que le build a fail parce que la variable manque dans le fichier de configuration"
        let transcript = Array(repeating: sentence, count: 40).joined(separator: " ")
        let faithful = Array(repeating: "Je pense que le build a fail parce que la variable manque dans le fichier de configuration.", count: 40)
            .joined(separator: " ")
        #expect(FidelityGuard.check(transcript: transcript, corrected: faithful) == faithful)
        #expect(FidelityGuard.check(transcript: transcript, corrected: faithful + " " + faithful) == transcript)
    }

    // MARK: Propriétés

    /// Une correction identique à la transcription est fidèle : elle ressort telle quelle, quel que soit le contexte.
    @Test func anUnchangedDictationIsKept() {
        forAll(1_000, seed: 0x4644_4731, { g in Self.dictation(&g) }) { dictation in
            let output = dictation.check(dictation.transcript)
            return output == dictation.transcript ? nil : "« \(dictation.transcript) » → « \(output) »"
        }
    }

    /// Le garde-fou est une projection pour une correction qui retouche un seul endroit : ce qu'il rend, il l'accepte tel
    /// quel à la passe suivante. Avec plusieurs inventions voisines (une date complète à la place de deux mots), retirer
    /// l'année ou la référence change le découpage du diff et la passe suivante répare encore : limite connue.
    @Test func checkingTwiceChangesNothingMore() {
        forAll(1_000, seed: 0x4644_4732, { g in Self.dictation(&g, changes: 0...1) }) { dictation in
            let once = dictation.check()
            let twice = dictation.check(once)
            return twice == once ? nil : "« \(dictation.transcript) » ‖ « \(dictation.corrected) » → « \(once) » → « \(twice) »"
        }
    }

    /// Une dictée qui a du contenu ne devient jamais blanche.
    @Test func nonBlankDictationsStayNonBlank() {
        forAll(1_500, seed: 0x4644_4733, { g in
            var dictation = Self.dictation(&g)
            if g.chance(40) { dictation.transcript = g.pick(["…", "?", "#", "-", "« »", "...", "!"]) }
            if g.chance(20) { dictation.corrected = g.chance(50) ? SampleText.unicode(&g, length: 0...6) : g.pick(Self.insertions) }
            return dictation
        }) { dictation in
            guard !dictation.transcript.allSatisfy(\.isWhitespace) else { return nil }
            let output = dictation.check()
            return output.allSatisfy(\.isWhitespace) ? "« \(dictation.transcript) » ‖ « \(dictation.corrected) » → blanc" : nil
        }
    }

    /// Rien d'inventé : chaque mot sans chiffre du texte rendu vient de la transcription, de la correction ou de l'autre
    /// écoute. Les chiffres ont leurs propres règles (une année non dite est retirée de la date).
    @Test func everyWordComesFromWhatWasHeardOrProposed() {
        forAll(1_000, seed: 0x4644_4734, { g in Self.dictation(&g) }) { dictation in
            let output = dictation.check()
            let sources = Self.tokens(dictation.transcript) + Self.tokens(dictation.corrected) + Self.tokens(dictation.alternative ?? "")
            let known = Set(sources.map { CorrectionLearner.key($0.trimmingCharacters(in: .punctuationCharacters)) })
            for token in Self.tokens(output) where !token.contains(where: \.isNumber) {
                let key = CorrectionLearner.key(token.trimmingCharacters(in: .punctuationCharacters))
                if !key.isEmpty, !known.contains(key) { return "« \(dictation.corrected) » → « \(output) » invente « \(token) »" }
            }
            return nil
        }
    }

    /// Longueur bornée : le texte rendu n'est jamais plus long que la correction et la transcription réunies.
    @Test func lengthIsBounded() {
        forAll(1_000, seed: 0x4644_4735, { g in Self.dictation(&g) }) { dictation in
            let output = dictation.check()
            let bound = dictation.transcript.count + dictation.corrected.count
            return output.count <= bound ? nil : "« \(dictation.corrected) » → « \(output) » (\(output.count) > \(bound))"
        }
    }

    /// Aucune entrée, même faite de caractères quelconques, ne fait planter le garde-fou.
    @Test func arbitraryTextNeverCrashes() {
        forAll(1_000, seed: 0x4644_4736, { g in
            Dictation(transcript: g.chance(50) ? SampleText.unicode(&g) : SampleText.sentence(&g, english: false),
                      corrected: g.chance(50) ? SampleText.unicode(&g) : SampleText.sentence(&g, english: false),
                      context: g.chance(30) ? SampleText.unicode(&g) : nil,
                      dictionary: g.chance(30) ? [SampleText.unicode(&g, length: 0...8)] : [],
                      previous: g.chance(30) ? [SampleText.unicode(&g)] : [],
                      alternative: g.chance(30) ? SampleText.unicode(&g) : nil)
        }) { dictation in
            _ = dictation.check()
            return nil
        }
    }
}

/// Filet anti-régression de `PhoneticKey`, la prononciation approchée qui juge deux écritures à l'oreille.
struct PhoneticKeyPropertyTests {
    static let words = SampleText.frenchWords + SampleText.englishWords + [
        "j'écris", "j'ai", "pris", "mer", "maire", "sot", "seau", "sept", "cette", "vingt", "vin", "mille", "mil",
        "fille", "fil", "doigt", "doit", "C-E-S", "M-E-L", "Vercel", "versel", "tranquille", "aujourd'hui", "œuf",
        "garçon", "Noël", "naïf", "ça", "où", "ès", "être", "qu'il", "peut-être",
    ]

    /// Un mot se prononce comme lui-même.
    @Test func everyWordSoundsLikeItself() {
        for word in Self.words where !CorrectionLearner.key(word).isEmpty && !PhoneticKey.key([word]).isEmpty {
            #expect(PhoneticKey.soundsAlike([word], [word]), "« \(word) »")
        }
        forAll(2_000, seed: 0x5048_4E31, { g in SampleText.unicode(&g, length: 1...12) }) { word in
            guard !CorrectionLearner.key(word).isEmpty, !PhoneticKey.key([word]).isEmpty else { return nil }
            return PhoneticKey.soundsAlike([word], [word]) ? nil : "« \(word) »"
        }
    }

    /// La casse ne s'entend pas, sauf « y » minuscule, le pronom, qu'une capitale fait lire comme la lettre.
    @Test func casingIsNotHeard() {
        for word in Self.words where word != "y" {
            #expect(PhoneticKey.key([word.uppercased()]) == PhoneticKey.key([word.lowercased()]), "« \(word) »")
        }
        #expect(PhoneticKey.key(["Y"]) != PhoneticKey.key(["y"]))
    }

    /// L'apostrophe droite et l'apostrophe typographique se lisent pareil ; une suite de mots se lit mot après mot.
    @Test func apostrophesAndSequences() {
        for word in Self.words where word.contains("'") {
            #expect(PhoneticKey.key([word]) == PhoneticKey.key([word.replacingOccurrences(of: "'", with: "’")]), "« \(word) »")
        }
        forAll(2_000, seed: 0x5048_4E32, { g in
            (g.pick(Self.words), g.pick(Self.words))
        }) { pair in
            let joined = PhoneticKey.key([pair.0, pair.1])
            return joined == PhoneticKey.key([pair.0]) + PhoneticKey.key([pair.1]) ? nil : "« \(pair.0) » « \(pair.1) »"
        }
    }

    /// Aucune écriture, même faite de caractères quelconques, ne fait planter la lecture à l'oreille.
    @Test func arbitraryTextNeverCrashes() {
        forAll(3_000, seed: 0x5048_4E33, { g in
            (written: (0..<g.int(0...4)).map { _ in SampleText.unicode(&g, length: 0...12) },
             heard: (0..<g.int(0...4)).map { _ in g.chance(50) ? SampleText.unicode(&g, length: 0...3) : g.pick(Self.words) })
        }) { sample in
            _ = PhoneticKey.key(sample.written)
            _ = PhoneticKey.soundsAlike(sample.written, sample.heard)
            _ = PhoneticKey.spells(sample.written, sample.heard)
            return nil
        }
    }
}
