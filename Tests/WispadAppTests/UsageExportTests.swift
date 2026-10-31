import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Consommation › Derniers appels : ce qui sort d'une copie ou d'un export. Un CSV que relit un tableur, une ligne
/// lisible par appel, et jamais de texte dicté ni de texte inattendu à la place d'un nom de modèle.
@MainActor
struct UsageExportTests {
    /// 31 octobre 2026, 12:40:01 UTC.
    private let base = Date(timeIntervalSince1970: 1_793_450_401)
    private let utc = TimeZone(secondsFromGMT: 0)!

    private var calls: [UsageEvent] {
        [
            UsageEvent(id: "a", createdAt: base, api: .openAIFile, model: "gpt-transcribe", audioSeconds: 12,
                       costUSD: 0.000416666, latencyMs: 450,
                       fallback: APIFallback(fromAPI: .xaiFile, stage: .transcription, reason: .requestFailed)),
            UsageEvent(id: "b", createdAt: base.addingTimeInterval(-3), api: .xaiFile, model: "fixture", costUSD: nil,
                       latencyMs: 2_500, succeeded: false, failureCause: .timeout),
            UsageEvent(id: "c", createdAt: base.addingTimeInterval(-60), api: .deepSeekCleanup, model: "deepseek-flash",
                       tokens: TokenUsage(input: 370, cachedInput: 4_480, output: 30), costUSD: 0.00014, latencyMs: 413),
            UsageEvent(id: "d", createdAt: base.addingTimeInterval(-120), api: .typesafeJudge, model: "jev-latest",
                       costUSD: nil, latencyMs: 90, succeeded: false, failureCause: .keyRejected),
            UsageEvent(id: "e", createdAt: base.addingTimeInterval(-180), api: .openAICleanup,
                       model: "Bonjour, voici une phrase \"dictée\"", costUSD: 0.001, latencyMs: 800)
        ]
    }

    @Test func csvHasOneHeaderAndOneWellFormedRowPerCall() throws {
        let text = UsageExport.csv(calls, timeZone: utc)
        #expect(text.hasSuffix("\r\n"))
        let rows = parseCSV(text)
        #expect(rows.count == calls.count + 1)
        #expect(rows.first == UsageExport.csvHeader)
        #expect(rows.allSatisfy { $0.count == UsageExport.csvHeader.count })
        #expect(rows[1] == ["2026-10-31 12:40:01", "OpenAI", "Transcription du fichier", "gpt-transcribe", "réussi", "",
                            "xAI", "échec ou délai dépassé", "450", "12", "", "", "", "0.00041667"])
        #expect(rows[2] == ["2026-10-31 12:39:58", "xAI", "Transcription du fichier", "fixture", "échec",
                            "pas de réponse à temps", "", "", "2500", "0", "", "", "", ""])
        #expect(rows[3] == ["2026-10-31 12:39:01", "DeepSeek", "Correction", "deepseek-flash", "réussi", "", "", "",
                            "413", "", "370", "4480", "30", "0.00014"])
        // Compteurs et coût inconnus : vides, jamais des zéros certains.
        #expect(rows[4] == ["2026-10-31 12:38:01", "Jev", "Dictionnaire", "jev-latest", "échec", "clé refusée", "", "",
                            "90", "", "", "", "", ""])
        // Un texte à la place du nom de modèle ne sort pas.
        #expect(rows[5][3] == "")
        #expect(!text.contains("Bonjour"))
    }

    @Test func fieldsAreQuotedOnlyWhenTheyMustBe() {
        #expect(UsageExport.csvField("OpenAI") == "OpenAI")
        #expect(UsageExport.csvField("limit, or credit") == "\"limit, or credit\"")
        #expect(UsageExport.csvField("a \"b\"") == "\"a \"\"b\"\"\"")
        #expect(UsageExport.csvField("a\r\nb") == "\"a\r\nb\"")
        #expect(parseCSV(UsageExport.csvField("a, \"b\"\nc") + "\r\n") == [["a, \"b\"\nc"]])
    }

    @Test func onlyModelNamesLeaveAsModelNames() {
        for name in ["gpt-5.4-mini", "grok-voice-transcribe-2.0", "qwen2.5:7b", "org/model-7B@q4_k_m", "jev-1.13.0"] {
            #expect(UsageExport.model(name) == name)
        }
        for text in ["", "=HYPERLINK(\"x\")", "-1+2", "@cmd", "Bonjour tout le monde", "ligne\nsuivante", "modèle",
                     String(repeating: "a", count: 81)] {
            #expect(UsageExport.model(text) == nil, "\(text)")
        }
    }

    @Test func numbersUseAPointWithoutUselessZeros() {
        #expect(UsageExport.decimal(0.000416666, digits: 8) == "0.00041667")
        #expect(UsageExport.decimal(12, digits: 1) == "12")
        #expect(UsageExport.decimal(12.25, digits: 1) == "12.2" || UsageExport.decimal(12.25, digits: 1) == "12.3")
        #expect(UsageExport.decimal(0, digits: 8) == "0")
        #expect(UsageExport.decimal(.nan, digits: 2) == "")
        #expect(UsageExport.decimal(.infinity, digits: 2) == "")
    }

    @Test func readableLinesSayWhatHappenedForEachCall() {
        let relay = UsageExport.line(calls[0])
        #expect(relay.contains("OpenAI · Transcription du fichier · gpt-transcribe"))
        #expect(relay.contains(MoneyFormat.usd(0.000416666)))
        #expect(relay.hasSuffix("Secours après xAI · échec ou délai dépassé"))
        let failure = UsageExport.line(calls[1])
        #expect(failure.contains("coût inconnu"))
        #expect(failure.hasSuffix("Échec · pas de réponse à temps"))
        #expect(!UsageExport.line(calls[4]).contains("Bonjour"))

        let table = UsageExport.text(calls, period: .today, incomplete: false)
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Titre, ligne vide, un appel par ligne, puis la fin du texte.
        #expect(lines.count == calls.count + 3)
        #expect(lines[0].hasPrefix("Appels de Wispad, aujourd'hui : 5 appels, ≥ "))
        #expect(Array(lines[2..<(2 + calls.count)]) == calls.map(UsageExport.line))
    }

    @Test func fileNameSaysThePeriodAndTheDay() {
        #expect(UsageExport.fileName(period: .days7, now: base, timeZone: utc) == "Wispad-appels-7-jours-2026-10-31.csv")
        #expect(UsageExport.fileName(period: .all, now: base, timeZone: utc) == "Wispad-appels-tout-2026-10-31.csv")
    }

    /// Le parcours réel : une dictée enregistrée, ses appels comptés, puis toutes les sorties. Rien de dicté n'y figure,
    /// ni le texte d'une réponse glissé à la place du nom de modèle.
    @Test func copiesAndExportsNeverCarryDictatedText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-usage-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var dependencies = AppDependencies()
        dependencies.copyText = { _ in }
        dependencies.loadKey = { _ in nil }
        dependencies.refreshKeys = { false }
        let model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
        model.overlay.displaysPanel = false
        try model.store.insert(DictationRecord(
            finalText: "texte-dicte-secret-sentinel", rawText: "brut-dicte-secret-sentinel", durationSeconds: 2,
            wordCount: 1, provider: "xai", model: "grok-voice-transcribe-2.0", targetApp: "app-secret-sentinel",
            targetBundle: "bundle.secret.sentinel", insertionStatus: InsertionStatus.inserted.rawValue
        ))
        model.recordUsage(UsageEvent(api: .xaiStreaming, model: "grok-voice-transcribe-2.0", audioSeconds: 2, costUSD: 0.0001))
        model.recordUsage(UsageEvent(api: .deepSeekCleanup, model: "réponse secret-sentinel glissée",
                                     tokens: TokenUsage(input: 10, output: 2), costUSD: 0.00001))
        model.reload()
        let events = model.usageEvents(for: .all)
        #expect(events.count == 2)
        let outputs = [UsageExport.csv(events), UsageExport.text(events, period: .all, incomplete: false)] + events.map(UsageExport.line)
        for output in outputs {
            #expect(!output.contains("secret-sentinel"))
            #expect(!output.contains(directory.path))
        }
    }
}

/// Lecture RFC 4180 : champs entre guillemets (guillemets doublés), virgules, fins de ligne CRLF.
private func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = String.UnicodeScalarView()
    var quoted = false
    let scalars = Array(text.unicodeScalars)
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        if quoted {
            if scalar == "\"" {
                if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    quoted = false
                }
            } else {
                field.append(scalar)
            }
        } else if scalar == "\"" {
            quoted = true
        } else if scalar == "," {
            row.append(String(field))
            field = String.UnicodeScalarView()
        } else if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
            row.append(String(field))
            rows.append(row)
            row = []
            field = String.UnicodeScalarView()
            index += 1
        } else {
            field.append(scalar)
        }
        index += 1
    }
    if !field.isEmpty || !row.isEmpty {
        row.append(String(field))
        rows.append(row)
    }
    return rows
}
