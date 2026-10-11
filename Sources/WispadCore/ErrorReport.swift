import Foundation

/// Dictée signalée comme mal écrite : ce qui a vraiment été dit, ce que Wispad a entendu puis écrit, et une copie de
/// l'audio. Tout reste sur le Mac ; le banc d'essai (`scripts/report-bench.sh`) rejoue ces audios pour mesurer
/// qu'un changement corrige une erreur sans en créer d'autres. Rien n'est journalisé ni envoyé.
public struct ErrorReport: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var dictationID: String
    public var dictatedAt: Date
    /// Ce qui a été dit, tapé par l'utilisateur.
    public var expected: String
    /// Transcription retenue, avant correction.
    public var heard: String
    /// Texte collé.
    public var written: String
    /// Autre écoute (flux en direct) quand le fichier retenu disait autre chose.
    public var alternative: String?
    public var language: String
    public var provider: String
    public var model: String
    public var durationSeconds: Double
    /// Nom du fichier audio copié à côté du signalement, s'il existait encore.
    public var audioFile: String?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        dictationID: String,
        dictatedAt: Date,
        expected: String,
        heard: String,
        written: String,
        alternative: String? = nil,
        language: String,
        provider: String,
        model: String,
        durationSeconds: Double,
        audioFile: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.dictationID = dictationID
        self.dictatedAt = dictatedAt
        self.expected = expected
        self.heard = heard
        self.written = written
        self.alternative = alternative
        self.language = language
        self.provider = provider
        self.model = model
        self.durationSeconds = durationSeconds
        self.audioFile = audioFile
    }
}

/// Dossier des signalements : un sous-dossier par dictée, `report.json` et l'audio copié.
public enum ErrorReportArchive {
    public static let folderName = "signalements"
    static let reportName = "report.json"

    /// Enregistre (ou remplace) le signalement d'une dictée. L'audio est copié : la purge de l'historique ne le
    /// touche pas. Le dossier est lisible par le seul utilisateur.
    @discardableResult
    public static func save(_ report: ErrorReport, audio: URL?, in directory: URL) throws -> ErrorReport {
        let fileManager = FileManager.default
        let folder = directory.appendingPathComponent(report.dictationID, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var saved = report
        if let audio, fileManager.fileExists(atPath: audio.path) {
            let name = "audio." + (audio.pathExtension.isEmpty ? "wav" : audio.pathExtension)
            let target = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: target.path) { try fileManager.copyItem(at: audio, to: target) }
            saved.audioFile = name
        } else if let previous = try? load(folder: folder), let file = previous.audioFile,
                  fileManager.fileExists(atPath: folder.appendingPathComponent(file).path) {
            saved.audioFile = file
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = folder.appendingPathComponent(reportName)
        try encoder.encode(saved).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return saved
    }

    /// Signalements lisibles, du plus ancien au plus récent, avec l'adresse de leur audio s'il existe.
    public static func all(in directory: URL) -> [(report: ErrorReport, audio: URL?)] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let report = try? load(folder: folder) else { return nil }
            let audio = report.audioFile.map { folder.appendingPathComponent($0) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            return (report, audio)
        }
        .sorted { $0.report.createdAt < $1.report.createdAt }
    }

    public static func report(for dictationID: String, in directory: URL) -> ErrorReport? {
        try? load(folder: directory.appendingPathComponent(dictationID, isDirectory: true))
    }

    private static func load(folder: URL) throws -> ErrorReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ErrorReport.self, from: Data(contentsOf: folder.appendingPathComponent(reportName)))
    }
}
