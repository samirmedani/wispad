import AppKit
import ApplicationServices
import Carbon
import WispadCore

/// Repli sans changement de focus : un seul candidat du meilleur type, dans la fenêtre active.
enum ProbableInput {
    struct Candidate {
        let multiline: Bool
        let canFill: Bool
    }

    static func choose(_ candidates: [Candidate]) -> Int? {
        let multiline = candidates.indices.filter { candidates[$0].multiline }
        let preferred = multiline.isEmpty ? Array(candidates.indices) : multiline
        guard preferred.count == 1, let index = preferred.first, candidates[index].canFill else { return nil }
        return index
    }

    struct Target: @unchecked Sendable {
        let app: AXUIElement
        let window: AXUIElement
        let element: AXUIElement
        let focus: AXUIElement?
    }

    @MainActor static func find(pid: pid_t, focus: AXUIElement?) async -> Target? {
        let focus = UncheckedSendable(focus)
        let task = Task.detached(priority: .userInitiated) {
            await BlockingQueue.run(label: "wispad.champ-probable") { scan(pid: pid, expectedFocus: focus.value) }
        }
        return await DictationCoordinator.value(of: task, within: TextInserter.fieldReadLimit) ?? nil
    }

    @MainActor static func fill(
        _ target: Target, text: String, pid: pid_t, keys: Int
    ) async -> InsertionStatus {
        await BlockingQueue.run(label: "wispad.champ-probable.ecriture") {
            let node = target.element
            guard let window = element(kAXFocusedWindowAttribute, target.app), CFEqual(window, target.window),
                  focusMatches(target.focus, in: target.app),
                  !ContextProbe.isSecure(node), isWritable(node), ContextProbe.valueForCheck(node) == "",
                  ContextProbe.systemFrontmostPID() == pid,
                  KeyboardTap.keystrokes == keys, !IsSecureEventInputEnabled() else { return .noTarget }
            // Aucun événement clavier : même si le focus bouge, l'écriture ne peut partir dans un autre champ.
            switch AXUIElementSetAttributeValue(node, kAXValueAttribute as CFString, text as CFString) {
            case .success:
                let after = ContextProbe.valueForCheck(node)
                if after == "" { return .failed }
                return after == text ? .inserted : .pasteSent
            case .cannotComplete:
                return .pasteSent // résultat incertain : ne pas risquer un second envoi
            default:
                return .noTarget
            }
        }
    }

    private static let excluded: Set<String> = [
        "AXToolbar", "AXMenuBar", "AXMenu", "AXMenuItem", "AXComboBox", "AXSearchField",
        "AXSecureTextField", "AXDialog", "AXSystemDialog", "AXSheet", "AXPopover",
        "AXStaticText", "AXImage", "AXButton",
    ]

    private static func scan(pid: pid_t, expectedFocus: AXUIElement?) -> Target? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.06)
        guard let window = element(kAXFocusedWindowAttribute, app) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.06)
        guard ContextProbe.string(kAXSubroleAttribute, window) == "AXStandardWindow",
              let bounds = ContextProbe.frame(of: window) else { return nil }
        guard focusMatches(expectedFocus, in: app) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        let limit = 300
        var queue = [(window, bounds)]
        var seen = Set<AXUIElement>()
        var fields: [(AXUIElement, Candidate)] = []
        var index = 0
        while index < queue.count {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let (node, parentClip) = queue[index]
            var clip = parentClip
            index += 1
            guard seen.insert(node).inserted else { continue }
            AXUIElementSetMessagingTimeout(node, 0.06)
            guard let role = ContextProbe.string(kAXRoleAttribute, node) else { return nil }
            guard !excluded.contains(role) else { continue }
            if role == "AXScrollArea", let frame = ContextProbe.frame(of: node) {
                clip = clip.intersection(frame)
                if clip.isEmpty { continue }
            }
            if role == "AXTextField" || role == "AXTextArea" {
                let subrole = ContextProbe.string(kAXSubroleAttribute, node)
                guard subrole.map({ !excluded.contains($0) }) ?? true,
                      let frame = ContextProbe.frame(of: node),
                      clip.contains(CGPoint(x: frame.midX, y: frame.midY)),
                      isWritable(node) else { continue }
                let empty = ContextProbe.valueForCheck(node) == ""
                fields.append((node, Candidate(multiline: role == "AXTextArea", canFill: empty)))
                continue
            }
            var count: CFIndex = 0
            switch AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count) {
            case .noValue, .attributeUnsupported: continue
            case .success: break
            default: return nil
            }
            guard count <= limit - queue.count else { return nil }
            guard count > 0 else { continue }
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, count, &values) == .success,
                  let children = values as? [AXUIElement], children.count == count else { return nil }
            queue.append(contentsOf: children.map { ($0, clip) })
        }
        guard ProcessInfo.processInfo.systemUptime < deadline,
              let choice = choose(fields.map(\.1)) else { return nil }
        return Target(app: app, window: window, element: fields[choice].0, focus: expectedFocus)
    }

    private static func isWritable(_ node: AXUIElement) -> Bool {
        var enabled: CFTypeRef?
        var settable: DarwinBoolean = false
        return AXUIElementCopyAttributeValue(node, kAXEnabledAttribute as CFString, &enabled) == .success &&
            enabled as? Bool == true &&
            AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Un focus réellement absent peut rester absent. Une erreur ou un nouveau champ ne vaut jamais accord.
    private static func focusMatches(_ expected: AXUIElement?, in app: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard let expected else { return status == .noValue }
        return status == .success && value.map { CFEqual($0, expected) } == true
    }

    private static func element(_ attribute: String, _ node: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }
}
