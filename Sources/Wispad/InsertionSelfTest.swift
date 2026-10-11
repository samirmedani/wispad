import AppKit
import WispadCore

// Outil de développement : absent de la version Release.
#if DEBUG

/// Récepteur de collage dont l'accessibilité n'expose ni champ ni texte, comme certains éditeurs web.
@MainActor
private final class PasteOnlyView: NSView {
    var pastedText = ""
    override var acceptsFirstResponder: Bool { true }
    // AppKit peut lire ces attributs depuis le fil de l'appel AX : aucun état UI n'est consulté ici.
    nonisolated override func isAccessibilityElement() -> Bool { true }
    nonisolated override func accessibilityRole() -> NSAccessibility.Role? { .button }

    @objc func paste(_ sender: Any?) {
        pastedText = NSPasteboard.general.string(forType: .string) ?? ""
    }
}

@MainActor
enum InsertionSelfTest {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        MainMenu.install()
        let field = NSTextField(string: "brouillon")
        field.frame = NSRect(x: 16, y: 44, width: 440, height: 28)
        let secure = NSSecureTextField(string: "")
        secure.frame = NSRect(x: 16, y: 8, width: 440, height: 28)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 472, height: 84))
        content.addSubview(field)
        content.addSubview(secure)
        let pasteOnly = PasteOnlyView(frame: NSRect(x: 456, y: 8, width: 12, height: 64))
        content.addSubview(pasteOnly)
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Wispad self-test"
        window.contentView = content
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (field.stringValue as NSString).length)

        Task { @MainActor in
            let ownPID = ProcessInfo.processInfo.processIdentifier
            // Ne colle jamais dans une autre app : sans le premier plan, le test s'arrête.
            func ownsFocus() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID }
            for _ in 0..<50 where !ownsFocus() {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard ownsFocus() else {
                print("selftest_skipped=not_frontmost")
                exit(2)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            window.makeFirstResponder(pasteOnly)
            try? await Task.sleep(nanoseconds: 250_000_000)
            let opaque = ContextProbe.capture()
            opaque.pid = ownPID
            guard ownsFocus() else { print("selftest_skipped=not_frontmost"); exit(2) }
            let opaqueRole = opaque.element.flatMap { ContextProbe.string(kAXRoleAttribute, $0) }
            let opaqueValue = ContextProbe.valueForCheck(opaque.element)
            let sent = await TextInserter.insert("Collage sans valeur accessible.", context: opaque)
            window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (field.stringValue as NSString).length)
            try? await Task.sleep(nanoseconds: 250_000_000)
            let editable = ContextProbe.capture()
            editable.pid = ownPID
            guard ownsFocus() else { print("selftest_skipped=not_frontmost"); exit(2) }
            let inserted = await TextInserter.insert("Réunion mercredi.", context: editable)
            try? await Task.sleep(nanoseconds: 200_000_000)
            window.makeFirstResponder(secure)
            try? await Task.sleep(nanoseconds: 250_000_000)
            let secret = ContextProbe.capture()
            secret.pid = ownPID
            guard ownsFocus() else { print("selftest_skipped=not_frontmost"); exit(2) }
            let refused = await TextInserter.insert("ne-pas-inserer", context: secret)
            let passed = (inserted == .inserted || inserted == .pasteSent)
                && field.stringValue == "Réunion mercredi."
                && opaqueRole == "AXButton"
                && opaqueValue == nil
                && sent == .pasteSent
                && pasteOnly.pastedText == "Collage sans valeur accessible."
                && secret.isSecure
                && refused == .refusedSecure
                && secure.stringValue.isEmpty
            print("selftest_insert=\(inserted.rawValue)")
            print("selftest_opaque=\(sent.rawValue) received=\(pasteOnly.pastedText == "Collage sans valeur accessible.") role=\(opaqueRole ?? "nil") readable=\(opaqueValue != nil)")
            print("selftest_secure=\(refused.rawValue)")
            print("selftest_passed=\(passed)")
            if !passed { exit(1) }
            app.terminate(nil)
        }
        app.run()
    }
}

/// Test d'insertion dans une autre app (ex. une fenêtre Chromium de test) : `--paste-probe <pid>`.
/// Ne colle que si ce processus est au premier plan ; sinon s'arrête sans rien envoyer.
@MainActor
enum PasteProbe {
    static func run(pid: pid_t) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            func targetOwnsFocus() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
            for _ in 0..<40 where !targetOwnsFocus() {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard targetOwnsFocus() else {
                print("probe_skipped=not_frontmost")
                exit(2)
            }
            let context = ContextProbe.capture()
            guard context.pid == pid else {
                print("probe_skipped=focus_changed")
                exit(2)
            }
            print("probe_app=\(context.bundleID ?? "?") element_at_start=\(context.element != nil)")
            let status = await TextInserter.insert("Test Wispad Chromium 42.", context: context)
            let after = ContextProbe.valueForCheck(ContextProbe.focusedElement(pid: pid)) ?? ""
            print("probe_status=\(status.rawValue) field_contains_text=\(after.contains("Test Wispad Chromium 42."))")
            exit(0)
        }
        app.run()
    }
}

#endif
