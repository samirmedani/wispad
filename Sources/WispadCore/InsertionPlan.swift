import Foundation

public enum InsertionStatus: String, Sendable, Codable {
    case transcriptionFailed = "transcription_failed"
    case pending
    case pasteSent = "paste_sent"
    case inserted
    case failed
    case refusedSecure = "refused_secure"
    /// Collage parti dans le vide : aucun champ de texte n'avait le focus.
    case noTarget = "no_target"
    case cancelled

    /// Le texte est parti dans un champ : inséré et confirmé, ou ⌘V envoyé sans confirmation possible.
    /// Une dictée comme « Coller la dernière dictée » se termine alors de la même façon.
    public var delivered: Bool {
        self == .inserted || self == .pasteSent
    }
}

public enum InsertionRoute: Equatable, Sendable {
    /// Collage dans l'app cible, comme un Cmd+V de l'utilisateur. Le texte reste dans l'historique.
    case paste
    case refuseSecure
    case keepOnly
}

public enum InsertionPlanner {
    /// Le collage ne dépend pas d'un champ visible via l'accessibilité : les apps Electron
    /// (Claude, Slack, VS Code…) n'en exposent souvent aucun, surtout au premier usage.
    public static func route(isSecureField: Bool, secureInputActive: Bool, accessibilityTrusted: Bool) -> InsertionRoute {
        if isSecureField || secureInputActive { return .refuseSecure }
        if !accessibilityTrusted { return .keepOnly }
        return .paste
    }
}

public enum InsertionCheck {
    /// Comparer l'édition complète au curseur couvre aussi une sélection remplacée dont le début ne change pas.
    /// Les transformations typographiques de l'éditeur ne sont pas des échecs d'insertion.
    public static func matchesReplacement(before: String?, selection: NSRange?, after: String?, inserted: String) -> Bool {
        guard let before, let selection, let after,
              selection.location >= 0, selection.length >= 0,
              selection.location <= (before as NSString).length,
              selection.length <= (before as NSString).length - selection.location else { return false }
        let expected = (before as NSString).replacingCharacters(in: selection, with: inserted)
        if expected == after { return true }
        // Pour un texte composé uniquement de ponctuation, seule l'égalité exacte ci-dessus fait foi.
        return !normalize(inserted).isEmpty && normalize(expected) == normalize(after)
    }

    /// Vrai seulement si la valeur du champ a changé et contient une fois de plus le début du texte collé.
    /// Seuls les lettres et les chiffres comptent : les éditeurs riches (Claude, ChatGPT dans Chrome) réécrivent
    /// espaces, apostrophes, tirets de liste et retours à la ligne.
    public static func confirms(before: String?, after: String?, inserted text: String) -> Bool {
        guard let after, after != before else { return false }
        let probe = String(normalize(text).prefix(40))
        guard !probe.isEmpty else { return false }
        return occurrences(of: probe, in: normalize(after)) > occurrences(of: probe, in: normalize(before ?? ""))
    }

    private static func normalize(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func occurrences(of probe: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: probe, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }
}

/// Nature de l'élément qui a le focus au moment du collage, lue dans l'arbre d'accessibilité.
public enum FocusedFieldKind: Equatable, Sendable {
    /// Champ où l'on écrit : rôle de texte ou curseur de texte exposé.
    case text
    /// Élément où l'on n'écrit sûrement pas (liste, bouton, menu… ou rien de lisible dans le Finder).
    case notText
    /// Impossible de conclure : rien de lisible, ou un conteneur (groupe, fenêtre, zone web, canevas) qui peut
    /// cacher un éditeur. Les apps Electron, les terminaux GPU et les éditeurs dessinés en sont souvent là.
    case unknown
}

public enum FocusedField {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Rôles qui ne reçoivent jamais de texte collé. Pas de tableau ni de cellule (tableurs), pas de groupe ni de
    /// fenêtre (éditeurs dessinés, terminaux GPU, champs web) : dans le doute, le collage reste « envoyé ».
    static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXBrowser", "AXButton", "AXImage", "AXLink", "AXMenu", "AXMenuBar", "AXMenuItem",
        "AXMenuBarItem", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXTabGroup",
        "AXToolbar", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXDockItem",
    ]
    /// Apps sans saisie de texte hors de leurs champs (renommer, rechercher) : le bureau et les fenêtres du Finder.
    static let textlessApps: Set<String> = ["com.apple.finder"]

    /// `role` : nil quand aucun élément n'a le focus (ou qu'il n'a pas pu être lu).
    public static func kind(role: String?, subrole: String? = nil, hasTextCursor: Bool, bundleID: String?) -> FocusedFieldKind {
        if hasTextCursor { return .text }
        if let role, textRoles.contains(role) { return .text }
        if let subrole, textRoles.contains(subrole) { return .text }
        if let bundleID, textlessApps.contains(bundleID) { return .notText }
        guard let role else { return .unknown }
        return nonTextRoles.contains(role) ? .notText : .unknown
    }

    /// Une lecture inchangée peut être un instantané AX en retard : elle ne prouve pas l'échec d'un envoi.
    /// Sans preuve d'insertion, conserver le statut incertain et l'accès au texte.
    public static func status(confirmed: Bool, kinds: [FocusedFieldKind]) -> InsertionStatus {
        if confirmed { return .inserted }
        if kinds.contains(.notText), !kinds.contains(.text) { return .noTarget }
        return .pasteSent
    }
}
