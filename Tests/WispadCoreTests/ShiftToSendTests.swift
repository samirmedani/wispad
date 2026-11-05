import Testing
@testable import WispadCore

/// Maj pour envoyer : Maj tenue quand la dictée s'arrête demande Entrée après le collage. Au repos, ⇧ + fn ne démarre rien.
struct ShiftToSendTests {
    private let fn = ChordMatcher.functionKeyCode
    private let shiftKey = 56
    private let fnFlag = ModifierMask.function
    private let shift = ModifierMask.shift

    private func flags(_ keyCode: Int, _ flags: UInt64, at time: Int) -> KeyEvent {
        KeyEvent(phase: .flags, keyCode: keyCode, flags: flags, time: time)
    }

    private func config(capturing: Bool) -> HotkeyConfig {
        HotkeyConfig(capturing: capturing)
    }

    /// Maintien démarré : fn enfoncée à 1 000 ms, seuil passé à 1 200 ms.
    private func holding() -> HotkeyLogic {
        var logic = HotkeyLogic()
        _ = logic.handle(flags(fn, fnFlag, at: 1_000), config: config(capturing: false))
        let started = logic.tick(at: 1_200, keyStillDown: true)
        #expect(started.effects == [.startPushToTalk])
        return logic
    }

    /// Mains libres démarré par un double appui.
    private func handsFree() -> HotkeyLogic {
        var logic = HotkeyLogic()
        _ = logic.handle(flags(fn, fnFlag, at: 1_000), config: config(capturing: false))
        _ = logic.handle(flags(fn, 0, at: 1_050), config: config(capturing: false))
        let started = logic.handle(flags(fn, fnFlag, at: 1_150), config: config(capturing: false))
        #expect(started.effects == [.startToggle])
        _ = logic.handle(flags(fn, 0, at: 1_200), config: config(capturing: true))
        return logic
    }

    @Test func shiftDuringAHoldStopsAndAsksToSend() {
        var logic = holding()
        let output = logic.handle(flags(shiftKey, fnFlag | shift, at: 2_000), config: config(capturing: true))
        #expect(output.effects == [.stopPushToTalk])
        #expect(output.sendAfterPaste)
    }

    @Test func aPlainReleaseNeverSends() {
        var logic = holding()
        let output = logic.handle(flags(fn, 0, at: 2_000), config: config(capturing: true))
        #expect(output.effects == [.stopPushToTalk])
        #expect(!output.sendAfterPaste)
    }

    @Test func shiftAndFnStopHandsFreeAndAskToSend() {
        var logic = handsFree()
        // Maj d'abord : rien ne change, la dictée continue.
        let shiftDown = logic.handle(flags(shiftKey, shift, at: 3_000), config: config(capturing: true))
        #expect(shiftDown.effects.isEmpty)
        let output = logic.handle(flags(fn, fnFlag | shift, at: 3_100), config: config(capturing: true))
        #expect(output.effects == [.stopToggle])
        #expect(output.sendAfterPaste)
        #expect(output.swallow)
        // Relâchements : aucune nouvelle dictée.
        let fnUp = logic.handle(flags(fn, shift, at: 3_200), config: config(capturing: false))
        let shiftUp = logic.handle(flags(shiftKey, 0, at: 3_300), config: config(capturing: false))
        #expect(fnUp.effects.isEmpty && shiftUp.effects.isEmpty)
        #expect(logic.tick(at: 4_000, keyStillDown: false).effects.isEmpty)
        #expect(logic.engine.isIdle)
    }

    @Test func fnAloneStopsHandsFreeWithoutSending() {
        var logic = handsFree()
        let output = logic.handle(flags(fn, fnFlag, at: 3_000), config: config(capturing: true))
        #expect(output.effects == [.stopToggle])
        #expect(!output.sendAfterPaste)
    }

    @Test func shiftAndFnAtRestStartNothing() {
        // Sélection ⇧ fn ← répétée : ni maintien, ni double appui (fn reste avalée comme toujours).
        var logic = HotkeyLogic()
        var time = 1_000
        for _ in 0..<3 {
            let down = logic.handle(flags(fn, fnFlag | shift, at: time), config: config(capturing: false))
            #expect(down.effects.isEmpty)
            _ = logic.tick(at: time + 300, keyStillDown: true)
            let up = logic.handle(flags(fn, shift, at: time + 400), config: config(capturing: false))
            #expect(up.effects.isEmpty)
            time += 500
        }
        #expect(logic.tick(at: time + 1_000, keyStillDown: false).effects.isEmpty)
        #expect(logic.engine.isIdle)
    }

    @Test func aShortcutThatAlreadyUsesShiftIsLeftAlone() {
        let event = flags(fn, fnFlag | shift, at: 1_000)
        var config = HotkeyConfig(keyCode: fn, modifierFlags: fnFlag | shift, capturing: true)
        #expect(HotkeyLogic.shortcutFlags(event, config: config) == event.flags)
        config.modifierFlags = fnFlag
        #expect(HotkeyLogic.shortcutFlags(event, config: config) == fnFlag)
        config.recording = true
        #expect(HotkeyLogic.shortcutFlags(event, config: config) == event.flags)
    }
}
