import Foundation

public enum ProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case xai
    case openAI = "openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .xai: return "xAI"
        case .openAI: return "OpenAI"
        }
    }

    public var defaultLiveModel: String {
        switch self {
        case .xai: return "grok-voice-transcribe-2.0"
        case .openAI: return "gpt-live-transcribe"
        }
    }

    public var defaultCleanupModel: String {
        switch self {
        case .xai: return "grok-4.7"
        case .openAI: return "gpt-5.6-luna"
        }
    }

    public var keyValidationURL: URL {
        switch self {
        case .xai:
            return URL(string: "https://api.x.ai/v1/models")!
        case .openAI:
            return URL(string: "https://api.openai.com/v1/models")!
        }
    }
}

public struct SpeechModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: ProviderID
    public var displayName: String
    public var streamingUSDPerHour: Double
    public var batchUSDPerHour: Double
    public var recommended: Bool
    public var fileModel: String
    /// Nom du modèle de l'enregistrement complet (« GPT Transcribe ») : celui du direct s'il est le même.
    public var fileDisplayName: String

    public init(
        id: String,
        provider: ProviderID,
        displayName: String,
        streamingUSDPerHour: Double,
        batchUSDPerHour: Double,
        recommended: Bool,
        fileModel: String? = nil,
        fileDisplayName: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.streamingUSDPerHour = streamingUSDPerHour
        self.batchUSDPerHour = batchUSDPerHour
        self.recommended = recommended
        self.fileModel = fileModel ?? id
        self.fileDisplayName = fileDisplayName ?? displayName
    }

    public var costSummary: String {
        "En direct \(MoneyFormat.price(streamingUSDPerHour, locale: MoneyFormat.french))/h · fichier \(MoneyFormat.price(batchUSDPerHour, locale: MoneyFormat.french))/h"
    }
}

public enum ProviderCatalog {
    public static let models: [SpeechModel] = [
        SpeechModel(
            id: "grok-voice-transcribe-2.0",
            provider: .xai,
            displayName: "Grok Voice Transcribe 2.0",
            streamingUSDPerHour: 0.20,
            batchUSDPerHour: 0.10,
            recommended: true
        ),
        SpeechModel(
            id: "grok-voice-transcribe-1.0",
            provider: .xai,
            displayName: "Grok Voice Transcribe 1.0",
            streamingUSDPerHour: 0.20,
            batchUSDPerHour: 0.10,
            recommended: false
        ),
        SpeechModel(
            id: "gpt-live-transcribe",
            provider: .openAI,
            displayName: "GPT Live Transcribe",
            streamingUSDPerHour: 1.02,
            batchUSDPerHour: 0.27,
            recommended: true,
            fileModel: "gpt-transcribe",
            fileDisplayName: "GPT Transcribe"
        ),
        SpeechModel(
            id: "gpt-4o-mini-transcribe",
            provider: .openAI,
            displayName: "GPT-4o mini Transcribe",
            streamingUSDPerHour: 0.18,
            batchUSDPerHour: 0.18,
            recommended: false
        )
    ]

    public static func models(for provider: ProviderID) -> [SpeechModel] {
        models.filter { $0.provider == provider }
    }

    public static func model(id: String, provider: ProviderID) -> SpeechModel? {
        models.first { $0.id == id && $0.provider == provider }
    }

    public static func liveModel(id: String, provider: ProviderID) -> SpeechModel {
        model(id: id, provider: provider)
            ?? models(for: provider).first { $0.recommended }
            ?? models(for: provider)[0]
    }
}
