import AppKit
import ApplicationServices
import Carbon
import WispadCore
import os

/// Dernier clic de souris dans une autre app : sa position et son heure seulement, jamais ce qui a été cliqué.
enum ClickTracker {
    struct Click: Sendable, Equatable {
        /// Coordonnées de l'accessibilité : origine en haut à gauche de l'écran principal.
        let point: CGPoint
        /// Horloge de KeyboardTap.now().
        let at: Int
        let serial: Int
    }

    private static let state = OSAllocatedUnfairLock<Click?>(initialState: nil)

    /// Appelé par l'écoute globale des clics, sur le fil principal.
    @MainActor static func note(_ location: NSPoint) {
        let point = accessibilityPoint(location)
        let now = KeyboardTap.now()
        state.withLock { previous in
            previous = Click(point: point, at: now, serial: (previous?.serial ?? 0) &+ 1)
        }
    }

    static var latest: Click? { state.withLock { $0 } }

    /// Position du dernier clic fait depuis `since` (horloge de KeyboardTap.now()), s'il y en a un.
    static func click(since: Int) -> CGPoint? {
        guard let click = latest, click.at >= since else { return nil }
        return click.point
    }

    /// Point d'AppKit (origine en bas à gauche) vers celui de l'accessibilité (origine en haut à gauche).
    @MainActor static func accessibilityPoint(_ location: NSPoint) -> CGPoint {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: top - location.y)
    }

    /// Pointeur de la souris, en coordonnées de l'accessibilité.
    @MainActor static func pointer() -> CGPoint {
        accessibilityPoint(NSEvent.mouseLocation)
    }
}

/// Habitudes de l'utilisateur, gardées sur le Mac sous forme d'empreintes (`InputMemory`), et dernier champ où
/// Wispad a écrit dans chaque app. Ni texte, ni adresse, ni libellé.
final class ProbableInputMemory: @unchecked Sendable {
    static let shared = ProbableInputMemory()
    static let fileName = "champs-probables.json"
    /// Au-delà, le dernier champ utilisé ne compte plus : la fenêtre a pu changer de rôle.
    static let lastTargetLifetime: TimeInterval = 30 * 60

    private let lock = NSLock()
    private var memory = InputMemory()
    private var url: URL?
    private var lastTargets: [pid_t: (element: AXUIElement, at: Date)] = [:]
    private let writer = DispatchQueue(label: "wispad.champs-probables", qos: .utility)

    /// Lit les habitudes enregistrées ; sans appel (tests), elles restent en mémoire seulement.
    func configure(directory: URL) {
        let url = directory.appendingPathComponent(Self.fileName)
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(InputMemory.self, from: $0) }
        lock.withLock {
            self.url = url
            if let loaded { memory = loaded }
        }
    }

    func count(place: String, signature: String) -> Int {
        lock.withLock { memory.count(place: place, signature: signature) }
    }

    func record(place: String, signature: String) {
        let snapshot: (InputMemory, URL)? = lock.withLock {
            memory.record(place: place, signature: signature)
            return url.map { (memory, $0) }
        }
        guard let (memory, url) = snapshot else { return }
        writer.async {
            guard let data = try? JSONEncoder().encode(memory) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func noteTarget(_ element: AXUIElement, pid: pid_t) {
        lock.withLock {
            lastTargets[pid] = (element, Date())
            if lastTargets.count > 12, let oldest = lastTargets.min(by: { $0.value.at < $1.value.at })?.key {
                lastTargets.removeValue(forKey: oldest)
            }
        }
    }

    func lastTarget(pid: pid_t) -> AXUIElement? {
        lock.withLock {
            guard let last = lastTargets[pid], Date().timeIntervalSince(last.at) < Self.lastTargetLifetime else { return nil }
            return last.element
        }
    }

    func reset() {
        lock.withLock {
            memory = InputMemory()
            lastTargets = [:]
        }
    }
}

/// Champ le plus probable d'une dictée finie sans curseur dans un champ : lu dans la fenêtre active de l'app au
/// premier plan, en lecture seule, puis choisi par `InputTargeting`. Le focus n'y est placé qu'au moment d'écrire,
/// comme le ferait un clic, et jamais dans une autre fenêtre ni une autre app.
enum ProbableInput {
    private static let log = Logger.wispad("insertion")

    struct Request: @unchecked Sendable {
        var pid: pid_t
        var bundleID: String?
        /// Élément actif lu juste avant (nil : aucun, ou illisible). Il ne doit pas changer pendant la recherche.
        var focus: AXUIElement?
        /// Champ du curseur au début de la dictée, dans cette même app.
        var start: AXUIElement?
        /// Dernier clic depuis le début de la dictée.
        var click: CGPoint?
        var pointer: CGPoint?
        /// Focus illisible ou indécis : un éditeur caché l'a peut-être ; il faut une preuve forte.
        var strict = false
        /// Carte « Texte prêt » qui attend : seul un champ sous le clic peut être choisi.
        var clickOnly = false
    }

    struct Target: @unchecked Sendable {
        let app: AXUIElement
        let window: AXUIElement
        let element: AXUIElement
        let focus: AXUIElement?
        /// Longueur du texte déjà présent, en unités UTF-16 (position de fin pour le curseur).
        let length: Int
        let caretMovable: Bool
        /// Champ d'une app native (hors page web) : sa valeur peut s'écrire directement si le focus ne s'y place pas.
        let native: Bool
        let empty: Bool
        let strict: Bool
    }

    /// Le parcours s'arrête là ; au-delà, seuls les candidats appuyés par un clic ou un souvenir peuvent être choisis.
    static let scanLimit = 0.35
    static let nodeLimit = 2_500
    /// Toute la recherche, lecture de l'app comprise : une app figée ne retient jamais la dictée.
    static let searchLimit = 0.6

    #if DEBUG
    /// Sonde de développement (`ProbableInputProbeTests`) : chaque candidat et la scène, sans texte du champ.
    nonisolated(unsafe) static var inspect: (([InputCandidate], InputScene) -> Void)?
    #endif

    @MainActor static func find(_ request: Request) async -> Target? {
        let boxed = UncheckedSendable(request)
        let task = Task.detached(priority: .userInitiated) {
            await BlockingQueue.run(label: "wispad.champ-probable") { UncheckedSendable(scan(boxed.value)) }
        }
        return await DictationCoordinator.value(of: task, within: searchLimit)?.value ?? nil
    }

    /// Place le focus dans le champ choisi, comme un clic, si rien n'a bougé depuis la recherche : même fenêtre au
    /// premier plan, même élément actif, aucune frappe. Vrai quand le focus y est (ou reste illisible dans une app qui
    /// ne l'annonce jamais, après une demande acceptée).
    @MainActor static func focus(_ target: Target, pid: pid_t, typingKeys: Int) async -> Bool {
        let boxed = UncheckedSendable(target)
        let task = Task.detached(priority: .userInitiated) {
            await BlockingQueue.run(label: "wispad.champ-probable.focus") { place(boxed.value, pid: pid, typingKeys: typingKeys) }
        }
        return await DictationCoordinator.value(of: task, within: 0.6) ?? false
    }

    /// Repli d'un champ natif vide où le focus ne se place pas : sa valeur est écrite directement, sans touche.
    @MainActor static func fill(_ target: Target, text: String, pid: pid_t, typingKeys: Int) async -> InsertionStatus {
        await BlockingQueue.run(label: "wispad.champ-probable.ecriture") {
            let node = target.element
            guard let window = element(kAXFocusedWindowAttribute, target.app), CFEqual(window, target.window),
                  focusMatches(target.focus, in: target.app),
                  !ContextProbe.isSecure(node), isWritable(node), ContextProbe.valueForCheck(node) == "",
                  ContextProbe.systemFrontmostPID() == pid,
                  KeyboardTap.typingKeys == typingKeys, !IsSecureEventInputEnabled() else { return .noTarget }
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

    /// Dictée arrivée dans un champ : sa forme compte pour la prochaine fois dans cette app (et ce site), et il devient
    /// le dernier champ utilisé. En arrière-plan, sans retarder la bulle. Rien n'est lu du texte.
    static func remember(pid: pid_t, bundleID: String?, element: AXUIElement?) {
        let boxed = UncheckedSendable(element)
        Task.detached(priority: .utility) {
            await BlockingQueue.run(label: "wispad.champ-probable.habitude", qos: .utility) {
                learn(pid: pid, bundleID: bundleID, element: boxed.value)
            }
        }
    }

    // MARK: - Lecture de la fenêtre

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    /// Branches sans champ de dictée : barres d'outils (adresse du navigateur), onglets, menus, boutons, textes.
    private static let skipped: Set<String> = [
        "AXToolbar", "AXTabGroup", "AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXSheet",
        "AXDialog", "AXSystemDialog", "AXPopover", "AXScrollBar", "AXStaticText", "AXImage", "AXButton", "AXLink",
        "AXCheckBox", "AXRadioButton", "AXSlider", "AXSplitter", "AXDisclosureTriangle", "AXValueIndicator",
        "AXIncrementor", "AXHeading", "AXSecureTextField", "AXSearchField", "AXColorWell", "AXProgressIndicator",
        "AXBusyIndicator", "AXLevelIndicator", "AXDateField", "AXTimeField",
    ]
    /// Listes (messages, fil, résultats) : parcourues en dernier, leurs champs sont rarement la cible.
    private static let lists: Set<String> = ["AXList", "AXOutline", "AXTable", "AXGrid", "AXBrowser"]
    private static let dialogSubroles: Set<String> = ["AXApplicationDialog", "AXApplicationAlertDialog", "AXDialog"]
    private static let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{00AD}")
        .union(.whitespacesAndNewlines)

    private struct Item {
        let node: AXUIElement
        let clip: CGRect
        let dialog: Bool
        let landmark: InputLandmark
        let list: Bool
        let web: Bool
    }

    private struct Found {
        let element: AXUIElement
        var candidate: InputCandidate
        let length: Int
        let native: Bool
        let signature: String
    }

    static func scan(_ request: Request) -> Target? {
        let started = ProcessInfo.processInfo.systemUptime
        let app = AXUIElementCreateApplication(request.pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let window = element(kAXFocusedWindowAttribute, app) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.1)
        guard ContextProbe.string(kAXSubroleAttribute, window) == "AXStandardWindow",
              let bounds = ContextProbe.frame(of: window), focusMatches(request.focus, in: app) else { return nil }
        // Focus déjà dans un éditeur (paragraphe d'un champ riche) : le collage habituel y va.
        if let focus = request.focus, element("AXEditableAncestor", focus) != nil { return nil }
        let click = request.click.flatMap { bounds.contains($0) ? $0 : nil }
        var found: [Found] = []
        var host: String?
        var visited = 0
        var complete = true
        if !request.clickOnly {
            (visited, complete) = walk(window: window, bounds: bounds, started: started, found: &found, host: &host)
        }
        func merge(_ node: AXUIElement, mark: (inout InputCandidate) -> Void) {
            if let index = found.firstIndex(where: { CFEqual($0.element, node) }) {
                mark(&found[index].candidate)
            } else if belongs(node, to: window), var entry = describeAlone(node, bounds: bounds) {
                mark(&entry.candidate)
                found.append(entry)
            }
        }
        if let click, let hit = editable(at: click, app: app, window: window) { merge(hit) { $0.clickHit = true } }
        if request.clickOnly {
            found.removeAll { !$0.candidate.clickHit }
        } else {
            if let start = request.start { merge(start) { $0.isStart = true } }
            if let last = ProbableInputMemory.shared.lastTarget(pid: request.pid) { merge(last) { $0.isLastTarget = true } }
        }
        let place = InputTargeting.placeKey(bundleID: request.bundleID, host: host)
        for index in found.indices {
            found[index].candidate.learned = ProbableInputMemory.shared.count(place: place, signature: found[index].signature)
        }
        let scene = InputScene(window: bounds, click: click, pointer: request.pointer,
                               strict: request.strict && !request.clickOnly, complete: complete || request.clickOnly)
        #if DEBUG
        inspect?(found.map(\.candidate), scene)
        #endif
        let choice = InputTargeting.choose(found.map(\.candidate), in: scene)
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        guard let choice else {
            log.notice("champ probable : aucun choix net (candidats=\(found.count, privacy: .public) strict=\(scene.strict, privacy: .public) complet=\(scene.complete, privacy: .public) nœuds=\(visited, privacy: .public) \(elapsed, privacy: .public) ms)")
            return nil
        }
        let chosen = found[choice.index]
        let margin = choice.runnerUp.map { String(format: "%.1f", choice.score - $0) } ?? "seul"
        log.notice("champ probable : choisi score=\(String(format: "%.1f", choice.score), privacy: .public) avance=\(margin, privacy: .public) signaux=\(choice.signals.joined(separator: ","), privacy: .public) candidats=\(found.count, privacy: .public) strict=\(scene.strict, privacy: .public) nœuds=\(visited, privacy: .public) \(elapsed, privacy: .public) ms")
        return Target(app: app, window: window, element: chosen.element, focus: request.focus, length: chosen.length,
                      caretMovable: chosen.candidate.caretMovable, native: chosen.native,
                      empty: chosen.candidate.length == 0, strict: scene.strict)
    }

    /// Parcours en largeur de la fenêtre, borné en temps et en nœuds. Les branches hors de la zone visible ne sont pas
    /// ouvertes ; les listes passent en dernier. Rend le nombre de nœuds lus et si l'essentiel a été parcouru.
    private static func walk(window: AXUIElement, bounds: CGRect, started: TimeInterval, found: inout [Found],
                             host: inout String?) -> (Int, Bool) {
        var queue = [Item(node: window, clip: bounds, dialog: false, landmark: .none, list: false, web: false)]
        var later: [Item] = []
        var head = 0
        var laterHead = 0
        var seen = Set<AXUIElement>()
        var visited = 0
        var mainDone = false
        let deadline = started + scanLimit
        while visited < nodeLimit, ProcessInfo.processInfo.systemUptime < deadline {
            let item: Item
            if head < queue.count {
                item = queue[head]
                head += 1
            } else if laterHead < later.count {
                mainDone = true
                item = later[laterHead]
                laterHead += 1
            } else {
                mainDone = true
                break
            }
            guard seen.insert(item.node).inserted else { continue }
            visited += 1
            AXUIElementSetMessagingTimeout(item.node, 0.1)
            guard let info = basics(item.node), let role = info.role, !skipped.contains(role) else { continue }
            if let subrole = info.subrole, subrole == "AXSecureTextField" || subrole == "AXSearchField" { continue }
            var clip = item.clip
            if let frame = info.frame, frame.width > 0, frame.height > 0 {
                guard frame.intersects(clip) else { continue }
                if role == "AXScrollArea" { clip = clip.intersection(frame) }
            }
            var web = item.web
            if role == "AXWebArea" {
                if host == nil { host = (attribute("AXURL", item.node) as? URL)?.host }
                web = true
                if ContextProbe.isEditable(item.node) {
                    if let entry = describe(item.node, role: role, frame: info.frame, item: item, clip: clip, bounds: bounds) {
                        found.append(entry)
                    }
                    continue
                }
            }
            if textRoles.contains(role) {
                if let entry = describe(item.node, role: role, frame: info.frame, item: item, clip: clip, bounds: bounds) {
                    found.append(entry)
                }
                continue
            }
            var dialog = item.dialog
            var landmark = item.landmark
            var list = item.list || lists.contains(role)
            switch info.subrole {
            case let subrole? where dialogSubroles.contains(subrole): dialog = true
            case "AXLandmarkMain": landmark = .main
            case "AXLandmarkBanner", "AXLandmarkNavigation", "AXLandmarkSearch": landmark = .banner
            case "AXLandmarkComplementary": landmark = .complementary
            case "AXContentList": list = true
            default: break
            }
            let next = info.children.prefix(600).map {
                Item(node: $0, clip: clip, dialog: dialog, landmark: landmark, list: list, web: web)
            }
            if list { later.append(contentsOf: next) } else { queue.append(contentsOf: next) }
        }
        return (visited, mainDone)
    }

    private static let basicAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ]

    /// Rôle, sous-rôle, cadre et enfants en une seule question à l'app.
    private static func basics(_ node: AXUIElement) -> (role: String?, subrole: String?, frame: CGRect?, children: [AXUIElement])? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node, basicAttributes as CFArray,
                                                     AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == 5 else { return nil }
        var frame: CGRect?
        var point = CGPoint.zero
        var size = CGSize.zero
        if axValue(array[2], .cgPoint, &point), axValue(array[3], .cgSize, &size) {
            frame = CGRect(origin: point, size: size)
        }
        let children = (array[4] as? [AnyObject] ?? []).compactMap { item -> AXUIElement? in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
        return (array[0] as? String, array[1] as? String, frame, children)
    }

    private static func axValue(_ object: AnyObject, _ type: AXValueType, _ result: UnsafeMutableRawPointer) -> Bool {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return false }
        let value = object as! AXValue
        return AXValueGetType(value) == type && AXValueGetValue(value, type, result)
    }

    /// Champ visible, actif et modifiable, décrit sans son texte. nil pour tout le reste.
    private static func describe(_ node: AXUIElement, role: String, frame: CGRect?, item: Item, clip: CGRect,
                                 bounds: CGRect) -> Found? {
        guard let frame, frame.width >= 12, frame.height >= 10,
              clip.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        guard !ContextProbe.isSecure(node), ContextProbe.string(kAXSubroleAttribute, node) != "AXSearchField" else { return nil }
        if let enabled = attribute(kAXEnabledAttribute, node) as? Bool, !enabled { return nil }
        guard ContextProbe.isEditable(node) else { return nil }
        let count = ContextProbe.number(kAXNumberOfCharactersAttribute, node)
        let length: Int
        if let count, count > 8 {
            length = count
        } else {
            let value = ContextProbe.string(kAXValueAttribute, node) ?? ""
            length = value.unicodeScalars.contains { !invisible.contains($0) } ? max(1, count ?? value.utf16.count) : 0
        }
        let hint = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
            .compactMap { ContextProbe.string($0, node) }
            .joined(separator: " ")
        let identifier = ContextProbe.string("AXDOMIdentifier", node) ?? ""
        let classes = (attribute("AXDOMClassList", node) as? [String]) ?? []
        var settable: DarwinBoolean = false
        let caret = AXUIElementIsAttributeSettable(node, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
            && settable.boolValue
        let multiline = role == "AXTextArea" || role == "AXWebArea"
        let candidate = InputCandidate(
            role: role, frame: frame, multiline: multiline, length: length == 0 ? 0 : max(1, length),
            hint: InputTargeting.normalize(hint), domIdentifier: identifier, domClasses: classes,
            inDialog: item.dialog, landmark: item.landmark, inList: item.list, caretMovable: caret
        )
        let signature = InputTargeting.signature(role: role, multiline: multiline, domIdentifier: identifier,
                                                 domClasses: classes, frame: frame, window: bounds)
        return Found(element: node, candidate: candidate, length: count ?? length, native: !item.web, signature: signature)
    }

    /// Champ trouvé hors du parcours (sous le clic, champ du début, dernier champ) : même description, sans son
    /// contexte de page, qu'on ne connaît pas.
    private static func describeAlone(_ node: AXUIElement, bounds: CGRect) -> Found? {
        AXUIElementSetMessagingTimeout(node, 0.1)
        guard let role = ContextProbe.string(kAXRoleAttribute, node),
              textRoles.contains(role) || (role == "AXWebArea" && ContextProbe.isEditable(node)) else { return nil }
        let web = attribute("AXDOMClassList", node) != nil || attribute("AXDOMIdentifier", node) != nil
        let item = Item(node: node, clip: bounds, dialog: false, landmark: .none, list: false, web: web)
        return describe(node, role: role, frame: ContextProbe.frame(of: node), item: item, clip: bounds, bounds: bounds)
    }

    /// Champ modifiable sous ce point : l'élément touché, ou son éditeur parent (paragraphe d'un champ riche).
    private static func editable(at point: CGPoint, app: AXUIElement, window: AXUIElement) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              var node = hit else { return nil }
        for _ in 0..<8 {
            AXUIElementSetMessagingTimeout(node, 0.1)
            if let editor = element("AXEditableAncestor", node) { return editor }
            if let role = ContextProbe.string(kAXRoleAttribute, node) {
                if textRoles.contains(role) { return node }
                if role == "AXWindow" || role == "AXWebArea" { return nil }
            }
            guard let parent = element(kAXParentAttribute, node), !CFEqual(parent, window) else { return nil }
            node = parent
        }
        return nil
    }

    /// L'élément est dans cette fenêtre. Sans réponse de l'app, il est accepté : il vient de la même app et sera
    /// encore vérifié avant d'écrire.
    private static func belongs(_ node: AXUIElement, to window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(node, 0.1)
        guard let owner = element(kAXWindowAttribute, node) else { return true }
        return CFEqual(owner, window)
    }

    // MARK: - Focus

    private enum FocusState { case inside, elsewhere, unreadable }

    private static func place(_ target: Target, pid: pid_t, typingKeys: Int) -> Bool {
        AXUIElementSetMessagingTimeout(target.app, 0.2)
        AXUIElementSetMessagingTimeout(target.element, 0.2)
        guard let window = element(kAXFocusedWindowAttribute, target.app), CFEqual(window, target.window),
              focusMatches(target.focus, in: target.app), ContextProbe.systemFrontmostPID() == pid,
              KeyboardTap.typingKeys == typingKeys, !ContextProbe.isSecure(target.element) else { return false }
        let request = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard request == .success || request == .cannotComplete else {
            log.notice("champ probable : focus refusé par l'app (\(request.rawValue, privacy: .public))")
            return false
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        var state = FocusState.elsewhere
        repeat {
            state = focusState(of: target)
            if state == .inside { break }
            usleep(25_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        // Une app qui n'annonce jamais son élément actif (Codex) : la demande acceptée vaut placement.
        let placed = state == .inside || (state == .unreadable && target.focus == nil && request == .success)
        guard placed else {
            log.notice("champ probable : le focus n'a pas rejoint le champ")
            return false
        }
        // Texte déjà présent : la dictée va à la fin, jamais au milieu d'un brouillon. Pas quand le focus était
        // illisible : le curseur y est peut-être déjà, à la place voulue.
        if !target.empty, !target.strict, target.caretMovable {
            var end = CFRange(location: target.length, length: 0)
            if let range = AXValueCreate(.cfRange, &end) {
                AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, range)
            }
        }
        return true
    }

    private static func focusState(of target: Target) -> FocusState {
        guard let focused = element(kAXFocusedUIElementAttribute, target.app) else { return .unreadable }
        if CFEqual(focused, target.element) { return .inside }
        if let editor = element("AXEditableAncestor", focused), CFEqual(editor, target.element) { return .inside }
        var node = focused
        for _ in 0..<6 {
            guard let parent = element(kAXParentAttribute, node) else { break }
            if CFEqual(parent, target.element) { return .inside }
            node = parent
        }
        return .elsewhere
    }

    // MARK: - Habitudes

    private static func learn(pid: pid_t, bundleID: String?, element node: AXUIElement?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let node = node ?? element(kAXFocusedUIElementAttribute, app) else { return }
        AXUIElementSetMessagingTimeout(node, 0.2)
        guard let role = ContextProbe.string(kAXRoleAttribute, node),
              textRoles.contains(role) || role == "AXWebArea", !ContextProbe.isSecure(node),
              let frame = ContextProbe.frame(of: node),
              let window = element(kAXWindowAttribute, node) ?? element(kAXFocusedWindowAttribute, app),
              let bounds = ContextProbe.frame(of: window) else { return }
        var host: String?
        var current = node
        for _ in 0..<40 {
            guard let parent = element(kAXParentAttribute, current), !CFEqual(parent, window) else { break }
            if ContextProbe.string(kAXRoleAttribute, parent) == "AXWebArea" {
                host = (attribute("AXURL", parent) as? URL)?.host
            }
            current = parent
        }
        let classes = (attribute("AXDOMClassList", node) as? [String]) ?? []
        let signature = InputTargeting.signature(
            role: role, multiline: role == "AXTextArea" || role == "AXWebArea",
            domIdentifier: ContextProbe.string("AXDOMIdentifier", node) ?? "", domClasses: classes,
            frame: frame, window: bounds
        )
        ProbableInputMemory.shared.record(place: InputTargeting.placeKey(bundleID: bundleID, host: host), signature: signature)
        ProbableInputMemory.shared.noteTarget(node, pid: pid)
    }

    // MARK: - Accessibilité

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

    private static func attribute(_ name: String, _ node: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ attribute: String, _ node: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
