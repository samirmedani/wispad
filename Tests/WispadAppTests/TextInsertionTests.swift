import AppKit
import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
private final class InsertionFixture {
    let board = NSPasteboard(name: .init("wispad-insertion-" + UUID().uuidString))
    let context = DictationContext()
    var field = InsertionField(element: AXUIElementCreateApplication(42_424), value: "Avant ", before: "Avant ",
                               role: "AXTextArea", hasTextCursor: true, selection: NSRange(location: 6, length: 0))
    var pid: pid_t? = 42_424
    var keys = 0
    var reads = 0
    var sent = 0
    var deliver = true
    var modifiers = true
    var hold = 0.0
    var events: [String] = []
    var system: InsertionSystem {
        var s = InsertionSystem()
        s.trusted = { true }
        s.frontmostPID = { self.pid }
        s.bundleID = { _ in "com.google.Chrome" }
        s.secureInput = { false }
        s.modifiersReleased = { self.modifiers }
        s.read = { _ in self.reads += 1; return self.field }
        s.postPaste = { _ in
            self.keys += 1
            self.events.append("paste")
            if self.deliver { self.field.value = "Avant " + (self.board.string(forType: .string) ?? "") }
            return true
        }
        s.locate = { _ in self.events.append("locate"); return CGRect(x: 100, y: 40, width: 600, height: 80) }
        s.pasteboard = board
        s.confirmationLimit = 0.09
        s.clipboardHold = hold
        return s
    }
    init() {
        context.pid = pid
        board.setString("Copie conservée", forType: .string)
    }
    func insert(_ text: String = "Bonjour.", system custom: InsertionSystem? = nil) async -> InsertionStatus {
        await TextInserter.insert(text, context: context, didSendPaste: { self.sent += 1 }, system: custom ?? system)
    }
    func dispose() { board.releaseGlobally() }
}

@MainActor
@Suite(.serialized)
struct TextInsertionTests {
    @Test func aConfirmedPasteRestoresTheClipboardAtOnce() async {
        let f = InsertionFixture(); defer { f.dispose() }
        #expect(await f.insert() == .inserted)
        #expect(f.field.value == "Avant Bonjour.")
        #expect(f.keys == 1 && f.sent == 1)
        #expect(f.board.string(forType: .string) == "Copie conservée")
    }

    /// Régression du 13 octobre 2026 : texte absent d'un champ lisible. C'est un échec à signaler, sans second envoi.
    @Test func aReadableFieldLeftUnchangedIsARealFailure() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.deliver = false
        #expect(await f.insert() == .failed)
        #expect(f.keys == 1)
    }

    /// Codex et les apps Electron n'exposent pas leur champ : le collage est envoyé, sans alerte à chaque dictée.
    @Test func anUnreadableFieldIsSentWithoutAlert() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.field = InsertionField(); f.deliver = false
        #expect(await f.insert() == .pasteSent)
        #expect(f.keys == 1)
    }

    /// Une app occupée lit le presse-papiers tard : sans confirmation, la dictée y reste le temps prévu.
    @Test func aSlowAppStillFindsTheDictationOnTheClipboard() async throws {
        let f = InsertionFixture(); defer { f.dispose() }
        f.field = InsertionField(); f.deliver = false; f.hold = 0.25
        #expect(await f.insert() == .pasteSent)
        #expect(f.board.string(forType: .string) == "Bonjour.")
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(f.board.string(forType: .string) == "Copie conservée")
    }

    @Test func theNextInsertionWaitsForTheClipboardToBeGivenBack() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.field = InsertionField(); f.deliver = false; f.hold = 0.2
        var seen: [String?] = []
        var system = f.system
        system.postPaste = { _ in seen.append(f.board.string(forType: .string)); return true }
        #expect(await f.insert("Premier.", system: system) == .pasteSent)
        #expect(await f.insert("Second.", system: system) == .pasteSent)
        #expect(seen == ["Premier.", "Second."])
    }

    @Test func heldModifiersDoNotTurnTheRecoveryShortcutIntoAnotherCommand() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.modifiers = false
        #expect(await f.insert() == .failed)
        #expect(f.keys == 0 && f.sent == 0)
    }

    @Test func failureToSendIsStillAnActualFailure() async {
        let f = InsertionFixture(); defer { f.dispose() }
        var system = f.system
        system.postPaste = { _ in false }
        #expect(await f.insert(system: system) == .failed)
        #expect(f.sent == 0)
        #expect(f.board.string(forType: .string) == "Copie conservée")
    }

    @Test func changingAppsOrEnteringASecureFieldNeverWrites() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.pid = 42_425
        #expect(await f.insert() == .noTarget)
        f.pid = 42_424; f.field.isSecure = true
        #expect(await f.insert() == .refusedSecure)
        #expect(f.keys == 0)
    }

    @Test func aFocusChangeWhileReadingDoesNotStealTheForeground() async {
        let f = InsertionFixture(); defer { f.dispose() }
        var system = f.system
        system.read = { _ in f.pid = 42_425; return f.field }
        #expect(await f.insert(system: system) == .noTarget)
        #expect(f.keys == 0)
    }

    @Test func aWebComponentRecreatedAfterInputIsReadAgain() async {
        let f = InsertionFixture(); defer { f.dispose() }
        var system = f.system
        system.postPaste = { _ in
            f.field.element = AXUIElementCreateApplication(42_426)
            f.field.value = "Avant " + (f.board.string(forType: .string) ?? "")
            return true
        }
        #expect(await f.insert(system: system) == .inserted)
    }

    @Test func movingToAnotherFieldContainingTheSamePhraseDoesNotConfirmThePaste() async {
        let f = InsertionFixture(); defer { f.dispose() }
        var system = f.system
        system.postPaste = { _ in
            f.field.element = AXUIElementCreateApplication(42_426)
            f.field.value = "Ancien brouillon Bonjour."
            return true
        }
        // Ni confirmé, ni échec prouvé : le champ observé n'est plus celui du collage.
        #expect(await f.insert(system: system) == .pasteSent)
    }

    @Test func replacingASelectionWithTheSameBeginningIsConfirmed() async {
        let f = InsertionFixture(); defer { f.dispose() }
        let prefix = "Une phrase suffisamment longue pour garder le même début et "
        f.field.value = prefix + "lundi."
        f.field.before = ""
        f.field.selection = NSRange(location: 0, length: (f.field.value! as NSString).length)
        var system = f.system
        system.postPaste = { _ in f.field.value = f.board.string(forType: .string); return true }
        #expect(await f.insert(prefix + "mardi.", system: system) == .inserted)
    }

    @Test func aRecreatedRichEditorMayNormalizePunctuationAndSpacing() async {
        let f = InsertionFixture(); defer { f.dispose() }
        var system = f.system
        system.postPaste = { _ in
            f.field.element = AXUIElementCreateApplication(42_426)
            f.field.value = "Avant J’ai\u{00A0}fini."
            return true
        }
        #expect(await f.insert("J'ai fini.", system: system) == .inserted)
    }

    @Test(arguments: [true, false])
    func replacingIdenticalSelectedTextNeedsTheSelectionToCollapse(delivered: Bool) async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.field.value = "Bonjour."; f.field.before = ""
        f.field.selection = NSRange(location: 0, length: 8)
        var system = f.system
        system.postPaste = { _ in
            if delivered { f.field.selection = NSRange(location: 8, length: 0) }
            return true
        }
        #expect(await f.insert(system: system) == (delivered ? .inserted : .failed))
    }

    @Test func punctuationOnlyInsertionIsConfirmedAtTheCursor() async {
        let f = InsertionFixture(); defer { f.dispose() }
        #expect(await f.insert("!") == .inserted)
    }

    @Test func anUnreadableBaselineDoesNotTurnAReadbackIntoAFailure() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.field.value = nil
        var system = f.system
        system.postPaste = { _ in f.field.value = "Valeur partielle"; return true }
        #expect(await f.insert(system: system) == .pasteSent)
    }

    /// La place du champ est lue après l'envoi : le texte ne l'attend pas, la bulle s'en sert pour ses messages.
    @Test func theInputZoneIsReadAfterThePaste() async throws {
        InputZoneTracker.reset()
        let f = InsertionFixture(); defer { f.dispose() }
        #expect(await f.insert() == .inserted)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(f.events.first == "paste")
        #expect(f.events.contains("locate"))
        #expect(InputZoneTracker.zone(frontmost: 42_424) == CGRect(x: 100, y: 40, width: 600, height: 80))
        #expect(InputZoneTracker.zone(frontmost: 42_425) == nil)
        InputZoneTracker.reset()
    }

    @Test func concurrentEntryPointsCannotOverwriteEachOthersClipboard() async throws {
        let f = InsertionFixture(); defer { f.dispose() }
        let entered = AsyncResult<Void>(), release = AsyncResult<Void>()
        var system = f.system
        system.postPaste = { _ in
            f.keys += 1
            let expected = f.board.string(forType: .string)
            entered.resolve(.success(()))
            if f.keys == 1 { try? await release.value() }
            #expect(f.board.string(forType: .string) == expected)
            f.field.value = "Avant " + (expected ?? "")
            return true
        }
        let first = Task { await TextInserter.insert("Premier.", context: f.context, system: system) }
        try await entered.value()
        let second = Task { await TextInserter.insert("Second.", context: f.context, system: system) }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(f.keys == 1)
        release.resolve(.success(()))
        #expect(await first.value == .inserted)
        #expect(await second.value == .inserted)
        #expect(f.keys == 2)
        #expect(f.board.string(forType: .string) == "Copie conservée")
    }

    /// ⌘V comme au clavier : ⌘ enfoncée, V, puis ⌘ relâchée ; marqués pour l'écoute du clavier de Wispad.
    @Test func pasteEventsPressCommandAroundV() throws {
        let events = try #require(TextInserter.pasteEvents())
        let v = Int64(KeyboardLayout.keyCode(for: "v") ?? 9)
        // ⌘ part comme sur un vrai clavier : changement de modificateur, puis V avec ⌘, puis ⌘ relâchée.
        #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [0x37, v, v, 0x37])
        #expect(events.prefix(3).allSatisfy { $0.flags == .maskCommand })
        #expect(events.last?.flags.contains(.maskCommand) == false)
        for event in events {
            #expect(event.getIntegerValueField(.eventSourceUserData) == KeyboardTap.syntheticMarker)
        }
    }

    /// Wispad au premier plan : sa fenêtre n'est jamais lue par l'accessibilité, surtout pas hors du fil principal,
    /// où ces lectures se font dans son propre processus et font recalculer SwiftUI (plantage du 13 octobre 2026).
    @Test func ownWindowIsNeverReadByAccessibility() async {
        let own = ProcessInfo.processInfo.processIdentifier
        let nothingRead = await Task.detached {
            ContextProbe.focusedElement(pid: own) == nil
                && ContextProbe.inputLocation(pid: own).zone == nil
                && WindowTextProbe.read(pid: own).context == nil
        }.value
        #expect(nothingRead)
    }
}
