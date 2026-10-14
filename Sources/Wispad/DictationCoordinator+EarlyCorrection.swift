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
        // Hors connexion, rien n'est préparé : l'appel échouerait et compterait un échec du service.
        guard let model, model.correctionReachable, isCapturing(current), !current.correctionClaimed,
              let speech = current.speech,
              current.earlyCorrections.count < Self.earlyCorrectionLimit else { return }
        let text = FranglaisNormalizer.normalize(heard.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, text != current.earlyText, model.commandSelection(for: text, context: current.context) == nil else { return }
        Task { @MainActor [weak self, weak current] in
            try? await Task.sleep(nanoseconds: UInt64(Self.earlyCorrectionPause * 1_000_000_000))
            // La connexion a pu se perdre pendant la pause : même règle qu'au moment de la pause.
            guard let self, let current, self.isCapturing(current), !current.correctionClaimed,
                  current.earlyCorrections.count < Self.earlyCorrectionLimit, model.correctionReachable else { return }
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

    /// À l'arrêt, ce que le flux a déjà affiché part aussitôt à la correction, sans attendre son texte final
    /// (0,3 à 0,5 s sur les dictées courtes, mesuré le 13 octobre 2026). Si le texte final dit la même chose
    /// (`TranscriptEquivalence`), la fin de dictée prend cette correction ; sinon elle est seulement comptée.
    /// Hors de la limite des corrections préparées pendant l'écoute : c'est celle qui sert le plus souvent.
    /// Hors connexion, rien n'est lancé : la fin de dictée corrigera si la connexion est revenue.
    func prepareCorrectionAtRelease(_ current: Capture) {
        guard let model, model.correctionReachable, !current.cancelled, !current.correctionClaimed,
              let speech = current.speech else { return }
        let text = FranglaisNormalizer.normalize(current.latestHeard.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, model.commandSelection(for: text, context: current.context) == nil else { return }
        // Déjà en préparation sur ce texte (pause juste avant l'arrêt) : rien de plus à lancer.
        if let ready = current.earlyReady, TranscriptEquivalence.equivalent(ready.text, text) { return }
        current.earlyText = text
        let task = Task { @MainActor in
            let request = await self.makeCorrectionRequest(
                transcript: text, context: current.context, field: current.field, window: current.window, model: model
            )
            let began = Date()
            let outcome = await model.dependencies.clean(text, request, speech, true)
            return PreparedCorrection(outcome: outcome, milliseconds: Self.milliseconds(since: began))
        }
        let ledger = CorrectionLedger(task: task)
        current.earlyCorrections.append(ledger)
        current.earlyReady = (text, ledger)
        current.run.trace.earlyCorrections = current.earlyCorrections.count
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

    /// Vrai si `ledger` termine avant `other` (ou est déjà prête). Attendre l'une n'annule jamais l'autre.
    static func finishesFirst(_ ledger: CorrectionLedger, before other: CorrectionLedger) async -> Bool {
        if ledger.ready != nil { return true }
        let winner = AsyncResult<Bool>()
        Task { @MainActor in _ = await ledger.task.value; winner.resolve(.success(true)) }
        Task { @MainActor in _ = await other.task.value; winner.resolve(.success(false)) }
        return (try? await winner.value()) ?? false
    }

    /// Le fichier ne change qu'un ou deux mots du flux : la correction du flux (déjà lancée) les reçoit
    /// (`CorrectionPatch`). nil si l'écart ne s'y prête pas ou si cette correction a échoué ; la correction
    /// complète du fichier prend alors le relais. La correction du flux doit déjà être prête : aucun délai
    /// n'est ajouté à la correction du texte retenu.
    func patchPreparedCorrection(
        _ ledger: CorrectionLedger, stream: String, file: String, current: Capture, model: AppModel
    ) async -> PreparedCorrection? {
        // Ne pas attendre une correction obsolète avant de lancer celle du texte retenu.
        // Si elle est déjà prête, le report évite toujours un appel supplémentaire.
        guard let prepared = ledger.ready, CorrectionPatch.isCandidate(stream: stream, file: file) else { return nil }
        _ = await ledger.account(model: model, run: current.run)
        guard prepared.outcome.usage?.succeeded == true,
              let text = CorrectionPatch.apply(
                  corrected: prepared.outcome.text, stream: stream, file: file, protected: model.dictionary.map(\.term)
              ) else { return nil }
        var patched = prepared
        // Les mots du fichier arrivent tels qu'entendus (« mètres carrés », « quatorze heures ») : ils reprennent le
        // format des dates, des heures et des nombres, comme le reste du texte corrigé.
        let english = CorrectionPrompt.language(for: CorrectionRequest(transcript: file, language: model.settings.language)) == .english
        let dated = DateTimeWriter.apply(text, format: model.settings.dateFormat, english: english)
        patched.outcome.text = NumberWriter.apply(dated, format: model.settings.numberFormat, english: english)
        return patched
    }
}
