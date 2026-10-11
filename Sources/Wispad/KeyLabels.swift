import AppKit
import Carbon
import Foundation
import WispadCore

/// Touche physique qui produit un caractère dans la disposition active (AZERTY, Dvorak…),
/// pour que Cmd+V reste Cmd+V quel que soit le clavier.
enum KeyboardLayout {
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
                )
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }

    /// Touches de caractère (lettres, chiffres, ponctuation), aux positions de macOS : leur inscription dépend de
    /// la disposition.
    static let characterKeyCodes: Set<Int> = Set(0...47).subtracting([36]).union([50])

    /// Caractère inscrit sur chaque touche de caractère dans la disposition active (A ou Q en haut à gauche selon
    /// AZERTY ou QWERTY), en majuscule. Vide si la disposition est illisible.
    static func characters(for codes: Set<Int> = characterKeyCodes) -> [Int: String] {
        let wanted = codes.intersection(characterKeyCodes)
        guard !wanted.isEmpty, let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> [Int: String] in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
            var result: [Int: String] = [:]
            for code in wanted {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
                )
                guard status == noErr, length > 0 else { continue }
                let text = String(utf16CodeUnits: chars, count: length).uppercased()
                let printable = text.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespaces.contains($0)
                }
                if printable { result[code] = text }
            }
            return result
        }
    }
}

enum KeyLabels {
    static func describe(keyCode: Int, modifiers: UInt64) -> String {
        if keyCode == ChordMatcher.functionKeyCode { return "fn" }
        var parts: [String] = []
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        parts.append(name(for: keyCode))
        return parts.joined(separator: " ")
    }

    /// Nom d'une touche : celui de la disposition active pour une touche de caractère, sinon un nom fixe.
    static func name(for keyCode: Int) -> String {
        if let printed = KeyboardLayout.characters(for: [keyCode])[keyCode] { return printed }
        let names: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M",
            36: "retour", 48: "tab", 49: "espace", 51: "suppr", 53: "esc",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return names[keyCode] ?? String(localized: "touche \(keyCode)")
    }
}

extension KeyLabels {
    /// « ⌃ ⌥ V » : même écriture que le raccourci de dictée ; « ⌃⌥V » serré pour la carte de la barre latérale.
    static func describe(_ shortcut: PasteShortcut, compact: Bool = false) -> String {
        (PasteShortcut.modifierSymbols(shortcut.modifiers) + [name(for: shortcut.keyCode)]).joined(separator: compact ? "" : " ")
    }
}

/// Raccourcis déclarés par macOS dans Réglages Système › Clavier › Raccourcis (Spotlight, captures, Mission
/// Control, sources de saisie…), seulement ceux qui sont activés. Lus à la demande, jamais enregistrés.
enum SystemShortcuts {
    static func enabled() -> [PasteShortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            // 65535 : raccourci lié à un caractère plutôt qu'à une touche, sans code utilisable.
            guard (entry["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = entry["kHISymbolicHotKeyCode"] as? Int, (0..<128).contains(code),
                  let carbon = entry["kHISymbolicHotKeyModifiers"] as? Int else { return nil }
            return PasteShortcut(keyCode: code, modifiers: PasteShortcut.modifiers(carbon: carbon))
        }
    }
}
