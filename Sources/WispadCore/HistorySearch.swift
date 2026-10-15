import Foundation

extension DictationRecord {
    /// Recherche dans l'historique : le texte collé, et aussi ce qui a été entendu (transcription, autre écoute). Une
    /// dictée dont la correction est partie à côté se retrouve ainsi par les mots vraiment dits.
    public func matches(search needle: String) -> Bool {
        finalText.localizedCaseInsensitiveContains(needle)
            || rawText.localizedCaseInsensitiveContains(needle)
            || alternativeText?.localizedCaseInsensitiveContains(needle) == true
    }
}
