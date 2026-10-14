import ApplicationServices
import CoreGraphics
import Foundation
import WispadCore
import os

/// État technique uniquement : aucune touche ni horodatage de frappe n'est conservé.
struct KeyboardDiagnosticState: Codable, Equatable, Sendable {
    enum Listening: String, Codable, Sendable { case notStarted, unavailable, enabled, disabled }
    var listening: Listening = .notStarted
    var recoveries = 0
    var capturing = false
    var pending = false
    var recordingShortcut = false
}

/// Frontières macOS de l'écoute du clavier, remplacées dans les tests : aucune vraie écoute, aucune frappe lue.
struct KeyboardTapSystem {
    /// Autorisations dont dépend l'écoute, lues sans rien demander. La surveillance des entrées est une question au
    /// démon des autorisations de macOS (une dizaine de millisecondes, davantage s'il est occupé) : jamais posée
    /// pendant que l'écoute retient les frappes, voir `accessibilityTrusted`.
    var permissions: () -> KeyboardPermissions = {
        KeyboardPermissions(listen: PermissionCenter.inputMonitoringTrusted(),
                            accessibility: PermissionCenter.accessibilityTrusted(prompt: false))
    }
    /// Accessibilité seule, que macOS garde en mémoire dans le processus (lecture d'une microseconde) : la seule
    /// autorisation relue toutes les 3 s pendant que l'écoute est active, car chaque frappe du Mac attend ce fil.
    var accessibilityTrusted: () -> Bool = { PermissionCenter.accessibilityTrusted(prompt: false) }
    /// Écoute active en tête de la session : elle voit passer, et peut avaler, chaque frappe de toutes les apps.
    var create: (KeyboardTap) -> CFMachPort? = { tap in
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyboardTapCallback,
            userInfo: Unmanaged.passUnretained(tap).toOpaque()
        )
    }
    var isEnabled: (CFMachPort) -> Bool = { CGEvent.tapIsEnabled(tap: $0) }
    var enable: (CFMachPort) -> Void = { CGEvent.tapEnable(tap: $0, enable: true) }
    /// État physique d'une touche, lu au clavier lui-même (état matériel) et non dans la file des événements.
    var keyIsDown: (Int) -> Bool = { keyCode in
        if keyCode == ChordMatcher.functionKeyCode {
            return CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
        }
        return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }
}

/// Écoute du clavier sur son propre fil, avec sa propre boucle d'événements : le clavier du Mac n'attend jamais
/// le fil principal de Wispad (fenêtre en cours de rendu, app lente interrogée, collage en cours). La logique du
/// raccourci (HotkeyLogic) tourne ici ; seuls ses effets (début, fin, annulation) partent vers le fil principal.
final class KeyboardTap: @unchecked Sendable {
    /// Marque les frappes que Wispad envoie lui-même (Cmd+V du collage) : l'écoute les laisse passer sans les lire,
    /// pour qu'un collage pendant une autre dictée ne soit pas pris pour « fn + une autre touche ».
    static let syntheticMarker: Int64 = 0x7769_7370_6164

    /// Frappes et clics réels depuis le lancement (un simple compteur, jamais les touches) : un collage suivi
    /// d'aucune frappe ni d'aucun clic laisse le curseur juste après le texte collé.
    private static let typed = OSAllocatedUnfairLock(initialState: 0)
    static var keystrokes: Int { typed.withLock { $0 } }

    static func noteInput() {
        typed.withLock { $0 &+= 1 }
    }

    /// Horloge des frappes : ms depuis le démarrage, hors veille, comme l'horodatage des événements clavier.
    static func now() -> Int {
        Int(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000)
    }

    private let deliver: @Sendable (HotkeyOutput) -> Void
    private let unavailable: @Sendable () -> Void
    /// L'écoute a été retirée faute d'une autorisation, sans pouvoir être refaite : plus aucune frappe n'est vue.
    private let lost: @Sendable (KeyboardPermissions) -> Void
    private let system: KeyboardTapSystem
    private let config = OSAllocatedUnfairLock(initialState: HotkeyConfig())
    private let diagnostics = OSAllocatedUnfairLock(initialState: KeyboardDiagnosticState())
    private let ready = DispatchSemaphore(value: 0)
    /// Boucle du fil de l'écoute, posée une fois au démarrage.
    private var runLoop: CFRunLoop?

    // Le reste n'est touché que sur le fil de l'écoute.
    private var logic = HotkeyLogic()
    private var watch = KeyboardTapWatch()
    /// Surveillance des entrées à la dernière lecture complète des autorisations.
    private var lastListen = true
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var wake: CFRunLoopTimer?
    /// L'état matériel du clavier a vu le raccourci enfoncé lors d'un appui traité sans retard : on peut s'y fier.
    /// Sinon (état non rapporté pour cette touche, ou jamais vérifié), on fait confiance aux seuls événements.
    private var physicalStateReliable = false
    /// Au-delà, l'appui est arrivé en retard : la touche a pu être relâchée entre-temps, l'état ne prouve rien.
    private static let promptPressMilliseconds = 30

    init(deliver: @escaping @Sendable (HotkeyOutput) -> Void, unavailable: @escaping @Sendable () -> Void,
         lost: @escaping @Sendable (KeyboardPermissions) -> Void = { _ in }, system: KeyboardTapSystem = KeyboardTapSystem()) {
        self.deliver = deliver
        self.unavailable = unavailable
        self.lost = lost
        self.system = system
    }

    func start() {
        guard runLoop == nil else { return }
        let thread = Thread { [self] in run() }
        thread.name = "wispad.clavier"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func update(_ change: @escaping @Sendable (inout HotkeyConfig) -> Void) {
        config.withLock { change(&$0) }
    }

    var diagnosticState: KeyboardDiagnosticState {
        var result = diagnostics.withLock { $0 }
        let current = config.withLock { $0 }
        result.capturing = current.capturing
        result.pending = current.pending
        result.recordingShortcut = current.recording
        return result
    }

    /// La dictée s'est terminée autrement que par le geste (annulation, échec, ■, menu).
    func endSession() {
        perform { $0.logic.endSession() }
    }

    func externalToggleStarted() {
        perform { $0.logic.externalToggleStarted() }
    }

    /// Nouvel essai après une autorisation donnée dans les Réglages.
    func reinstall() {
        perform { $0.install(reportFailure: true) }
    }

    /// Sur le fil de l'écoute. Sans fil (écoute jamais démarrée, comme dans les tests), tout de suite.
    private func perform(_ work: @escaping (KeyboardTap) -> Void) {
        guard let runLoop else {
            work(self)
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in work(self) }
        CFRunLoopWakeUp(runLoop)
    }

    private func run() {
        runLoop = CFRunLoopGetCurrent()
        ready.signal()
        install(reportFailure: true)
        // macOS peut couper l'écoute sans prévenir (veille, serveur graphique relancé) : vérifiée toutes les 3 s.
        let watchdog = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3, 3, 0, 0) { [self] _ in
            checkTap()
        }
        // Toujours toutes les 3 s, à 0,3 s près : macOS peut grouper ce réveil avec d'autres au repos.
        CFRunLoopTimerSetTolerance(watchdog, 0.3)
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), watchdog, .commonModes)
        CFRunLoopRun()
    }

    /// `known` : autorisations que l'appelant vient de lire en entier, pour ne pas reposer la question à macOS.
    private func install(reportFailure: Bool, permissions known: KeyboardPermissions? = nil) {
        if let tap {
            if CFMachPortIsValid(tap) {
                // Installée avec une autorisation retirée depuis : jamais réarmée (voir `KeyboardTapWatch`).
                // Lecture complète : demande explicite (premier lancement, bouton des Réglages), jamais répétée.
                let permissions = known ?? readPermissions()
                guard watch.withdrawn(permissions) else {
                    system.enable(tap)
                    diagnostics.withLock { $0.listening = .enabled }
                    return
                }
                withdraw(permissions)
                if self.tap == nil, reportFailure { unavailable() }
                return
            }
            remove()
        }
        let permissions = known ?? readPermissions()
        guard let created = system.create(self) else {
            diagnostics.withLock { $0.listening = .unavailable }
            if reportFailure { unavailable() }
            return
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        system.enable(created)
        diagnostics.withLock { $0.listening = .enabled }
        watch.installed(with: permissions)
    }

    private func remove() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        diagnostics.withLock { $0.listening = .notStarted }
    }

    /// Surveillance de 3 s (fil de l'écoute ; tout de suite dans les tests, sans fil) : écoute coupée, invalidée,
    /// privée d'une autorisation, ou absente alors que ses autorisations sont revenues.
    func checkTap() {
        guard let tap else {
            let permissions = readPermissions()
            if watch.missingTap(permissions) == .install { install(reportFailure: false, permissions: permissions) }
            return
        }
        if !CFMachPortIsValid(tap) {
            let permissions = readPermissions()
            guard !watch.withdrawn(permissions) else {
                withdraw(permissions)
                return
            }
            diagnostics.withLock { $0.listening = .disabled; $0.recoveries += 1 }
            hotkeyLog.notice("Écoute du clavier invalidée : recréée")
            remove()
            resync()
            install(reportFailure: false, permissions: permissions)
            return
        }
        // Écoute active : chaque frappe du Mac attend ce fil, seule l'accessibilité (lue en mémoire) est relue ; un
        // retrait de la surveillance des entrées se voit dès que macOS coupe ou invalide l'écoute. Coupée, elle ne
        // retient plus rien : la lecture complète est sans risque.
        let enabled = system.isEnabled(tap)
        let permissions = enabled ? quickPermissions() : readPermissions()
        switch watch.installedTap(enabled: enabled, permissions: permissions) {
        case .remove:
            withdraw(enabled ? nil : permissions)
        case .reenable:
            diagnostics.withLock { $0.recoveries += 1 }
            hotkeyLog.notice("Écoute du clavier désactivée : réactivée")
            resync()
            system.enable(tap)
            diagnostics.withLock { $0.listening = .enabled }
        case .keep, .install:
            if logic.chordDown, physicalStateReliable {
                // Écoute active mais qui a pu ne rien recevoir (saisie sécurisée, écran verrouillé, autre session,
                // veille) : un relâchement qu'elle n'a pas vu ne laisse ni dictée ouverte, ni raccourci bloqué.
                apply(logic.reconcile(keyPhysicallyDown: keyIsDown(), at: Self.now()))
            }
        }
    }

    /// Une autorisation dont dépendait l'écoute a été retirée dans Réglages Système. Elle n'est jamais réarmée :
    /// active en tête de la session, elle pourrait retenir les frappes de tout le Mac. Une écoute neuve est tentée
    /// si les autorisations restantes le permettent ; sinon le geste en cours est oublié, et l'app arrête la dictée
    /// qu'il tenait en disant pourquoi. La surveillance de 3 s la réinstallera quand l'autorisation reviendra.
    /// `known` : lecture complète déjà faite ; sinon, elle est faite une fois l'écoute retirée.
    private func withdraw(_ known: KeyboardPermissions? = nil) {
        hotkeyLog.notice("Autorisation retirée : écoute du clavier retirée")
        remove()
        let permissions = known ?? readPermissions()
        if watch.missingTap(permissions) == .install { install(reportFailure: false, permissions: permissions) }
        guard tap == nil else {
            resync()
            return
        }
        schedule(nil)
        logic.listeningLost()
        diagnostics.withLock { $0.listening = .unavailable }
        lost(permissions)
    }

    /// Lecture complète des autorisations, quand l'écoute ne retient aucune frappe (absente, coupée, invalidée) ou à
    /// une installation.
    private func readPermissions() -> KeyboardPermissions {
        let permissions = system.permissions()
        lastListen = permissions.listen
        return permissions
    }

    /// Écoute active : l'accessibilité relue, la surveillance des entrées gardée de la dernière lecture complète.
    private func quickPermissions() -> KeyboardPermissions {
        KeyboardPermissions(listen: lastListen, accessibility: system.accessibilityTrusted())
    }

    /// Des frappes ont pu se perdre pendant la coupure : l'état du raccourci est recalé sur la touche réelle.
    private func resync() {
        apply(logic.resync(keyPhysicallyDown: physicalStateReliable ? keyIsDown() : logic.chordDown, at: Self.now()))
    }

    /// Rappel de l'écoute (fil de l'écoute ; appelé directement par les tests, sans fil).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let phase: KeyPhase
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            diagnostics.withLock { $0.listening = .disabled }
            // Coupée, l'écoute ne retient plus aucune frappe : la lecture complète est sans risque.
            guard !watch.withdrawn(readPermissions()) else {
                // Coupée parce qu'une autorisation a été retirée : jamais réarmée. Retirée juste après ce rappel,
                // comme par la surveillance de 3 s, plutôt que pendant le service de sa propre source.
                perform { $0.checkTap() }
                return Unmanaged.passUnretained(event)
            }
            diagnostics.withLock { $0.recoveries += 1 }
            hotkeyLog.notice("Écoute du clavier coupée par macOS (\(type == .tapDisabledByTimeout ? "lenteur" : "saisie sécurisée", privacy: .public)) : réactivée")
            if let tap {
                system.enable(tap)
                diagnostics.withLock { $0.listening = .enabled }
            }
            resync()
            return Unmanaged.passUnretained(event)
        case .keyDown: phase = .down
        case .keyUp: phase = .up
        case .flagsChanged: phase = .flags
        default: return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let key = KeyEvent(
            phase: phase,
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags.rawValue,
            autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            time: Self.time(of: event)
        )
        let output = logic.handle(key, config: config.withLock { $0 })
        if let pressed = output.pressedAt, Self.now() - pressed < Self.promptPressMilliseconds {
            physicalStateReliable = keyIsDown()
        }
        if phase == .down, !output.swallow { Self.typed.withLock { $0 &+= 1 } }
        apply(output)
        return output.swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func apply(_ output: HotkeyOutput) {
        if case .reschedule(let time) = output.wake { schedule(time) }
        if !output.isQuiet { deliver(output) }
    }

    /// Réveil du geste (seuil de maintien, fin de l'intervalle du double appui), à l'heure dite.
    private func schedule(_ time: Int?) {
        if let wake {
            CFRunLoopTimerInvalidate(wake)
            self.wake = nil
        }
        guard let time else { return }
        let delay = Double(max(0, time - Self.now())) / 1_000
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { [self] _ in
            wake = nil
            apply(logic.tick(at: Self.now(), keyStillDown: !physicalStateReliable || keyIsDown()))
        }
        wake = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    }

    /// État physique du raccourci, lu au clavier lui-même (état matériel) et non dans la file des événements.
    private func keyIsDown() -> Bool {
        system.keyIsDown(config.withLock { $0.keyCode })
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Instant réel de la frappe : son horodatage s'il est cohérent avec l'horloge (moins de 5 s d'écart),
    /// sinon maintenant. Un fil principal occupé ne retarde ainsi plus le seuil de maintien.
    static func time(of event: CGEvent) -> Int {
        let now = now()
        let stamp = event.timestamp
        guard stamp > 0 else { return now }
        let nanoseconds = Int(stamp / 1_000_000)
        let ticks = Int(Double(stamp) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000)
        for candidate in [nanoseconds, ticks] where candidate <= now && now - candidate < 5_000 {
            return candidate
        }
        return now
    }
}

private let keyboardTapCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyboardTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
}
