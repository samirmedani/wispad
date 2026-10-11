import Foundation
import Testing
@testable import WispadCore

/// « Coller la dernière dictée » : choix de la dictée, format, validation et persistance du raccourci, et son
/// déclenchement dans l'écoute du clavier, sans jamais toucher à fn.
struct PasteShortcutTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let ctrlOpt = ModifierMask.control | ModifierMask.option

    private func record(_ text: String, age: TimeInterval, status: InsertionStatus, id: String = UUID().uuidString) -> DictationRecord {
        DictationRecord(
            id: id,
            createdAt: now.addingTimeInterval(-age),
            finalText: text,
            rawText: text,
            durationSeconds: 1,
            wordCount: 2,
            provider: "fixture",
            model: "fixture",
            insertionStatus: status.rawValue
        )
    }

    // MARK: - Choix de la dictée

    @Test func theNewestUndeliveredDictationWinsOverANewerDeliveredOne() {
        let records = [
            record("collée ensuite", age: 30, status: .inserted),
            record("restée sans champ", age: 120, status: .noTarget, id: "attendue"),
            record("plus ancienne ratée", age: 300, status: .failed),
        ]
        #expect(PasteLastChoice.pick(records, now: now)?.id == "attendue")
    }

    @Test func everyUndeliveredStatusCounts() {
        for status in [InsertionStatus.pending, .noTarget, .failed, .refusedSecure] {
            let records = [record("livrée", age: 10, status: .pasteSent), record("prête", age: 60, status: status, id: "prête")]
            #expect(PasteLastChoice.pick(records, now: now)?.id == "prête", "statut \(status.rawValue)")
        }
    }

    @Test func withoutUndeliveredDictationTheLastDictationIsPasted() {
        let records = [
            record("ancienne", age: 600, status: .inserted),
            record("dernière", age: 20, status: .pasteSent, id: "dernière"),
        ]
        #expect(PasteLastChoice.pick(records, now: now)?.id == "dernière")
    }

    @Test func anOldUndeliveredDictationGivesWayToTheLastDictation() {
        let records = [
            record("dernière", age: 60, status: .inserted, id: "dernière"),
            record("vieille ratée", age: PasteLastChoice.undeliveredWindow + 1, status: .noTarget),
        ]
        #expect(PasteLastChoice.pick(records, now: now)?.id == "dernière")
    }

    @Test func cancelledEmptyAndUntranscribedDictationsAreNeverPasted() {
        let records = [
            record("annulée", age: 5, status: .cancelled),
            record("  ", age: 10, status: .noTarget),
            record("", age: 15, status: .transcriptionFailed),
            record("valable", age: 900, status: .inserted, id: "valable"),
        ]
        #expect(PasteLastChoice.pick(records, now: now)?.id == "valable")
        #expect(PasteLastChoice.pick([record("annulée", age: 5, status: .cancelled)], now: now) == nil)
        #expect(PasteLastChoice.pick([], now: now) == nil)
    }

    @Test func theStatusOnlyImprovesAfterANewPaste() {
        #expect(PasteLastChoice.updatedStatus(previous: InsertionStatus.noTarget.rawValue, outcome: .inserted) == .inserted)
        #expect(PasteLastChoice.updatedStatus(previous: InsertionStatus.pending.rawValue, outcome: .pasteSent) == .pasteSent)
        #expect(PasteLastChoice.updatedStatus(previous: InsertionStatus.pasteSent.rawValue, outcome: .inserted) == .inserted)
        // Une dictée déjà livrée ne redevient jamais « non insérée ».
        #expect(PasteLastChoice.updatedStatus(previous: InsertionStatus.inserted.rawValue, outcome: .noTarget) == nil)
        #expect(PasteLastChoice.updatedStatus(previous: InsertionStatus.pasteSent.rawValue, outcome: .failed) == nil)
        #expect(PasteLastChoice.updatedStatus(previous: InsertionStatus.inserted.rawValue, outcome: .pasteSent) == nil)
        #expect(PasteLastChoice.updatedStatus(previous: InsertionStatus.noTarget.rawValue, outcome: .noTarget) == nil)
    }

    // MARK: - Fin du collage, comme une dictée

    @Test func onlyAPasteThatReachedAFieldCountsAsDelivered() {
        #expect(InsertionStatus.inserted.delivered)
        #expect(InsertionStatus.pasteSent.delivered)
        for status in [InsertionStatus.pending, .noTarget, .failed, .refusedSecure, .cancelled, .transcriptionFailed] {
            #expect(!status.delivered, "statut \(status.rawValue)")
        }
    }

    @Test func aDeliveredPasteIsWatchedWithTheRulesOfADictation() {
        #expect(CorrectionWatch.shouldStart(status: .inserted, learnCorrections: true, selectionCommand: false, writtenByWispad: false))
        #expect(CorrectionWatch.shouldStart(status: .pasteSent, learnCorrections: true, selectionCommand: false, writtenByWispad: false))
        // Apprentissage coupé, sélection réécrite, essai écrit par Wispad, ou rien de livré : aucune surveillance.
        #expect(!CorrectionWatch.shouldStart(status: .inserted, learnCorrections: false, selectionCommand: false, writtenByWispad: false))
        #expect(!CorrectionWatch.shouldStart(status: .inserted, learnCorrections: true, selectionCommand: true, writtenByWispad: false))
        #expect(!CorrectionWatch.shouldStart(status: .inserted, learnCorrections: true, selectionCommand: false, writtenByWispad: true))
        for status in [InsertionStatus.noTarget, .failed, .refusedSecure, .cancelled] {
            #expect(!CorrectionWatch.shouldStart(status: status, learnCorrections: true, selectionCommand: false, writtenByWispad: false))
        }
    }

    @Test func aLaterDeliveryRecordsTheStatusAndTheTargetApp() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-paste-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try HistoryStore(path: path)
        try store.insert(record("sans champ", age: 10, status: .noTarget, id: "ratée"))
        try store.updateDelivery(id: "ratée", status: InsertionStatus.inserted.rawValue,
                                 targetApp: "Éditeur de test", targetBundle: "test.editeur", usageCategory: UsageKind.other.rawValue)
        var saved = try #require(try store.dictations().first)
        #expect(saved.insertionStatus == InsertionStatus.inserted.rawValue)
        #expect(saved.targetApp == "Éditeur de test")
        #expect(saved.targetBundle == "test.editeur")
        #expect(saved.usageCategory == UsageKind.other.rawValue)
        // App inconnue : celle déjà enregistrée reste.
        try store.updateDelivery(id: "ratée", status: InsertionStatus.inserted.rawValue,
                                 targetApp: nil, targetBundle: nil, usageCategory: nil)
        saved = try #require(try store.dictations().first)
        #expect(saved.targetApp == "Éditeur de test")
        #expect(saved.usageCategory == UsageKind.other.rawValue)
    }

    // MARK: - Format

    @Test func modifiersAreWrittenInTheMacOSOrder() {
        #expect(PasteShortcut.modifierSymbols(ModifierMask.command | ModifierMask.shift | ModifierMask.option | ModifierMask.control) == ["⌃", "⌥", "⇧", "⌘"])
        #expect(PasteShortcut.modifierSymbols(ctrlOpt) == ["⌃", "⌥"])
        #expect(PasteShortcut.modifierSymbols(ModifierMask.function).isEmpty)
    }

    @Test func carbonModifiersOfSystemShortcutsAreConverted() {
        // cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
        #expect(PasteShortcut.modifiers(carbon: 0x100) == ModifierMask.command)
        #expect(PasteShortcut.modifiers(carbon: 0x1800) == ctrlOpt)
        #expect(PasteShortcut.modifiers(carbon: 0x300) == ModifierMask.command | ModifierMask.shift)
    }

    @Test func fnIsNeverPartOfTheStoredModifiers() {
        let shortcut = PasteShortcut(keyCode: 9, modifiers: ctrlOpt | ModifierMask.function | 0x100)
        #expect(shortcut.modifiers == ctrlOpt)
    }

    // MARK: - Validation

    @Test func theDefaultIsControlOptionVAndValid() {
        #expect(PasteShortcut.standard.keyCode == PasteShortcut.vKeyCode)
        #expect(PasteShortcut.standard.modifiers == ctrlOpt)
        #expect(PasteShortcut.standard.enabled)
        #expect(PasteShortcutRules.problem(.standard) == nil)
        #expect(PasteShortcutRules.problem(.standard, dictation: (ChordMatcher.functionKeyCode, ModifierMask.function)) == nil)
    }

    @Test func knownPasteShortcutsOfMacOSAndAppsAreRefused() {
        let cmd = ModifierMask.command, shift = ModifierMask.shift, opt = ModifierMask.option
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 9, modifiers: cmd | shift)) == .reserved(.pastePlain))
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 9, modifiers: cmd | opt)) == .reserved(.finderMove))
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 9, modifiers: cmd)) == .reserved(.paste))
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 49, modifiers: cmd)) == .reserved(.spotlight))
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 21, modifiers: cmd | shift)) == .reserved(.screenshot))
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 53, modifiers: cmd | opt)) == .reserved(.forceQuit))
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 49, modifiers: ModifierMask.control)) == .reserved(.inputSource))
    }

    @Test func combinationsThatWouldTypeOrBelongToMenusAreRefused() {
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 9, modifiers: 0)) == .needsModifier)
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 9, modifiers: ModifierMask.shift)) == .needsModifier)
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 40, modifiers: ModifierMask.command)) == .commandOnly)
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 53, modifiers: ctrlOpt)) == .escape)
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 58, modifiers: ModifierMask.control)) == .modifierOnly)
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: ChordMatcher.functionKeyCode, modifiers: ctrlOpt)) == .functionKey)
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 400, modifiers: ctrlOpt)) == .modifierOnly)
    }

    @Test func systemAndDictationShortcutsAreRefused() {
        let candidate = PasteShortcut(keyCode: 11, modifiers: ctrlOpt)
        #expect(PasteShortcutRules.problem(candidate) == nil)
        #expect(PasteShortcutRules.problem(candidate, system: [PasteShortcut(keyCode: 11, modifiers: ctrlOpt, enabled: true)]) == .system)
        #expect(PasteShortcutRules.problem(candidate, system: [PasteShortcut(keyCode: 11, modifiers: ModifierMask.control)]) == nil)
        #expect(PasteShortcutRules.problem(candidate, dictation: (11, ctrlOpt)) == .sameAsDictation)
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 9, modifiers: ModifierMask.control | ModifierMask.command)) == .reserved(.pastePlain))
        #expect(PasteShortcutRules.problem(PasteShortcut(keyCode: 9, modifiers: ModifierMask.control | ModifierMask.shift)) == nil)
    }

    // MARK: - Persistance

    @Test func storedShortcutRoundTripsWithItsEnabledState() throws {
        let stored = PasteShortcut(keyCode: 11, modifiers: ctrlOpt, enabled: false)
        let data = try JSONEncoder().encode(stored)
        #expect(try JSONDecoder().decode(PasteShortcut.self, from: data) == stored)
    }

    @Test func missingOrUnreadableFieldsFallBackFieldByField() throws {
        let decoded = try JSONDecoder().decode(PasteShortcut.self, from: Data(#"{"keyCode": 11, "modifiers": "x"}"#.utf8))
        #expect(decoded.keyCode == 11)
        #expect(decoded.modifiers == PasteShortcut.standard.modifiers)
        #expect(decoded.enabled)
    }

    @Test func anInvalidStoredCombinationBecomesTheDefaultButKeepsItsChoice() {
        #expect(PasteShortcut.restored(nil) == .standard)
        let disabledInvalid = PasteShortcut(keyCode: 9, modifiers: 0, enabled: false)
        #expect(PasteShortcut.restored(disabledInvalid) == PasteShortcut(keyCode: 9, modifiers: ctrlOpt, enabled: false))
        let valid = PasteShortcut(keyCode: 11, modifiers: ctrlOpt, enabled: true)
        #expect(PasteShortcut.restored(valid) == valid)
    }

    // MARK: - Écoute du clavier

    private func key(_ phase: KeyPhase, _ keyCode: Int, _ flags: UInt64, autorepeat: Bool = false, time: Int = 1_000) -> KeyEvent {
        KeyEvent(phase: phase, keyCode: keyCode, flags: flags, autorepeat: autorepeat, time: time)
    }

    private var config: HotkeyConfig { HotkeyConfig(paste: .standard) }

    @Test func theShortcutPastesOnceAndIsSwallowed() {
        var logic = HotkeyLogic()
        let down = logic.handle(key(.down, 9, ctrlOpt), config: config)
        #expect(down.pasteLast)
        #expect(down.swallow)
        #expect(!down.isQuiet)
        #expect(down.effects.isEmpty)
        let repeated = logic.handle(key(.down, 9, ctrlOpt, autorepeat: true), config: config)
        #expect(!repeated.pasteLast)
        #expect(repeated.swallow)
        let up = logic.handle(key(.up, 9, ctrlOpt), config: config)
        #expect(up.swallow)
        #expect(!up.pasteLast)
        // V seul reste à l'app.
        #expect(!logic.handle(key(.down, 9, 0), config: config).swallow)
    }

    @Test func otherModifiersDisabledOrRecordingDoNothing() {
        var logic = HotkeyLogic()
        #expect(!logic.handle(key(.down, 9, ModifierMask.control), config: config).pasteLast)
        #expect(!logic.handle(key(.down, 9, ctrlOpt | ModifierMask.shift), config: config).pasteLast)
        #expect(!logic.handle(key(.down, 9, ctrlOpt), config: HotkeyConfig(paste: nil)).pasteLast)
        var disabled = PasteShortcut.standard
        disabled.enabled = false
        #expect(!logic.handle(key(.down, 9, ctrlOpt), config: HotkeyConfig(paste: disabled)).pasteLast)
        #expect(!logic.handle(key(.down, 9, ctrlOpt), config: HotkeyConfig(recording: true, paste: .standard)).pasteLast)
    }

    @Test func holdingFnNeverTriggersThePasteAndTheDictationKeepsWorking() {
        var logic = HotkeyLogic()
        // fn enfoncé (dictée en maintien) : ⌃⌥V n'est pas le raccourci, la frappe va au raccourci de dictée.
        _ = logic.handle(key(.flags, ChordMatcher.functionKeyCode, ModifierMask.function, time: 1_000), config: config)
        #expect(logic.chordDown)
        let pressed = logic.handle(key(.down, 9, ctrlOpt | ModifierMask.function, time: 1_050), config: config)
        #expect(!pressed.pasteLast)
        // Appui simple sur fn, puis le raccourci : aucune dictée, seulement le collage.
        var idle = HotkeyLogic()
        let fnDown = idle.handle(key(.flags, ChordMatcher.functionKeyCode, ModifierMask.function, time: 2_000), config: config)
        let fnUp = idle.handle(key(.flags, ChordMatcher.functionKeyCode, 0, time: 2_060), config: config)
        #expect(fnDown.effects.isEmpty)
        #expect(fnUp.effects.isEmpty)
        let paste = idle.handle(key(.down, 9, ctrlOpt, time: 2_500), config: config)
        #expect(paste.pasteLast)
        #expect(paste.effects.isEmpty)
        #expect(paste.pressedAt == nil)
    }

    @Test func arrowKeysKeepWorkingDespiteTheirFnFlag() {
        let shortcut = PasteShortcut(keyCode: 125, modifiers: ctrlOpt)
        #expect(shortcut.matches(keyCode: 125, flags: ctrlOpt | ModifierMask.function))
        #expect(!PasteShortcut.standard.matches(keyCode: 9, flags: ctrlOpt | ModifierMask.function))
    }

    @Test func aLostReleaseNeverSwallowsTheNextPlainKeystroke() {
        var logic = HotkeyLogic()
        _ = logic.handle(key(.down, 9, ctrlOpt), config: config)
        // Relâchement perdu (écoute coupée) : V tapé ensuite atteint l'app.
        let typed = logic.handle(key(.down, 9, 0), config: config)
        #expect(!typed.swallow)
        #expect(!typed.pasteLast)
    }

    // MARK: - Nature du champ

    @Test func focusedFieldKindRecognisesTextAndClearlyTextlessElements() {
        #expect(FocusedField.kind(role: "AXTextArea", hasTextCursor: false, bundleID: nil) == .text)
        #expect(FocusedField.kind(role: "AXGroup", hasTextCursor: true, bundleID: nil) == .text)
        #expect(FocusedField.kind(role: "AXList", hasTextCursor: false, bundleID: nil) == .notText)
        #expect(FocusedField.kind(role: "AXButton", hasTextCursor: false, bundleID: nil) == .notText)
        // Conteneurs et cas illisibles : on ne conclut pas (Electron, terminaux GPU, tableurs).
        #expect(FocusedField.kind(role: "AXGroup", hasTextCursor: false, bundleID: nil) == .unknown)
        #expect(FocusedField.kind(role: "AXWindow", hasTextCursor: false, bundleID: nil) == .unknown)
        #expect(FocusedField.kind(role: "AXTable", hasTextCursor: false, bundleID: nil) == .unknown)
        #expect(FocusedField.kind(role: nil, hasTextCursor: false, bundleID: nil) == .unknown)
        // Le Finder n'a pas de saisie hors de ses champs : bureau ou fenêtre sans champ = aucun champ.
        #expect(FocusedField.kind(role: nil, hasTextCursor: false, bundleID: "com.apple.finder") == .notText)
        #expect(FocusedField.kind(role: "AXScrollArea", hasTextCursor: false, bundleID: "com.apple.finder") == .notText)
        #expect(FocusedField.kind(role: "AXTextField", subrole: "AXSearchField", hasTextCursor: true, bundleID: "com.apple.finder") == .text)
    }

    @Test func pasteStatusNeedsTextlessFocusBeforeAndAfter() {
        #expect(FocusedField.status(confirmed: true, kinds: [.notText]) == .inserted)
        #expect(FocusedField.status(confirmed: false, kinds: [.notText]) == .noTarget)
        #expect(FocusedField.status(confirmed: false, kinds: [.notText, .unknown]) == .noTarget)
        #expect(FocusedField.status(confirmed: false, kinds: [.notText, .text]) == .pasteSent)
        #expect(FocusedField.status(confirmed: false, kinds: [.unknown]) == .pasteSent)
        #expect(FocusedField.status(confirmed: false, kinds: [.text]) == .pasteSent)
    }
}
