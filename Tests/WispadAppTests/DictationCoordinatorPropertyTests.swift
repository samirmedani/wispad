import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

// Filet anti-régression du coordinateur de dictée, par séquences tirées d'une graine fixe. Chaque séquence joue, sur
// une app neuve et les faux de `AppDependencies`, des gestes du raccourci passés par la vraie logique du clavier
// (`HotkeyLogic`), des boutons de la bulle et du menu, un micro qui ne démarre pas ou qui tombe, des fournisseurs
// lents, en erreur ou hors connexion, une correction lente ou en échec, des collages réussis, refusés, sans champ ou
// dans un champ sécurisé, « Coller la dernière dictée », l'écoute du clavier coupée ou retirée, l'accès au micro
// retiré et des mots corrigés. Les délais simulés sont courts. Après chaque événement :
// - micro, spectre et son coupé du Mac sont fermés hors de l'écoute, et `stop()` n'attend jamais le micro ;
// - jamais deux collages pour une dictée, jamais de collage après une annulation, toujours dans l'ordre dicté ;
// - une dictée n'apparaît qu'une fois dans l'historique ; copie et surveillance des corrections suivent un collage ;
// - l'écoute du clavier sait si une dictée écoute ou se termine (Échap avalé ou non).
// En fin de séquence : retour au repos dans une borne de temps ; chaque dictée terminée et entendue est dans
// l'historique une seule fois, avec le statut de ce qui s'est passé ; raccourci libre (geste au repos, un double
// appui écoute aussitôt) ; flux refermés ; plus aucun objet de dictée en vie (références faibles).
// Aucun micro, réseau, clé, collage ni son réels.

// MARK: - Tirages

/// Générateur à graine fixe (SplitMix64), le même que `SeededGenerator` des tests de WispadCore : mêmes séquences
/// d'une machine ou d'une version de Swift à l'autre.
private struct ModelRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    /// Vrai `percent` fois sur cent.
    mutating func chance(_ percent: Int) -> Bool {
        int(0...99) < percent
    }
}

/// Séquences jouées : un quart par défaut (au moins 25), toutes avec `WISPAD_PROPERTY_RUNS=full`, comme `forAll`
/// dans les tests de propriétés de WispadCore.
private func modelRuns(_ count: Int) -> Int {
    ProcessInfo.processInfo.environment["WISPAD_PROPERTY_RUNS"] == "full" ? count : max(min(count, 25), count / 4)
}

/// Délai d'un fournisseur, en ms : souvent immédiat, parfois lent.
private func latency(_ g: inout ModelRandom) -> Int {
    switch g.int(0...99) {
    case 0..<35: return 0
    case 35..<80: return g.int(1...15)
    default: return g.int(30...200)
    }
}

// MARK: - Plans des faux

/// Micro d'une dictée.
private enum MicPlan: Equatable, Sendable {
    /// Ouvert tout de suite, premier paquet aussitôt.
    case normal
    /// Rend la main après le délai de démarrage : la dictée l'abandonne.
    case slow
    /// Moteur refusé (aucun micro).
    case refused
    /// Accès au micro refusé.
    case denied
    /// Ouvert sans aucun paquet : la dictée le redémarre sur un moteur neuf.
    case silent(MicRestart)

    var emitsOnStart: Bool {
        if case .silent = self { return false }
        return true
    }

    var label: String {
        switch self {
        case .normal: return "micro"
        case .slow: return "micro lent"
        case .refused: return "micro refusé"
        case .denied: return "micro interdit"
        case .silent(.hears): return "micro muet puis entendu"
        case .silent(.staysSilent): return "micro muet"
        case .silent(.fails): return "micro muet, moteur neuf refusé"
        case .silent(.hangs): return "micro muet, moteur neuf bloqué"
        }
    }
}

/// Moteur neuf d'un micro muet.
private enum MicRestart: Equatable, Sendable {
    case hears
    case staysSilent
    case fails
    case hangs
}

/// Ce que rend le fichier : le même texte que le flux, un autre, ou rien.
private enum FileText: Equatable, Sendable {
    case same
    case different
    case empty
}

/// Fournisseurs d'une dictée : flux en direct, fichier, relais et correction (délais en ms).
private struct ProviderPlan: Sendable {
    var streamStartMs = 0
    var streamStartFails = false
    var streamFinishMs = 0
    var streamFinishFails = false
    var streamSilent = false
    /// Le flux signale une pause : une correction se prépare pendant l'écoute.
    var settles = false
    var fileMs = 0
    var fileFails = false
    var fileText = FileText.same
    var relayMs = 0
    var relayFails = false
    var cleanMs = 0
    var cleanFails = false

    var label: String {
        var parts: [String] = []
        if streamStartFails { parts.append("flux refusé") }
        if streamFinishFails { parts.append("flux coupé") }
        if streamSilent { parts.append("flux vide") }
        if fileFails { parts.append("fichier en échec") }
        if fileText != .same { parts.append(fileText == .empty ? "fichier vide" : "fichier différent") }
        if max(streamStartMs, streamFinishMs, fileMs) >= 30 { parts.append("voix lente") }
        if cleanFails { parts.append("correction en échec") } else if cleanMs >= 30 { parts.append("correction lente") }
        return parts.joined(separator: ", ")
    }
}

/// Un collage : refusé avant ⌘V (aucun champ, champ sécurisé, accessibilité retirée) ou envoyé (confirmé, sans
/// confirmation possible, texte pas arrivé). Délais en ms : lecture du champ, confirmation, presse-papiers gardé.
private struct PastePlan: Sendable {
    enum Outcome: Equatable, Sendable {
        case inserted
        case pasteSent
        case notArrived
        case noTarget
        case secure
        case untrusted
    }

    var outcome = Outcome.inserted
    var readMs = 0
    var confirmMs = 0
    var holdMs = 0

    static func draw(_ g: inout ModelRandom) -> PastePlan {
        var plan = PastePlan()
        switch g.int(0...99) {
        case 0..<55: plan.outcome = .inserted
        case 55..<70: plan.outcome = .pasteSent
        case 70..<78: plan.outcome = .notArrived
        case 78..<89: plan.outcome = .noTarget
        case 89..<96: plan.outcome = .secure
        default: plan.outcome = .untrusted
        }
        plan.readMs = g.int(0...10)
        plan.confirmMs = g.int(0...30)
        plan.holdMs = g.int(0...20)
        return plan
    }
}

/// Tout ce que les faux feront pour une dictée.
private struct DictationPlan: Sendable {
    var mic = MicPlan.normal
    /// Secondes d'audio ; 0 : trop court pour être envoyé.
    var seconds = 2
    var providers = ProviderPlan()
    var paste = PastePlan()

    var label: String {
        let audio = seconds == 0 ? "trop court" : "\(seconds) s"
        let providers = self.providers.label
        return [mic.label, audio, providers, "collage \(paste.outcome)"].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func draw(_ g: inout ModelRandom) -> DictationPlan {
        var plan = DictationPlan()
        switch g.int(0...99) {
        case 0..<78: plan.mic = .normal
        case 78..<82: plan.mic = .slow
        case 82..<85: plan.mic = .refused
        case 85..<87: plan.mic = .denied
        case 87..<91: plan.mic = .silent(.hears)
        case 91..<94: plan.mic = .silent(.staysSilent)
        case 94..<97: plan.mic = .silent(.fails)
        default: plan.mic = .silent(.hangs)
        }
        plan.seconds = g.chance(12) ? 0 : g.int(1...5)
        var providers = ProviderPlan()
        providers.streamStartMs = latency(&g)
        providers.streamStartFails = g.chance(8)
        providers.streamFinishMs = latency(&g)
        providers.streamFinishFails = g.chance(8)
        providers.streamSilent = g.chance(8)
        providers.settles = g.chance(30)
        providers.fileMs = g.chance(2) ? 1_400 : latency(&g)
        providers.fileFails = g.chance(15)
        switch g.int(0...9) {
        case 0..<6: providers.fileText = .same
        case 6..<9: providers.fileText = .different
        default: providers.fileText = .empty
        }
        providers.relayMs = latency(&g)
        providers.relayFails = g.chance(40)
        providers.cleanMs = latency(&g)
        providers.cleanFails = g.chance(12)
        plan.providers = providers
        plan.paste = PastePlan.draw(&g)
        return plan
    }
}

// MARK: - Séquences

/// Un événement : geste du raccourci, bouton de la bulle ou du menu, micro, réseau, mot corrigé, ou simple attente.
private enum ModelStep: Equatable, Sendable {
    /// fn enfoncée et tenue au-delà du seuil de maintien.
    case hold
    /// fn relâchée.
    case release
    case doubleTap
    /// Appui simple (il arrête une dictée mains libres).
    case tap
    case escape
    /// ⌃⌥V : « Coller la dernière dictée ».
    case pasteLast
    /// ✕ d'un message de la bulle.
    case closeMessage
    /// ■ de la bulle en mains libres.
    case bubbleStop
    /// ✕ de la bulle en mains libres.
    case bubbleCancel
    /// Menu de la barre : « Dicter (mains libres) » ou « Terminer la dictée ».
    case menuToggle
    /// Coller, dans la carte du texte prêt.
    case pasteButton
    /// Copier, dans la carte du texte prêt.
    case copyButton
    /// Micro débranché en pleine écoute, sans autre micro.
    case microphoneLost
    /// Écoute du clavier coupée par macOS ; fn relâchée pendant la coupure.
    case keyboardCut
    /// Écoute du clavier retirée faute d'autorisation (`keyboardLost`), puis rendue.
    case keyboardWithdrawn
    case keyboardBack
    /// Accès au micro retiré dans Réglages Système, puis rendu.
    case microphoneRevoked
    case microphoneRestored
    case offline
    case online
    /// Un mot corrigé à la main dans le champ surveillé.
    case correctWord
    case wait(Int)

    var label: String {
        switch self {
        case .hold: return "maintien"
        case .release: return "relâche"
        case .doubleTap: return "double appui"
        case .tap: return "appui"
        case .escape: return "Échap"
        case .pasteLast: return "⌃⌥V"
        case .closeMessage: return "✕ message"
        case .bubbleStop: return "■"
        case .bubbleCancel: return "✕ écoute"
        case .menuToggle: return "menu"
        case .pasteButton: return "Coller"
        case .copyButton: return "Copier"
        case .microphoneLost: return "micro perdu"
        case .keyboardCut: return "écoute du clavier coupée"
        case .keyboardWithdrawn: return "écoute du clavier retirée"
        case .keyboardBack: return "écoute du clavier rendue"
        case .microphoneRevoked: return "accès au micro retiré"
        case .microphoneRestored: return "accès au micro rendu"
        case .offline: return "hors connexion"
        case .online: return "connexion"
        case .correctWord: return "mot corrigé"
        case .wait(let milliseconds): return "attente \(milliseconds) ms"
        }
    }

    static func draw(_ g: inout ModelRandom) -> ModelStep {
        switch g.int(0...99) {
        case 0..<13: return .hold
        case 13..<26: return .release
        case 26..<37: return .doubleTap
        case 37..<44: return .tap
        case 44..<52: return .escape
        case 52..<57: return .pasteLast
        case 57..<61: return .closeMessage
        case 61..<64: return .bubbleStop
        case 64..<66: return .bubbleCancel
        case 66..<69: return .menuToggle
        case 69..<72: return .pasteButton
        case 72..<74: return .copyButton
        case 74..<77: return .microphoneLost
        case 77..<79: return .keyboardCut
        case 79..<81: return .keyboardWithdrawn
        case 81..<83: return .keyboardBack
        case 83..<85: return .microphoneRevoked
        case 85..<87: return .microphoneRestored
        case 87..<89: return .offline
        case 89..<91: return .online
        case 91..<93: return .correctWord
        default: return .wait(g.int(10...150))
        }
    }
}

/// Temps laissé au fil principal après un événement.
private enum ModelPause: Equatable, Sendable {
    /// Aucun : l'événement suivant arrive avant que le fil principal ait repris la main (fil occupé).
    case immediate
    case yield
    case milliseconds(Int)

    static func draw(_ g: inout ModelRandom) -> ModelPause {
        switch g.int(0...99) {
        case 0..<15: return .immediate
        case 15..<35: return .yield
        case 35..<85: return .milliseconds(g.int(1...8))
        case 85..<97: return .milliseconds(g.int(20...60))
        default: return .milliseconds(g.int(100...200))
        }
    }
}

private struct ModelSequence: Sendable {
    var verifyWithFile = true
    var cleanupEnabled = true
    var learnCorrections = true
    var muteWhileDictating = false
    /// Dictée n : `plans[(n - 1) % plans.count]`.
    var plans = [DictationPlan()]
    /// Collages demandés (« Coller la dernière dictée », bouton Coller), dans l'ordre.
    var pastes = [PastePlan()]
    var steps: [ModelStep] = []
    var pauses: [ModelPause] = []

    static func draw(_ g: inout ModelRandom) -> ModelSequence {
        var sequence = ModelSequence()
        sequence.verifyWithFile = g.chance(80)
        sequence.cleanupEnabled = g.chance(80)
        sequence.learnCorrections = g.chance(60)
        sequence.muteWhileDictating = g.chance(25)
        sequence.plans = []
        for _ in 0..<6 { sequence.plans.append(DictationPlan.draw(&g)) }
        sequence.pastes = []
        for _ in 0..<4 { sequence.pastes.append(PastePlan.draw(&g)) }
        let count = g.int(5...14)
        for _ in 0..<count {
            sequence.steps.append(ModelStep.draw(&g))
            sequence.pauses.append(ModelPause.draw(&g))
        }
        return sequence
    }

    /// Séquence écrite à la main : chaque pas suivi de sa pause (aucune par défaut).
    static func scripted(_ steps: [(ModelStep, ModelPause)], plans: [DictationPlan]) -> ModelSequence {
        var sequence = ModelSequence()
        sequence.plans = plans
        sequence.steps = steps.map { $0.0 }
        sequence.pauses = steps.map { $0.1 }
        return sequence
    }
}

// MARK: - Micro et flux simulés (appelés hors du fil principal)

/// Micro du Mac simulé, partagé par les dictées comme `AudioCapture.shared` : une file pour ses démarrages et
/// redémarrages, les écoutes ouvertes, et ce que la dictée ne doit jamais lui demander. Les flux simulés y notent
/// aussi leurs appels. Tout passe par un verrou.
private final class FuzzHardware: @unchecked Sendable {
    private struct Recording {
        var url: URL
        /// Au moins un paquet reçu : sans paquet, le fichier ne dure rien.
        var heard = false
        /// La dictée ne l'attend plus : il se referme seul à la fin de l'opération en cours.
        var abandoned = false
        var interrupted = false
    }

    private let lock = NSLock()
    private var queueBusy = false
    private var queue: [AsyncResult<Void>] = []
    private var recordings: [Int: Recording] = [:]
    private var operations: [Int: String] = [:]
    private var abandonedMicrophones: Set<Int> = []
    private var online = true
    private var microphoneAccess = true
    private var calls = 0
    private var heardDictations: Set<Int> = []
    private var streamsCreated: Set<Int> = []
    private var streamsClosed: Set<Int> = []
    private var problems: [String] = []

    var isOnline: Bool {
        get { lock.withLock { online } }
        set { lock.withLock { online = newValue } }
    }

    /// Accès au micro accordé dans Réglages Système, lu hors du fil principal.
    var microphoneAuthorized: Bool {
        get { lock.withLock { microphoneAccess } }
        set { lock.withLock { microphoneAccess = newValue } }
    }

    func takeProblems() -> [String] {
        lock.withLock {
            let taken = problems
            problems.removeAll()
            return taken
        }
    }

    /// File du micro, comme la file `control` de `AudioCapture` : une opération attend la fin de la précédente.
    func enterQueue() async {
        let turn: AsyncResult<Void>? = lock.withLock {
            guard queueBusy else {
                queueBusy = true
                return nil
            }
            let waiter = AsyncResult<Void>()
            queue.append(waiter)
            return waiter
        }
        if let turn { try? await turn.value() }
    }

    func leaveQueue() {
        let next: AsyncResult<Void>? = lock.withLock {
            guard !queue.isEmpty else {
                queueBusy = false
                return nil
            }
            return queue.removeFirst()
        }
        next?.resolve(.success(()))
    }

    func beginOperation(_ number: Int, _ name: String) {
        lock.withLock { operations[number] = name }
    }

    /// Fin d'un démarrage ou d'un redémarrage : abandonné, ce qu'il a ouvert se referme à son tour.
    func endOperation(_ number: Int) {
        lock.withLock {
            operations[number] = nil
            if abandonedMicrophones.contains(number) { recordings[number] = nil }
        }
    }

    func isAbandoned(_ number: Int) -> Bool {
        lock.withLock { abandonedMicrophones.contains(number) }
    }

    func isStarting(_ number: Int) -> Bool {
        lock.withLock { operations[number] == "démarrage" }
    }

    func isRestarting(_ number: Int) -> Bool {
        lock.withLock { operations[number] == "redémarrage" }
    }

    /// Une écoute s'ouvre. Une autre encore ouverte, ni arrêtée ni abandonnée par sa dictée, serait perdue : le vrai
    /// micro n'en tient qu'une.
    func open(_ number: Int, url: URL) {
        lock.withLock {
            let others = recordings.filter { $0.key != number && !$0.value.abandoned }.keys.sorted()
            if !others.isEmpty {
                problems.append("micro de la dictée \(number) ouvert pendant l'écoute de la dictée \(others)")
            }
            recordings[number] = Recording(url: url)
        }
    }

    func isOpen(_ number: Int) -> Bool {
        lock.withLock { recordings[number] != nil }
    }

    /// Un paquet audio, seulement pendant une écoute ouverte.
    func hear(_ number: Int) -> Bool {
        lock.withLock {
            guard recordings[number] != nil else { return false }
            recordings[number]?.heard = true
            return true
        }
    }

    func close(_ number: Int) {
        lock.withLock { recordings[number] = nil }
    }

    /// `abandonStart()` : l'opération en cours se refermera seule ; sans opération, l'écoute se referme à son tour.
    func abandon(_ number: Int) {
        lock.withLock {
            abandonedMicrophones.insert(number)
            if operations[number] == nil {
                recordings[number] = nil
            } else {
                recordings[number]?.abandoned = true
            }
        }
    }

    /// `stop()` du vrai micro passe par sa file (`control.sync`) : il attendrait, sur le fil principal, la fin du
    /// démarrage ou du redémarrage en cours.
    func stop(_ number: Int, seconds: Double) -> (url: URL?, duration: Double) {
        lock.withLock {
            if let operation = operations[number] {
                problems.append("stop() pendant le \(operation) du micro de la dictée \(number) : le vrai micro bloquerait le fil principal jusqu'à sa fin")
            } else if queueBusy {
                problems.append("stop() du micro de la dictée \(number) pendant une opération d'un autre micro : le fil principal l'attendrait")
            }
            guard let recording = recordings.removeValue(forKey: number) else { return (url: nil, duration: 0) }
            return (url: recording.url, duration: recording.heard ? seconds : 0)
        }
    }

    /// Micro débranché en pleine écoute : signalé une fois, seulement pendant une écoute ouverte.
    func interrupt(_ number: Int) -> Bool {
        lock.withLock {
            guard let recording = recordings[number], !recording.abandoned, !recording.interrupted else { return false }
            recordings[number]?.interrupted = true
            return true
        }
    }

    /// Écoutes ouvertes que leur dictée n'a ni arrêtées ni abandonnées.
    var openMicrophones: [Int] {
        lock.withLock { recordings.filter { !$0.value.abandoned }.keys.sorted() }
    }

    /// Une opération du micro est en cours ou en attente.
    var microphoneBusy: Bool {
        lock.withLock { queueBusy || !operations.isEmpty }
    }

    func enterCall() {
        lock.withLock { calls += 1 }
    }

    func leaveCall() {
        lock.withLock { calls -= 1 }
    }

    var callsInFlight: Int {
        lock.withLock { calls }
    }

    /// Un fournisseur a rendu du texte pour cette dictée.
    func noteHeard(_ number: Int) {
        lock.withLock { _ = heardDictations.insert(number) }
    }

    func wasHeard(_ number: Int) -> Bool {
        lock.withLock { heardDictations.contains(number) }
    }

    func noteStream(_ number: Int) {
        lock.withLock { _ = streamsCreated.insert(number) }
    }

    func closeStream(_ number: Int) {
        lock.withLock { _ = streamsClosed.insert(number) }
    }

    var unclosedStreams: [Int] {
        lock.withLock { streamsCreated.subtracting(streamsClosed).sorted() }
    }
}

/// Clés de l'app lues tard (coffre de secrets lent) : aucune clé tant que la relecture n'a pas rendu la main.
private final class LateKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var waiters: [AsyncResult<Void>] = []

    var isLoaded: Bool { lock.withLock { loaded } }

    /// Une relecture attend les clés.
    var isReading: Bool { lock.withLock { !waiters.isEmpty } }

    func refresh() async {
        let waiter: AsyncResult<Void>? = lock.withLock {
            guard !loaded else { return nil }
            let waiter = AsyncResult<Void>()
            waiters.append(waiter)
            return waiter
        }
        if let waiter { try? await waiter.value() }
    }

    func load() {
        let released: [AsyncResult<Void>] = lock.withLock {
            loaded = true
            let released = waiters
            waiters.removeAll()
            return released
        }
        for waiter in released { waiter.resolve(.success(())) }
    }
}

/// Micro d'une dictée, sur le micro simulé partagé.
private final class FuzzMicrophone: AudioRecording, @unchecked Sendable {
    let number: Int
    let plan: MicPlan
    let seconds: Double
    /// Durée d'un démarrage ou d'un redémarrage qui ne rend pas la main à temps.
    let hangSeconds: Double
    let hardware: FuzzHardware
    @Guarded var onPCM: (@Sendable (Data) -> Void)? = nil
    @Guarded var onInterruption: (@Sendable () -> Void)? = nil
    @Guarded var inputDeviceUID: String? = nil
    let bands = Array(repeating: Float(0.3), count: SpectrumAnalyzer.bandCount)

    init(number: Int, plan: MicPlan, seconds: Double, hangSeconds: Double, hardware: FuzzHardware) {
        self.number = number
        self.plan = plan
        self.seconds = seconds
        self.hangSeconds = hangSeconds
        self.hardware = hardware
    }

    func start(directory: URL) async throws -> URL {
        await hardware.enterQueue()
        defer { hardware.leaveQueue() }
        hardware.beginOperation(number, "démarrage")
        defer { hardware.endOperation(number) }
        switch plan {
        case .slow:
            try? await Task.sleep(nanoseconds: UInt64(hangSeconds * 1_000_000_000))
        case .refused:
            throw AudioCaptureError.noInput
        case .normal, .denied, .silent:
            await Task.yield()
        }
        // Abandonné pendant le démarrage : rien n'est ouvert, comme `AudioCapture`.
        guard !hardware.isAbandoned(number) else { throw CancellationError() }
        let url = directory.appendingPathComponent("dictee-\(number)-\(UUID().uuidString).wav")
        try Data(repeating: 0, count: 64).write(to: url)
        hardware.open(number, url: url)
        if plan.emitsOnStart { packet() }
        return url
    }

    func stop() -> (url: URL?, duration: Double) {
        hardware.stop(number, seconds: seconds)
    }

    func restart() async throws {
        await hardware.enterQueue()
        defer { hardware.leaveQueue() }
        hardware.beginOperation(number, "redémarrage")
        defer { hardware.endOperation(number) }
        guard hardware.isOpen(number), case .silent(let restart) = plan else { return }
        switch restart {
        case .hears:
            await Task.yield()
            packet()
        case .staysSilent:
            await Task.yield()
        case .fails:
            hardware.close(number)
            throw AudioCaptureError.engine("Moteur refusé.")
        case .hangs:
            try? await Task.sleep(nanoseconds: UInt64(hangSeconds * 1_000_000_000))
        }
    }

    func abandonStart() {
        hardware.abandon(number)
    }

    /// Micro débranché en pleine écoute, sans autre micro : signalé une fois, comme `AudioCapture`.
    func interrupt() {
        guard hardware.interrupt(number) else { return }
        onInterruption?()
    }

    private func packet() {
        guard hardware.hear(number) else { return }
        onPCM?(Data(repeating: 1, count: 640))
    }
}

/// Flux en direct d'une dictée.
private final class FuzzStream: SpeechStreaming, @unchecked Sendable {
    let number: Int
    let plan: ProviderPlan
    let text: String
    let hardware: FuzzHardware
    @Guarded var onPartial: (@Sendable (String) -> Void)? = nil
    @Guarded var onSettled: (@Sendable (String) -> Void)? = nil

    init(number: Int, plan: ProviderPlan, text: String, hardware: FuzzHardware) {
        self.number = number
        self.plan = plan
        self.text = text
        self.hardware = hardware
    }

    func start() async throws {
        hardware.enterCall()
        defer { hardware.leaveCall() }
        try await Task.sleep(nanoseconds: UInt64(plan.streamStartMs) * 1_000_000)
        guard hardware.isOnline else { throw URLError(.notConnectedToInternet) }
        guard !plan.streamStartFails else { throw URLError(.badServerResponse) }
        guard !text.isEmpty else { return }
        onPartial?(text)
        if plan.settles { onSettled?(text) }
    }

    func send(_ data: Data) {}

    func finish() async throws -> StreamFinish {
        hardware.enterCall()
        defer { hardware.leaveCall() }
        try await Task.sleep(nanoseconds: UInt64(plan.streamFinishMs) * 1_000_000)
        guard hardware.isOnline else { throw URLError(.networkConnectionLost) }
        guard !plan.streamFinishFails else { throw URLError(.badServerResponse) }
        if !text.isEmpty { hardware.noteHeard(number) }
        return StreamFinish(text: text, endingFinalized: true)
    }

    func cancel() {
        hardware.closeStream(number)
    }
}

// MARK: - Clavier simulé

/// Écoute du clavier simulée : la vraie logique du raccourci (`HotkeyLogic`) sur une horloge simulée. Elle reçoit ce
/// que la dictée dit à l'écoute réelle (`HotkeyControl`) et transmet ses effets comme `HotkeyMonitor`.
@MainActor
private final class FuzzKeyboard: HotkeyControl {
    private(set) var logic = HotkeyLogic()
    private(set) var config = HotkeyConfig(paste: .standard)
    private(set) var now = 10_000
    private(set) var fnHeld = false
    /// Écoute installée : retirée faute d'autorisation, elle ne voit plus aucune frappe.
    private(set) var listening = true
    private var wake: Int?
    /// Sortie du raccourci (geste, Échap, ⌃⌥V), transmise à la dictée comme `HotkeyMonitor.receive`.
    var receive: ((HotkeyOutput) -> Void)?

    var diagnosticState: KeyboardDiagnosticState { KeyboardDiagnosticState() }

    func refreshConfig() {}

    func setDictationState(capturing: Bool, pending: Bool) {
        config.capturing = capturing
        config.pending = pending
    }

    func installTap() {}

    func sessionEnded() {
        logic.endSession()
    }

    func externalToggleStarted() {
        logic.externalToggleStarted()
    }

    /// Le temps passe : chaque réveil échu du geste lit l'état réel de fn.
    func advance(by milliseconds: Int) {
        let target = now + milliseconds
        while let due = wake, due <= target {
            wake = nil
            now = max(now, due)
            apply(logic.tick(at: due, keyStillDown: fnHeld))
        }
        now = target
    }

    func pressFn() {
        fnHeld = true
        see(KeyEvent(phase: .flags, keyCode: ChordMatcher.functionKeyCode, flags: ModifierMask.function, time: now))
    }

    func releaseFn() {
        fnHeld = false
        see(KeyEvent(phase: .flags, keyCode: ChordMatcher.functionKeyCode, flags: 0, time: now))
    }

    func doubleTap() {
        pressFn()
        advance(by: 40)
        releaseFn()
        advance(by: 40)
        pressFn()
        advance(by: 40)
        releaseFn()
        advance(by: 30)
    }

    func tap() {
        pressFn()
        advance(by: 40)
        releaseFn()
        advance(by: 400)
    }

    func escape() {
        let flags = fnHeld ? ModifierMask.function : 0
        see(KeyEvent(phase: .down, keyCode: HotkeyLogic.escapeKeyCode, flags: flags, time: now))
        see(KeyEvent(phase: .up, keyCode: HotkeyLogic.escapeKeyCode, flags: flags, time: now))
    }

    func pasteChord() {
        let flags = ModifierMask.control | ModifierMask.option | (fnHeld ? ModifierMask.function : 0)
        see(KeyEvent(phase: .down, keyCode: PasteShortcut.vKeyCode, flags: flags, time: now))
        see(KeyEvent(phase: .up, keyCode: PasteShortcut.vKeyCode, flags: flags, time: now))
    }

    /// macOS coupe l'écoute ; fn est relâchée pendant la coupure, puis l'écoute revient et se recale sur la touche
    /// réelle (`KeyboardTap.resync`).
    func cut() {
        fnHeld = false
        guard listening else { return }
        apply(logic.resync(keyPhysicallyDown: false, at: now))
    }

    /// Autorisation retirée (`KeyboardTap.withdraw`) : l'écoute disparaît, son réveil et le geste en cours sont
    /// oubliés ; l'app arrête elle-même la dictée qu'il tenait.
    func withdraw() {
        listening = false
        wake = nil
        logic.listeningLost()
    }

    /// Autorisation rendue : une écoute neuve, sans recalage ; le premier appui compte.
    func restore() {
        listening = true
    }

    private func see(_ event: KeyEvent) {
        guard listening else { return }
        apply(logic.handle(event, config: config))
    }

    /// Comme `KeyboardTap.apply` : réveil reprogrammé, puis effets transmis s'il y en a.
    private func apply(_ output: HotkeyOutput) {
        if case .reschedule(let time) = output.wake { wake = time }
        if !output.isQuiet { receive?(output) }
    }
}

// MARK: - Monde d'une séquence

@MainActor
private final class WeakBox<Object: AnyObject> {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

private extension DictationPhase {
    /// Une dictée écoute (préparation ou écoute).
    var modelCapturing: Bool {
        switch self {
        case .starting, .listening: return true
        case .idle, .finishing, .failure: return false
        }
    }

    /// Une dictée se termine ou un message est affiché.
    var modelPending: Bool {
        switch self {
        case .finishing, .failure: return true
        case .idle, .starting, .listening: return false
        }
    }
}

/// Une app neuve, ses faux et le clavier simulé ; ce qu'ils voient pendant la séquence ; les invariants.
@MainActor
private final class ModelWorld {
    /// Ce que la séquence a vu d'une dictée.
    struct Track {
        var plan = DictationPlan()
        /// Fin de l'écoute avec de l'audio : sa fin (`FinishJob`) a commencé (son de fin).
        var ended = false
        var cancelledListening = false
        /// Échap pendant sa fin, avant son collage : plus rien ne doit être collé pour elle.
        var cancelledBeforePaste = false
        var pasteCalls = 0
        var pasted = false
        var ownResult: InsertionStatus?
        var fileCalls = 0
    }

    /// Un appel à `insert` : la dictée elle-même (`number`), ou « Coller la dernière dictée » d'une dictée (`record`).
    struct PasteCall {
        var number: Int?
        var record: Int?
        var text: String
        var pid: pid_t?
        var sent = false
        var result: InsertionStatus?
        var watched = false
    }

    static let frontmostPID: pid_t = 5_151
    /// Borne de retour au repos, large pour une machine de CI chargée.
    static let restLimit = 15.0

    let directory: URL
    let sequence: ModelSequence
    let hardware = FuzzHardware()
    let keyboard = FuzzKeyboard()
    var model: AppModel!
    let startLimit: Double
    let hangSeconds: Double
    /// Numéro de la dernière dictée commencée (la première est 1).
    private(set) var latest = 0
    private(set) var tracks: [Int: Track] = [:]
    private(set) var pasteCalls: [PasteCall] = []
    private var pasteRequests = 0
    private var pastePlansUsed = 0
    private var lastPasted: Int?
    private var mutes = 0
    private var restores = 0
    private var copying = false
    private var corrections: [@MainActor ([CorrectionLearner.Candidate]) -> Void] = []
    private var beginsRunning = 0
    /// Un départ de dictée (`begin`) est en cours.
    var isBeginning: Bool { beginsRunning > 0 }
    private var pasteTasks = 0
    private var insertsRunning = 0
    private var cleansRunning = 0
    private var filesRunning = 0
    private var probesRun = 0
    private var pasteBusy = false
    private var pasteWaiting: [AsyncResult<Void>] = []
    private var contexts: [WeakBox<DictationContext>] = []
    private var microphones: [WeakBox<FuzzMicrophone>] = []
    private var streams: [WeakBox<FuzzStream>] = []
    private(set) var violations: [String] = []
    private var log: [String] = []
    /// Dictée de contrôle de fin de séquence : micro et fournisseurs ordinaires.
    private var ordinary = false

    /// `startLimit` : délai de démarrage du micro, court pour qu'un micro bloqué coûte peu ; `hangSeconds` : durée
    /// d'un démarrage ou d'un redémarrage qui ne rend pas la main à temps ; `keys` : clés lues tard.
    init(_ sequence: ModelSequence, startLimit: Double = 0.3, hangSeconds: Double = 0.45, keys: LateKeys? = nil) throws {
        self.sequence = sequence
        self.startLimit = startLimit
        self.hangSeconds = hangSeconds
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hardware = self.hardware
        var deps = AppDependencies()
        if let keys {
            deps.loadKey = { keys.isLoaded ? "fixture-" + $0 : nil }
            deps.refreshKeys = {
                await keys.refresh()
                return true
            }
        } else {
            deps.loadKey = { "fixture-" + $0 }
            deps.refreshKeys = { true }
        }
        deps.saveKey = { _, _ in true }
        deps.deleteKey = { _ in true }
        deps.validateKey = { _ in 200 }
        deps.requestMicrophone = { [weak self] in self?.microphoneAllowed() ?? false }
        deps.microphoneAuthorized = { hardware.microphoneAuthorized }
        deps.captureContext = { [weak self] in
            let context = DictationContext()
            self?.newDictation(context)
            return (context, Task { nil })
        }
        deps.frontmostApp = {
            let context = DictationContext()
            context.pid = ModelWorld.frontmostPID
            context.appName = "Éditeur de test"
            context.bundleID = "test.editeur"
            return context
        }
        deps.readWindow = { _ in nil }
        deps.makeCapture = { [weak self] in
            self?.makeMicrophone() ?? FuzzMicrophone(number: 0, plan: .refused, seconds: 0, hangSeconds: 0, hardware: hardware)
        }
        deps.makeSession = { [weak self] _ in
            self?.makeStream() ?? FuzzStream(number: 0, plan: ProviderPlan(), text: "", hardware: hardware)
        }
        deps.transcribe = { [weak self] url, _ in
            guard let self else { throw URLError(.cancelled) }
            return try await self.transcribe(url)
        }
        deps.isOnline = { hardware.isOnline }
        deps.clean = { [weak self] text, request, _, enabled in
            guard let self else { return CleanupOutcome(text: text) }
            return await self.clean(text, appName: request.appName, enabled: enabled)
        }
        deps.probeDeepSeek = { _ in nil }
        deps.probeVoice = { _, _ in true }
        deps.playCue = { [weak self] in self?.cue($0) }
        deps.muteOutput = { [weak self] _, _ in self?.mute() }
        deps.restoreOutput = { [weak self] in self?.restore() }
        deps.watchCorrections = { [weak self] text, pid, _, learned in self?.watch(text, pid: pid, learned) }
        deps.judgeTerms = { candidates, _, _ in
            let judge = DictionaryJudge(kind: .correctionModel, provider: "DeepSeek", model: CleanupModel.deepSeek)
            return TermJudgement(kept: candidates.map { LearnedTerm(term: $0.corrected, judge: judge) })
        }
        deps.copyText = { [weak self] in self?.copy($0) }
        deps.insert = { [weak self] text, context, shouldProceed, didSendPaste in
            guard let self else { return .cancelled }
            return await self.insert(text, context: context, shouldProceed: shouldProceed, didSendPaste: didSendPaste)
        }
        deps.systemShortcuts = { [] }
        var settings = AppSettings()
        settings.onboardingCompleted = true
        settings.verifyWithFile = sequence.verifyWithFile
        settings.cleanupEnabled = sequence.cleanupEnabled
        settings.learnCorrections = sequence.learnCorrections
        settings.muteWhileDictating = sequence.muteWhileDictating
        settings.soundsEnabled = true
        settings.structureDictation = false
        model = try AppModel(supportDirectory: directory, settings: settings, dependencies: deps)
        model.overlay.displaysPanel = false
        model.hotkeys = keyboard
        let coordinator = model.coordinator
        coordinator.audioStartLimit = startLimit
        coordinator.audioRestartLimit = startLimit
        coordinator.firstPacketLimit = 0.08
        coordinator.microphoneAccessInterval = 0.05
        keyboard.receive = { [weak self] output in self?.route(output) }
    }

    func dispose() {
        model.coordinator.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Identité des dictées dans les faux

    static func pid(_ number: Int) -> pid_t {
        pid_t(10_000 + number)
    }

    static func number(ofPID pid: pid_t?) -> Int? {
        guard let pid, pid > 10_000 else { return nil }
        return Int(pid) - 10_000
    }

    static func number(ofFile url: URL) -> Int? {
        let parts = url.lastPathComponent.split(separator: "-")
        guard parts.count > 2, parts[0] == "dictee" else { return nil }
        return Int(parts[1])
    }

    static func number(ofApp name: String?) -> Int? {
        guard let name, name.hasPrefix("Appli ") else { return nil }
        return Int(name.dropFirst("Appli ".count))
    }

    /// La durée enregistrée porte le numéro de la dictée en millièmes de seconde, même sans aucun texte.
    static func seconds(_ number: Int, _ whole: Int) -> Double {
        whole == 0 ? 0.1 : Double(whole) + Double(number) / 1_000
    }

    static func number(ofRecord record: DictationRecord) -> Int {
        Int((record.durationSeconds * 1_000).rounded()) % 1_000
    }

    static func streamText(_ number: Int) -> String {
        "Dictée \(number), mot à mot."
    }

    static func fileText(_ number: Int, _ kind: FileText) -> String {
        switch kind {
        case .same: return streamText(number)
        case .different: return "Dictée \(number), sur l'enregistrement."
        case .empty: return ""
        }
    }

    static func relayText(_ number: Int) -> String {
        "Dictée \(number), par le relais."
    }

    private func plan(_ number: Int) -> DictationPlan {
        tracks[number]?.plan ?? DictationPlan()
    }

    // MARK: Faux de AppDependencies

    private func newDictation(_ context: DictationContext) {
        latest += 1
        context.pid = Self.pid(latest)
        context.appName = "Appli \(latest)"
        context.bundleID = "test.appli.\(latest)"
        var track = Track()
        track.plan = ordinary ? DictationPlan() : sequence.plans[(latest - 1) % sequence.plans.count]
        tracks[latest] = track
        contexts.append(WeakBox(context))
        note("d\(latest)")
    }

    private func microphoneAllowed() -> Bool {
        hardware.microphoneAuthorized && plan(latest).mic != .denied
    }

    private func makeMicrophone() -> FuzzMicrophone {
        let chosen = plan(latest)
        let microphone = FuzzMicrophone(
            number: latest, plan: chosen.mic, seconds: Self.seconds(latest, chosen.seconds),
            hangSeconds: hangSeconds, hardware: hardware
        )
        microphones.append(WeakBox(microphone))
        return microphone
    }

    private func makeStream() -> FuzzStream {
        let providers = plan(latest).providers
        let stream = FuzzStream(
            number: latest, plan: providers, text: providers.streamSilent ? "" : Self.streamText(latest), hardware: hardware
        )
        hardware.noteStream(latest)
        streams.append(WeakBox(stream))
        return stream
    }

    /// Fichier chez le fournisseur, puis relais (deuxième appel pour la même dictée).
    private func transcribe(_ url: URL) async throws -> String {
        guard let number = Self.number(ofFile: url) else { throw URLError(.fileDoesNotExist) }
        let attempt = tracks[number]?.fileCalls ?? 0
        tracks[number]?.fileCalls = attempt + 1
        let providers = plan(number).providers
        let relay = attempt > 0
        filesRunning += 1
        defer { filesRunning -= 1 }
        try await Task.sleep(nanoseconds: UInt64(relay ? providers.relayMs : providers.fileMs) * 1_000_000)
        guard hardware.isOnline else { throw URLError(.notConnectedToInternet) }
        let fails = relay ? providers.relayFails : providers.fileFails
        if fails { throw URLError(.badServerResponse) }
        let text = relay ? Self.relayText(number) : Self.fileText(number, providers.fileText)
        if !text.isEmpty { hardware.noteHeard(number) }
        return text
    }

    private func clean(_ text: String, appName: String?, enabled: Bool) async -> CleanupOutcome {
        guard enabled else { return CleanupOutcome(text: text) }
        let providers = Self.number(ofApp: appName).map { plan($0).providers } ?? ProviderPlan()
        cleansRunning += 1
        defer { cleansRunning -= 1 }
        let failed = UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: nil, succeeded: false)
        do {
            try await Task.sleep(nanoseconds: UInt64(providers.cleanMs) * 1_000_000)
        } catch {
            return CleanupOutcome(text: text, usage: failed)
        }
        guard hardware.isOnline, !providers.cleanFails else { return CleanupOutcome(text: text, usage: failed) }
        return CleanupOutcome(text: text, usage: UsageEvent(api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0.000_01))
    }

    private func cue(_ cue: DictationCue) {
        let number = latest
        switch cue {
        case .start:
            break
        case .stop:
            if tracks[number]?.ended == true { fail("deux fins pour la dictée \(number)") }
            if tracks[number]?.cancelledListening == true { fail("fin de la dictée \(number) après son annulation") }
            tracks[number]?.ended = true
        case .cancel:
            if tracks[number]?.ended == true { fail("annulation de la dictée \(number) déjà terminée") }
            tracks[number]?.cancelledListening = true
        }
    }

    private func mute() {
        mutes += 1
        if mutes > restores + 1 { fail("son du Mac coupé deux fois") }
    }

    private func restore() {
        restores += 1
        if restores > mutes { fail("son du Mac rétabli sans avoir été coupé") }
    }

    /// Copie automatique : seulement d'un texte qui n'a pas pu être écrit (aucun champ, collage raté), jamais d'un
    /// champ sécurisé ; ou bouton Copier.
    private func copy(_ text: String) {
        guard !copying else { return }
        guard let call = pasteCalls.last(where: { $0.text == text && $0.result != nil }) else {
            return fail("texte copié sans collage")
        }
        switch call.result {
        case .noTarget?, .failed?: break
        default: fail("texte copié après un collage \(call.result?.rawValue ?? "?")")
        }
    }

    /// Surveillance des corrections : après un collage confirmé de ce texte dans ce champ, une seule fois, et
    /// seulement avec l'apprentissage.
    private func watch(_ text: String, pid: pid_t, _ learned: @escaping @MainActor ([CorrectionLearner.Candidate]) -> Void) {
        if !model.settings.learnCorrections { fail("champ surveillé alors que l'apprentissage est coupé") }
        guard let index = pasteCalls.lastIndex(where: { $0.text == text && $0.pid == pid && $0.result != nil }) else {
            return fail("champ surveillé sans collage")
        }
        if pasteCalls[index].result != .inserted {
            fail("champ surveillé après un collage \(pasteCalls[index].result?.rawValue ?? "?")")
        }
        if pasteCalls[index].watched { fail("champ surveillé deux fois pour un même collage") }
        pasteCalls[index].watched = true
        corrections.append(learned)
    }

    // MARK: Collage, comme `TextInserter.insert`

    private func insert(
        _ text: String, context: DictationContext,
        shouldProceed: @escaping @MainActor () -> Bool, didSendPaste: @escaping @MainActor () -> Void
    ) async -> InsertionStatus {
        let number = Self.number(ofPID: context.pid)
        let index = pasteCalls.count
        pasteCalls.append(PasteCall(number: number, record: nil, text: text, pid: context.pid))
        noteCall(index)
        insertsRunning += 1
        await enterPasteTurn()
        let plan: PastePlan
        if let number {
            plan = self.plan(number).paste
        } else {
            plan = sequence.pastes[pastePlansUsed % sequence.pastes.count]
            pastePlansUsed += 1
        }
        let status = await paste(index, plan: plan, context: context, shouldProceed: shouldProceed, didSendPaste: didSendPaste)
        pasteCalls[index].result = status
        if let number { tracks[number]?.ownResult = status }
        // Le presse-papiers reste réservé un moment après ⌘V : le collage suivant attend son tour.
        let hold = pasteCalls[index].sent ? plan.holdMs : 0
        Task { @MainActor [weak self] in
            if hold > 0 { try? await Task.sleep(nanoseconds: UInt64(hold) * 1_000_000) }
            self?.leavePasteTurn()
            self?.insertsRunning -= 1
        }
        return status
    }

    private func paste(
        _ index: Int, plan: PastePlan, context: DictationContext,
        shouldProceed: @MainActor () -> Bool, didSendPaste: @MainActor () -> Void
    ) async -> InsertionStatus {
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        // Lecture du champ actif, bornée.
        if plan.readMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(plan.readMs) * 1_000_000)
        } else {
            await Task.yield()
        }
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        switch plan.outcome {
        case .noTarget: return .noTarget
        case .secure: return .refusedSecure
        case .untrusted:
            // Comme `TextInserter` : ni ⌘V ni lecture du champ, la bulle dira quelle autorisation manque.
            context.accessibilityRefused = true
            return .failed
        case .inserted, .pasteSent, .notArrived: break
        }
        // ⌘V part dans le même tour que la dernière vérification.
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        sent(index)
        didSendPaste()
        if plan.confirmMs > 0 { try? await Task.sleep(nanoseconds: UInt64(plan.confirmMs) * 1_000_000) }
        switch plan.outcome {
        case .inserted: return .inserted
        case .pasteSent: return .pasteSent
        case .notArrived, .noTarget, .secure, .untrusted: return .failed
        }
    }

    private func enterPasteTurn() async {
        guard pasteBusy else {
            pasteBusy = true
            return
        }
        let turn = AsyncResult<Void>()
        pasteWaiting.append(turn)
        try? await turn.value()
    }

    private func leavePasteTurn() {
        if pasteWaiting.isEmpty {
            pasteBusy = false
        } else {
            pasteWaiting.removeFirst().resolve(.success(()))
        }
    }

    /// Un collage demandé : par sa dictée, une seule fois, terminée, jamais annulée, avec sa ligne d'historique en
    /// attente ; ou par « Coller la dernière dictée », sur demande, d'une dictée ni annulée ni sans transcription.
    private func noteCall(_ index: Int) {
        let call = pasteCalls[index]
        let records = (try? model.store.dictations()) ?? []
        guard let number = call.number else {
            if pasteCalls.filter({ $0.number == nil }).count > pasteRequests {
                fail("collage sans demande de « Coller la dernière dictée »")
            }
            guard let record = records.first(where: { $0.finalText == call.text }) else {
                return fail("« Coller la dernière dictée » d'un texte absent de l'historique")
            }
            pasteCalls[index].record = Self.number(ofRecord: record)
            if record.insertionStatus == InsertionStatus.cancelled.rawValue
                || record.insertionStatus == InsertionStatus.transcriptionFailed.rawValue {
                fail("« Coller la dernière dictée » d'une dictée \(record.insertionStatus)")
            }
            return
        }
        guard var track = tracks[number] else { return fail("collage d'une dictée inconnue \(number)") }
        track.pasteCalls += 1
        if track.pasteCalls > 1 { fail("deux collages demandés pour la dictée \(number)") }
        if !track.ended { fail("collage de la dictée \(number), jamais terminée") }
        if track.cancelledBeforePaste { fail("collage demandé pour la dictée \(number) après son annulation") }
        tracks[number] = track
        let mine = records.filter { Self.number(ofRecord: $0) == number }
        if mine.count != 1 || mine.first?.finalText != call.text
            || mine.first?.insertionStatus != InsertionStatus.pending.rawValue {
            fail("collage de la dictée \(number) sans sa seule ligne d'historique en attente")
        }
    }

    /// ⌘V envoyé : une fois par dictée, jamais après son annulation, dans l'ordre dicté ; jamais pendant une écoute
    /// pour « Coller la dernière dictée ».
    private func sent(_ index: Int) {
        pasteCalls[index].sent = true
        guard let number = pasteCalls[index].number else {
            if model.coordinator.phase.modelCapturing { fail("« Coller la dernière dictée » collé pendant une écoute") }
            return
        }
        if tracks[number]?.pasted == true { fail("dictée \(number) collée deux fois") }
        if tracks[number]?.cancelledBeforePaste == true { fail("dictée \(number) collée après son annulation") }
        if let last = lastPasted, number < last { fail("dictée \(number) collée après la dictée \(last)") }
        tracks[number]?.pasted = true
        lastPasted = max(lastPasted ?? number, number)
    }

    // MARK: Raccourci, bulle et menu, comme l'app

    /// Comme `HotkeyMonitor.receive`.
    private func route(_ output: HotkeyOutput) {
        let coordinator = model.coordinator
        if output.pasteLast {
            pasteRequests += 1
            pasteTasks += 1
            Task { @MainActor [weak self] in
                await coordinator.pasteLastDictation()
                self?.pasteTasks -= 1
            }
            return
        }
        if output.cancel { cancel() }
        for effect in output.effects {
            switch effect {
            case .startPushToTalk: start(.pushToTalk)
            case .startToggle: start(.toggle)
            case .stopPushToTalk, .stopToggle: coordinator.enqueue { coordinator.endCapture() }
            }
        }
    }

    private func start(_ mode: ListenMode) {
        let coordinator = model.coordinator
        coordinator.enqueue { [weak self] in
            self?.beginsRunning += 1
            await coordinator.begin(mode)
            self?.beginsRunning -= 1
        }
    }

    /// Échap, ✕ ou menu. Pendant la fin d'une dictée, tout ce qui n'est pas encore collé est annulé.
    private func cancel() {
        let coordinator = model.coordinator
        if coordinator.phase == .finishing {
            for (number, track) in tracks where track.ended && !track.pasted {
                tracks[number]?.cancelledBeforePaste = true
            }
        }
        coordinator.cancel()
    }

    func perform(_ step: ModelStep) async {
        let coordinator = model.coordinator
        switch step {
        case .hold:
            guard !keyboard.fnHeld else { return note("—") }
            keyboard.pressFn()
            keyboard.advance(by: 200)
        case .release:
            guard keyboard.fnHeld else { return note("—") }
            keyboard.releaseFn()
            keyboard.advance(by: 20)
        case .doubleTap:
            guard !keyboard.fnHeld else { return note("—") }
            keyboard.doubleTap()
        case .tap:
            guard !keyboard.fnHeld else { return note("—") }
            keyboard.tap()
        case .escape:
            keyboard.escape()
        case .pasteLast:
            keyboard.pasteChord()
        case .closeMessage:
            coordinator.closeMessage()
        case .bubbleStop:
            // ■ de la bulle : comme `OverlayCluster`.
            guard coordinator.phase == .listening(.toggle) else { return note("—") }
            model.hotkeys?.sessionEnded()
            coordinator.enqueue { coordinator.endCapture() }
        case .bubbleCancel:
            guard coordinator.phase == .listening(.toggle) else { return note("—") }
            cancel()
        case .menuToggle:
            // Comme `AppDelegate.toggleDictation` ; le menu ne s'ouvre pas pendant un maintien.
            guard !keyboard.fnHeld else { return note("—") }
            switch coordinator.phase {
            case .listening:
                model.hotkeys?.sessionEnded()
                coordinator.enqueue { coordinator.endCapture() }
            case .starting:
                note("—")
            case .idle, .finishing, .failure:
                model.hotkeys?.externalToggleStarted()
                start(.toggle)
            }
        case .pasteButton:
            guard coordinator.failureText != nil else { return note("—") }
            pasteRequests += 1
            coordinator.pasteReadyText()
        case .copyButton:
            guard coordinator.failureText != nil else { return note("—") }
            copying = true
            coordinator.copyReadyText()
            copying = false
        case .microphoneLost:
            microphones.last?.object?.interrupt()
        case .keyboardCut:
            keyboard.cut()
        case .keyboardWithdrawn:
            // Comme `KeyboardTap.withdraw`, puis `HotkeyMonitor.keyboardLost`.
            guard keyboard.listening else { return note("—") }
            keyboard.withdraw()
            coordinator.keyboardLost(KeyboardPermissions(listen: latest % 2 == 0, accessibility: latest % 2 != 0))
        case .keyboardBack:
            keyboard.restore()
        case .microphoneRevoked:
            hardware.microphoneAuthorized = false
        case .microphoneRestored:
            hardware.microphoneAuthorized = true
        case .offline:
            hardware.isOnline = false
        case .online:
            hardware.isOnline = true
        case .correctWord:
            guard let learned = corrections.popLast() else { return note("—") }
            learned([CorrectionLearner.Candidate(heard: "Sidance", corrected: "Seedance")])
        case .wait(let milliseconds):
            try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }
    }

    private func pause(_ pause: ModelPause) async {
        switch pause {
        case .immediate: break
        case .yield: await Task.yield()
        case .milliseconds(let milliseconds): try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }
    }

    // MARK: Séquence et invariants

    /// Joue la séquence, puis la fin ; rend la première violation, avec la séquence jouée.
    func play() async -> String? {
        for (index, step) in sequence.steps.enumerated() {
            note(step.label)
            await perform(step)
            await pause(sequence.pauses[index])
            checkStep()
            if let violation = violations.first { return report(violation) }
        }
        return await finishAndCheck()
    }

    /// Fin de séquence et invariants de fin ; rend la première violation.
    func finishAndCheck() async -> String? {
        await finish()
        guard let violation = violations.first else { return nil }
        return report(violation)
    }

    private func fail(_ violation: String) {
        violations.append(violation)
    }

    private func note(_ entry: String) {
        log.append(entry)
    }

    private func report(_ violation: String) -> String {
        let coordinator = model.coordinator
        let plans = (1...max(1, latest)).compactMap { number in tracks[number].map { "d\(number) : \($0.plan.label)" } }
        let settings = "vérification \(sequence.verifyWithFile), correction \(sequence.cleanupEnabled), apprentissage \(sequence.learnCorrections), son coupé \(sequence.muteWhileDictating)"
        return "\(violation) — phase \(coordinator.phase), \(coordinator.finishingCount) en fin — "
            + "événements : \(log.joined(separator: " → ")) — dictées : \(plans.joined(separator: " ; ")) — réglages : \(settings)"
    }

    /// Invariants vrais à tout moment où la séquence reprend la main.
    private func checkStep() {
        let coordinator = model.coordinator
        let phase = coordinator.phase
        // Hors de l'écoute, micro, spectre et son coupé sont rendus. Un démarrage encore attendu par sa dictée
        // referme lui-même ce qu'il a ouvert entre-temps.
        if !phase.modelCapturing, beginsRunning == 0 {
            let open = hardware.openMicrophones
            if !open.isEmpty { fail("micro ouvert hors de l'écoute (dictée \(open))") }
            if coordinator.isMetering { fail("spectre allumé hors de l'écoute") }
            if mutes != restores { fail("son du Mac laissé coupé hors de l'écoute") }
        }
        if keyboard.config.capturing != phase.modelCapturing || keyboard.config.pending != phase.modelPending {
            fail("écoute du clavier pas tenue au courant de la phase \(phase)")
        }
        let records = (try? model.store.dictations()) ?? []
        var counts: [Int: Int] = [:]
        for record in records { counts[Self.number(ofRecord: record), default: 0] += 1 }
        for (number, count) in counts where count > 1 {
            fail("dictée \(number) \(count) fois dans l'historique")
        }
        violations += hardware.takeProblems()
    }

    /// Tout est relâché et la connexion revient ; une dictée encore à l'écoute se termine comme d'habitude. Puis
    /// repos dans la borne, historique, raccourci libre, dictée de contrôle et mémoire.
    private func finish() async {
        note("fin")
        hardware.isOnline = true
        hardware.microphoneAuthorized = true
        keyboard.restore()
        if keyboard.fnHeld { keyboard.releaseFn() }
        keyboard.advance(by: 400)
        let deadline = Date().addingTimeInterval(Self.restLimit)
        var rested = false
        while Date() < deadline {
            if model.coordinator.phase == .listening(.toggle) { keyboard.tap() }
            if quietNow(), await queueDrained() {
                // Un collage demandé par un bouton part au tour suivant : le repos doit tenir.
                try? await Task.sleep(nanoseconds: 30_000_000)
                if quietNow() {
                    rested = true
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        checkStep()
        guard rested else {
            return fail("pas de retour au repos en \(Int(Self.restLimit)) s (opérations du micro \(hardware.microphoneBusy), appels \(hardware.callsInFlight + insertsRunning + cleansRunning + filesRunning), départs \(beginsRunning), collages demandés \(pasteTasks))")
        }
        if case .failure = model.coordinator.phase { model.coordinator.closeMessage() }
        checkHistory()
        checkShortcutFree()
        guard violations.isEmpty else { return }
        await checkShortcutStarts()
        guard violations.isEmpty else { return }
        await checkReleased()
    }

    /// Rien en cours : aucune dictée qui écoute ou se termine, aucun appel ni collage, micro au repos.
    private func quietNow() -> Bool {
        let coordinator = model.coordinator
        switch coordinator.phase {
        case .idle, .failure: break
        case .starting, .listening, .finishing: return false
        }
        return coordinator.finishingCount == 0 && beginsRunning == 0 && pasteTasks == 0 && insertsRunning == 0
            && cleansRunning == 0 && filesRunning == 0 && hardware.callsInFlight == 0 && !hardware.microphoneBusy
    }

    /// La file des gestes est vide : un geste ajouté maintenant passe tout de suite.
    func queueDrained() async -> Bool {
        let before = probesRun
        model.coordinator.enqueue { [weak self] in self?.probesRun += 1 }
        return await eventually(seconds: 1) { self.probesRun > before }
    }

    /// Chaque dictée terminée et entendue est dans l'historique, une seule fois, avec le statut de ce qui s'est
    /// passé ; aucune autre n'y est.
    private func checkHistory() {
        let records = (try? model.store.dictations()) ?? []
        var byNumber: [Int: DictationRecord] = [:]
        for record in records {
            let number = Self.number(ofRecord: record)
            byNumber[number] = record
            guard let track = tracks[number], track.ended else {
                fail("dictée \(number) dans l'historique sans avoir été terminée")
                continue
            }
            let heard = hardware.wasHeard(number)
            switch InsertionStatus(rawValue: record.insertionStatus) {
            case .transcriptionFailed?:
                if track.pasteCalls > 0 { fail("dictée \(number) collée puis notée sans transcription") }
                if heard { fail("dictée \(number) notée sans transcription alors qu'un fournisseur l'a entendue") }
            case .cancelled?:
                if !track.cancelledBeforePaste { fail("dictée \(number) notée annulée sans Échap") }
                if track.pasted { fail("dictée \(number) collée puis notée annulée") }
            case .pending?:
                fail("dictée \(number) restée en attente dans l'historique")
            case nil:
                fail("dictée \(number) au statut inconnu \(record.insertionStatus)")
            default:
                if track.pasteCalls != 1 { fail("dictée \(number) au statut \(record.insertionStatus) sans son collage") }
                let expected = expectedStatus(number)
                if record.insertionStatus != expected?.rawValue {
                    fail("dictée \(number) au statut \(record.insertionStatus) au lieu de \(expected?.rawValue ?? "aucun")")
                }
            }
        }
        for (number, track) in tracks where track.ended && !track.cancelledBeforePaste && hardware.wasHeard(number) {
            guard let record = byNumber[number] else {
                fail("dictée \(number) entendue mais absente de l'historique")
                continue
            }
            if record.insertionStatus == InsertionStatus.transcriptionFailed.rawValue
                || record.insertionStatus == InsertionStatus.cancelled.rawValue || track.pasteCalls != 1 {
                fail("dictée \(number) entendue mais jamais collée (\(record.insertionStatus))")
            }
        }
    }

    /// Statut attendu : le collage de la dictée, amélioré par chaque « Coller la dernière dictée » réussi.
    private func expectedStatus(_ number: Int) -> InsertionStatus? {
        guard var status = tracks[number]?.ownResult else { return nil }
        for call in pasteCalls where call.number == nil && call.record == number {
            guard let result = call.result else { continue }
            if let updated = PasteLastChoice.updatedStatus(previous: status.rawValue, outcome: result) { status = updated }
        }
        return status
    }

    /// Au repos, le raccourci est libre : aucun geste en cours, Échap rendu à l'app.
    private func checkShortcutFree() {
        let phase = model.coordinator.phase
        if phase != .idle { fail("au repos, phase \(phase)") }
        if !keyboard.logic.engine.isIdle { fail("raccourci pas libre au repos : geste resté en cours (\(keyboard.logic.engine))") }
        if keyboard.logic.chordDown { fail("raccourci resté enfoncé au repos") }
        if keyboard.config.capturing || keyboard.config.pending { fail("Échap encore pris par Wispad au repos") }
    }

    /// Un double appui écoute aussitôt, Échap l'annule, et tout revient au repos.
    private func checkShortcutStarts() async {
        ordinary = true
        model.settings.muteWhileDictating = false
        model.coordinator.audioStartLimit = MicrophoneStartWatch.startLimit
        note("contrôle")
        keyboard.doubleTap()
        let listening = await eventually(seconds: Self.restLimit) { self.model.coordinator.phase == .listening(.toggle) }
        guard listening else { return fail("au repos, un double appui ne démarre pas de dictée") }
        keyboard.escape()
        keyboard.advance(by: 400)
        if model.coordinator.phase != .idle { fail("Échap n'annule pas la dictée de contrôle") }
        checkShortcutFree()
        checkStep()
    }

    /// Plus rien de la séquence en vie : contexte de chaque dictée (et donc son écoute et sa fin), micros et flux.
    private func checkReleased() async {
        let released = await eventually(seconds: 10) {
            self.contexts.allSatisfy { $0.object == nil } && self.microphones.allSatisfy { $0.object == nil }
                && self.streams.allSatisfy { $0.object == nil }
        }
        if !released {
            let contexts = self.contexts.filter { $0.object != nil }.count
            let microphones = self.microphones.filter { $0.object != nil }.count
            let streams = self.streams.filter { $0.object != nil }.count
            fail("objets de dictée encore en vie : \(contexts) contexte(s), \(microphones) micro(s), \(streams) flux")
        }
        let unclosed = hardware.unclosedStreams
        if !unclosed.isEmpty { fail("flux en direct jamais refermé (dictées \(unclosed))") }
    }
}

/// Attend qu'une condition devienne vraie, sans bloquer le fil principal ; rend la main dès qu'elle l'est.
@MainActor
private func eventually(seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

// MARK: - Tests

/// Séquences tirées d'une graine fixe : quelques centaines par défaut, toutes avec `WISPAD_PROPERTY_RUNS=full`.
@MainActor
@Suite(.serialized)
struct DictationCoordinatorPropertyTests {
    /// Séquences jouées ensemble, par lots : chacune a son app, ses faux et son clavier ; seul le fil principal est
    /// commun, et il est le plus souvent libre (délais simulés). Les tirages, eux, restent dans l'ordre de la graine.
    static let concurrentSequences = 4

    @Test func randomSequencesKeepEveryInvariant() async {
        let seed: UInt64 = 0x00D1_C7A7_10A5
        var random = ModelRandom(seed: seed)
        let sequences = (0..<800).map { _ in ModelSequence.draw(&random) }
        var start = 0
        while start < sequences.count {
            let batch = start..<min(start + Self.concurrentSequences, sequences.count)
            var plays: [Task<String?, Never>] = []
            for index in batch {
                let sequence = sequences[index]
                plays.append(Task { @MainActor in await Self.play(sequence) })
            }
            // Tout le lot finit ; la première violation, dans l'ordre des tirages, est rapportée.
            var failure: (index: Int, text: String)?
            for (index, play) in zip(batch, plays) {
                if let text = await play.value, failure == nil { failure = (index, text) }
            }
            if let failure {
                // Une ligne, valeur comprise : scripts/check.sh ne garde que les lignes ✘ du journal.
                let violation: String? = "séquence \(failure.index), graine \(seed) : \(failure.text)"
                #expect(violation == nil)
                return
            }
            start = batch.upperBound
        }
    }

    /// Une séquence sur une app neuve ; rend sa première violation.
    private static func play(_ sequence: ModelSequence) async -> String? {
        let world: ModelWorld
        do {
            world = try ModelWorld(sequence)
        } catch {
            return "app de test impossible à créer : \(error)"
        }
        let failure = await world.play()
        world.dispose()
        return failure
    }
}

/// Séquences gardées comme tests fixes : chacune a révélé un défaut, corrigé depuis.
@MainActor
@Suite(.serialized)
struct DictationSequenceRegressionTests {
    /// Une dictée se termine ; double appui, puis Échap traité avant que le départ en file ait joué (fil principal
    /// occupé). Échap annule la fin, comme pendant toute fin de dictée ; le départ déjà compté par le clavier doit
    /// jouer quand même. Jeté, il laissait le clavier en mains libres : l'appui suivant n'arrêtait qu'une dictée jamais
    /// commencée, et le double appui suivant ne démarrait rien.
    @Test func escapeBeforeAQueuedDoubleTapLeavesTheShortcutReady() async throws {
        var finishing = DictationPlan()
        finishing.providers.streamFinishMs = 2_000
        let sequence = ModelSequence.scripted([], plans: [finishing, DictationPlan()])
        let world = try ModelWorld(sequence, startLimit: MicrophoneStartWatch.startLimit)
        defer { world.dispose() }
        await world.perform(.hold)
        let listening = await eventually { world.model.coordinator.phase == .listening(.pushToTalk) && !world.isBeginning }
        #expect(listening)
        await world.perform(.release)
        let ending = await eventually { world.model.coordinator.phase == .finishing }
        #expect(ending)
        // Dans le même tour du fil principal : le départ du double appui attend encore son tour quand Échap arrive.
        await world.perform(.doubleTap)
        await world.perform(.escape)
        let failure = await world.finishAndCheck()
        #expect(failure == nil)
        // La première dictée est annulée ; la seconde, démarrée par le double appui, est collée.
        #expect(world.tracks[1]?.cancelledBeforePaste == true)
        #expect(world.tracks[1]?.pasted == false)
        #expect(world.tracks[2]?.pasted == true)
    }

    /// Micro lent à démarrer : on relâche la touche, puis double appui et Échap pendant ce démarrage. Échap annule la
    /// dictée qui démarre ; sa fin et le départ du double appui attendent en file, déjà comptés par le clavier.
    /// `sessionEnded()` remettait pourtant son geste au repos : la seconde dictée écoutait en mains libres sans que
    /// l'appui suivant l'arrête (un appui simple ne fait rien au repos).
    @Test func cancellingAStartingDictationKeepsTheQueuedDoubleTap() async throws {
        var slow = DictationPlan()
        slow.mic = .slow
        let sequence = ModelSequence.scripted([], plans: [slow, DictationPlan()])
        let world = try ModelWorld(sequence, startLimit: MicrophoneStartWatch.startLimit, hangSeconds: 1)
        defer { world.dispose() }
        await world.perform(.hold)
        let starting = await eventually { world.hardware.isStarting(1) }
        #expect(starting)
        // Dans le même tour du fil principal, pendant le démarrage du micro.
        await world.perform(.release)
        await world.perform(.doubleTap)
        await world.perform(.escape)
        #expect(world.model.coordinator.phase == .idle)
        #expect(world.tracks[1]?.cancelledListening == true)
        let failure = await world.finishAndCheck()
        #expect(failure == nil)
        #expect(world.tracks[1]?.ended == false)
        #expect(world.tracks[2]?.pasted == true)
    }

    /// Double appui, puis écoute du clavier retirée (autorisation retirée) avant que son départ en file ait joué.
    /// L'écoute oublie alors le geste en cours ; le départ en file ouvrait pourtant une dictée en mains libres que ni
    /// le raccourci ni Échap n'atteignaient, et qu'un appui n'arrêtait pas l'écoute rendue.
    @Test func keyboardWithdrawnBeforeAQueuedDoubleTapStartsNothing() async throws {
        let sequence = ModelSequence.scripted([], plans: [DictationPlan()])
        let world = try ModelWorld(sequence, startLimit: MicrophoneStartWatch.startLimit)
        defer { world.dispose() }
        // Dans le même tour du fil principal : le départ du double appui attend encore son tour.
        await world.perform(.doubleTap)
        await world.perform(.keyboardWithdrawn)
        let drained = await world.queueDrained()
        #expect(drained)
        #expect(world.latest == 0)
        #expect(world.model.coordinator.phase == .idle)
        let failure = await world.finishAndCheck()
        #expect(failure == nil)
    }

    /// Même retrait pendant que le départ du double appui attend la clé (coffre de secrets lent) : la clé arrivée, il
    /// ouvrait aussi une dictée hors d'atteinte du clavier.
    @Test func keyboardWithdrawnWhileTheKeyIsReadStartsNothing() async throws {
        let keys = LateKeys()
        let sequence = ModelSequence.scripted([], plans: [DictationPlan()])
        let world = try ModelWorld(sequence, startLimit: MicrophoneStartWatch.startLimit, keys: keys)
        defer { world.dispose() }
        await world.perform(.doubleTap)
        let reading = await eventually { keys.isReading }
        #expect(reading)
        await world.perform(.keyboardWithdrawn)
        keys.load()
        let drained = await world.queueDrained()
        #expect(drained)
        #expect(world.latest == 0)
        #expect(world.model.coordinator.phase == .idle)
        let failure = await world.finishAndCheck()
        #expect(failure == nil)
    }

    /// Micro muet, redémarré sur un moteur neuf qui tarde ; on relâche la touche pendant ce redémarrage. `stop()`
    /// attendait sa fin sur le fil principal (file du micro) : Wispad restait figé tant que le moteur ne rendait pas
    /// la main. La dictée s'arrête maintenant sans l'attendre, et le micro se referme dès qu'il rend la main.
    @Test func releasingWhileTheMicrophoneRestartsNeverWaitsForIt() async throws {
        var silent = DictationPlan()
        silent.mic = .silent(.hangs)
        let sequence = ModelSequence.scripted([], plans: [silent, DictationPlan()])
        let world = try ModelWorld(sequence, startLimit: MicrophoneStartWatch.startLimit, hangSeconds: 1.5)
        defer { world.dispose() }
        await world.perform(.hold)
        let restarting = await eventually { world.hardware.isRestarting(1) }
        #expect(restarting)
        await world.perform(.release)
        let rested = await eventually(seconds: 0.5) { world.model.coordinator.phase == .idle }
        #expect(rested)
        #expect(world.hardware.isRestarting(1))
        let failure = await world.finishAndCheck()
        #expect(failure == nil)
        #expect(world.hardware.openMicrophones.isEmpty)
        #expect(world.tracks[1]?.ended == false)
    }

    /// Même redémarrage, annulé par Échap : la dictée part tout de suite, sans attendre le micro.
    @Test func escapeWhileTheMicrophoneRestartsNeverWaitsForIt() async throws {
        var silent = DictationPlan()
        silent.mic = .silent(.hangs)
        let sequence = ModelSequence.scripted([], plans: [silent, DictationPlan()])
        let world = try ModelWorld(sequence, startLimit: MicrophoneStartWatch.startLimit, hangSeconds: 1.5)
        defer { world.dispose() }
        await world.perform(.doubleTap)
        let restarting = await eventually { world.hardware.isRestarting(1) }
        #expect(restarting)
        await world.perform(.escape)
        #expect(world.model.coordinator.phase == .idle)
        #expect(world.tracks[1]?.cancelledListening == true)
        let failure = await world.finishAndCheck()
        #expect(failure == nil)
        #expect(world.hardware.openMicrophones.isEmpty)
    }
}
