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

/// Filtre de l’écran Dictionnaire selon l’origine des mots.
public enum DictionaryFilter: String, CaseIterable, Codable, Sendable {
    case all
    /// Mots ajoutés à la main dans l'écran Dictionnaire.
    case addedByUser
    /// Mots appris d'une correction, gardés par « Oui » ou non.
    case learned
    case unknown

    public func includes(_ entry: DictionaryEntry) -> Bool {
        switch self {
        case .all: return true
        case .addedByUser: return entry.origin == .user
        case .learned: return entry.origin.judge != nil
        case .unknown: return entry.origin == .unknown
        }
    }
}


/// Période d’ajout : jours calendaires, aujourd’hui compris.
public enum DictionaryPeriod: String, CaseIterable, Codable, Sendable {
    case all, days7, days30

    public func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .all: return nil
        case .days7: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .days30: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        }
    }
}

/// Présentation déduite du texte, sans limite de longueur ni modification des entrées conservées.
public enum DictionaryKind: String, CaseIterable, Codable, Sendable {
    case word, phrase

    public static func classify(_ term: String) -> Self {
        term.split(whereSeparator: \.isWhitespace).count > 1 ? .phrase : .word
    }

    public func includes(_ entry: DictionaryEntry) -> Bool { Self.classify(entry.term) == self }
}

extension DictionaryFilter {
    /// Les filtres se croisent ; les compteurs d’origine restent ceux du dictionnaire complet.
    public func matchingEntries(in entries: [DictionaryEntry], period: DictionaryPeriod, search: String,
                                sort: DictionarySort = .newest,
                                now: Date = Date(), calendar: Calendar = .current) -> [DictionaryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = period.startDate(now: now, calendar: calendar)
        return entries.filter { entry in
            includes(entry) && (start.map { entry.createdAt >= $0 } ?? true) &&
                (query.isEmpty || entry.term.localizedStandardContains(query))
        }.sorted(by: sort.precedes)
    }
}

/// Tri d'affichage seulement : ne change ni le stockage ni l'ordre des indices envoyés aux fournisseurs.
public enum DictionarySort: String, Codable, CaseIterable, Sendable {
    case newest, oldest, originAscending, originDescending, termAscending, termDescending

    public enum Column: Sendable { case date, origin, term }

    public var column: Column {
        switch self {
        case .newest, .oldest: return .date
        case .originAscending, .originDescending: return .origin
        case .termAscending, .termDescending: return .term
        }
    }

    public var ascending: Bool { self == .oldest || self == .originAscending || self == .termAscending }

    public func selecting(_ column: Column) -> Self {
        switch column {
        case .date: return self == .newest ? .oldest : .newest
        case .origin: return self == .originAscending ? .originDescending : .originAscending
        case .term: return self == .termAscending ? .termDescending : .termAscending
        }
    }

    public func precedes(_ lhs: DictionaryEntry, _ rhs: DictionaryEntry) -> Bool {
        switch column {
        case .date:
            if lhs.createdAt != rhs.createdAt {
                return ascending ? lhs.createdAt < rhs.createdAt : lhs.createdAt > rhs.createdAt
            }
        case .origin:
            let left = Self.originRank(lhs.origin), right = Self.originRank(rhs.origin)
            if left != right { return ascending ? left < right : left > right }
        case .term:
            let order = lhs.term.localizedStandardCompare(rhs.term)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
        }
        // Dans chaque origine et en cas d'égalité, les ajouts récents restent en tête.
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        let order = lhs.term.localizedStandardCompare(rhs.term)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    private static func originRank(_ origin: DictionaryOrigin) -> Int {
        switch origin { case .user: return 0; case .learned: return 1; case .unknown: return 2 }
    }
}
