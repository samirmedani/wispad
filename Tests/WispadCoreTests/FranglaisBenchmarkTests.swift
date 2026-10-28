import Foundation
import XCTest
@testable import WispadCore

/// Banc franglais : rejoue des audios dans la même chaîne que l'app (flux xAI en direct, puis correction)
/// et vérifie, phrase par phrase, les termes attendus et interdits, avant et après correction.
/// Un cas avec `transcript` saute l'audio : cette transcription brute part directement à la correction
/// (mots mal entendus, tics, citations, lettres épelées, dates et heures, nombres mal entendus, termes techniques
/// anglais entendus comme des mots français, deux écoutes qui divergent).
/// Réseau et payant (quelques centimes) : ne tourne qu'avec WISPAD_LIVE_TESTS=1, via scripts/franglais-bench.sh.
///
/// Variables : BENCH_LABEL (nom du rapport), BENCH_KEYTERMS=none (sans vocabulaire), BENCH_LANGUAGE=auto
/// (sans indice de langue), BENCH_CLEANUP=off (sans correction), BENCH_ONLY=préfixes d'identifiant séparés par
/// des virgules (h,r,g,l,e,d,n,k,j,a : les cas de correction seule), BENCH_REAL_DIR (dossier d'enregistrements réels avec
/// cases.json, hors Git).
final class FranglaisBenchmarkTests: XCTestCase {
    struct Case: Decodable {
        var id: String
        var text: String?
        var audio: String?
        /// Transcription brute donnée telle quelle à la correction, sans audio ni reconnaissance.
        var transcript: String?
        /// Dictées précédentes de la même app, envoyées comme contexte à la correction.
        var previous: [String]?
        /// Conversation visible dans la fenêtre, envoyée comme contexte à la correction.
        var window: String?
        /// Autre écoute du même audio (le flux en direct), donnée à la correction comme dans l'app.
        var alternative: String?
        /// Langue de ce cas (fr, en) ; sinon celle du banc pour la reconnaissance, le français pour la correction.
        var language: DictationLanguage?
        /// Format des dates et des heures de ce cas ; sinon celui d'une nouvelle installation.
        var dateFormat: DictationDateFormat?
        var required: [String]
        var forbidden: [String]
        var control: Bool?
    }

    struct CaseFile: Decodable { var cases: [Case] }

    struct Outcome: Codable {
        var id: String
        var control: Bool
        var raw: String
        var final: String
        var rawMissing: [String]
        var finalMissing: [String]
        var rawForbidden: [String]
        var finalForbidden: [String]
        var required: Int
    }

    struct Report: Codable {
        var label: String
        var settings: [String: String]
        var outcomes: [Outcome]
    }

    func testFranglaisBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WISPAD_LIVE_TESTS"] == "1" && env["WISPAD_FRANGLAIS"] == "1", "Banc réseau réservé à scripts/franglais-bench.sh.")
        let xaiKey = env["WISPAD_LIVE_XAI_KEY"] ?? ""
        try XCTSkipUnless(!xaiKey.isEmpty, "Clé xAI absente.")
        let deepSeekKey = env["WISPAD_LIVE_DEEPSEEK_KEY"]
        let openAIKey = env["WISPAD_LIVE_OPENAI_KEY"]
        let label = env["BENCH_LABEL"] ?? "sans-nom"
        let useHints = env["BENCH_KEYTERMS"] != "none"
        let language: DictationLanguage = env["BENCH_LANGUAGE"] == "auto" ? .auto : .french
        let cleanup = env["BENCH_CLEANUP"] != "off"
        let only = (env["BENCH_ONLY"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // DeepSeek muet : on part directement au relais, comme l'app après deux échecs.
        var deepSeekDown = false
        if cleanup, let key = deepSeekKey, !key.isEmpty {
            deepSeekDown = (await HealthProbe.deepSeek(key: key))?.succeeded != true
        }

        var sets: [(URL, [Case])] = []
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/franglais")
        sets.append((fixtures.appendingPathComponent("audio"), try load(fixtures.appendingPathComponent("cases.json"))))
        let realDir = URL(fileURLWithPath: env["BENCH_REAL_DIR"]
            ?? NSHomeDirectory() + "/Library/Application Support/Wispad/benchmarks/franglais/voix-reelle")
        if FileManager.default.fileExists(atPath: realDir.appendingPathComponent("cases.json").path) {
            sets.append((realDir, try load(realDir.appendingPathComponent("cases.json"))))
        }

        var outcomes: [Outcome] = []
        for (directory, cases) in sets {
            for item in cases where only.isEmpty || only.contains(where: { item.id.hasPrefix($0) }) {
                let speech = SpeechRequest(
                    provider: .xai,
                    liveModel: "grok-voice-transcribe-2.0",
                    fileModel: "grok-voice-transcribe-2.0",
                    apiKey: xaiKey,
                    language: item.language ?? language,
                    keyterms: useHints ? Self.recognitionHints() : [],
                    prompt: CorrectionPrompt.recognitionPrompt(appName: nil, nearby: nil),
                    cleanupKey: deepSeekKey,
                    fallbackKey: openAIKey,
                    cleanupPrimaryDown: deepSeekDown
                )
                var raw = ""
                if let transcript = item.transcript {
                    raw = transcript
                } else {
                    let audio = directory.appendingPathComponent(item.audio ?? "\(item.id).wav")
                    let pcm = try Self.pcm(fromWAV: Data(contentsOf: audio))
                    do { raw = try await stream(pcm, speech: speech) } catch { raw = "<échec : \(error.localizedDescription)>" }
                }
                let prepared = Self.prepare(raw)
                var final = prepared
                if cleanup {
                    var request = CorrectionRequest(transcript: prepared, dictionary: [], previousDictations: item.previous ?? [],
                                                    windowText: item.window, language: item.language ?? .french)
                    request.dateFormat = item.dateFormat ?? DictationDateFormat()
                    request.alternativeTranscript = item.alternative.map(Self.prepare)
                    final = Self.finish(await TextCleaner.clean(transcript: prepared, request: request, speech: speech, enabled: true).text)
                }
                let outcome = Outcome(
                    id: item.id,
                    control: item.control ?? false,
                    raw: raw,
                    final: final,
                    rawMissing: item.required.filter { !Self.matches($0, raw) },
                    finalMissing: item.required.filter { !Self.matches($0, final) },
                    rawForbidden: item.forbidden.filter { Self.matches($0, raw) },
                    finalForbidden: item.forbidden.filter { Self.matches($0, final) },
                    required: item.required.count
                )
                outcomes.append(outcome)
                print("BANC \(item.id) | manque \(outcome.finalMissing) | interdit \(outcome.finalForbidden)")
            }
        }

        let report = Report(label: label, settings: [
            "keyterms": useHints ? "vocabulaire" : "aucun",
            "language": language.rawValue, "extra": env["BENCH_EXTRA_KEYTERMS"] ?? "",
            "cleanup": cleanup ? (deepSeekDown ? "relais OpenAI (DeepSeek muet)" : "DeepSeek") : "aucune",
        ], outcomes: outcomes)
        let reports = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Wispad/benchmarks/franglais/rapports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reports.appendingPathComponent("\(label).json"))
        print(Self.summary(report))
    }

    // MARK: - Points d'accroche de la chaîne de l'app

    /// Mots-clés envoyés à la reconnaissance, comme l'app avec un dictionnaire vide.
    static func recognitionHints() -> [String] {
        // BENCH_EXTRA_KEYTERMS=push,fix : essai de mots-clés supplémentaires, ajoutés comme le dictionnaire.
        let extra = (ProcessInfo.processInfo.environment["BENCH_EXTRA_KEYTERMS"] ?? "").split(separator: ",").map(String.init)
        return RecognitionHints.keyterms(dictionary: extra, context: [])
    }

    /// Retouches appliquées au texte brut avant correction.
    static func prepare(_ raw: String) -> String { FranglaisNormalizer.normalize(raw) }

    /// Retouches appliquées au texte corrigé.
    static func finish(_ text: String) -> String { FranglaisNormalizer.normalize(text) }

    // MARK: - Outils

    private func load(_ url: URL) throws -> [Case] {
        try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: url)).cases
    }

    /// Rejoue l'audio dans une session en direct, en temps réel comme le micro (plus vite, xAI se trompe davantage).
    private func stream(_ pcm: Data, speech: SpeechRequest) async throws -> String {
        let session = LiveSpeechSession(request: speech)
        try await session.start()
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 3_200, pcm.count)
            session.send(pcm.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let finish = try await session.finish()
        session.cancel()
        return finish.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pcm(fromWAV data: Data) throws -> Data {
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            if id == "data" { return data.subdata(in: (offset + 8)..<min(data.count, offset + 8 + size)) }
            offset += 8 + size + (size % 2)
        }
        throw NSError(domain: "banc", code: 1, userInfo: [NSLocalizedDescriptionKey: "WAV sans bloc data"])
    }

    static func matches(_ term: String, _ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "\u{00A0}", with: " ")
        if term.hasPrefix("re:") {
            guard let regex = try? NSRegularExpression(pattern: String(term.dropFirst(3))) else { return false }
            return regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
        }
        return normalized.contains(term)
    }

    static func summary(_ report: Report) -> String {
        let tech = report.outcomes.filter { !$0.control }
        let controls = report.outcomes.filter(\.control)
        let total = tech.reduce(0) { $0 + $1.required }
        let rawFound = total - tech.reduce(0) { $0 + $1.rawMissing.count }
        let finalFound = total - tech.reduce(0) { $0 + $1.finalMissing.count }
        let forbidden = tech.reduce(0) { $0 + $1.finalForbidden.count }
        let controlsOK = controls.filter { $0.finalMissing.isEmpty && $0.finalForbidden.isEmpty }.count
        return """
        BANC-RESUME \(report.label) \(report.settings)
        BANC-RESUME termes trouvés : brut \(rawFound)/\(total), final \(finalFound)/\(total) ; termes interdits au final : \(forbidden) ; phrases témoins intactes : \(controlsOK)/\(controls.count)
        """
    }
}
