#if DEBUG
import Foundation
import XCTest
@testable import WispadCore

/// Comparatif de correction seulement : aucune capture audio, aucun collage et aucune transcription personnelle.
/// Même fichier sur les deux versions, ordre ABBA, une passe par processus :
/// WISPAD_WRITTEN_BENCH=1 WISPAD_WRITTEN_VERSION=avant scripts/live-test.sh WrittenFrenchLiveTests
/// Le lanceur peut réserver les quatre passes (0,28 USD pour ce corpus) une fois dans SpendLedger et définir
/// WISPAD_WRITTEN_RESERVED=1. Sinon chaque passe réserve 0,15 USD avant tout appel.
/// Une seule clé dédiée DeepSeek, modèle de l'app, aucun relais ; résultats sans aucun texte dicté ou corrigé.
final class WrittenFrenchLiveTests: XCTestCase {
    private struct Case: Sendable {
        var id: String
        var transcript: String
        var language: DictationLanguage = .french
        var tone: DictationTone = .natural
        /// Toutes ces expressions doivent être présentes : sens et détails qui ne doivent pas disparaître.
        var fidelity: [String]
        var forbidden: [String] = []
        /// Conventions écrites attendues, distinctes de la fidélité au contenu.
        var quality: [String]
        var oralResidues: [String] = []

        func evaluate(_ text: String) -> (faithful: Bool, polished: Bool) {
            let normalized = text.replacingOccurrences(of: "’", with: "'")
            let contains = { (pattern: String) in
                normalized.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            return (fidelity.allSatisfy(contains) && !forbidden.contains(where: contains),
                    quality.allSatisfy(contains) && !oralResidues.contains(where: contains))
        }
    }

    // Phrases fictives fixées avant le comparatif. Les variantes acceptées portent sur l'orthotypographie,
    // pas sur une perte de nuance, une traduction, une négation inversée ou un détail ajouté.
    private static let cases: [Case] = [
        Case(id: "fr-negations-multiples", transcript: "La lampe chauffe pas et le voyant clignote jamais.",
             fidelity: [#"lampe.*chauffe pas"#, #"voyant.*clignote jamais"#],
             quality: [#"lampe ne chauffe pas"#, #"voyant ne clignote jamais"#]),
        Case(id: "fr-clitiques", transcript: "Je lui en prête pas.",
             fidelity: [#"lui en prête pas"#], quality: [#"je ne lui en prête pas"#]),
        Case(id: "fr-elision-negative", transcript: "On en a pas besoin.",
             fidelity: [#"en a pas besoin"#], quality: [#"on n'en a pas besoin"#]),
        Case(id: "fr-impersonnel-court", transcript: "Faut patienter.",
             fidelity: [#"faut patienter"#], forbidden: [#"\b(?:pas|plus|jamais)\b"#],
             quality: [#"^il faut patienter[.!]?$"#]),
        Case(id: "fr-impersonnel-negatif", transcript: "Faut pas insister.",
             fidelity: [#"faut pas insister"#], quality: [#"^il ne faut pas insister[.!]?$"#]),
        Case(id: "fr-existentiel", transcript: "Y a un escargot sous le pot.",
             fidelity: [#"un escargot sous le pot"#], quality: [#"^il y a un escargot"#]),
        Case(id: "fr-existentiel-negatif", transcript: "Y a pas de lumière dans la cave.",
             fidelity: [#"a pas de lumière dans la cave"#], quality: [#"^il n'y a pas de lumière"#]),
        Case(id: "fr-contractions-soignees", transcript: "T'as froid et t'es fatigué.", tone: .polished,
             fidelity: [#"(?:t'|tu )as froid"#, #"(?:t'|tu )es fatigué"#],
             quality: [#"tu as froid"#, #"tu es fatigué"#]),
        Case(id: "fr-impersonnel-passe", transcript: "Fallait prévenir.",
             fidelity: [#"fallait prévenir"#], quality: [#"^il fallait prévenir[.!]?$"#]),
        Case(id: "fr-incertitude", transcript: "La fuite vient peut-être du joint, mais c'est pas confirmé.",
             fidelity: [#"fuite vient peut[- ]être du joint"#, #"pas confirmé"#],
             quality: [#"(?:ce|c') n'est pas confirmé"#]),
        Case(id: "fr-conditionnel", transcript: "La serrure pourrait être gelée, je peux pas le vérifier.",
             fidelity: [#"serrure pourrait être gelée"#, #"peux pas le vérifier"#],
             quality: [#"je ne peux pas le vérifier"#]),
        Case(id: "fr-sujet-non-invente", transcript: "Faut voir si elle revient.",
             fidelity: [#"voir si elle revient"#], quality: [#"^il faut voir"#]),
        Case(id: "fr-hesitations", transcript: "Euh la la barrière est ouverte, euh, on peut passer.",
             fidelity: [#"barrière est ouverte"#, #"on peut passer"#],
             quality: [#"^la barrière"#], oralResidues: [#"\beuh\b"#, #"\bla la\b"#]),
        Case(id: "fr-reprise-heure", transcript: "Le colis part lundi, pardon, mercredi à seize heures.",
             fidelity: [#"colis part mercredi"#, #"(?:16\s?h(?:\s?00)?|seize heures)"#],
             forbidden: [#"\blundi\b"#, #"\bpardon\b"#], quality: [#"16\s?h(?:\s?00)?"#]),
        Case(id: "fr-quantites", transcript: "Il manque dix-huit boulons et le poids a baissé de douze pour cent.",
             fidelity: [#"(?:18|dix-huit) boulons"#, #"poids a baissé de (?:12\s?%|douze pour cent)"#],
             quality: [#"18 boulons"#, #"12\s?%"#]),
        Case(id: "fr-technique", transcript: "J'ai push le patch mais le build passe pas.",
             fidelity: [#"j'ai push le patch"#, #"le build.*passe pas"#],
             forbidden: [#"\b(?:poussé|construction|correctif)\b"#], quality: [#"build ne passe pas"#]),
        Case(id: "fr-plus-positif", transcript: "Le jardin reçoit plus de soleil depuis la taille du chêne.",
             fidelity: [#"jardin reçoit plus de soleil"#, #"depuis la taille du chêne"#],
             forbidden: [#"\bne\b"#, #"n'"#], quality: [#"^le jardin reçoit plus de soleil"#]),
        Case(id: "fr-citation-exacte", transcript: "L'étiquette porte exactement les mots « touche pas ».",
             fidelity: [#"exactement les mots.*touche pas"#], forbidden: [#"ne touche"#],
             quality: [#"«\s?touche pas\s?»"#]),
        Case(id: "fr-nuances", transcript: "La première clé ouvre seulement le portail, pas la remise.",
             fidelity: [#"première clé"#, #"ouvre seulement le portail"#, #"pas la remise"#],
             quality: [#"portail, pas la remise"#]),
        Case(id: "fr-casual-negation", transcript: "Je trouve pas mes gants.", tone: .casual,
             fidelity: [#"trouve pas mes gants"#], forbidden: [#"\bne\b"#],
             quality: [#"^je trouve pas mes gants$"#]),
        Case(id: "fr-casual-contraction", transcript: "T'as pris ton manteau ?", tone: .casual,
             fidelity: [#"t'as pris ton manteau"#], quality: [#"^t'as pris ton manteau\s?\?$"#]),
        Case(id: "en-negation", transcript: "The heater isn't broken but I can't restart it.", language: .english,
             fidelity: [#"heater (?:isn't|is not) broken"#, #"I (?:can't|cannot) restart it"#],
             quality: [#"^the heater"#, #"restart it\.$"#]),
        Case(id: "en-uncertainty", transcript: "The parcel might arrive tomorrow but the date isn't confirmed.", language: .english,
             fidelity: [#"parcel might arrive tomorrow"#, #"date (?:isn't|is not) confirmed"#],
             quality: [#"^the parcel"#, #"confirmed\.$"#]),
        Case(id: "en-self-repair", transcript: "Leave the box upstairs, no wait, downstairs by the stairs.", language: .english,
             fidelity: [#"leave the box downstairs"#, #"by the stairs"#], forbidden: [#"\bupstairs\b"#, #"no wait"#],
             quality: [#"^leave the box"#, #"stairs\.$"#]),
        Case(id: "fr-accords-homophones", transcript: "Les volets son fermé et la fenêtre à été réparer.",
             fidelity: [#"volets sont fermés"#, #"fenêtre a été réparée"#],
             quality: [#"^les volets sont fermés"#, #"la fenêtre a été réparée\.$"#]),
        Case(id: "fr-ecoute-courante", transcript: "Le marin a levé l'encre avant de quitter le port.",
             fidelity: [#"marin a levé l'ancre"#, #"avant de quitter le port"#],
             forbidden: [#"\bencre\b"#], quality: [#"^le marin a levé l'ancre"#]),
        Case(id: "fr-technique-phonetique", transcript: "Le modèle attend un data sette nettoyé avant l'entraînement.",
             fidelity: [#"modèle attend un data[- ]?set nettoyé"#, #"avant l'entraînement"#],
             forbidden: [#"jeu de données"#, #"data sette"#], quality: [#"\bdata[- ]?set\b"#]),
        Case(id: "fr-reprise-nombre", transcript: "Commande quatorze ampoules, non, dix-sept ampoules pour le couloir.",
             fidelity: [#"commande (?:17|dix-sept) ampoules"#, #"pour le couloir"#],
             forbidden: [#"\b(?:14|quatorze|non)\b"#], quality: [#"commande 17 ampoules"#]),
        Case(id: "fr-paroles-rapportees", transcript: "Le gardien m'a répondu revenez après la pluie.",
             fidelity: [#"gardien m'a répondu"#, #"revenez après la pluie"#],
             quality: [#"répondu\s?:\s?«\s?revenez après la pluie[.!]?\s?»"#]),
        Case(id: "fr-epellation", transcript: "Sur le badge le mot est épelé L U N E.",
             fidelity: [#"sur le badge"#, #"mot est épelé"#, #"(?:l[\s-]*u[\s-]*n[\s-]*e|lune)"#],
             quality: [#"(?:L-U-N-E|«\s?lune\s?»)"#]),
        Case(id: "fr-nombre-homophone", transcript: "Elle s'occupe deux la serre pendant les vacances.",
             fidelity: [#"elle s'occupe de la serre"#, #"pendant les vacances"#],
             forbidden: [#"\b(?:2|deux)\b"#], quality: [#"^elle s'occupe de la serre"#]),
        Case(id: "fr-ordre-dicte", transcript: "Ajoute une chaise près de la porte et ferme doucement le volet.",
             fidelity: [#"ajoute une chaise près de la porte"#, #"ferme doucement le volet"#],
             quality: [#"^ajoute une chaise près de la porte et ferme doucement le volet\.$"#]),
    ]

    private actor Observation {
        var calls = 0
        var raw: String?
        var networkMs = 0.0

        func begin() -> Bool {
            guard calls == 0 else { return false }
            calls += 1
            return true
        }

        func received(_ data: Data, elapsed: Double) {
            networkMs += elapsed
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { return }
            raw = content
        }

        func snapshot() -> (calls: Int, raw: String?, networkMs: Double) { (calls, raw, networkMs) }
    }

    private enum ProbeError: Error { case unexpectedRoute }

    func testWrittenQualityAndFidelity() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1" && env["WISPAD_WRITTEN_BENCH"] == "1",
                          "Comparatif réseau explicitement désactivé.")
        let key = env["WISPAD_LIVE_DEEPSEEK_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Clé de test dédiée DeepSeek absente.")
        let version = String((env["WISPAD_WRITTEN_VERSION"] ?? "candidate").filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))
        }.prefix(40))
        if env["WISPAD_WRITTEN_RESERVED"] != "1" { try SpendLedger.wispadDefault().reserve(0.15) }
        var passedFidelity = 0, passedQuality = 0, completed = 0, calls = 0
        var totalTokens = TokenUsage()
        var costUSD = 0.0, unknownCosts = 0
        var elapsedTimes: [Double] = []

        for item in Self.cases {
            let observation = Observation()
            let transport: TextCleaner.HTTPTransport = { request in
                guard request.url?.host == TextCleaner.deepSeekURL.host,
                      let body = request.httpBody,
                      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      object["model"] as? String == CleanupModel.deepSeek else { throw ProbeError.unexpectedRoute }
                guard await observation.begin() else { throw ProbeError.unexpectedRoute }
                let started = ContinuousClock.now
                let result = try await TextCleaner.httpTransport(request)
                await observation.received(result.0, elapsed: Self.milliseconds(started.duration(to: .now)))
                return result
            }
            let speech = SpeechRequest(provider: .xai, liveModel: "", fileModel: "", apiKey: "",
                                       language: item.language, keyterms: [], prompt: "", cleanupKey: key,
                                       cleanupRelay: .off)
            var request = CorrectionRequest(transcript: item.transcript, language: item.language)
            request.tone = item.tone
            let started = ContinuousClock.now
            let outcome = await TextCleaner.clean(transcript: item.transcript, request: request,
                                                  speech: speech, enabled: true, transport: transport)
            let elapsed = Self.milliseconds(started.duration(to: .now))
            let captured = await observation.snapshot()
            let raw = captured.raw.map { CorrectionPrompt.cleanModelOutput($0, fallback: "") } ?? ""
            let rawScore = item.evaluate(raw), score = item.evaluate(outcome.text)
            let succeeded = outcome.usage?.succeeded == true
            if succeeded { completed += 1 }
            if score.faithful { passedFidelity += 1 }
            if score.polished { passedQuality += 1 }
            calls += captured.calls
            elapsedTimes.append(elapsed)
            let usages = outcome.failedUsages + [outcome.usage].compactMap { $0 }
            let tokens = usages.reduce(TokenUsage()) { $0.adding($1.tokens) }
            totalTokens = totalTokens.adding(tokens)
            let knownCost = usages.compactMap(\.costUSD).reduce(0, +)
            let missing = usages.filter { $0.costUSD == nil }.count
            costUSD += knownCost
            unknownCosts += missing
            try Self.emit([
                "kind": "case", "version": version, "id": item.id, "succeeded": succeeded,
                "rawFidelity": rawScore.faithful, "rawQuality": rawScore.polished,
                "fidelity": score.faithful, "quality": score.polished,
                "returnedOriginal": outcome.text == item.transcript,
                "calls": captured.calls, "totalMs": elapsed, "networkMs": captured.networkMs,
                "inputTokens": tokens.input, "cachedInputTokens": tokens.cachedInput, "outputTokens": tokens.output,
                "estimatedCostUSD": knownCost, "unknownCosts": missing
            ])
            // Un problème réseau interrompt la passe : aucune relance masquée ne fausse coûts et latences.
            XCTAssertTrue(succeeded, "Réponse fournisseur absente pour \(item.id) ; passe interrompue.")
            if !succeeded { return }
        }
        let ordered = elapsedTimes.sorted()
        try Self.emit([
            "kind": "summary", "version": version, "cases": Self.cases.count, "completed": completed,
            "fidelity": passedFidelity, "quality": passedQuality, "calls": calls,
            "medianMs": ordered[ordered.count / 2], "p95Ms": ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1],
            "inputTokens": totalTokens.input, "cachedInputTokens": totalTokens.cachedInput,
            "outputTokens": totalTokens.output, "estimatedCostUSD": costUSD, "unknownCosts": unknownCosts
        ])
        // La qualité est comparée entre les versions par le lanceur ; pas de seuil qui masque les cas en échec.
        XCTAssertEqual(completed, Self.cases.count)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print("WRITTEN_BENCH " + String(decoding: data, as: UTF8.self))
    }
}
#endif
