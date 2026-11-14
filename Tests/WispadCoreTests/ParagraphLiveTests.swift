import Foundation
import XCTest
@testable import WispadCore

/// Paragraphes posés par la vraie correction : une dictée longue à plusieurs idées est découpée aux endroits où un
/// lecteur attend un retour à la ligne, une dictée courte reste d'un bloc, aucun mot ne change. Réseau et payant
/// (quelques centimes) : seulement via `scripts/live-test.sh ParagraphLiveTests`, avec les clés de test du coffre.
final class ParagraphLiveTests: XCTestCase {
    private struct Case: Sendable {
        var id: String
        var language: DictationLanguage
        var transcript: String
        /// Vrai : au moins deux paragraphes attendus ; faux : un seul bloc.
        var split: Bool
        /// Mots qui doivent rester (insensible à la casse et aux accents).
        var keep: [String]
    }

    private static let cases: [Case] = [
        Case(id: "fr-boulangerie", language: .french,
             transcript: "Hier soir vers 23h30, un homme entre dans une boulangerie encore ouverte et demande trois croissants, deux cafés et un gâteau à 12,50 €. La vendeuse lui répond : « Monsieur, vous savez qu'on ferme dans cinq minutes ? » Il regarde sa montre, hésite quelques secondes, puis s'exclame : « Attendez, on est déjà vendredi ?! » Le plus drôle dans cette histoire, c'est qu'il était persuadé d'être mercredi. Et devinez quoi ? Il s'était même trompé de boulangerie !",
             split: true, keep: ["boulangerie", "vendeuse", "vendredi", "mercredi"]),
        Case(id: "fr-mail-projet", language: .french,
             transcript: "Bonjour Thomas, j'espère que tu vas bien. Je te fais un point rapide sur le projet. On a terminé la nouvelle page d'accueil et les tests sont tous passés hier soir. Côté budget, on reste dans l'enveloppe prévue, avec environ 2 000 € de marge. Par contre, le prestataire pour l'hébergement ne répond plus depuis lundi, donc je pense qu'il faudrait regarder une autre solution. Est-ce que tu peux me dire d'ici jeudi si tu préfères qu'on attende ou qu'on change ? Bonne journée.",
             split: true, keep: ["thomas", "budget", "hebergement", "jeudi"]),
        Case(id: "fr-message-ami", language: .french,
             transcript: "Salut, merci encore pour hier soir, c'était vraiment une super soirée et le repas était incroyable. Sinon, pour le week-end prochain, je pensais qu'on pourrait partir à Lyon samedi matin et rentrer dimanche soir. J'ai regardé les trains, il y en a un à 8h12 qui arrive vers 10h. Au fait, tu as pensé à rappeler ta sœur pour son anniversaire ? Elle m'en a parlé deux fois cette semaine.",
             split: true, keep: ["lyon", "trains", "anniversaire"]),
        Case(id: "en-email", language: .english,
             transcript: "Hi Sarah, thanks for sending the draft so quickly. I went through the whole document this morning and overall it reads really well. The introduction is clear and the numbers in the second section match what we discussed. I do think the conclusion is a bit short, so it might be worth adding a paragraph about next steps and the timeline. Also, could you send me the final version by Friday so I can share it with the board on Monday? Thanks again.",
             split: true, keep: ["sarah", "conclusion", "friday", "board"]),
        Case(id: "fr-court", language: .french, transcript: "On se voit demain à 14h, je t'apporte les documents.", split: false, keep: ["demain", "documents"]),
        Case(id: "fr-deux-phrases", language: .french,
             transcript: "Le build est passé sur la branche principale. Tu peux lancer le déploiement quand tu veux.", split: false, keep: ["build", "deploiement"]),
        Case(id: "fr-meme-idee", language: .french,
             transcript: "Le bug vient du cache qui garde l'ancienne version de la page. Quand on vide le cache, tout revient dans l'ordre. Je pense qu'il faut juste baisser sa durée à cinq minutes.",
             split: false, keep: ["cache", "minutes"]),
        Case(id: "en-short", language: .english, transcript: "Running five minutes late, start without me.", split: false, keep: ["late", "without"]),
    ]

    func testParagraphsWhereAReaderExpectsThem() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1", "Test réseau réservé à scripts/live-test.sh.")
        let deepSeek = env["WISPAD_LIVE_DEEPSEEK_KEY"] ?? ""
        let xai = env["WISPAD_LIVE_XAI_KEY"] ?? ""
        try XCTSkipUnless(!deepSeek.isEmpty || !xai.isEmpty, "Aucune clé de test de correction.")
        let runs = 2
        // Réservation prudente (0,003 $ l'appel), remplacée à la fin par le coût mesuré de chaque appel.
        let reserved = Double(Self.cases.count * runs) * 0.003
        let ledger = SpendLedger.wispadDefault()
        try ledger.reserve(reserved)
        var actual = 0.0
        let fold = { (text: String) in text.lowercased().folding(options: .diacriticInsensitive, locale: nil) }
        var passed = 0
        var total = 0
        for item in Self.cases {
            let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: xai, language: item.language,
                                       keyterms: [], prompt: "", cleanupKey: deepSeek.isEmpty ? nil : deepSeek)
            let request = CorrectionRequest(transcript: item.transcript, structureDictation: true, language: item.language)
            for run in 1...runs {
                let outcome = await TextCleaner.clean(transcript: item.transcript, request: request, speech: speech, enabled: true)
                actual += outcome.usage?.costUSD ?? 0.003
                let paragraphs = outcome.text.components(separatedBy: "\n\n")
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                let kept = item.keep.allSatisfy { fold(outcome.text).contains($0) }
                let shape = item.split ? paragraphs >= 2 : paragraphs == 1
                let ok = outcome.usage?.succeeded == true && shape && kept
                total += 1
                if ok { passed += 1 }
                let call = outcome.usage?.succeeded == true ? "" : " appel=échec"
                print("PARAGRAPHES \(item.id) passe=\(run) \(ok ? "ok" : "ÉCHEC") blocs=\(paragraphs)\(call) → \(outcome.text.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
        }
        print("PARAGRAPHES total \(passed)/\(total)")
        try ledger.settle(reserved: reserved, actual: actual)
        print("PARAGRAPHES coût \(String(format: "%.4f", actual)) $")
        XCTAssertGreaterThanOrEqual(Double(passed) / Double(total), 0.85, "Paragraphes trop souvent manqués ou ajoutés à tort.")
    }
}
