import AppKit
import Foundation
import WispadCore

protocol AudioRecording: AnyObject, Sendable {
    var onPCM: (@Sendable (Data) -> Void)? { get set }
    /// L'écoute en cours s'est arrêtée sans pouvoir repartir (micro disparu sans autre micro, moteur refusé) :
    /// plus aucun audio n'arrivera. Appelé une fois, hors du fil principal.
    var onInterruption: (@Sendable () -> Void)? { get set }
    /// Niveaux par bande de fréquence (grave → aigu), pour l'overlay.
    var bands: [Float] { get }
    /// Micro choisi (identifiant CoreAudio) pour la prochaine écoute ; nil : celui du système.
    var inputDeviceUID: String? { get set }
    func start(directory: URL) async throws -> URL
    func stop() -> (url: URL?, duration: Double)
    /// Écoute en cours mais muette : redémarre le micro sur un moteur neuf, dans le même fichier.
    func restart() async throws
    /// Démarrage ou redémarrage trop long : la dictée ne l'attend plus. Ce qu'il a ouvert pour elle se referme
    /// seul dès qu'il rend la main, sans `stop()` à attendre sur le fil principal.
    func abandonStart()
}

extension AudioRecording {
    /// Un enregistreur sans moteur à relancer (tests) : rien à faire.
    func restart() async throws {}
    func abandonStart() {}

    /// Un enregistreur qui ne s'interrompt jamais seul (tests) : rien à signaler.
    var onInterruption: (@Sendable () -> Void)? {
        get { nil }
        set {}
    }

    /// Un enregistreur qui ne choisit pas son micro (tests) : toujours celui du système.
    var inputDeviceUID: String? {
        get { nil }
        set {}
    }
}

protocol SpeechStreaming: AnyObject, Sendable {
    var onPartial: (@Sendable (String) -> Void)? { get set }
    /// Tout ce qui a été dit jusqu'ici est transcrit en final : la parole vient de marquer une pause.
    var onSettled: (@Sendable (String) -> Void)? { get set }
    func start() async throws
    func send(_ data: Data)
    func finish() async throws -> StreamFinish
    func cancel()
}

extension SpeechStreaming {
    /// Un flux qui ne signale pas ses pauses : aucune correction n'est préparée pendant l'écoute.
    var onSettled: (@Sendable (String) -> Void)? {
        get { nil }
        set {}
    }
}

extension AudioCapture: AudioRecording {}
extension LiveSpeechSession: SpeechStreaming {}

/// System boundaries are injectable so regression tests never open the microphone,
/// contact an API, use real credentials or write into another application.
@MainActor
struct AppDependencies {
    /// Fichier de l'app par défaut, ou coffre de secrets s'il est configuré (voir APIKeys).
    var keyStore: KeyStoreKind = APIKeys.kind
    var loadKey: (String) -> String? = { APIKeys.cached($0) }
    var saveKey: (String, String) async -> Bool = { await APIKeys.save($0, $1) }
    var deleteKey: (String) async -> Bool = { await APIKeys.delete($0) }
    var refreshKeys: () async -> Bool = { await APIKeys.refresh() }
    var validateKey: (URLRequest) async throws -> Int = { request in
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
    var requestMicrophone: () async -> Bool = { await PermissionCenter.requestMicrophone() }
    /// Accès au micro, relu sans rien demander pendant l'écoute : retiré dans Réglages Système, la dictée s'arrête.
    /// Lu hors du fil principal : la question à macOS prend une dizaine de millisecondes.
    var microphoneAuthorized: @Sendable () -> Bool = { PermissionCenter.microphoneAuthorized() }
    /// Autorisations et ouverture à la connexion affichées, lues sans rien demander, sur place : au lancement, et
    /// juste après une action dont l'écran ou le diagnostic dépend aussitôt.
    var permissions: () -> PermissionReading = { PermissionReading.read() }
    /// Les mêmes, lues sans retenir le fil principal (retour dans Wispad, fenêtre ou Réglages qui s'ouvrent) : le micro
    /// et la surveillance des entrées sont chacun une question au démon des autorisations de macOS (une dizaine de
    /// millisecondes), posée sur la file des autorisations.
    var permissionsOffMain: @Sendable () async -> PermissionReading = { await PermissionReads.offMain { PermissionReading.read() } }
    /// Ouverture à la connexion (`SMAppService`) : jamais touchée par les tests.
    var launchAtLogin: () -> Bool = { LoginItemController.isEnabled }
    var setLaunchAtLogin: (Bool) throws -> Void = { try LoginItemController.setEnabled($0) }
    /// App au premier plan tout de suite, champ actif lu en parallèle : le micro n'attend pas une app lente.
    var captureContext: () -> (DictationContext, Task<FieldSnapshot?, Never>) = { ContextProbe.begin() }
    /// App au premier plan, sans lire son champ : cible de « Coller la dernière dictée ».
    var frontmostApp: () -> DictationContext = { ContextProbe.frontmost() }
    /// Conversation visible dans la fenêtre de l'app où l'on dicte, lue hors du fil principal (300 ms au plus).
    /// Elle reste en mémoire le temps de la correction : jamais journalisée ni enregistrée.
    var readWindow: (pid_t) async -> String? = { pid in await WindowTextProbe.context(pid: pid) }
    var makeCapture: () -> any AudioRecording = { AudioCapture.shared }
    var makeSession: (SpeechRequest) -> any SpeechStreaming = { LiveSpeechSession(request: $0) }
    /// Transcription d'un fichier chez le fournisseur.
    var transcribe: (URL, SpeechRequest) async throws -> String = { try await BatchTranscriber.transcribe(fileURL: $0, request: $1) }
    /// Une route vers internet existe (NWPathMonitor).
    var isOnline: () -> Bool = { NetworkStatus.shared.isOnline }
    var clean: (String, CorrectionRequest, SpeechRequest, Bool) async -> CleanupOutcome = {
        await TextCleaner.clean(transcript: $0, request: $1, speech: $2, enabled: $3)
    }
    /// Contrôles d'un service mis de côté : complétion d'un jeton chez DeepSeek, liste des modèles (gratuite) chez
    /// un fournisseur de voix.
    var probeDeepSeek: (String) async -> UsageEvent? = { await HealthProbe.deepSeek(key: $0) }
    var probeVoice: (ProviderID, String) async -> Bool = { await HealthProbe.voice($0, key: $1) }
    var playCue: (DictationCue) -> Void = { SoundCues.play($0) }
    /// Son du Mac coupé pendant la dictée, puis rétabli. Simulé dans les tests : jamais de vrai son touché.
    var muteOutput: (Bool, OutputMuteMode) -> Void = { OutputMuter.mute(enabled: $0, mode: $1) }
    var restoreOutput: () -> Void = { OutputMuter.restore() }
    var watchCorrections: (String, pid_t, [String], @escaping @MainActor ([CorrectionLearner.Candidate]) -> Void) -> Void = {
        CorrectionWatcher.shared.watch(inserted: $0, pid: $1, known: $2, corrected: $3)
    }
    /// Le modèle de correction juge si un mot corrigé mérite le dictionnaire.
    var judgeTerms: ([CorrectionLearner.Candidate], String, SpeechRequest) async -> TermJudgement = {
        await TermJudge.judge($0, dictated: $1, speech: $2)
    }
    /// Copie automatique du texte quand le collage échoue. Remplacée dans les tests : jamais le vrai presse-papiers.
    var copyText: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Le dernier callback signale l'envoi de ⌘V, avant la confirmation d'accessibilité.
    var insert: (String, DictationContext, @escaping @MainActor () -> Bool, @escaping @MainActor () -> Void) async -> InsertionStatus = {
        await TextInserter.insert($0, context: $1, shouldProceed: $2, didSendPaste: $3)
    }
    /// « Coller la dernière dictée » : attend que les touches du raccourci soient relâchées avant ⌘V.
    /// Raccourcis déclarés par macOS (Réglages Système › Clavier › Raccourcis), pour refuser une combinaison prise.
    var systemShortcuts: () -> [PasteShortcut] = { SystemShortcuts.enabled() }
}

enum DictationCue: Hashable {
    case start
    case stop
    case cancel
}
