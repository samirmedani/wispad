import CoreGraphics
import Testing
@testable import WispadApp
@testable import WispadCore

/// Raccourcis dessinés : une touche par touche à enfoncer, symbole et nom comme sur un clavier Mac, et chaque touche
/// à sa place sur le schéma du clavier de MacBook. Sur le fil principal, comme les noms de touches qu'ils dessinent.
@MainActor
struct ShortcutKeysTests {
    /// Noms fixes : les tests ne dépendent pas de la disposition du Mac qui les lance.
    private let names: @MainActor (Int) -> String = { [9: "V", 126: "↑", 49: "espace"][$0] ?? "?" }

    @Test func functionAloneIsOneKey() {
        let keys = ShortcutKeys.dictation(keyCode: ChordMatcher.functionKeyCode, modifiers: ModifierMask.function,
                                          name: names)
        #expect(keys == [ShortcutKeys.function])
        #expect(keys[0].name == "fn")
        #expect(keys[0].systemImage == "globe")
    }

    @Test func pasteDefaultIsControlOptionV() {
        let keys = ShortcutKeys.paste(.standard, name: names)
        #expect(keys.map(\.name) == ["control", "option", "V"])
        #expect(keys.map(\.symbol) == ["⌃", "⌥", nil])
        #expect(keys.map(\.keyCode) == [59, 58, 9])
        #expect(keys.map(\.isGlyph) == [false, false, true])
        #expect(ShortcutKeys.spoken(keys) == "control option V")
    }

    /// Ordre de macOS, fn d'abord ; fn que macOS ajoute à une flèche n'est pas une touche de plus.
    @Test func modifiersFollowMacOrder() {
        let all = ModifierMask.command | ModifierMask.shift | ModifierMask.option | ModifierMask.control
        let keys = ShortcutKeys.dictation(keyCode: 49, modifiers: all | ModifierMask.function, name: names)
        #expect(keys.map(\.name) == ["fn", "control", "option", "shift", "command", "espace"])
        let arrow = ShortcutKeys.dictation(keyCode: 126, modifiers: ModifierMask.control | ModifierMask.function,
                                           name: names)
        #expect(arrow.map(\.name) == ["control", "↑"])
    }

    /// Faute de place, une touche ne garde que son symbole ; fn et les lettres, sans symbole, gardent leur nom.
    @Test func compactKeysKeepTheirSymbols() {
        #expect(ShortcutKeys.paste(.standard, name: names).map(\.compactLabel) == ["⌃", "⌥", "V"])
        let all = ModifierMask.command | ModifierMask.shift | ModifierMask.option | ModifierMask.control
        let long = ShortcutKeys.dictation(keyCode: 49, modifiers: all | ModifierMask.function, name: names)
        #expect(long.map(\.compactLabel) == ["fn", "⌃", "⌥", "⇧", "⌘", "espace"])
    }

    /// ↺ (revenir à ⌃⌥V) n'apparaît que pour une autre combinaison, activée ou non, et jamais pendant
    /// l'enregistrement : il n'est jamais montré grisé.
    @Test func resetShowsOnlyForAnotherCombination() {
        let custom = PasteShortcut(keyCode: 35, modifiers: ModifierMask.control | ModifierMask.shift)
        var disabledStandard = PasteShortcut.standard
        disabledStandard.enabled = false
        var disabledCustom = custom
        disabledCustom.enabled = false
        #expect(!PasteShortcutRow.showsReset(.standard, recording: false))
        #expect(!PasteShortcutRow.showsReset(disabledStandard, recording: false))
        #expect(PasteShortcutRow.showsReset(custom, recording: false))
        #expect(PasteShortcutRow.showsReset(disabledCustom, recording: false))
        #expect(!PasteShortcutRow.showsReset(custom, recording: true))
    }

    /// Toute touche qu'un raccourci peut montrer a sa place sur le schéma.
    @Test func everyShortcutKeyIsOnTheDiagram() {
        let codes = Set(MacKeyboardLayout.keys.map(\.code))
        let modifiers = [ShortcutKeys.function, ShortcutKeys.control, ShortcutKeys.option, ShortcutKeys.shift,
                         ShortcutKeys.command].map(\.keyCode)
        for code in modifiers { #expect(codes.contains(code), "\(code)") }
        for code in KeyboardLayout.characterKeyCodes.subtracting([10]) { #expect(codes.contains(code), "\(code)") }
        for code in [36, 48, 49, 51, 53, 123, 124, 125, 126] { #expect(codes.contains(code), "\(code)") }
    }

    /// Chaque rangée remplit la largeur du clavier, sans touche qui en chevauche une autre.
    @Test func diagramKeysTileTheKeyboard() {
        let keys = MacKeyboardLayout.keys
        let rects = keys.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        for rect in rects {
            #expect(rect.minX >= 0 && rect.maxX <= MacKeyboardLayout.width + 0.001)
            #expect(rect.minY >= 0 && rect.maxY <= MacKeyboardLayout.height + 0.001)
        }
        for (index, rect) in rects.enumerated() {
            for other in rects[(index + 1)...] {
                let overlap = rect.intersection(other)
                #expect(overlap.isNull || overlap.width < 0.001 || overlap.height < 0.001, "\(rect) \(other)")
            }
        }
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(area - MacKeyboardLayout.width * MacKeyboardLayout.height) < 0.001)
        let pressable = keys.map(\.code).filter { $0 >= 0 }
        #expect(Set(pressable).count == pressable.count)
    }
}
