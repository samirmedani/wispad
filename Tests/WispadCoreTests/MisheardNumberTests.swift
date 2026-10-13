import Testing
@testable import WispadCore

/// Nombres mal entendus : un mot qui sonne comme un nombre (« deux mois » pour « de moi ») n'est pas figé en chiffres,
/// la consigne le corrige comme un mot mal entendu et le garde-fou accepte la correction. Phrases inventées, sans réseau.
/// Le banc réseau correspondant : cas n de `scripts/franglais-bench.sh`.
struct MisheardNumberTests {
    @Test func promptChecksANumberBeforeWritingItAsDigits() {
        let french = CorrectionPrompt.system
        #expect(french.contains("Tout nombre qui compte, mesure, date ou chiffre vraiment quelque chose s'écrit en chiffres"))
        #expect(french.contains("Un mot qui sonne comme un nombre n'en est pas toujours un : voir les nombres mal entendus plus bas."))
        #expect(french.contains("Un nombre peut lui aussi être un mot mal entendu : avant de l'écrire en chiffres, vérifie qu'il compte vraiment quelque chose dans la phrase et la conversation visible."))
        #expect(french.contains("« deux » / « de », « deux mois » / « de moi », « cent » / « sans » / « s'en », « six » / « si », « sept » / « cette », « vingt » / « vin » / « vint », « mille » / « mil », « un » / « hein »"))
        #expect(french.contains("« Franchement, ils veulent quoi, deux mois ? » → « Franchement, ils veulent quoi de moi ? »"))
        #expect(french.contains("Mais « Le chantier dure deux mois » → « Le chantier dure 2 mois. »"))
        #expect(french.contains("Dans le doute entre un nombre et un autre mot, garde le mot en lettres, jamais le chiffre."))
        // La règle des unités reste : « c'est gigas » ne devient 16 gigas qu'avec une confirmation.
        #expect(french.contains("Sans cette confirmation, garde le mot transcrit"))
        let english = CorrectionPrompt.englishSystem
        #expect(english.contains("A number can be a misheard word too: before writing it as digits, check that it really counts something"))
        #expect(english.contains("\"two\" / \"to\" / \"too\", \"four\" / \"for\", \"eight\" / \"ate\", \"one\" / \"won\""))
        #expect(english.contains("\"I want two go home\" → \"I want to go home.\""))
        #expect(english.contains("When in doubt between a number and another word, keep the word in letters, never the digit."))
    }

    @Test(arguments: [
        // La dictée réelle inspirée de ce cas, réécrite : la transcription brute, en lettres ou en chiffres.
        ("Franchement, ils veulent quoi, deux mois ?", "Franchement, ils veulent quoi de moi ?"),
        ("Franchement, ils veulent quoi, 2 mois ?", "Franchement, ils veulent quoi de moi ?"),
        ("deux mois ?", "De moi ?"),
        ("2 mois ?", "De moi ?"),
        ("Il est parti cent rien dire.", "Il est parti sans rien dire."),
        ("Il cent va demain.", "Il s'en va demain."),
        ("six tu veux", "Si tu veux."),
        ("sept semaine", "Cette semaine."),
        ("Un verre de vingt.", "Un verre de vin."),
        ("l'an mille", "L'an mil."),
        ("C'est bon, un ?", "C'est bon, hein ?"),
    ])
    func soundAlikeWordReplacesTheNumber(transcript: String, corrected: String) {
        #expect(FidelityGuard.check(transcript: transcript, corrected: corrected) == corrected)
    }

    @Test func aRealCountStaysInDigits() {
        #expect(FidelityGuard.check(transcript: "Le chantier dure deux mois.", corrected: "Le chantier dure 2 mois.") == "Le chantier dure 2 mois.")
        // Ni écrit ni dit pareil : une invention, la transcription reste.
        #expect(FidelityGuard.check(transcript: "sept", corrected: "Huit.") == "sept")
    }

    @Test func phoneticKeyHearsNumberHomophones() {
        #expect(PhoneticKey.soundsAlike(["de", "moi"], ["deux", "mois"]))
        #expect(PhoneticKey.soundsAlike(["sans"], ["cent"]))
        #expect(PhoneticKey.soundsAlike(["s'en"], ["cent"]))
        #expect(PhoneticKey.soundsAlike(["si"], ["six"]))
        #expect(PhoneticKey.soundsAlike(["cette"], ["sept"]))
        #expect(PhoneticKey.soundsAlike(["vin"], ["vingt"]))
        #expect(PhoneticKey.soundsAlike(["vint"], ["vingt"]))
        #expect(PhoneticKey.soundsAlike(["mil"], ["mille"]))
        #expect(PhoneticKey.soundsAlike(["hein"], ["un"]))
        #expect(PhoneticKey.key(["doigt"]) == PhoneticKey.key(["doit"]))
        #expect(PhoneticKey.key(["ville"]) == PhoneticKey.key(["vil"]))
        // « septembre » garde son p, « fille » son son « ij ».
        #expect(!PhoneticKey.soundsAlike(["septembre"], ["cette"]))
        #expect(PhoneticKey.key(["fille"]) != PhoneticKey.key(["fil"]))
        #expect(!PhoneticKey.soundsAlike(["huit"], ["sept"]))
    }
}
