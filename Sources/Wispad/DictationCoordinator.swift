import AppKit
import QuartzCore
import Foundation
import WispadCore
import os

enum ListenMode: Equatable {
    case pushToTalk
    case toggle
}

enum DictationPhase: Equatable {
    case idle
    case starting
    case listening(ListenMode)
    case finishing
    case failure(String)
}

/// Une dictée tient en deux temps. L'écoute (Capture) : une seule à la fois, micro ouvert dès l'appui.
/// La fin (FinishJob) : transcription, correction et collage en arrière-plan, pour qu'une nouvelle dictée puisse
/// commencer aussitôt ; les textes se collent toujours dans l'ordre où ils ont été dits.
@MainActor
@Observable
final class DictationCoordinator {
    weak var model: AppModel?
    var phase: DictationPhase = .idle {
        didSet {
            let capturing: Bool
            switch phase {
            case .starting, .listening: capturing = true
            default: capturing = false
            }
            // Ne jamais réenregistrer la lecture d'une ancienne dictée.
            if capturing && !oldValue.isCapturing { model?.historyPlayer.close() }
            // Dès que l'écoute s'arrête (fin, annulation, échec), le son coupé par Wispad revient.
            if !capturing, outputMuted {
                outputMuted = false
                model?.dependencies.restoreOutput()
            }
            if capturing != oldValue.isCapturing || phase.isPending != oldValue.isPending {
                model?.hotkeys?.setDictationState(capturing: capturing, pending: phase.isPending)
            }
        }
    }
    @ObservationIgnored private var outputMuted = false
    var failureText: String?
    /// Copier vient d'être cliqué : la bulle confirme « Copié » avant de partir.
    var failureCopied = false
    /// Le message d'erreur propose d'ouvrir l'historique (faux pour un micro qui n'a pas démarré).
    var failureOffersHistory = true
    /// Un collage de « Coller la dernière dictée » (ou du bouton Coller) est en cours.
    @ObservationIgnored private var pastingAgain = false
    /// Barres du spectre affiché : graves au centre, aigus sur les bords.
    var spectrum = Array(repeating: Float(0), count: DictationCoordinator.barCount)
    /// Relais qui travaille sur cette dictée (« OpenAI ») : la bulle change de couleur.
    private(set) var relay: String?
    @ObservationIgnored var onChange: (() -> Void)?
    /// Bascules déjà annoncées : un seul message par panne, jusqu'au retour du service principal.
    @ObservationIgnored private var announcedRelays: Set<String> = []
    @ObservationIgnored private var pendingAnnouncement: String?
    /// Le message de la bulle annonce une bascule vers un relais (icône et couleur dédiées).
    private(set) var noticeIsRelay = false
    /// Le message de la bulle est une simple information (rien à coller) : icône neutre.
    private(set) var noticeIsInfo = false
    /// Le message demande de garder ou non un mot déjà ajouté au dictionnaire.
    private(set) var noticeConfirmsLearning = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operation: Task<Void, Never>?
    /// Gestes en file, pas encore joués : l'écoute du clavier les a déjà comptés.
    @ObservationIgnored private var queuedGestures = 0
    /// Retraits de l'écoute du clavier (`keyboardLost`) : un geste compté avant l'un d'eux a été oublié avec elle.
    @ObservationIgnored private var keyboardLosses = 0
    /// Dictée en cours d'écoute.
    @ObservationIgnored private var capture: Capture?
    /// Dictées qui se terminent, dans l'ordre où elles ont été dites.
    @ObservationIgnored private var jobs: [FinishJob] = []
    /// Erreur à montrer dans la bulle, dès que le micro est libre.
    @ObservationIgnored private var shownFailure: ShownFailure?
    @ObservationIgnored private var dismissing: UUID?
    /// Départ automatique du message d'erreur, en pause au survol.
    let failureTimer = MessageTimer()
    /// Le pointeur survole un message de la bulle : son décompte attend.
    @ObservationIgnored private(set) var messagesHeld = false
    /// Nouvelle transcription demandée depuis l'historique.
    @ObservationIgnored private var retrying = false
    @ObservationIgnored private var meter: FrameTicker?

    static let barCount = SpectrumAnalyzer.bandCount * 2 - 1
    /// Fréquence d'affichage du spectre.
    static let meterInterval = 1.0 / 60.0
    /// En dessous, l'enregistrement est jeté sans appel API (appui trop bref, souffle).
    static let minimumDuration = 0.3
    /// Durées d'affichage des messages ; une fine barre se vide pendant ce temps.
    /// Le temps de lire et de cliquer sur Copier ou Coller quand le texte n'a pas pu être collé.
    static let failureSeconds = 12.0
    /// Confirmation « Copié », puis la bulle part.
    static let copiedSeconds = 1.5
    static let noticeSeconds = 3.5
    /// Confirmation d'un mot appris : assez longtemps pour cliquer, puis le mot reste.
    static let learningSeconds = 8.0
    private static let learningLog = Logger.wispad("apprentissage")
    static let transcriptionLog = Logger.wispad("transcription")
    private static let insertionLog = Logger.wispad("insertion")
    /// Attente maximale du champ actif avant d'ouvrir le flux en direct (l'audio est gardé pendant ce temps).
    static let contextWait = 0.15
    /// Attente supplémentaire de la lecture de fenêtre à la fin d'une dictée très courte.
    static let windowWait = 0.25
    static let audioLog = Logger.wispad("audio")
    /// Message de la bulle quand le micro ne démarre pas (trop lent ou sans aucun audio).
    static var microphoneStalledMessage: String {
        String(localized: "Le micro n'a pas démarré : réessaie")
    }
    /// Message de la bulle quand le micro s'arrête en pleine écoute sans pouvoir repartir.
    static var microphoneLostMessage: String {
        String(localized: "Le micro ne répond plus : dictée arrêtée")
    }
    /// Message de la bulle quand l'accès au micro est retiré dans Réglages Système en pleine écoute.
    static var microphoneRevokedMessage: String {
        String(localized: "Accès au micro retiré : dictée arrêtée")
    }
    /// Message de la bulle quand l'écoute du clavier est retirée en pleine dictée, faute de cette autorisation.
    static func keyboardLostMessage(_ permissions: KeyboardPermissions) -> String {
        permissions.listen
            ? String(localized: "Accessibilité retirée : dictée arrêtée")
            : String(localized: "Surveillance des entrées retirée : dictée arrêtée")
    }
    /// Vérification de l'accès au micro pendant l'écoute ; raccourcie par les tests.
    @ObservationIgnored var microphoneAccessInterval = 1.0
    /// Délais de démarrage du micro (`MicrophoneStartWatch`) ; raccourcis par les tests. Un redémarrage sur un
    /// moteur neuf a le même délai que le premier démarrage.
    @ObservationIgnored var audioStartLimit = MicrophoneStartWatch.startLimit
    @ObservationIgnored var audioRestartLimit = MicrophoneStartWatch.startLimit
    @ObservationIgnored var firstPacketLimit = MicrophoneStartWatch.firstPacketLimit

    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    /// Dictées en cours de transcription, de correction ou de collage.
    var finishingCount: Int { jobs.count }

    /// Début ou fin d'une dictée, dans l'ordre des gestes. Chaque geste en file est joué, même après un Échap pris
    /// avant lui (fil principal occupé) : l'écoute du clavier l'a déjà compté. Jeté, un début en mains libres la
    /// laissait attendre une fin, et l'appui suivant ne servait qu'à arrêter une dictée jamais commencée.
    /// Seule exception : l'écoute du clavier retirée depuis l'a oublié avec le geste en cours (`keyboardLost`).
    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        let losses = keyboardLosses
        queuedGestures += 1
        operation = Task { @MainActor in
            await previous?.value
            self.queuedGestures -= 1
            guard self.keyboardLosses == losses else { return }
            await work()
        }
    }

    /// La dictée s'arrête sans son geste (annulée, échouée, micro perdu) : l'écoute du clavier oublie le geste qui la
    /// tenait, pour que l'appui suivant en démarre une autre. Un geste encore en file vient après lui (relâchement,
    /// nouveau départ) : le clavier en est déjà là, et le remettre au repos effacerait la dictée suivante.
    private func endGesture() {
        guard queuedGestures == 0 else { return }
        model?.hotkeys?.sessionEnded()
    }

    func begin(_ mode: ListenMode, pressedAt: Int? = nil) async {
        guard capture == nil, let model else { return }
        guard !retrying else {
            endGesture()
            return
        }
        let latencyMarks = LatencyMarks(pressed: pressedAt)
        let run = DictationTraceRecorder(origin: mode == .toggle ? .toggle : .hold, pressedAt: pressedAt, marks: latencyMarks)
        let losses = keyboardLosses
        let problem = await model.voiceProblem()
        // Écoute du clavier retirée pendant la lecture de la clé : elle a oublié ce geste (`keyboardLost`).
        guard capture == nil, !retrying, keyboardLosses == losses else { return }
        if let problem {
            run.complete(problem.outcome, model: model)
            model.statusBanner = problem.message
            model.open(.providers)
            endGesture()
            return
        }
        // La bulle d'abord, puis le micro. L'app au premier plan est lue tout de suite ; son champ actif (lent
        // dans les apps Electron) est lu en parallèle et ne retarde plus l'enregistrement.
        let (context, field) = model.dependencies.captureContext()
        let current = Capture(mode: mode, context: context, field: field, marks: latencyMarks, run: run)
        capture = current
        // La conversation visible (Claude, Codex, Chrome…) est lue pendant qu'on parle : ni le micro
        // ni la bulle ne l'attendent, et seule la correction s'en sert.
        if model.settings.cleanupEnabled, model.settings.useWindowContext, let pid = context.pid {
            let read = model.dependencies.readWindow
            current.window = Task { await read(pid) }
        }
        relay = nil
        spectrum = Array(repeating: 0, count: Self.barCount)
        refreshPhase()
        // La capture possède déjà la bulle : retirer l'ancien message ne lance pas de disparition
        // SwiftUI suivie d'une réapparition dans la même boucle du fil principal.
        clearNotice()
        dismissFailure()
        changed()
        current.marks.bubble = KeyboardTap.now()
        // Couleur de relais dès la première image de la bulle (elle ne dépend pas du champ actif).
        relay = routed(model.speechRequest(context: nil), model: model).relay
        let microphone = await model.dependencies.requestMicrophone()
        guard capture === current, !current.cancelled else { return }
        guard microphone else {
            discard(current, outcome: .microphoneDenied)
            model.statusBanner = String(localized: "Le microphone n'est pas autorisé.")
            model.open(.settings)
            return
        }
        let audio = model.dependencies.makeCapture()
        audio.inputDeviceUID = model.settings.microphoneUID.isEmpty ? nil : model.settings.microphoneUID
        let pcm = current.pcm
        let firstPacket = OSAllocatedUnfairLock<Int?>(initialState: nil)
        audio.onPCM = { [weak self, weak current] data in
            guard !data.isEmpty else { return }
            pcm.push(data)
            let at = KeyboardTap.now()
            let isFirst = firstPacket.withLock { first in
                guard first == nil else { return false }
                first = at
                return true
            }
            if isFirst {
                Task { @MainActor in
                    guard let self, let current, self.capture === current, !current.cancelled else { return }
                    current.marks.firstAudio = at
                    self.signalAudioReady(current)
                }
            }
        }
        // Micro disparu en pleine écoute, sans autre micro pour repartir : la dictée s'arrête avec ce qui a été dit.
        audio.onInterruption = { [weak self, weak current] in
            Task { @MainActor in
                guard let self, let current else { return }
                self.microphoneLost(current)
            }
        }
        let directory = model.audioDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            failMicrophone(current, message: error.localizedDescription)
            return
        }
        // Premier démarrage à froid du moteur : il peut tarder. Au-delà du délai, la dictée est abandonnée
        // (la bulle le dit) et le démarrage se refermera seul ; jamais une bulle figée en attente.
        // Lancé hors du fil principal, sans y repasser : le micro n'attend jamais une file principale occupée.
        let starting = Task.detached(priority: Task.currentPriority) { () async -> Result<URL, Error> in
            do {
                return .success(try await audio.start(directory: directory))
            } catch {
                return .failure(error)
            }
        }
        guard let started = await Self.value(of: starting, within: audioStartLimit) else {
            audio.abandonStart()
            guard capture === current, !current.cancelled else { return }
            Self.audioLog.error("démarrage du micro trop long : dictée abandonnée")
            failMicrophone(current, message: Self.microphoneStalledMessage)
            return
        }
        guard capture === current, !current.cancelled else {
            // Le démarrage async peut même être enfilé après stop(). L'arrêter de nouveau avant
            // de rendre la main à la dictée suivante (enqueue sérialise les démarrages).
            if case .success(let url) = started {
                _ = audio.stop()
                delete(url)
            }
            return
        }
        switch started {
        case .success(let url):
            current.audio = audio
            current.audioURL = url
            current.marks.firstAudio = firstPacket.withLock { $0 }
        case .failure(let error):
            Self.audioLog.error("démarrage du micro impossible")
            failMicrophone(current, message: error.localizedDescription)
            return
        }
        current.marks.microphone = KeyboardTap.now()
        current.listening = true
        refreshPhase()
        changed()
        startMeter()
        signalAudioReady(current)
        watchFirstAudio(current, audio: audio) { firstPacket.withLock { $0 != nil } }
        watchMicrophoneAccess(current)
        // Le flux en direct reçoit les mots utiles du champ actif : attendus au plus 150 ms, l'audio est gardé
        // pendant ce temps et part dès que le flux est branché.
        if case .some(let snapshot) = await Self.value(of: field, within: Self.contextWait) {
            context.apply(snapshot)
        }
        guard capture === current, !current.cancelled else { return }
        let requestedSpeech = model.speechRequest(context: context, includeRecentDictations: true)
        let (speech, relayName) = routed(requestedSpeech, model: model)
        relay = relayName
        current.speech = speech
        if speech.provider != requestedSpeech.provider {
            current.voiceFallback = APIFallback(
                fromAPI: .transcription(requestedSpeech.provider, streaming: true),
                stage: .transcription, reason: .servicePaused
            )
        }
        let live = model.dependencies.makeSession(speech)
        current.session = live
        wireEarlyCorrection(live, for: current)
        current.pcm.attach { [weak live] data in live?.send(data) }
        let marks = current.marks
        current.startTask = Task { [weak current] in
            guard !Task.isCancelled, current?.cancelled == false else { return false }
            current?.streamAttemptedAt = Date()
            do {
                try await live.start()
                marks.stream = KeyboardTap.now()
                current?.streamStarted = true
                return true
            } catch {
                current?.streamFailure = APIFailureCause.classify(error)
                current?.streamStarted = false
                return false
            }
        }
    }

    /// Le son confirme l'arrivée réelle du micro, une seule fois, jamais une préparation ou une annulation.
    private func signalAudioReady(_ current: Capture) {
        guard capture === current, current.listening, !current.cancelled,
              current.marks.firstAudio != nil, !current.didSignalReady else { return }
        current.didSignalReady = true
        pushLevel(elapsed: Self.meterInterval)
        cue(.start)
        muteOutputAfterCue(current)
    }

    /// Le premier paquet se fait attendre : le micro redémarre une fois sur un moteur neuf, puis la dictée est
    /// abandonnée (`MicrophoneStartWatch`). L'écoute ne reste jamais muette avec une bulle figée.
    /// `packetArrived` lit l'arrivée du paquet là où le micro la note, sans attendre le fil principal.
    private func watchFirstAudio(_ current: Capture, audio: any AudioRecording, packetArrived: @escaping @Sendable () -> Bool) {
        guard !packetArrived() else { return }
        let limit = firstPacketLimit
        let restartLimit = audioRestartLimit
        current.audioWatch = Task { @MainActor [weak self] in
            var watch = MicrophoneStartWatch()
            while true {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard !Task.isCancelled, let self, self.isCapturing(current) else { return }
                switch watch.deadlinePassed(packetReceived: packetArrived()) {
                case .done:
                    return
                case .restart:
                    Self.audioLog.notice("aucun audio du micro : redémarrage sur un moteur neuf")
                    // Un moteur neuf peut tarder autant qu'au premier démarrage : même délai, jamais d'attente sans fin.
                    let busy = current.restarting
                    busy.withLock { $0 = true }
                    let restarting = Task.detached(priority: Task.currentPriority) { () async -> Bool in
                        defer { busy.withLock { $0 = false } }
                        do {
                            try await audio.restart()
                            return true
                        } catch {
                            return false
                        }
                    }
                    let restarted = await Self.value(of: restarting, within: restartLimit)
                    guard self.isCapturing(current) else { return }
                    guard restarted == true else {
                        _ = watch.restartFailed()
                        if restarted == nil {
                            // Il se refermera seul en rendant la main : rien n'attend sa file sur le fil principal.
                            audio.abandonStart()
                            current.audio = nil
                            Self.audioLog.error("redémarrage du micro trop long : dictée abandonnée")
                        } else {
                            Self.audioLog.error("redémarrage du micro impossible : dictée abandonnée")
                        }
                        self.failMicrophone(current, message: Self.microphoneStalledMessage)
                        return
                    }
                case .fail:
                    Self.audioLog.error("toujours aucun audio du micro : dictée abandonnée")
                    self.failMicrophone(current, message: Self.microphoneStalledMessage)
                    return
                }
            }
        }
    }

    /// Le micro n'a pas démarré : la dictée est abandonnée, Wispad revient prêt et la bulle dit pourquoi.
    private func failMicrophone(_ current: Capture, message: String) {
        shownFailure = ShownFailure(message: message, text: nil, offersHistory: false)
        model?.statusBanner = message
        discard(current)
    }

    /// Le micro s'est arrêté en pleine écoute sans pouvoir repartir : la dictée s'arrête là, comme si on l'avait
    /// terminée (ce qui a déjà été dit est transcrit et collé), le raccourci est libre et la bulle dit pourquoi.
    private func microphoneLost(_ current: Capture) {
        guard isCapturing(current) else { return }
        Self.audioLog.error("micro arrêté pendant l'écoute : dictée terminée avec l'audio déjà reçu")
        stopListening(current, message: Self.microphoneLostMessage)
    }

    /// L'écoute en cours ne peut plus continuer : elle s'arrête là, comme si on l'avait terminée (ce qui a déjà été
    /// dit est transcrit et collé), le raccourci est libre et la bulle dit pourquoi.
    private func stopListening(_ current: Capture, message: String) {
        guard isCapturing(current) else { return }
        endGesture()
        endCapture()
        model?.statusBanner = message
        shownFailure = ShownFailure(message: message, text: nil, offersHistory: false)
        refreshPhase()
        changed()
    }

    /// Accès au micro retiré dans Réglages Système pendant l'écoute : macOS n'arrête pas le moteur, il ne lui livre
    /// plus que du silence, et la dictée continuerait sur un spectre immobile. Vérifié chaque seconde, pendant
    /// l'écoute seulement et si l'accès était accordé au départ ; jamais une demande à macOS.
    /// Chaque lecture interroge le démon des autorisations de macOS (une dizaine de millisecondes) : faite hors du
    /// fil principal, pour que le spectre ne saccade pas.
    private func watchMicrophoneAccess(_ current: Capture) {
        guard let model else { return }
        let authorized = model.dependencies.microphoneAuthorized
        let interval = microphoneAccessInterval
        current.microphoneAccessWatch = Task { @MainActor [weak self] in
            // Accès refusé au départ (tests, machine de vérification) : rien n'est surveillé.
            guard await PermissionReads.offMain(authorized) else { return }
            while true {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.isCapturing(current) else { return }
                guard await !PermissionReads.offMain(authorized) else { continue }
                guard !Task.isCancelled, self.isCapturing(current) else { return }
                Self.audioLog.error("accès au micro retiré pendant l'écoute : dictée terminée avec l'audio déjà reçu")
                self.stopListening(current, message: Self.microphoneRevokedMessage)
                return
            }
        }
    }

    /// L'écoute du clavier a été retirée faute d'une autorisation (`KeyboardTap`) : ni le raccourci ni Échap
    /// n'atteindraient plus la dictée en cours. Elle s'arrête là, comme si on l'avait terminée, et la bulle dit
    /// pourquoi ; un micro encore en démarrage est abandonné (rien n'a été dit). Les gestes encore en file ou en
    /// attente de la clé sont oubliés avec elle (`HotkeyLogic.listeningLost`) : leur dictée ne démarre pas.
    func keyboardLost(_ permissions: KeyboardPermissions) {
        keyboardLosses += 1
        guard let current = capture, !current.cancelled else { return }
        let message = Self.keyboardLostMessage(permissions)
        hotkeyLog.notice("écoute du clavier retirée pendant la dictée : dictée terminée")
        if current.listening {
            stopListening(current, message: message)
        } else {
            shownFailure = ShownFailure(message: message, text: nil, offersHistory: false)
            model?.statusBanner = message
            discard(current, outcome: .cancelled)
        }
    }

    /// Relais pris d'emblée : voix chez l'autre fournisseur si le principal est en panne (jamais hors connexion, où
    /// la bascule échouerait de même), correction par OpenAI si DeepSeek l'est.
    private func routed(_ speech: SpeechRequest, model: AppModel) -> (speech: SpeechRequest, relay: String?) {
        if model.health.isDown(ServiceHealth.voice(speech.provider)), let fallback = model.voiceRelay(for: speech) {
            return (fallback, fallback.provider.displayName)
        }
        if speech.cleanupPrimaryDown, model.settings.cleanupEnabled, !(speech.fallbackKey ?? "").isEmpty {
            return (speech, ProviderID.openAI.displayName)
        }
        return (speech, nil)
    }

    /// Fin de l'écoute : le micro se ferme tout de suite, la dictée se termine en arrière-plan et le raccourci
    /// est aussitôt libre pour la suivante. Rend la tâche de fin (attendue par les tests).
    @discardableResult
    func endCapture() -> Task<Void, Never>? {
        guard let current = capture, current.listening else { return nil }
        capture = nil
        current.audioWatch?.cancel()
        current.microphoneAccessWatch?.cancel()
        stopMeter()
        let stopped = closeMicrophone(current)
        current.pcm.close()
        current.marks.released = KeyboardTap.now()
        let url = stopped?.url ?? current.audioURL
        let duration = max(0, stopped?.duration ?? 0)
        guard duration >= Self.minimumDuration else {
            current.correctionClaimed = true
            if let model { accountEarlyCorrections(current, model: model, cancel: true) }
            current.startTask?.cancel()
            recordStreaming(current, seconds: duration, succeeded: false, stoppedByWispad: true)
            current.session?.cancel()
            delete(url)
            if let model { current.run.complete(.noSpeech, model: model) }
            refreshPhase()
            changed()
            return nil
        }
        let job = FinishJob(capture: current, url: url, duration: duration, previous: jobs.last?.pasted)
        jobs.append(job)
        // La correction part sur ce qui a déjà été entendu, pendant que le flux finalise son texte.
        prepareCorrectionAtRelease(current)
        // L'écoute est finie : le son du Mac revient avant le son de fin, pour qu'on l'entende.
        refreshPhase()
        cue(.stop)
        changed()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finish(job)
        }
        job.task = task
        return task
    }

    /// Cette écoute est toujours en cours (ni arrêtée, ni annulée).
    func isCapturing(_ current: Capture) -> Bool {
        capture === current && current.listening && !current.cancelled
    }

    /// Termine l'écoute et attend que la dictée soit collée.
    func end() async {
        await endCapture()?.value
    }

    func dismissFailure() {
        guard shownFailure != nil || phase.isFailure else { return }
        shownFailure = nil
        failureTimer.cancel()
        refreshPhase()
        changed()
    }

    /// Échap, ✕ ou menu. Pendant l'écoute, seule cette dictée est abandonnée : celles qui se terminent continuent.
    /// Sinon, ce qui se termine est annulé et rien n'est collé.
    func cancel() {
        if let current = capture {
            cancelCapture(current)
            return
        }
        if phase.isFailure || shownFailure != nil {
            dismissFailure()
            return
        }
        guard !jobs.isEmpty || retrying else { return }
        generation += 1
        // Un collage envoyé ne peut plus être annulé. Sa confirmation doit conserver le vrai statut,
        // même si Échap arrive pendant la relecture du champ.
        for job in jobs where !job.pasteSent {
            job.cancelled = true
            job.task?.cancel()
            job.cancelSideWork()
        }
        retrying = false
        refreshPhase()
        changed()
    }

    private func cancelCapture(_ current: Capture) {
        current.cancelled = true
        current.correctionClaimed = true
        current.audioWatch?.cancel()
        current.microphoneAccessWatch?.cancel()
        capture = nil
        stopMeter()
        current.startTask?.cancel()
        current.field.cancel()
        let stopped = closeMicrophone(current)
        current.pcm.close()
        // L'audio a pu partir, mais une annulation ne confirme ni son traitement ni sa facturation.
        recordStreaming(current, seconds: stopped?.duration ?? 0, succeeded: false, stoppedByWispad: true)
        current.session?.cancel()
        delete(stopped?.url ?? current.audioURL)
        if let model {
            accountEarlyCorrections(current, model: model, cancel: true)
            current.run.complete(.cancelled, model: model)
        }
        endGesture()
        refreshPhase()
        cue(.cancel)
        changed()
    }

    /// Ferme le micro de cette écoute. Pendant son redémarrage (`watchFirstAudio`), `stop()` attendrait la fin du
    /// moteur neuf sur le fil principal (file du micro) : Wispad resterait figé. Le micro se refermera seul en rendant
    /// la main (`abandonStart`), sans audio à garder : aucun paquet n'était arrivé, d'où le redémarrage.
    private func closeMicrophone(_ current: Capture) -> (url: URL?, duration: Double)? {
        defer { current.audio = nil }
        guard let audio = current.audio else { return nil }
        guard !current.restarting.withLock({ $0 }) else {
            audio.abandonStart()
            return nil
        }
        return audio.stop()
    }

    /// Écoute qui n'a pas pu commencer (micro refusé, capture impossible) ou micro resté muet : tout ce qu'elle a
    /// ouvert se referme, spectre et flux en direct compris.
    private func discard(_ current: Capture, outcome: DictationOutcome = .captureFailed) {
        current.cancelled = true
        current.audioWatch?.cancel()
        current.microphoneAccessWatch?.cancel()
        capture = nil
        stopMeter()
        current.startTask?.cancel()
        current.field.cancel()
        current.pcm.close()
        let stopped = closeMicrophone(current)
        // Flux déjà branché quand le micro reste muet : refermé, sans audio rien n'a été envoyé ni facturé.
        current.session?.cancel()
        delete(stopped?.url ?? current.audioURL)
        if let model { current.run.complete(outcome, model: model) }
        endGesture()
        refreshPhase()
        changed()
    }

    private func finish(_ job: FinishJob) async {
        guard let model else { return }
        let current = job.capture
        defer {
            // Corrections préparées pendant l'écoute et restées sans usage : comptées, jamais collées.
            current.correctionClaimed = true
            accountEarlyCorrections(current, model: model, cancel: job.cancelled)
            current.run.complete(job.cancelled ? .cancelled : current.run.trace.outcome, model: model)
            settle(job)
        }
        let transcriptionBegan = KeyboardTap.now()
        let context = current.context
        let url = job.url
        var speech = current.speech ?? model.speechRequest(context: context, includeRecentDictations: true)
        let finishStarted = Date()
        // Le fichier part en même temps que la fin du flux : s'ils concordent, la correction du flux est déjà lancée.
        let fileLedger: FileLedger? = model.settings.verifyWithFile && current.session != nil && url != nil && !job.cancelled
            ? launchFile(url: url!, speech: speech, seconds: job.duration, run: current.run, model: model) : nil
        if let fileLedger {
            job.cancelSideWork = { fileLedger.task.cancel() }
        }
        let started = await current.startTask?.value ?? false
        var raw = ""
        var liveBroke = current.session != nil && !started
        var streamFinish: StreamFinish?
        let streamClock = Date()
        if let session = current.session, started, !job.cancelled {
            do {
                let finish = try await session.finish()
                streamFinish = finish
                raw = finish.text
            } catch {
                current.streamFailure = APIFailureCause.classify(error)
                liveBroke = true
            }
        }
        let streamMs = Self.milliseconds(since: streamClock)
        recordStreaming(current, seconds: job.duration, latencyMs: streamMs, succeeded: !liveBroke)
        current.session?.cancel()
        if job.cancelled {
            fileLedger?.task.cancel()
            await fileLedger?.account()
            delete(url)
            return
        }
        let streamed = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if current.session != nil, liveBroke || streamed {
            model.recordHealth(ServiceHealth.voice(speech.provider), succeeded: !liveBroke)
            if !liveBroke { announcedRelays.remove(ServiceHealth.voice(speech.provider)) }
        }
        var correctionLedger: CorrectionLedger?
        var usePrepared = false
        var alternative: String?
        if let fileLedger {
            let decision = await verifyAgainstFile(
                raw: raw, streamed: streamed, liveBroke: liveBroke, streamMs: streamMs,
                finishStarted: finishStarted, speech: speech, ledger: fileLedger, job: job,
                model: model, context: context, transcriptionBegan: transcriptionBegan
            )
            if decision.stop { return }
            raw = decision.raw
            alternative = decision.alternative
            speech = decision.speech
            correctionLedger = decision.ledger
            usePrepared = decision.usePrepared
        } else if let legacy = await legacyTranscript(
            raw: raw, streamed: streamed, streamFinish: streamFinish, streamMs: streamMs,
            speech: &speech, job: job, model: model, context: context, transcriptionBegan: transcriptionBegan
        ) {
            raw = legacy
        } else {
            return
        }
        // Retouches franglaises prudentes (références matérielles, OAuth…) avant la correction, puis après.
        let transcript = FranglaisNormalizer.normalize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        current.run.trace.timings.transcriptionMs = max(0, KeyboardTap.now() - transcriptionBegan)
        guard !transcript.isEmpty else {
            current.run.trace.outcome = .noSpeech
            delete(url)
            model.statusBanner = String(localized: "Aucune parole détectée.")
            return
        }
        let cleaned: CleanupOutcome
        if !context.fieldRead { context.apply(await current.field.value) }
        let commandSelection = model.commandSelection(for: transcript, context: context)
        if let commandSelection {
            // Consigne sur la sélection : aucune correction préparée ne sert ; elles restent comptées.
            if let correctionLedger {
                Task { @MainActor in _ = await correctionLedger.account(model: model, run: current.run) }
            }
            current.correctionClaimed = true
            current.run.trace.selectionCommand = true
            var request = await makeCorrectionRequest(
                transcript: transcript, context: context, field: current.field, window: current.window, model: model
            )
            request.commandSelection = commandSelection
            let began = KeyboardTap.now()
            cleaned = await model.dependencies.clean(transcript, request, speech, model.correctionReachable)
            current.run.trace.timings.correctionMs = max(0, KeyboardTap.now() - began)
            for usage in cleaned.failedUsages { current.run.record(usage) }
            if let usage = cleaned.usage { current.run.record(usage) }
            model.recordCleanup(cleaned)
        } else if usePrepared, let correctionLedger {
            let prepared = await correctionLedger.account(model: model, run: current.run)
            cleaned = prepared.outcome
            if model.settings.cleanupEnabled {
                current.run.trace.timings.correctionMs = prepared.milliseconds
            }
            if current.earlyReady?.ledger === correctionLedger { current.run.trace.earlyCorrectionUsed = true }
        } else if alternative == nil, model.settings.cleanupEnabled,
                  let early = claimEarlyCorrection(for: transcript, current: current, model: model) {
            // Rien n'a été ajouté depuis la dernière pause : la correction préparée pendant l'écoute sert telle quelle.
            let prepared = await early.account(model: model, run: current.run)
            cleaned = prepared.outcome
            current.run.trace.timings.correctionMs = prepared.milliseconds
            current.run.trace.earlyCorrectionUsed = true
        } else if let alternative, let correctionLedger, model.settings.cleanupEnabled,
                  let patched = await patchPreparedCorrection(
                      correctionLedger, stream: FranglaisNormalizer.normalize(alternative), file: transcript, current: current, model: model
                  ) {
            // Fichier différent d'un ou deux mots : ils passent dans la correction du flux, sans second appel.
            cleaned = patched.outcome
            current.run.trace.timings.correctionMs = patched.milliseconds
            current.run.trace.correctionPatched = true
            if current.earlyReady?.ledger === correctionLedger { current.run.trace.earlyCorrectionUsed = true }
        } else {
            // Fichier différent : la correction du flux est déjà payée, on en lance une autre sur le texte retenu
            // sans l'attendre (mesuré le 5 octobre : 1,1 s puis 1,0 s en série). Elle est comptée dès qu'elle finit,
            // même après le collage : la trace l'ajoute alors à la dictée.
            var correction = await makeCorrectionRequest(
                transcript: transcript, context: context, field: current.field, window: current.window, model: model
            )
            correction.alternativeTranscript = alternative.map { FranglaisNormalizer.normalize($0) }
            let correctionBegan = KeyboardTap.now()
            let reachable = model.correctionReachable
            let retained = CorrectionLedger(task: Task { @MainActor in
                let began = Date()
                let outcome = await model.dependencies.clean(transcript, correction, speech, reachable)
                return PreparedCorrection(outcome: outcome, milliseconds: Self.milliseconds(since: began))
            })
            let otherSideWork = job.cancelSideWork
            job.cancelSideWork = {
                otherSideWork()
                retained.task.cancel()
            }
            // Fichier différent d'un ou deux mots alors que la correction du flux tourne encore (106 dictées sur 179
            // divergentes, mesuré le 13 octobre 2026) : elle finit souvent avant celle du fichier. La première qui
            // sert l'emporte ; l'autre est comptée quand elle finit.
            let stream = alternative.map { FranglaisNormalizer.normalize($0) }
            if let stream, let correctionLedger, model.settings.cleanupEnabled,
               CorrectionPatch.isCandidate(stream: stream, file: transcript),
               await Self.finishesFirst(correctionLedger, before: retained),
               let patched = await patchPreparedCorrection(correctionLedger, stream: stream, file: transcript, current: current, model: model) {
                cleaned = patched.outcome
                current.run.trace.timings.correctionMs = patched.milliseconds
                current.run.trace.correctionPatched = true
                if current.earlyReady?.ledger === correctionLedger { current.run.trace.earlyCorrectionUsed = true }
                Task { @MainActor in _ = await retained.account(model: model, run: current.run) }
            } else {
                if let correctionLedger {
                    Task { @MainActor in _ = await correctionLedger.account(model: model, run: current.run) }
                }
                cleaned = await retained.account(model: model, run: current.run).outcome
                if model.settings.cleanupEnabled {
                    current.run.trace.timings.correctionMs = max(0, KeyboardTap.now() - correctionBegan)
                }
            }
        }
        if let fallback = cleaned.fallback {
            showRelay(fallback)
            let primary = cleaned.failedUsages.first?.api.provider ?? ServiceHealth.deepSeek
            announceRelay("cleanup", String(localized: "\(primary) ne répond pas : correction via \(fallback)."), job: job)
        } else if cleaned.usage?.succeeded == true {
            announcedRelays.remove("cleanup")
        }
        // Une consigne sans réponse ne colle rien : la sélection reste intacte.
        if commandSelection != nil, cleaned.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.run.trace.outcome = .commandFailed
            await waitForTurn(job)
            delete(url)
            guard !job.cancelled else { return }
            let message = String(localized: "Consigne non appliquée : la sélection est inchangée.")
            model.statusBanner = message
            showFailure(message, text: nil)
            return
        }
        let finalText = commandSelection != nil
            ? cleaned.text
            : FranglaisNormalizer.normalize(cleaned.text)
        // Les dictées se collent dans l'ordre où elles ont été dites.
        await waitForTurn(job)
        guard !job.cancelled else {
            delete(url)
            return
        }
        let record = DictationRecord(
            finalText: finalText,
            rawText: transcript,
            durationSeconds: job.duration,
            wordCount: WordCount.count(finalText),
            provider: speech.provider.rawValue,
            model: speech.liveModel,
            targetApp: context.appName,
            targetBundle: context.bundleID,
            usageCategory: UsageClassifier.classify(bundleIdentifier: context.bundleID, appName: context.appName).rawValue,
            insertionStatus: InsertionStatus.pending.rawValue,
            audioPath: url?.path,
            alternativeText: alternative
        )
        do {
            try model.store.insert(record)
        } catch {
            current.run.trace.outcome = .historyFailed
            model.statusBanner = String(localized: "L'enregistrement local a échoué.")
            showFailure(String(localized: "Historique indisponible. Copie le texte avant de fermer."), text: finalText)
            return
        }
        current.run.trace.dictationID = record.id
        let insertionBegan = KeyboardTap.now()
        let status: InsertionStatus
        // Essai du premier lancement, dicté dans la fenêtre de Wispad : écrit directement dans le champ d'essai.
        // Un Cmd+V envoyé à soi-même et la lecture d'accessibilité de sa propre fenêtre ne sont pas fiables.
        let trial = model.onboarding.flatMap { $0.acceptsDictation(targetPID: context.pid) ? $0 : nil }
        if let trial {
            trial.receiveDictation(finalText)
            status = .inserted
        } else {
            status = await model.dependencies.insert(finalText, context, { [weak job] in
                job.map { !$0.cancelled } ?? false
            }, { [weak self, weak job] in
                guard let self, let job, !job.cancelled else { return }
                job.pasteSent = true
                job.capture.marks.pasteSent = KeyboardTap.now()
                self.refreshPhase()
                self.changed()
            })
        }
        current.marks.pasted = KeyboardTap.now()
        current.run.trace.timings.insertionMs = max(0, KeyboardTap.now() - insertionBegan)
        current.run.trace.outcome = DictationOutcome(status)
        guard !job.cancelled else {
            model.persist("statut d'une dictée") { try model.store.updateStatus(id: record.id, status: InsertionStatus.cancelled.rawValue) }
            applyRetention(recordID: record.id, url: url, status: .cancelled, model: model)
            model.reloadHistory()
            return
        }
        model.persist("statut d'une dictée") { try model.store.updateStatus(id: record.id, status: status.rawValue) }
        applyRetention(recordID: record.id, url: url, status: status, model: model)
        model.reloadHistory()
        LatencyLog.append(
            LatencyLog.line(current.marks, mode: current.mode, status: status.rawValue),
            to: model.supportURL.appendingPathComponent(LatencyLog.fileName)
        )
        if status.delivered {
            // Apprentissage seulement sur un texte vu dans le champ ; un champ illisible ne dit rien de plus.
            if status == .inserted {
                watchCorrections(
                    of: finalText, status: status, pid: context.pid, selectionCommand: commandSelection != nil,
                    writtenByWispad: trial != nil, speech: speech, traceID: current.run.trace.id
                )
            }
            // Collage normal : rien à signaler, la dictée reste de toute façon dans l'historique.
            // Collage envoyé dans un champ illisible (Codex, apps Electron) : pas de message à chaque dictée ;
            // « Coller la dernière dictée » et l'historique restent là si le texte manque.
            model.statusBanner = nil
            job.delivered = true
            if let note = job.announcement { pendingAnnouncement = note.message }
        } else {
            offerReadyText(finalText, status: status, recordID: record.id, accessibilityRefused: context.accessibilityRefused,
                           heldModifiers: context.heldModifiers)
        }
        // La bulle part d'abord ; le ménage des vieux audios vient après.
        settle(job)
        model.purgeAudio()
    }

    /// Texte livré : le champ est surveillé pour apprendre les mots corrigés à la main (`CorrectionWatch.shouldStart`).
    private func watchCorrections(
        of text: String, status: InsertionStatus, pid: pid_t?, selectionCommand: Bool, writtenByWispad: Bool,
        speech: SpeechRequest, traceID: String?
    ) {
        guard let model, let pid, CorrectionWatch.shouldStart(
            status: status, learnCorrections: model.settings.learnCorrections,
            selectionCommand: selectionCommand, writtenByWispad: writtenByWispad
        ) else { return }
        model.dependencies.watchCorrections(text, pid, model.dictionary.map(\.term)) { [weak model] candidates in
            model?.considerLearning(candidates, dictated: text, speech: speech, traceID: traceID)
        }
    }

    /// Attend que la dictée précédente soit collée (ou abandonnée).
    func waitForTurn(_ job: FinishJob) async {
        try? await job.previous?.value()
    }

    /// La dictée est terminée : la suivante peut coller, la bulle suit.
    private func settle(_ job: FinishJob) {
        job.pasted.resolve(.success(()))
        guard let index = jobs.firstIndex(where: { $0 === job }) else { return }
        jobs.remove(at: index)
        // Bascule non annoncée (dictée annulée ou non collée) : la prochaine dictée relayée la dira.
        if !job.delivered, let note = job.announcement { announcedRelays.remove(note.service) }
        refreshPhase()
        changed()
    }

    private func showFailure(_ message: String, text: String?, recordID: String? = nil) {
        shownFailure = ShownFailure(message: message, text: text, recordID: recordID)
        refreshPhase()
        changed()
    }

    // MARK: - Texte prêt, faute de champ

    /// Message de la bulle quand le texte n'a pas pu être écrit : court, toujours suivi de Copier. Collage refusé
    /// faute d'accessibilité : la bulle dit laquelle manque, plutôt qu'un texte « pas arrivé » jamais envoyé.
    /// Collage retenu parce qu'une touche modificatrice est restée tenue : la bulle dit laquelle.
    static func readyMessage(for status: InsertionStatus, accessibilityRefused: Bool = false, heldModifiers: UInt64 = 0) -> String {
        if accessibilityRefused { return String(localized: "Accessibilité non autorisée : le texte est prêt") }
        if status == .failed, heldModifiers != 0 {
            let keys = TextInserter.modifierNames(heldModifiers)
            return (heldModifiers & ModifierMask.relevant).nonzeroBitCount == 1
                ? String(localized: "Touche \(keys) maintenue : le texte est prêt")
                : String(localized: "Touches \(keys) maintenues : le texte est prêt")
        }
        switch status {
        case .noTarget: return String(localized: "Pas de champ où écrire : le texte est prêt")
        case .refusedSecure: return String(localized: "Champ sécurisé : le texte est prêt")
        case .failed: return String(localized: "Le texte n'est pas arrivé dans le champ")
        default: return String(localized: "Collage impossible : le texte est prêt")
        }
    }

    /// Échec avéré : le texte reste récupérable sans voler le focus. Il est copié, sauf vers un champ sécurisé
    /// où il ne doit pas traîner dans le presse-papiers.
    private func offerReadyText(_ text: String, status: InsertionStatus, recordID: String?, accessibilityRefused: Bool = false,
                                heldModifiers: UInt64 = 0) {
        guard let model else { return }
        if status != .refusedSecure { model.dependencies.copyText(text) }
        Self.insertionLog.notice("récupération du collage : \(status.rawValue, privacy: .public)")
        let message = Self.readyMessage(for: status, accessibilityRefused: accessibilityRefused, heldModifiers: heldModifiers)
        model.statusBanner = message
        showFailure(message, text: text, recordID: recordID)
    }

    /// Copier, dans la bulle : le texte part dans le presse-papiers et la bulle confirme « Copié ».
    func copyReadyText() {
        guard let model, let failure = shownFailure, let text = failure.text else { return }
        model.dependencies.copyText(text)
        model.statusBanner = String(localized: "Texte copié.")
        shownFailure = ShownFailure(message: String(localized: "Copié"), text: nil, copied: true)
        refreshPhase()
        changed()
    }

    /// Coller, dans la bulle : la bulle ne prend jamais le focus, le texte va donc au champ de l'app active.
    func pasteReadyText() {
        guard let failure = shownFailure, let text = failure.text else { return }
        let record = failure.recordID.flatMap { id in model?.history.first { $0.id == id } }
        dismissFailure()
        Task { @MainActor [weak self] in await self?.pasteAgain(text, record: record) }
    }

    /// Raccourci « Coller la dernière dictée » : la dernière dictée non insérée, sinon la dernière dictée, au
    /// curseur actuel. Ignoré pendant une écoute : la bulle et le micro servent à cette dictée.
    func pasteLastDictation() async {
        guard let model, capture == nil, !pastingAgain else { return }
        // Les dictées qui se terminent se collent d'abord, dans l'ordre.
        while let last = jobs.last {
            try? await last.pasted.value()
            if jobs.last === last { break }
        }
        guard capture == nil, !pastingAgain else { return }
        guard let record = PasteLastChoice.pick(model.history) else {
            dismissFailure()
            announce(String(localized: "Aucune dictée à coller"), relay: false, info: true)
            return
        }
        await pasteAgain(record.finalText, record: record)
    }

    /// Même collage qu'une dictée (presse-papiers restauré après), dans l'app au premier plan. Collé, il finit comme
    /// une dictée : statut et app dans l'historique, surveillance des corrections, et « Collé » dans la bulle.
    /// Sans champ, même message que la dictée.
    private func pasteAgain(_ text: String, record: DictationRecord?) async {
        guard let model, capture == nil, !pastingAgain else { return }
        pastingAgain = true
        defer { pastingAgain = false }
        dismissFailure()
        guard capture == nil else { return }
        let target = model.dependencies.frontmostApp()
        let status = await model.dependencies.insert(text, target, { [weak self] in self?.capture == nil }, {})
        if let record, let updated = PasteLastChoice.updatedStatus(previous: record.insertionStatus, outcome: status) {
            let category = target.appName == nil && target.bundleID == nil
                ? nil
                : UsageClassifier.classify(bundleIdentifier: target.bundleID, appName: target.appName).rawValue
            model.persist("statut d'une dictée") {
                try model.store.updateDelivery(
                    id: record.id, status: updated.rawValue,
                    targetApp: target.appName, targetBundle: target.bundleID, usageCategory: category
                )
            }
            model.reloadHistory()
        }
        switch status {
        case .inserted, .pasteSent:
            model.statusBanner = nil
            if status == .inserted, let record {
                // Une trace illisible compte comme une consigne : dans le doute, rien n'est appris.
                let traces = try? model.store.traces(dictationID: record.id)
                watchCorrections(
                    of: text, status: status, pid: target.pid,
                    selectionCommand: traces.map { list in list.contains { $0.selectionCommand == true } } ?? true,
                    writtenByWispad: false, speech: model.speechRequest(context: target), traceID: traces?.first?.id
                )
            }
            announce(String(localized: "Collé"), relay: false)
        case .cancelled: break
        default: offerReadyText(text, status: status, recordID: record?.id, accessibilityRefused: target.accessibilityRefused,
                                heldModifiers: target.heldModifiers)
        }
    }

    /// Couleur de relais : seulement si la bulle montre cette dictée, pas l'écoute d'une autre.
    func showRelay(_ name: String) {
        if capture == nil { relay = name }
    }

    /// Phase montrée par la bulle et le menu : l'écoute d'abord, puis un message d'erreur, puis ce qui se termine.
    private func refreshPhase() {
        let next: DictationPhase
        if let capture {
            next = capture.listening ? .listening(capture.mode) : .starting
        } else if let shownFailure {
            next = .failure(shownFailure.message)
        } else if !jobs.isEmpty || retrying {
            next = .finishing
        } else {
            next = .idle
        }
        let text = capture == nil ? shownFailure?.text : nil
        if failureText != text { failureText = text }
        let copied = capture == nil && shownFailure?.copied == true
        if failureCopied != copied { failureCopied = copied }
        let offersHistory = shownFailure?.offersHistory ?? true
        if failureOffersHistory != offersHistory { failureOffersHistory = offersHistory }
        if phase != next { phase = next }
        scheduleFailureDismissal()
        // Relais, puis confirmation d'un mot appris, dès que la bulle est libre.
        if phase == .idle, notice == nil {
            presentIdleBubble()
        }
        guard let model else { return }
        // Ne pas libérer la file de collage avant la restauration du presse-papiers.
        // Son attente de confirmation est toutefois invisible ; une autre dictée reste prioritaire.
        let onlyConfirming = capture == nil && shownFailure == nil && !retrying
            && !jobs.isEmpty && jobs.allSatisfy(\.pasteSent)
        if onlyConfirming {
            model.overlay.hide()
        } else if phase != .idle {
            model.overlay.show()
        } else if notice == nil {
            model.overlay.hide()
        }
    }

    /// L'enregistrement reste dans l'historique : la bulle d'erreur se retire seule.
    private func scheduleFailureDismissal() {
        guard phase.isFailure, let failure = shownFailure, dismissing != failure.id else { return }
        dismissing = failure.id
        let seconds = failure.copied ? Self.copiedSeconds : Self.failureSeconds
        failureTimer.start(seconds: seconds, paused: messagesHeld) { [weak self] in
            guard let self, self.shownFailure?.id == failure.id else { return }
            self.dismissFailure()
        }
    }

    /// Survol d'un message par le pointeur : les décomptes s'arrêtent, puis reprennent à la sortie.
    func holdMessages(_ held: Bool) {
        guard messagesHeld != held else { return }
        messagesHeld = held
        failureTimer.setPaused(held)
        noticeTimer.setPaused(held)
    }

    /// ✕ de la bulle : le message affiché part tout de suite, comme à la fin de son décompte.
    func closeMessage() {
        if phase.isFailure {
            dismissFailure()
        } else if phase == .idle {
            dismissCurrentNotice()
        }
    }

    func retranscribe(_ record: DictationRecord) async {
        dismissFailure()
        guard let model, !retrying else { return }
        guard capture == nil else {
            model.statusBanner = String(localized: "Une dictée est en cours : réessaie quand elle sera finie.")
            return
        }
        // Les dictées qui se terminent passent d'abord, puis la nouvelle transcription.
        while let last = jobs.last {
            try? await last.pasted.value()
            if jobs.last === last { break }
        }
        guard capture == nil, jobs.isEmpty, !retrying else { return }
        guard let path = record.audioPath, FileManager.default.fileExists(atPath: path) else {
            model.statusBanner = String(localized: "L'audio d'origine n'est plus disponible.")
            return
        }
        let run = DictationTraceRecorder(origin: .retry)
        run.trace.dictationID = record.id
        let problem = await model.voiceProblem()
        guard capture == nil, jobs.isEmpty, !retrying else { return }
        if let problem {
            run.complete(problem.outcome, model: model)
            model.statusBanner = problem.message
            model.open(.providers)
            return
        }
        let token = generation
        retrying = true
        model.statusBanner = String(localized: "Nouvelle transcription…")
        refreshPhase()
        changed()
        // A retry from History updates History; it must not paste into its own search field.
        let retryContext = DictationContext()
        retryContext.appName = record.targetApp
        retryContext.bundleID = record.targetBundle
        // Retranscription d'un ancien audio : pas de dictées récentes, le sujet peut avoir changé.
        let speech = model.speechRequest(context: retryContext)
        run.trace.outcome = .transcriptionFailed
        defer {
            run.complete(generation == token && !Task.isCancelled ? run.trace.outcome : .cancelled, model: model)
            if generation == token {
                retrying = false
                refreshPhase()
                changed()
            }
        }
        let transcriptionBegan = KeyboardTap.now()
        do {
            let raw = FranglaisNormalizer.normalize(try await transcribeFile(URL(fileURLWithPath: path), speech: speech, seconds: record.durationSeconds, run: run))
            run.trace.timings.transcriptionMs = max(0, KeyboardTap.now() - transcriptionBegan)
            guard generation == token, !Task.isCancelled else { return }
            let correctionBegan = KeyboardTap.now()
            var request = CorrectionRequest(transcript: raw, dictionary: model.dictionary.map(\.term), appName: record.targetApp,
                                            structureDictation: model.settings.structureDictation, language: model.settings.language)
            request.tone = model.tone(bundleID: record.targetBundle, appName: record.targetApp)
            request.dateFormat = model.settings.dateFormat
            request.numberFormat = model.settings.numberFormat
            let cleaned = await model.dependencies.clean(
                raw,
                request,
                speech,
                model.correctionReachable
            )
            if model.settings.cleanupEnabled {
                run.trace.timings.correctionMs = max(0, KeyboardTap.now() - correctionBegan)
            }
            for usage in cleaned.failedUsages { run.record(usage) }
            if let usage = cleaned.usage { run.record(usage) }
            model.recordCleanup(cleaned)
            let finalText = FranglaisNormalizer.normalize(cleaned.text)
            guard generation == token, !Task.isCancelled else { return }
            guard !finalText.isEmpty else {
                run.trace.outcome = .noSpeech
                model.statusBanner = String(localized: "La nouvelle transcription est vide. L'audio est conservé.")
                return
            }
            run.trace.outcome = .historyFailed
            try model.store.updateTranscript(id: record.id, finalText: finalText, rawText: raw, wordCount: WordCount.count(finalText))
            try model.store.updateStatus(id: record.id, status: InsertionStatus.pending.rawValue)
            run.trace.outcome = .pending
            model.statusBanner = String(localized: "Transcription mise à jour. Utilise Copier pour l'insérer où tu veux.")
            model.reloadHistory()
        } catch {
            if run.trace.timings.transcriptionMs == nil {
                run.trace.timings.transcriptionMs = max(0, KeyboardTap.now() - transcriptionBegan)
            }
            guard generation == token, !Task.isCancelled else { return }
            model.statusBanner = String(localized: "Transcription impossible. Vérifie la clé, le réseau et le quota du fournisseur. L'audio est conservé.")
        }
    }

    func preserveFailedAudio(_ url: URL, duration: Double, speech: SpeechRequest, context: DictationContext, model: AppModel, run: DictationTraceRecorder) {
        let record = DictationRecord(
            finalText: "", rawText: "", durationSeconds: duration, wordCount: 0,
            provider: speech.provider.rawValue, model: speech.liveModel,
            targetApp: context.appName, targetBundle: context.bundleID,
            insertionStatus: InsertionStatus.transcriptionFailed.rawValue,
            audioPath: url.path
        )
        do {
            try model.store.insert(record)
            run.trace.dictationID = record.id
            applyRetention(recordID: record.id, url: url, status: .transcriptionFailed, model: model)
            model.reloadHistory()
            model.purgeAudio()
            model.statusBanner = String(localized: "Transcription impossible. Vérifie la clé, le réseau et le quota, puis réessaie depuis l'historique.")
        } catch {
            model.statusBanner = String(localized: "Transcription et historique indisponibles. L'audio est conservé dans le dossier Audio de Wispad.")
        }
        showFailure(String(localized: "Transcription impossible. L'audio est gardé dans l'historique."), text: nil)
    }

    private func applyRetention(recordID: String, url: URL?, status: InsertionStatus, model: AppModel) {
        let succeeded = status == .inserted
        if RetentionPolicy.shouldDeleteImmediately(mode: model.settings.retention, insertionSucceeded: succeeded) {
            delete(url)
            model.persist("conservation de l'audio") { try model.store.updateAudio(id: recordID, path: nil, expiresAt: nil) }
            return
        }
        let expiry = RetentionPolicy.expiry(
            mode: model.settings.retention,
            temporaryHours: model.settings.temporaryHours,
            now: Date(),
            insertionSucceeded: succeeded
        )
        model.persist("conservation de l'audio") { try model.store.updateAudio(id: recordID, path: url?.path, expiresAt: expiry) }
    }

    /// Compte le flux en direct d'une dictée, une seule fois (fin, annulation ou dictée trop courte).
    /// Sans succès explicite, le flux compte comme réussi s'il a démarré. Un flux arrêté par Wispad (annulation,
    /// dictée trop courte) est noté « annulé » : il n'entre pas dans les échecs des fournisseurs.
    private func recordStreaming(_ capture: Capture, seconds: Double, latencyMs: Int = 0, succeeded: Bool? = nil,
                                 stoppedByWispad: Bool = false) {
        guard !capture.streamUsageRecorded, let started = capture.streamAttemptedAt,
              capture.session != nil, let speech = capture.speech, let model else { return }
        capture.streamUsageRecorded = true
        let ok = succeeded ?? (capture.streamStarted == true)
        let event = UsageEvent.transcription(
            provider: speech.provider,
            streaming: true,
            model: speech.liveModel,
            audioSeconds: seconds,
            latencyMs: latencyMs,
            succeeded: ok,
            at: started,
            fallback: capture.voiceFallback,
            failureCause: ok ? nil : (stoppedByWispad ? .cancelled : capture.streamFailure ?? .badResponse)
        )
        capture.run.record(event)
        model.recordUsage(event)
    }

    func transcribeFile(_ url: URL, speech: SpeechRequest, seconds: Double, run: DictationTraceRecorder, fallback: APIFallback? = nil) async throws -> String {
        try Task.checkCancellation()
        let started = Date()
        do {
            let text = try await model?.dependencies.transcribe(url, speech) ?? ""
            let event = UsageEvent.transcription(
                provider: speech.provider, streaming: false, model: speech.liveModel, billedModel: speech.fileModel,
                audioSeconds: seconds, latencyMs: Self.milliseconds(since: started), at: started, fallback: fallback
            )
            run.record(event)
            model?.recordUsage(event)
            return text
        } catch {
            let event = UsageEvent.transcription(
                provider: speech.provider, streaming: false, model: speech.liveModel, billedModel: speech.fileModel,
                audioSeconds: seconds, latencyMs: Self.milliseconds(since: started), succeeded: false, at: started, fallback: fallback,
                failureCause: APIFailureCause.classify(error)
            )
            run.record(event)
            model?.recordUsage(event)
            throw error
        }
    }

    static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }

    /// Résultat d'une tâche s'il arrive dans le délai ; sinon nil, et la tâche continue.
    /// Échéance murale, hors du fil principal : une file déjà occupée ne doit pas
    /// repousser l'ouverture du flux au-delà des 150 ms (le micro est déjà ouvert).
    static func value<Value: Sendable>(of task: Task<Value, Never>, within seconds: Double) async -> Value? {
        let result = AsyncResult<Value?>()
        let priority = Task.currentPriority
        Task.detached(priority: priority) { result.resolve(.success(await task.value)) }
        Task.detached(priority: priority) {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            result.resolve(.success(nil))
        }
        return (try? await result.value()) ?? nil
    }

    func delete(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func startMeter() {
        meter?.stop()
        let ticker = FrameTicker { [weak self] elapsed in
            self?.pushLevel(elapsed: elapsed)
        }
        ticker.start { NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main }
        meter = ticker
    }

    private func stopMeter() {
        meter?.stop()
        meter = nil
    }

    /// Le spectre suit le micro à la cadence de l'écran : seulement pendant une écoute.
    var isMetering: Bool { meter != nil }

    private func pushLevel(elapsed: Double) {
        let bands = capture?.audio?.bands ?? []
        guard bands.count == SpectrumAnalyzer.bandCount else { return }
        let next = Self.smoothed(spectrum, toward: SpectrumAnalyzer.mirrored(bands), elapsed: elapsed)
        if next != spectrum { spectrum = next }
    }

    /// Montée rapide (~50 ms), retombée douce (~150 ms), quelle que soit la cadence de l'écran :
    /// les coefficients sont donnés pour une image à 60 Hz et ramenés au temps réellement écoulé.
    static func smoothed(_ previous: [Float], toward target: [Float], elapsed: Double = meterInterval) -> [Float] {
        let frames = Float(max(0, min(elapsed, 0.1)) * 60)
        let rise = 1 - pow(1 - Float(0.5), frames)
        let fall = 1 - pow(1 - Float(0.11), frames)
        return zip(previous, target).map { previous, target in
            let next = previous + (target - previous) * (target > previous ? rise : fall)
            return next < 0.002 ? 0 : next
        }
    }

    /// Mots ajoutés au dictionnaire, à confirmer discrètement.
    private(set) var learnedNotice: [String] = []
    /// Ajouts en attente, regroupés jusqu’à trois par notification.
    @ObservationIgnored private var learningQueue: [String] = []
    /// Premier terme du groupe affiché, utilisé pour savoir si une notification est ouverte.
    var learningOffer: String? { learningOfferedTerms.first }
    private(set) var learningOfferedTerms: [String] = []
    /// Nouvelle version à rappeler dès que la bulle se libère après une dictée.
    @ObservationIgnored private(set) var pendingUpdate: ReleaseInfo?
    /// Nouvelle version dont la bulle affiche le rappel.
    @ObservationIgnored private(set) var updateOffer: ReleaseInfo?
    /// Le message de la bulle rappelle une nouvelle version de Wispad (Voir, Ne plus me rappeler).
    private(set) var noticeOffersUpdate = false

    /// Message bref montré dans la bulle quand aucune dictée n'est en cours.
    var notice: String?
    /// Départ automatique du message bref, en pause au survol.
    let noticeTimer = MessageTimer()

    /// Coupe le son du Mac juste après le son de début, pour qu'il reste audible.
    private func muteOutputAfterCue(_ current: Capture) {
        guard let model, model.settings.muteWhileDictating else { return }
        Task { @MainActor [weak self] in
            if model.settings.soundsEnabled { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard let self, self.capture === current, current.listening, !self.outputMuted else { return }
            self.outputMuted = true
            model.dependencies.muteOutput(model.settings.muteWhileDictating, model.settings.muteMode)
        }
    }

    private func cue(_ sound: DictationCue) {
        guard model?.settings.soundsEnabled == true else { return }
        model?.dependencies.playCue(sound)
    }

    private func changed() {
        onChange?()
    }
}

private extension DictationPhase {
    var isCapturing: Bool {
        switch self {
        case .starting, .listening: return true
        case .idle, .finishing, .failure: return false
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }

    /// Une dictée se termine ou un message d'erreur est affiché.
    var isPending: Bool {
        switch self {
        case .finishing, .failure: return true
        case .idle, .starting, .listening: return false
        }
    }
}

// MARK: - Messages de la bulle

/// Messages de la bulle hors dictée : relais annoncé, mot appris à confirmer.
extension DictationCoordinator {
    static func learningMessage(_ term: String) -> String {
        String(localized: "« \(term) » ajouté au dictionnaire. Le garder ?")
    }

    func notifyLearned(_ terms: [String]) {
        let incoming = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var seen = Set((learningQueue + learningOfferedTerms).map { $0.lowercased() })
        let unique = incoming.filter { seen.insert($0.lowercased()).inserted }
        learnedNotice = unique
        learningQueue.append(contentsOf: unique)
        if phase == .idle, notice == nil {
            presentNextLearningOffer()
        }
    }

    /// Voir : les termes restent, leur confirmation est notée (origine inchangée), le message se ferme.
    func acceptLearning() {
        guard !learningOfferedTerms.isEmpty else { return }
        let terms = learningOfferedTerms
        learningOfferedTerms = []
        for term in terms { model?.confirmLearnedTerm(term) }
        Self.learningLog.notice("Gardés \(terms.count), refusés 0")
        clearNotice()
    }

    /// Annuler l’ajout : le groupe sort du dictionnaire et ne sera plus proposé.
    func declineLearning() {
        guard !learningOfferedTerms.isEmpty else { return }
        let terms = learningOfferedTerms
        learningOfferedTerms = []
        for term in terms { model?.refuseLearnedTerm(term) }
        Self.learningLog.notice("Gardés 0, refusés \(terms.count)")
        clearNotice()
    }

    /// Première bascule vers un relais pendant une panne : annoncée une fois, après le collage de cette dictée.
    func announceRelay(_ service: String, _ message: String, job: FinishJob) {
        guard announcedRelays.insert(service).inserted else { return }
        job.announcement = (service, message)
    }

    static func updateMessage(_ version: SemanticVersion) -> String {
        String(localized: "Wispad \(version.description) est disponible")
    }

    /// Rappel d'une nouvelle version : le temps de lire et de cliquer, en pause au survol.
    static let updateSeconds = 10.0

    /// Nouvelle version à rappeler. La bulle attend de se libérer après une dictée (ou un autre message) : on est
    /// alors devant le Mac et on la regarde. Jamais pendant une dictée, jamais au premier plan.
    func offerUpdate(_ release: ReleaseInfo) {
        guard updateOffer?.version != release.version else { return }
        pendingUpdate = release
    }

    /// « Voir » : la fenêtre s'ouvre sur les notes de version.
    func openUpdateOffer() {
        guard let release = updateOffer else { return }
        clearNotice()
        model?.showUpdate(release)
    }

    /// « Ne plus me rappeler » : le message part et cette version ne sera plus rappelée (elle reste proposée dans
    /// la barre latérale).
    func declineUpdateOffer() {
        guard updateOffer != nil else { return }
        clearNotice()
    }

    /// Message bref dans la bulle, hors dictée.
    func announce(_ message: String, relay: Bool, confirmsLearning: Bool = false, info: Bool = false,
                  offersUpdate: Bool = false, seconds: Double? = nil) {
        // Pendant une dictée, la bulle sert à la dictée : le message est ignoré.
        guard phase == .idle, let model else { return }
        noticeIsRelay = relay
        noticeIsInfo = info
        noticeConfirmsLearning = confirmsLearning
        noticeOffersUpdate = offersUpdate
        if !offersUpdate { updateOffer = nil }
        notice = message
        model.overlay.show()
        let duration = seconds ?? (confirmsLearning ? Self.learningSeconds : Self.noticeSeconds)
        noticeTimer.start(seconds: duration, paused: messagesHeld) { [weak self] in
            guard let self, self.notice == message else { return }
            self.dismissCurrentNotice()
        }
    }

    /// Réglages › Bulle et messages : un message bref, quelques secondes, à la place choisie pour ce rôle.
    func previewPlacement(_ role: OverlayRole) {
        guard phase == .idle, let model else { return }
        let message: String
        switch role {
        case .dictation: message = String(localized: "La bulle de dictée apparaîtra ici")
        case .alerts: message = String(localized: "Les alertes de collage apparaîtront ici")
        case .info: message = String(localized: "Les messages apparaîtront ici")
        }
        model.overlay.previewRole = role
        announce(message, relay: false, info: true, seconds: 3)
        model.overlay.moveToTarget()
    }

    /// Délai écoulé ou ✕ : les ajouts restent dans le dictionnaire.
    func dismissCurrentNotice() {
        guard notice != nil else { return }
        if noticeConfirmsLearning {
            let count = learningOfferedTerms.count
            learningOfferedTerms = []
            Self.learningLog.notice("Gardés \(count), refusés 0")
        }
        clearNotice()
    }

    /// Relais d'abord, puis la prochaine confirmation de mot, puis une nouvelle version, quand la bulle ne sert plus à
    /// dicter.
    @discardableResult
    private func presentIdleBubble() -> Bool {
        guard phase == .idle, notice == nil else { return false }
        if let message = pendingAnnouncement {
            pendingAnnouncement = nil
            announce(message, relay: true)
            return true
        }
        if presentNextLearningOffer() { return true }
        return presentUpdateOffer()
    }

    /// Rappel d'une nouvelle version, jamais pendant la configuration guidée. Une fois paru, il ne revient plus pour
    /// cette version, sauf s'il est interrompu par une dictée : il reparaît alors à la fin de celle-ci.
    @discardableResult
    private func presentUpdateOffer() -> Bool {
        guard phase == .idle, notice == nil, learningOffer == nil, let release = pendingUpdate,
              let model, model.onboarding == nil else { return false }
        pendingUpdate = nil
        announce(Self.updateMessage(release.version), relay: false, offersUpdate: true, seconds: Self.updateSeconds)
        updateOffer = release
        model.noteUpdateReminded(release.version)
        return true
    }

    @discardableResult
    private func presentNextLearningOffer() -> Bool {
        guard phase == .idle, notice == nil, learningOffer == nil, !learningQueue.isEmpty else { return false }
        let terms = Array(learningQueue.prefix(CorrectionLearner.maxTermsPerDictation))
        learningQueue.removeFirst(terms.count)
        learningOfferedTerms = terms
        let message = terms.count == 1 ? Self.learningMessage(terms[0]) : String(localized: "\(terms.count) ajouts au dictionnaire")
        announce(message, relay: false, confirmsLearning: true, seconds: Self.learningSeconds)
        return true
    }

    private func clearNotice() {
        noticeTimer.cancel()
        model?.overlay.previewRole = nil
        if phase != .idle, !learningOfferedTerms.isEmpty {
            learningQueue.insert(contentsOf: learningOfferedTerms, at: 0)
            learningOfferedTerms = []
        }
        // Rappel coupé par une dictée : il reparaît à la fin de celle-ci (sauf si une version plus récente l'a remplacé).
        if phase != .idle, let release = updateOffer, pendingUpdate == nil {
            pendingUpdate = release
        }
        updateOffer = nil
        let hadNotice = notice != nil
        notice = nil
        noticeIsRelay = false
        noticeIsInfo = false
        noticeConfirmsLearning = false
        noticeOffersUpdate = false
        guard phase == .idle else { return }
        if presentIdleBubble() { return }
        if hadNotice { model?.overlay.hide() }
    }
}
