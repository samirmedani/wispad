import CoreGraphics
import Foundation

/// Repère de page autour d'un champ (rôles ARIA exposés par l'accessibilité).
public enum InputLandmark: String, Sendable {
    case none
    /// Contenu principal de la page (fil, conversation, article).
    case main
    /// En-tête du site, navigation ou zone de recherche : rarement là qu'on écrit un message.
    case banner
    /// Colonne annexe (tendances, suggestions, recherche latérale).
    case complementary
}

/// Champ de saisie visible dans la fenêtre active, décrit sans son texte : de quoi juger s'il attend la dictée.
public struct InputCandidate: Equatable, Sendable {
    public var role: String
    /// Cadre à l'écran, origine en haut à gauche comme l'accessibilité.
    public var frame: CGRect
    public var multiline: Bool
    /// Caractères visibles du champ (espaces et caractères invisibles exclus). Jamais le texte lui-même.
    public var length: Int
    /// Texte indicatif, libellé et aide, en minuscules sans accents. Jamais enregistré ni journalisé.
    public var hint: String
    public var domIdentifier: String
    public var domClasses: [String]
    /// Dans une fenêtre modale de la page (réponse, nouveau message) : elle passe devant le reste.
    public var inDialog: Bool
    public var landmark: InputLandmark
    /// Dans une liste (messages, fil, résultats) : souvent un champ d'une autre conversation ou d'un élément.
    public var inList: Bool
    /// Le curseur peut être placé à la fin du texte déjà présent.
    public var caretMovable: Bool
    /// Champ du curseur au début de la dictée.
    public var isStart: Bool
    /// Dernier champ de cette app où Wispad a écrit.
    public var isLastTarget: Bool
    /// Dictées déjà arrivées dans un champ de cette forme, dans cette app ou sur ce site.
    public var learned: Int
    /// Sous le dernier clic, ou parent modifiable de l'élément cliqué.
    public var clickHit: Bool

    public init(role: String, frame: CGRect, multiline: Bool = false, length: Int = 0, hint: String = "",
                domIdentifier: String = "", domClasses: [String] = [], inDialog: Bool = false,
                landmark: InputLandmark = .none, inList: Bool = false, caretMovable: Bool = false,
                isStart: Bool = false, isLastTarget: Bool = false, learned: Int = 0, clickHit: Bool = false) {
        self.role = role
        self.frame = frame
        self.multiline = multiline
        self.length = length
        self.hint = hint
        self.domIdentifier = domIdentifier
        self.domClasses = domClasses
        self.inDialog = inDialog
        self.landmark = landmark
        self.inList = inList
        self.caretMovable = caretMovable
        self.isStart = isStart
        self.isLastTarget = isLastTarget
        self.learned = learned
        self.clickHit = clickHit
    }

    /// Signal qui vient de l'utilisateur lui-même : clic, champ du début, dernier champ utilisé, habitude.
    public var hasStrongSignal: Bool {
        clickHit || isStart || isLastTarget || learned >= 2
    }
}

/// Ce qui entoure la décision : la fenêtre, le dernier clic, le pointeur, et la confiance qu'on peut avoir.
public struct InputScene: Equatable, Sendable {
    public var window: CGRect
    /// Dernier clic depuis le début de la dictée, dans cette fenêtre.
    public var click: CGPoint?
    public var pointer: CGPoint?
    /// Focus illisible ou indécis : un éditeur caché peut déjà l'avoir. Déplacer le focus demande une preuve forte.
    public var strict: Bool
    /// Arbre parcouru en entier (hors listes longues) : sinon seuls les candidats appuyés par un signal fort comptent.
    public var complete: Bool

    public init(window: CGRect, click: CGPoint? = nil, pointer: CGPoint? = nil, strict: Bool = false, complete: Bool = true) {
        self.window = window
        self.click = click
        self.pointer = pointer
        self.strict = strict
        self.complete = complete
    }
}

public struct InputChoice: Equatable, Sendable {
    public let index: Int
    public let score: Double
    public let runnerUp: Double?
    /// Signaux retenus, pour le journal : jamais de texte.
    public let signals: [String]
}

/// Champ le plus probable pour une dictée finie sans curseur dans un champ. Tout se décide sur le Mac, en quelques
/// millisecondes, à partir de la forme des champs : multiligne, texte indicatif (« Message », « Répondre »,
/// « Rechercher »), taille, place dans la fenêtre, fenêtre modale, et ce que l'utilisateur a fait (clic, champ du
/// début, dernier champ utilisé, habitudes). Sans choix net, rien n'est choisi.
public enum InputTargeting {
    /// Mots d'un champ où l'on écrit un message, une réponse ou une demande.
    static let composeWords = [
        "message", "ecri", "repon", "reply", "comment", "post", "tweet", "quoi de neuf", "what's happening",
        "whats happening", "what is happening", "ask", "demand", "pose", "question", "send", "envoy", "tape ",
        "type a", "type here", "start typing", "saisi", "write", "compose", "prompt", "chat", "say something",
        "follow", "suite", "anything", "note", "partag", "share", "texte", "text", "corps", "body", "contenu",
        "redig", "draft", "brouillon", "discut", "talk", "parle", "describe", "decri", "travaill", "work on",
        "how can i help", "comment puis", "instruction",
    ]
    /// Champs de recherche, d'adresse ou de mot de passe : jamais là qu'on dicte un texte sans le viser.
    static let searchWords = [
        "search", "recherch", "find", "trouver", "filter", "filtr", "url", "address", "adresse", "go to", "aller a",
        "jump to", "password", "mot de passe", "passcode", "lookup",
    ]
    /// Champs de formulaire courts : possibles, mais moins probables qu'une zone de message.
    static let formWords = [
        "e-mail", "email", "courriel", "username", "identifiant", "login", "name", "nom", "prenom", "phone",
        "telephone", "zip", "postal", "code", "date", "ville", "city", "pays", "country", "objet", "subject",
        "titre", "title", "lien", "link", "tag",
    ]
    static let composeMarkup = [
        "prompt", "composer", "compose", "message", "chat", "reply", "comment", "editor", "prosemirror",
        "drafteditor", "slate", "ql-editor", "tweet", "lexical", "tiptap",
    ]
    static let searchMarkup = ["search", "query", "filter", "omnibox", "url", "find", "lookup"]

    /// Minuscules sans accents ni apostrophe typographique, pour comparer les textes indicatifs.
    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
    }

    public static func score(_ candidate: InputCandidate, in scene: InputScene, dialogPresent: Bool = false) -> Double {
        evaluate(candidate, in: scene, dialogPresent: dialogPresent).score
    }

    static func evaluate(_ c: InputCandidate, in scene: InputScene, dialogPresent: Bool) -> (score: Double, signals: [String]) {
        var score = 0.0
        var signals: [String] = []
        if c.multiline { score += 2 }
        if c.role == "AXComboBox" { score -= 1 }
        let hint = c.hint
        if composeWords.contains(where: hint.contains) { score += 3 }
        if searchWords.contains(where: hint.contains) {
            score -= 3
        } else if formWords.contains(where: hint.contains) {
            score -= 1.5
        }
        let markup = ([c.domIdentifier] + c.domClasses).map { $0.lowercased() }
        if markup.contains(where: { item in searchMarkup.contains(where: item.contains) }) {
            score -= 3
        } else if markup.contains(where: { item in composeMarkup.contains(where: item.contains) }) {
            score += 1.5
        }
        let area = max(0, c.frame.width) * max(0, c.frame.height)
        score += min(2, area.squareRoot() / 150)
        let widthRatio = c.frame.width / max(1, scene.window.width)
        if widthRatio >= 0.4 { score += 1 } else if widthRatio < 0.15 { score -= 1 }
        if scene.window.height > 0, (c.frame.midY - scene.window.minY) / scene.window.height >= 0.65 { score += 0.75 }
        if c.length == 0 { score += 1 } else { score -= c.caretMovable ? 1.5 : 3 }
        switch c.landmark {
        case .main: score += 0.5
        case .banner: score -= 2.5
        case .complementary: score -= 1
        case .none: break
        }
        if c.inDialog { score += 2 } else if dialogPresent { score -= 4 }
        if c.inList { score -= 0.5 }
        if c.isStart { score += 4; signals.append("début") }
        if c.isLastTarget { score += 3; signals.append("dernier") }
        if c.learned > 0 {
            score += min(3, 1.2 * log2(1 + Double(c.learned)))
            signals.append("habitude")
        }
        if c.clickHit {
            score += 7
            signals.append("clic")
        } else if let click = scene.click, scene.window.contains(click) {
            score += 2.5 * exp(-distance(from: click, to: c.frame) / 150)
        }
        if let pointer = scene.pointer, scene.window.contains(pointer) {
            score += exp(-distance(from: pointer, to: c.frame) / 250)
        }
        return (score, signals)
    }

    /// Le champ retenu, ou nil si le choix n'est pas net. Focus lisible : meilleur score d'au moins 2,5 et 1,5 point
    /// d'avance (un seul champ visible : 1 point suffit). Focus illisible : il faut un signal de l'utilisateur (clic,
    /// champ du début, dernier champ, habitude), une zone de message évidente, ou un seul champ franc (5 points).
    /// Parcours incomplet : seul un signal de l'utilisateur compte.
    public static func choose(_ candidates: [InputCandidate], in scene: InputScene) -> InputChoice? {
        guard !candidates.isEmpty else { return nil }
        let dialog = candidates.contains { $0.inDialog }
        let scored = candidates.enumerated()
            .map { (index: $0.offset, result: evaluate($0.element, in: scene, dialogPresent: dialog)) }
            .sorted { $0.result.score > $1.result.score }
        let best = scored[0]
        let runnerUp = scored.count > 1 ? scored[1].result.score : nil
        let margin = best.result.score - (runnerUp ?? -.infinity)
        let strong = candidates[best.index].hasStrongSignal && best.result.score >= 3 && margin >= 2
        let accepted: Bool
        if !scene.complete {
            accepted = strong
        } else if scene.strict {
            accepted = strong || (best.result.score >= 7.5 && margin >= 3) || (candidates.count == 1 && best.result.score >= 5)
        } else {
            accepted = (candidates.count == 1 && best.result.score >= 1) || (best.result.score >= 2.5 && margin >= 1.5)
        }
        guard accepted else { return nil }
        return InputChoice(index: best.index, score: best.result.score, runnerUp: runnerUp, signals: best.result.signals)
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Habitudes

    /// Forme d'un champ, sans son texte ni son libellé : rôle, identifiants techniques, place dans la fenêtre.
    /// Seule l'empreinte est gardée.
    public static func signature(role: String, multiline: Bool, domIdentifier: String, domClasses: [String],
                                 frame: CGRect, window: CGRect) -> String {
        let height = max(1, window.height)
        let middle = (frame.midY - window.minY) / height
        let vertical = middle < 0.33 ? "haut" : middle < 0.66 ? "milieu" : "bas"
        let ratio = frame.width / max(1, window.width)
        let width = ratio < 0.25 ? "etroit" : ratio < 0.6 ? "moyen" : "large"
        let classes = domClasses.prefix(3).joined(separator: ".")
        return digest([role, multiline ? "m" : "l", domIdentifier, classes, vertical, width].joined(separator: "|"))
    }

    /// App, et site pour un navigateur : seule l'empreinte est gardée, jamais l'adresse.
    public static func placeKey(bundleID: String?, host: String?) -> String {
        digest((bundleID ?? "?") + "|" + (host?.lowercased() ?? ""))
    }

    /// FNV-1a 64 bits : stable d'un lancement à l'autre, contrairement à Hasher.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Champs où les dictées arrivent, par app et par site, sous forme d'empreintes : aucun texte, aucune adresse.
public struct InputMemory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var count: Int
        public var last: Date
    }

    public static let maxPlaces = 300
    public static let maxShapes = 12

    public var places: [String: [String: Entry]] = [:]

    public init() {}

    public func count(place: String, signature: String) -> Int {
        places[place]?[signature]?.count ?? 0
    }

    public mutating func record(place: String, signature: String, at date: Date = Date()) {
        var shapes = places[place] ?? [:]
        var entry = shapes[signature] ?? Entry(count: 0, last: date)
        entry.count += 1
        entry.last = date
        shapes[signature] = entry
        if shapes.count > Self.maxShapes, let oldest = shapes.min(by: { $0.value.last < $1.value.last })?.key {
            shapes.removeValue(forKey: oldest)
        }
        places[place] = shapes
        if places.count > Self.maxPlaces,
           let oldest = places.min(by: { latest($0.value) < latest($1.value) })?.key {
            places.removeValue(forKey: oldest)
        }
    }

    private func latest(_ shapes: [String: Entry]) -> Date {
        shapes.values.map(\.last).max() ?? .distantPast
    }
}
