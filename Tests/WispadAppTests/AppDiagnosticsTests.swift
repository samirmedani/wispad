import AVFoundation
import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

@MainActor
private final class DiagnosticsFixture {
    let directory: URL
    var model: AppModel!
    var keyReads = 0
    /// Ce que Wispad a mis dans le presse-papiers (jamais le vrai).
    var copied: [String] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-diagnostic-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { [weak self] text in self?.copied.append(text) }
        dependencies.loadKey = { [weak self] _ in
            self?.keyReads += 1
            return "secret-key-sentinel"
        }
        dependencies.refreshKeys = { false }
        dependencies.requestMicrophone = { false }
        model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
        model.overlay.displaysPanel = false
    }

    func dispose() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct AppDiagnosticsTests {
    @Test func exportProjectionOmitsAllUntrustedTextAndIdentifiers() throws {
        let fixture = try DiagnosticsFixture()
        defer { fixture.dispose() }
        let model = try #require(fixture.model)
        model.statusBanner = "status-secret-sentinel"
        model.keyMessages["xai"] = "validation-secret-sentinel"
        model.keyDrafts["xai"] = "draft-secret-sentinel"
        model.coordinator.phase = .failure("error-secret-sentinel")
        model.coordinator.failureText = "failure-secret-sentinel"
        model.history = [DictationRecord(
            id: "history-id-secret-sentinel", finalText: "text-secret-sentinel", rawText: "raw-secret-sentinel",
            durationSeconds: 1, wordCount: 1, provider: "provider-secret-sentinel", model: "model-secret-sentinel",
            targetApp: "app-secret-sentinel", targetBundle: "bundle-secret-sentinel",
            insertionStatus: "status-secret-sentinel", audioPath: "/private/path-secret-sentinel.wav"
        )]
        let call = DictationAPICall(UsageEvent(
            id: "usage-id-secret-sentinel", api: .openAIFile, model: "model-secret-sentinel",
            costUSD: nil, latencyMs: 450, succeeded: false,
            fallback: APIFallback(fromAPI: .xaiFile, stage: .transcription, reason: .requestFailed)
        ))
        let trace = DictationTrace(
            id: "trace-id-secret-sentinel", dictationID: "history-id-secret-sentinel",
            origin: .toggle, timings: DictationTimings(firstAudioMs: 240), calls: [call], outcome: .transcriptionFailed
        )
        let snapshot = AppDiagnostics.snapshot(model: model)
        let report = AppDiagnostics.report(snapshot: snapshot, traces: [trace])
        let data = try AppDiagnostics.encodedData(report)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("secret-sentinel"))
        #expect(fixture.keyReads == 0)
        #expect(report.snapshot.phase == .failure)
        #expect(report.attempts.first?.outcome == .transcriptionFailed)
        #expect(report.attempts.first?.calls.first?.fallback?.reason == "requestFailed")

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "snapshot", "traceReadSucceeded", "attempts"])
        let attempts = try #require(object["attempts"] as? [[String: Any]])
        #expect(Set(try #require(attempts.first).keys) == ["createdAt", "origin", "outcome", "timings", "calls"])
        let calls = try #require(attempts.first?["calls"] as? [[String: Any]])
        #expect(Set(try #require(calls.first).keys) == ["api", "latencyMs", "succeeded", "fallback"])
    }

    @Test func missingTimingsRemainAbsentAndReadFailureIsExplicit() throws {
        let fixture = try DiagnosticsFixture()
        defer { fixture.dispose() }
        let trace = DictationTrace(origin: .retry, outcome: .transcriptionFailed)
        let report = AppDiagnostics.report(snapshot: AppDiagnostics.snapshot(model: fixture.model),
                                           traces: [trace], traceReadSucceeded: false)
        #expect(!report.traceReadSucceeded)
        #expect(report.attempts.first?.timings.microphoneMs == nil)
        let object = try #require(JSONSerialization.jsonObject(with: AppDiagnostics.encodedData(report)) as? [String: Any])
        let attempts = try #require(object["attempts"] as? [[String: Any]])
        let timings = try #require(attempts.first?["timings"] as? [String: Any])
        #expect(timings.isEmpty)
    }

    @Test func reportIsBoundedEvenForOversizedInputs() throws {
        let fixture = try DiagnosticsFixture()
        defer { fixture.dispose() }
        let call = DictationAPICall(UsageEvent(api: .xaiFile, model: "fixture", costUSD: nil))
        let traces = (0..<75).map { _ in DictationTrace(origin: .hold, calls: Array(repeating: call, count: 100)) }
        let report = AppDiagnostics.report(snapshot: AppDiagnostics.snapshot(model: fixture.model), traces: traces)
        #expect(report.attempts.count == 50)
        #expect(report.attempts.allSatisfy { $0.calls.count == 32 })
    }

    @Test func localExportReadsTechnicalTracesAndProducesJSON() async throws {
        let fixture = try DiagnosticsFixture()
        defer { fixture.dispose() }
        fixture.model.microphoneStatus = .denied
        try fixture.model.store.saveTrace(DictationTrace(
            origin: .hold, timings: DictationTimings(microphoneMs: 90), outcome: .microphoneDenied
        ))
        let destination = fixture.directory.appendingPathComponent("report.json")
        try await AppDiagnostics.export(snapshot: AppDiagnostics.snapshot(model: fixture.model),
                                        store: fixture.model.store, to: destination)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        let attempts = try #require(object["attempts"] as? [[String: Any]])
        #expect(attempts.count == 1)
        #expect(attempts.first?["outcome"] as? String == "microphoneDenied")
        let snapshot = try #require(object["snapshot"] as? [String: Any])
        #expect(snapshot["microphone"] as? String == "denied")
        #expect(object["traceReadSucceeded"] as? Bool == true)
        #expect(fixture.keyReads == 0)
    }

    @Test func versionMetadataRejectsArbitraryStrings() {
        #expect(AppDiagnostics.versionComponent("1.2.3") == "1.2.3")
        #expect(AppDiagnostics.versionComponent("1.2\nsecret-key-sentinel") == "unknown")
        #expect(AppDiagnostics.versionComponent("/Users/sensitive") == "unknown")
        #expect(AppDiagnostics.versionComponent("١٢٣") == "unknown")
        #expect(AppDiagnostics.versionComponent(String(repeating: "1", count: 41)) == "unknown")
        #expect(AppDiagnostics.versionComponent(nil) == "unknown")
    }

    @Test func keyboardSnapshotDoesNotStartListening() {
        let tap = KeyboardTap(deliver: { _ in }, unavailable: {})
        tap.update { $0.capturing = true; $0.pending = true; $0.recording = true }
        let state = tap.diagnosticState
        #expect(state.listening == .notStarted)
        #expect(state.recoveries == 0)
        #expect(state.capturing && state.pending && state.recordingShortcut)
    }

    // MARK: Réglages › Aide : copier le diagnostic, copier le prompt

    /// Les deux copies reprennent le rapport de l'export : rien de dicté, aucun identifiant, aucun chemin, aucune clé.
    @Test func copiedDiagnosticAndAgentPromptCarryNothingPersonal() async throws {
        let fixture = try DiagnosticsFixture()
        defer { fixture.dispose() }
        let model = try #require(fixture.model)
        model.statusBanner = "status-secret-sentinel"
        model.keyDrafts["xai"] = "draft-secret-sentinel"
        model.coordinator.failureText = "failure-secret-sentinel"
        try model.store.insert(DictationRecord(
            id: "history-id-secret-sentinel", finalText: "text-secret-sentinel", rawText: "raw-secret-sentinel",
            durationSeconds: 1, wordCount: 1, provider: "provider-secret-sentinel", model: "model-secret-sentinel",
            targetApp: "app-secret-sentinel", targetBundle: "bundle-secret-sentinel", insertionStatus: "inserted"
        ))
        model.reloadHistory()
        try model.store.saveTrace(DictationTrace(
            id: "trace-id-secret-sentinel", dictationID: "history-id-secret-sentinel", origin: .toggle,
            timings: DictationTimings(firstAudioMs: 240),
            calls: [DictationAPICall(UsageEvent(id: "usage-id-secret-sentinel", api: .openAIFile, model: "model-secret-sentinel",
                                                costUSD: nil, latencyMs: 450, succeeded: false,
                                                fallback: APIFallback(fromAPI: .xaiFile, stage: .transcription, reason: .requestFailed)))],
            outcome: .transcriptionFailed
        ))
        await model.copyDiagnostic()
        #expect(model.statusBanner == "Diagnostic copié : colle-le dans ton ticket.")
        await model.copyAgentPrompt()
        #expect(model.statusBanner?.hasPrefix("Prompt copié") == true)
        #expect(fixture.copied.count == 2)
        for text in fixture.copied {
            #expect(!text.contains("secret-sentinel"))
            #expect(!text.contains(NSHomeDirectory()))
            #expect(!text.contains(fixture.directory.path))
            #expect(text.contains("\"outcome\" : \"transcriptionFailed\""))
        }
        #expect(fixture.keyReads == 0)
    }

    @Test func copiedDiagnosticIsReadyToPasteInATicket() throws {
        let fixture = try DiagnosticsFixture()
        defer { fixture.dispose() }
        let report = AppDiagnostics.report(snapshot: AppDiagnostics.snapshot(model: fixture.model),
                                           traces: [DictationTrace(origin: .hold, outcome: .inserted)])
        let text = AppDiagnostics.clipboardText(report)
        #expect(text.hasPrefix("<details>\n<summary>Diagnostic Wispad "))
        #expect(text.hasSuffix("</details>"))
        #expect(!text.contains("retirée"))
        let decoded = try decodedReport(in: text)
        #expect(decoded.attempts.count == 1)
        #expect(decoded.snapshot.appVersion == report.snapshot.appVersion)
    }

    /// Un ticket GitHub accepte 65 536 caractères : les tentatives les plus anciennes cèdent la place.
    @Test func anOversizedDiagnosticDropsItsOldestAttemptsToFitATicket() throws {
        let fixture = try DiagnosticsFixture()
        defer { fixture.dispose() }
        let call = DictationAPICall(UsageEvent(api: .openAIFile, model: "fixture", costUSD: nil, latencyMs: 450, succeeded: false,
                                               fallback: APIFallback(fromAPI: .xaiFile, stage: .transcription, reason: .requestFailed)))
        let newest = Date(timeIntervalSince1970: 1_793_450_400)
        let traces = (0..<50).map { index in
            DictationTrace(createdAt: newest.addingTimeInterval(Double(-index) * 60), origin: .hold,
                           calls: Array(repeating: call, count: 32), outcome: .inserted)
        }
        let report = AppDiagnostics.report(snapshot: AppDiagnostics.snapshot(model: fixture.model), traces: traces)
        let fitted = AppDiagnostics.fitted(report)
        #expect(fitted.omitted > 0 && fitted.omitted < 50)
        #expect(fitted.json.utf8.count <= AppDiagnostics.clipboardLimit)
        let text = AppDiagnostics.clipboardText(report)
        #expect(text.contains("\(fitted.omitted) tentatives les plus anciennes sont retirées"))
        let kept = try decodedReport(in: text)
        #expect(kept.attempts.count == 50 - fitted.omitted)
        #expect(kept.attempts.first?.createdAt == newest)
        // Une tentative de plus ne tiendrait pas.
        var oneMore = report
        oneMore.attempts = Array(report.attempts.prefix(kept.attempts.count + 1))
        #expect(try AppDiagnostics.encodedData(oneMore).count > AppDiagnostics.clipboardLimit)
    }

    /// Le prompt dit où regarder, ce qu'il ne faut jamais lire, comment chercher un ticket existant et en préparer un
    /// anonyme, publié seulement avec l'accord de l'utilisateur ; le diagnostic suit, tel que l'export l'écrit.
    @Test func agentPromptIsExactAboutWispadOnThisMac() throws {
        let fixture = try DiagnosticsFixture()
        defer { fixture.dispose() }
        let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1)
        let context = AgentHelpPrompt.Context(
            version: "0.7.7 · 1e861a2", macOS: "macOS 26.0.1", mac: "Apple Silicon", voice: "xAI",
            bugReportURL: FeedbackLinks.bugReportURL(version: "0.7.7", commit: "1e861a2", system: system)
        )
        let report = AppDiagnostics.report(snapshot: AppDiagnostics.snapshot(model: fixture.model),
                                           traces: [DictationTrace(origin: .toggle, outcome: .noSpeech)])
        let prompt = AgentHelpPrompt.make(context, report: report)
        for expected in [
            "Ce Mac : Wispad 0.7.7 · 1e861a2, macOS 26.0.1, Apple Silicon. Voix : xAI.",
            "/usr/bin/log show --last 1h --style compact --predicate 'subsystem == \"\(AppIdentity.bundleID)\"'",
            "lis seulement latence.log", "wispad.sqlite", "Audio", "benchmarks", "api-keys.json",
            "Ne change rien sur ce Mac sans mon accord",
            "gh issue list --repo samirmedani/wispad --state all",
            "Version de Wispad : 0.7.7 · 1e861a2. Version de macOS : macOS 26.0.1.",
            "Fournisseur de transcription : xAI. Type de Mac : Apple Silicon.",
            "Anonymise tout", "chemins personnels",
            "gh issue create --repo samirmedani/wispad",
            context.bugReportURL.absoluteString
        ] {
            #expect(prompt.contains(expected), "\(expected)")
        }
        #expect(context.bugReportURL.absoluteString.hasPrefix("https://github.com/samirmedani/wispad/issues/new?template=bug.yml&"))
        let decoded = try decodedReport(in: prompt)
        #expect(decoded.attempts.first?.outcome == .noSpeech)
    }

    @Test func agentPromptContextTakesTheVersionsShownInTheApp() throws {
        let fixture = try DiagnosticsFixture()
        defer { fixture.dispose() }
        let status = BuildStatus(info: ["CFBundleShortVersionString": "0.7.7", BuildStatus.commitInfoKey: "1e861a2f00"])
        let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1)
        let context = AgentHelpPrompt.context(model: fixture.model, status: status, system: system)
        #expect(context.version == "0.7.7 · 1e861a2")
        #expect(context.macOS == "macOS 26.0.1")
        #expect(context.voice == fixture.model.settings.provider.displayName)
        #expect(["Apple Silicon", "Intel"].contains(context.mac))
        #expect(context.bugReportURL == status.bugReportURL(system: system))
    }

    /// Le rapport JSON entre les balises de code d'un texte copié.
    private func decodedReport(in text: String) throws -> DiagnosticReport {
        let fence = "```"
        let start = try #require(text.range(of: fence + "json\n"))
        let end = try #require(text.range(of: "\n" + fence, range: start.upperBound..<text.endIndex))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticReport.self, from: Data(text[start.upperBound..<end.lowerBound].utf8))
    }
}
