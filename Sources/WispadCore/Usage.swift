import Foundation
import CoreFoundation

/// Chaque appel facturable de l'app, regroupé par API pour l'écran Consommation.
public enum UsageAPI: String, CaseIterable, Sendable, Codable {
    case xaiStreaming = "xai.stt.stream"
    case xaiFile = "xai.stt.file"
    case openAIStreaming = "openai.stt.stream"
    case openAIFile = "openai.stt.file"
    case deepSeekCleanup = "deepseek.cleanup"
    case xaiCleanup = "xai.cleanup"
    case openAICleanup = "openai.cleanup"
    case typesafeJudge = "typesafe.judge"

    public var title: String {
        switch self {
        case .xaiStreaming: return "xAI · transcription en direct"
        case .xaiFile: return "xAI · transcription de fichier"
        case .openAIStreaming: return "OpenAI · transcription en direct"
        case .openAIFile: return "OpenAI · transcription de fichier"
        case .deepSeekCleanup: return "DeepSeek · correction"
        case .xaiCleanup: return "xAI · correction"
        case .openAICleanup: return "OpenAI · correction"
        case .typesafeJudge: return "TypeSafe · Jev (dictionnaire)"
        }
    }

    public var provider: String {
        switch self {
        case .xaiStreaming, .xaiFile, .xaiCleanup: return "xAI"
        case .openAIStreaming, .openAIFile, .openAICleanup: return "OpenAI"
        case .deepSeekCleanup: return "DeepSeek"
        case .typesafeJudge: return "TypeSafe"
        }
    }

    public var isAudio: Bool {
        switch self {
        case .xaiStreaming, .xaiFile, .openAIStreaming, .openAIFile: return true
        case .deepSeekCleanup, .xaiCleanup, .openAICleanup, .typesafeJudge: return false
        }
    }

    public static func transcription(_ provider: ProviderID, streaming: Bool) -> UsageAPI {
        switch provider {
        case .xai: return streaming ? .xaiStreaming : .xaiFile
        case .openAI: return streaming ? .openAIStreaming : .openAIFile
        }
    }
}

public struct TokenUsage: Equatable, Sendable {
    /// Jetons d'entrée facturés plein tarif (hors cache).
    public var input: Int
    public var cachedInput: Int
    public var output: Int

    public init(input: Int = 0, cachedInput: Int = 0, output: Int = 0) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
    }

    /// Lit le bloc `usage` d'une réponse chat/completions (DeepSeek, xAI, OpenAI).
    public static func parse(_ object: [String: Any]?) -> TokenUsage? {
        guard let object,
              let prompt = nonnegativeInteger(object["prompt_tokens"]),
              let output = nonnegativeInteger(object["completion_tokens"]) else { return nil }
        let details = object["prompt_tokens_details"] as? [String: Any]
        let cached: Int
        if let value = object["prompt_cache_hit_tokens"] ?? details?["cached_tokens"] {
            guard let parsed = nonnegativeInteger(value), parsed <= prompt else { return nil }
            cached = parsed
        } else {
            cached = 0
        }
        return TokenUsage(input: prompt - cached, cachedInput: cached, output: output)
    }

    static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = value as? Int, count >= 0,
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return count
    }
}

public struct UsageEvent: Identifiable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var api: UsageAPI
    public var model: String
    public var audioSeconds: Double
    public var tokens: TokenUsage
    /// nil : compteurs, tarif ou facturation de la tentative inconnus.
    public var costUSD: Double?
    public var latencyMs: Int
    public var succeeded: Bool
    /// Présent uniquement quand cet appel a été tenté en remplacement d'une autre API.
    public var fallback: APIFallback?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        api: UsageAPI,
        model: String,
        audioSeconds: Double = 0,
        tokens: TokenUsage = TokenUsage(),
        costUSD: Double?,
        latencyMs: Int = 0,
        succeeded: Bool = true,
        fallback: APIFallback? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.api = api
        self.model = model
        self.audioSeconds = audioSeconds
        self.tokens = tokens
        self.costUSD = costUSD
        self.latencyMs = latencyMs
        self.succeeded = succeeded
        self.fallback = fallback
    }

    public static func transcription(
        provider: ProviderID,
        streaming: Bool,
        model: String,
        billedModel: String? = nil,
        audioSeconds: Double,
        latencyMs: Int = 0,
        succeeded: Bool = true,
        at date: Date = Date(),
        fallback: APIFallback? = nil
    ) -> UsageEvent {
        UsageEvent(
            createdAt: date,
            api: .transcription(provider, streaming: streaming),
            model: billedModel ?? model,
            audioSeconds: audioSeconds,
            costUSD: succeeded ? Pricing.audioCost(provider: provider, model: model, streaming: streaming, seconds: audioSeconds) : nil,
            latencyMs: latencyMs,
            succeeded: succeeded,
            fallback: fallback
        )
    }
}

/// Tarifs publiés dans les documentations xAI, DeepSeek et OpenAI.
/// Ce sont des estimations : la facture du fournisseur fait foi.
public enum Pricing {
    public struct TokenRate: Equatable, Sendable {
        public var input: Double
        public var cachedInput: Double
        public var output: Double
    }

    public static func audioCost(provider: ProviderID, model: String, streaming: Bool, seconds: Double) -> Double? {
        guard seconds.isFinite, seconds >= 0,
              let speech = ProviderCatalog.model(id: model, provider: provider) else { return nil }
        let perHour = streaming ? speech.streamingUSDPerHour : speech.batchUSDPerHour
        return perHour * seconds / 3_600
    }

    /// Prix en dollars par million de jetons.
    public static func tokenRate(model: String, at date: Date) -> TokenRate? {
        switch model {
        case CleanupModel.deepSeek:
            guard let peak = deepSeekPeakStatus(date) else { return nil }
            let factor = peak ? 1.0 : 0.5
            return TokenRate(input: 0.30 * factor, cachedInput: 0.006 * factor, output: 1.20 * factor)
        case "grok-4.7", "grok-4.6":
            return TokenRate(input: 2.00, cachedInput: 0.50, output: 6.00)
        case CleanupModel.openAIFallback, "gpt-5.4-mini-2026-03-17":
            // https://developers.openai.com/api/docs/models/gpt-5.4-mini
            return TokenRate(input: 0.75, cachedInput: 0.075, output: 4.50)
        case "gpt-5.6-luna":
            // https://developers.openai.com/api/docs/models/gpt-5.6-luna
            return TokenRate(input: 0.20, cachedInput: 0.02, output: 1.20)
        case "jev-latest", "jev-1.13.0":
            // Jev (TypeSafe) : seule l'entrée est facturée.
            return TokenRate(input: 0.042, cachedInput: 0.042, output: 0)
        default:
            return nil
        }
    }

    /// Tarif d'un modèle, en clair, pour l'aide au survol de l'écran Consommation.
    public static func rateDescription(model: String, at date: Date = Date()) -> String? {
        if model == CleanupModel.deepSeek {
            return "\(model) : \(MoneyFormat.price(0.30, locale: MoneyFormat.french)) / \(MoneyFormat.price(1.20, locale: MoneyFormat.french)) par million de jetons, moitié prix hors heures pleines"
        }
        if let rate = tokenRate(model: model, at: date) {
            let output = rate.output > 0 ? " / \(MoneyFormat.price(rate.output, locale: MoneyFormat.french))" : " (sortie gratuite)"
            return "\(model) : \(MoneyFormat.price(rate.input, locale: MoneyFormat.french))\(output) par million de jetons"
        }
        for provider in ProviderID.allCases {
            if let speech = ProviderCatalog.model(id: model, provider: provider) {
                return "\(speech.displayName) : \(speech.costSummary.prefix(1).lowercased() + speech.costSummary.dropFirst())"
            }
        }
        // Transcription de fichier enregistrée sous son propre nom (gpt-transcribe).
        if let speech = ProviderCatalog.models.first(where: { $0.fileModel == model && $0.fileModel != $0.id }) {
            return "\(model) : fichier \(MoneyFormat.price(speech.batchUSDPerHour, locale: MoneyFormat.french))/h"
        }
        return nil
    }

    public static func tokenCost(model: String, tokens: TokenUsage, at date: Date) -> Double? {
        guard tokens.input >= 0, tokens.cachedInput >= 0, tokens.output >= 0,
              let rate = tokenRate(model: model, at: date) else { return nil }
        // La somme en Double évite de déborder lorsque les compteurs sont de grands Int.
        let totalInput = Double(tokens.input) + Double(tokens.cachedInput)
        let inputFactor: Double
        let outputFactor: Double
        switch model {
        case "grok-4.7", "grok-4.6":
            inputFactor = totalInput >= 200_000 ? 2 : 1
            outputFactor = inputFactor
        case "gpt-5.6-luna" where totalInput > 272_000:
            inputFactor = 2
            outputFactor = 1.5
        default:
            inputFactor = 1
            outputFactor = 1
        }
        return ((Double(tokens.input) * rate.input + Double(tokens.cachedInput) * rate.cachedInput) * inputFactor
            + Double(tokens.output) * rate.output * outputFactor) / 1_000_000
    }

    /// Vrai uniquement pour une plage pleine confirmée. Pour distinguer l'inconnu, utiliser deepSeekPeakStatus.
    public static func isDeepSeekPeak(_ date: Date) -> Bool {
        deepSeekPeakStatus(date) == true
    }

    /// 9 h–12 h et 14 h–18 h en Chine, hors week-ends et congés nationaux.
    /// Dans une plage potentiellement pleine, une année sans calendrier renvoie nil.
    /// https://api-docs.deepseek.com/zh-cn/quick_start/pricing/
    public static func deepSeekPeakStatus(_ date: Date) -> Bool? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        let hour = calendar.component(.hour, from: date)
        guard (9..<12).contains(hour) || (14..<18).contains(hour) else { return false }
        guard let holiday = ChinesePublicHolidays.isHoliday(date) else { return nil }
        return !holiday
    }
}

public struct UsageRow: Equatable, Sendable, Identifiable {
    public var api: UsageAPI
    public var models: [String]
    public var requests: Int
    public var failures: Int
    public var audioSeconds: Double
    public var tokens: TokenUsage
    public var costUSD: Double
    /// Au moins un appel sans tarif connu : le coût affiché est un minimum.
    public var hasUnpricedCalls: Bool
    public var lastCall: Date?

    public var id: String { api.rawValue }
}

public struct UsageSummary: Equatable, Sendable {
    public var rows: [UsageRow]
    public var totalUSD: Double
    public var hasUnpricedCalls: Bool

    public func cost(provider: String) -> Double {
        rows.filter { $0.api.provider == provider }.reduce(0) { $0 + $1.costUSD }
    }

    public static func make(events: [UsageEvent], period: StatsPeriod, now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let start = period.startDate(now: now, calendar: calendar)
        let kept = events.filter { start == nil || $0.createdAt >= start! }
        var rows: [UsageRow] = []
        for api in UsageAPI.allCases {
            let matching = kept.filter { $0.api == api }
            guard !matching.isEmpty else { continue }
            var models: [String] = []
            for event in matching where !models.contains(event.model) {
                models.append(event.model)
            }
            rows.append(UsageRow(
                api: api,
                models: models,
                requests: matching.count,
                failures: matching.filter { !$0.succeeded }.count,
                audioSeconds: matching.reduce(0) { $0 + $1.audioSeconds },
                tokens: matching.reduce(TokenUsage()) {
                    TokenUsage(input: $0.input + $1.tokens.input, cachedInput: $0.cachedInput + $1.tokens.cachedInput, output: $0.output + $1.tokens.output)
                },
                costUSD: matching.reduce(0) { $0 + ($1.costUSD ?? 0) },
                hasUnpricedCalls: matching.contains { $0.costUSD == nil },
                lastCall: matching.map(\.createdAt).max()
            ))
        }
        rows.sort { $0.costUSD > $1.costUSD }
        return UsageSummary(
            rows: rows,
            totalUSD: rows.reduce(0) { $0 + $1.costUSD },
            hasUnpricedCalls: rows.contains { $0.hasUnpricedCalls }
        )
    }
}

public extension StatsPeriod {
    func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .days7: return calendar.date(byAdding: .day, value: -7, to: now)
        case .days30: return calendar.date(byAdding: .day, value: -30, to: now)
        case .all: return nil
        }
    }
}

public enum MoneyFormat {
    /// Les petits montants gardent leurs décimales : une dictée coûte souvent moins d'un centime.
    public static func usd(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let digits: Int
        switch value {
        case 0: digits = 2
        case ..<0.01: digits = 5
        case ..<1: digits = 4
        default: digits = 2
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = digits == 2 ? 2 : 0
        formatter.maximumFractionDigits = digits
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
        return dollars(number, locale: locale)
    }

    /// Prix unitaire, toujours à deux décimales au moins : « 0,20 $ », « 0,075 $ ».
    public static func price(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 3
        return dollars(formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value), locale: locale)
    }

    /// « 0,20 $ » en français, « $0.20 » ailleurs.
    static func dollars(_ number: String, locale: Locale) -> String {
        locale.language.languageCode == .french ? "\(number) $" : "$\(number)"
    }

    /// Textes internes du cœur (journaux, tests) : toujours en français.
    static let french = Locale(identifier: "fr_FR")
}
