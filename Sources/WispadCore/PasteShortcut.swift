import Foundation

/// Raccourci global « Coller la dernière dictée » : une touche et ses modificateurs (masques `ModifierMask`).
/// Désactivé, il garde sa combinaison pour la retrouver en le réactivant.
public struct PasteShortcut: Equatable, Sendable, Codable {
    public var keyCode: Int
    public var modifiers: UInt64
    public var enabled: Bool

    /// Touche V (même position en QWERTY, AZERTY et QWERTZ).
    public static let vKeyCode = 9
    /// ⌃⌥V : faisable d'une main (pouce et annulaire gauches sur ⌃⌥, index sur V), libre dans macOS et rare dans
    /// les apps courantes, contrairement à ⌘⇧V (coller sans mise en forme) et ⌥⌘V (déplacer dans le Finder).
    public static let standard = PasteShortcut(keyCode: vKeyCode, modifiers: ModifierMask.control | ModifierMask.option)

    /// Modificateurs pris en compte : fn n'en fait jamais partie (il reste au raccourci de dictée).
    public static let modifierMask = ModifierMask.command | ModifierMask.shift | ModifierMask.option | ModifierMask.control

    public init(keyCode: Int, modifiers: UInt64, enabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
        self.enabled = enabled
    }

    /// Lecture tolérante : champ absent ou illisible, valeur du raccourci par défaut pour ce seul champ.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = (try? container.decodeIfPresent(Int.self, forKey: .keyCode)) ?? Self.standard.keyCode
        let modifiers = (try? container.decodeIfPresent(UInt64.self, forKey: .modifiers)) ?? Self.standard.modifiers
        let enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        self.init(keyCode: keyCode, modifiers: modifiers, enabled: enabled)
    }

    /// Valeur enregistrée relue : une combinaison devenue invalide (modifiée à la main, version future) redevient
    /// le raccourci par défaut, en gardant le choix activé ou désactivé.
    public static func restored(_ stored: PasteShortcut?) -> PasteShortcut {
        guard let stored else { return standard }
        guard PasteShortcutRules.problem(stored) == nil else {
            return PasteShortcut(keyCode: standard.keyCode, modifiers: standard.modifiers, enabled: stored.enabled)
        }
        return stored
    }

    /// Même touche et mêmes modificateurs, sans tenir compte de l'état activé.
    public func sameCombination(as other: PasteShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    /// Frappe qui déclenche le raccourci : touche et modificateurs exacts. fn enfoncé ne déclenche rien, sauf sur
    /// les touches que macOS marque toujours de fn (flèches, touches F, début, fin…).
    public func matches(keyCode: Int, flags: UInt64) -> Bool {
        guard enabled, keyCode == self.keyCode, flags & Self.modifierMask == modifiers else { return false }
        if flags & ModifierMask.function != 0, !PasteShortcutRules.carriesFunctionFlag(keyCode) { return false }
        return true
    }

    /// Symboles des modificateurs dans l'ordre de macOS : ⌃ ⌥ ⇧ ⌘.
    public static func modifierSymbols(_ flags: UInt64) -> [String] {
        var symbols: [String] = []
        if flags & ModifierMask.control != 0 { symbols.append("⌃") }
        if flags & ModifierMask.option != 0 { symbols.append("⌥") }
        if flags & ModifierMask.shift != 0 { symbols.append("⇧") }
        if flags & ModifierMask.command != 0 { symbols.append("⌘") }
        return symbols
    }

    /// Modificateurs Carbon (raccourcis du système) convertis en masques `ModifierMask`.
    public static func modifiers(carbon: Int) -> UInt64 {
        var flags: UInt64 = 0
        if carbon & 0x100 != 0 { flags |= ModifierMask.command }
        if carbon & 0x200 != 0 { flags |= ModifierMask.shift }
        if carbon & 0x800 != 0 { flags |= ModifierMask.option }
        if carbon & 0x1000 != 0 { flags |= ModifierMask.control }
        return flags
    }
}

/// Pourquoi une combinaison est refusée pour « Coller la dernière dictée ». Les textes sont dans l'app.
public enum PasteShortcutProblem: Equatable, Sendable {
    /// Une touche de modificateur seule (⌘, ⇧, ⌥, ⌃, verr. maj).
    case modifierOnly
    /// fn ou la touche 🌐 : réservée au raccourci de dictée.
    case functionKey
    /// Échap : réservé à l'annulation.
    case escape
    /// Ni ⌃, ni ⌥, ni ⌘ : la frappe écrirait un caractère.
    case needsModifier
    /// ⌘ seul avec une touche : raccourci des menus de presque toutes les apps.
    case commandOnly
    /// Combinaison connue de macOS ou des apps courantes.
    case reserved(PasteShortcutRules.Use)
    /// Raccourci du système déclaré dans Réglages Système › Clavier › Raccourcis.
    case system
    /// Déjà le raccourci de dictée.
    case sameAsDictation
}

public enum PasteShortcutRules {
    /// Usage connu d'une combinaison refusée.
    public enum Use: String, Equatable, Sendable, CaseIterable {
        case paste, pastePlain, finderMove, copy, cut, undo, selectAll, quit, closeWindow, hide, minimize
        case appSwitcher, spotlight, inputSource, emoji, screenshot, lockScreen, fullScreen, forceQuit, dock
    }

    static let escapeKeyCode = 53
    static let spaceKeyCode = 49
    static let tabKeyCode = 48
    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62]

    /// Touches que macOS marque de fn dans chaque frappe : flèches, F1 à F20, aide, début, fin, pages, suppr. avant.
    static let functionFlagKeyCodes: Set<Int> = [
        123, 124, 125, 126,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        114, 115, 116, 117, 119, 121,
    ]

    public static func carriesFunctionFlag(_ keyCode: Int) -> Bool {
        functionFlagKeyCodes.contains(keyCode)
    }

    private static let command = ModifierMask.command
    private static let shift = ModifierMask.shift
    private static let option = ModifierMask.option
    private static let control = ModifierMask.control

    /// Combinaisons connues (positions de touches ANSI, identiques en AZERTY pour ces lettres et chiffres).
    static let reserved: [(keyCode: Int, modifiers: UInt64, use: Use)] = [
        (9, command | shift, .pastePlain),
        (9, command | option | shift, .pastePlain),
        (9, command | option, .finderMove),
        (9, command | control, .pastePlain),
        (49, command, .spotlight),
        (49, command | option, .spotlight),
        (49, control, .inputSource),
        (49, control | option, .inputSource),
        (49, command | control, .emoji),
        (48, command, .appSwitcher),
        (48, command | shift, .appSwitcher),
        (50, command, .appSwitcher),
        (20, command | shift, .screenshot),
        (21, command | shift, .screenshot),
        (23, command | shift, .screenshot),
        (22, command | shift, .screenshot),
        (20, command | control | shift, .screenshot),
        (21, command | control | shift, .screenshot),
        (12, command | control, .lockScreen),
        (3, command | control, .fullScreen),
        (53, command | option, .forceQuit),
        (2, command | option, .dock),
        (4, command | option, .hide),
        (46, command | option, .minimize),
        (13, command | option, .closeWindow),
    ]

    /// Raccourcis ⌘ + touche des menus d'édition, pour nommer l'usage dans le message.
    static let commandUses: [Int: Use] = [
        9: .paste, 8: .copy, 7: .cut, 6: .undo, 0: .selectAll, 12: .quit, 13: .closeWindow, 4: .hide, 46: .minimize,
    ]

    /// Première raison de refuser la combinaison, ou nil si elle convient.
    /// `system` : combinaisons déclarées par macOS (Réglages Système › Clavier › Raccourcis), lues par l'app.
    /// `dictation` : touche et modificateurs du raccourci de dictée.
    public static func problem(
        _ shortcut: PasteShortcut,
        system: [PasteShortcut] = [],
        dictation: (keyCode: Int, flags: UInt64)? = nil
    ) -> PasteShortcutProblem? {
        let modifiers = shortcut.modifiers & PasteShortcut.modifierMask
        if shortcut.keyCode == ChordMatcher.functionKeyCode { return .functionKey }
        if modifierKeyCodes.contains(shortcut.keyCode) { return .modifierOnly }
        if shortcut.keyCode < 0 || shortcut.keyCode > 127 { return .modifierOnly }
        if let use = reserved.first(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == modifiers })?.use {
            return .reserved(use)
        }
        if shortcut.keyCode == escapeKeyCode { return .escape }
        if modifiers & (command | option | control) == 0 { return .needsModifier }
        if modifiers == command {
            if let use = commandUses[shortcut.keyCode] { return .reserved(use) }
            return .commandOnly
        }
        if let dictation, dictation.keyCode == shortcut.keyCode, dictation.flags & PasteShortcut.modifierMask == modifiers {
            return .sameAsDictation
        }
        if system.contains(where: { $0.sameCombination(as: shortcut) }) { return .system }
        return nil
    }
}

/// Dictée que « Coller la dernière dictée » remet au curseur.
public enum PasteLastChoice {
    /// Une dictée non insérée plus ancienne cède la place à la dernière dictée : on ne ressort pas un vieux texte.
    public static let undeliveredWindow: TimeInterval = 30 * 60

    /// Statuts d'une dictée dont le texte n'est arrivé nulle part : prête à copier, aucun champ, collage raté,
    /// champ sécurisé.
    public static let undelivered: Set<String> = [
        InsertionStatus.pending.rawValue,
        InsertionStatus.noTarget.rawValue,
        InsertionStatus.failed.rawValue,
        InsertionStatus.refusedSecure.rawValue,
    ]

    /// La dernière dictée non insérée de la dernière demi-heure, sinon la dernière dictée. Une dictée annulée,
    /// sans transcription ou vide n'est jamais choisie.
    public static func pick(_ records: [DictationRecord], now: Date = Date()) -> DictationRecord? {
        let usable = records
            .filter { record in
                record.insertionStatus != InsertionStatus.cancelled.rawValue
                    && record.insertionStatus != InsertionStatus.transcriptionFailed.rawValue
                    && !record.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id > rhs.id
            }
        let fresh = usable.first { record in
            undelivered.contains(record.insertionStatus)
                && now.timeIntervalSince(record.createdAt) < undeliveredWindow
        }
        return fresh ?? usable.first
    }

    /// Statut à enregistrer après un nouveau collage : seulement s'il améliore celui de la dictée.
    /// Une dictée déjà livrée ne redevient jamais « non insérée » parce qu'un nouveau collage a échoué.
    public static func updatedStatus(previous: String, outcome: InsertionStatus) -> InsertionStatus? {
        switch outcome {
        case .inserted:
            return previous == InsertionStatus.inserted.rawValue ? nil : .inserted
        case .pasteSent:
            return undelivered.contains(previous) ? .pasteSent : nil
        default:
            return nil
        }
    }
}
