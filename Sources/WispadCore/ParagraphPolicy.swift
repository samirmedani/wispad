import Foundation

/// Paragraphes automatiques : seule une dictée assez longue reçoit la consigne de découpage. En dessous, un message
/// court reste d'un bloc, sauf retour à la ligne déjà présent ou commande « nouveau paragraphe » prononcée.
public enum ParagraphPolicy {
    /// Environ quatre phrases : en dessous, un lecteur n'attend pas de paragraphe.
    public static let minimumWords = 40

    public static func applies(to request: CorrectionRequest) -> Bool {
        request.autoParagraphs && request.commandSelection == nil && wordCount(request.transcript) >= minimumWords
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
