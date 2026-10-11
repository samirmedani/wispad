import Foundation

/// Raccord d'une dictée avec le texte déjà présent avant le curseur : deux dictées de suite ne doivent pas
/// se coller (« phrase.Deuxième »). Seul un espace est ajouté, jamais de mot ni de majuscule modifiée.
public enum SmartJoin {
    /// Caractères après lesquels on colle sans espace : ouverture, apostrophe, trait, barre, retour à la ligne.
    private static let attachAfter: Set<Character> = ["(", "[", "{", "«", "“", "\"", "'", "’", "‘", "/", "\\", "-", "–", "—", "@", "#", "_"]
    /// Caractères qui se collent au texte précédent quand la dictée commence par eux.
    private static let attachBefore: Set<Character> = [",", ".", "…", ")", "]", "}", "»", "”", "'", "’"]

    /// - Parameter before: texte juste avant le point d'insertion (quelques caractères suffisent),
    ///   nil s'il est inconnu (champ illisible) : dans le doute, on ne touche à rien.
    public static func adjust(_ text: String, before: String?) -> String {
        guard let first = text.first, let previous = before?.last else { return text }
        if previous.isWhitespace || previous.isNewline || first.isWhitespace { return text }
        if attachAfter.contains(previous) || attachBefore.contains(first) { return text }
        return " " + text
    }

    /// Texte juste avant le curseur.
    /// - Parameters:
    ///   - read: lu par l'accessibilité au moment du collage ; nil si l'app ne l'expose pas.
    ///   - previous: dernier collage de Wispad dans ce même champ, sans aucune frappe depuis.
    ///   - previousConfirmed: ce collage a été constaté dans le champ, l'accessibilité y est donc à jour.
    public static func textBefore(read: String?, previous: String?, previousConfirmed: Bool) -> String? {
        guard let previous, !previous.isEmpty else { return read }
        guard let read else { return previous }
        // Collage constaté : si la lecture ne le montre plus avant le curseur, c'est que le curseur a bougé.
        if previousConfirmed { return read }
        // Collage pas encore visible (apps Electron qui mettent leur valeur à jour en différé) : on sait
        // pourtant ce qui précède le curseur, puisque Wispad vient de l'y coller.
        let tail = String(previous.suffix(min(16, read.count)))
        return !tail.isEmpty && read.hasSuffix(tail) ? read : previous
    }
}
