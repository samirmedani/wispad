import Foundation
import WispadCore

/// Installation en un clic qui vient de finir. L'ancienne version la note juste avant sa relance ; la nouvelle la lit
/// une seule fois au lancement et, si la fenêtre était ouverte, rouvre la fenêtre de mise à jour sur ses quatre
/// étapes : « Redémarrage » se coche, puis « Wispad X est installé » et les notes de version, même hors ligne.
/// Rien de personnel : la version, ses notes publiques et la version d'avant.
struct UpdateCompletion: Equatable {
    var release: ReleaseInfo
    /// Version qui tournait avant l'installation (plus récente après un retour en arrière).
    var previous: String

    static let defaultsKey = "wispad.update.completion"
    /// Au-delà, la note est trop vieille pour décrire ce lancement (relance ratée, ouverture des jours plus tard).
    static let lifetime: TimeInterval = 10 * 60

    static func save(_ release: ReleaseInfo, from previous: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        var record: [String: Any] = [
            "version": release.version.description, "tag": release.tag, "notes": release.notes,
            "page": release.pageURL.absoluteString, "previous": previous, "saved": now.timeIntervalSince1970,
        ]
        if let published = release.publishedAt { record["published"] = published.timeIntervalSince1970 }
        defaults.set(record, forKey: defaultsKey)
    }

    /// La note de cette version, effacée dès la lecture ; nil si elle manque, vient d'une autre version ou est trop
    /// vieille.
    static func take(version: String?, defaults: UserDefaults = .standard, now: Date = Date()) -> UpdateCompletion? {
        guard let record = defaults.dictionary(forKey: defaultsKey) else { return nil }
        defaults.removeObject(forKey: defaultsKey)
        guard let installed = version.flatMap(SemanticVersion.init),
              let text = record["version"] as? String, SemanticVersion(text) == installed,
              let saved = record["saved"] as? Double, (0...lifetime).contains(now.timeIntervalSince1970 - saved),
              let tag = record["tag"] as? String, let previous = record["previous"] as? String,
              let page = (record["page"] as? String).flatMap(URL.init(string:)) else { return nil }
        let release = ReleaseInfo(
            version: installed, tag: tag, notes: record["notes"] as? String ?? "", pageURL: page, diskImage: nil,
            publishedAt: (record["published"] as? Double).map(Date.init(timeIntervalSince1970:))
        )
        return UpdateCompletion(release: release, previous: previous)
    }
}
