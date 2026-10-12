import Foundation

/// Juge qui a fait entrer un mot appris au dictionnaire : Jev (TypeSafe) ou le modèle de correction.
/// Fournisseur et modèle sont ceux de l'appel qui a tranché, jamais une valeur fixe : un mot appris après un
/// changement de clé ou de fournisseur porte le modèle qui a répondu pour lui.
public struct DictionaryJudge: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// Note nette de Jev, ou note de Jev seule quand le modèle de correction n'a pas répondu.
        case jev
        /// Avis du modèle de correction : sans Jev, ou sur un mot que la note de Jev laissait douteux.
        case correctionModel = "model"
    }

    public var kind: Kind
    /// Fournisseur appelé : « TypeSafe », « DeepSeek », « OpenAI », « xAI »…
    public var provider: String
    /// Modèle qui a répondu : « jev-latest », « deepseek-flash », « gpt-5.4-mini »…
    public var model: String

    public init(kind: Kind, provider: String, model: String) {
        self.kind = kind
        self.provider = provider
        self.model = model
    }
}

/// Qui a ajouté un mot au dictionnaire.
public enum DictionaryOrigin: Equatable, Sendable {
    /// Mot ajouté avant le suivi de l'origine : l'historique ne dit pas de façon sûre qui l'a ajouté.
    case unknown
    /// Mot ajouté à la main dans l'écran Dictionnaire.
    case user
    /// Mot appris d'une correction faite juste après une dictée, retenu par ce juge.
    case learned(DictionaryJudge)

    /// Juge d'un mot appris ; nil pour un mot ajouté à la main ou d'origine inconnue.
    public var judge: DictionaryJudge? {
        if case .learned(let judge) = self { return judge }
        return nil
    }
}

extension DictionaryOrigin {
    static let userValue = "user"

    /// Colonne `origin` de la table `dictionary` : `user`, `jev` ou `model` ; NULL pour une origine inconnue.
    var storedValue: String? {
        switch self {
        case .unknown: return nil
        case .user: return Self.userValue
        case .learned(let judge): return judge.kind.rawValue
        }
    }

    /// Lecture tolérante : une valeur inconnue (écrite par une version plus récente) ou un juge incomplet
    /// donnent une origine inconnue, jamais une erreur.
    init(stored: String?, provider: String?, model: String?) {
        if stored == Self.userValue {
            self = .user
            return
        }
        guard let stored, let kind = DictionaryJudge.Kind(rawValue: stored),
              let provider, !provider.isEmpty, let model, !model.isEmpty else {
            self = .unknown
            return
        }
        self = .learned(DictionaryJudge(kind: kind, provider: provider, model: model))
    }
}

/// Filtre de l'écran Dictionnaire selon l'origine des mots. Un mot d'avant le suivi ne paraît que dans « Tous ».
public enum DictionaryFilter: String, CaseIterable, Sendable {
    case all
    /// Mots ajoutés à la main dans l'écran Dictionnaire.
    case addedByUser
    /// Mots appris d'une correction, gardés par « Oui » ou non.
    case learned

    public func includes(_ entry: DictionaryEntry) -> Bool {
        switch self {
        case .all: return true
        case .addedByUser: return entry.origin == .user
        case .learned: return entry.origin.judge != nil
        }
    }
}
