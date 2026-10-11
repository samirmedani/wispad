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
