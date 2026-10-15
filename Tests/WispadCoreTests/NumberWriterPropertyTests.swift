import Foundation
import Testing
@testable import WispadCore

/// Filet anti-régression de `NumberWriter` : défauts corrigés, cas limites, propriétés sur des phrases tirées au hasard.
struct NumberWriterPropertyTests {
    private let nb = "\u{00A0}"
    private let thin = "\u{202F}"

    static let formats: [DictationNumberFormat] = DictationNumberFormat.Thousands.allCases.flatMap { thousands in
        [true, false].map { DictationNumberFormat(thousands: thousands, symbols: $0) }
    }

    private func french(_ text: String, _ format: DictationNumberFormat = DictationNumberFormat()) -> String {
        NumberWriter.apply(text, format: format, english: false)
    }

    private func english(_ text: String, _ format: DictationNumberFormat = DictationNumberFormat()) -> String {
        NumberWriter.apply(text, format: format, english: true)
    }

    // MARK: Défauts corrigés

    /// « kilowatt-hours » s'écrit avec un trait d'union en anglais : sans cette forme, « kilowatt » seul était lu comme
    /// l'unité (« 15 kW-hours »), et l'écriture en lettres devenait « kilowatts-hours » à la passe suivante.
    @Test func englishKilowattHoursKeepTheirUnit() {
        #expect(english("The car used 15 kilowatt-hours.") == "The car used 15\(nb)kWh.")
        #expect(english("It used 1 kilowatt-hour.") == "It used 1\(nb)kWh.")
        let words = DictationNumberFormat(symbols: false)
        #expect(english("The car used 15 kWh.", words) == "The car used 15 kilowatt-hours.")
        #expect(english("The car used 15 kilowatt-hours.", words) == "The car used 15 kilowatt-hours.")
        #expect(english("It used 1 kilowatt-hour.", words) == "It used 1 kilowatt-hour.")
    }

    /// Au singulier (moins de 2 en français), « kilomètre par heure » restait à moitié récrit : « 1,5 km par heure ».
    @Test func singularSpeedsBecomeKilometersPerHour() {
        #expect(french("Il roule à 1,5 kilomètre par heure.") == "Il roule à 1,5\(nb)km/h.")
        #expect(french("Une pointe à 1 kilomètre-heure.") == "Une pointe à 1\(nb)km/h.")
        #expect(english("At 1 kilometer per hour.") == "At 1\(nb)km/h.")
        #expect(english("At 1 kilometre per hour.") == "At 1\(nb)km/h.")
        // L'écriture en lettres, au singulier, revient à son symbole.
        let words = DictationNumberFormat(symbols: false)
        #expect(french(french("Il roule à 1,5 km/h.", words)) == "Il roule à 1,5\(nb)km/h.")
    }

    /// Un symbole qui suit déjà un montant n'appartient pas au nombre suivant : « 20 € 3 fois » devenait
    /// « 20 3 € fois », et « 3 € 50 » (trois euros cinquante) devenait « 3 50 € ».
    @Test func aSymbolAfterAnAmountStaysWithIt() {
        #expect(french("J'ai payé 20 € 3 fois.") == "J'ai payé 20\(nb)€ 3 fois.")
        #expect(french("Il reste 5 € 20 centimes.") == "Il reste 5\(nb)€ 20 centimes.")
        #expect(french("Il a 3 € 50.") == "Il a 3\(nb)€ 50.")
        #expect(english("Paid 20 $ 3 times.") == "Paid $20 3 times.")
        // Devant un nombre, sans montant avant lui, le symbole reste celui du nombre.
        #expect(french("Prix : € 25.") == "Prix : 25\(nb)€.")
        #expect(french("Ça fait $3.50 là-bas.") == "Ça fait 3,50\(nb)$ là-bas.")
    }

    /// Un nombre précédé de sa devise est un montant, jamais une mesure : « $5m » (cinq millions) devenait « $5 m ».
    @Test func aCurrencyPrefixedAmountIsNeverAMeasure() {
        #expect(english("They raised $5m last year.") == "They raised $5m last year.")
        #expect(english("A £3m deal.") == "A £3m deal.")
        #expect(french("Ils ont levé €5m.") == "Ils ont levé €5m.")
        // Une vraie mesure reste récrite.
        #expect(english("A 5m cable.") == "A 5\(nb)m cable.")
    }

    // MARK: Cas limites

    @Test func emptyAndDigitOnlyTexts() {
        for format in Self.formats {
            for english in [false, true] {
                for text in ["", " ", "\n", "€", "%", "km", "0", "00", "€ €", "1/2", "½", "- 5", "5 -"] {
                    #expect(NumberWriter.apply(text, format: format, english: english) == text, "« \(text) »")
                }
            }
        }
    }

    @Test func zerosNegativesAndHugeNumbers() {
        #expect(french("Solde : 0 €.") == "Solde : 0\(nb)€.")
        #expect(french("Écart : -5 €.") == "Écart : -5\(nb)€.")
        #expect(french("Il gagne 1500000 € par an.") == "Il gagne 1\(thin)500\(thin)000\(nb)€ par an.")
        // Quarante chiffres : ni plantage ni perte, groupés par trois depuis la droite.
        let huge = String(repeating: "9", count: 40)
        #expect(NumberWriter.apply(huge + " €", format: DictationNumberFormat(thousands: .none), english: false) == huge + "\(nb)€")
        #expect(french(huge + " €") == "9" + String(repeating: thin + "999", count: 13) + "\(nb)€")
        // Des décimales très longues ne sont ni coupées ni regroupées.
        #expect(french("Pi vaut 3,14159265358979 m.") == "Pi vaut 3,14159265358979\(nb)m.")
        // Les centimes d'un prix ont deux chiffres, une mesure garde les siens.
        #expect(french("Un café à 2,5 € et 2,5 km.") == "Un café à 2,50\(nb)€ et 2,5\(nb)km.")
        #expect(english("A 2.5 $ coffee.") == "A $2.50 coffee.")
    }

    @Test func phonesOnlyWhenTheyAreFrenchNumbers() {
        #expect(french("Appelle le 06 12 34 56 78 9.") == "Appelle le 06 12 34 56 78 9.")
        #expect(french("Ou le 0012345678.") == "Ou le 0012345678.")
        // Le zéro national n'est retiré qu'entre parenthèses (« +33 (0)6 ») ; ailleurs, le numéro reste tel quel.
        #expect(french("Ou le +330612345678.") == "Ou le +330612345678.")
        #expect(french("Ou le +44612345678.") == "Ou le +44612345678.")
        // Déjà par paires : rien ne bouge.
        #expect(french("Appelle le 06 12 34 56 78.") == "Appelle le 06 12 34 56 78.")
        #expect(french("Appelle le +33 6 12 34 56 78.") == "Appelle le +33 6 12 34 56 78.")
    }

    @Test func unitsNextToEmojiAndOtherScripts() {
        #expect(french("🙂 25 € 🙂") == "🙂 25\(nb)€ 🙂")
        #expect(french("Prix 25 €, puis 中文 3 km.") == "Prix 25\(nb)€, puis 中文 3\(nb)km.")
        // Une lettre accolée au nombre en fait une référence, pas une mesure.
        #expect(french("Le modèle X25 €uro") == "Le modèle X25 €uro")
    }

    // MARK: Propriétés

    /// Repasser sur un texte déjà mis au format ne change plus rien, quel que soit le réglage.
    @Test func applyingTwiceChangesNothingMore() {
        forAll(1_500, seed: 0x4E55_4D31, { g in
            (text: SampleText.sentence(&g, english: g.chance(50)), format: g.pick(Self.formats), english: g.chance(50))
        }) { sample in
            let once = NumberWriter.apply(sample.text, format: sample.format, english: sample.english)
            let twice = NumberWriter.apply(once, format: sample.format, english: sample.english)
            return twice == once ? nil : "« \(sample.text) » → « \(once) » → « \(twice) » (\(sample.format), anglais : \(sample.english))"
        }
    }

    /// Un texte sans chiffre ressort tel quel, octet pour octet.
    @Test func textWithoutDigitsIsLeftAlone() {
        forAll(1_500, seed: 0x4E55_4D32, { g in
            (text: g.chance(70) ? SampleText.digitless(&g) : SampleText.unicode(&g), format: g.pick(Self.formats), english: g.chance(50))
        }) { sample in
            guard !sample.text.unicodeScalars.contains(where: { $0.properties.generalCategory == .decimalNumber }) else { return nil }
            let output = NumberWriter.apply(sample.text, format: sample.format, english: sample.english)
            return output == sample.text ? nil : "« \(sample.text) » → « \(output) »"
        }
    }

    /// Les chiffres significatifs restent les mêmes, dans le même ordre : seuls un zéro de centimes (« 3,5 € » →
    /// « 3,50 € ») ou le zéro de « +33 (0)6 » peuvent apparaître ou disparaître. « m2 » devient « m² », et « et 1/2 »
    /// s'écrit « et demi » : ces deux formes sont mises à part.
    @Test func significantDigitsAreKept() {
        func significant(_ text: String) -> String { String(text.filter { $0.isASCII && $0.isNumber && $0 != "0" }) }
        forAll(1_500, seed: 0x4E55_4D33, { g in
            (text: SampleText.sentence(&g, english: g.chance(50)), format: g.pick(Self.formats), english: g.chance(50))
        }) { sample in
            guard !sample.text.contains("1/2"), !sample.text.contains("m2"), !sample.text.contains("m3") else { return nil }
            let output = NumberWriter.apply(sample.text, format: sample.format, english: sample.english)
            return significant(output) == significant(sample.text) ? nil : "« \(sample.text) » → « \(output) »"
        }
    }

    /// Longueur bornée : chaque nombre s'allonge au plus de son unité en toutes lettres et de ses séparateurs.
    @Test func lengthGrowsBoundedly() {
        forAll(1_500, seed: 0x4E55_4D34, { g in
            (text: SampleText.sentence(&g, english: g.chance(50)), format: g.pick(Self.formats), english: g.chance(50))
        }) { sample in
            let output = NumberWriter.apply(sample.text, format: sample.format, english: sample.english)
            let numbers = sample.text.split(whereSeparator: { !$0.isNumber }).count
            let digits = sample.text.filter(\.isNumber).count
            let bound = sample.text.count + 20 * numbers + digits / 3
            return output.count <= bound ? nil : "« \(sample.text) » → « \(output) » (\(output.count) > \(bound))"
        }
    }

    /// Passer des lettres aux symboles donne le même texte que les symboles directement : chaque unité écrite en lettres
    /// se relit. Seule exception : « pounds » en anglais, qui peut aussi être un poids.
    @Test func wordsAndSymbolsSettingsAgree() {
        forAll(1_500, seed: 0x4E55_4D35, { g in
            (text: SampleText.sentence(&g, english: g.chance(50)), thousands: g.pick(DictationNumberFormat.Thousands.allCases), english: g.chance(50))
        }) { sample in
            guard !(sample.english && sample.text.contains("£")) else { return nil }
            let words = DictationNumberFormat(thousands: sample.thousands, symbols: false)
            let symbols = DictationNumberFormat(thousands: sample.thousands, symbols: true)
            let viaWords = NumberWriter.apply(NumberWriter.apply(sample.text, format: words, english: sample.english),
                                              format: symbols, english: sample.english)
            let direct = NumberWriter.apply(sample.text, format: symbols, english: sample.english)
            return viaWords == direct ? nil : "« \(sample.text) » : « \(viaWords) » ≠ « \(direct) »"
        }
    }

    /// Les exemples de la consigne sont déjà au format : un modèle qui les suit ne voit pas son texte réécrit.
    @Test func promptExamplesAreAlreadyFormatted() {
        for format in Self.formats {
            for english in [false, true] {
                for sample in format.samples(english: english) {
                    #expect(NumberWriter.apply(sample, format: format, english: english) == sample, "\(format) : « \(sample) »")
                }
            }
        }
    }

    /// Aucune entrée, même faite de caractères de contrôle, de marques combinantes ou d'écritures non latines, ne fait
    /// planter l'écriture des nombres.
    @Test func arbitraryTextNeverCrashes() {
        forAll(2_000, seed: 0x4E55_4D36, { g in
            (text: g.chance(50) ? SampleText.unicode(&g, length: 0...80) : SampleText.unicode(&g) + SampleText.amount(&g) + SampleText.unicode(&g),
             format: g.pick(Self.formats), english: g.chance(50))
        }) { sample in
            _ = NumberWriter.apply(sample.text, format: sample.format, english: sample.english)
            return nil
        }
    }
}
