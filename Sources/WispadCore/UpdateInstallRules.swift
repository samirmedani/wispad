import Foundation

/// Pourquoi une release ne s'installe pas en un clic : la page de la release s'ouvre à la place.
public enum UpdateInstallObstacle: Equatable, Sendable {
    /// Build compilé depuis les sources : il se met à jour depuis le dépôt.
    case developmentBuild
    /// Release publiée sans `Wispad.dmg`.
    case noDiskImage
    /// App sans signature Developer ID (Team ID inconnu) : aucune signature à laquelle comparer la nouvelle version.
    case unsigned
    /// Dossier de l'app non modifiable, app lancée depuis le disque d'installation ou déplacée par macOS (translocation).
    case readOnlyLocation
}

/// Règles de l'installation en un clic, sans système de fichiers ni réseau : qui peut s'installer, quelle signature
/// est exigée, où la nouvelle version attend avant de remplacer l'app.
public enum UpdateInstallRules {
    /// Obstacle à l'installation en place, ou nil : téléchargement, vérification, remplacement et relance.
    public static func obstacle(kind: BuildKind, release: ReleaseInfo, appPath: String, teamID: String?,
                                folderWritable: Bool, appWritable: Bool) -> UpdateInstallObstacle? {
        guard kind == .release else { return .developmentBuild }
        guard release.diskImage != nil else { return .noDiskImage }
        guard let teamID, isTeamID(teamID) else { return .unsigned }
        guard appPath.hasSuffix(".app"), !appPath.contains("/AppTranslocation/"), folderWritable, appWritable else {
            return .readOnlyLocation
        }
        return nil
    }

    /// Identifiant d'équipe Apple : dix lettres majuscules ou chiffres.
    public static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// Exigence de signature (langage des exigences de code d'Apple) de la nouvelle version : même identifiant,
    /// signée Developer ID (racine Apple, certificat intermédiaire et certificat d'application Developer ID) par la
    /// même équipe que l'app qui tourne. Nil si l'équipe ou l'identifiant ne sont pas sûrs à insérer.
    public static func requirement(bundleID: String, teamID: String) -> String? {
        guard isTeamID(teamID), !bundleID.isEmpty,
              bundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        return "identifier \"\(bundleID)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Copie de la nouvelle version, cachée, à côté de l'app : même volume, donc un simple échange de noms.
    public static func stagingURL(for app: URL) -> URL {
        sibling(of: app, suffix: "nouveau")
    }

    /// Ancienne version mise de côté le temps du remplacement, quand l'échange atomique n'est pas possible.
    public static func backupURL(for app: URL) -> URL {
        sibling(of: app, suffix: "ancien")
    }

    /// Seule la nouvelle version remplace l'app : jamais un retour en arrière non demandé, ni une version illisible.
    public static func isNewer(_ downloaded: String?, than installed: String) -> Bool {
        guard let downloaded = downloaded.flatMap({ SemanticVersion($0) }),
              let current = SemanticVersion(installed) else { return false }
        return downloaded > current
    }

    /// Retour à une version précédente, choisi dans Réglages : le disque contient exactement la version demandée,
    /// et elle est plus ancienne que celle qui tourne. Toute autre version, ou une version illisible, est refusée.
    public static func isRequestedPrevious(_ downloaded: String?, target: SemanticVersion, installed: String) -> Bool {
        guard let downloaded = downloaded.flatMap({ SemanticVersion($0) }),
              let current = SemanticVersion(installed) else { return false }
        return downloaded == target && target < current
    }

    /// Points de montage lus dans la sortie de `hdiutil attach -plist` (texte éventuel avant le plist ignoré).
    public static func mountPoints(fromPlist output: Data) -> [String] {
        let start = output.range(of: Data("<?xml".utf8))?.lowerBound ?? output.startIndex
        guard let root = try? PropertyListSerialization.propertyList(from: output[start...], options: [], format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { $0["mount-point"] as? String }.filter { !$0.isEmpty }
    }

    private static func sibling(of app: URL, suffix: String) -> URL {
        let name = app.deletingPathExtension().lastPathComponent
        return app.deletingLastPathComponent().appendingPathComponent(".\(name).\(suffix).app", isDirectory: true)
    }
}
