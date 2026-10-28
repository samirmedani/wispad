import Foundation

/// Fichier de configuration de Wispad, exporté sur un appareil et importé sur un autre : les réglages et le
/// dictionnaire, jamais les clés API, l'historique ni l'audio. Un JSON lisible, le même pour toutes les plateformes ;
/// un champ inconnu (version plus récente, autre plateforme) est ignoré à la lecture, jamais une erreur.
public struct ConfigurationFile: @unchecked Sendable {
    public static let format = "wispad-configuration"
    public static let formatVersion = 1

    /// Appareil et version de l'app qui ont exporté le fichier.
    public struct Origin: Equatable, Sendable {
        public var app: String
        public var version: String
        public var build: String
        public var platform: String
        public var system: String

        public init(app: String = "Wispad", version: String, build: String, platform: String, system: String) {
            self.app = app
            self.version = version
            self.build = build
            self.platform = platform
            self.system = system
        }
    }

    /// Un terme du dictionnaire avec son histoire : quand il est entré, qui l'a ajouté, ce qui avait été entendu.
    public struct Term: Equatable, Sendable {
        public var term: String
        public var addedAt: Date?
        public var origin: DictionaryOrigin
        public var heard: String?
        public var source: DictionarySource?

        public init(term: String, addedAt: Date? = nil, origin: DictionaryOrigin = .unknown, heard: String? = nil,
                    source: DictionarySource? = nil) {
            self.term = term
            self.addedAt = addedAt
            self.origin = origin
            self.heard = heard
            self.source = source
        }

        public init(_ entry: DictionaryEntry) {
            self.init(term: entry.term, addedAt: entry.createdAt, origin: entry.origin, heard: entry.heard, source: entry.source)
        }
    }

    public enum ReadError: Error, Equatable {
        /// Pas un objet JSON.
        case unreadable
        /// Un JSON, mais pas une configuration de Wispad.
        case notAConfiguration
    }

    public var formatVersion: Int
    public var exportedAt: Date
    public var origin: Origin
    /// Lignes lisibles par une personne : date, contenu, ce qui n'est jamais inclus. Ignorées à l'import.
    public var notes: [String]
    /// Réglages, objet JSON tel que l'app les enregistre (clé par clé).
    public var settingsJSON: Data
    public var dictionary: [Term]

    public init(exportedAt: Date, origin: Origin, notes: [String], settings: [String: Any], dictionary: [Term],
                formatVersion: Int = ConfigurationFile.formatVersion) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.origin = origin
        self.notes = notes
        self.settingsJSON = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.dictionary = dictionary
    }

    public var settings: [String: Any] {
        (try? JSONSerialization.jsonObject(with: settingsJSON)) as? [String: Any] ?? [:]
    }

    /// Fichier plus récent que cette version : il se lit quand même, ses champs inconnus sont ignorés.
    public var isNewerFormat: Bool { formatVersion > Self.formatVersion }

    // MARK: Écriture

    public func encoded() throws -> Data {
        let object: [String: Any] = [
            "format": Self.format,
            "formatVersion": formatVersion,
            "exportedAt": Self.timestamp(exportedAt),
            "exportedFrom": ["app": origin.app, "version": origin.version, "build": origin.build,
                             "platform": origin.platform, "system": origin.system],
            "notes": notes,
            "settings": settings,
            "dictionary": dictionary.map(Self.object(for:)),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func object(for term: Term) -> [String: Any] {
        var object: [String: Any] = ["term": term.term]
        if let addedAt = term.addedAt { object["addedAt"] = timestamp(addedAt) }
        if let origin = term.origin.storedValue { object["origin"] = origin }
        if let judge = term.origin.judge {
            object["judgeProvider"] = judge.provider
            object["judgeModel"] = judge.model
        }
        if let heard = term.heard, !heard.isEmpty { object["heard"] = heard }
        if let source = term.source { object["source"] = source.rawValue }
        return object
    }

    // MARK: Lecture

    public static func read(_ data: Data) throws -> ConfigurationFile {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ReadError.unreadable }
        guard object["format"] as? String == format else { throw ReadError.notAConfiguration }
        let from = object["exportedFrom"] as? [String: Any] ?? [:]
        let origin = Origin(app: from["app"] as? String ?? "Wispad", version: from["version"] as? String ?? "",
                            build: from["build"] as? String ?? "", platform: from["platform"] as? String ?? "",
                            system: from["system"] as? String ?? "")
        let terms = (object["dictionary"] as? [Any] ?? []).compactMap { item -> Term? in
            guard let item = item as? [String: Any], let term = (item["term"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty else { return nil }
            return Term(
                term: term,
                addedAt: (item["addedAt"] as? String).flatMap(date(from:)),
                origin: DictionaryOrigin(stored: item["origin"] as? String, provider: item["judgeProvider"] as? String,
                                         model: item["judgeModel"] as? String),
                heard: item["heard"] as? String,
                source: (item["source"] as? String).flatMap(DictionarySource.init(rawValue:))
            )
        }
        return ConfigurationFile(
            exportedAt: (object["exportedAt"] as? String).flatMap(date(from:)) ?? .distantPast,
            origin: origin,
            notes: object["notes"] as? [String] ?? [],
            settings: object["settings"] as? [String: Any] ?? [:],
            dictionary: terms,
            formatVersion: object["formatVersion"] as? Int ?? 1
        )
    }

    /// Termes du fichier absents du dictionnaire actuel (à la casse près), sans doublon, dans l'ordre du fichier.
    public func newTerms(comparedTo existing: [String]) -> [Term] {
        var known = Set(existing.map { $0.lowercased() })
        return dictionary.filter { known.insert($0.term.lowercased()).inserted }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
