import Foundation

public enum DictationOrigin: String, Codable, Equatable, Sendable {
    case hold
    case toggle
    case retry
}

/// Codes fermés : aucun message fournisseur ni contenu dicté n'entre dans les traces.
public enum DictationOutcome: String, Codable, Equatable, Sendable {
    case inserted
    case pasteSent
    case pending
    case noTarget
    case refusedSecure
    case insertionFailed
    case transcriptionFailed
    case cancelled
    case noSpeech
    case microphoneDenied
    case captureFailed
    case keyUnavailable
    case historyFailed
    /// Consigne sur une sélection restée sans réponse : rien n'est collé.
    case commandFailed
}

/// Une valeur absente correspond à une étape non observée, jamais à une durée nulle.
public struct DictationTimings: Codable, Equatable, Sendable {
    public var microphoneMs: Int?
    public var firstAudioMs: Int?
    public var streamReadyMs: Int?
    public var transcriptionMs: Int?
    public var correctionMs: Int?
    public var insertionMs: Int?
    public var afterReleaseMs: Int?

    public init(
        microphoneMs: Int? = nil,
        firstAudioMs: Int? = nil,
        streamReadyMs: Int? = nil,
        transcriptionMs: Int? = nil,
        correctionMs: Int? = nil,
        insertionMs: Int? = nil,
        afterReleaseMs: Int? = nil
    ) {
        self.microphoneMs = microphoneMs
        self.firstAudioMs = firstAudioMs
        self.streamReadyMs = streamReadyMs
        self.transcriptionMs = transcriptionMs
        self.correctionMs = correctionMs
        self.insertionMs = insertionMs
        self.afterReleaseMs = afterReleaseMs
    }
}

public struct DictationAPICall: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var api: UsageAPI
    public var model: String
    public var latencyMs: Int
    public var succeeded: Bool
    public var fallback: APIFallback?

    public init(_ event: UsageEvent) {
        id = event.id
        api = event.api
        model = event.model
        latencyMs = event.latencyMs
        succeeded = event.succeeded
        fallback = event.fallback
    }

    private enum CodingKeys: String, CodingKey {
        case id, api, model, latencyMs, succeeded, fallback
    }

    private struct FallbackPayload: Codable {
        var fromAPI: UsageAPI
        var stage: String
        var reason: String
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        api = try values.decode(UsageAPI.self, forKey: .api)
        model = try values.decode(String.self, forKey: .model)
        latencyMs = try values.decode(Int.self, forKey: .latencyMs)
        succeeded = try values.decode(Bool.self, forKey: .succeeded)
        if let payload = try values.decodeIfPresent(FallbackPayload.self, forKey: .fallback) {
            guard let stage = FallbackStage(rawValue: payload.stage),
                  let reason = FallbackReason(rawValue: payload.reason) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .fallback, in: values, debugDescription: "Métadonnée de relais inconnue."
                )
            }
            fallback = APIFallback(fromAPI: payload.fromAPI, stage: stage, reason: reason)
        } else {
            fallback = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(api, forKey: .api)
        try values.encode(model, forKey: .model)
        try values.encode(latencyMs, forKey: .latencyMs)
        try values.encode(succeeded, forKey: .succeeded)
        if let fallback {
            try values.encode(
                FallbackPayload(fromAPI: fallback.fromAPI, stage: fallback.stage.rawValue, reason: fallback.reason.rawValue),
                forKey: .fallback
            )
        }
    }
}

/// D'où vient le texte brut retenu. Aucune transcription n'est stockée ici.
public enum TranscriptSource: String, Codable, Equatable, Sendable {
    case stream
    case file
}

/// Pourquoi cette source a été retenue. Aucun texte.
public enum TranscriptChoice: String, Codable, Equatable, Sendable {
    case equivalent
    case diverged
    case fileTimeout
    case fileFailed
    case streamEmpty
    case settingOff
}

public struct DictationTrace: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var dictationID: String?
    public var createdAt: Date
    public var origin: DictationOrigin
    public var timings: DictationTimings
    public var calls: [DictationAPICall]
    public var outcome: DictationOutcome
    /// Repli fichier parce que la fin du flux n'était pas fiable. Aucun texte.
    public var streamFallback: StreamEndFallback?
    /// Source du texte brut retenu, quand la fin de dictée l'a tranchée.
    public var transcriptSource: TranscriptSource?
    /// Raison de ce choix. Absente sur les traces d'avant la vérification fichier.
    public var transcriptChoice: TranscriptChoice?
    /// Délai observé du fichier, en millisecondes. Absent s'il n'a pas été demandé.
    public var fileLatencyMs: Int?
    /// Corrections préparées pendant l'écoute, aux pauses de la parole. Absent : aucune.
    public var earlyCorrections: Int?
    /// La correction collée était déjà prête (ou en cours) au moment d'arrêter.
    public var earlyCorrectionUsed: Bool?
    /// Flux et fichier en désaccord : nombre de mots qui diffèrent après normalisation. Aucun texte.
    public var divergentWords: Int?
    /// Nombre de mots du flux et du fichier quand ils sont comparés (un flux doublé se voit ici). Aucun texte.
    public var streamWords: Int?
    public var fileWords: Int?
    /// Consigne appliquée au texte sélectionné au lieu d'une dictée à coller.
    public var selectionCommand: Bool?
    /// Fichier différent d'un ou deux mots : ils ont été reportés dans la correction du flux, sans nouvel appel.
    public var correctionPatched: Bool?

    public init(
        id: String = UUID().uuidString,
        dictationID: String? = nil,
        createdAt: Date = Date(),
        origin: DictationOrigin,
        timings: DictationTimings = DictationTimings(),
        calls: [DictationAPICall] = [],
        outcome: DictationOutcome = .pending,
        streamFallback: StreamEndFallback? = nil,
        transcriptSource: TranscriptSource? = nil,
        transcriptChoice: TranscriptChoice? = nil,
        fileLatencyMs: Int? = nil
    ) {
        self.id = id
        self.dictationID = dictationID
        self.createdAt = createdAt
        self.origin = origin
        self.timings = timings
        self.calls = calls
        self.outcome = outcome
        self.streamFallback = streamFallback
        self.transcriptSource = transcriptSource
        self.transcriptChoice = transcriptChoice
        self.fileLatencyMs = fileLatencyMs
    }
}
