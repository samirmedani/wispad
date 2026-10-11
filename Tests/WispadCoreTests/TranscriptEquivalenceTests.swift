import Testing
@testable import WispadCore

struct TranscriptEquivalenceTests {
    @Test func spelledThousandsMatchDigitsAndGroupedDigits() {
        #expect(TranscriptEquivalence.equivalent("deux mille six cent soixante-six", "2666"))
        #expect(TranscriptEquivalence.equivalent("Euh, deux mille six cent soixante-six.", "2 666"))
        #expect(TranscriptEquivalence.equivalent("2 666", "2666"))
    }

    @Test func quatreVingtUneMatchesEightyOne() {
        #expect(TranscriptEquivalence.equivalent("quatre-vingt-une", "81"))
        #expect(TranscriptEquivalence.equivalent("quatre-vingts", "80"))
        #expect(TranscriptEquivalence.equivalent("soixante-et-onze", "71"))
    }

    /// « et » ne joint une unité qu'à une dizaine, et deux unités de suite restent deux nombres : « deux et trois »
    /// n'est pas « cinq », « sept-huit personnes » n'est pas « quinze personnes ».
    @Test func separateNumbersAreNotAddedTogether() {
        #expect(TranscriptEquivalence.equivalent("deux et trois font cinq", "2 et 3 font 5"))
        #expect(!TranscriptEquivalence.equivalent("deux et trois", "cinq"))
        #expect(TranscriptEquivalence.equivalent("sept-huit personnes", "7-8 personnes"))
        #expect(!TranscriptEquivalence.equivalent("sept huit personnes", "15 personnes"))
        #expect(TranscriptEquivalence.equivalent("un deux trois", "1, 2, 3"))
        #expect(SpokenNumbers.spell(["deux", "et", "trois"]) == ["2", "et", "3"])
        #expect(SpokenNumbers.spell(["un", "deux", "trois"]) == ["1", "2", "3"])
        // Les nombres composés restent entiers.
        #expect(SpokenNumbers.spell(["vingt", "et", "un", "et", "deux"]) == ["21", "et", "2"])
        #expect(SpokenNumbers.spell(["soixante", "dix", "sept"]) == ["77"])
        #expect(SpokenNumbers.spell(["cent", "deux"]) == ["102"])
    }

    @Test func sameCountWithAUnitMatchesEitherSpelling() {
        #expect(TranscriptEquivalence.equivalent("8 gigas", "huit gigas"))
        #expect(TranscriptEquivalence.equivalent("Huit Gigas.", "8 gigas"))
    }

    @Test func differentCountsStayDifferentEvenWithAUnit() {
        #expect(!TranscriptEquivalence.equivalent("16 Go", "six gigas"))
        #expect(!TranscriptEquivalence.equivalent("16 go", "6 gigas"))
    }

    @Test func fillersAccentsAndPunctuationDoNotSplitAMatch() {
        #expect(TranscriptEquivalence.equivalent("Euh, bah il écrit DDR4.", "il ecrit ddr4"))
        #expect(TranscriptEquivalence.equivalent("Hum… ben non.", "non"))
    }

    @Test func unitSpellingsElisionsAndEtCeteraMatch() {
        // Écarts mesurés le 5 octobre entre flux et fichier, sans différence de sens.
        #expect(TranscriptEquivalence.equivalent("2133 méga", "2133 mégahertz"))
        #expect(TranscriptEquivalence.equivalent("2400 MHz", "2400 mégahertz"))
        #expect(TranscriptEquivalence.equivalent("8 Go", "huit gigas"))
        #expect(TranscriptEquivalence.equivalent("j'sais pas quoi faire", "je sais pas quoi faire"))
        #expect(TranscriptEquivalence.equivalent("il faut d'faire ça", "il faut de faire ça"))
        #expect(TranscriptEquivalence.equivalent("des câbles et cetera", "des câbles, etc."))
        // Un vrai écart reste un écart.
        #expect(!TranscriptEquivalence.equivalent("barrettes de DDR4", "barrettes de DDR3"))
        #expect(!TranscriptEquivalence.equivalent("tu verras que j'", "tu verras que j'ai beaucoup de quantités"))
    }

    @Test func fileWaitGrowsWithAudioAndStaysCapped() {
        #expect(TranscriptEquivalence.fileWaitSeconds(audioDuration: 0) == 1.2)
        #expect(abs(TranscriptEquivalence.fileWaitSeconds(audioDuration: 2) - 1.32) < 0.000_001)
        #expect(abs(TranscriptEquivalence.fileWaitSeconds(audioDuration: 10) - 1.8) < 0.000_001)
        #expect(TranscriptEquivalence.fileWaitSeconds(audioDuration: 60) == 4)
        #expect(TranscriptEquivalence.fileWaitSeconds(audioDuration: .nan) == 1.2)
    }
}

struct DivergenceMeasureTests {
    @Test func countsOnlyTheWordsThatReallyDiffer() {
        #expect(TranscriptEquivalence.differingWords("Et si tu commences ?", "Et si je commence.") == 2)
        #expect(TranscriptEquivalence.differingWords("J'ai deux barrettes.", "J'ai 2 barrettes") == 0)
        #expect(TranscriptEquivalence.differingWords("Bonjour", "Bonjour à tous") == 2)
        #expect(TranscriptEquivalence.differingWords("", "Bonjour") == 1)
    }
}
