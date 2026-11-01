import Foundation
import Testing
@testable import WispadCore

/// Ton selon le site et registre de la personne (exemples fictifs).
struct ToneAndRegisterTests {
    private func kind(_ title: String?, app: String = "Google Chrome", bundle: String = "com.google.Chrome") -> UsageKind {
        UsageClassifier.classify(bundleIdentifier: bundle, appName: app, windowTitle: title)
    }

    @Test func theBrowserTitleGivesTheSite() {
        #expect(kind("Accueil / X") == .social)
        #expect(kind("Paul sur X : « On teste la bêta ce soir » / X") == .social)
        #expect(kind("(3) Notifications / X - Google Chrome - Perso") == .social)
        #expect(kind("Fil d'actualité | LinkedIn") == .social)
        #expect(kind("#général | Serveur fictif - Discord") == .messaging)
        #expect(kind("WhatsApp") == .messaging)
        #expect(kind("Boîte de réception (3) - Gmail") == .email)
        #expect(kind("Recette de la pâte à pizza") == .browser)
        #expect(kind("Signal processing basics") == .browser)
        #expect(kind(nil) == .browser)
        // Hors navigateur, le titre ne change rien : l'app décide.
        #expect(kind("Accueil / X", app: "Notes", bundle: "com.apple.Notes") == .notes)
    }

    @Test func eachCategoryHasItsDefaultTone() {
        #expect(DictationTone.defaultTone(for: .social) == .casual)
        #expect(DictationTone.defaultTone(for: .messaging) == .casual)
        #expect(DictationTone.defaultTone(for: .email) == .polished)
        #expect(DictationTone.defaultTone(for: .browser) == .natural)
        #expect(DictationTone.defaultTone(for: .development) == .natural)
    }

    @Test func aCasualWordReplacedByAFormalOneComesBack() {
        #expect(FidelityGuard.check(transcript: "c'est grave dommage pour lui", corrected: "C'est vraiment dommage pour lui.")
                == "C'est grave dommage pour lui.")
        #expect(FidelityGuard.check(transcript: "Ouais mais je pense pas que ça marche", corrected: "Oui, mais je pense pas que ça marche.")
                == "Ouais, mais je pense pas que ça marche.")
        // Ton soigné : la correction peut rendre le mot plus soutenu.
        #expect(FidelityGuard.check(transcript: "c'est grave dommage pour lui", corrected: "C'est vraiment dommage pour lui.",
                                    keepRegister: false) == "C'est vraiment dommage pour lui.")
        // Un « oui » dit reste « oui », un autre mot n'est jamais touché.
        #expect(FidelityGuard.check(transcript: "oui je viens demain", corrected: "Oui, je viens demain.") == "Oui, je viens demain.")
    }

    @Test func theCorrectionKeepsTheRegisterAndPunctuatesSparingly() {
        let french = CorrectionPrompt.system(for: CorrectionRequest(transcript: "x"))
        #expect(french.contains("Garde le registre de la personne"))
        #expect(french.contains("jamais de point-virgule"))
        let english = CorrectionPrompt.system(for: CorrectionRequest(transcript: "x", language: .english))
        #expect(english.contains("Keep the speaker's register"))
        #expect(DictationTone.casual.instructions(english: false).contains("« t'as »"))
    }
}
