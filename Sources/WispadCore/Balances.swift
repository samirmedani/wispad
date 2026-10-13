import Foundation

public struct XAIAccountStatus: Equatable, Sendable {
    public var teamID: String
    public var keyName: String?
    /// Crédit épuisé ou plafond mensuel atteint : xAI refuse alors toutes les requêtes.
    public var blocked: Bool

    /// Page de facturation de l'équipe ; la console si l'identifiant reçu de xAI ne forme pas une adresse.
    public var billingURL: URL {
        URL(string: "https://console.x.ai/team/\(teamID)/billing") ?? Self.consoleURL
    }

    public static let consoleURL = URL(string: "https://console.x.ai")!
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

    /// Crédit prépayé restant, via la clé de gestion xAI (console → Settings → Management Keys).
    /// `total.val` est en centimes de dollar, négatif quand il reste du crédit.
    public static func xaiPrepaid(managementKey: String, teamID: String) async -> String? {
        guard let url = URL(string: "https://management-api.x.ai/v1/billing/teams/\(teamID)/prepaid/balance"),
              let object = await json(url, key: managementKey),
              let total = object["total"] as? [String: Any] else { return nil }
        let raw = total["val"] as? String ?? (total["val"] as? NSNumber)?.stringValue ?? ""
        guard let cents = Double(raw) else { return nil }
        return MoneyFormat.usd(-cents / 100)
    }

    private static func json(_ url: URL, key: String) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
