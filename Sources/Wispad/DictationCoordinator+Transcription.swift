import AppKit
import Foundation
import os
import WispadCore

/// Texte retenu à la fin d'une dictée : flux en direct, enregistrement complet, ou relais.
extension DictationCoordinator {
    func launchFile(url: URL, speech: SpeechRequest, seconds: Double, run: DictationTraceRecorder, model: AppModel) -> FileLedger {
        let completion = FileLedger.Completion()
        let task = Task { @MainActor in
            let attempt: FileAttempt
            if Task.isCancelled {
                attempt = FileAttempt(text: "", started: Date(), latencyMs: 0, failed: false, called: false)
            } else {
                let started = Date()
                do {
                    let text = try await model.dependencies.transcribe(url, speech)
                    attempt = FileAttempt(text: text, started: started, latencyMs: Self.milliseconds(since: started), failed: false, called: true)
                } catch {
                    attempt = FileAttempt(text: "", started: started, latencyMs: Self.milliseconds(since: started), failed: true, called: true,
                                          failureCause: APIFailureCause.classify(error))
                }
            }
            completion.attempt = attempt
            return attempt
        }
        return FileLedger(task: task, completion: completion, speech: speech, seconds: seconds, run: run, model: model)
    }

    struct FileDecision {
        var raw = ""
        /// Texte du flux quand le fichier est retenu : la correction peut y départager un mot.
        var alternative: String?
        var speech: SpeechRequest
        var ledger: CorrectionLedger?
        var usePrepared = false
        var stop = false
    }

    /// Fichier et flux en parallèle. Le fichier gagne seulement s'il arrive dans la borne et dit autre chose.
    func verifyAgainstFile(
        raw: String,
        streamed: Bool,
        liveBroke: Bool,
        streamMs: Int,
        finishStarted: Date,
        speech: SpeechRequest,
        ledger: FileLedger,
        job: FinishJob,
        model: AppModel,
        context: DictationContext,
        transcriptionBegan: Int
    ) async -> FileDecision {
        var decision = FileDecision(speech: speech)
        let current = job.capture
        if !streamed || liveBroke {
            let outcome = await consumeLaunchedFile(
                ledger: ledger, speech: &decision.speech, job: job, model: model,
                context: context, transcriptionBegan: transcriptionBegan
            )
            switch outcome {
            case .text(let text, let latency):
                decision.raw = text
                noteChoice(.file, .streamEmpty, latency, streamMs, job.duration, current.run)
            case .stop:
                decision.stop = true
            }
            return decision
        }

        let streamText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.fieldRead { context.apply(await current.field.value) }
        // Le fichier peut être revenu pendant la finalisation du flux. Le choix est alors déjà connu :
        // inutile de corriger le flux, puis d'attendre cette correction pour finalement corriger le fichier.
        if let attempt = ledger.completion.attempt, !attempt.failed,
           !TranscriptEquivalence.normalize(attempt.text).isEmpty {
            await ledger.account()
            selectVerifiedTranscript(attempt, raw: raw, streamText: streamText, streamMs: streamMs, job: job, decision: &decision)
            if !job.cancelled, model.settings.cleanupEnabled,
               model.commandSelection(for: decision.raw, context: context) == nil {
                decision.ledger = claimEarlyCorrection(
                    for: FranglaisNormalizer.normalize(decision.raw), current: current, model: model
                )
                decision.usePrepared = decision.ledger != nil
            }
            return decision
        }
        // Une consigne sur la sélection n'a pas de correction du flux à préparer. Hors connexion non plus : l'appel
        // échouerait, et la fin de dictée décide avec la connexion du moment.
        if model.correctionReachable, !job.cancelled, model.commandSelection(for: streamText, context: context) == nil {
            let normalized = FranglaisNormalizer.normalize(streamText)
            if let early = claimEarlyCorrection(for: normalized, current: current, model: model) {
                // Correction déjà lancée pendant l'écoute, sur ce même texte : elle tient lieu de correction du flux.
                decision.ledger = early
                let fileTask = ledger.task
                job.cancelSideWork = {
                    fileTask.cancel()
                    early.task.cancel()
                }
            } else {
                let request = await makeCorrectionRequest(
                    transcript: normalized, context: context, field: current.field, window: current.window, model: model
                )
                // Échap pendant la lecture du champ : la correction n'est pas lancée.
                if !job.cancelled {
                    let task = Task { @MainActor in
                        let began = Date()
                        let outcome = await model.dependencies.clean(normalized, request, speech, true)
                        return PreparedCorrection(outcome: outcome, milliseconds: Self.milliseconds(since: began))
                    }
                    decision.ledger = CorrectionLedger(task: task)
                    let fileTask = ledger.task
                    job.cancelSideWork = {
                        fileTask.cancel()
                        task.cancel()
                    }
                }
            }
        }

        let remaining = max(0, TranscriptEquivalence.fileWaitSeconds(audioDuration: job.duration) - Date().timeIntervalSince(finishStarted))
        let attempt = await Self.firstFile(ledger.task, within: remaining, job: job)
        if job.cancelled {
            _ = await decision.ledger?.account(model: model, run: current.run)
            await ledger.account()
            delete(job.url)
            decision.stop = true
            return decision
        }
        // Un fichier sans aucun mot face à un flux qui en a ne gagne pas : la dictée serait perdue.
        if let attempt, !attempt.failed, !TranscriptEquivalence.normalize(attempt.text).isEmpty {
            await ledger.account()
            selectVerifiedTranscript(attempt, raw: raw, streamText: streamText, streamMs: streamMs, job: job, decision: &decision)
            return decision
        }
        if let attempt {
            await ledger.account()
            decision.raw = raw
            decision.usePrepared = decision.ledger != nil
            noteChoice(.stream, .fileFailed, attempt.latencyMs, streamMs, job.duration, current.run)
            return decision
        }
        let waited = Self.milliseconds(since: finishStarted)
        Task { @MainActor in await ledger.account() }
        decision.raw = raw
        decision.usePrepared = decision.ledger != nil
        noteChoice(.stream, .fileTimeout, waited, streamMs, job.duration, current.run)
        return decision
    }

    private func selectVerifiedTranscript(
        _ attempt: FileAttempt, raw: String, streamText: String, streamMs: Int,
        job: FinishJob, decision: inout FileDecision
    ) {
        let run = job.capture.run
        run.trace.streamWords = WordCount.count(streamText)
        run.trace.fileWords = WordCount.count(attempt.text)
        if TranscriptEquivalence.equivalent(streamText, attempt.text) {
            decision.raw = raw
            decision.usePrepared = decision.ledger != nil
            noteChoice(.stream, .equivalent, attempt.latencyMs, streamMs, job.duration, run)
        } else {
            decision.raw = attempt.text
            decision.alternative = streamText
            run.trace.divergentWords = TranscriptEquivalence.differingWords(streamText, attempt.text)
            noteChoice(.file, .diverged, attempt.latencyMs, streamMs, job.duration, run)
        }
    }

    private enum LaunchedFileResult {
        case text(String, Int)
        case stop
    }

    /// Le flux n'a rien donné : on attend le fichier déjà lancé, sans le rappeler.
    private func consumeLaunchedFile(
        ledger: FileLedger,
        speech: inout SpeechRequest,
        job: FinishJob,
        model: AppModel,
        context: DictationContext,
        transcriptionBegan: Int
    ) async -> LaunchedFileResult {
        let attempt = await ledger.task.value
        await ledger.account()
        if job.cancelled {
            delete(job.url)
            return .stop
        }
        if !attempt.failed { return .text(attempt.text, attempt.latencyMs) }
        guard let url = job.url else { return .stop }
        let service = ServiceHealth.voice(speech.provider)
        if let fallback = model.voiceRelay(for: speech),
           let text = try? await transcribeFile(url, speech: fallback, seconds: job.duration, run: job.capture.run, fallback: APIFallback(
               fromAPI: .transcription(speech.provider, streaming: false),
               stage: .transcription, reason: .requestFailed
           )) {
            if job.cancelled {
                delete(url)
                return .stop
            }
            announceRelay(service, String(localized: "\(speech.provider.displayName) ne répond pas : voix via \(fallback.provider.displayName)."), job: job)
            speech = fallback
            showRelay(fallback.provider.displayName)
            return .text(text, attempt.latencyMs)
        }
        if job.cancelled {
            delete(url)
            return .stop
        }
        job.capture.run.trace.timings.transcriptionMs = max(0, KeyboardTap.now() - transcriptionBegan)
        job.capture.run.trace.outcome = .transcriptionFailed
        await waitForTurn(job)
        guard !job.cancelled else {
            delete(url)
            return .stop
        }
        preserveFailedAudio(url, duration: job.duration, speech: speech, context: context, model: model, run: job.capture.run)
        return .stop
    }

    /// Réglage coupé, ou pas de flux : le fichier ne part que si le flux est vide ou sa fin peu fiable.
    func legacyTranscript(
        raw: String,
        streamed: Bool,
        streamFinish: StreamFinish?,
        streamMs: Int,
        speech: inout SpeechRequest,
        job: FinishJob,
        model: AppModel,
        context: DictationContext,
        transcriptionBegan: Int
    ) async -> String? {
        let current = job.capture
        var text = raw
        let streamFallback = streamFinish.flatMap { finish -> StreamEndFallback? in
            guard streamed else { return nil }
            return StreamEndReliability.fallback(finish, audioSeconds: job.duration)
        }
        if let streamFallback {
            current.run.trace.streamFallback = streamFallback
            let audioMs = max(0, Int((job.duration * 1_000).rounded()))
            switch streamFallback {
            case .unfinalized:
                Self.transcriptionLog.notice("fin de flux non finalisée → repli fichier audio=\(audioMs, privacy: .public) ms flux=\(streamMs, privacy: .public) ms")
            case .shortCoverage:
                let coveredMs = max(0, Int(((streamFinish?.coveredSeconds ?? 0) * 1_000).rounded()))
                Self.transcriptionLog.notice("couverture du flux trop courte → repli fichier audio=\(audioMs, privacy: .public) ms couvert=\(coveredMs, privacy: .public) ms flux=\(streamMs, privacy: .public) ms")
            }
        }
        let needsFile = !streamed || streamFallback != nil
        var fileMs: Int?
        var keptStream = false
        if needsFile, let url = job.url {
            let fileClock = Date()
            do {
                let file = try await transcribeFile(url, speech: speech, seconds: job.duration, run: current.run)
                // Fichier sans aucun mot alors que le flux en a : le texte du flux reste, rien n'est perdu.
                if !streamed || !TranscriptEquivalence.normalize(file).isEmpty { text = file } else { keptStream = true }
                fileMs = Self.milliseconds(since: fileClock)
                guard !job.cancelled else {
                    delete(url)
                    return nil
                }
                model.recordHealth(ServiceHealth.voice(speech.provider), succeeded: true)
            } catch {
                fileMs = Self.milliseconds(since: fileClock)
                guard !job.cancelled else {
                    delete(url)
                    return nil
                }
                let service = ServiceHealth.voice(speech.provider)
                model.recordHealth(service, succeeded: false)
                if let fallback = model.voiceRelay(for: speech),
                   let recovered = try? await transcribeFile(url, speech: fallback, seconds: job.duration, run: current.run, fallback: APIFallback(
                       fromAPI: .transcription(speech.provider, streaming: false),
                       stage: .transcription, reason: .requestFailed
                   )) {
                    guard !job.cancelled else {
                        delete(url)
                        return nil
                    }
                    announceRelay(service, String(localized: "\(speech.provider.displayName) ne répond pas : voix via \(fallback.provider.displayName)."), job: job)
                    text = recovered
                    speech = fallback
                    showRelay(fallback.provider.displayName)
                    fileMs = Self.milliseconds(since: fileClock)
                } else {
                    guard !job.cancelled else {
                        delete(url)
                        return nil
                    }
                    current.run.trace.timings.transcriptionMs = max(0, KeyboardTap.now() - transcriptionBegan)
                    current.run.trace.outcome = .transcriptionFailed
                    noteChoice(needsFile ? .file : .stream, legacyReason(model: model, needsFile: true, streamed: streamed), fileMs, streamMs, job.duration, current.run)
                    await waitForTurn(job)
                    guard !job.cancelled else {
                        delete(url)
                        return nil
                    }
                    preserveFailedAudio(url, duration: job.duration, speech: speech, context: context, model: model, run: current.run)
                    return nil
                }
            }
        }
        noteChoice(
            needsFile && !keptStream ? .file : .stream,
            legacyReason(model: model, needsFile: needsFile, streamed: streamed),
            needsFile ? fileMs : nil,
            streamMs,
            job.duration,
            current.run
        )
        return text
    }

    private func legacyReason(model: AppModel, needsFile: Bool, streamed: Bool) -> TranscriptChoice {
        if !model.settings.verifyWithFile { return .settingOff }
        if needsFile || !streamed { return .streamEmpty }
        return .fileFailed
    }

    func makeCorrectionRequest(
        transcript: String,
        context: DictationContext,
        field: Task<FieldSnapshot?, Never>,
        window: Task<String?, Never>?,
        model: AppModel
    ) async -> CorrectionRequest {
        if !context.fieldRead { context.apply(await field.value) }
        var windowText: String?
        if let window, case .some(let text) = await Self.value(of: window, within: Self.windowWait) {
            windowText = text
        }
        var request = CorrectionRequest(
            transcript: transcript,
            dictionary: model.dictionary.map(\.term),
            appName: context.appName,
            selectedText: context.selectedText,
            nearbyText: context.nearbyText,
            previousDictations: model.recentDictationTexts(bundleID: context.bundleID),
            windowText: windowText,
            structureDictation: model.settings.structureDictation,
            language: model.settings.language
        )
        request.tone = model.tone(bundleID: context.bundleID, appName: context.appName)
        request.dateFormat = model.settings.dateFormat
        request.numberFormat = model.settings.numberFormat
        return request
    }

    private func noteChoice(
        _ source: TranscriptSource,
        _ reason: TranscriptChoice,
        _ fileMs: Int?,
        _ streamMs: Int,
        _ audioSeconds: Double,
        _ run: DictationTraceRecorder
    ) {
        run.trace.transcriptSource = source
        run.trace.transcriptChoice = reason
        run.trace.fileLatencyMs = fileMs
        let audioMs = max(0, Int((audioSeconds * 1_000).rounded()))
        let fileLabel = fileMs.map(String.init) ?? "absent"
        Self.transcriptionLog.notice("source=\(source.rawValue, privacy: .public) raison=\(reason.rawValue, privacy: .public) audio=\(audioMs, privacy: .public) ms flux=\(streamMs, privacy: .public) ms fichier=\(fileLabel, privacy: .public) ms")
    }

    /// Premier résultat : le fichier, l'échéance, ou une annulation. Le fichier lui-même continue.
    private static func firstFile(_ task: Task<FileAttempt, Never>, within seconds: Double, job: FinishJob) async -> FileAttempt? {
        let stop = OSAllocatedUnfairLock(initialState: false)
        let winner = AsyncResult<FileAttempt?>()
        func win(_ value: FileAttempt?) {
            let first = stop.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            if first { winner.resolve(.success(value)) }
        }
        let fileWaiter = Task { @MainActor in win(await task.value) }
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            win(nil)
        }
        let cancelWatch = Task { @MainActor in
            while !stop.withLock({ $0 }), !job.cancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            win(nil)
        }
        let result = (try? await winner.value()) ?? nil
        fileWaiter.cancel()
        timer.cancel()
        cancelWatch.cancel()
        return result
    }
}
