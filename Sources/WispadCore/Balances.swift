import Foundation

public struct XAIAccountStatus: Equatable, Sendable {
    public var teamID: String
    public var keyName: String?
    /// Crédit épuisé ou plafond mensuel atteint : xAI refuse alors toutes les requêtes.
    public var blocked: Bool

    public init(teamID: String, keyName: String?, blocked: Bool) {
        self.teamID = teamID
        self.keyName = keyName
        self.blocked = blocked
    }

    /// Page de facturation de l'équipe ; la console si l'identifiant reçu de xAI ne forme pas une adresse.
    public var billingURL: URL {
        URL(string: "https://console.x.ai/team/\(teamID)/billing") ?? Self.consoleURL
    }

    public static let consoleURL = URL(string: "https://console.x.ai")!
}

/// Compte xAI vu par la clé de gestion : crédit réel, consommation récente et dernière recharge.
public struct XAIBilling: Equatable, Sendable {
    public struct Share: Equatable, Sendable, Identifiable {
        public var name: String
        public var usd: Double
        public var id: String { name }

        public init(name: String, usd: Double) {
            self.name = name
            self.usd = usd
        }
    }

    public struct TopUp: Equatable, Sendable {
        public var date: Date
        public var usd: Double
        public var automatic: Bool

        public init(date: Date, usd: Double, automatic: Bool) {
            self.date = date
            self.usd = usd
            self.automatic = automatic
        }
    }

    /// Crédit prépayé encore disponible, consommation du mois en cours déduite.
    public var remainingUSD: Double
    /// Consommation du mois en cours : xAI ne la retire du crédit qu'à la facture mensuelle, vers le 10 du mois suivant.
    public var cycleSpentUSD: Double
    /// Consommation des 30 derniers jours par clé API et par service, de la plus chère à la moins chère.
    public var recentByKey: [Share]
    public var recentByService: [Share]
    public var lastTopUp: TopUp?

    public init(remainingUSD: Double, cycleSpentUSD: Double, recentByKey: [Share] = [], recentByService: [Share] = [],
                lastTopUp: TopUp? = nil) {
        self.remainingUSD = remainingUSD
        self.cycleSpentUSD = cycleSpentUSD
        self.recentByKey = recentByKey
        self.recentByService = recentByService
        self.lastTopUp = lastTopUp
    }

    public static let recentDays = 30

    public var recentUSD: Double { recentByKey.reduce(0) { $0 + $1.usd } }

    /// Jours de crédit au rythme des 30 derniers jours ; nil sans consommation récente.
    public var daysLeft: Int? {
        guard recentUSD > 0 else { return nil }
        return max(0, Int((remainingUSD / (recentUSD / Double(Self.recentDays))).rounded(.down)))
    }

    /// Crédit et consommation du mois en cours, d'après l'aperçu de la facture mensuelle.
    /// `prepaidCredits.val` : crédit restant au début du mois, en centimes, négatif. Chaque ligne coûte
    /// `unitPrice` × `numUnits` en dix-milliardièmes de dollar ; son `amount` est arrondi au centime, donc à 0 pour
    /// quelques minutes de voix.
    /// Le solde de `prepaid/balance` ne suffit pas : il ne retire la consommation qu'une fois la facture du mois émise,
    /// et annonçait ainsi 14,97 $ le 1er novembre 2026 pour 8,43 $ réellement disponibles.
    static func cycle(preview: [String: Any]) -> (remainingUSD: Double, spentUSD: Double)? {
        guard let invoice = preview["coreInvoice"] as? [String: Any],
              let credits = number((invoice["prepaidCredits"] as? [String: Any])?["val"]) else { return nil }
        let lines = invoice["lines"] as? [[String: Any]] ?? []
        let spent = lines.reduce(0.0) { total, line in
            total + (number(line["unitPrice"]) ?? 0) * (number(line["numUnits"]) ?? 0) / 10_000_000_000
        }
        return (max(0, -credits / 100 - spent), spent)
    }

    /// Somme d'une réponse `usage` regroupée par clé API puis par service, selon le niveau de regroupement demandé.
    static func shares(usage: [String: Any], level: Int) -> [Share] {
        var totals: [String: Double] = [:]
        for series in usage["timeSeries"] as? [[String: Any]] ?? [] {
            let labels = series["groupLabels"] as? [String] ?? series["group"] as? [String] ?? []
            guard labels.indices.contains(level) else { continue }
            let usd = (series["dataPoints"] as? [[String: Any]] ?? []).reduce(0.0) { total, point in
                total + ((point["values"] as? [Any])?.first.flatMap(number) ?? 0)
            }
            totals[label(labels[level]), default: 0] += usd
        }
        return totals.filter { $0.value >= 0.005 }
            .map { Share(name: $0.key, usd: $0.value) }
            .sorted { $0.usd != $1.usd ? $0.usd > $1.usd : $0.name < $1.name }
    }

    /// « wispad (xai-...vRwk) » → « wispad » ; « API Speech-to-Text » → « Speech-to-Text ».
    static func label(_ raw: String) -> String {
        var name = raw
        if let range = name.range(of: " (xai-", options: .backwards) { name = String(name[..<range.lowerBound]) }
        if name.hasPrefix("API ") { name.removeFirst(4) }
        return name.isEmpty ? raw : name
    }

    /// Dernière recharge payée, manuelle ou automatique, dans l'historique du crédit prépayé.
    static func lastTopUp(balance: [String: Any]) -> TopUp? {
        let changes = balance["changes"] as? [[String: Any]] ?? []
        return changes.compactMap { change -> TopUp? in
            let origin = change["changeOrigin"] as? String
            guard origin == "PURCHASE" || origin == "AUTO_PURCHASE",
                  change["topupStatus"] as? String == "SUCCEEDED",
                  let cents = number((change["amount"] as? [String: Any])?["val"]),
                  let date = (change["createTs"] as? String ?? change["createTime"] as? String).flatMap(timestamp) else { return nil }
            return TopUp(date: date, usd: abs(cents) / 100, automatic: origin == "AUTO_PURCHASE")
        }
        .max { $0.date < $1.date }
    }

    /// Horodatage xAI, avec ou sans fraction de seconde (« 2026-10-26T14:09:29.329752Z »).
    static func timestamp(_ raw: String) -> Date? {
        let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// xAI écrit ses montants tantôt en texte, tantôt en nombre.
    static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        return nil
    }
}

/// Soldes réels chez les fournisseurs. Ces appels sont gratuits.
public enum BalanceProbe {
    public static func deepSeek(key: String) async -> String? {
        guard let object = await json(URL(string: "https://api.deepseek.com/user/balance")!, key: key),
              let infos = object["balance_infos"] as? [[String: Any]],
              let first = infos.first,
              let total = first["total_balance"] as? String,
              let value = Double(total) else { return nil }
        let currency = first["currency"] as? String ?? "USD"
        return currency == "USD" ? MoneyFormat.usd(value) : String(format: "%.2f %@", value, currency)
    }

    public static func xai(key: String) async -> XAIAccountStatus? {
        guard let object = await json(URL(string: "https://api.x.ai/v1/api-key")!, key: key),
              let team = object["team_id"] as? String else { return nil }
        return XAIAccountStatus(
            teamID: team,
            keyName: object["name"] as? String,
            blocked: (object["team_blocked"] as? Bool ?? false)
                || (object["api_key_blocked"] as? Bool ?? false)
                || (object["api_key_disabled"] as? Bool ?? false)
        )
    }

    /// Crédit réel, consommation des 30 derniers jours et dernière recharge, via la clé de gestion xAI
    /// (console → Settings → Management Keys). nil si l'aperçu de facture, qui porte le crédit, est illisible.
    public static func xaiBilling(managementKey: String, teamID: String, now: Date = Date()) async -> XAIBilling? {
        let base = "https://management-api.x.ai/v1/billing/teams/\(teamID)"
        guard let previewURL = URL(string: base + "/postpaid/invoice/preview"),
              let balanceURL = URL(string: base + "/prepaid/balance"),
              let usageURL = URL(string: base + "/usage") else { return nil }
        async let preview = json(previewURL, key: managementKey)
        async let balance = json(balanceURL, key: managementKey)
        async let usage = json(usageURL, key: managementKey, body: usageQuery(now: now))
        guard let previewObject = await preview, let cycle = XAIBilling.cycle(preview: previewObject) else { return nil }
        let usageObject = await usage ?? [:]
        return XAIBilling(
            remainingUSD: cycle.remainingUSD,
            cycleSpentUSD: cycle.spentUSD,
            recentByKey: XAIBilling.shares(usage: usageObject, level: 0),
            recentByService: XAIBilling.shares(usage: usageObject, level: 1),
            lastTopUp: (await balance).flatMap(XAIBilling.lastTopUp)
        )
    }

    /// Dépense en dollars des 30 derniers jours, regroupée par clé API puis par service.
    static func usageQuery(now: Date) -> Data? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let start = now.addingTimeInterval(-Double(XAIBilling.recentDays) * 86_400)
        let query: [String: Any] = ["analyticsRequest": [
            "timeRange": ["startTime": formatter.string(from: start), "endTime": formatter.string(from: now), "timezone": "Etc/GMT"],
            "timeUnit": "TIME_UNIT_NONE",
            "values": [["name": "usd", "aggregation": "AGGREGATION_SUM"]],
            "groupBy": ["api_key_id", "description"],
        ]]
        return try? JSONSerialization.data(withJSONObject: query)
    }

    private static func json(_ url: URL, key: String, body: Data? = nil) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
