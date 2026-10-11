import Foundation

/// Écart entre le commit de cette version et la branche principale du dépôt public.
public enum BuildFreshness: Equatable, Sendable {
    case upToDate
    /// Commits de la branche principale absents de cette version.
    case behind(Int)
    /// GitHub injoignable, dépôt privé, commit inconnu ou réponse illisible : seule la version s'affiche.
    case unknown
}

/// Décision pure, sans réseau : le commit gravé à la compilation, l'adresse à interroger, la réponse lue.
public enum BuildFreshnessCheck {
    public static let repository = "samirmedani/wispad"
    public static let branch = "main"
    /// Une requête au lancement, puis toutes les 6 heures.
    public static let interval: TimeInterval = 6 * 3600
    public static let timeout: TimeInterval = 8

    public static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    public static let commitsURL = URL(string: "https://github.com/\(repository)/commits/\(branch)")!

    /// Commit court (7 caractères) d'une valeur gravée à la compilation, ou nil si elle n'est pas un hash git.
    public static func shortCommit(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              (7...40).contains(value.count),
              value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return String(value.prefix(7))
    }

    /// `compare/<commit>...main` : `ahead_by` y compte les commits de main absents du commit de la version.
    public static func compareURL(commit: String) -> URL? {
        guard let commit = shortCommit(commit) else { return nil }
        return URL(string: "https://api.github.com/repos/\(repository)/compare/\(commit)...\(branch)")
    }

    private struct Comparison: Decodable {
        var aheadBy: Int

        enum CodingKeys: String, CodingKey {
            case aheadBy = "ahead_by"
        }
    }

    /// Réponse de l'API publique → état affiché. Tout ce qui n'est pas une comparaison lisible reste inconnu.
    public static func freshness(statusCode: Int, data: Data) -> BuildFreshness {
        guard statusCode == 200,
              let comparison = try? JSONDecoder().decode(Comparison.self, from: data),
              comparison.aheadBy >= 0 else { return .unknown }
        return comparison.aheadBy == 0 ? .upToDate : .behind(comparison.aheadBy)
    }
}
