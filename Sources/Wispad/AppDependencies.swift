import AppKit
import Foundation
import WispadCore

protocol AudioRecording: AnyObject, Sendable {
    var onPCM: (@Sendable (Data) -> Void)? { get set }
    /// Niveaux par bande de fréquence (grave → aigu), pour l'overlay.
    var bands: [Float] { get }
    func start(directory: URL) async throws -> URL
    func stop() -> (url: URL?, duration: Double)
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
    /// App au premier plan tout de suite, champ actif lu en parallèle : le micro n'attend pas une app lente.
    var captureContext: () -> (DictationContext, Task<FieldSnapshot?, Never>) = { ContextProbe.begin() }
    /// Conversation visible dans la fenêtre de l'app où l'on dicte, lue hors du fil principal (300 ms au plus).
    /// Elle reste en mémoire le temps de la correction : jamais journalisée ni enregistrée.
    var readWindow: (pid_t) async -> String? = { pid in
        await Task.detached(priority: .userInitiated) { WindowTextProbe.read(pid: pid).context }.value
    }
    var makeCapture: () -> any AudioRecording = { AudioCapture.shared }
    var makeSession: (SpeechRequest) -> any SpeechStreaming = { LiveSpeechSession(request: $0) }
    /// Transcription d'un fichier chez le fournisseur.
    var transcribe: (URL, SpeechRequest) async throws -> String = { try await BatchTranscriber.transcribe(fileURL: $0, request: $1) }
    /// Une route vers internet existe (NWPathMonitor).
    var isOnline: () -> Bool = { NetworkStatus.shared.isOnline }
    var clean: (String, CorrectionRequest, SpeechRequest, Bool) async -> CleanupOutcome = {
        await TextCleaner.clean(transcript: $0, request: $1, speech: $2, enabled: $3)
    }
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
    var insert: (String, DictationContext, @escaping @MainActor () -> Bool) async -> InsertionStatus = {
        await TextInserter.insert($0, context: $1, shouldProceed: $2)
    }
}

enum DictationCue: Hashable {
    case start
    case stop
    case cancel
}
