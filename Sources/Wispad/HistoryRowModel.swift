import SwiftUI
import WispadCore

/// Ce qu'une ligne de l'historique affiche, calculé une fois par version d'une dictée :
/// le corps de la vue ne formate plus ni date, ni nombre, ni libellé pendant le défilement.
struct HistoryRowItem: Equatable {
    /// Au-delà, ou avec un retour à la ligne, le texte peut dépasser la limite de lignes : il faut le mesurer.
    static let overflowCharacterThreshold = 160

    var id: String
    var time: String
    var text: String
    var mayOverflow: Bool
    var meta: String
    var metaHelp: String
    var status: HistoryStatus
    var targetBundle: String?
    var hasAudio: Bool

    init(_ record: DictationRecord, locale: Locale = appLocale) {
        id = record.id
        time = record.createdAt.formatted(.dateTime.hour().minute().locale(locale))
        text = record.finalText
        mayOverflow = record.finalText.count > Self.overflowCharacterThreshold || record.finalText.contains("\n")
        meta = String(localized: "\(record.targetApp ?? "—") · \(record.wordCount) mots · \(record.providerLabel)")
        metaHelp = String(localized: "\(record.providerLabel) · \(record.model)")
        status = HistoryStatus(record.insertionStatus)
        targetBundle = record.targetBundle
        hasAudio = record.audioPath != nil
    }
}

/// Mémoire des lignes déjà vues : modèle de ligne et troncature mesurée, par dictée.
/// Une ligne qui revient à l'écran (défilement, retour sur l'écran) n'est ni reformatée ni remesurée.
/// Rien n'est écrit sur disque ; la mémoire suit l'historique (`follow`) et se vide d'un coup si elle dépasse
/// `limit` dictées.
@MainActor
final class HistoryRowCache {
    static let shared = HistoryRowCache()

    /// Résultat d'une mesure : à cette largeur, ce texte dépasse-t-il la limite de lignes ?
    struct Overflow: Equatable {
        var text: String
        var width: CGFloat
        var overflows: Bool

        /// `nil` : à mesurer. Une largeur nulle veut dire « pas encore connue » (ligne qui réapparaît) :
        /// la dernière mesure fait foi, puis la vraie largeur la confirme ou demande une nouvelle mesure.
        func overflows(text: String, width: CGFloat) -> Bool? {
            guard self.text == text else { return nil }
            guard width > 0 else { return overflows }
            return abs(self.width - width) < 0.5 ? overflows : nil
        }
    }

    let limit: Int
    private var items: [String: (record: DictationRecord, item: HistoryRowItem)] = [:]
    private var overflowByID: [String: Overflow] = [:]

    init(limit: Int = 5_000) {
        self.limit = max(limit, 1)
    }

    var itemCount: Int { items.count }
    var overflowCount: Int { overflowByID.count }

    func item(for record: DictationRecord) -> HistoryRowItem {
        if let cached = items[record.id], cached.record == record { return cached.item }
        let item = HistoryRowItem(record)
        if items[record.id] == nil, items.count >= limit { items.removeAll(keepingCapacity: true) }
        items[record.id] = (record, item)
        return item
    }

    func overflows(id: String, text: String, width: CGFloat) -> Bool? {
        overflowByID[id]?.overflows(text: text, width: width)
    }

    func store(_ overflow: Overflow, id: String) {
        guard overflow.width > 0 else { return }
        if overflowByID[id] == nil, overflowByID.count >= limit { overflowByID.removeAll(keepingCapacity: true) }
        overflowByID[id] = overflow
    }

    /// Une ligne de cette dictée est gardée (modèle ou mesure).
    func contains(id: String) -> Bool {
        items[id] != nil || overflowByID[id] != nil
    }

    /// Suit l'historique de l'app, relu après chaque dictée : une dictée supprimée quitte la mémoire avec sa mesure,
    /// une dictée modifiée sera recalculée, et une dictée relue à l'identique prend la place de sa copie. Ni texte
    /// supprimé ni seconde copie de l'historique ne restent ici pendant les jours où l'app reste ouverte.
    func follow(_ history: [DictationRecord], previous: [DictationRecord]) {
        guard !items.isEmpty || !overflowByID.isEmpty else { return }
        var present = Set<String>(minimumCapacity: history.count)
        for record in history {
            present.insert(record.id)
            if let cached = items[record.id] {
                if cached.record == record {
                    items[record.id] = (record, cached.item.sharing(record))
                } else {
                    items[record.id] = nil
                }
            }
            if let overflow = overflowByID[record.id] {
                if overflow.text == record.finalText {
                    overflowByID[record.id] = overflow.sharing(record.finalText)
                } else {
                    overflowByID[record.id] = nil
                }
            }
        }
        for record in previous where !present.contains(record.id) {
            items[record.id] = nil
            overflowByID[record.id] = nil
        }
    }

    func removeAll() {
        items.removeAll()
        overflowByID.removeAll()
    }
}

private extension HistoryRowItem {
    /// La même ligne, avec les textes de cette version de la dictée (égale à celle qui l'a calculée).
    func sharing(_ record: DictationRecord) -> HistoryRowItem {
        var item = self
        item.id = record.id
        item.text = record.finalText
        item.targetBundle = record.targetBundle
        return item
    }
}

private extension HistoryRowCache.Overflow {
    func sharing(_ text: String) -> HistoryRowCache.Overflow {
        var overflow = self
        overflow.text = text
        return overflow
    }
}
