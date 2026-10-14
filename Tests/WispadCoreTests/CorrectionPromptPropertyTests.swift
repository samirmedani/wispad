import Foundation
import Testing
@testable import WispadCore

/// Filet anti-régression de `CorrectionPrompt` (consigne, message envoyé au modèle, nettoyage de sa réponse) et de
/// `KeytermList`, qui borne le dictionnaire envoyé.
struct CorrectionPromptPropertyTests {
    static let labels = ["Texte corrigé : ", "Voici le texte : ", "Résultat: ", "Transcription corrigée : "]

    /// Phrase de mots ordinaires, sans guillemets, clôtures de code ni préambule.
    static func plainText(_ g: inout SeededGenerator) -> String {
        (0..<g.int(1...12)).map { _ in g.pick(SampleText.frenchWords + SampleText.englishWords) + (g.chance(15) ? g.pick([",", ".", " !", " ?"]) : "") }
            .joined(separator: g.pick([" ", " ", "\n"]))
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Réponse du modèle

    @Test func cleanModelOutputEdgeCases() {
        let fallback = "texte dicté"
        // Rien d'exploitable : la transcription.
        for reply in ["", "   \n ", "\"\"", "« »", "“ ”", "```\n\n```", "~~~\n \n~~~"] {
            #expect(CorrectionPrompt.cleanModelOutput(reply, fallback: fallback) == fallback, "« \(reply) »")
        }
        // Un préambule sans texte après lui reste tel quel, une clôture incomplète aussi.
        #expect(CorrectionPrompt.cleanModelOutput("Texte corrigé :", fallback: fallback) == "Texte corrigé :")
        #expect(CorrectionPrompt.cleanModelOutput("```\nBonjour", fallback: fallback) == "```\nBonjour")
        // Une dictée de code garde ses clôtures.
        #expect(CorrectionPrompt.cleanModelOutput("```\nlet x = 1\n```", fallback: "écris ```let x = 1```") == "```\nlet x = 1\n```")
        // Un seul niveau d'enveloppe est retiré : des guillemets dictés à l'intérieur restent.
        #expect(CorrectionPrompt.cleanModelOutput("\"« ces »\"", fallback: "c e s") == "« ces »")
    }

    /// Le texte rendu n'est jamais blanc tant que la transcription ne l'est pas.
    @Test func cleanedReplyIsNeverBlank() {
        forAll(3_000, seed: 0x434C_4E31, { g in
            (reply: g.chance(30) ? SampleText.unicode(&g) : Self.wrapped(Self.plainText(&g), &g), fallback: Self.plainText(&g))
        }) { sample in
            let output = CorrectionPrompt.cleanModelOutput(sample.reply, fallback: sample.fallback)
            return Self.isBlank(output) ? "« \(sample.reply) » → blanc" : nil
        }
    }

    /// Le nettoyage ne fait que retirer : le texte rendu est la transcription, ou un morceau d'un seul tenant de la
    /// réponse, jamais plus long qu'elle.
    @Test func cleanedReplyIsAPieceOfTheReply() {
        forAll(3_000, seed: 0x434C_4E32, { g in
            (reply: g.chance(30) ? SampleText.unicode(&g) : Self.wrapped(SampleText.sentence(&g, english: g.chance(50)), &g),
             fallback: Self.plainText(&g))
        }) { sample in
            let output = CorrectionPrompt.cleanModelOutput(sample.reply, fallback: sample.fallback)
            if output == sample.fallback { return nil }
            return sample.reply.range(of: output, options: .literal) != nil ? nil : "« \(sample.reply) » → « \(output) »"
        }
    }

    /// Une réponse sans enveloppe ressort telle quelle, aux blancs du bord près ; une enveloppe (guillemets, clôture de
    /// code, préambule) est retirée une fois, sans toucher au texte.
    @Test func onlyTheWrapperIsRemoved() {
        forAll(3_000, seed: 0x434C_4E33, { g in
            (text: Self.plainText(&g), wrapper: g.int(0...8), margin: g.pick(["", " ", "\n", " \n "]))
        }) { sample in
            let text = sample.text
            let plain = CorrectionPrompt.cleanModelOutput(sample.margin + text + sample.margin, fallback: "x")
            guard plain == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return "« \(text) » → « \(plain) »" }
            let reply: String
            switch sample.wrapper {
            case 0: reply = "\"" + text + "\""
            case 1: reply = "“" + text + "”"
            case 2: reply = "« " + text + " »"
            case 3: reply = "«" + text + "»"
            case 4: reply = "```\n" + text + "\n```"
            case 5: reply = "```text\n" + text + "\n```"
            case 6: reply = "~~~\n" + text + "\n~~~"
            default: reply = Self.labels[sample.wrapper - 7] + text
            }
            let output = CorrectionPrompt.cleanModelOutput(sample.margin + reply + sample.margin, fallback: "x")
            return output == text.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : "« \(reply) » → « \(output) »"
        }
    }

    static func wrapped(_ text: String, _ g: inout SeededGenerator) -> String {
        var reply = text
        for _ in 0..<g.int(0...3) {
            reply = g.pick(["\"", "“", "«", "```\n", "```text\n", "Texte corrigé : ", " ", "\n", "~~~\n"]) + reply
                + g.pick(["\"", "”", "»", "\n```", "\n~~~", " ", "\n", ""])
        }
        return reply
    }

    // MARK: Message envoyé au modèle

    /// Taille de la ligne d'un champ, son libellé compris, pour un contenu d'un caractère, dans la plus longue des deux
    /// langues de la consigne.
    private static func overhead(_ configure: (inout CorrectionRequest) -> Void) -> Int {
        [DictationLanguage.french, .english].map { language in
            var request = CorrectionRequest(transcript: "", language: language)
            configure(&request)
            return CorrectionPrompt.userText(request).count - CorrectionPrompt.userText(CorrectionRequest(transcript: "", language: language)).count - 1
        }.max() ?? 0
    }

    /// Longueur bornée : sélection, texte voisin, conversation visible et dictionnaire sont coupés, aussi longs
    /// soient-ils ; seuls la transcription, l'autre écoute et les dictées précédentes (déjà bornées par
    /// `RecentDictationContext`) passent en entier. La transcription finit toujours le message, intacte.
    @Test func userTextIsBoundedAndEndsWithTheTranscript() {
        let base = [DictationLanguage.french, .english].map { CorrectionPrompt.userText(CorrectionRequest(transcript: "", language: $0)).count }.max() ?? 0
        let selection = Self.overhead { $0.selectedText = "x" } + 300
        let nearby = Self.overhead { $0.nearbyText = "x" } + 500
        let window = Self.overhead { $0.windowText = "x" } + 2_000
        let dictionary = Self.overhead { $0.dictionary = ["x"] } + 80 * (50 + 2)
        let labels = Self.overhead { $0.appName = "x" } + Self.overhead { $0.alternativeTranscript = "x" } + Self.overhead { $0.previousDictations = ["x"] }
        let bound = base + selection + nearby + window + dictionary + labels
        forAll(300, seed: 0x5553_5231, { g in
            let huge = String(repeating: SampleText.sentence(&g, english: false) + "\n", count: g.int(1...300))
            var request = CorrectionRequest(
                transcript: SampleText.sentence(&g, english: false) + (g.chance(30) ? "\n" + SampleText.unicode(&g) : ""),
                dictionary: (0..<g.int(0...400)).map { "terme\($0) " + String(repeating: "x", count: $0 % 90) },
                appName: g.chance(50) ? "Notes" : nil,
                selectedText: g.chance(70) ? huge : nil,
                nearbyText: g.chance(70) ? huge : nil,
                previousDictations: g.chance(50) ? [SampleText.sentence(&g, english: false)] : [],
                windowText: g.chance(70) ? huge : nil,
                alternativeTranscript: g.chance(30) ? SampleText.sentence(&g, english: false) : nil,
                language: g.pick([.french, .english, .auto])
            )
            request.tone = g.pick(DictationTone.allCases)
            return request
        }) { request in
            let text = CorrectionPrompt.userText(request)
            guard text.hasSuffix("Transcription: " + request.transcript) else { return "la transcription ne finit pas le message" }
            let free = request.transcript.count + (request.alternativeTranscript?.count ?? 0) + (request.appName?.count ?? 0)
                + request.previousDictations.reduce(0) { $0 + $1.count + 3 }
            return text.count <= bound + free ? nil : "\(text.count) caractères pour une borne de \(bound + free)"
        }
    }

    /// Le dictionnaire envoyé : 80 termes au plus, de 50 caractères au plus, sans balise ni retour à la ligne, sans
    /// doublon à la casse près, dans l'ordre d'origine.
    @Test func keytermsAreBoundedCleanAndUnique() {
        forAll(500, seed: 0x4B45_5931, { g in
            (0..<g.int(0...200)).map { _ in
                g.chance(30) ? SampleText.unicode(&g, length: 0...70) : g.pick(SampleText.frenchWords + SampleText.englishWords + ["<b>", "a\nb", "  OAuth  ", "OAUTH"])
            }
        }) { terms in
            let kept = KeytermList.sanitize(terms, limit: 80, maxCharacters: 50)
            if kept.count > 80 { return "\(kept.count) termes" }
            if let bad = kept.first(where: { $0.count > 50 || $0.contains("<") || $0.contains(">") || $0.contains("\n") || $0.contains("\r") || $0.isEmpty }) {
                return "terme « \(bad) »"
            }
            // Ni retour à la ligne caché derrière un accent combinant, ni caractère de contrôle.
            if let bad = kept.first(where: { $0.unicodeScalars.contains { $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0) } }) {
                return "caractère de contrôle dans « \(bad.debugDescription) »"
            }
            if Set(kept.map { $0.lowercased() }).count != kept.count { return "doublon dans \(kept)" }
            return nil
        }
    }

    // MARK: Consigne

    /// Chaque réglage de Mise en forme et de ton donne une consigne qui porte ses exemples, dans sa langue.
    @Test func everySettingShapesTheSystemPrompt() {
        // Chaque format de date une fois, avec un format de nombres, un ton et une langue tirés au hasard.
        var next = 0
        forAll(DateTimeWriterPropertyTests.formats.count, seed: 0x5359_5331, { g -> CorrectionRequest in
            var request = CorrectionRequest(transcript: g.pick(["on se voit demain", "see you tomorrow", "ok"]),
                                            structureDictation: g.chance(50), language: g.pick(DictationLanguage.allCases))
            request.dateFormat = DateTimeWriterPropertyTests.formats[next]
            next += 1
            request.numberFormat = g.pick(NumberWriterPropertyTests.formats)
            request.tone = g.pick(DictationTone.allCases)
            return request
        }) { request in
            let english = CorrectionPrompt.language(for: request) == .english
            let system = CorrectionPrompt.system(for: request)
            guard system.hasPrefix(english ? CorrectionPrompt.englishSystem : CorrectionPrompt.system) else { return "début de la consigne" }
            guard system.contains(request.dateFormat.instructions(english: english)) else { return "dates absentes : \(request.dateFormat)" }
            guard system.contains(request.numberFormat.instructions(english: english)) else { return "nombres absents : \(request.numberFormat)" }
            guard system.hasSuffix(request.tone.instructions(english: english)) else { return "ton absent : \(request.tone)" }
            return CorrectionPrompt.system(for: request) == system ? nil : "consigne instable"
        }
    }
}
