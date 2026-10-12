import Foundation

/// Verdict sur des mots corrigés juste après une dictée.
public struct TermJudgement: Equatable, Sendable {
    /// Termes à ajouter au dictionnaire, chacun avec le juge qui l'a retenu.
    public var kept: [LearnedTerm]
    /// Appels effectués (réussis ou non), à compter dans la consommation.
    public var usages: [UsageEvent]

    public init(kept: [LearnedTerm], usages: [UsageEvent] = []) {
        self.kept = kept
        self.usages = usages
    }
}

/// Mot retenu après une correction, et le juge qui l'a retenu.
public struct LearnedTerm: Equatable, Sendable {
    /// Orthographié comme l'utilisateur l'a écrit.
    public var term: String
    public var judge: DictionaryJudge

    public init(term: String, judge: DictionaryJudge) {
        self.term = term
        self.judge = judge
    }
}

/// Demande au modèle de correction si un mot corrigé mérite le dictionnaire : une marque ou un jargon mal entendu,
/// oui ; un mot courant retouché, une faute de frappe ou un changement d'avis, non.
/// Seules la phrase dictée et les paires « écrit → corrigé » lui sont envoyées, jamais le reste du champ.
/// Sans réponse exploitable, rien n'est ajouté.
public enum TermJudge {
    typealias ScoreRequest = @Sendable ([CorrectionLearner.Candidate], String, String) async -> ([Double]?, UsageEvent)

    public static let system = """
    Tu tiens le dictionnaire personnel d'un outil de dictée vocale. Ce dictionnaire aide la reconnaissance vocale à écrire correctement des termes qu'elle écorche : noms de marques, de produits, de logiciels, d'entreprises, de personnes ou de lieux peu courants, sigles, jargon technique, mots rares ou étrangers.
    Juste après une dictée, l'utilisateur a remplacé à la main ce que l'outil avait écrit. Pour chaque correction, décide si le terme corrigé doit entrer dans le dictionnaire.
    Garde un terme seulement si c'est un terme spécifique comme ci-dessus, dont l'orthographe ne se devine pas à l'oreille, et si ce que l'outil avait écrit ressemble à une erreur d'écoute de ce terme.
    Refuse les mots courants du français ou de l'anglais, même avec une majuscule, les prénoms et noms de lieux très courants, les fautes de frappe, l'accord, la conjugaison, la ponctuation, les reformulations, les changements d'avis ou de sens, les nombres et les injures.
    En cas de doute, refuse : un mot inutile dans le dictionnaire gêne les dictées suivantes.
    Réponds uniquement par un objet JSON : {"garder": ["terme", ...]} avec les termes corrigés retenus, écrits exactement comme dans la correction, ou {"garder": []}.
    """

    /// Le jugement tourne en arrière-plan : il peut attendre une connexion lente.
    static let timeoutSeconds = 8.0
    static let excerptLimit = 600

    public static func userText(_ candidates: [CorrectionLearner.Candidate], dictated: String) -> String {
        var lines = ["Phrase dictée : \(excerpt(dictated, around: candidates.first?.heard ?? ""))", "Corrections :"]
        for (index, candidate) in candidates.enumerated() {
            lines.append("\(index + 1). « \(candidate.heard) » → « \(candidate.corrected) »")
        }
        return lines.joined(separator: "\n")
    }

    /// Termes retenus par le modèle, limités aux candidats proposés et écrits comme l'utilisateur.
    public static func parse(_ content: String, candidates: [CorrectionLearner.Candidate]) -> [String] {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start < end,
              let data = String(content[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kept = object["garder"] as? [String] else { return [] }
        let keys = Set(kept.map(CorrectionLearner.key))
        return candidates.map(\.corrected).filter { keys.contains(CorrectionLearner.key($0)) }
    }

    /// Seuils de Jev : au-dessus, le mot est gardé sans autre avis ; en dessous, refusé.
    public static let jevKeep = 0.85
    public static let jevReject = 0.2
    /// Sans second avis (modèle de correction muet), Jev décide seul avec ce seuil plus strict.
    public static let jevAlone = 0.7

    /// Jev tranche les cas nets en 0,3 s ; les cas douteux reçoivent un second avis du modèle de correction.
    /// Sans Jev, le modèle de correction décide seul ; sans réponse exploitable, rien n'est ajouté.
    public static func judge(_ candidates: [CorrectionLearner.Candidate], dictated: String, speech: SpeechRequest) async -> TermJudgement {
        await judge(candidates, dictated: dictated, speech: speech, scoreRequest: {
            await JevJudge.scores($0, dictated: $1, key: $2)
        }, transport: TextCleaner.httpTransport)
    }

    static func judge(_ candidates: [CorrectionLearner.Candidate], dictated: String, speech: SpeechRequest,
                      scoreRequest: @escaping ScoreRequest, transport: @escaping TextCleaner.HTTPTransport) async -> TermJudgement {
        guard !candidates.isEmpty, !Task.isCancelled else { return TermJudgement(kept: []) }
        var usages: [UsageEvent] = []
        var jev: (scores: [Double], judge: DictionaryJudge)?
        if let key = speech.judgeKey, !key.isEmpty {
            let (result, usage) = await scoreRequest(candidates, dictated, key)
            usages.append(usage)
            // Fournisseur et modèle de l'appel qui a noté : TypeSafe annonce le modèle facturé.
            jev = result.map { ($0, DictionaryJudge(kind: .jev, provider: usage.api.provider, model: usage.model)) }
        }
        guard !Task.isCancelled else { return TermJudgement(kept: [], usages: usages) }
        guard let jev else {
            // Un Jev absent n'est pas une panne ; un Jev réellement essayé sans résultat l'est.
            let previousAPI: UsageAPI? = usages.isEmpty ? nil : .typesafeJudge
            let (answer, llmUsages) = await askModel(candidates, dictated: dictated, speech: speech, previousAPI: previousAPI, transport: transport)
            let kept = answer.map { answer in answer.approved.map { LearnedTerm(term: $0, judge: answer.judge) } } ?? []
            return TermJudgement(kept: kept, usages: usages + llmUsages)
        }
        let doubtful = zip(candidates, jev.scores).filter { $0.1 < jevKeep && $0.1 > jevReject }.map(\.0)
        var secondOpinion: ModelAnswer?
        if !doubtful.isEmpty {
            let (answer, llmUsages) = await askModel(doubtful, dictated: dictated, speech: speech, transport: transport)
            usages += llmUsages
            secondOpinion = answer
        }
        return TermJudgement(kept: decide(candidates, scores: jev.scores, jev: jev.judge, secondOpinion: secondOpinion), usages: usages)
    }

    /// Verdict final, avec le juge de chaque terme retenu : Jev quand sa note suffit (nette, ou au-dessus de
    /// `jevAlone` si le modèle de correction n'a pas répondu), le modèle de correction pour un cas douteux qu'il
    /// approuve. `secondOpinion` : sa réponse sur les cas douteux, nil s'il n'a pas répondu.
    static func decide(_ candidates: [CorrectionLearner.Candidate], scores: [Double], jev: DictionaryJudge,
                       secondOpinion: ModelAnswer?) -> [LearnedTerm] {
        zip(candidates, scores).compactMap { candidate, score in
            if score >= jevKeep { return LearnedTerm(term: candidate.corrected, judge: jev) }
            if score <= jevReject { return nil }
            guard let secondOpinion else {
                return score >= jevAlone ? LearnedTerm(term: candidate.corrected, judge: jev) : nil
            }
            let approved = secondOpinion.approved.contains(candidate.corrected) && score >= 0.5
            return approved ? LearnedTerm(term: candidate.corrected, judge: secondOpinion.judge) : nil
        }
    }

    /// Réponse du modèle de correction : termes approuvés, et le fournisseur et le modèle de la route qui a
    /// répondu (le modèle demandé, comme dans Consommation).
    struct ModelAnswer: Equatable, Sendable {
        var approved: [String]
        var judge: DictionaryJudge
    }

    /// Avis du modèle de correction (DeepSeek, puis le relais). nil : aucun modèle n'a répondu.
    static func askModel(_ candidates: [CorrectionLearner.Candidate], dictated: String, speech: SpeechRequest,
                         previousAPI: UsageAPI? = nil, transport: @escaping TextCleaner.HTTPTransport = TextCleaner.httpTransport) async -> (ModelAnswer?, [UsageEvent]) {
        let user = userText(candidates, dictated: dictated)
        let requests = TextCleaner.RequestLog()
        let routes = Array(TextCleaner.routes(speech).prefix(2))
        for (index, route) in routes.enumerated() {
            guard !Task.isCancelled else { break }
            let transition: APIFallback?
            if index == 0, let previousAPI {
                transition = APIFallback(fromAPI: previousAPI, stage: .dictionary, reason: .requestFailed)
            } else {
                transition = TextCleaner.fallback(for: index, routes: routes, speech: speech, stage: .dictionary)
            }
            do {
                let reply = try await TextCleaner.withTimeout(seconds: timeoutSeconds) {
                    try await TextCleaner.send(system: system, user: user, route: route, maxTokens: 80, includeReasoning: true,
                                               transport: transport, requests: requests, fallback: transition)
                }
                let judge = DictionaryJudge(kind: .correctionModel, provider: route.provider, model: route.model)
                return (ModelAnswer(approved: parse(reply.content, candidates: candidates), judge: judge), requests.events)
            } catch {
                if TextCleaner.isCancellation(error) { break }
            }
        }
        return (nil, requests.events)
    }

    /// Extrait de la dictée autour du mot corrigé, pour les longues dictées.
    static func excerpt(_ text: String, around word: String, limit: Int = excerptLimit) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let anchor = word.isEmpty ? nil : trimmed.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        let center = anchor.map { trimmed.distance(from: trimmed.startIndex, to: $0.lowerBound) } ?? 0
        let startOffset = max(0, min(center - limit / 2, trimmed.count - limit))
        let start = trimmed.index(trimmed.startIndex, offsetBy: startOffset)
        let end = trimmed.index(start, offsetBy: limit)
        return (startOffset > 0 ? "…" : "") + trimmed[start..<end] + (end < trimmed.endIndex ? "…" : "")
    }
}
