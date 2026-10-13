import Foundation

/// Fragment lu dans l'arbre d'accessibilité, dans l'ordre de lecture.
public struct WindowTextFragment: Equatable, Sendable {
    public var text: String
    public var role: String
    public var isFocusedField: Bool
    public var isSecure: Bool

    public init(text: String, role: String, isFocusedField: Bool = false, isSecure: Bool = false) {
        self.text = text
        self.role = role
        self.isFocusedField = isFocusedField
        self.isSecure = isSecure
    }
}

/// Met en forme le texte visible d'une fenêtre pour un futur contexte de correction.
/// Le texte reste en mémoire : rien n'est journalisé ici.
public enum WindowContext {
    public static let defaultCharacterLimit = 2_000

    /// Fragments utiles, du plus ancien au plus récent, séparés par des retours à la ligne.
    /// nil s'il ne reste rien. La fin est conservée : les messages récents sont en bas.
    public static func assemble(_ fragments: [WindowTextFragment], characterLimit: Int = defaultCharacterLimit) -> String? {
        let clipped = tail(lines(from: fragments), limit: characterLimit)
        guard !clipped.isEmpty else { return nil }
        return clipped.joined(separator: "\n")
    }

    /// Termes techniques candidats. `ContextTerms.hints` extrait, `KeytermList.sanitize` nettoie :
    /// les deux restent inchangés dans TextPipeline.
    public static func candidateTerms(in text: String?) -> [String] {
        KeytermList.sanitize(ContextTerms.hints(from: text))
    }

    private static let chromeRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem",
        "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTab", "AXToolbar", "AXToolbarButton",
        "AXIncrementor", "AXDisclosureTriangle", "AXSlider", "AXValueIndicator",
    ]

    private static let actionLabels: Set<String> = [
        "copier", "copy", "envoyer", "send", "annuler", "cancel",
        "coller", "paste", "fermer", "close", "partager", "share",
        "supprimer", "delete", "modifier", "edit",
    ]

    private static func lines(from fragments: [WindowTextFragment]) -> [String] {
        var kept: [String] = []
        var seen = Set<String>()
        var previousWords: [String] = []
        for fragment in fragments {
            if fragment.isSecure || fragment.isFocusedField { continue }
            let text = normalize(fragment.text)
            if text.isEmpty || isChrome(text, role: fragment.role) { continue }
            if seen.contains(text) { continue }
            let currentWords = words(in: text)
            // Un parent AX et son enfant exposent souvent le même texte, ou le parent contient l'enfant.
            if repeats(currentWords, previous: previousWords) { continue }
            kept.append(text)
            seen.insert(text)
            previousWords = currentWords
        }
        return kept
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isChrome(_ text: String, role: String) -> Bool {
        if chromeRoles.contains(role) { return true }
        if isActionLabel(text) || isTimestamp(text) || isCounter(text) { return true }
        return !isProse(text)
    }

    /// Une phrase, ou un passage assez long pour ne pas être un libellé de bouton.
    private static func isProse(_ text: String) -> Bool {
        if text.count >= 40 { return true }
        if text.split(whereSeparator: \.isWhitespace).count >= 4 { return true }
        return hasSentenceEnding(text)
    }

    private static func hasSentenceEnding(_ text: String) -> Bool {
        let characters = Array(text)
        for (offset, character) in characters.enumerated() {
            guard character == "." || character == "!" || character == "?" || character == "…" else { continue }
            if character == ".", offset > 0, characters[offset - 1].isNumber { continue }
            let next = offset + 1
            if next == characters.count || characters[next].isWhitespace { return true }
        }
        return false
    }

    private static func isActionLabel(_ text: String) -> Bool {
        let stripped = text.lowercased().trimmingCharacters(in: punctuationAndSymbols)
        return actionLabels.contains(stripped)
    }

    private static func isTimestamp(_ text: String) -> Bool {
        matchesAny(timestampPatterns, text)
    }

    private static func isCounter(_ text: String) -> Bool {
        matchesAny(counterPatterns, text)
    }

    // Compilées une fois : une lecture de fenêtre passe chaque fragment (des centaines) par ces dix expressions,
    // qu'une recherche `range(of:options: .regularExpression)` recompilait à chaque appel. Même moteur (ICU), même
    // motif, mêmes options : le résultat ne change pas.
    private static let timestampPatterns = expressions([
        #"(?i)^\d{1,2}:\d{2}(:\d{2})?( ?[ap]m)?$"#,
        #"(?i)^\d{1,2}h\d{2}$"#,
        #"(?i)^il y a \d+ (s|sec|secs|seconde|secondes|min|mins|minute|minutes|h|heure|heures)$"#,
        #"(?i)^\d+ (s|sec|secs|min|mins|h) ago$"#,
        #"(?i)^(aujourd'hui|aujourd’hui|hier|today|yesterday)$"#,
    ])

    private static let counterPatterns = expressions([
        #"^\d+$"#,
        #"^\(\d+\)$"#,
        #"^\+\d+$"#,
        #"^\d+/\d+$"#,
        #"(?i)^\d+ (messages?|nouveaux?|comments?|commentaires?|items?)$"#,
    ])

    /// Un motif invalide ne reconnaît rien, comme une recherche `range(of:options:)` qui échoue.
    private static func expressions(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    private static func matchesAny(_ expressions: [NSRegularExpression], _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Calculé une fois : l'union était refaite pour chaque fragment et chaque mot d'une lecture de fenêtre.
    private static let punctuationAndSymbols = CharacterSet.punctuationCharacters.union(.symbols)

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let cleaned = token.trimmingCharacters(in: punctuationAndSymbols)
            return cleaned.isEmpty ? nil : String(cleaned)
        }
    }

    private static func repeats(_ current: [String], previous: [String]) -> Bool {
        guard !current.isEmpty, !previous.isEmpty else { return false }
        if current == previous { return true }
        guard current.count < previous.count else { return false }
        let lastStart = previous.count - current.count
        for start in 0...lastStart {
            if previous[start..<(start + current.count)].elementsEqual(current) { return true }
        }
        return false
    }

    /// Garde la fin. Un mot à cheval sur la limite est laissé de côté, pas coupé.
    private static func tail(_ lines: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            let separator = kept.isEmpty ? 0 : 1
            if used + separator + line.count <= limit {
                kept.append(line)
                used += separator + line.count
                continue
            }
            let room = limit - used - separator
            if room > 0, let suffix = wordSuffix(line, room: room) {
                kept.append(suffix)
            }
            break
        }
        return kept.reversed()
    }

    private static func wordSuffix(_ line: String, room: Int) -> String? {
        guard room > 0 else { return nil }
        if line.count <= room { return line }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var chosen: [String] = []
        var count = 0
        for word in parts.reversed() {
            let extra = word.count + (chosen.isEmpty ? 0 : 1)
            if count + extra > room { break }
            chosen.append(word)
            count += extra
        }
        guard !chosen.isEmpty else { return nil }
        return chosen.reversed().joined(separator: " ")
    }
}

/// Bornes d'un parcours d'arbre : nœuds, profondeur et temps.
public struct WindowWalkLimits: Equatable, Sendable {
    public var maxNodes: Int
    public var maxDepth: Int
    public var budget: Duration

    public init(maxNodes: Int, maxDepth: Int, budget: Duration) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.budget = budget
    }

    /// Fenêtre focalisée : 4 000 nœuds, profondeur 60, 300 ms.
    public static let windowReading = WindowWalkLimits(maxNodes: 4_000, maxDepth: 60, budget: .milliseconds(300))
}

public struct WindowWalkResult<Value: Sendable>: Sendable {
    public var values: [Value]
    public var nodesVisited: Int
    public var stoppedOnBudget: Bool

    public init(values: [Value], nodesVisited: Int, stoppedOnBudget: Bool) {
        self.values = values
        self.nodesVisited = nodesVisited
        self.stoppedOnBudget = stoppedOnBudget
    }
}

/// Parcours en profondeur. La profondeur coupe une branche ; le nombre de nœuds et le temps arrêtent tout,
/// en gardant ce qui a déjà été lu.
public enum WindowTreeWalk {
    public static func collect<Node, Value: Sendable>(
        root: Node,
        limits: WindowWalkLimits,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        children: (Node) -> [Node],
        value: (Node) -> Value?
    ) -> WindowWalkResult<Value> {
        let deadline = now().advanced(by: limits.budget)
        var values: [Value] = []
        var visited = 0
        var stopped = false

        func visit(_ node: Node, depth: Int) {
            guard !stopped else { return }
            if depth >= limits.maxDepth { return }
            if visited >= limits.maxNodes || now() >= deadline {
                stopped = true
                return
            }
            visited += 1
            if let item = value(node) {
                values.append(item)
            }
            for child in children(node) {
                visit(child, depth: depth + 1)
                if stopped { return }
            }
        }

        visit(root, depth: 0)
        return WindowWalkResult(values: values, nodesVisited: visited, stoppedOnBudget: stopped)
    }
}
