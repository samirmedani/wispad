import AppKit
import SwiftUI

/// Écrans gardés en vie, comme les onglets d'une app Mac : chaque section a sa propre vue AppKit, construite une fois.
/// La quitter la retire de la fenêtre sans la détruire : y revenir ne reconstruit pas l'écran. Les sections jamais
/// ouvertes sont préparées une à une, au repos, pendant que Wispad est au premier plan.
/// Une vue détachée reste abonnée à ses données : quand Wispad passe en arrière-plan (on dicte dans une autre app),
/// seul l'écran affiché est gardé, pour qu'une fin de dictée ne recalcule pas les autres écrans.
struct SectionStack: NSViewRepresentable {
    var section: AppSection
    var make: (AppSection) -> AnyView
    var onShow: (AppSection) -> Void = { _ in }
    var canWarmUp: () -> Bool = { true }

    func makeNSView(context: Context) -> SectionContainer {
        let container = SectionContainer(make: make)
        container.onShow = onShow
        container.canWarmUp = canWarmUp
        container.show(section)
        return container
    }

    func updateNSView(_ container: SectionContainer, context: Context) {
        container.show(section)
    }
}

@MainActor
final class SectionContainer: NSView {
    private let make: (AppSection) -> AnyView
    private var hosts: [AppSection: NSHostingView<AnyView>] = [:]
    private(set) var current: AppSection?
    private var warmUp: DispatchWorkItem?
    /// Appelé à chaque arrivée sur une section (y compris la première) : l'écran relance ce qu'il rafraîchissait à
    /// son apparition (autorisations, soldes).
    var onShow: ((AppSection) -> Void)?
    /// Préparation d'une section en attente, seulement si l'app est libre (aucune dictée en cours).
    var canWarmUp: () -> Bool = { true }

    #if DEBUG
    /// `--no-section-cache` : comportement d'avant, chaque écran est reconstruit à chaque visite (comparaison).
    static let keepsSections = !CommandLine.arguments.contains("--no-section-cache")
    #else
    static let keepsSections = true
    #endif

    /// Première préparation après l'ouverture de la fenêtre, puis une section à la fois.
    static let warmUpDelay: TimeInterval = 0.8
    static let warmUpSpacing: TimeInterval = 0.25

    init(make: @escaping (AppSection) -> AnyView) {
        self.make = make
        super.init(frame: .zero)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appResigned), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivated), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// Wispad passe en arrière-plan : seul l'écran affiché reste construit.
    @objc private func appResigned() {
        warmUp?.cancel()
        trimHiddenSections()
    }

    @objc private func appActivated() {
        if window != nil, Self.keepsSections { scheduleWarmUp(after: Self.warmUpDelay) }
    }

    func trimHiddenSections() {
        for section in Array(hosts.keys) where section != current { hosts[section] = nil }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Sections déjà construites (tests et sondes).
    var builtSections: Set<AppSection> { Set(hosts.keys) }

    func show(_ section: AppSection) {
        guard section != current else { return }
        let host = host(for: section)
        if let current, let previous = hosts[current] {
            previous.removeFromSuperview()
            if !Self.keepsSections { hosts[current] = nil }
        }
        host.alphaValue = 1
        host.frame = bounds
        addSubview(host)
        current = section
        onShow?(section)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, Self.keepsSections { scheduleWarmUp(after: Self.warmUpDelay) }
    }

    override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }

    private func host(for section: AppSection) -> NSHostingView<AnyView> {
        if let host = hosts[section] { return host }
        let host = NSHostingView(rootView: make(section))
        // La taille vient du conteneur : pas de contraintes tirées du contenu SwiftUI.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        hosts[section] = host
        return host
    }

    private func scheduleWarmUp(after delay: TimeInterval) {
        warmUp?.cancel()
        guard AppSection.allCases.contains(where: { hosts[$0] == nil }) else { return }
        let item = DispatchWorkItem { [weak self] in self?.warmUpNext() }
        warmUp = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Construit, met en page et dessine une section jamais ouverte, invisible sous l'écran courant, puis la détache.
    private func warmUpNext() {
        // Aperçu hors écran : l'app ne passe jamais au premier plan, la préparation y est mesurée quand même.
        let offscreen = window is OffscreenWindow
        guard window?.isVisible == true || offscreen, NSApp.isActive || offscreen,
              let section = AppSection.allCases.first(where: { hosts[$0] == nil }) else { return }
        guard canWarmUp() else {
            scheduleWarmUp(after: 1)
            return
        }
        let host = host(for: section)
        host.alphaValue = 0
        host.frame = bounds
        addSubview(host, positioned: .below, relativeTo: nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        if current != section { host.removeFromSuperview() } else { host.alphaValue = 1 }
        scheduleWarmUp(after: Self.warmUpSpacing)
    }
}
