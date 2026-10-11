import Foundation
import WispadCore

/// Un collecteur par opération : les dictées qui se chevauchent ne partagent jamais leurs appels.
@MainActor
final class DictationTraceRecorder {
    var trace: DictationTrace
    private let marks: LatencyMarks?
    private let began: Int
    private var completed = false

    init(origin: DictationOrigin, pressedAt: Int? = nil, marks: LatencyMarks? = nil) {
        trace = DictationTrace(origin: origin)
        self.marks = marks
        began = pressedAt ?? KeyboardTap.now()
    }

    func record(_ event: UsageEvent) {
        guard !trace.calls.contains(where: { $0.id == event.id }) else { return }
        trace.calls.append(DictationAPICall(event))
    }

    /// Comme `record`, et si la trace est déjà écrite, l'appel tardif (fichier hors délai) y est ajouté.
    func adopt(_ event: UsageEvent, model: AppModel) {
        let known = trace.calls.contains { $0.id == event.id }
        record(event)
        guard completed, !known else { return }
        if model.persist("appel ajouté au détail", { try model.store.appendTraceCalls(id: trace.id, calls: [DictationAPICall(event)]) }) {
            model.traceRevision += 1
        }
    }

    func complete(_ outcome: DictationOutcome, model: AppModel) {
        guard !completed else { return }
        completed = true
        trace.outcome = outcome
        if let marks {
            trace.timings.microphoneMs = elapsed(to: marks.microphone)
            trace.timings.firstAudioMs = elapsed(to: marks.firstAudio)
            trace.timings.streamReadyMs = elapsed(to: marks.stream)
            if let released = marks.released {
                trace.timings.afterReleaseMs = max(0, (marks.pasted ?? KeyboardTap.now()) - released)
            }
        }
        if model.persist("détail d'une dictée", { try model.store.saveTrace(trace) }) { model.traceRevision += 1 }
        model.noteCompletion(trace)
    }

    private func elapsed(to instant: Int?) -> Int? {
        instant.map { max(0, $0 - began) }
    }
}

extension DictationOutcome {
    init(_ status: InsertionStatus) {
        switch status {
        case .inserted: self = .inserted
        case .pasteSent: self = .pasteSent
        case .pending: self = .pending
        case .noTarget: self = .noTarget
        case .refusedSecure: self = .refusedSecure
        case .failed: self = .insertionFailed
        case .transcriptionFailed: self = .transcriptionFailed
        case .cancelled: self = .cancelled
        }
    }
}
