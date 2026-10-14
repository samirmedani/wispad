import Foundation

/// Autorisations de macOS dont dépend l'écoute du clavier, lues sans rien demander.
public struct KeyboardPermissions: Equatable, Sendable {
    /// Surveillance des entrées : recevoir les frappes de toutes les apps.
    public var listen: Bool
    /// Accessibilité : une écoute qui avale des frappes (le raccourci, Échap) en dépend aussi.
    public var accessibility: Bool

    public init(listen: Bool, accessibility: Bool) {
        self.listen = listen
        self.accessibility = accessibility
    }
}

/// Garde de l'écoute du clavier (KeyboardTap), vérifiée toutes les 3 s et à chaque coupure signalée par macOS.
/// Placée en tête de la session, l'écoute voit passer et peut avaler chaque frappe de toutes les apps : réarmée
/// après le retrait d'une autorisation dont elle dépendait, elle peut retenir le clavier de tout le Mac. Elle n'est
/// donc réarmée qu'avec les autorisations de son installation ; sinon elle est retirée, puis réinstallée quand
/// elles reviennent. Rien n'est jamais demandé à macOS ici : seules des lectures, au rythme de la surveillance.
public struct KeyboardTapWatch: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Rien à faire.
        case keep
        /// Écoute coupée par macOS (lenteur, saisie sécurisée, veille) : la réarmer, ses autorisations sont là.
        case reenable
        /// Une autorisation de l'installation a été retirée : retirer l'écoute, sans jamais la réarmer.
        case remove
        /// Pas d'écoute : essayer de l'installer.
        case install
    }

    /// Autorisations présentes à la dernière installation réussie ; nil tant qu'aucune n'a réussi.
    public private(set) var installedWith: KeyboardPermissions?

    public init() {}

    /// Une écoute vient d'être installée avec ces autorisations.
    public mutating func installed(with permissions: KeyboardPermissions) {
        installedWith = permissions
    }

    /// Une autorisation présente à l'installation manque maintenant. Une autorisation donnée depuis ne compte pas :
    /// l'écoute ne s'en servait pas.
    public func withdrawn(_ now: KeyboardPermissions) -> Bool {
        guard let installedWith else { return false }
        return (installedWith.listen && !now.listen) || (installedWith.accessibility && !now.accessibility)
    }

    /// Écoute installée, active ou coupée par macOS.
    public func installedTap(enabled: Bool, permissions now: KeyboardPermissions) -> Decision {
        if withdrawn(now) { return .remove }
        return enabled ? .keep : .reenable
    }

    /// Pas d'écoute (jamais installée, invalidée par macOS ou retirée) : installée dès que la surveillance des
    /// entrées est accordée, comme au lancement, ou dès que toutes les autorisations de sa dernière installation
    /// sont revenues. Sinon on attend, sans rien tenter.
    public func missingTap(_ now: KeyboardPermissions) -> Decision {
        if now.listen { return .install }
        guard let installedWith, installedWith.listen || installedWith.accessibility, !withdrawn(now) else { return .keep }
        return .install
    }
}
