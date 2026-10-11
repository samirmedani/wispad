import AppKit
import ApplicationServices
import WispadCore

/// Résultat d'une lecture de fenêtre. `context` reste en mémoire et ne doit jamais être journalisé ni imprimé.
struct WindowTextSnapshot: Sendable, Equatable {
    var context: String?
    var nodesVisited: Int
    var fragmentsKept: Int
    var characterCount: Int
    var candidateTermCount: Int
    var durationMilliseconds: Int
    var stoppedOnBudget: Bool

    /// Nœuds visités, fragments retenus, caractères, termes candidats, durée en ms, budget atteint (1 ou 0).
    var diagnosticNumbers: String {
        "\(nodesVisited) \(fragmentsKept) \(characterCount) \(candidateTermCount) \(durationMilliseconds) \(stoppedOnBudget ? 1 : 0)"
    }

    static let empty = WindowTextSnapshot(
        context: nil,
        nodesVisited: 0,
        fragmentsKept: 0,
        characterCount: 0,
        candidateTermCount: 0,
        durationMilliseconds: 0,
        stoppedOnBudget: false
    )
}

/// Lit le texte visible de la fenêtre focalisée d'un processus.
/// Synchrone, sans isolation : à appeler depuis une tâche détachée, comme `CorrectionWatcher`.
enum WindowTextProbe {
    private static let messagingTimeout: Float = 0.1
    private static let navigationOrder = "AXChildrenInNavigationOrder"

    static func read(pid: pid_t, limits: WindowWalkLimits = .windowReading) -> WindowTextSnapshot {
        let start = ContinuousClock.now
        guard AXIsProcessTrusted(), let access = focusedWindow(pid: pid) else {
            return snapshot(fragments: [], nodesVisited: 0, stoppedOnBudget: false, start: start)
        }
        let walked = WindowTreeWalk.collect(
            root: access.window,
            limits: limits,
            children: { children(of: $0, focused: access.focused) },
            value: { fragment(of: $0, focused: access.focused) }
        )
        return snapshot(
            fragments: walked.values,
            nodesVisited: walked.nodesVisited,
            stoppedOnBudget: walked.stoppedOnBudget,
            start: start
        )
    }

    #if DEBUG
    /// `--window-context-probe <bundle-id>` : nombres seuls, sans fenêtre, sans Dock, sans activer l'app.
    @MainActor static func runDiagnostic(arguments: [String]) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let bundleID = bundleIdentifier(in: arguments)
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
        let pid = (running.first(where: \.isActive) ?? running.first)?.processIdentifier
        let snapshot = pid.map { readOffMain(pid: $0) } ?? .empty
        print(snapshot.diagnosticNumbers)
        fflush(stdout)
        exit(0)
    }
    #endif

    private static func snapshot(
        fragments: [WindowTextFragment],
        nodesVisited: Int,
        stoppedOnBudget: Bool,
        start: ContinuousClock.Instant
    ) -> WindowTextSnapshot {
        let context = WindowContext.assemble(fragments)
        let fragmentsKept = context?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
        return WindowTextSnapshot(
            context: context,
            nodesVisited: nodesVisited,
            fragmentsKept: fragmentsKept,
            characterCount: context?.count ?? 0,
            candidateTermCount: WindowContext.candidateTerms(in: context).count,
            durationMilliseconds: milliseconds(start.duration(to: .now)),
            stoppedOnBudget: stoppedOnBudget
        )
    }

    /// La lecture AX quitte le fil principal avant la première question.
    private static func readOffMain(pid: pid_t) -> WindowTextSnapshot {
        let handoff = ProbeHandoff()
        Task.detached(priority: .utility) {
            handoff.complete(read(pid: pid))
        }
        return handoff.wait()
    }

    private static func bundleIdentifier(in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "--window-context-probe"),
              arguments.indices.contains(index + 1) else { return "" }
        let value = arguments[index + 1]
        if value.hasPrefix("-") { return "" }
        return value
    }

    private static func focusedWindow(pid: pid_t) -> (window: AXUIElement, focused: AXUIElement?)? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        // Les apps Electron et Chromium n'ouvrent leur arbre qu'à la demande, comme `ContextProbe.focusedElement`.
        ContextProbe.openAccessibility(application, pid: pid)
        guard let window = element(kAXFocusedWindowAttribute as CFString, of: application) else { return nil }
        return (window, element(kAXFocusedUIElementAttribute as CFString, of: application))
    }

    private static func fragment(of element: AXUIElement, focused: AXUIElement?) -> WindowTextFragment? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        guard let role = ContextProbe.string(kAXRoleAttribute, element) else { return nil }
        let isFocused = focused.map { CFEqual(element, $0) } ?? false
        if role == "AXHeading" {
            guard let text = headingText(element) else { return nil }
            return WindowTextFragment(text: text, role: role, isFocusedField: isFocused, isSecure: false)
        }
        guard role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" else { return nil }
        if ContextProbe.isSecure(element) {
            return WindowTextFragment(text: "", role: role, isFocusedField: isFocused, isSecure: true)
        }
        // Le champ en cours de saisie est exclu : on ne lit pas sa valeur.
        if isFocused, isTextEntry(role) { return nil }
        guard let value = ContextProbe.string(kAXValueAttribute, element) else { return nil }
        return WindowTextFragment(text: value, role: role, isFocusedField: isFocused, isSecure: false)
    }

    private static func headingText(_ element: AXUIElement) -> String? {
        let title = ContextProbe.string(kAXTitleAttribute, element)
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return ContextProbe.string(kAXDescriptionAttribute, element)
    }

    private static func children(of element: AXUIElement, focused: AXUIElement?) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let role = ContextProbe.string(kAXRoleAttribute, element)
        if let focused, CFEqual(element, focused), isTextEntry(role) {
            return []
        }
        if role == "AXWebArea", let ordered = elements(navigationOrder as CFString, of: element), !ordered.isEmpty {
            return ordered
        }
        return elements(kAXChildrenAttribute as CFString, of: element) ?? []
    }

    private static func isTextEntry(_ role: String?) -> Bool {
        role == "AXTextArea" || role == "AXTextField"
    }

    private static func element(_ attribute: CFString, of parent: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let child = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(child, messagingTimeout)
        return child
    }

    private static func elements(_ attribute: CFString, of parent: AXUIElement) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute, &raw) == .success, let raw,
              CFGetTypeID(raw) == CFArrayGetTypeID() else { return nil }
        var children: [AXUIElement] = []
        for item in raw as! NSArray {
            let ref = item as CFTypeRef
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { continue }
            let child = ref as! AXUIElement
            AXUIElementSetMessagingTimeout(child, messagingTimeout)
            children.append(child)
        }
        return children
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        let value = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        return Int(max(0, value))
    }
}

/// Passe le résultat de la tâche détachée au fil qui attend, sans exposer le texte.
private final class ProbeHandoff: @unchecked Sendable {
    private var snapshot: WindowTextSnapshot?
    private let semaphore = DispatchSemaphore(value: 0)

    func complete(_ snapshot: WindowTextSnapshot) {
        self.snapshot = snapshot
        semaphore.signal()
    }

    func wait() -> WindowTextSnapshot {
        semaphore.wait()
        return snapshot ?? .empty
    }
}
