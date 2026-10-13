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
        alternativeText: String? = nil
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

    public init(id: String = UUID().uuidString, term: String, createdAt: Date = Date(),
                origin: DictionaryOrigin = .unknown, confirmedAt: Date? = nil) {
        self.id = id
        self.term = term
        self.createdAt = createdAt
        self.origin = origin
        self.confirmedAt = confirmedAt
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

    public init(path: String) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &connection, flags, nil) != SQLITE_OK {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "ouverture impossible"
            sqlite3_close(connection)
            throw StoreError.message(message)
        }
        db = connection
        sqlite3_busy_timeout(connection, 2_000)
        try execute("PRAGMA journal_mode = WAL;")
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
        if !dictationColumns.contains("alternative_text") {
            try execute("ALTER TABLE dictations ADD COLUMN alternative_text TEXT;")
        }
        try execute("CREATE INDEX IF NOT EXISTS dictations_created ON dictations(created_at DESC);")
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
                confirmed_at REAL
            );
            """
        )
        // Origine des mots : les colonnes s'ajoutent aux anciennes bases sans toucher aux mots, et restent NULL sur
        // les mots d'avant ce suivi (origine inconnue) : l'historique ne relie aucun appel de jugement à un mot,
        // rien ne permet de la retrouver de façon sûre.
        let dictionaryColumns = Set(try query("PRAGMA table_info(dictionary);") { column(1, $0) })
        let originColumns = [("origin", "TEXT"), ("judge_provider", "TEXT"), ("judge_model", "TEXT"), ("confirmed_at", "REAL")]
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
                fallback_reason TEXT
            );
            """
        )
        // Les colonnes restent NULL sur les anciennes lignes : une API de destination
        // ne suffit pas à distinguer un choix explicite d'une bascule automatique.
        let usageColumns = Set(try query("PRAGMA table_info(api_usage);") { column(1, $0) })
        for name in ["fallback_from_api", "fallback_stage", "fallback_reason"] where !usageColumns.contains(name) {
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
        try execute("INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('learning_refusals_v1', '1');")
        try run("INSERT OR IGNORE INTO app_metadata (key, value) VALUES ('fallback_tracking_started_at', ?);") { statement in
            sqlite3_bind_double(statement, 1, fallbackTrackingStartedAt.timeIntervalSince1970)
        }
        let trackingDates = try query("SELECT value FROM app_metadata WHERE key = 'fallback_tracking_started_at';") {
            Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
        }
        if let date = trackingDates.first { fallbackTrackingStartedAt = date }
        // Ancienne date de début du suivi financier, sans usage depuis la fin de la séparation
        // Utilisation / Développement. Les appels eux-mêmes restent intacts.
        try execute("DELETE FROM app_metadata WHERE key = 'financial_tracking_started_at';")
        try migrateUsageAccuracy()
        try forgetRetiredValues()
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
        try run(
            """
            INSERT INTO dictations (
                id, created_at, final_text, raw_text, duration_seconds, word_count,
                provider, model, target_app, target_bundle, usage_category,
                insertion_status, audio_path, audio_expires_at, alternative_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        ) { statement in
            bind(record.id, at: 1, statement)
            sqlite3_bind_double(statement, 2, record.createdAt.timeIntervalSince1970)
            bind(record.finalText, at: 3, statement)
            bind(record.rawText, at: 4, statement)
            sqlite3_bind_double(statement, 5, record.durationSeconds)
            sqlite3_bind_int(statement, 6, Int32(record.wordCount))
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
        }
    }

    public func dictations() throws -> [DictationRecord] {
        try query("SELECT * FROM dictations ORDER BY created_at DESC;") { statement in
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
                alternativeText: optionalColumn(14, statement)
            )
        }
    }

    public func updateTranscript(id: String, finalText: String, rawText: String, wordCount: Int) throws {
        try run("UPDATE dictations SET final_text = ?, raw_text = ?, word_count = ? WHERE id = ?;") { statement in
            bind(finalText, at: 1, statement)
            bind(rawText, at: 2, statement)
            sqlite3_bind_int(statement, 3, Int32(wordCount))
            bind(id, at: 4, statement)
        }
    }

    public func updateStatus(id: String, status: String) throws {
        try run("UPDATE dictations SET insertion_status = ? WHERE id = ?;") { statement in
            bind(status, at: 1, statement)
            bind(id, at: 2, statement)
        }
    }

    /// Dictée livrée plus tard (« Coller la dernière dictée ») : nouveau statut et app où elle a été collée.
    /// Une app inconnue (nil) laisse celle déjà enregistrée.
    public func updateDelivery(id: String, status: String, targetApp: String?, targetBundle: String?, usageCategory: String?) throws {
        try run(
            """
            UPDATE dictations SET insertion_status = ?, target_app = COALESCE(?, target_app),
                target_bundle = COALESCE(?, target_bundle), usage_category = COALESCE(?, usage_category)
            WHERE id = ?;
            """
        ) { statement in
            bind(status, at: 1, statement)
            bindOptional(targetApp, at: 2, statement)
            bindOptional(targetBundle, at: 3, statement)
            bindOptional(usageCategory, at: 4, statement)
            bind(id, at: 5, statement)
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

    public func deleteDictation(id: String) throws {
        // La clé étrangère supprime aussi les traces, dans la même opération SQLite.
        try run("DELETE FROM dictations WHERE id = ?;") { statement in
            bind(id, at: 1, statement)
        }
    }

    public func deleteAllDictations() throws {
        try execute("DELETE FROM dictations;")
    }

    /// Le record associé doit déjà exister. Les captures sans dictée sont bornées à 100.
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
    public func insertUsage(_ event: UsageEvent) throws {
        try run(
            """
            INSERT INTO api_usage (
                id, created_at, api, model, audio_seconds, input_tokens, cached_tokens,
                output_tokens, cost_usd, latency_ms, succeeded,
                fallback_from_api, fallback_stage, fallback_reason
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        }
    }

    public func usageEvents() throws -> [UsageEvent] {
        let rows: [UsageEvent?] = try query(
            """
            SELECT id, created_at, api, model, audio_seconds, input_tokens, cached_tokens,
                output_tokens, cost_usd, latency_ms, succeeded,
                fallback_from_api, fallback_stage, fallback_reason
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
                fallback: fallback
            )
        }
        return rows.compactMap { $0 }
    }

    public func dictionary() throws -> [DictionaryEntry] {
        try query(
            """
            SELECT id, term, created_at, origin, judge_provider, judge_model, confirmed_at
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
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            )
        }
    }

    /// Ajoute un mot avec son origine. Sans origine précisée, il est noté comme d'avant le suivi : jamais « ajouté
    /// par toi » ni un juge par défaut. Un mot déjà présent, à la casse près, garde son entrée et son origine.
    public func addTerm(_ term: String, origin: DictionaryOrigin = .unknown) throws {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        try run(
            """
            INSERT OR IGNORE INTO dictionary (id, term, created_at, origin, judge_provider, judge_model)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        ) { statement in
            bind(UUID().uuidString, at: 1, statement)
            bind(cleaned, at: 2, statement)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            bindOptional(origin.storedValue, at: 4, statement)
            bindOptional(origin.judge?.provider, at: 5, statement)
            bindOptional(origin.judge?.model, at: 6, statement)
        }
    }

    /// « Oui » dans la bulle « Le garder ? » : note la confirmation d'un mot appris, sans changer son origine.
    /// Un mot ajouté à la main, d'avant le suivi ou déjà confirmé n'est pas touché. La casse ne compte pas.
    public func confirmLearnedTerm(_ term: String) throws {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        try run(
            """
            UPDATE dictionary SET confirmed_at = ?
            WHERE term = ? AND origin IN ('jev', 'model') AND confirmed_at IS NULL;
            """
        ) { statement in
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            bind(cleaned, at: 2, statement)
        }
    }

    public func deleteTerm(id: String) throws {
        try run("DELETE FROM dictionary WHERE id = ?;") { statement in
            bind(id, at: 1, statement)
        }
    }

    /// Mémorise un mot que l'utilisateur a refusé dans la bulle. La casse ne compte pas.
    public func rememberRefusal(_ term: String) throws {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        try run("INSERT OR IGNORE INTO learning_refusals (term, created_at) VALUES (?, ?);") { statement in
            bind(cleaned, at: 1, statement)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
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

    private func bind(_ value: String, at index: Int32, _ statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, transient)
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
        return String(cString: pointer)
    }

    private func optionalColumn(_ index: Int32, _ statement: OpaquePointer?) -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return column(index, statement)
    }
}
