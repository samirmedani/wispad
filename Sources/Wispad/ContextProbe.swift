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

    /// App au premier plan, sans lire son champ.
    @MainActor static func frontmost() -> DictationContext {
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
    /// Jamais Wispad lui-même (voir `isOwnProcess`).
    static func focusedElement(pid: pid_t?) -> AXUIElement? {
        guard !isOwnProcess(pid) else { return nil }
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
        guard let element = systemFocusedElement() else { return nil }
        // Le repli système peut appartenir à une autre app si le focus a changé pendant la lecture.
        var owner: pid_t = 0
        let ownerKnown = AXUIElementGetPid(element, &owner) == .success
        if ownerKnown, isOwnProcess(owner) { return nil }
        if let pid {
            guard ownerKnown, owner == pid else { return nil }
        }
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Wispad lui-même (sa fenêtre au premier plan, une dictée dans son dictionnaire…) : jamais lu par
    /// l'accessibilité. Ces lectures se font alors dans son propre processus, sur le fil qui les demande : hors du
    /// fil principal, SwiftUI y recalcule l'interface et macOS arrête l'app (plantage du 13 octobre 2026). Sa
    /// fenêtre n'apporte rien à la dictée, et un collage dans Wispad n'a pas besoin de confirmation.
    static func isOwnProcess(_ pid: pid_t?) -> Bool {
        #if DEBUG
        // Autotest d'insertion (`--self-test`, développement seulement) : il vise exprès ses fenêtres AppKit.
        if selfTestReadsOwnProcess.withLock({ $0 }) { return false }
        #endif
        return pid == ownPID
    }

    #if DEBUG
    /// Posé par `InsertionSelfTest` au démarrage ; absent de la version Release.
    static let selfTestReadsOwnProcess = OSAllocatedUnfairLock(initialState: false)
    #endif

    /// Repli : champ actif de l'app au premier plan, demandé à l'élément système. Jamais quand c'est Wispad (sa
    /// fenêtre ouverte pendant la lecture d'une autre app) : la question lui serait servie dans son propre processus,
    /// sur ce fil, pour une réponse de toute façon écartée (voir `isOwnProcess`). L'app au premier plan est lue
    /// d'abord, sans rien demander à ses fenêtres.
    static func systemFocusedElement(frontmost: () -> pid_t? = systemFrontmostPID,
                                     ask: () -> AXUIElement? = askSystemFocusedElement) -> AXUIElement? {
        guard !isOwnProcess(frontmost()) else { return nil }
        return ask()
    }

    /// App au premier plan selon l'accessibilité : seul son processus est lu.
    static func systemFrontmostPID() -> pid_t? {
        var application: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString,
                                            &application) == .success,
              let application, CFGetTypeID(application) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(application as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }

    static func askSystemFocusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return focused as! AXUIElement
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

    /// L'élément expose un curseur ou une sélection de texte : on peut y écrire.
    static func hasTextCursor(_ element: AXUIElement) -> Bool {
        var range: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success && range != nil
    }

    static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Où se trouve la saisie à l'écran : champ actif, ligne du curseur et fenêtre active, en coordonnées macOS.
    /// Quelques lectures d'accessibilité, faites après l'envoi du texte : ni la bulle ni le collage ne les attendent.
    struct InputLocation: Sendable {
        var field: CGRect?
        var caret: CGRect?
        var window: CGRect?
        var zone: CGRect? { OverlayGeometry.inputZone(field: field, caret: caret, window: window) }
    }

    static func inputLocation(pid: pid_t) -> InputLocation {
        guard !isOwnProcess(pid) else { return InputLocation() }
        // Écran principal (barre des menus) : origine des coordonnées d'accessibilité. Lisible hors du fil principal.
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let flip = { (rect: CGRect) in OverlayGeometry.flipped(rect, primaryHeight: primaryHeight) }
        var location = InputLocation()
        if let element = focusedElement(pid: pid), !isSecure(element) {
            location.field = frame(of: element).map(flip)
            location.caret = caretBounds(element).map(flip)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            location.window = frame(of: window as! AXUIElement).map(flip)
        }
        return location
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Rectangle de la sélection ou du curseur, si l'app sait le donner.
    static func caretBounds(_ element: AXUIElement) -> CGRect? {
        guard let range = selectedRange(element) else { return nil }
        var wanted = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &wanted) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
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
        let read = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success
        return nearby(value: value, selection: read ? rangeValue : nil)
    }

    /// Texte autour de la sélection que l'app annonce. Une valeur qui n'est pas une plage, ou une plage démesurée,
    /// ne fait pas planter Wispad : le début du champ sert alors de repère, comme sans sélection lisible.
    static func nearby(value: String, selection rangeValue: CFTypeRef?) -> String {
        var range = CFRange(location: 0, length: 0)
        if let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            let axValue = rangeValue as! AXValue
            withUnsafeMutablePointer(to: &range) { pointer in
                _ = AXValueGetValue(axValue, .cfRange, pointer)
            }
        }
        let ns = value as NSString
        let location = min(max(0, range.location), ns.length)
        let start = max(0, location - 220)
        // Longueur bornée au champ avant l'addition, qui ne peut plus déborder.
        let end = min(ns.length, location + min(max(range.length, 0), ns.length) + 220)
        guard end > start else { return String(value.prefix(400)) }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}
