import AppKit
import Foundation
import WispadCore

/// Une seule anticipation à une pause ; une préparation à l'arrêt si le texte a changé.
/// Reprendre la parole ne lance jamais une série de corrections aux pauses suivantes.
extension DictationCoordinator {
    static let earlyCorrectionPause: TimeInterval = 0.25

    func wireEarlyCorrection(_ live: any SpeechStreaming, for current: Capture) {
        live.onPartial = { [weak current] text in
            Task { @MainActor in
                guard let current else { return }
                Self.updateHeard(text, for: current)
            }
        }
        live.onSettled = { [weak self, weak current] text in
            Task { @MainActor in
                guard let self, let current else { return }
                Self.updateHeard(text, for: current)
                current.latestSettledHeard = text
                self.scheduleEarlyCorrection(text, for: current)
            }
        }
    }

    private static func updateHeard(_ text: String, for current: Capture) {
        if current.latestHeard != text {
            current.earlyPauseTask?.cancel()
            current.earlyPauseTask = nil
        }
        current.latestHeard = text
    }

    private func scheduleEarlyCorrection(_ heard: String, for current: Capture) {
        guard let model, model.correctionReachable, isCapturing(current), !current.correctionClaimed,
              current.earlyReady == nil, current.earlyPauseTask == nil,
              !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        current.earlyPauseTask = Task { @MainActor [weak self, weak current] in
            do { try await Task.sleep(for: .seconds(Self.earlyCorrectionPause)) } catch { return }
            guard !Task.isCancelled, let self, let current, self.isCapturing(current),
                  current.latestHeard == heard else { return }
            // L'arrêt ou un nouveau mot ne doit plus annuler la tâche réseau réservée ci-dessous.
            current.earlyPauseTask = nil
            self.prepareCorrection(current, heard: heard)
        }
    }

    /// Une seule anticipation à une pause ; une autre au relâchement uniquement si le texte a changé.
    /// Chaque créneau est réservé avant toute lecture asynchrone du contexte.
    private func prepareCorrection(_ current: Capture, heard: String, atRelease: Bool = false) {
        guard let model, model.correctionReachable, !current.cancelled, !current.correctionClaimed,
              current.earlyCorrections.count < (atRelease ? 2 : 1), let speech = current.speech else { return }
        let text = FranglaisNormalizer.normalize(heard.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, model.commandSelection(for: text, context: current.context) == nil,
              !current.earlyCorrections.contains(where: { TranscriptEquivalence.equivalent($0.text, text) }) else { return }
        let task = Task { @MainActor in
            // À l'arrêt, la dernière phrase de la seconde écoute arrive pendant la lecture du contexte.
            let local = atRelease ? await current.localHearing?.finalText(within: Self.localHearingWait)
                                  : current.localHearing?.text
            let request = await self.makeCorrectionRequest(
                transcript: text, context: current.context, field: current.field, window: current.window, model: model,
                local: local
            )
            current.run.trace.localPassages = max(current.run.trace.localPassages ?? 0, request.localDivergences.count)
            guard !Task.isCancelled, !current.cancelled, model.correctionReachable else {
                return PreparedCorrection(outcome: CleanupOutcome(text: text), milliseconds: 0)
            }
            let began = Date()
            let outcome = await model.dependencies.clean(text, request, speech, true)
            return PreparedCorrection(outcome: outcome, milliseconds: Self.milliseconds(since: began))
        }
        let ledger = CorrectionLedger(task: task)
        current.earlyCorrections.append(EarlyPreparation(text: text, ledger: ledger))
        current.run.trace.earlyCorrections = current.earlyCorrections.count
    }

    /// Retrouve une préparation du même texte ou prépare le texte de l'arrêt en parallèle des transcriptions.
    /// Une correction définitive ne s'ajoutera que si le fichier apporte encore un autre texte.
    func prepareCorrectionAtRelease(_ current: Capture) {
        current.earlyPauseTask?.cancel()
        current.earlyPauseTask = nil
        if model?.settings.verifyWithFile == true {
            let heard = current.latestHeard.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalized = !current.latestSettledHeard.isEmpty
                && TranscriptEquivalence.equivalent(heard, current.latestSettledHeard)
            let punctuated = heard.last.map { ".!?".contains($0) } == true
            // Simple indice de préparation, jamais une raison de contourner la vérification audio.
            guard finalized || punctuated else { return }
        }
        let previous = current.earlyCorrections.count
        prepareCorrection(current, heard: current.latestHeard, atRelease: true)
        current.preparedAtRelease = current.earlyCorrections.count > previous
    }

    /// Le flux a fini son écoute ; le fichier est encore en cours de vérification. Préparer ce texte complet
    /// permet de chevaucher les deux appels, même si une pause avait préparé un ancien fragment.
    func prepareFinalStreamCorrection(_ current: Capture, text: String) {
        guard !current.preparedAtRelease else { return }
        prepareCorrection(current, heard: text, atRelease: true)
    }

    /// La fin de dictée prend la préparation si son texte correspond au texte retenu, au sens de
    /// `TranscriptEquivalence`. Une préparation sur un autre texte reste comptée, sans être réutilisée à tort.
    func claimEarlyCorrection(for text: String, current: Capture, model: AppModel) -> CorrectionLedger? {
        current.correctionClaimed = true
        let used = current.earlyCorrections.last { TranscriptEquivalence.equivalent($0.text, text) }?.ledger
        // Vrai seulement quand le texte collé en sort (le fichier peut encore dire autre chose).
        if !current.earlyCorrections.isEmpty, current.run.trace.earlyCorrectionUsed == nil {
            current.run.trace.earlyCorrectionUsed = false
        }
        accountEarlyCorrections(current, model: model, except: used)
        return used
    }

    /// Compte chaque correction préparée, une seule fois, même si elle finit après le collage.
    func accountEarlyCorrections(_ current: Capture, model: AppModel, except used: CorrectionLedger? = nil, cancel: Bool = false) {
        for prepared in current.earlyCorrections where prepared.ledger !== used {
            let ledger = prepared.ledger
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

    /// Terme anglais dans une dictée française (« repo », « unlock ») : connu de l'orthographe anglaise, inconnu de la
    /// française. La seconde écoute ne le remplace jamais.
    static func englishTerm(for transcript: String, language: DictationLanguage) -> ((String) -> Bool)? {
        let spoken = language == .auto ? TranscriptLanguage.guess(transcript) : language
        let checker = NSSpellChecker.shared
        guard spoken != .english, checker.availableLanguages.contains(where: { $0.hasPrefix("en") }),
              checker.availableLanguages.contains(where: { $0.hasPrefix("fr") }) else { return nil }
        func known(_ word: String, _ code: String) -> Bool {
            checker.checkSpelling(of: word, startingAt: 0, language: code, wrap: false, inSpellDocumentWithTag: 0,
                                  wordCount: nil).location == NSNotFound
        }
        return { word in known(word, "en") && !known(word, "fr") }
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
        let numbered = NumberWriter.apply(dated, format: model.settings.numberFormat, english: english)
        patched.outcome.text = TextCleaner.completeWrittenGrammar(numbered, language: model.settings.language,
            tone: model.tone(bundleID: current.context.bundleID, appName: current.context.appName))
        return patched
    }
}
