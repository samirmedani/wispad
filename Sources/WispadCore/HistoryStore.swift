import Foundation
import SQLite3

public struct DictationRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var finalText: String
    public var rawText: String
    public var durationSeconds: Double
    public var wordCount: Int
    public var provider: String
    public var model: String
    public var targetApp: String?
    public var targetBundle: String?
    public var usageCategory: String?
    public var insertionStatus: String
    public var audioPath: String?
    public var audioExpiresAt: Date?
    /// Autre écoute du même audio (le flux en direct) quand le fichier retenu dit autre chose. Reste sur le Mac,
    /// comme le texte : elle sert à comprendre un désaccord et au banc des erreurs signalées.
    public var alternativeText: String?
    /// Appareil d'origine de la dictée (rempli pour la synchro multiplateforme ; l'audio reste local sur cet appareil).
    public var sourceDeviceID: String?
    public var sourceDeviceName: String?
    public var sourceDevicePlatform: String?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        finalText: String,
        rawText: String,
        durationSeconds: Double,
        wordCount: Int,
        provider: String,
        model: String,
        targetApp: String? = nil,
        targetBundle: String? = nil,
        usageCategory: String? = nil,
        insertionStatus: String,
        audioPath: String? = nil,
        audioExpiresAt: Date? = nil,
        alternativeText: String? = nil,
        sourceDeviceID: String? = nil,
        sourceDeviceName: String? = nil,
        sourceDevicePlatform: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.finalText = finalText
        self.rawText = rawText
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.provider = provider
        self.model = model
        self.targetApp = targetApp
        self.targetBundle = targetBundle
        self.usageCategory = usageCategory
        self.insertionStatus = insertionStatus
        self.audioPath = audioPath
        self.audioExpiresAt = audioExpiresAt
        self.alternativeText = alternativeText
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.sourceDevicePlatform = sourceDevicePlatform
    }

    /// Vrai si cette dictée a été enregistrée sur un autre appareil (synchro texte seul, audio resté là-bas).
    public func isFromRemoteDevice(localDeviceID: String?) -> Bool {
        guard let source = sourceDeviceID, !source.isEmpty else { return false }
        return source != localDeviceID
    }
}

/// Note de réunion (style Granola) : notes rapides prises par l'utilisateur + transcription + synthèse IA.
public struct MeetingRecord: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var durationSeconds: Double
    public var userNotes: String
    public var rawTranscript: String
    public var enhancedNotes: String
    public var sourceDeviceID: String?
    public var sourceDeviceName: String?
    public var sourceDevicePlatform: String?

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        durationSeconds: Double = 0,
        userNotes: String = "",
        rawTranscript: String = "",
        enhancedNotes: String = "",
        sourceDeviceID: String? = nil,
        sourceDeviceName: String? = nil,
        sourceDevicePlatform: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.durationSeconds = durationSeconds
        self.userNotes = userNotes
        self.rawTranscript = rawTranscript
        self.enhancedNotes = enhancedNotes
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceName = sourceDeviceName
        self.sourceDevicePlatform = sourceDevicePlatform
    }
}

public struct DictionaryEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var term: String
    public var createdAt: Date
    /// Qui a ajouté le mot ; `.unknown` pour un mot d'avant le suivi de l'origine.
    public var origin: DictionaryOrigin
    /// « Oui » dans la bulle « Le garder ? » : l'utilisateur a gardé ce mot appris. L'origine ne change pas.
    public var confirmedAt: Date?
    /// Ce que la reconnaissance avait écrit à la place du terme (« revenu quatre » pour « RevenueCat »), quand le
    /// terme vient d'une correction ; nil sinon.
    public var heard: String?
    /// D'où vient le terme, en plus de qui l'a décidé ; nil pour un mot tapé ou d'avant ce suivi.
    public var source: DictionarySource?

    public init(id: String = UUID().uuidString, term: String, createdAt: Date = Date(),
                origin: DictionaryOrigin = .unknown, confirmedAt: Date? = nil,
                heard: String? = nil, source: DictionarySource? = nil) {
        self.id = id
        self.term = term
        self.createdAt = createdAt
        self.origin = origin
        self.confirmedAt = confirmedAt
        self.heard = heard
        self.source = source
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.yatofix.wispad.sqlite")
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Les appels antérieurs à cette date ne permettent pas de déduire les bascules.
    public private(set) var fallbackTrackingStartedAt = Date()
    /// Les appels ratés antérieurs à cette date n'ont pas de cause enregistrée.
    public private(set) var failureCauseTrackingStartedAt = Date()

    public init(path: String) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &connection, flags, nil) != SQLITE_OK {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "ouverture impossible"
            sqlite3_close(connection)
            throw StoreError.message(message)
        }
        db = connection
        if path != ":memory:", !path.isEmpty {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            for suffix in ["-wal", "-shm"] {
                let sidecar = path + suffix
                if FileManager.default.fileExists(atPath: sidecar) {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar)
                }
            }
        }
        sqlite3_busy_timeout(connection, 2_000)
        try execute("PRAGMA journal_mode = WAL;")
        if path != ":memory:", !path.isEmpty {
            for suffix in ["-wal", "-shm"] {
                let sidecar = path + suffix
                if FileManager.default.fileExists(atPath: sidecar) {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar)
                }
            }
        }
        try execute("PRAGMA foreign_keys = ON;")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS dictations (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                final_text TEXT NOT NULL,
                raw_text TEXT NOT NULL,
                duration_seconds REAL NOT NULL,
                word_count INTEGER NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                target_app TEXT,
                target_bundle TEXT,
                usage_category TEXT,
                insertion_status TEXT NOT NULL,
                audio_path TEXT,
                audio_expires_at REAL
            );
            """
        )
        let dictationColumns = Set(try query("PRAGMA table_info(dictations);") { column(1, $0) })
        let extraDictationColumns = [
            ("alternative_text", "TEXT"),
            ("source_device_id", "TEXT"),
            ("source_device_name", "TEXT"),
            ("source_device_platform", "TEXT"),
            ("updated_at", "REAL"),
        ]
        for (name, type) in extraDictationColumns where !dictationColumns.contains(name) {
            try execute("ALTER TABLE dictations ADD COLUMN \(name) \(type);")
        }
        try execute("CREATE INDEX IF NOT EXISTS dictations_created ON dictations(created_at DESC);")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                duration_seconds REAL NOT NULL,
                user_notes TEXT NOT NULL,
                raw_transcript TEXT NOT NULL,
                enhanced_notes TEXT NOT NULL,
                source_device_id TEXT,
                source_device_name TEXT,
                source_device_platform TEXT
            );
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS meetings_created ON meetings(created_at DESC);")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_peers (
                device_id TEXT PRIMARY KEY,
                last_sequence INTEGER NOT NULL,
                updated_at REAL NOT NULL
            );
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_tombstones (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                deleted_at REAL NOT NULL,
                PRIMARY KEY (entity_type, entity_id)
            );
            """
        )
        // Boîte d'envoi locale : suit uniquement les mutations locales à pousser (évite toute boucle d'écho
        // et toute perte par dérive d'horloge, sans toucher au schéma de `dictionary`).
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_outbox (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                PRIMARY KEY (entity_type, entity_id)
            );
            """
        )
        // Index plein texte FTS5 pour des recherches instantanées même sur des milliers de dictées.
        try? execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS dictations_fts USING fts5(
                id UNINDEXED,
                final_text,
                raw_text,
                alternative_text,
                tokenize='unicode61 remove_diacritics 2'
            );
            """
        )
        // Les détails se chargent à la demande ; la liste des dictées ne lit pas cette table.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS dictation_traces (
                id TEXT PRIMARY KEY,
                dictation_id TEXT REFERENCES dictations(id) ON DELETE CASCADE,
                created_at REAL NOT NULL,
                payload TEXT NOT NULL
            );
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS dictation_traces_recent ON dictation_traces(created_at DESC, id DESC);")
        try execute("CREATE INDEX IF NOT EXISTS dictation_traces_dictation ON dictation_traces(dictation_id, created_at DESC, id DESC);")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS dictionary (
                id TEXT PRIMARY KEY,
                term TEXT NOT NULL UNIQUE COLLATE NOCASE,
                created_at REAL NOT NULL,
                origin TEXT,
                judge_provider TEXT,
                judge_model TEXT,
                confirmed_at REAL,
                heard TEXT,
                source TEXT
            );
            """
        )
        // Origine des mots : les colonnes s'ajoutent aux anciennes bases sans toucher aux mots, et restent NULL sur
        // les mots d'avant ce suivi (origine inconnue) : l'historique ne relie aucun appel de jugement à un mot,
        // rien ne permet de la retrouver de façon sûre.
        let dictionaryColumns = Set(try query("PRAGMA table_info(dictionary);") { column(1, $0) })
        let originColumns = [("origin", "TEXT"), ("judge_provider", "TEXT"), ("judge_model", "TEXT"), ("confirmed_at", "REAL"),
                             ("heard", "TEXT"), ("source", "TEXT")]
        for (name, type) in originColumns where !dictionaryColumns.contains(name) {
            try execute("ALTER TABLE dictionary ADD COLUMN \(name) \(type);")
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS api_usage (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                api TEXT NOT NULL,
                model TEXT NOT NULL,
                audio_seconds REAL NOT NULL,
                input_tokens INTEGER NOT NULL,
                cached_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cost_usd REAL,
                latency_ms INTEGER NOT NULL,
                succeeded INTEGER NOT NULL,
                fallback_from_api TEXT,
                fallback_stage TEXT,
                fallback_reason TEXT,
                failure_cause TEXT,
                retry_of TEXT
            );
            """
        )
        // Les colonnes restent NULL sur les anciennes lignes : une API de destination
        // ne suffit pas à distinguer un choix explicite d'une bascule automatique.
        let usageColumns = Set(try query("PRAGMA table_info(api_usage);") { column(1, $0) })
        for name in ["fallback_from_api", "fallback_stage", "fallback_reason", "failure_cause", "retry_of"] where !usageColumns.contains(name) {
            try execute("ALTER TABLE api_usage ADD COLUMN \(name) TEXT;")
        }
        try execute("CREATE INDEX IF NOT EXISTS api_usage_created ON api_usage(created_at DESC);")
        try execute("CREATE TABLE IF NOT EXISTS app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        // Refus d'un mot proposé après une dictée : ne plus jamais le renvoyer au juge.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS learning_refusals (
                term TEXT PRIMARY KEY COLLATE NOCASE,
                created_at REAL NOT NULL
            );
            """
        )
        // Une base déjà à jour s'ouvre sans rien écrire, donc sans attendre le verrou d'écriture : un autre Wispad ou
        // un outil qui le tient plus de 2 s n'empêche pas le lancement. Chaque écriture ci-dessous n'a lieu que si
        // son marqueur manque ; les migrations le relisent dans leur transaction, au cas où une autre instance passe.
        let metadata = Set(try query("SELECT key FROM app_metadata;") { column(0, $0) })
        if !metadata.contains("learning_refusals_v1") {
            try execute("INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('learning_refusals_v1', '1');")
        }
        if !metadata.contains("fallback_tracking_started_at") {
            try run("INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('fallback_tracking_started_at', ?);") { statement in
                sqlite3_bind_double(statement, 1, fallbackTrackingStartedAt.timeIntervalSince1970)
            }
        }
        let trackingDates = try query("SELECT value FROM app_metadata WHERE key = 'fallback_tracking_started_at';") {
            Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
        }
        if let date = trackingDates.first { fallbackTrackingStartedAt = date }
        if !metadata.contains("failure_cause_tracking_started_at") {
            try run("INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('failure_cause_tracking_started_at', ?);") { statement in
                sqlite3_bind_double(statement, 1, failureCauseTrackingStartedAt.timeIntervalSince1970)
            }
        }
        let causeDates = try query("SELECT value FROM app_metadata WHERE key = 'failure_cause_tracking_started_at';") {
            Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
        }
        if let date = causeDates.first { failureCauseTrackingStartedAt = date }
        // Ancienne date de début du suivi financier, sans usage depuis la fin de la séparation
        // Utilisation / Développement. Les appels eux-mêmes restent intacts.
        if metadata.contains("financial_tracking_started_at") {
            try execute("DELETE FROM app_metadata WHERE key = 'financial_tracking_started_at';")
        }
        if !metadata.contains("usage_accuracy_v1") { try migrateUsageAccuracy() }
        if !metadata.contains("retired_values_v1") { try forgetRetiredValues() }
        if !metadata.contains("dictations_fts_v1") { try backfillDictationsFTS() }
        if !metadata.contains("sync_outbox_v1") { try seedSyncOutbox() }
        if !metadata.contains("sync_outbox_api_v1") { try seedSyncApiOutbox() }
    }

    /// Enregistre une seule fois dans `sync_outbox` les appels d'API déjà comptés avant leur synchronisation : à cette
    /// ouverture, la table ne contient que les appels de cet appareil.
    private func seedSyncApiOutbox() throws {
        try transaction {
            let done = try queryOnQueue("SELECT value FROM app_metadata WHERE key = 'sync_outbox_api_v1';") { column(0, $0) }
            guard done.isEmpty else { return }
            try executeOnQueue("INSERT OR IGNORE INTO sync_outbox (entity_type, entity_id) SELECT 'api_call', id FROM api_usage;")
            try executeOnQueue("INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('sync_outbox_api_v1', '1');")
        }
    }

    /// Peuple une seule fois l'index FTS5 pour les bases déjà existantes avant l'introduction de `dictations_fts`.
    private func backfillDictationsFTS() throws {
        try transaction {
            let done = try queryOnQueue("SELECT value FROM app_metadata WHERE key = 'dictations_fts_v1';") { column(0, $0) }
            guard done.isEmpty else { return }
            try? executeOnQueue("DELETE FROM dictations_fts;")
            try? executeOnQueue(
                """
                INSERT INTO dictations_fts (id, final_text, raw_text, alternative_text)
                SELECT id, final_text, raw_text, alternative_text FROM dictations;
                """
            )
            try executeOnQueue("INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('dictations_fts_v1', '1');")
        }
    }

    /// Enregistre dans `sync_outbox` les données déjà présentes avant l'introduction du suivi dirty par boîte d'envoi.
    private func seedSyncOutbox() throws {
        try transaction {
            let done = try queryOnQueue("SELECT value FROM app_metadata WHERE key = 'sync_outbox_v1';") { column(0, $0) }
            guard done.isEmpty else { return }
            try executeOnQueue("INSERT OR IGNORE INTO sync_outbox (entity_type, entity_id) SELECT 'dictation', id FROM dictations;")
            try executeOnQueue("INSERT OR IGNORE INTO sync_outbox (entity_type, entity_id) SELECT 'meeting', id FROM meetings;")
            try executeOnQueue("INSERT OR IGNORE INTO sync_outbox (entity_type, entity_id) SELECT 'dictionary', id FROM dictionary;")
            try executeOnQueue("INSERT OR IGNORE INTO sync_outbox (entity_type, entity_id) SELECT 'refusal', term FROM learning_refusals;")
            try executeOnQueue("INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('sync_outbox_v1', '1');")
        }
    }

    /// Répare une seule fois les estimations anciennes, sans reconstruire de jetons perdus.
    /// Les tarifs DeepSeek actuels sont entrés en vigueur le 16 août 2026 à 16 h UTC.
    private func migrateUsageAccuracy() throws {
        try transaction {
            let done = try queryOnQueue("SELECT value FROM app_metadata WHERE key = 'usage_accuracy_v1';") {
                column(0, $0)
            }
            guard done.isEmpty else { return }
            // Un résultat échoué ne prouve pas que le fournisseur n'a rien traité.
            // Les anciens succès texte sans aucun compteur ne prouvent pas non plus la gratuité.
            try executeOnQueue("""
                UPDATE api_usage SET cost_usd = NULL
                WHERE cost_usd = 0 AND (
                    succeeded = 0 OR (
                        api IN ('deepseek.cleanup', 'xai.cleanup', 'openai.cleanup', 'typesafe.judge')
                        AND input_tokens = 0 AND cached_tokens = 0 AND output_tokens = 0
                    )
                );
                """)
            let repriced = try queryOnQueue("""
                SELECT id, created_at, model, input_tokens, cached_tokens, output_tokens
                FROM api_usage
                WHERE api = 'deepseek.cleanup' AND model = 'deepseek-flash'
                    AND created_at >= 1786896000 AND cost_usd IS NOT NULL
                    AND (input_tokens > 0 OR cached_tokens > 0 OR output_tokens > 0);
                """) { statement in
                (id: column(0, statement), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                 model: column(2, statement), tokens: TokenUsage(
                    input: Int(sqlite3_column_int64(statement, 3)),
                    cachedInput: Int(sqlite3_column_int64(statement, 4)),
                    output: Int(sqlite3_column_int64(statement, 5))))
            }
            for event in repriced {
                let cost = Pricing.tokenCost(model: event.model, tokens: event.tokens, at: event.date)
                try runOnQueue("UPDATE api_usage SET cost_usd = ? WHERE id = ?;") { statement in
                    if let cost { sqlite3_bind_double(statement, 1, cost) }
                    else { sqlite3_bind_null(statement, 1) }
                    bind(event.id, at: 2, statement)
                }
            }
            try executeOnQueue("INSERT INTO app_metadata (key, value) VALUES ('usage_accuracy_v1', '1');")
        }
    }

    /// Une seule fois : retire ce qui cite une valeur de fonction retirée (transcription sur le Mac, serveur de
    /// correction compatible OpenAI). Ces traces ne se décodent plus et rendraient illisibles le détail et le
    /// diagnostic ; ces appels, gratuits ou de tarif inconnu, ne sont plus lus par l'écran Consommation.
    private func forgetRetiredValues() throws {
        try transaction {
            let done = try queryOnQueue("SELECT value FROM app_metadata WHERE key = 'retired_values_v1';") {
                column(0, $0)
            }
            guard done.isEmpty else { return }
            try executeOnQueue("""
                DELETE FROM dictation_traces
                WHERE payload LIKE '%"modelUnavailable"%' OR payload LIKE '%"custom.cleanup"%';
                """)
            try executeOnQueue("DELETE FROM api_usage WHERE api = 'custom.cleanup' OR fallback_from_api = 'custom.cleanup';")
            try executeOnQueue("INSERT INTO app_metadata (key, value) VALUES ('retired_values_v1', '1');")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    public func insert(_ record: DictationRecord) throws {
        let updated = record.createdAt.timeIntervalSince1970
        try transaction {
            try runOnQueue(
                """
                INSERT INTO dictations (
                    id, created_at, final_text, raw_text, duration_seconds, word_count,
                    provider, model, target_app, target_bundle, usage_category,
                    insertion_status, audio_path, audio_expires_at, alternative_text,
                    source_device_id, source_device_name, source_device_platform, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            ) { statement in
                bind(record.id, at: 1, statement)
                sqlite3_bind_double(statement, 2, record.createdAt.timeIntervalSince1970)
                bind(record.finalText, at: 3, statement)
                bind(record.rawText, at: 4, statement)
                sqlite3_bind_double(statement, 5, record.durationSeconds)
                // Colonne lue en Int32 : un compte démesuré y est borné au lieu de faire planter l'écriture.
                sqlite3_bind_int(statement, 6, Int32(clamping: record.wordCount))
                bind(record.provider, at: 7, statement)
                bind(record.model, at: 8, statement)
                bindOptional(record.targetApp, at: 9, statement)
                bindOptional(record.targetBundle, at: 10, statement)
                bindOptional(record.usageCategory, at: 11, statement)
                bind(record.insertionStatus, at: 12, statement)
                bindOptional(record.audioPath, at: 13, statement)
                if let expires = record.audioExpiresAt {
                    sqlite3_bind_double(statement, 14, expires.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 14)
                }
                bindOptional(record.alternativeText, at: 15, statement)
                bindOptional(record.sourceDeviceID, at: 16, statement)
                bindOptional(record.sourceDeviceName, at: 17, statement)
                bindOptional(record.sourceDevicePlatform, at: 18, statement)
                sqlite3_bind_double(statement, 19, updated)
            }
            indexFTSOnQueue(id: record.id, finalText: record.finalText, rawText: record.rawText, alternativeText: record.alternativeText)
            try markOutboxOnQueue(entityType: "dictation", entityID: record.id)
        }
    }

    public func dictations() throws -> [DictationRecord] {
        try query(
            """
            SELECT id, created_at, final_text, raw_text, duration_seconds, word_count,
                provider, model, target_app, target_bundle, usage_category,
                insertion_status, audio_path, audio_expires_at, alternative_text,
                source_device_id, source_device_name, source_device_platform
            FROM dictations ORDER BY created_at DESC;
            """
        ) { statement in
            DictationRecord(
                id: column(0, statement),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                finalText: column(2, statement),
                rawText: column(3, statement),
                durationSeconds: sqlite3_column_double(statement, 4),
                wordCount: Int(sqlite3_column_int(statement, 5)),
                provider: column(6, statement),
                model: column(7, statement),
                targetApp: optionalColumn(8, statement),
                targetBundle: optionalColumn(9, statement),
                usageCategory: optionalColumn(10, statement),
                insertionStatus: column(11, statement),
                audioPath: optionalColumn(12, statement),
                audioExpiresAt: sqlite3_column_type(statement, 13) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
                alternativeText: optionalColumn(14, statement),
                sourceDeviceID: optionalColumn(15, statement),
                sourceDeviceName: optionalColumn(16, statement),
                sourceDevicePlatform: optionalColumn(17, statement)
            )
        }
    }

    /// Recherche rapide dans l'index FTS5 (retourne les identifiants correspondants) ; nil si la requête est vide ou FTS indisponible.
    public func searchDictationIDs(query text: String) -> Set<String>? {
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        let matchExpr = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " AND ")
        guard let ids = try? query("SELECT id FROM dictations_fts WHERE dictations_fts MATCH ?;",
                                   bind: { bind(matchExpr, at: 1, $0) },
                                   map: { column(0, $0) }) else { return nil }
        return Set(ids)
    }

    public func updateTranscript(id: String, finalText: String, rawText: String, wordCount: Int) throws {
        let now = Date().timeIntervalSince1970
        try transaction {
            let alt = try queryOnQueue("SELECT alternative_text FROM dictations WHERE id = ?;", bind: { bind(id, at: 1, $0) }) {
                optionalColumn(0, $0)
            }.first ?? nil
            try runOnQueue("UPDATE dictations SET final_text = ?, raw_text = ?, word_count = ?, updated_at = ? WHERE id = ?;") { statement in
                bind(finalText, at: 1, statement)
                bind(rawText, at: 2, statement)
                sqlite3_bind_int(statement, 3, Int32(clamping: wordCount))
                sqlite3_bind_double(statement, 4, now)
                bind(id, at: 5, statement)
            }
            indexFTSOnQueue(id: id, finalText: finalText, rawText: rawText, alternativeText: alt)
            try markOutboxOnQueue(entityType: "dictation", entityID: id)
        }
    }

    public func updateStatus(id: String, status: String) throws {
        try transaction {
            try runOnQueue("UPDATE dictations SET insertion_status = ?, updated_at = ? WHERE id = ?;") { statement in
                bind(status, at: 1, statement)
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                bind(id, at: 3, statement)
            }
            try markOutboxOnQueue(entityType: "dictation", entityID: id)
        }
    }

    /// Dictée livrée plus tard (« Coller la dernière dictée ») : nouveau statut et app où elle a été collée.
    /// Une app inconnue (nil) laisse celle déjà enregistrée, sauf si la destination a explicitement changé.
    public func updateDelivery(id: String, status: String, targetApp: String?, targetBundle: String?, usageCategory: String?,
                               preserveUnknownTarget: Bool = true) throws {
        try transaction {
            try runOnQueue(
                """
                UPDATE dictations SET insertion_status = ?, target_app = \(preserveUnknownTarget ? "COALESCE(?, target_app)" : "?"),
                    target_bundle = \(preserveUnknownTarget ? "COALESCE(?, target_bundle)" : "?"),
                    usage_category = \(preserveUnknownTarget ? "COALESCE(?, usage_category)" : "?"),
                    updated_at = ?
                WHERE id = ?;
                """
            ) { statement in
                bind(status, at: 1, statement)
                bindOptional(targetApp, at: 2, statement)
                bindOptional(targetBundle, at: 3, statement)
                bindOptional(usageCategory, at: 4, statement)
                sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
                bind(id, at: 6, statement)
            }
            try markOutboxOnQueue(entityType: "dictation", entityID: id)
        }
    }

    public func updateAudio(id: String, path: String?, expiresAt: Date?) throws {
        try run("UPDATE dictations SET audio_path = ?, audio_expires_at = ? WHERE id = ?;") { statement in
            bindOptional(path, at: 1, statement)
            if let expiresAt {
                sqlite3_bind_double(statement, 2, expiresAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            bind(id, at: 3, statement)
        }
    }

    /// Purge : oublie l'audio de plusieurs dictées en une seule transaction, sans toucher au reste. Une écriture par
    /// audio attendait chaque fois une base occupée (jusqu'à 2 s), sur le fil principal. Tout ou rien.
    public func clearAudio(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids {
                try runOnQueue("UPDATE dictations SET audio_path = NULL, audio_expires_at = NULL WHERE id = ?;") { statement in
                    bind(id, at: 1, statement)
                }
            }
        }
    }

    public func deleteDictation(id: String) throws {
        let now = Date().timeIntervalSince1970
        try transaction {
            // La clé étrangère supprime aussi les traces, dans la même opération SQLite.
            try runOnQueue("DELETE FROM dictations WHERE id = ?;") { statement in
                bind(id, at: 1, statement)
            }
            try? runOnQueue("DELETE FROM dictations_fts WHERE id = ?;") { bind(id, at: 1, $0) }
            try recordTombstoneOnQueue(entityType: "dictation", entityID: id, at: now)
            try markOutboxOnQueue(entityType: "dictation", entityID: id)
        }
    }

    public func deleteAllDictations() throws {
        let now = Date().timeIntervalSince1970
        try transaction {
            let ids = try queryOnQueue("SELECT id FROM dictations;") { column(0, $0) }
            try executeOnQueue("DELETE FROM dictations;")
            try? executeOnQueue("DELETE FROM dictations_fts;")
            for id in ids {
                try recordTombstoneOnQueue(entityType: "dictation", entityID: id, at: now)
                try markOutboxOnQueue(entityType: "dictation", entityID: id)
            }
        }
    }

    /// Le record associé doit déjà exister. Les captures sans dictée sont bornées à 100 et les traces liées à 500
    /// pour éviter la croissance illimitée de la base locale.
    public func saveTrace(_ trace: DictationTrace) throws {
        try transaction {
            try writeTraceOnQueue(trace)
            if trace.dictationID == nil {
                try executeOnQueue(
                    """
                    DELETE FROM dictation_traces WHERE dictation_id IS NULL AND id NOT IN (
                        SELECT id FROM dictation_traces WHERE dictation_id IS NULL
                        ORDER BY created_at DESC, id DESC LIMIT 100
                    );
                    """
                )
            } else {
                try executeOnQueue(
                    """
                    DELETE FROM dictation_traces WHERE dictation_id IS NOT NULL AND id NOT IN (
                        SELECT id FROM dictation_traces WHERE dictation_id IS NOT NULL
                        ORDER BY created_at DESC, id DESC LIMIT 500
                    );
                    """
                )
            }
        }
    }

    public func traces(dictationID: String) throws -> [DictationTrace] {
        try query(
            "SELECT payload FROM dictation_traces WHERE dictation_id = ? ORDER BY created_at DESC, id DESC;",
            bind: { bind(dictationID, at: 1, $0) }
        ) { try decodeTrace($0) }
    }

    public func trace(id: String) throws -> DictationTrace? {
        try query(
            "SELECT payload FROM dictation_traces WHERE id = ?;",
            bind: { bind(id, at: 1, $0) }
        ) { try decodeTrace($0) }.first
    }

    public func recentTraces(limit: Int = 50) throws -> [DictationTrace] {
        guard limit > 0 else { return [] }
        return try query(
            "SELECT payload FROM dictation_traces ORDER BY created_at DESC, id DESC LIMIT ?;",
            bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }
        ) { try decodeTrace($0) }
    }

    /// Un apprentissage tardif ne recrée jamais une trace supprimée avec sa dictée.
    public func appendTraceCalls(id: String, calls: [DictationAPICall]) throws {
        guard !calls.isEmpty else { return }
        try transaction {
            guard var trace = try queryOnQueue(
                "SELECT payload FROM dictation_traces WHERE id = ?;",
                bind: { bind(id, at: 1, $0) }, map: { try decodeTrace($0) }
            ).first else { return }
            var knownIDs = Set(trace.calls.map(\.id))
            let additions = calls.filter { knownIDs.insert($0.id).inserted }
            guard !additions.isEmpty else { return }
            trace.calls.append(contentsOf: additions)
            try writeTraceOnQueue(trace)
        }
    }

    private func writeTraceOnQueue(_ trace: DictationTrace) throws {
        let payload = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        try runOnQueue(
            """
            INSERT INTO dictation_traces (id, dictation_id, created_at, payload) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET dictation_id = excluded.dictation_id,
                created_at = excluded.created_at, payload = excluded.payload;
            """
        ) { statement in
            bind(trace.id, at: 1, statement)
            bindOptional(trace.dictationID, at: 2, statement)
            sqlite3_bind_double(statement, 3, trace.createdAt.timeIntervalSince1970)
            bind(payload, at: 4, statement)
        }
    }

    private func decodeTrace(_ statement: OpaquePointer?) throws -> DictationTrace {
        do {
            return try JSONDecoder().decode(DictationTrace.self, from: Data(column(0, statement).utf8))
        } catch {
            // Ne pas intégrer le contenu d'un payload illisible au message d'erreur.
            throw StoreError.message("Trace technique illisible.")
        }
    }

    /// La consommation reste comptée même si l'historique des dictées est effacé.
    /// L'appel part aussi dans `sync_outbox` : les autres appareils le comptent dans leur consommation.
    public func insertUsage(_ event: UsageEvent) throws {
        try transaction {
            try runOnQueue(
                """
                INSERT INTO api_usage (
                    id, created_at, api, model, audio_seconds, input_tokens, cached_tokens,
                    output_tokens, cost_usd, latency_ms, succeeded,
                    fallback_from_api, fallback_stage, fallback_reason, failure_cause, retry_of
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            ) { statement in
                bind(event.id, at: 1, statement)
                sqlite3_bind_double(statement, 2, event.createdAt.timeIntervalSince1970)
                bind(event.api.rawValue, at: 3, statement)
                bind(event.model, at: 4, statement)
                sqlite3_bind_double(statement, 5, event.audioSeconds)
                sqlite3_bind_int64(statement, 6, Int64(event.tokens.input))
                sqlite3_bind_int64(statement, 7, Int64(event.tokens.cachedInput))
                sqlite3_bind_int64(statement, 8, Int64(event.tokens.output))
                if let cost = event.costUSD {
                    sqlite3_bind_double(statement, 9, cost)
                } else {
                    sqlite3_bind_null(statement, 9)
                }
                sqlite3_bind_int64(statement, 10, Int64(event.latencyMs))
                sqlite3_bind_int(statement, 11, event.succeeded ? 1 : 0)
                bindOptional(event.fallback?.fromAPI.rawValue, at: 12, statement)
                bindOptional(event.fallback?.stage.rawValue, at: 13, statement)
                bindOptional(event.fallback?.reason.rawValue, at: 14, statement)
                bindOptional(event.failureCause?.rawValue, at: 15, statement)
                bindOptional(event.retryOf, at: 16, statement)
            }
            try markOutboxOnQueue(entityType: "api_call", entityID: event.id)
        }
    }

    public func usageEvents() throws -> [UsageEvent] {
        let rows: [UsageEvent?] = try query(
            """
            SELECT id, created_at, api, model, audio_seconds, input_tokens, cached_tokens,
                output_tokens, cost_usd, latency_ms, succeeded,
                fallback_from_api, fallback_stage, fallback_reason, failure_cause, retry_of
            FROM api_usage ORDER BY created_at DESC;
            """
        ) { statement in
            guard let api = UsageAPI(rawValue: column(2, statement)) else { return nil }
            let fallback: APIFallback?
            if let from = UsageAPI(rawValue: column(11, statement)),
               let stage = FallbackStage(rawValue: column(12, statement)),
               let reason = FallbackReason(rawValue: column(13, statement)) {
                fallback = APIFallback(fromAPI: from, stage: stage, reason: reason)
            } else {
                fallback = nil
            }
            return UsageEvent(
                id: column(0, statement),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                api: api,
                model: column(3, statement),
                audioSeconds: sqlite3_column_double(statement, 4),
                tokens: TokenUsage(
                    input: Int(sqlite3_column_int64(statement, 5)),
                    cachedInput: Int(sqlite3_column_int64(statement, 6)),
                    output: Int(sqlite3_column_int64(statement, 7))
                ),
                costUSD: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 8),
                latencyMs: Int(sqlite3_column_int64(statement, 9)),
                succeeded: sqlite3_column_int(statement, 10) != 0,
                fallback: fallback,
                failureCause: APIFailureCause(rawValue: column(14, statement)),
                retryOf: optionalColumn(15, statement)
            )
        }
        return rows.compactMap { $0 }
    }

    public func dictionary() throws -> [DictionaryEntry] {
        try query(
            """
            SELECT id, term, created_at, origin, judge_provider, judge_model, confirmed_at, heard, source
            FROM dictionary ORDER BY term COLLATE NOCASE;
            """
        ) { statement in
            DictionaryEntry(
                id: column(0, statement),
                term: column(1, statement),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                origin: DictionaryOrigin(
                    stored: optionalColumn(3, statement),
                    provider: optionalColumn(4, statement),
                    model: optionalColumn(5, statement)
                ),
                confirmedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                heard: optionalColumn(7, statement).flatMap { $0.isEmpty ? nil : $0 },
                // Une source inconnue (écrite par une version plus récente) se lit comme absente.
                source: optionalColumn(8, statement).flatMap(DictionarySource.init(rawValue:))
            )
        }
    }

    /// Ajoute un mot avec son origine. Sans origine précisée, il est noté comme d'avant le suivi : jamais « ajouté
    /// par toi » ni un juge par défaut. Un mot déjà présent, à la casse près, garde son entrée et son origine.
    /// `heard` et `source` : ce que la reconnaissance avait écrit, et d'où vient le terme.
    public func addTerm(_ term: String, origin: DictionaryOrigin = .unknown, heard: String? = nil,
                        source: DictionarySource? = nil, createdAt: Date = Date()) throws {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let heard = heard?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newID = UUID().uuidString
        try transaction {
            let existing = try queryOnQueue("SELECT id FROM dictionary WHERE term = ? COLLATE NOCASE LIMIT 1;", bind: { bind(cleaned, at: 1, $0) }) {
                column(0, $0)
            }.first
            guard existing == nil else { return }
            try runOnQueue(
                """
                INSERT OR IGNORE INTO dictionary (id, term, created_at, origin, judge_provider, judge_model, heard, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
            ) { statement in
                bind(newID, at: 1, statement)
                bind(cleaned, at: 2, statement)
                sqlite3_bind_double(statement, 3, createdAt.timeIntervalSince1970)
                bindOptional(origin.storedValue, at: 4, statement)
                bindOptional(origin.judge?.provider, at: 5, statement)
                bindOptional(origin.judge?.model, at: 6, statement)
                bindOptional(heard?.isEmpty == false ? heard : nil, at: 7, statement)
                bindOptional(source?.rawValue, at: 8, statement)
            }
            try markOutboxOnQueue(entityType: "dictionary", entityID: newID)
        }
    }

    /// Change l'écriture d'une entrée (« codex » → « Codex ») sans toucher à son origine ni à sa date. Refusé (false)
    /// quand une autre entrée porte déjà ce terme, à la casse près.
    @discardableResult
    public func renameTerm(id: String, to term: String) throws -> Bool {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        return try transaction {
            let taken = try !queryOnQueue("SELECT id FROM dictionary WHERE term = ? AND id <> ? LIMIT 1;", bind: { statement in
                bind(cleaned, at: 1, statement)
                bind(id, at: 2, statement)
            }) { column(0, $0) }.isEmpty
            guard !taken else { return false }
            try runOnQueue("UPDATE dictionary SET term = ? WHERE id = ?;") { statement in
                bind(cleaned, at: 1, statement)
                bind(id, at: 2, statement)
            }
            try markOutboxOnQueue(entityType: "dictionary", entityID: id)
            return true
        }
    }

    /// « Oui » dans la bulle « Le garder ? » : note la confirmation d'un mot appris, sans changer son origine.
    /// Un mot ajouté à la main, d'avant le suivi ou déjà confirmé n'est pas touché. La casse ne compte pas.
    public func confirmLearnedTerm(_ term: String) throws {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        try transaction {
            let ids = try queryOnQueue(
                "SELECT id FROM dictionary WHERE term = ? AND origin IN ('jev', 'model') AND confirmed_at IS NULL;",
                bind: { bind(cleaned, at: 1, $0) }
            ) { column(0, $0) }
            guard !ids.isEmpty else { return }
            try runOnQueue(
                """
                UPDATE dictionary SET confirmed_at = ?
                WHERE term = ? AND origin IN ('jev', 'model') AND confirmed_at IS NULL;
                """
            ) { statement in
                sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                bind(cleaned, at: 2, statement)
            }
            for id in ids { try markOutboxOnQueue(entityType: "dictionary", entityID: id) }
        }
    }

    public func deleteTerm(id: String) throws {
        let now = Date().timeIntervalSince1970
        try transaction {
            try runOnQueue("DELETE FROM dictionary WHERE id = ?;") { statement in
                bind(id, at: 1, statement)
            }
            try recordTombstoneOnQueue(entityType: "dictionary", entityID: id, at: now)
            try markOutboxOnQueue(entityType: "dictionary", entityID: id)
        }
    }

    // MARK: - Notes de réunion (style Granola)

    public func meetings() throws -> [MeetingRecord] {
        try query(
            """
            SELECT id, title, created_at, updated_at, duration_seconds, user_notes, raw_transcript, enhanced_notes,
                source_device_id, source_device_name, source_device_platform
            FROM meetings ORDER BY created_at DESC;
            """
        ) { statement in
            MeetingRecord(
                id: column(0, statement),
                title: column(1, statement),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                durationSeconds: sqlite3_column_double(statement, 4),
                userNotes: column(5, statement),
                rawTranscript: column(6, statement),
                enhancedNotes: column(7, statement),
                sourceDeviceID: optionalColumn(8, statement),
                sourceDeviceName: optionalColumn(9, statement),
                sourceDevicePlatform: optionalColumn(10, statement)
            )
        }
    }

    public func upsertMeeting(_ meeting: MeetingRecord) throws {
        try transaction {
            try runOnQueue(
                """
                INSERT INTO meetings (
                    id, title, created_at, updated_at, duration_seconds, user_notes, raw_transcript, enhanced_notes,
                    source_device_id, source_device_name, source_device_platform
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    updated_at = excluded.updated_at,
                    duration_seconds = excluded.duration_seconds,
                    user_notes = excluded.user_notes,
                    raw_transcript = excluded.raw_transcript,
                    enhanced_notes = excluded.enhanced_notes,
                    source_device_id = COALESCE(excluded.source_device_id, meetings.source_device_id),
                    source_device_name = COALESCE(excluded.source_device_name, meetings.source_device_name),
                    source_device_platform = COALESCE(excluded.source_device_platform, meetings.source_device_platform);
                """
            ) { statement in
                bind(meeting.id, at: 1, statement)
                bind(meeting.title, at: 2, statement)
                sqlite3_bind_double(statement, 3, meeting.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 4, meeting.updatedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 5, meeting.durationSeconds)
                bind(meeting.userNotes, at: 6, statement)
                bind(meeting.rawTranscript, at: 7, statement)
                bind(meeting.enhancedNotes, at: 8, statement)
                bindOptional(meeting.sourceDeviceID, at: 9, statement)
                bindOptional(meeting.sourceDeviceName, at: 10, statement)
                bindOptional(meeting.sourceDevicePlatform, at: 11, statement)
            }
            try markOutboxOnQueue(entityType: "meeting", entityID: meeting.id)
        }
    }

    public func deleteMeeting(id: String) throws {
        let now = Date().timeIntervalSince1970
        try transaction {
            try runOnQueue("DELETE FROM meetings WHERE id = ?;") { bind(id, at: 1, $0) }
            try recordTombstoneOnQueue(entityType: "meeting", entityID: id, at: now)
            try markOutboxOnQueue(entityType: "meeting", entityID: id)
        }
    }

    // MARK: - Synchronisation BYOS E2EE (`WispadSyncEngine`)

    public func syncCursor(for deviceID: String) throws -> Int {
        try query("SELECT last_sequence FROM sync_peers WHERE device_id = ?;", bind: { bind(deviceID, at: 1, $0) }) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    public func setSyncCursor(deviceID: String, sequence: Int) throws {
        try run(
            """
            INSERT INTO sync_peers (device_id, last_sequence, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(device_id) DO UPDATE SET last_sequence = excluded.last_sequence, updated_at = excluded.updated_at;
            """
        ) { statement in
            bind(deviceID, at: 1, statement)
            sqlite3_bind_int64(statement, 2, Int64(sequence))
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        }
    }

    public func lastSyncPushTimestamp() throws -> Double {
        try query("SELECT value FROM app_metadata WHERE key = 'sync_last_push_at';") {
            Double(column(0, $0)) ?? 0
        }.first ?? 0
    }

    public func setLastSyncPushTimestamp(_ timestamp: Double) throws {
        try run(
            """
            INSERT INTO app_metadata (key, value) VALUES ('sync_last_push_at', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
        ) { bind(String(timestamp), at: 1, $0) }
    }

    public func dictationsForSync(modifiedAfter cutoff: Double, localDevice: DeviceIdentity) throws -> [SyncDictation] {
        var items: [SyncDictation] = try query(
            """
            SELECT id, created_at, final_text, raw_text, duration_seconds, word_count,
                provider, model, target_app, target_bundle, usage_category, insertion_status,
                source_device_id, source_device_name, source_device_platform, COALESCE(updated_at, created_at)
            FROM dictations
            WHERE COALESCE(updated_at, created_at) > ?
              AND (source_device_id IS NULL OR source_device_id = ?);
            """,
            bind: { statement in
                sqlite3_bind_double(statement, 1, cutoff)
                bind(localDevice.deviceId, at: 2, statement)
            }
        ) { statement in
            SyncDictation(
                id: column(0, statement),
                createdAt: sqlite3_column_double(statement, 1),
                updatedAt: sqlite3_column_double(statement, 15),
                deletedAt: nil,
                finalText: column(2, statement),
                rawText: column(3, statement),
                durationSeconds: sqlite3_column_double(statement, 4),
                wordCount: Int(sqlite3_column_int(statement, 5)),
                provider: column(6, statement),
                model: column(7, statement),
                targetApp: optionalColumn(8, statement),
                targetBundle: optionalColumn(9, statement),
                usageCategory: optionalColumn(10, statement),
                insertionStatus: column(11, statement),
                sourceDeviceId: optionalColumn(12, statement) ?? localDevice.deviceId,
                sourceDeviceName: optionalColumn(13, statement) ?? localDevice.deviceName,
                sourceDevicePlatform: optionalColumn(14, statement) ?? localDevice.platform.rawValue
            )
        }
        let deleted: [SyncDictation] = try query(
            "SELECT entity_id, deleted_at FROM sync_tombstones WHERE entity_type = 'dictation' AND deleted_at > ?;",
            bind: { sqlite3_bind_double($0, 1, cutoff) }
        ) { statement in
            let ts = sqlite3_column_double(statement, 1)
            return SyncDictation(
                id: column(0, statement), createdAt: ts, updatedAt: ts, deletedAt: ts,
                finalText: "", rawText: "", durationSeconds: 0, wordCount: 0,
                provider: "", model: "", insertionStatus: "deleted",
                sourceDeviceId: localDevice.deviceId,
                sourceDeviceName: localDevice.deviceName,
                sourceDevicePlatform: localDevice.platform.rawValue
            )
        }
        items.append(contentsOf: deleted)
        return items
    }

    public func meetingsForSync(modifiedAfter cutoff: Double, localDevice: DeviceIdentity) throws -> [SyncMeeting] {
        var items: [SyncMeeting] = try query(
            """
            SELECT id, title, created_at, updated_at, duration_seconds, user_notes, raw_transcript, enhanced_notes,
                source_device_id, source_device_name, source_device_platform
            FROM meetings WHERE updated_at > ?;
            """,
            bind: { sqlite3_bind_double($0, 1, cutoff) }
        ) { statement in
            SyncMeeting(
                id: column(0, statement),
                title: column(1, statement),
                createdAt: sqlite3_column_double(statement, 2),
                updatedAt: sqlite3_column_double(statement, 3),
                deletedAt: nil,
                durationSeconds: sqlite3_column_double(statement, 4),
                userNotes: column(5, statement),
                rawTranscript: column(6, statement),
                enhancedNotes: column(7, statement),
                sourceDeviceId: optionalColumn(8, statement) ?? localDevice.deviceId,
                sourceDeviceName: optionalColumn(9, statement) ?? localDevice.deviceName,
                sourceDevicePlatform: optionalColumn(10, statement) ?? localDevice.platform.rawValue
            )
        }
        let deleted: [SyncMeeting] = try query(
            "SELECT entity_id, deleted_at FROM sync_tombstones WHERE entity_type = 'meeting' AND deleted_at > ?;",
            bind: { sqlite3_bind_double($0, 1, cutoff) }
        ) { statement in
            let ts = sqlite3_column_double(statement, 1)
            return SyncMeeting(
                id: column(0, statement), title: "", createdAt: ts, updatedAt: ts, deletedAt: ts,
                durationSeconds: 0, userNotes: "", rawTranscript: "", enhancedNotes: "",
                sourceDeviceId: localDevice.deviceId,
                sourceDeviceName: localDevice.deviceName,
                sourceDevicePlatform: localDevice.platform.rawValue
            )
        }
        items.append(contentsOf: deleted)
        return items
    }

    public func dictionaryForSync(modifiedAfter cutoff: Double) throws -> [SyncDictionaryTerm] {
        var items: [SyncDictionaryTerm] = try query(
            """
            SELECT id, term, created_at, COALESCE(confirmed_at, created_at), origin, judge_provider, judge_model, heard, source
            FROM dictionary WHERE COALESCE(confirmed_at, created_at) > ?;
            """,
            bind: { sqlite3_bind_double($0, 1, cutoff) }
        ) { statement in
            SyncDictionaryTerm(
                id: column(0, statement),
                term: column(1, statement),
                createdAt: sqlite3_column_double(statement, 2),
                updatedAt: sqlite3_column_double(statement, 3),
                deletedAt: nil,
                origin: optionalColumn(4, statement),
                judgeProvider: optionalColumn(5, statement),
                judgeModel: optionalColumn(6, statement),
                heard: optionalColumn(7, statement),
                source: optionalColumn(8, statement)
            )
        }
        let deleted: [SyncDictionaryTerm] = try query(
            "SELECT entity_id, deleted_at FROM sync_tombstones WHERE entity_type = 'dictionary' AND deleted_at > ?;",
            bind: { sqlite3_bind_double($0, 1, cutoff) }
        ) { statement in
            let ts = sqlite3_column_double(statement, 1)
            return SyncDictionaryTerm(id: column(0, statement), term: "", createdAt: ts, updatedAt: ts, deletedAt: ts)
        }
        items.append(contentsOf: deleted)
        return items
    }

    public func refusalsForSync(createdAfter cutoff: Double) throws -> [SyncRefusal] {
        try query("SELECT term, created_at FROM learning_refusals WHERE created_at > ?;",
                  bind: { sqlite3_bind_double($0, 1, cutoff) }) { statement in
            SyncRefusal(term: column(0, statement), createdAt: sqlite3_column_double(statement, 1))
        }
    }

    /// Lot de mutations locales en attente d'envoi dans `sync_outbox`.
    public struct SyncOutboxBatch: Sendable {
        public var dictations: [SyncDictation]
        public var meetings: [SyncMeeting]
        public var dictionary: [SyncDictionaryTerm]
        public var refusals: [SyncRefusal]
        public var apiCalls: [SyncApiCall] = []

        public var isEmpty: Bool {
            dictations.isEmpty && meetings.isEmpty && dictionary.isEmpty && refusals.isEmpty && apiCalls.isEmpty
        }
    }

    public func pendingSyncBatch(localDevice: DeviceIdentity, limit: Int = 500) throws -> SyncOutboxBatch {
        let cap = max(1, limit)
        return try queue.sync {
            var remaining = cap
            var dictations: [SyncDictation] = []
            var meetings: [SyncMeeting] = []
            var terms: [SyncDictionaryTerm] = []
            var refusals: [SyncRefusal] = []

            let dictIDs = try queryOnQueue(
                "SELECT entity_id FROM sync_outbox WHERE entity_type = 'dictation' LIMIT ?;",
                bind: { sqlite3_bind_int64($0, 1, Int64(remaining)) }
            ) { column(0, $0) }
            for id in dictIDs {
                let rows: [SyncDictation] = try queryOnQueue(
                    """
                    SELECT id, created_at, final_text, raw_text, duration_seconds, word_count,
                        provider, model, target_app, target_bundle, usage_category, insertion_status,
                        source_device_id, source_device_name, source_device_platform, COALESCE(updated_at, created_at)
                    FROM dictations WHERE id = ?;
                    """,
                    bind: { bind(id, at: 1, $0) }
                ) { statement in
                    SyncDictation(
                        id: column(0, statement),
                        createdAt: sqlite3_column_double(statement, 1),
                        updatedAt: sqlite3_column_double(statement, 15),
                        deletedAt: nil,
                        finalText: column(2, statement),
                        rawText: column(3, statement),
                        durationSeconds: sqlite3_column_double(statement, 4),
                        wordCount: Int(sqlite3_column_int(statement, 5)),
                        provider: column(6, statement),
                        model: column(7, statement),
                        targetApp: optionalColumn(8, statement),
                        targetBundle: optionalColumn(9, statement),
                        usageCategory: optionalColumn(10, statement),
                        insertionStatus: column(11, statement),
                        sourceDeviceId: optionalColumn(12, statement) ?? localDevice.deviceId,
                        sourceDeviceName: optionalColumn(13, statement) ?? localDevice.deviceName,
                        sourceDevicePlatform: optionalColumn(14, statement) ?? localDevice.platform.rawValue
                    )
                }
                if let row = rows.first {
                    dictations.append(row)
                } else {
                    let tombstones: [Double] = try queryOnQueue(
                        "SELECT deleted_at FROM sync_tombstones WHERE entity_type = 'dictation' AND entity_id = ?;",
                        bind: { bind(id, at: 1, $0) }
                    ) { sqlite3_column_double($0, 0) }
                    if let ts = tombstones.first {
                        dictations.append(SyncDictation(
                            id: id, createdAt: ts, updatedAt: ts, deletedAt: ts,
                            finalText: "", rawText: "", durationSeconds: 0, wordCount: 0,
                            provider: "", model: "", insertionStatus: "deleted",
                            sourceDeviceId: localDevice.deviceId,
                            sourceDeviceName: localDevice.deviceName,
                            sourceDevicePlatform: localDevice.platform.rawValue
                        ))
                    } else {
                        try clearOutboxOnQueue(entityType: "dictation", entityID: id)
                    }
                }
            }
            remaining = max(0, remaining - dictations.count)

            if remaining > 0 {
                let meetIDs = try queryOnQueue(
                    "SELECT entity_id FROM sync_outbox WHERE entity_type = 'meeting' LIMIT ?;",
                    bind: { sqlite3_bind_int64($0, 1, Int64(remaining)) }
                ) { column(0, $0) }
                for id in meetIDs {
                    let rows: [SyncMeeting] = try queryOnQueue(
                        """
                        SELECT id, title, created_at, updated_at, duration_seconds, user_notes, raw_transcript, enhanced_notes,
                            source_device_id, source_device_name, source_device_platform
                        FROM meetings WHERE id = ?;
                        """,
                        bind: { bind(id, at: 1, $0) }
                    ) { statement in
                        SyncMeeting(
                            id: column(0, statement),
                            title: column(1, statement),
                            createdAt: sqlite3_column_double(statement, 2),
                            updatedAt: sqlite3_column_double(statement, 3),
                            deletedAt: nil,
                            durationSeconds: sqlite3_column_double(statement, 4),
                            userNotes: column(5, statement),
                            rawTranscript: column(6, statement),
                            enhancedNotes: column(7, statement),
                            sourceDeviceId: optionalColumn(8, statement) ?? localDevice.deviceId,
                            sourceDeviceName: optionalColumn(9, statement) ?? localDevice.deviceName,
                            sourceDevicePlatform: optionalColumn(10, statement) ?? localDevice.platform.rawValue
                        )
                    }
                    if let row = rows.first {
                        meetings.append(row)
                    } else {
                        let tombstones: [Double] = try queryOnQueue(
                            "SELECT deleted_at FROM sync_tombstones WHERE entity_type = 'meeting' AND entity_id = ?;",
                            bind: { bind(id, at: 1, $0) }
                        ) { sqlite3_column_double($0, 0) }
                        if let ts = tombstones.first {
                            meetings.append(SyncMeeting(
                                id: id, title: "", createdAt: ts, updatedAt: ts, deletedAt: ts,
                                durationSeconds: 0, userNotes: "", rawTranscript: "", enhancedNotes: "",
                                sourceDeviceId: localDevice.deviceId,
                                sourceDeviceName: localDevice.deviceName,
                                sourceDevicePlatform: localDevice.platform.rawValue
                            ))
                        } else {
                            try clearOutboxOnQueue(entityType: "meeting", entityID: id)
                        }
                    }
                }
                remaining = max(0, remaining - meetings.count)
            }

            if remaining > 0 {
                let termIDs = try queryOnQueue(
                    "SELECT entity_id FROM sync_outbox WHERE entity_type = 'dictionary' LIMIT ?;",
                    bind: { sqlite3_bind_int64($0, 1, Int64(remaining)) }
                ) { column(0, $0) }
                for id in termIDs {
                    let rows: [SyncDictionaryTerm] = try queryOnQueue(
                        """
                        SELECT id, term, created_at, COALESCE(confirmed_at, created_at), origin, judge_provider, judge_model, heard, source
                        FROM dictionary WHERE id = ?;
                        """,
                        bind: { bind(id, at: 1, $0) }
                    ) { statement in
                        SyncDictionaryTerm(
                            id: column(0, statement),
                            term: column(1, statement),
                            createdAt: sqlite3_column_double(statement, 2),
                            updatedAt: sqlite3_column_double(statement, 3),
                            deletedAt: nil,
                            origin: optionalColumn(4, statement),
                            judgeProvider: optionalColumn(5, statement),
                            judgeModel: optionalColumn(6, statement),
                            heard: optionalColumn(7, statement),
                            source: optionalColumn(8, statement)
                        )
                    }
                    if let row = rows.first {
                        terms.append(row)
                    } else {
                        let tombstones: [Double] = try queryOnQueue(
                            "SELECT deleted_at FROM sync_tombstones WHERE entity_type = 'dictionary' AND entity_id = ?;",
                            bind: { bind(id, at: 1, $0) }
                        ) { sqlite3_column_double($0, 0) }
                        if let ts = tombstones.first {
                            terms.append(SyncDictionaryTerm(id: id, term: "", createdAt: ts, updatedAt: ts, deletedAt: ts))
                        } else {
                            try clearOutboxOnQueue(entityType: "dictionary", entityID: id)
                        }
                    }
                }
                remaining = max(0, remaining - terms.count)
            }

            if remaining > 0 {
                let refTerms = try queryOnQueue(
                    "SELECT entity_id FROM sync_outbox WHERE entity_type = 'refusal' LIMIT ?;",
                    bind: { sqlite3_bind_int64($0, 1, Int64(remaining)) }
                ) { column(0, $0) }
                for term in refTerms {
                    let rows: [SyncRefusal] = try queryOnQueue(
                        "SELECT term, created_at FROM learning_refusals WHERE term = ? COLLATE NOCASE LIMIT 1;",
                        bind: { bind(term, at: 1, $0) }
                    ) { statement in
                        SyncRefusal(term: column(0, statement), createdAt: sqlite3_column_double(statement, 1))
                    }
                    if let row = rows.first {
                        refusals.append(row)
                    } else {
                        try clearOutboxOnQueue(entityType: "refusal", entityID: term)
                    }
                }
                remaining = max(0, remaining - refusals.count)
            }

            var apiCalls: [SyncApiCall] = []
            if remaining > 0 {
                let callIDs = try queryOnQueue(
                    "SELECT entity_id FROM sync_outbox WHERE entity_type = 'api_call' LIMIT ?;",
                    bind: { sqlite3_bind_int64($0, 1, Int64(remaining)) }
                ) { column(0, $0) }
                for id in callIDs {
                    let rows: [SyncApiCall] = try queryOnQueue(
                        """
                        SELECT id, created_at, api, model, audio_seconds, input_tokens, cached_tokens, output_tokens,
                            cost_usd, latency_ms, succeeded, fallback_from_api, fallback_stage, fallback_reason,
                            failure_cause, retry_of
                        FROM api_usage WHERE id = ?;
                        """,
                        bind: { bind(id, at: 1, $0) }
                    ) { statement in
                        SyncApiCall(
                            id: column(0, statement),
                            createdAt: sqlite3_column_double(statement, 1),
                            api: column(2, statement),
                            model: column(3, statement),
                            audioSeconds: sqlite3_column_double(statement, 4),
                            inputTokens: Int(sqlite3_column_int64(statement, 5)),
                            cachedTokens: Int(sqlite3_column_int64(statement, 6)),
                            outputTokens: Int(sqlite3_column_int64(statement, 7)),
                            costUSD: sqlite3_column_type(statement, 8) == SQLITE_NULL
                                ? nil : sqlite3_column_double(statement, 8),
                            latencyMs: Int(sqlite3_column_int64(statement, 9)),
                            succeeded: sqlite3_column_int(statement, 10) != 0,
                            fallbackFromAPI: optionalColumn(11, statement),
                            fallbackStage: optionalColumn(12, statement),
                            fallbackReason: optionalColumn(13, statement),
                            failureCause: optionalColumn(14, statement),
                            retryOf: optionalColumn(15, statement)
                        )
                    }
                    if let row = rows.first {
                        apiCalls.append(row)
                    } else {
                        try clearOutboxOnQueue(entityType: "api_call", entityID: id)
                    }
                }
            }

            return SyncOutboxBatch(
                dictations: dictations, meetings: meetings, dictionary: terms, refusals: refusals, apiCalls: apiCalls
            )
        }
    }

    public func clearSyncOutbox(_ batch: SyncOutboxBatch) throws {
        try transaction {
            for item in batch.dictations { try clearOutboxOnQueue(entityType: "dictation", entityID: item.id) }
            for item in batch.meetings { try clearOutboxOnQueue(entityType: "meeting", entityID: item.id) }
            for item in batch.dictionary { try clearOutboxOnQueue(entityType: "dictionary", entityID: item.id) }
            for item in batch.refusals { try clearOutboxOnQueue(entityType: "refusal", entityID: item.term) }
            for item in batch.apiCalls { try clearOutboxOnQueue(entityType: "api_call", entityID: item.id) }
        }
    }

    /// Applique un delta distant et avance le curseur de son appareil dans une unique transaction atomique SQLite
    /// (jamais de ré-ajout dans `sync_outbox` -> zéro boucle d'écho).
    public func applyRemoteDelta(
        _ delta: SyncDelta,
        peerDeviceID: String,
        sequence: Int
    ) throws -> (dictations: Int, meetings: Int, terms: Int) {
        try transaction {
            var pulledDictations = 0
            var pulledMeetings = 0
            var pulledTerms = 0
            for item in delta.dictations {
                if try applySyncedDictationOnQueue(item) { pulledDictations += 1 }
            }
            for meeting in delta.meetings {
                if try applySyncedMeetingOnQueue(meeting) { pulledMeetings += 1 }
            }
            for term in delta.dictionary {
                if try applySyncedDictionaryTermOnQueue(term) { pulledTerms += 1 }
            }
            for refusal in delta.refusals {
                try applySyncedRefusalOnQueue(refusal.term, createdAt: refusal.createdAt)
            }
            // Appels d'un autre appareil : comptés ici, jamais renvoyés (pas de `sync_outbox`), jamais en double.
            for call in delta.apiCalls ?? [] where !call.id.isEmpty && !call.api.isEmpty {
                try runOnQueue(
                    """
                    INSERT OR IGNORE INTO api_usage (
                        id, created_at, api, model, audio_seconds, input_tokens, cached_tokens,
                        output_tokens, cost_usd, latency_ms, succeeded,
                        fallback_from_api, fallback_stage, fallback_reason, failure_cause, retry_of
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                ) { statement in
                    bind(call.id, at: 1, statement)
                    sqlite3_bind_double(statement, 2, call.createdAt)
                    bind(call.api, at: 3, statement)
                    bind(call.model, at: 4, statement)
                    sqlite3_bind_double(statement, 5, call.audioSeconds)
                    sqlite3_bind_int64(statement, 6, Int64(call.inputTokens))
                    sqlite3_bind_int64(statement, 7, Int64(call.cachedTokens))
                    sqlite3_bind_int64(statement, 8, Int64(call.outputTokens))
                    if let cost = call.costUSD {
                        sqlite3_bind_double(statement, 9, cost)
                    } else {
                        sqlite3_bind_null(statement, 9)
                    }
                    sqlite3_bind_int64(statement, 10, Int64(call.latencyMs))
                    sqlite3_bind_int(statement, 11, call.succeeded ? 1 : 0)
                    bindOptional(call.fallbackFromAPI, at: 12, statement)
                    bindOptional(call.fallbackStage, at: 13, statement)
                    bindOptional(call.fallbackReason, at: 14, statement)
                    bindOptional(call.failureCause, at: 15, statement)
                    bindOptional(call.retryOf, at: 16, statement)
                }
            }
            try runOnQueue(
                """
                INSERT INTO sync_peers (device_id, last_sequence, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET last_sequence = excluded.last_sequence, updated_at = excluded.updated_at;
                """
            ) { statement in
                bind(peerDeviceID, at: 1, statement)
                sqlite3_bind_int64(statement, 2, Int64(sequence))
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            }
            return (pulledDictations, pulledMeetings, pulledTerms)
        }
    }

    /// Fusionne une dictée reçue par synchro : préserve l'audio local s'il existe déjà, sinon laisse
    /// `audio_path = NULL` et conserve `source_device_name` / `source_device_platform`.
    @discardableResult
    public func applySyncedDictation(_ item: SyncDictation, localDeviceID: String = "") throws -> Bool {
        _ = localDeviceID
        return try transaction { try applySyncedDictationOnQueue(item) }
    }

    private func applySyncedDictationOnQueue(_ item: SyncDictation) throws -> Bool {
        if let deletedAt = item.deletedAt {
            let existingUpdated = try queryOnQueue(
                "SELECT COALESCE(updated_at, created_at) FROM dictations WHERE id = ?;",
                bind: { bind(item.id, at: 1, $0) }
            ) { sqlite3_column_double($0, 0) }.first
            if let existingUpdated, existingUpdated > deletedAt { return false }
            try runOnQueue("DELETE FROM dictations WHERE id = ?;") { bind(item.id, at: 1, $0) }
            try? runOnQueue("DELETE FROM dictations_fts WHERE id = ?;") { bind(item.id, at: 1, $0) }
            try recordTombstoneOnQueue(entityType: "dictation", entityID: item.id, at: deletedAt)
            try clearOutboxOnQueue(entityType: "dictation", entityID: item.id)
            return existingUpdated != nil
        }
        let localTombstone = try queryOnQueue(
            "SELECT deleted_at FROM sync_tombstones WHERE entity_type = 'dictation' AND entity_id = ?;",
            bind: { bind(item.id, at: 1, $0) }
        ) { sqlite3_column_double($0, 0) }.first
        if let localTombstone, localTombstone >= item.updatedAt { return false }

        let existing = try queryOnQueue(
            "SELECT COALESCE(updated_at, created_at), alternative_text FROM dictations WHERE id = ?;",
            bind: { bind(item.id, at: 1, $0) }
        ) { (sqlite3_column_double($0, 0), optionalColumn(1, $0)) }.first
        if let existing, existing.0 >= item.updatedAt { return false }

        try runOnQueue(
            """
            INSERT INTO dictations (
                id, created_at, final_text, raw_text, duration_seconds, word_count,
                provider, model, target_app, target_bundle, usage_category,
                insertion_status, audio_path, audio_expires_at, alternative_text,
                source_device_id, source_device_name, source_device_platform, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                final_text = excluded.final_text,
                raw_text = excluded.raw_text,
                word_count = excluded.word_count,
                target_app = COALESCE(excluded.target_app, dictations.target_app),
                target_bundle = COALESCE(excluded.target_bundle, dictations.target_bundle),
                usage_category = COALESCE(excluded.usage_category, dictations.usage_category),
                insertion_status = excluded.insertion_status,
                source_device_id = COALESCE(dictations.source_device_id, excluded.source_device_id),
                source_device_name = COALESCE(dictations.source_device_name, excluded.source_device_name),
                source_device_platform = COALESCE(dictations.source_device_platform, excluded.source_device_platform),
                updated_at = excluded.updated_at;
            """
        ) { statement in
            bind(item.id, at: 1, statement)
            sqlite3_bind_double(statement, 2, item.createdAt)
            bind(item.finalText, at: 3, statement)
            bind(item.rawText, at: 4, statement)
            sqlite3_bind_double(statement, 5, item.durationSeconds)
            sqlite3_bind_int(statement, 6, Int32(clamping: item.wordCount))
            bind(item.provider, at: 7, statement)
            bind(item.model, at: 8, statement)
            bindOptional(item.targetApp, at: 9, statement)
            bindOptional(item.targetBundle, at: 10, statement)
            bindOptional(item.usageCategory, at: 11, statement)
            bind(item.insertionStatus, at: 12, statement)
            bind(item.sourceDeviceId, at: 13, statement)
            bind(item.sourceDeviceName, at: 14, statement)
            bind(item.sourceDevicePlatform, at: 15, statement)
            sqlite3_bind_double(statement, 16, item.updatedAt)
        }
        indexFTSOnQueue(id: item.id, finalText: item.finalText, rawText: item.rawText, alternativeText: existing?.1)
        try clearOutboxOnQueue(entityType: "dictation", entityID: item.id)
        return true
    }

    @discardableResult
    public func applySyncedMeeting(_ item: SyncMeeting) throws -> Bool {
        try transaction { try applySyncedMeetingOnQueue(item) }
    }

    private func applySyncedMeetingOnQueue(_ item: SyncMeeting) throws -> Bool {
        if let deletedAt = item.deletedAt {
            let existing = try queryOnQueue("SELECT updated_at FROM meetings WHERE id = ?;", bind: { bind(item.id, at: 1, $0) }) {
                sqlite3_column_double($0, 0)
            }.first
            if let existing, existing > deletedAt { return false }
            try runOnQueue("DELETE FROM meetings WHERE id = ?;") { bind(item.id, at: 1, $0) }
            try recordTombstoneOnQueue(entityType: "meeting", entityID: item.id, at: deletedAt)
            try clearOutboxOnQueue(entityType: "meeting", entityID: item.id)
            return existing != nil
        }
        let localTombstone = try queryOnQueue(
            "SELECT deleted_at FROM sync_tombstones WHERE entity_type = 'meeting' AND entity_id = ?;",
            bind: { bind(item.id, at: 1, $0) }
        ) { sqlite3_column_double($0, 0) }.first
        if let localTombstone, localTombstone >= item.updatedAt { return false }

        let existing = try queryOnQueue("SELECT updated_at FROM meetings WHERE id = ?;", bind: { bind(item.id, at: 1, $0) }) {
            sqlite3_column_double($0, 0)
        }.first
        if let existing, existing >= item.updatedAt { return false }
        try runOnQueue(
            """
            INSERT INTO meetings (
                id, title, created_at, updated_at, duration_seconds, user_notes, raw_transcript, enhanced_notes,
                source_device_id, source_device_name, source_device_platform
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                updated_at = excluded.updated_at,
                duration_seconds = excluded.duration_seconds,
                user_notes = excluded.user_notes,
                raw_transcript = excluded.raw_transcript,
                enhanced_notes = excluded.enhanced_notes,
                source_device_id = COALESCE(meetings.source_device_id, excluded.source_device_id),
                source_device_name = COALESCE(meetings.source_device_name, excluded.source_device_name),
                source_device_platform = COALESCE(meetings.source_device_platform, excluded.source_device_platform);
            """
        ) { statement in
            bind(item.id, at: 1, statement)
            bind(item.title, at: 2, statement)
            sqlite3_bind_double(statement, 3, item.createdAt)
            sqlite3_bind_double(statement, 4, item.updatedAt)
            sqlite3_bind_double(statement, 5, item.durationSeconds)
            bind(item.userNotes, at: 6, statement)
            bind(item.rawTranscript, at: 7, statement)
            bind(item.enhancedNotes, at: 8, statement)
            bind(item.sourceDeviceId, at: 9, statement)
            bind(item.sourceDeviceName, at: 10, statement)
            bind(item.sourceDevicePlatform, at: 11, statement)
        }
        try clearOutboxOnQueue(entityType: "meeting", entityID: item.id)
        return true
    }

    @discardableResult
    public func applySyncedDictionaryTerm(_ item: SyncDictionaryTerm) throws -> Bool {
        try transaction { try applySyncedDictionaryTermOnQueue(item) }
    }

    private func applySyncedDictionaryTermOnQueue(_ item: SyncDictionaryTerm) throws -> Bool {
        if let deletedAt = item.deletedAt {
            let existing = try queryOnQueue("SELECT COALESCE(confirmed_at, created_at) FROM dictionary WHERE id = ?;", bind: { bind(item.id, at: 1, $0) }) {
                sqlite3_column_double($0, 0)
            }.first
            if let existing, existing > deletedAt { return false }
            try runOnQueue("DELETE FROM dictionary WHERE id = ?;") { bind(item.id, at: 1, $0) }
            try recordTombstoneOnQueue(entityType: "dictionary", entityID: item.id, at: deletedAt)
            try clearOutboxOnQueue(entityType: "dictionary", entityID: item.id)
            return existing != nil
        }
        let localTombstone = try queryOnQueue(
            "SELECT deleted_at FROM sync_tombstones WHERE entity_type = 'dictionary' AND entity_id = ?;",
            bind: { bind(item.id, at: 1, $0) }
        ) { sqlite3_column_double($0, 0) }.first
        if let localTombstone, localTombstone >= item.updatedAt { return false }

        let cleaned = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let conflictOther = try queryOnQueue(
            "SELECT id FROM dictionary WHERE term = ? COLLATE NOCASE AND id <> ? LIMIT 1;",
            bind: { bind(cleaned, at: 1, $0); bind(item.id, at: 2, $0) }
        ) { column(0, $0) }.first
        guard conflictOther == nil else { return false }

        let existing = try queryOnQueue("SELECT term FROM dictionary WHERE id = ?;", bind: { bind(item.id, at: 1, $0) }) {
            column(0, $0)
        }.first
        if existing == cleaned { return false }

        try runOnQueue(
            """
            INSERT INTO dictionary (id, term, created_at, origin, judge_provider, judge_model, heard, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                term = excluded.term,
                origin = COALESCE(dictionary.origin, excluded.origin),
                judge_provider = COALESCE(dictionary.judge_provider, excluded.judge_provider),
                judge_model = COALESCE(dictionary.judge_model, excluded.judge_model),
                heard = COALESCE(dictionary.heard, excluded.heard),
                source = COALESCE(dictionary.source, excluded.source);
            """
        ) { statement in
            bind(item.id, at: 1, statement)
            bind(cleaned, at: 2, statement)
            sqlite3_bind_double(statement, 3, item.createdAt)
            bindOptional(item.origin, at: 4, statement)
            bindOptional(item.judgeProvider, at: 5, statement)
            bindOptional(item.judgeModel, at: 6, statement)
            bindOptional(item.heard, at: 7, statement)
            bindOptional(item.source, at: 8, statement)
        }
        try clearOutboxOnQueue(entityType: "dictionary", entityID: item.id)
        return true
    }

    private func applySyncedRefusalOnQueue(_ term: String, createdAt: Double) throws {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        try runOnQueue("INSERT OR IGNORE INTO learning_refusals (term, created_at) VALUES (?, ?);") { statement in
            bind(cleaned, at: 1, statement)
            sqlite3_bind_double(statement, 2, createdAt)
        }
        try clearOutboxOnQueue(entityType: "refusal", entityID: cleaned)
    }

    private func markOutboxOnQueue(entityType: String, entityID: String) throws {
        try runOnQueue("INSERT OR IGNORE INTO sync_outbox (entity_type, entity_id) VALUES (?, ?);") { statement in
            bind(entityType, at: 1, statement)
            bind(entityID, at: 2, statement)
        }
    }

    private func clearOutboxOnQueue(entityType: String, entityID: String) throws {
        try runOnQueue("DELETE FROM sync_outbox WHERE entity_type = ? AND entity_id = ?;") { statement in
            bind(entityType, at: 1, statement)
            bind(entityID, at: 2, statement)
        }
    }

    private func recordTombstoneOnQueue(entityType: String, entityID: String, at timestamp: Double) throws {
        try runOnQueue(
            """
            INSERT INTO sync_tombstones (entity_type, entity_id, deleted_at) VALUES (?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET deleted_at = MAX(sync_tombstones.deleted_at, excluded.deleted_at);
            """
        ) { statement in
            bind(entityType, at: 1, statement)
            bind(entityID, at: 2, statement)
            sqlite3_bind_double(statement, 3, timestamp)
        }
    }

    private func indexFTSOnQueue(id: String, finalText: String, rawText: String, alternativeText: String?) {
        try? runOnQueue("DELETE FROM dictations_fts WHERE id = ?;") { bind(id, at: 1, $0) }
        try? runOnQueue("INSERT INTO dictations_fts (id, final_text, raw_text, alternative_text) VALUES (?, ?, ?, ?);") { statement in
            bind(id, at: 1, statement)
            bind(finalText, at: 2, statement)
            bind(rawText, at: 3, statement)
            bindOptional(alternativeText, at: 4, statement)
        }
    }

    /// Mémorise un mot que l'utilisateur a refusé dans la bulle. La casse ne compte pas.
    public func rememberRefusal(_ term: String) throws {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        try transaction {
            try runOnQueue("INSERT OR IGNORE INTO learning_refusals (term, created_at) VALUES (?, ?);") { statement in
                bind(cleaned, at: 1, statement)
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            }
            try markOutboxOnQueue(entityType: "refusal", entityID: cleaned)
        }
    }

    public func refusedTerms() throws -> [String] {
        try query("SELECT term FROM learning_refusals ORDER BY created_at, term COLLATE NOCASE;") { statement in
            column(0, statement)
        }
    }

    public func hasRefused(_ term: String) throws -> Bool {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        return try refusedTerms().contains { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
    }

    private func execute(_ sql: String) throws {
        try queue.sync { try executeOnQueue(sql) }
    }

    private func executeOnQueue(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &error)
        if code != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite \(code)"
            sqlite3_free(error)
            throw StoreError.message(message)
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        try queue.sync { try runOnQueue(sql, bind: bind) }
    }

    private func runOnQueue(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.message(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw StoreError.message(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in },
        map: (OpaquePointer?) throws -> T
    ) throws -> [T] {
        try queue.sync { try queryOnQueue(sql, bind: bind, map: map) }
    }

    private func queryOnQueue<T>(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in },
        map: (OpaquePointer?) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.message(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var rows: [T] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            rows.append(try map(statement))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else {
            throw StoreError.message(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try queue.sync {
            try executeOnQueue("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let result = try operation()
                try executeOnQueue("COMMIT;")
                return result
            } catch {
                try? executeOnQueue("ROLLBACK;")
                throw error
            }
        }
    }

    /// Longueur en octets : un caractère nul dans le texte ne le coupe pas (SQLite s'arrêterait au premier).
    private func bind(_ value: String, at index: Int32, _ statement: OpaquePointer?) {
        sqlite3_bind_text64(statement, index, value, UInt64(value.utf8.count), transient, UInt8(SQLITE_UTF8))
    }

    private func bindOptional(_ value: String?, at index: Int32, _ statement: OpaquePointer?) {
        if let value {
            bind(value, at: index, statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func column(_ index: Int32, _ statement: OpaquePointer?) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        // Après sqlite3_column_text, comme le demande SQLite : la taille du texte en UTF-8, caractères nuls compris.
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, index)))
        return String(decoding: bytes, as: UTF8.self)
    }

    private func optionalColumn(_ index: Int32, _ statement: OpaquePointer?) -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return column(index, statement)
    }
}
