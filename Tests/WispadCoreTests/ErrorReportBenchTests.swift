import Foundation
import XCTest
@testable import WispadCore

/// Banc des erreurs signalées : rejoue l'audio de chaque dictée signalée dans la chaîne réelle (fichier xAI, puis
/// correction) et compte les mots qui diffèrent de ce qui a vraiment été dit, avant (texte collé à l'époque) et
/// maintenant. Réseau et payant (quelques centimes) : seulement via scripts/report-bench.sh, clés de test.
final class ErrorReportBenchTests: XCTestCase {
    struct Outcome: Codable {
        var id: String
        var expected: String
        var before: String
        var heard: String
        var final: String
        var wrongBefore: Int
        var wrongHeard: Int
        var wrongAfter: Int
    }

    struct Report: Codable {
        var label: String
        var outcomes: [Outcome]
    }

    func testReportedErrors() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1" && env["WISPAD_REPORT_BENCH"] == "1", "Banc réseau réservé à scripts/report-bench.sh.")
        let xaiKey = env["WISPAD_LIVE_XAI_KEY"] ?? ""
        try XCTSkipUnless(!xaiKey.isEmpty, "Clé xAI de test absente.")
        let support = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Wispad/benchmarks")
        let reports = ErrorReportArchive.all(in: support.appendingPathComponent(ErrorReportArchive.folderName))
            .filter { $0.audio != nil }
        try XCTSkipIf(reports.isEmpty, "Aucune erreur signalée avec son audio.")
        let label = env["BENCH_LABEL"] ?? "sans-nom"

        var outcomes: [Outcome] = []
        for (report, audio) in reports {
            let language = DictationLanguage(rawValue: report.language) ?? .french
            let speech = SpeechRequest(
                provider: .xai, liveModel: "grok-voice-transcribe-2.0", fileModel: "grok-voice-transcribe-2.0",
                apiKey: xaiKey, language: language, keyterms: RecognitionHints.keyterms(dictionary: [], context: []),
                prompt: CorrectionPrompt.recognitionPrompt(appName: nil, nearby: nil, language: language),
                cleanupKey: env["WISPAD_LIVE_DEEPSEEK_KEY"], fallbackKey: env["WISPAD_LIVE_OPENAI_KEY"]
            )
            var heard = ""
            do { heard = try await BatchTranscriber.transcribe(fileURL: audio!, request: speech) } catch { heard = "" }
            let prepared = FranglaisNormalizer.normalize(heard.trimmingCharacters(in: .whitespacesAndNewlines))
            let request = CorrectionRequest(transcript: prepared, language: language)
            let final = FranglaisNormalizer.normalize(await TextCleaner.clean(transcript: prepared, request: request, speech: speech, enabled: true).text)
            let outcome = Outcome(
                id: report.dictationID, expected: report.expected, before: report.written, heard: prepared, final: final,
                wrongBefore: TranscriptEquivalence.differingWords(report.expected, report.written),
                wrongHeard: TranscriptEquivalence.differingWords(report.expected, prepared),
                wrongAfter: TranscriptEquivalence.differingWords(report.expected, final)
            )
            outcomes.append(outcome)
            print("BANC \(report.dictationID.prefix(8)) | mots faux : avant \(outcome.wrongBefore), entendu \(outcome.wrongHeard), maintenant \(outcome.wrongAfter)")
        }
        let folder = support.appendingPathComponent("signalements-rapports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Report(label: label, outcomes: outcomes)).write(to: folder.appendingPathComponent("\(label).json"))
        let fixed = outcomes.filter { $0.wrongAfter < $0.wrongBefore }.count
        let worse = outcomes.filter { $0.wrongAfter > $0.wrongBefore }.count
        print("BANC-RESUME \(label) : \(outcomes.count) dictées, mots faux avant \(outcomes.map(\.wrongBefore).reduce(0, +)), maintenant \(outcomes.map(\.wrongAfter).reduce(0, +)) ; mieux \(fixed), pire \(worse)")
    }
}
