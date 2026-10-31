import AppKit
import AVFoundation
import Foundation
import WispadCore

struct OverlayDiagnosticState: Codable, Equatable, Sendable {
    var installed: Bool
    var wanted: Bool
    var visible: Bool
    var onActiveSpace: Bool
    var recoveries: Int
    /// Panneaux recréés pour rejoindre un espace plein écran.
    var spaceReplacements: Int
}

/// Liste fermée : aucun message d'erreur, texte dicté, contexte, chemin ou secret.
struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    enum Microphone: String, Codable, Sendable {
        case authorized, denied, restricted, notDetermined, unknown
    }
    enum Phase: String, Codable, Sendable {
        case idle, starting, hold, toggle, finishing, failure

        var title: String {
            switch self {
            case .idle: return String(localized: "Au repos")
            case .starting: return String(localized: "Démarrage du micro")
            case .hold: return String(localized: "Dictée en maintien")
            case .toggle: return String(localized: "Dictée mains libres")
            case .finishing: return String(localized: "Finalisation")
            case .failure: return String(localized: "Erreur")
            }
        }
    }

    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var macOSVersion: String
    var microphone: Microphone
    var accessibilityTrusted: Bool
    var inputMonitoringTrusted: Bool
    var keyboard: KeyboardDiagnosticState
    var overlay: OverlayDiagnosticState
    var phase: Phase
    var finishingCount: Int
    var voiceProvider: ProviderID
    var correctionEnabled: Bool
    var soundsEnabled: Bool
}

struct DiagnosticReport: Codable, Equatable, Sendable {
    struct Fallback: Codable, Equatable, Sendable {
        var fromAPI: UsageAPI
        var stage: String
        var reason: String

        init(_ source: APIFallback) {
            fromAPI = source.fromAPI
            stage = source.stage.rawValue
            reason = source.reason.rawValue
        }
    }

    struct Timings: Codable, Equatable, Sendable {
        var microphoneMs: Int?
        var firstAudioMs: Int?
        var streamReadyMs: Int?
        var transcriptionMs: Int?
        var correctionMs: Int?
        var insertionMs: Int?
        var afterReleaseMs: Int?

        init(_ source: DictationTimings) {
            microphoneMs = source.microphoneMs
            firstAudioMs = source.firstAudioMs
            streamReadyMs = source.streamReadyMs
            transcriptionMs = source.transcriptionMs
            correctionMs = source.correctionMs
            insertionMs = source.insertionMs
            afterReleaseMs = source.afterReleaseMs
        }
    }

    struct Call: Codable, Equatable, Sendable {
        var api: UsageAPI
        var latencyMs: Int
        var succeeded: Bool
        var fallback: Fallback?

        init(_ source: DictationAPICall) {
            api = source.api
            latencyMs = source.latencyMs
            succeeded = source.succeeded
            fallback = source.fallback.map(Fallback.init)
        }
    }

    struct Attempt: Codable, Equatable, Sendable {
        var createdAt: Date
        var origin: DictationOrigin
        var outcome: DictationOutcome
        var timings: Timings
        var calls: [Call]

        init(_ source: DictationTrace) {
            createdAt = source.createdAt
            origin = source.origin
            outcome = source.outcome
            timings = Timings(source.timings)
            // Défense supplémentaire contre un enregistrement anormalement volumineux.
            calls = source.calls.prefix(32).map(Call.init)
        }
    }

    var schemaVersion = 1
    var snapshot: DiagnosticSnapshot
    var traceReadSucceeded: Bool
    var attempts: [Attempt]
}

enum AppDiagnostics {
    static let traceLimit = 50
    /// File de l'export : lecture de la base (jusqu'à 2 s si un autre programme la tient) et écriture du rapport, jamais
    /// sur un fil de Swift concurrency.
    static let exports = BlockingQueue(label: "wispad.diagnostic", qos: .utility)

    @MainActor
    static func snapshot(model: AppModel, at date: Date = Date(), bundle: Bundle = .main) -> DiagnosticSnapshot {
        let microphone: DiagnosticSnapshot.Microphone
        switch model.microphoneStatus {
        case .authorized: microphone = .authorized
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        case .notDetermined: microphone = .notDetermined
        @unknown default: microphone = .unknown
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticSnapshot(
            createdAt: date,
            appVersion: versionComponent(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            appBuild: versionComponent(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            microphone: microphone,
            accessibilityTrusted: model.accessibilityTrusted,
            inputMonitoringTrusted: model.inputMonitoringTrusted,
            keyboard: model.hotkeys?.diagnosticState ?? KeyboardDiagnosticState(),
            overlay: model.overlay.diagnosticState,
            phase: phase(model.coordinator.phase),
            finishingCount: model.coordinator.finishingCount,
            voiceProvider: model.settings.provider,
            correctionEnabled: model.settings.cleanupEnabled,
            soundsEnabled: model.settings.soundsEnabled
        )
    }

    static func phase(_ phase: DictationPhase) -> DiagnosticSnapshot.Phase {
        switch phase {
        case .idle: return .idle
        case .starting: return .starting
        case .listening(.pushToTalk): return .hold
        case .listening(.toggle): return .toggle
        case .finishing: return .finishing
        case .failure: return .failure
        }
    }

    /// Même les chaînes de version sont limitées à des chiffres ASCII et des points.
    static func versionComponent(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 40,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              value.utf8.contains(where: { (48...57).contains($0) }) else { return "unknown" }
        return value
    }

    static func report(snapshot: DiagnosticSnapshot, traces: [DictationTrace], traceReadSucceeded: Bool = true) -> DiagnosticReport {
        DiagnosticReport(snapshot: snapshot, traceReadSucceeded: traceReadSucceeded,
                         attempts: traces.prefix(traceLimit).map(DiagnosticReport.Attempt.init))
    }

    static func encodedData(_ report: DiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    /// La lecture SQLite et l'écriture du rapport ne bloquent ni le micro ni la fenêtre.
    static func export(snapshot: DiagnosticSnapshot, store: HistoryStore, to url: URL) async throws {
        try await exports.run {
            let traces = try? store.recentTraces(limit: traceLimit)
            let report = report(snapshot: snapshot, traces: traces ?? [], traceReadSucceeded: traces != nil)
            try encodedData(report).write(to: url, options: .atomic)
        }
    }

    // MARK: Copier le diagnostic (Réglages › Aide)

    /// Taille maximale du rapport copié, en octets : un ticket GitHub accepte 65 536 caractères, il reste de la place
    /// pour la description, les étapes et les journaux.
    static let clipboardLimit = 40_000

    /// Même rapport que l'export, lu sur la même file : la base n'est jamais lue sur le fil principal.
    static func report(snapshot: DiagnosticSnapshot, store: HistoryStore) async -> DiagnosticReport {
        await exports.run {
            let traces = try? store.recentTraces(limit: traceLimit)
            return report(snapshot: snapshot, traces: traces ?? [], traceReadSucceeded: traces != nil)
        }
    }

    /// Le rapport tient en `limit` octets : les tentatives les plus anciennes sont retirées d'abord (elles arrivent
    /// de la plus récente à la plus ancienne). Rend aussi le nombre de tentatives retirées.
    static func fitted(_ report: DiagnosticReport, limit: Int = clipboardLimit) -> (json: String, omitted: Int) {
        func json(keeping count: Int) -> String {
            var kept = report
            kept.attempts = Array(report.attempts.prefix(count))
            return (try? encodedData(kept)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
        let full = json(keeping: report.attempts.count)
        guard full.utf8.count > limit else { return (full, 0) }
        // Plus grand nombre de tentatives qui tient : recherche par dichotomie, quelques encodages au plus.
        var low = 0, high = report.attempts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if json(keeping: middle).utf8.count <= limit { low = middle } else { high = middle - 1 }
        }
        return (json(keeping: low), report.attempts.count - low)
    }

    /// Prêt à coller dans un ticket GitHub ou dans un agent : les versions en titre, puis le rapport JSON dans un bloc
    /// repliable. Rien d'autre que le rapport de l'export, éventuellement allégé de ses tentatives les plus anciennes.
    static func clipboardText(_ report: DiagnosticReport, limit: Int = clipboardLimit) -> String {
        let (json, omitted) = fitted(report, limit: limit)
        let snapshot = report.snapshot
        let title = String(localized: "Diagnostic Wispad \(snapshot.appVersion) (\(snapshot.appBuild)) · macOS \(snapshot.macOSVersion)")
        var note = String(localized: "Aucun texte dicté, audio, contexte d'app ni clé : autorisations, raccourci, bulle et dernières tentatives de dictée.")
        if omitted > 0 {
            note += " " + (omitted == 1
                ? String(localized: "La tentative la plus ancienne est retirée pour tenir dans un ticket.")
                : String(localized: "Les \(omitted) tentatives les plus anciennes sont retirées pour tenir dans un ticket."))
        }
        let fence = "```"
        return """
        <details>
        <summary>\(title)</summary>

        \(note)

        \(fence)json
        \(json)
        \(fence)

        </details>
        """
    }

    /// « Apple Silicon » ou « Intel », comme le formulaire de bug. Une app Intel traduite par Rosetta tourne sur Apple
    /// Silicon.
    static var macKind: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 { return "Apple Silicon" }
        return "Intel"
        #endif
    }
}
