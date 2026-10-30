import AppKit
import Foundation
import WispadCore

/// Une correction peut commencer au relâchement, en parallèle de la fin des transcriptions.
/// Les pauses pendant la parole ne lancent aucun appel : leurs textes sont encore incomplets.
extension DictationCoordinator {
    func wireEarlyCorrection(_ live: any SpeechStreaming, for current: Capture) {
        let heard: @Sendable (String) -> Void = { [weak current] text in
            Task { @MainActor in current?.latestHeard = text }
        }
        live.onPartial = heard
        live.onSettled = heard
    }

    /// À l'arrêt, ce que le flux a déjà affiché part aussitôt à la correction, sans attendre son texte final
    /// (0,3 à 0,5 s sur les dictées courtes, mesuré le 13 octobre 2026). Si le texte final dit la même chose
    /// (`TranscriptEquivalence`), la fin de dictée prend cette correction ; sinon elle est seulement comptée.
    /// Une seule préparation par dictée ; si le texte retenu diffère, lui seul aura une autre correction.
    /// Hors connexion, rien n'est lancé : la fin de dictée corrigera si la connexion est revenue.
    func prepareCorrectionAtRelease(_ current: Capture) {
        guard let model, model.correctionReachable, !current.cancelled, !current.correctionClaimed,
              current.earlyReady == nil, let speech = current.speech else { return }
        let text = FranglaisNormalizer.normalize(current.latestHeard.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, model.commandSelection(for: text, context: current.context) == nil else { return }
        let task = Task { @MainActor in
            let request = await self.makeCorrectionRequest(
                transcript: text, context: current.context, field: current.field, window: current.window, model: model
            )
            guard !Task.isCancelled, !current.cancelled, model.correctionReachable else {
                return PreparedCorrection(outcome: CleanupOutcome(text: text), milliseconds: 0)
            }
            let began = Date()
            let outcome = await model.dependencies.clean(text, request, speech, true)
            return PreparedCorrection(outcome: outcome, milliseconds: Self.milliseconds(since: began))
        }
        let ledger = CorrectionLedger(task: task)
        current.earlyCorrections.append(ledger)
        current.earlyReady = (text, ledger)
        current.run.trace.earlyCorrections = current.earlyCorrections.count
    }

    /// La fin de dictée prend la préparation si son texte correspond au texte retenu, au sens de
    /// `TranscriptEquivalence`. Une préparation sur un autre texte reste comptée, sans être réutilisée à tort.
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

    /// Mot connu pour le report du fichier (`CorrectionPatch`) : terme du dictionnaire ou du vocabulaire technique, ou
    /// mot que l'orthographe de macOS connaît dans la langue de la dictée. nil si macOS n'a pas cette langue : le
    /// report ne vérifie alors que les chiffres.
    static func knownWord(for file: String, language: DictationLanguage, terms: [String]) -> ((String) -> Bool)? {
        let spoken = language == .auto ? TranscriptLanguage.guess(file) : language
        let code = spoken == .english ? "en" : "fr"
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains(where: { $0.hasPrefix(code) }) else { return nil }
        let known = Set((terms + TechVocabulary.correction).flatMap { $0.split(whereSeparator: \.isWhitespace) }.map { $0.lowercased() })
        return { word in
            known.contains(word.lowercased())
                || checker.checkSpelling(of: word, startingAt: 0, language: code, wrap: false, inSpellDocumentWithTag: 0,
                                         wordCount: nil).location == NSNotFound
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
                  corrected: prepared.outcome.text, stream: stream, file: file, protected: model.dictionary.map(\.term),
                  knownWord: Self.knownWord(for: file, language: model.settings.language, terms: model.dictionary.map(\.term))
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
