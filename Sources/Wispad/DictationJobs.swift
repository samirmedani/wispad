import AppKit
import Foundation
import os
import WispadCore

// Étapes d'une dictée suivies par le coordinateur : l'écoute, puis sa fin en arrière-plan.

/// Dictée en cours d'écoute : micro, audio gardé pour le flux en direct, contexte de l'app.
@MainActor
final class Capture {
    let mode: ListenMode
    let context: DictationContext
    let field: Task<FieldSnapshot?, Never>
    let pcm = PCMRelay()
    let marks: LatencyMarks
    let run: DictationTraceRecorder
    var listening = false
    var cancelled = false
    var didSignalReady = false
    var audio: (any AudioRecording)?
    var audioURL: URL?
    var speech: SpeechRequest?
    var session: (any SpeechStreaming)?
    var startTask: Task<Bool, Never>?
    /// Flux en direct branché (true), en échec (false), ou pas encore fixé (nil).
    var streamStarted: Bool?
    var streamAttemptedAt: Date?
    var streamUsageRecorded = false
    var voiceFallback: APIFallback?
    /// Conversation visible dans la fenêtre, lue pendant l'écoute pour la seule correction.
    var window: Task<String?, Never>?
    /// Dernier texte affiché par le flux en direct.
    var latestHeard = ""
    /// Corrections lancées pendant l'écoute, à chaque pause : toutes sont comptées, une seule peut servir.
    var earlyCorrections: [CorrectionLedger] = []
    /// Texte (normalisé) de la correction en préparation ou prête.
    var earlyText: String?
    /// La correction préparée la plus récente, avec le texte exact qu'elle corrige.
    var earlyReady: (text: String, ledger: CorrectionLedger)?
    /// La fin de dictée a choisi sa correction : plus rien ne se prépare.
    var correctionClaimed = false

    init(mode: ListenMode, context: DictationContext, field: Task<FieldSnapshot?, Never>, marks: LatencyMarks, run: DictationTraceRecorder) {
        self.mode = mode
        self.context = context
        self.field = field
        self.marks = marks
        self.run = run
    }
}

/// Dictée terminée côté micro : transcription, correction et collage, en arrière-plan.
@MainActor
final class FinishJob {
    let capture: Capture
    let url: URL?
    let duration: Double
    /// Collage de la dictée précédente : attendu avant de coller celle-ci.
    let previous: AsyncResult<Void>?
    let pasted = AsyncResult<Void>()
    var cancelled = false
    var task: Task<Void, Never>?
    /// Fichier et correction spéculative : annulés avec la dictée, leur coût reste compté.
    var cancelSideWork: () -> Void = {}
    /// Texte collé (ou envoyé au collage).
    var delivered = false
    /// Première bascule de la panne vers un relais, à annoncer une fois ce texte collé.
    var announcement: (service: String, message: String)?

    init(capture: Capture, url: URL?, duration: Double, previous: AsyncResult<Void>?) {
        self.capture = capture
        self.url = url
        self.duration = duration
        self.previous = previous
    }
}

struct FileAttempt: Sendable {
    var text: String
    var started: Date
    var latencyMs: Int
    var failed: Bool
    /// Faux si l'appel a été annulé avant d'être envoyé : rien à facturer.
    var called: Bool
}

struct PreparedCorrection: Sendable {
    var outcome: CleanupOutcome
    var milliseconds: Int
}

/// Un appel fichier déjà lancé. `account` ne le compte qu'une fois, même s'il finit après la dictée.
@MainActor
final class FileLedger {
    let task: Task<FileAttempt, Never>
    private var recorded = false
    private let speech: SpeechRequest
    private let seconds: Double
    private let run: DictationTraceRecorder
    private let model: AppModel

    init(task: Task<FileAttempt, Never>, speech: SpeechRequest, seconds: Double, run: DictationTraceRecorder, model: AppModel) {
        self.task = task
        self.speech = speech
        self.seconds = seconds
        self.run = run
        self.model = model
    }

    func account() async {
        let attempt = await task.value
        guard attempt.called, !recorded else { return }
        recorded = true
        let event = UsageEvent.transcription(
            provider: speech.provider, streaming: false, model: speech.liveModel, billedModel: speech.fileModel,
            audioSeconds: seconds, latencyMs: attempt.latencyMs, succeeded: !attempt.failed,
            at: attempt.started
        )
        run.adopt(event, model: model)
        model.recordUsage(event)
        model.health.record(ServiceHealth.voice(speech.provider), succeeded: !attempt.failed)
    }
}

/// Correction lancée sur le flux avant de savoir si le fichier dira la même chose.
@MainActor
final class CorrectionLedger {
    let task: Task<PreparedCorrection, Never>
    private var recorded = false

    init(task: Task<PreparedCorrection, Never>) { self.task = task }

    func account(model: AppModel, run: DictationTraceRecorder) async -> PreparedCorrection {
        let prepared = await task.value
        if !recorded {
            recorded = true
            for usage in prepared.outcome.failedUsages { run.adopt(usage, model: model) }
            if let usage = prepared.outcome.usage { run.adopt(usage, model: model) }
            model.recordCleanup(prepared.outcome)
        }
        return prepared
    }
}

struct ShownFailure {
    let id = UUID()
    var message: String
    var text: String?
    /// Dictée de l'historique dont le texte est proposé : son statut suit un nouveau collage réussi.
    var recordID: String?
    /// Confirmation « Copié » après un clic sur Copier.
    var copied = false
}
