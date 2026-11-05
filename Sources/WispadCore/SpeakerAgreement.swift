import Foundation

/// Accord de ce qui se rapporte à la personne qui dicte (« je suis allée » ou « je suis allé ») : l'oreille ne fait pas
/// la différence, la transcription écrit le plus souvent au masculin. Réglage « Quand tu parles de toi ».
public enum SpeakerAgreement: String, Codable, CaseIterable, Sendable {
    /// Comportement d'origine : rien n'est accordé après coup.
    case asHeard
    case feminine
    case masculine

    /// Consigne ajoutée à la correction, en français seulement (l'anglais n'accorde pas ces mots).
    public func instructions(english: Bool) -> String {
        guard !english else { return "" }
        switch self {
        case .asHeard:
            return ""
        case .feminine:
            return """
            La personne qui dicte parle d'elle au féminin. Accorde au féminin les participes passés et les adjectifs qui se rapportent à elle (« je », « me », « moi ») quand le masculin et le féminin se prononcent pareil : « je suis allé » → « je suis allée », « je me suis trompé » → « je me suis trompée », « je suis désolé » → « je suis désolée », « je suis seul » → « je suis seule ». N'accorde jamais un mot qui se rapporte à quelqu'un d'autre (« tu », « il », « elle », « on », « nous », « vous »), ni un participe suivi de son complément (« je me suis lavé les mains » ne change pas). Ne change aucun autre mot.
            """
        case .masculine:
            return """
            La personne qui dicte parle d'elle au masculin. Accorde au masculin les participes passés et les adjectifs qui se rapportent à elle (« je », « me », « moi ») quand le masculin et le féminin se prononcent pareil : « je suis allée » → « je suis allé », « je me suis trompée » → « je me suis trompé », « je suis désolée » → « je suis désolé », « je suis seule » → « je suis seul ». N'accorde jamais un mot qui se rapporte à quelqu'un d'autre (« tu », « il », « elle », « on », « nous », « vous »). Ne change aucun autre mot.
            """
        }
    }
}

/// Filet local, après la correction (ou sans elle) : accorde le mot qui suit « je suis », « je me suis », « j'étais »,
/// « je me sens »… quand ses deux genres se prononcent pareil. Prudent : un mot inconnu, un nom propre, un pluriel
/// ou un participe suivi de son complément d'objet (« je me suis lavé les mains ») restent tels quels.
public enum SpeakerAgreementRule {
    public static func apply(_ text: String, agreement: SpeakerAgreement, language: DictationLanguage) -> String {
        guard agreement != .asHeard, !text.isEmpty else { return text }
        let french = language == .french || (language == .auto && TranscriptLanguage.guess(text) == .french)
        guard french, let pattern else { return text }
        let source = text as NSString
        var result = text
        // De la fin vers le début : les positions des mots déjà lus restent justes.
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let reflexive = match.range(at: 1).location != NSNotFound
            let after = source.substring(from: match.range.location + match.range.length)
            if reflexive, followedByObject(after) { continue }
            for group in [3, 2] {
                let range = match.range(at: group)
                guard range.location != NSNotFound, let swift = Range(range, in: result) else { continue }
                let word = String(result[swift])
                if let agreed = agree(word, to: agreement), agreed != word {
                    result.replaceSubrange(swift, with: agreed)
                }
            }
        }
        return result
    }

    /// Le mot accordé, ou nil s'il n'est pas sûr que ses deux genres se prononcent pareil.
    static func agree(_ word: String, to agreement: SpeakerAgreement) -> String? {
        let lower = word.lowercased()
        guard lower == word else { return nil }
        switch agreement {
        case .asHeard:
            return nil
        case .feminine:
            if let pair = pairs.first(where: { $0.masculine == lower }) { return pair.feminine }
            if pairs.contains(where: { $0.feminine == lower }) { return nil }
            if lower.hasSuffix("é"), !invariable.contains(lower) { return lower + "e" }
            if lower.hasSuffix("el"), !lower.hasSuffix("ell") { return lower + "le" }
            return nil
        case .masculine:
            if let pair = pairs.first(where: { $0.feminine == lower }) { return pair.masculine }
            if pairs.contains(where: { $0.masculine == lower }) { return nil }
            if lower.hasSuffix("ée"), !feminineNouns.contains(lower) { return String(lower.dropLast()) }
            if lower.hasSuffix("elle"), !feminineOnly.contains(lower) { return String(lower.dropLast(2)) }
            return nil
        }
    }

    /// Paires dont les deux genres se prononcent pareil, hors -é / -ée et -el / -elle (traités à part).
    private static let pairs: [(masculine: String, feminine: String)] = {
        var list: [(String, String)] = [("seul", "seule"), ("nul", "nulle"), ("pareil", "pareille"), ("cher", "chère"),
                                        ("fier", "fière"), ("tel", "telle")]
        let withE = ["parti", "sorti", "reparti", "ressorti", "fini", "ravi", "réussi", "endormi", "rendormi", "guéri",
                     "épanoui", "réjoui", "abruti", "aigri", "ahuri", "assoupi", "enrichi", "investi", "servi", "trahi",
                     "choisi", "saisi", "nourri", "grandi", "vieilli", "étourdi", "engourdi", "établi", "accueilli",
                     "perdu", "venu", "revenu", "parvenu", "devenu", "redevenu", "intervenu", "déçu", "convaincu", "vaincu",
                     "battu", "abattu", "tenu", "retenu", "connu", "reconnu", "méconnu", "détendu", "tendu", "attendu",
                     "entendu", "vendu", "rendu", "perçu", "aperçu", "foutu", "têtu", "élu", "réélu", "confondu",
                     "morfondu", "fondu", "pendu", "suspendu", "descendu", "redescendu", "défendu", "répandu", "étendu",
                     "senti", "ressenti", "menti", "dormi", "bouilli"]
        list += withE.map { ($0, $0 + "e") }
        return list
    }()

    /// Mots en -é qui ne s'accordent pas (noms), même juste après « je suis ».
    private static let invariable: Set<String> = ["été", "café", "thé", "clé", "côté", "marché", "blé", "pré", "bébé",
                                                  "comité", "député", "curé", "abbé"]

    /// Noms en -ée, qui ne sont pas des participes au féminin.
    private static let feminineNouns: Set<String> = ["idée", "année", "lycée", "musée", "fée", "poupée", "journée",
                                                     "soirée", "matinée", "pensée", "armée", "épée", "fusée"]

    /// Féminins en -elle dont le masculin n'est pas en -el.
    private static let feminineOnly: Set<String> = ["belle", "nouvelle", "jumelle", "elle", "vaisselle", "poubelle",
                                                    "ficelle", "chandelle", "querelle", "nacelle", "pelle", "selle"]

    /// Le participe d'un verbe pronominal reste au masculin quand un complément d'objet le suit.
    private static func followedByObject(_ after: String) -> Bool {
        object?.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) != nil
    }

    private static let object = try? NSRegularExpression(pattern: #"^\s+(?:le|la|les|l['’]|un|une|des|du|mon|ma|mes|ton|ta|tes|son|sa|ses|notre|nos|votre|vos|leur|leurs|ce|cet|cette|ces)\b"#,
                                                         options: [.caseInsensitive])

    /// « je » (ou « j' »), négation facultative, « me » (groupe 1) facultatif devant être, le verbe, un participe de
    /// liaison facultatif (groupe 2 : « resté », « devenu », « senti »…), des adverbes, puis le mot à accorder (groupe 3).
    private static let pattern: NSRegularExpression? = {
        let negation = #"(?:ne\s+|n['’]\s*)?"#
        let reflexive = #"(me\s+|m['’]\s*)"#
        let etre = #"(?:suis|étais|serai|serais|fus)"#
        let plain = #"(?:ai\s+été|avais\s+été|aurai\s+été|aurais\s+été|reste|restais|resterai|resterais|deviens|devenais)"#
        let withMe = #"(?:sens|sentais|sentirai|sentirais|trouve|trouvais|retrouve|retrouvais)"#
        let verb = "(?:" + reflexive + "?" + etre + "|" + plain + "|" + #"(?:me\s+|m['’]\s*)"# + withMe + ")"
        let adverbs = #"(?:\s+(?:pas|plus|jamais|vraiment|très|trop|si|tellement|déjà|bien|encore|toujours|aussi|un\s+peu|assez|complètement|totalement|super|hyper|presque|juste|enfin|finalement|probablement|sûrement|peut-être|tout\s+à\s+fait|carrément))*"#
        let linking = #"(?:\s+(resté|restée|devenu|devenue|senti|sentie|retrouvé|retrouvée|redevenu|redevenue))?"#
        let word = #"\s+(\p{Ll}[\p{L}]*)(?![\p{L}'’-])"#
        let full = #"(?<![\p{L}])(?:je\s+|j['’]\s*)"# + negation + verb + linking + adverbs + word
        return try? NSRegularExpression(pattern: full, options: [.caseInsensitive])
    }()
}
