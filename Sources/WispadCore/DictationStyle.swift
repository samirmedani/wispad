import Foundation

// MARK: - Ton selon l'app

/// Registre demandé à la correction pour une catégorie d'apps. Le naturel produit un écrit fluide, sans changer
/// le vocabulaire ni le sens ; le détendu conserve les tournures orales et le soigné développe les contractions.
public enum DictationTone: String, Codable, CaseIterable, Sendable {
    case natural
    case polished
    case casual

    /// Consigne ajoutée à la correction, dans la langue de la dictée.
    public func instructions(english: Bool) -> String {
        switch (self, english) {
        case (.natural, true):
            return ""
        case (.natural, false):
            return "Français écrit naturel : garde le vocabulaire et la personnalité de la dictée, avec des phrases grammaticales. Rétablis systématiquement le « ne » ou « n' » d'une négation certaine, aussi dans les subordonnées et avec les pronoms compléments (« elle le trouve pas » → « elle ne le trouve pas »). Complète les sujets impersonnels omis (« faut patienter » → « il faut patienter », « y a personne » → « il n'y a personne »). Ces petits mots grammaticaux sont autorisés : ils ne sont pas des informations nouvelles. N'invente aucune négation : « plus », « jamais » et « personne » peuvent avoir un sens positif ou interrogatif ; conserve l'ambiguïté quand le sens n'est pas certain. Garde les mots cités, le code et les adresses tels quels."
        case (.polished, false):
            return DictationTone.natural.instructions(english: false) + "\nTon soigné : développe aussi les contractions familières (« t'as » → « tu as », « t'es » → « tu es »). Ne change ni le vocabulaire ni le sens ; n'ajoute ni formule de politesse ni information."
        case (.casual, false):
            return "Ton détendu, comme un message tapé par la personne elle-même : garde les tournures familières et la négation sans « ne » telles qu'elles ont été dites (« j'pense pas que t'as besoin » reste ainsi, « faut », « y a », « t'as », « t'es » restent), et les petits mots oraux qui donnent le ton quand ils ne sont pas répétés (« bah », « genre », « en vrai », « du coup », « ouais »). Pas de point final pour un message court d'une seule phrase. Ne change ni le vocabulaire ni le sens."
        case (.polished, true):
            return "Polished tone: complete sentences and careful punctuation; write casual forms in standard form (\"gonna\" → \"going to\", \"wanna\" → \"want to\", \"kinda\" → \"kind of\"). These grammatical expansions are allowed. Do not change the vocabulary or the meaning; add no greeting or information."
        case (.casual, true):
            return "Casual tone, like a message the person typed themselves: keep casual forms as they were spoken (\"gonna\", \"wanna\", \"yeah\", \"kinda\") and the small spoken words that set the tone when they are not repeated (\"well\", \"like\", \"honestly\"); no final period for a short single-sentence message. Do not change the vocabulary or the meaning."
        }
    }

    /// Ton d'une catégorie que l'utilisateur n'a pas réglée : détendu pour les réseaux sociaux et les messageries,
    /// soigné pour les e-mails, naturel ailleurs. Le 1er novembre 2026, des réponses sur X dictées au ton naturel
    /// (« ne » rétabli, « t'as » développé, « ouais » devenu « oui ») ont été prises pour des textes d'IA.
    public static func defaultTone(for kind: UsageKind) -> DictationTone {
        switch kind {
        case .social, .messaging: return .casual
        case .email: return .polished
        case .development, .writing, .browser, .notes, .other: return .natural
        }
    }
}

// MARK: - Commande vocale sur une sélection

/// Avec du texte sélectionné, une dictée qui commence par une consigne d'écriture (« reformule plus poliment »,
/// « traduis en anglais », « make it shorter ») transforme la sélection au lieu de la remplacer par la dictée.
public enum SelectionCommand {
    /// Sélection au-delà de laquelle aucune transformation n'est tentée (la réponse serait coupée).
    public static let maxSelectionCharacters = 6_000

    private static let politeness: [[String]] = [
        ["peux", "tu"], ["tu", "peux"], ["pourrais", "tu"], ["tu", "pourrais"], ["est", "ce", "que", "tu", "peux"],
        ["pouvez", "vous"], ["vous", "pouvez"], ["s", "il", "te", "plait"], ["s", "il", "vous", "plait"],
        ["can", "you"], ["could", "you"], ["please"], ["ok"], ["alors"],
    ]

    private static let verbs: Set<String> = [
        "reformule", "reformulez", "reformuler", "reecris", "reecrivez", "reecrire", "traduis", "traduisez", "traduire",
        "resume", "resumez", "resumer", "corrige", "corrigez", "corriger", "raccourcis", "raccourcissez", "raccourcir",
        "simplifie", "simplifiez", "simplifier", "developpe", "developpez", "developper", "ameliore", "ameliorez", "ameliorer",
        "transforme", "transformez", "transformer", "allege", "allegez", "formalise", "formalisez", "adoucis", "adoucissez",
        "rewrite", "rephrase", "translate", "summarize", "summarise", "fix", "shorten", "simplify", "expand", "improve",
        "polish", "condense",
    ]

    /// Verbes qui ne sont une consigne que suivis de leur objet (« rends-le plus court », « make it shorter »).
    private static let objectVerbs: [String: Set<String>] = [
        "rends": ["le", "la", "les", "ca", "ce", "moi", "plus", "un"], "rendez": ["le", "la", "les", "ca", "ce", "plus"],
        "mets": ["le", "la", "les", "ca", "ce", "tout"], "mettez": ["le", "la", "les", "ca", "ce", "tout"],
        "make": ["it", "this", "that", "them"], "turn": ["it", "this", "that", "them"],
    ]

    /// La dictée est une consigne à appliquer à la sélection.
    public static func isCommand(_ transcript: String) -> Bool {
        var words = keys(transcript)
        var stripped = true
        while stripped {
            stripped = false
            for phrase in politeness where words.starts(with: phrase) {
                words.removeFirst(phrase.count)
                stripped = true
            }
        }
        guard let first = words.first else { return false }
        if verbs.contains(first) { return true }
        if let objects = objectVerbs[first], words.count > 1, objects.contains(words[1]) { return true }
        return false
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    /// Mots d'un texte, sans casse, accents ni ponctuation.
    private static func keys(_ text: String) -> [String] {
        let ns = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        }
    }
}

public enum CommandPrompt {
    public static func system(english: Bool) -> String {
        english ? englishSystem : frenchSystem
    }

    public static func userText(command: String, selection: String, english: Bool) -> String {
        english
            ? "Instruction: \(command)\nSelected text:\n\(selection)"
            : "Consigne : \(command)\nTexte sélectionné :\n\(selection)"
    }

    private static let frenchSystem = """
    Tu modifies un texte sélectionné selon une consigne dictée à voix haute. Tu réponds uniquement par le nouveau texte, \
    prêt à remplacer la sélection : sans préambule, sans guillemets, sans commentaire, sans bloc de code.
    Applique la consigne et rien d'autre : garde le sens, les noms, les chiffres, les liens et la mise en forme du texte \
    (retours à la ligne, listes) sauf si la consigne demande de les changer. Garde la langue du texte, sauf pour une traduction.
    Si la consigne ne s'applique pas au texte, rends le texte sélectionné inchangé.
    """

    private static let englishSystem = """
    You edit a selected text according to a spoken instruction. Reply with the new text only, ready to replace the \
    selection: no preamble, no quotes, no comments, no code block.
    Apply the instruction and nothing else: keep the meaning, names, numbers, links and the layout of the text (line \
    breaks, lists) unless the instruction asks to change them. Keep the language of the text, except for a translation.
    If the instruction does not apply to the text, return the selected text unchanged.
    """
}
