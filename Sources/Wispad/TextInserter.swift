import AppKit
import ApplicationServices
import Carbon
import Foundation
import WispadCore
import os

/// Champ visé au moment du collage, relu hors du fil principal.
private struct InsertionField: @unchecked Sendable {
    var element: AXUIElement?
    var isSecure = false
    var value: String?
    var before: String?
    /// Rôle d'accessibilité et curseur de texte : de quoi reconnaître un focus qui n'est sur aucun champ.
    var role: String?
    var subrole: String?
    var hasTextCursor = false

    static func read(pid: pid_t) -> InsertionField {
        guard let element = ContextProbe.focusedElement(pid: pid) else { return InsertionField() }
        guard !ContextProbe.isSecure(element) else { return InsertionField(element: element, isSecure: true) }
        return InsertionField(
            element: element,
            value: ContextProbe.valueForCheck(element),
            before: ContextProbe.textBeforeCursor(element),
            role: ContextProbe.string(kAXRoleAttribute, element),
            subrole: ContextProbe.string(kAXSubroleAttribute, element),
            hasTextCursor: ContextProbe.hasTextCursor(element)
        )
    }

    func kind(bundleID: String?) -> FocusedFieldKind {
        if isSecure { return .text }
        return FocusedField.kind(role: role, subrole: subrole, hasTextCursor: hasTextCursor, bundleID: bundleID)
    }
}

@MainActor
enum TextInserter {
    private static let log = Logger.wispad("insertion")

    /// Dernier collage de Wispad : raccorde la dictée suivante quand l'app tarde à exposer son texte.
    private struct Memory {
        var pid: pid_t
        var element: AXUIElement?
        var text: String
        var confirmed: Bool
        var keystrokes: Int
        var at: Date
    }
    private static var last: Memory?
    /// Lectures d'accessibilité bornées : une app qui construit encore son arbre (Chrome à la première dictée,
    /// mesuré le 9 octobre : 5,2 s) ne retarde ni le collage ni la dictée suivante. Au-delà, on colle sans.
    static let fieldReadLimit = 0.3
    static let confirmationLimit = 0.7

    /// Colle le texte dans l'app où la dictée a commencé, comme un Cmd+V de l'utilisateur, précédé d'une espace
    /// s'il suit directement un mot ou une ponctuation (deux dictées de suite). Le presse-papiers est restauré
    /// ensuite, sauf si quelqu'un l'a modifié entre-temps.
    static func insert(_ text: String, context: DictationContext, shouldProceed: @escaping @MainActor () -> Bool = { true }) async -> InsertionStatus {
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        let route = InsertionPlanner.route(
            isSecureField: context.isSecure,
            secureInputActive: false,
            accessibilityTrusted: PermissionCenter.accessibilityTrusted(prompt: false)
        )
        switch route {
        case .refuseSecure: return .refusedSecure
        case .keepOnly:
            log.notice("collage impossible : accessibilité non autorisée")
            return .failed
        case .paste: break
        }
        guard let pid = context.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            log.notice("collage impossible : aucune app cible")
            return .failed
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                log.notice("collage impossible : app cible fermée")
                return .failed
            }
            app.activate()
            for _ in 0..<12 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            log.notice("collage impossible : app cible pas au premier plan")
            return .failed
        }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        // Relu au dernier moment : le focus a pu changer pendant la transcription.
        let reading = Task.detached(priority: .userInitiated) { InsertionField.read(pid: pid) }
        let field = await DictationCoordinator.value(of: reading, within: fieldReadLimit) ?? InsertionField()
        // Nature du focus avant ⌘V, puis à chaque relecture : liste, bouton ou bureau du Finder = aucun champ.
        var kinds = [field.kind(bundleID: bundleID)]
        let secure = InsertionPlanner.route(
            isSecureField: field.isSecure,
            secureInputActive: IsSecureEventInputEnabled(),
            accessibilityTrusted: true
        )
        guard secure != .refuseSecure else { return .refusedSecure }
        let memory = previous(pid: pid, element: field.element)
        let joined = SmartJoin.adjust(text, before: SmartJoin.textBefore(
            read: field.before,
            previous: memory?.text,
            previousConfirmed: memory?.confirmed ?? false
        ))
        guard let transaction = PasteboardTransaction(text: joined) else {
            log.notice("collage impossible : presse-papiers non modifiable")
            return .failed
        }
        defer { transaction.restoreIfUnchanged() }
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        // Relevé avant le Cmd+V : une Entrée ou un clic pendant la confirmation invalide le raccord suivant.
        let keystrokes = KeyboardTap.keystrokes
        guard postCommandV() else {
            log.notice("collage impossible : ⌘V non envoyé")
            return .failed
        }
        // Laisse l'app lire le presse-papiers (les apps Electron le lisent en différé).
        var confirmed = false
        var sawValue = false
        let deadline = Date().addingTimeInterval(confirmationLimit)
        // Champ non lu avant le collage (Chrome qui construit encore son arbre) : on le relit ici, sans valeur
        // d'avant ; le texte collé doit alors apparaître dans le champ.
        let element = UncheckedSendable(field.element)
        let readFocused = field.element == nil
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let read = Task.detached(priority: .userInitiated) { () -> UncheckedSendable<(String?, InsertionField?)> in
                guard readFocused else { return UncheckedSendable((ContextProbe.valueForCheck(element.value), nil)) }
                let refreshed = InsertionField.read(pid: pid)
                return UncheckedSendable((refreshed.value, refreshed))
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let after = await DictationCoordinator.value(of: read, within: remaining) else { break }
            let (afterValue, refreshed) = after.value
            if let refreshed { kinds.append(refreshed.kind(bundleID: bundleID)) }
            if afterValue != nil { sawValue = true }
            if InsertionCheck.confirms(before: field.value, after: afterValue, inserted: joined) {
                confirmed = true
                break
            }
        }
        let status = FocusedField.status(confirmed: confirmed, kinds: kinds)
        if status == .noTarget {
            // Le focus était sur une liste, un bouton ou le bureau, avant comme après ⌘V : aucun champ où écrire.
            log.notice("collage non confirmé : aucun champ de texte au focus")
        } else if !confirmed {
            // Cause seulement, jamais de texte : de quoi expliquer les collages non confirmés par app.
            log.notice("collage non confirmé : \(sawValue ? "texte absent du champ" : readFocused ? "champ toujours illisible" : "valeur du champ illisible", privacy: .public)")
        }
        if !confirmed { try? await Task.sleep(nanoseconds: 200_000_000) }
        // Cmd+V a été envoyé. Un champ illisible ou un conteneur (groupe, zone web, fenêtre) ne prouve pas un
        // échec : certains éditeurs collent bien sans exposer leur texte. Reste « Collage envoyé ».
        last = Memory(pid: pid, element: field.element, text: joined, confirmed: confirmed, keystrokes: keystrokes, at: Date())
        return status
    }

    /// Attend que ⌃, ⌥, ⇧ et ⌘ soient relâchés (0,6 s au plus) : un ⌘V envoyé pendant que l'utilisateur tient
    /// encore ⌃⌥ du raccourci « Coller la dernière dictée » deviendrait ⌃⌥⌘V dans certaines apps.
    static func waitForModifierRelease(limit: Double = 0.6) async {
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let deadline = Date().addingTimeInterval(limit)
        while !CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Dernier collage, s'il précède sans doute encore le curseur : même app, même champ, moins de 30 s,
    /// et aucune frappe depuis.
    private static func previous(pid: pid_t, element: AXUIElement?) -> Memory? {
        guard let last, last.pid == pid, Date().timeIntervalSince(last.at) < 30,
              last.keystrokes == KeyboardTap.keystrokes else { return nil }
        if let element, let previous = last.element, !CFEqual(element, previous) { return nil }
        return last
    }

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Marqué : l'écoute du clavier de Wispad le laisse passer sans le prendre pour une frappe.
        source?.userData = KeyboardTap.syntheticMarker
        let key = KeyboardLayout.keyCode(for: "v") ?? 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
