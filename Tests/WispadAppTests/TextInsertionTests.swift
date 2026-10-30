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
        s.appName = { _ in "Navigateur fictif" }
        s.secureInput = { false }
        s.modifiersStillHeld = { self.modifiers ? 0 : ModifierMask.shift }
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
@Suite(.serialized, .inputZoneExclusive)
struct TextInsertionTests {
    @Test func aConfirmedPasteRestoresTheClipboardAtOnce() async {
        let f = InsertionFixture(); defer { f.dispose() }
        #expect(await f.insert() == .inserted)
        #expect(f.field.value == "Avant Bonjour.")
        #expect(f.keys == 1 && f.sent == 1)
        #expect(f.board.string(forType: .string) == "Copie conservée")
    }

    /// Dictée démarrée sur le bureau, puis curseur placé dans une autre app : c'est là qu'elle doit arriver.
    @Test func startingWithoutAFieldFollowsTheNewDestination() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.context.appName = "Bureau fictif"
        f.context.bundleID = "com.example.fictif.bureau"
        f.pid = 42_425
        var readPIDs: [pid_t] = []
        var system = f.system
        system.read = { pid in readPIDs.append(pid); return f.field }
        #expect(await f.insert(system: system) == .inserted)
        #expect(f.keys == 1 && f.sent == 1)
        #expect(readPIDs == [42_425, 42_425])
        #expect(f.context.pid == 42_425)
        #expect(f.context.bundleID == "com.google.Chrome")
        #expect(f.context.appName == "Navigateur fictif")
        #expect(f.board.string(forType: .string) == "Copie conservée")
    }

    @Test func startingOnAPageThenChoosingAFieldInTheSameAppPastes() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.context.apply(FieldSnapshot(element: AXUIElementCreateApplication(51_515)))
        #expect(await f.insert() == .inserted)
        #expect(f.keys == 1 && f.reads == 2)
        #expect(!f.context.leftTextField)
    }

    @Test func anUnreadableEditorCanAlsoBeChosenAfterTheStart() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.pid = 42_425
        f.field = InsertionField(); f.deliver = false
        #expect(await f.insert() == .pasteSent)
        #expect(f.keys == 1 && f.sent == 1)
        #expect(f.context.pid == 42_425)
    }

    @Test func cancellingWhileReadingTheNewDestinationNeverPastes() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.pid = 42_425
        var allowed = true
        var system = f.system
        system.read = { _ in allowed = false; return f.field }
        #expect(await TextInserter.insert("Bonjour.", context: f.context, shouldProceed: { allowed }, system: system) == .cancelled)
        #expect(f.keys == 0)
        #expect(f.board.string(forType: .string) == "Copie conservée")
    }

    /// La nouvelle destination subit les mêmes contrôles ; aucune touche vers un mot de passe ou une liste.
    @Test(arguments: [true, false])
    func aNewDestinationStillRequiresASafeField(secure: Bool) async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.pid = 42_425
        f.field = secure
            ? InsertionField(element: AXUIElementCreateApplication(61_616), isSecure: true)
            : InsertionField(element: AXUIElementCreateApplication(61_616), role: "AXList")
        #expect(await f.insert() == (secure ? .refusedSecure : .noTarget))
        #expect(f.keys == 0 && f.sent == 0)
        #expect(f.board.string(forType: .string) == "Copie conservée")
    }

    @Test func aSelectionKeepsItsOriginalAppEvenWithoutAReadableTextRole() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.context.selectedText = "Une phrase fictive à reformuler."
        f.pid = 42_425
        #expect(await f.insert() == .noTarget)
        #expect(f.keys == 0 && f.reads == 0)
    }

    /// Choisir la destination ne permet pas de la suivre indéfiniment pendant une lecture AX lente.
    @Test func changingAppsDuringTheDestinationReadNeverPastes() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.pid = 42_425
        var system = f.system
        system.read = { _ in f.reads += 1; f.pid = 42_426; return f.field }
        #expect(await f.insert(system: system) == .noTarget)
        #expect(f.reads == 1 && f.keys == 0)
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

    /// Curseur sorti du champ pendant la dictée : elle avait commencé dans un champ de texte, le focus est maintenant
    /// sur la page (lisible, sans texte). Aucun ⌘V dans le vide : le texte reste prêt, et la bulle dit pourquoi.
    @Test func leavingTheFieldDuringTheDictationKeepsTheTextReady() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.context.element = AXUIElementCreateApplication(51_515)
        f.context.startedInTextField = true
        f.field = InsertionField(element: AXUIElementCreateApplication(61_616), role: "AXWebArea")
        #expect(await f.insert() == .noTarget)
        #expect(f.keys == 0 && f.sent == 0)
        #expect(f.context.leftTextField)
        #expect(f.board.string(forType: .string) == "Copie conservée")
        #expect(DictationCoordinator.readyReason(for: .noTarget, leftTextField: f.context.leftTextField) == "Le curseur a quitté le champ")
        InputZoneTracker.reset()
    }

    /// Sans preuve que le curseur a quitté un vrai champ, le collage part comme avant : focus illisible (Electron),
    /// dictée commencée hors d'un champ de texte, ou même élément qu'au début.
    @Test func noProofOfLeavingTheFieldStillPastes() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.deliver = false
        f.context.startedInTextField = true
        f.field = InsertionField()
        #expect(await f.insert() == .pasteSent)

        f.context.startedInTextField = false
        f.field = InsertionField(element: AXUIElementCreateApplication(61_616), role: "AXWebArea")
        #expect(await f.insert() == .pasteSent)

        let page = AXUIElementCreateApplication(61_616)
        f.context.startedInTextField = true
        f.context.element = page
        f.field = InsertionField(element: page, role: "AXGroup")
        #expect(await f.insert() == .pasteSent)
        #expect(f.keys == 3)
        #expect(!f.context.leftTextField)
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
        // La bulle dira quelle touche était tenue, et sa carte évitera le champ, repéré même sans ⌘V.
        #expect(f.context.heldModifiers == ModifierMask.shift)
        #expect(f.events == ["locate"])
        #expect(InputZoneTracker.zone(frontmost: f.pid) == CGRect(x: 100, y: 40, width: 600, height: 80))
        #expect(f.board.string(forType: .string) == "Copie conservée")
        InputZoneTracker.reset()
    }

    @Test func theReadyCardNamesTheHeldKeys() {
        #expect(DictationCoordinator.readyMessage(for: .failed, heldModifiers: ModifierMask.shift)
                == "Touche ⇧ maintenue : le texte est prêt")
        #expect(DictationCoordinator.readyMessage(for: .failed, heldModifiers: ModifierMask.command | ModifierMask.shift)
                == "Touches ⇧⌘ maintenues : le texte est prêt")
        #expect(DictationCoordinator.readyMessage(for: .failed, heldModifiers: ModifierMask.function)
                == "Touche fn maintenue : le texte est prêt")
        #expect(DictationCoordinator.readyMessage(for: .failed, heldModifiers: ModifierMask.option | ModifierMask.function)
                == "Touches ⌥ fn maintenues : le texte est prêt")
        #expect(DictationCoordinator.readyMessage(for: .failed) == "Le texte n'est pas arrivé dans le champ")
        // La carte a déjà le titre « Texte prêt à copier » : sa ligne ne le répète pas.
        #expect(DictationCoordinator.readyReason(for: .failed, heldModifiers: ModifierMask.shift) == "Touche ⇧ maintenue")
        #expect(DictationCoordinator.readyReason(for: .noTarget) == "Pas de champ où écrire")
        #expect(DictationCoordinator.readyReason(for: .pending, accessibilityRefused: true) == "Accessibilité non autorisée")
    }

    @Test func failureToSendIsStillAnActualFailure() async {
        let f = InsertionFixture(); defer { f.dispose() }
        var system = f.system
        system.postPaste = { _ in false }
        #expect(await f.insert(system: system) == .failed)
        #expect(f.sent == 0)
        #expect(f.board.string(forType: .string) == "Copie conservée")
    }

    /// Accessibilité retirée dans Réglages Système : ni ⌘V ni lecture du champ, le presse-papiers reste tel quel, et
    /// la cause est notée pour que la bulle la dise.
    @Test func withoutAccessibilityNothingIsSentAndTheCauseIsKept() async {
        let f = InsertionFixture(); defer { f.dispose() }
        var system = f.system
        system.trusted = { false }
        #expect(await f.insert(system: system) == .failed)
        #expect(f.keys == 0 && f.reads == 0 && f.sent == 0)
        #expect(f.context.accessibilityRefused)
        #expect(f.board.string(forType: .string) == "Copie conservée")
        // Rendue : le collage repart normalement.
        let context = DictationContext()
        context.pid = f.pid
        #expect(await TextInserter.insert("Bonjour.", context: context, system: f.system) == .inserted)
        #expect(!context.accessibilityRefused)
        #expect(f.keys == 1)
    }

    @Test func changingAppsOrEnteringASecureFieldNeverWrites() async {
        let f = InsertionFixture(); defer { f.dispose() }
        f.context.startedInTextField = true
        f.pid = 42_425
        #expect(await f.insert() == .noTarget)
        f.pid = 42_424; f.field.isSecure = true
        #expect(await f.insert() == .refusedSecure)
        #expect(f.keys == 0)
    }

    /// La saisie sécurisée tenue par une autre app (Chrome et un champ de mot de passe) ne bloque pas le collage ici.
    @Test func secureInputHeldByAnotherAppDoesNotBlockThePaste() async {
        let f = InsertionFixture(); defer { f.dispose() }
        var system = f.system
        system.secureInput = { true }
        system.secureInputHolder = { 69_232 }
        #expect(await f.insert(system: system) == .inserted)
        #expect(f.keys == 1)
    }

    /// Tenue par l'app visée, ou par une app que macOS ne nomme pas : un champ illisible peut être un mot de passe,
    /// rien n'est collé ; un champ lu, non sécurisé, avec curseur, reçoit le texte.
    @Test func secureInputHeldByTheTargetOrAnUnknownAppStillProtects() async {
        let f = InsertionFixture(); defer { f.dispose() }
        var system = f.system
        system.secureInput = { true }
        system.secureInputHolder = { nil }
        #expect(await f.insert(system: system) == .refusedSecure)
        system.secureInputHolder = { 42_424 }
        let readable = f.field
        f.field = InsertionField()
        #expect(await f.insert(system: system) == .refusedSecure)
        #expect(f.keys == 0)
        f.field = readable
        #expect(await f.insert(system: system) == .inserted)
        #expect(f.keys == 1)
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

    /// L'app visée ne donne pas son champ (inactive, lente) et Wispad est passé au premier plan entre-temps : fenêtre
    /// ouverte pendant la surveillance des corrections, la confirmation d'un collage ou la lecture de la zone de saisie.
    /// Le repli sur l'élément système ne lui pose jamais la question : elle lui serait servie dans son propre
    /// processus, hors du fil principal, comme lors du plantage du 13 octobre 2026.
    @Test func systemFallbackNeverAsksWispadItself() async {
        let own = ProcessInfo.processInfo.processIdentifier
        let frontmostApps: [pid_t?] = [own, own + 1, nil]
        let questions = await Task.detached { () -> [Bool] in
            frontmostApps.map { (frontmost: pid_t?) -> Bool in
                var asked = false
                _ = ContextProbe.systemFocusedElement(frontmost: { frontmost }, ask: { asked = true; return nil })
                return asked
            }
        }.value
        // Wispad au premier plan : rien n'est demandé. Une autre app, ou une app inconnue : la question part, comme avant.
        #expect(questions == [false, true, true])
    }
}
