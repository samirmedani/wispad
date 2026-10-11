import AppKit
import ApplicationServices
import Foundation
import WispadCore
import os

final class DictationContext: @unchecked Sendable {
    var appName: String?
    var bundleID: String?
    var pid: pid_t?
    var selectedText: String?
    var nearbyText: String?
    var isSecure = false
    var element: AXUIElement?
    /// Le champ actif a été lu (ou sa lecture a échoué) : rien de plus à attendre.
    private(set) var fieldRead = false

    func apply(_ field: FieldSnapshot?) {
        fieldRead = true
        guard let field else { return }
        element = field.element
        isSecure = field.isSecure
        selectedText = field.selectedText
        nearbyText = field.nearbyText
    }
}

/// Champ actif au début de la dictée, lu hors du fil principal.
struct FieldSnapshot: @unchecked Sendable {
    var element: AXUIElement
    var isSecure = false
    var selectedText: String?
    var nearbyText: String?
}

/// Valeur qui traverse vers un autre fil sans être Sendable (éléments d'accessibilité) : un seul fil s'en sert à la fois.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Lecture d'accessibilité hors du fil principal : une app lente (Electron) ne fige ni la bulle ni Wispad.
func offMain<Input, Output>(_ input: Input, _ work: @escaping @Sendable (Input) -> Output) async -> Output {
    let box = UncheckedSendable(input)
    return await Task.detached(priority: .userInitiated) { UncheckedSendable(work(box.value)) }.value.value
}

enum ContextProbe {
    /// App au premier plan, lue tout de suite (c'est là que le texte sera collé), puis le champ actif et le texte
    /// autour du curseur, lus en parallèle hors du fil principal : le micro s'ouvre sans attendre une app lente.
    @MainActor static func begin() -> (DictationContext, Task<FieldSnapshot?, Never>) {
        let context = frontmost()
        let pid = context.pid
        let field = Task.detached(priority: .userInitiated) { () -> FieldSnapshot? in
            guard PermissionCenter.accessibilityTrusted(prompt: false) else { return nil }
            return readField(pid: pid)
        }
        return (context, field)
    }

    /// Lecture complète et immédiate (autotest d'insertion).
    @MainActor static func capture() -> DictationContext {
        let context = frontmost()
        if PermissionCenter.accessibilityTrusted(prompt: false) { context.apply(readField(pid: context.pid)) }
        return context
    }

    @MainActor private static func frontmost() -> DictationContext {
        let context = DictationContext()
        if let app = NSWorkspace.shared.frontmostApplication {
            context.appName = app.localizedName
            context.bundleID = app.bundleIdentifier
            context.pid = app.processIdentifier
        }
        return context
    }

    static func readField(pid: pid_t?) -> FieldSnapshot? {
        guard let element = focusedElement(pid: pid) else { return nil }
        var field = FieldSnapshot(element: element)
        field.isSecure = isSecure(element)
        guard !field.isSecure else { return field }
        field.selectedText = string(kAXSelectedTextAttribute, element)
        if let count = number(kAXNumberOfCharactersAttribute, element), count <= 4_000,
           let value = string(kAXValueAttribute, element) {
            field.nearbyText = nearby(value: value, element: element)
        }
        return field
    }

    /// Apps dont l'arbre d'accessibilité a déjà été ouvert : la demande n'est faite qu'une fois par app.
    private static let opened = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// Champ actif de l'app au premier plan. Les apps Electron/Chromium n'ouvrent leur arbre
    /// d'accessibilité qu'à la demande : AXManualAccessibility le force, comme le font les outils de dictée.
    static func focusedElement(pid: pid_t?) -> AXUIElement? {
        var focused: CFTypeRef?
        if let pid {
            let app = AXUIElementCreateApplication(pid)
            // Une app lente (Electron) ne bloque jamais la lecture plus d'une demi-seconde par question.
            AXUIElementSetMessagingTimeout(app, 0.5)
            if opened.withLock({ $0.insert(pid).inserted }) { openAccessibility(app, pid: pid) }
            if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let element = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.5)
                return element
            }
        }
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    /// Navigateurs Chromium : ils ignorent AXManualAccessibility (réservé à Electron) et n'exposent le champ d'une
    /// page qu'avec AXEnhancedUserInterface, comme pour un lecteur d'écran (mesuré le 9 octobre : 40 collages sur 40
    /// non confirmés dans Chrome). Limité aux navigateurs : ce drapeau peut ralentir les animations de fenêtre.
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func openAccessibility(_ app: AXUIElement, pid: pid_t) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, chromiumBrowsers.contains(bundle) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        string(kAXSubroleAttribute, element) == "AXSecureTextField"
    }

    /// Valeur courte du champ, pour constater un collage. Jamais journalisée.
    static func valueForCheck(_ element: AXUIElement?) -> String? {
        guard let element else { return nil }
        if let count = number(kAXNumberOfCharactersAttribute, element), count > 50_000 { return nil }
        return string(kAXValueAttribute, element)
    }

    /// Quelques caractères juste avant le curseur (ou la sélection), pour raccorder deux dictées : "" en début
    /// de champ, nil si l'app ne les expose pas. Jamais journalisés.
    static func textBeforeCursor(_ element: AXUIElement?, length: Int = 32) -> String? {
        guard let element else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location >= 0 else { return nil }
        guard selection.location > 0 else { return "" }
        let start = max(0, selection.location - length)
        var wanted = CFRange(location: start, length: selection.location - start)
        if let parameter = AXValueCreate(.cfRange, &wanted) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
               let text = value as? String, !text.isEmpty {
                return text
            }
        }
        guard let value = valueForCheck(element) else { return nil }
        let ns = value as NSString
        guard selection.location <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: start, length: selection.location - start))
    }

    static func string(_ attribute: String, _ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func number(_ attribute: String, _ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func nearby(value: String, element: AXUIElement) -> String {
        var rangeValue: CFTypeRef?
        var range = CFRange(location: 0, length: 0)
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue {
            let axValue = rangeValue as! AXValue
            withUnsafeMutablePointer(to: &range) { pointer in
                _ = AXValueGetValue(axValue, .cfRange, pointer)
            }
        }
        let ns = value as NSString
        let location = min(max(0, range.location), ns.length)
        let start = max(0, location - 220)
        let end = min(ns.length, location + max(range.length, 0) + 220)
        guard end > start else { return String(value.prefix(400)) }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}
