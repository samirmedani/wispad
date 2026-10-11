import Foundation
import WispadCore

// Libellés traduits des types du cœur. Le cœur ne porte aucun texte d'interface ; ses titres français
// (`title`, `titleFR`) ne servent qu'aux journaux et aux tests.

extension UsageAPI {
    var label: String {
        switch self {
        case .xaiStreaming: return String(localized: "xAI · transcription en direct")
        case .xaiFile: return String(localized: "xAI · transcription de fichier")
        case .openAIStreaming: return String(localized: "OpenAI · transcription en direct")
        case .openAIFile: return String(localized: "OpenAI · transcription de fichier")
        case .deepSeekCleanup: return String(localized: "DeepSeek · correction")
        case .xaiCleanup: return String(localized: "xAI · correction")
        case .openAICleanup: return String(localized: "OpenAI · correction")
        case .typesafeJudge: return String(localized: "TypeSafe · Jev (dictionnaire)")
        }
    }
}

extension FallbackStage {
    var label: String {
        switch self {
        case .transcription: return String(localized: "Transcription")
        case .correction: return String(localized: "Correction")
        case .dictionary: return String(localized: "Dictionnaire")
        }
    }
}

extension OutputMuteMode {
    var label: String {
        switch self {
        case .speakersOnly: return String(localized: "Haut-parleurs seulement")
        case .always: return String(localized: "Toujours, casque compris")
        }
    }
}

extension StatsPeriod {
    var label: String {
        switch self {
        case .today: return String(localized: "Aujourd'hui")
        case .days7: return String(localized: "7 jours")
        case .days30: return String(localized: "30 jours")
        case .all: return String(localized: "Tout")
        }
    }
}

extension RetentionMode {
    var label: String {
        switch self {
        case .deleteOnSuccess: return String(localized: "Supprimer après une insertion réussie")
        case .temporary: return String(localized: "Conserver temporairement")
        case .keepWithHistory: return String(localized: "Conserver avec l'historique")
        }
    }
}

extension DictationLanguage {
    var label: String {
        switch self {
        case .french: return "Français"
        case .english: return "English"
        case .auto: return String(localized: "Automatique")
        }
    }
}

extension SpeechModel {
    /// « En direct 0,20 $/h · fichier 0,10 $/h ».
    var localizedCostSummary: String {
        String(localized: "En direct \(MoneyFormat.price(streamingUSDPerHour))/h · fichier \(MoneyFormat.price(batchUSDPerHour))/h")
    }
}

extension DictationRecord {
    /// Fournisseur de la transcription, en clair : « xAI » ou « OpenAI ».
    var providerLabel: String {
        ProviderID(rawValue: provider)?.displayName ?? provider
    }
}

enum PriceText {
    /// Tarif d'un modèle, en clair, pour l'aide au survol de l'écran Consommation.
    static func describe(model: String, at date: Date = Date()) -> String? {
        if model == CleanupModel.deepSeek {
            return String(localized: "\(model) : \(MoneyFormat.price(0.30)) / \(MoneyFormat.price(1.20)) par million de jetons, moitié prix hors heures pleines")
        }
        if let rate = Pricing.tokenRate(model: model, at: date) {
            if rate.output > 0 {
                return String(localized: "\(model) : \(MoneyFormat.price(rate.input)) / \(MoneyFormat.price(rate.output)) par million de jetons")
            }
            return String(localized: "\(model) : \(MoneyFormat.price(rate.input)) par million de jetons (sortie gratuite)")
        }
        for provider in ProviderID.allCases {
            if let speech = ProviderCatalog.model(id: model, provider: provider) {
                return "\(speech.displayName) : \(speech.localizedCostSummary)"
            }
        }
        if let speech = ProviderCatalog.models.first(where: { $0.fileModel == model && $0.fileModel != $0.id }) {
            return String(localized: "\(model) : fichier \(MoneyFormat.price(speech.batchUSDPerHour))/h")
        }
        return nil
    }
}
