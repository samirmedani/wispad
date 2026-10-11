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

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-diagnostic-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
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
}
