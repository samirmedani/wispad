import AppKit
import ApplicationServices
import Carbon
import Foundation
import WispadCore
import os

/// État éphémère du champ. Son contenu ne quitte jamais la mémoire de l'insertion.
struct InsertionField: @unchecked Sendable {
    var element: AXUIElement?
    var isSecure = false
    var value: String?
    var before: String?
    var role: String?
    var subrole: String?
    var hasTextCursor = false
    var selection: NSRange?

    static func read(pid: pid_t) -> InsertionField {
        guard let element = ContextProbe.focusedElement(pid: pid) else { return InsertionField() }
        guard !ContextProbe.isSecure(element) else { return InsertionField(element: element, isSecure: true) }
        let selection = ContextProbe.selectedRange(element)
        let value = ContextProbe.valueForCheck(element)
        let before: String?
        if let value, let selection, selection.location <= (value as NSString).length {
            let start = max(0, selection.location - 32)
            before = (value as NSString).substring(with: NSRange(location: start, length: selection.location - start))
        } else {
            before = ContextProbe.textBeforeCursor(element)
        }
        return InsertionField(
            element: element, value: value, before: before,
            role: ContextProbe.string(kAXRoleAttribute, element),
            subrole: ContextProbe.string(kAXSubroleAttribute, element),
            hasTextCursor: selection != nil, selection: selection
        )
    }

    func kind(bundleID: String?) -> FocusedFieldKind {
        if isSecure { return .text }
        return FocusedField.kind(role: role, subrole: subrole, hasTextCursor: hasTextCursor, bundleID: bundleID)
    }

    /// Un nouveau nœud AX n'est accepté que s'il contient l'édition attendue, typographie normalisée.
    /// Un autre champ déjà rempli avec une ancienne dictée ne suffit pas à confirmer.
    func confirmsReplacement(in after: InsertionField, inserted: String) -> Bool {
        guard InsertionCheck.matchesReplacement(before: value, selection: selection, after: after.value, inserted: inserted) else { return false }
        if value != after.value { return true }
        // Remplacer une sélection par le même texte est un succès si le curseur s'est bien déplacé à sa fin.
        guard let selection, selection.length > 0 else { return false }
        return after.selection == NSRange(location: selection.location + (inserted as NSString).length, length: 0)
    }

    func sameElement(as other: InsertionField) -> Bool {
        guard let element, let other = other.element else { return false }
        return CFEqual(element, other)
    }

    /// Champ actif de l'app, `seconds` au plus ; un champ vide sans réponse à temps. `reader` : la lecture, remplacée
    /// dans les tests.
    @MainActor static func read(pid: pid_t, within seconds: Double,
                                reader: @escaping @Sendable (pid_t) -> InsertionField = { InsertionField.read(pid: $0) })
        async -> InsertionField {
        let task = Task.detached(priority: .userInitiated) { reader(pid) }
        return await DictationCoordinator.value(of: task, within: seconds) ?? InsertionField()
    }
}

/// Frontières macOS remplaçables dans les tests, sans envoyer de touches aux apps de l'utilisateur.
@MainActor
struct InsertionSystem {
    var trusted: () -> Bool = { PermissionCenter.accessibilityTrusted(prompt: false) }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var bundleID: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var modifiersReleased: () async -> Bool = { await TextInserter.waitForModifierRelease() }
    var read: (pid_t) async -> InsertionField = { pid in
        await InsertionField.read(pid: pid, within: TextInserter.fieldReadLimit)
    }
    var pasteboard: NSPasteboard = .general
    /// Sur le fil principal : la touche V se cherche dans la disposition du clavier, que macOS n'autorise que là.
    var postPaste: @MainActor (pid_t) async -> Bool = { _ in TextInserter.postCommandV() }
    /// Zone de saisie lue après l'envoi, pour que les messages de la bulle ne la couvrent pas.
    var locate: (pid_t) async -> CGRect? = { pid in
        await ContextProbe.inputZone(pid: pid, within: TextInserter.fieldReadLimit)
    }
    var confirmationLimit: Double = TextInserter.confirmationLimit
    var clipboardHold: Double = TextInserter.clipboardHold
}

/// Dernière zone de saisie connue, par app : les messages de la bulle s'en écartent.
@MainActor
enum InputZoneTracker {
    private static var latest: (zone: CGRect, pid: pid_t, at: Date)?
    /// Au-delà, la fenêtre a pu bouger : la zone n'est plus fiable.
    static let lifetime: TimeInterval = 120

    static func note(_ zone: CGRect?, pid: pid_t) {
        latest = zone.map { ($0, pid, Date()) }
    }

    /// Zone de l'app au premier plan, si elle a été lue récemment.
    static func zone(frontmost pid: pid_t?) -> CGRect? {
        guard let latest, let pid, latest.pid == pid, Date().timeIntervalSince(latest.at) < lifetime else { return nil }
        return latest.zone
    }

    static func reset() { latest = nil }
}

@MainActor
enum TextInserter {
    private static let log = Logger.wispad("insertion")
    private struct Memory {
        var pid: pid_t
        var element: AXUIElement?
        var text: String
        var keystrokes: Int
        var at: Date
    }
    private static var last: Memory?
    /// Toutes les entrées (dictée, historique, bouton et raccourci) partagent le même presse-papiers.
    private static var tail: AsyncResult<Void>?
    static let fieldReadLimit = 0.3
    /// Relecture du champ après ⌘V. Elle suit l'envoi : le spectre de traitement a déjà disparu.
    static let confirmationLimit = 1.0
    /// Sans confirmation, le texte reste au presse-papiers au moins ce temps après ⌘V : une app occupée
    /// (page web chargée, Electron) peut lire le presse-papiers tard ; le restaurer avant ferait coller l'ancien contenu.
    static let clipboardHold = 1.5

    static func insert(
        _ text: String, context: DictationContext,
        shouldProceed: @escaping @MainActor () -> Bool = { true },
        didSendPaste: @escaping @MainActor () -> Void = {},
        system: InsertionSystem = InsertionSystem()
    ) async -> InsertionStatus {
        let previous = tail
        let done = AsyncResult<Void>()
        tail = done
        try? await previous?.value()
        var releasesLater = false
        defer { if !releasesLater { finishTurn(done) } }
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        if context.isSecure || system.secureInput() { return .refusedSecure }
        guard system.trusted() else {
            // Accessibilité retirée (ou jamais donnée) : ni ⌘V ni lecture du champ, le texte reste à copier.
            log.notice("collage retenu : accessibilité non autorisée")
            context.accessibilityRefused = true
            return .failed
        }
        guard let pid = context.pid ?? system.frontmostPID(), system.frontmostPID() == pid else {
            // Ne pas réactiver une ancienne app pendant que l'utilisateur écrit ailleurs.
            log.notice("collage retenu : app cible plus au premier plan")
            return .noTarget
        }
        guard await system.modifiersReleased() else {
            log.notice("collage retenu : touches modificatrices encore maintenues")
            return .failed
        }
        let bundle = system.bundleID(pid)
        let field = await system.read(pid)
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        guard system.frontmostPID() == pid else { return .noTarget }
        guard !field.isSecure, !system.secureInput() else { return .refusedSecure }
        let kind = field.kind(bundleID: bundle)
        guard kind != .notText else { return .noTarget }
        let memory = previousMemory(pid: pid, element: field.element)
        let joined = SmartJoin.adjust(text, before: SmartJoin.textBefore(
            read: field.before, previous: memory?.text, previousConfirmed: memory != nil
        ))
        let keystrokes = KeyboardTap.keystrokes
        guard let transaction = PasteboardTransaction(text: joined, pasteboard: system.pasteboard) else {
            log.notice("collage impossible : presse-papiers non modifiable")
            return .failed
        }
        guard shouldProceed(), !Task.isCancelled, system.frontmostPID() == pid, await system.postPaste(pid) else {
            transaction.restoreIfUnchanged()
            if !shouldProceed() || Task.isCancelled { return .cancelled }
            return system.frontmostPID() == pid ? .failed : .noTarget
        }
        let sentAt = Date()
        didSendPaste()
        // Où écrit l'utilisateur : lu après l'envoi, sans retarder le texte ni l'apparition de la bulle.
        let locate = system.locate
        Task { @MainActor in InputZoneTracker.note(await locate(pid), pid: pid) }
        let deadline = sentAt.addingTimeInterval(system.confirmationLimit)
        var unchangedTarget = false
        var confirmed = false
        repeat {
            // Relire immédiatement : une insertion déjà visible n'attend aucun minuteur.
            // Chaque lecture système est elle-même bornée à fieldReadLimit.
            guard system.frontmostPID() == pid else { break }
            let after = await system.read(pid)
            guard !after.isSecure else { break }
            // Un composant web peut recréer son nœud après input : le focus est relu à chaque fois.
            let sameTarget = field.sameElement(as: after)
            unchangedTarget = sameTarget && field.value != nil && after.value == field.value
            if field.confirmsReplacement(in: after, inserted: joined) ||
                ((sameTarget || field.element == nil) && InsertionCheck.confirms(before: field.value, after: after.value, inserted: joined)) {
                confirmed = true
                break
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        } while Date() < deadline
        // Même champ, toujours lisible et inchangé une seconde après ⌘V : le texte n'est pas arrivé.
        // Un champ illisible (apps Electron, éditeurs dessinés) ne prouve rien : collage envoyé, sans alerte.
        let status: InsertionStatus = confirmed ? .inserted : unchangedTarget ? .failed : .pasteSent
        if !confirmed {
            log.notice("collage non confirmé : champ_inchangé=\(unchangedTarget, privacy: .public) statut=\(status.rawValue, privacy: .public)")
        }
        // Un texte non confirmé ne doit jamais servir à inventer une espace à la dictée suivante.
        last = confirmed ? Memory(pid: pid, element: field.element, text: joined, keystrokes: keystrokes, at: Date()) : nil
        if confirmed {
            transaction.restoreIfUnchanged()
        } else {
            // Le statut part tout de suite ; le presse-papiers, lui, n'est rendu qu'après le délai de lecture.
            releasesLater = true
            let wait = max(0, system.clipboardHold - Date().timeIntervalSince(sentAt))
            Task { @MainActor in
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                transaction.restoreIfUnchanged()
                finishTurn(done)
            }
        }
        return status
    }

    private static func finishTurn(_ done: AsyncResult<Void>) {
        done.resolve(.success(()))
        if tail === done { tail = nil }
    }

    /// Un délai expiré est un échec récupérable, jamais une permission d'envoyer ⌃⌥⌘V.
    @discardableResult
    static func waitForModifierRelease(limit: Double = 0.8) async -> Bool {
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
        let deadline = Date().addingTimeInterval(limit)
        while !CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !Task.isCancelled
    }

    private static func previousMemory(pid: pid_t, element: AXUIElement?) -> Memory? {
        guard let last, last.pid == pid, Date().timeIntervalSince(last.at) < 30,
              last.keystrokes == KeyboardTap.keystrokes else { return nil }
        if let element, let previous = last.element, !CFEqual(element, previous) { return nil }
        return last
    }

    /// ⌘V comme au clavier : ⌘ enfoncée, V, puis ⌘ relâchée, envoyés au système (l'app au premier plan, vérifiée
    /// juste avant). Chrome et les apps Electron ignorent parfois un ⌘V adressé à leur processus ou porté par la
    /// seule touche V (régression du 13 octobre 2026 : texte absent du champ).
    @MainActor static func postCommandV() -> Bool {
        guard let events = pasteEvents() else { return false }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    /// Marqués : l'écoute du clavier de Wispad les laisse passer sans les prendre pour une frappe.
    @MainActor static func pasteEvents() -> [CGEvent]? {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = KeyboardTap.syntheticMarker
        let command: CGKeyCode = 0x37
        let key = KeyboardLayout.keyCode(for: "v") ?? 9
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) else { return nil }
        commandDown.flags = .maskCommand
        down.flags = .maskCommand
        up.flags = .maskCommand
        commandUp.flags = []
        return [commandDown, down, up, commandUp]
    }
}
