import Foundation

/// Pages de retour du dépôt public : ticket de bug prérempli (formulaire `bug.yml`), idées et questions dans les
/// Discussions. Décision pure, sans réseau. L'adresse du ticket ne porte que la version de Wispad et celle de
/// macOS : jamais de dictée, de réglage ni de donnée personnelle.
public enum FeedbackLinks {
    /// Formulaire de bug du dépôt (`.github/ISSUE_TEMPLATE/bug.yml`), dont les champs `version` et `macos` se
    /// préremplissent par l'adresse.
    public static let bugTemplate = "bug.yml"

    /// Discussions, catégorie Ideas : idées à discuter et à voter.
    public static let ideasURL = URL(string: "https://github.com/\(BuildFreshnessCheck.repository)/discussions/categories/ideas")!
    /// Discussions, catégorie Q&A.
    public static let questionsURL = URL(string: "https://github.com/\(BuildFreshnessCheck.repository)/discussions/categories/q-a")!

    static let newIssueURL = URL(string: "https://github.com/\(BuildFreshnessCheck.repository)/issues/new")!

    /// Nouveau ticket sur le formulaire de bug : version de Wispad (champ omis si ni la version ni le commit ne
    /// sont connus) et version de macOS, encodées pour l'adresse.
    public static func bugReportURL(version: String?, commit: String?, system: OperatingSystemVersion) -> URL {
        var fields: [(name: String, value: String)] = [("template", bugTemplate)]
        if let value = versionValue(version: version, commit: commit) {
            fields.append(("version", value))
        }
        fields.append(("macos", systemValue(system)))
        let query = fields.map { "\($0.name)=\(percentEncoded($0.value))" }.joined(separator: "&")
        // Valeurs encodées : seuls des caractères permis restent, l'adresse se lit toujours.
        return URL(string: newIssueURL.absoluteString + "?" + query) ?? newIssueURL
    }

    /// « 0.1.0 · abc1234 », comme la barre latérale sans le nom de l'app. Le commit n'y entre que court et s'il est
    /// un hash git. Version ou commit absents : la partie connue ; aucun des deux : nil.
    static func versionValue(version: String?, commit: String?) -> String? {
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [version, BuildFreshnessCheck.shortCommit(commit)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// « macOS 15.3.1 » : toujours majeure, mineure et correctif.
    static func systemValue(_ version: OperatingSystemVersion) -> String {
        "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Encodage strict d'une valeur : seuls lettres et chiffres ASCII et « - . _ ~ » restent tels quels. Espaces,
    /// accents, « + », « & », « = » et « # » sont encodés : une valeur ne devient pas une espace (GitHub lit « + »
    /// ainsi), n'ajoute aucun champ et ne coupe pas l'adresse.
    static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
