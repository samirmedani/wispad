import Foundation
import WispadCore

/// Correction préparée pendant l'écoute. À chaque pause de la parole, le flux a tout transcrit en final : ce texte
/// part à la correction sans attendre l'arrêt. Si l'on s'arrête sans rien ajouter, elle est déjà prête (ou en cours)
/// et le texte se colle aussitôt. Si la parole reprend, elle est comptée et la suivante la remplace.
extension DictationCoordinator {
    /// Pause minimale après le segment final : une parole qui reprend aussitôt n'en était pas une.
    static let earlyCorrectionPause = 0.25
    /// Au plus quelques corrections préparées par dictée : une longue dictée ne multiplie pas les appels.
    static let earlyCorrectionLimit = 4
    /// Attente maximale de la correction du flux pour y reporter les mots du fichier (une correction complète
    /// prend environ 0,9 s).
    static let patchWaitLimit = 0.3

    func wireEarlyCorrection(_ live: any SpeechStreaming, for current: Capture) {
        live.onPartial = { [weak current] text in
            Task { @MainActor in current?.latestHeard = text }
        }
        live.onSettled = { [weak self, weak current] text in
            Task { @MainActor in
                guard let self, let current else { return }
                current.latestHeard = text
                self.scheduleEarlyCorrection(text, for: current)
            }
        }
    }

    private func scheduleEarlyCorrection(_ heard: String, for current: Capture) {
        guard let model, model.settings.cleanupEnabled, isCapturing(current), !current.correctionClaimed,
              let speech = current.speech,
              current.earlyCorrections.count < Self.earlyCorrectionLimit else { return }
        let text = FranglaisNormalizer.normalize(heard.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, text != current.earlyText, model.commandSelection(for: text, context: current.context) == nil else { return }
        Task { @MainActor [weak self, weak current] in
            try? await Task.sleep(nanoseconds: UInt64(Self.earlyCorrectionPause * 1_000_000_000))
            guard let self, let current, self.isCapturing(current), !current.correctionClaimed,
                  current.earlyCorrections.count < Self.earlyCorrectionLimit else { return }
            // La parole a repris pendant la pause : on attend la prochaine.
            guard current.latestHeard.trimmingCharacters(in: .whitespacesAndNewlines) == heard.trimmingCharacters(in: .whitespacesAndNewlines),
                  text != current.earlyText else { return }
            current.earlyText = text
            let request = await self.makeCorrectionRequest(
                transcript: text, context: current.context, field: current.field, window: current.window, model: model
            )
            // L'arrêt a pu arriver pendant la lecture du contexte : la fin de dictée a déjà choisi.
            guard !current.cancelled, !current.correctionClaimed, current.earlyText == text else { return }
            let task = Task { @MainActor in
                let began = Date()
                let outcome = await model.dependencies.clean(text, request, speech, true)
                return PreparedCorrection(outcome: outcome, milliseconds: Self.milliseconds(since: began))
            }
            let ledger = CorrectionLedger(task: task)
            current.earlyCorrections.append(ledger)
            current.earlyReady = (text, ledger)
            current.run.trace.earlyCorrections = current.earlyCorrections.count
        }
    }

    /// La fin de dictée prend la correction préparée sur ce même texte, s'il y en a une ; plus rien ne se
    /// prépare ensuite. « Même texte » au sens de `TranscriptEquivalence` : la fin du flux réécrit souvent la
    /// ponctuation ou la casse du dernier segment, ce que la correction refait de toute façon (mesuré du 9 au
    /// 11 octobre : 7 corrections préparées servies sur 98 avec une égalité stricte). Les autres restent comptées.
    func claimEarlyCorrection(for text: String, current: Capture, model: AppModel) -> CorrectionLedger? {
        current.correctionClaimed = true
        let ready = current.earlyReady
        let used = ready.flatMap { TranscriptEquivalence.equivalent($0.text, text) ? $0.ledger : nil }
        // Vrai seulement quand le texte collé en sort (le fichier peut encore dire autre chose).
        if !current.earlyCorrections.isEmpty, current.run.trace.earlyCorrectionUsed == nil {
            current.run.trace.earlyCorrectionUsed = false
        }
        accountEarlyCorrections(current, model: model, except: used)
        return used
    }

    /// Compte chaque correction préparée, une seule fois, même si elle finit après le collage.
    func accountEarlyCorrections(_ current: Capture, model: AppModel, except used: CorrectionLedger? = nil, cancel: Bool = false) {
        for ledger in current.earlyCorrections where ledger !== used {
            if cancel { ledger.task.cancel() }
            Task { @MainActor in _ = await ledger.account(model: model, run: current.run) }
        }
    }

    /// Le fichier ne change qu'un ou deux mots du flux : la correction du flux (déjà lancée) les reçoit
    /// (`CorrectionPatch`). nil si l'écart ne s'y prête pas ou si cette correction a échoué ; la correction
    /// complète du fichier prend alors le relais. La correction du flux est partie avant le fichier : elle est
    /// d'ordinaire prête ; plus lente que `patchWaitLimit`, on ne l'attend pas.
    func patchPreparedCorrection(
        _ ledger: CorrectionLedger, stream: String, file: String, current: Capture, model: AppModel
    ) async -> PreparedCorrection? {
        guard CorrectionPatch.isCandidate(stream: stream, file: file),
              await Self.value(of: ledger.task, within: Self.patchWaitLimit) != nil else { return nil }
        let prepared = await ledger.account(model: model, run: current.run)
        guard prepared.outcome.usage?.succeeded == true,
              let text = CorrectionPatch.apply(
                  corrected: prepared.outcome.text, stream: stream, file: file, protected: model.dictionary.map(\.term)
              ) else { return nil }
        var patched = prepared
        patched.outcome.text = text
        return patched
    }
}
