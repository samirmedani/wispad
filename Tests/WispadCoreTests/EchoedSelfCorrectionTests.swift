import Testing
@testable import WispadCore

struct EchoedSelfCorrectionTests {
    @Test(arguments: [
        ("Achète treize rondelles, non, dix-neuf rondelles pour le montage.", "Achète 19 rondelles pour le montage."),
        ("Prépare quatre vis, non, six vis pour la fixation.", "Prépare 6 vis pour la fixation."),
        ("Bring fourteen cups, sorry, seventeen cups for the table.", "Bring 17 cups for the table."),
    ])
    func theRepeatedNounDoesNotHideTheReplacement(heard: String, written: String) {
        #expect(FidelityGuard.check(transcript: heard, corrected: written) == written)
    }

    @Test(arguments: [
        ("Prépare quatre vis, non, six vis pour la fixation.", "Prépare 4 vis pour la fixation."),
        ("Achète treize rondelles, non, dix-neuf rondelles pour le montage.", "Achète 13 rondelles pour le montage."),
        ("Le panneau indique non trois fois de suite.", "Le panneau indique trois fois de suite."),
        ("Le technicien attend encore trois vis pour le montage.", "Le technicien attend trois vis pour le montage."),
        ("Garde quatre degrés, non, -6 degrés pour l'essai.", "Garde six degrés pour l'essai."),
        ("Garde quatre degrés, non, 0.6 degrés pour l'essai.", "Garde six degrés pour l'essai."),
    ])
    func aCueDoesNotAuthorizeLosingTheActualAnswer(heard: String, written: String) {
        #expect(FidelityGuard.check(transcript: heard, corrected: written) == heard)
    }
}
