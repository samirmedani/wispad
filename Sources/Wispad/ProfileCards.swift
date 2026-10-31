import SwiftUI
import WispadCore

/// Cartes du Profil que la personne choisit d'afficher (Profil › Personnaliser), dans l'ordre de l'écran.
enum ProfileCard: String, CaseIterable, Identifiable {
    case rhythm
    case days
    case brain
    case words
    case tics
    case fixes
    case languages
    case apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rhythm: String(localized: "Ton rythme")
        case .days: String(localized: "Tes jours")
        case .brain: String(localized: "Ton cerveau")
        case .words: String(localized: "Tes mots")
        case .tics: String(localized: "Tes tics de langage")
        case .fixes: String(localized: "Ce que Wispad corrige le plus")
        case .languages: String(localized: "Langues")
        case .apps: String(localized: "Applications")
        }
    }

    var symbol: String {
        switch self {
        case .rhythm: "chart.bar.fill"
        case .days: "square.grid.3x3.fill"
        case .brain: "brain"
        case .words: "textformat"
        case .tics: "quote.bubble.fill"
        case .fixes: "wand.and.stars"
        case .languages: "globe"
        case .apps: "square.grid.2x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .rhythm: .blue
        case .days: Theme.brand
        case .brain: .pink
        case .words: .orange
        case .tics: .yellow
        case .fixes: .green
        case .languages: .teal
        case .apps: .indigo
        }
    }

    /// Carte large, seule sur sa ligne ; les autres vont par deux.
    var isWide: Bool { self == .brain || self == .words }

    /// Partie du calcul du profil qu'elle affiche ; le cerveau a son propre calcul.
    var part: ProfileBuilder.Parts? {
        switch self {
        case .rhythm: .rhythm
        case .days: .days
        case .brain: nil
        case .words: .words
        case .tics: .tics
        case .fixes: .fixes
        case .languages: .languages
        case .apps: .apps
        }
    }

    /// Lignes de l'écran, dans l'ordre : une carte large seule, les autres par deux. Une carte restée seule, parce
    /// que sa voisine est masquée, prend toute la ligne.
    static func rows(_ cards: [ProfileCard]) -> [[ProfileCard]] {
        var rows: [[ProfileCard]] = []
        for card in cards {
            if !card.isWide, let last = rows.last, last.count == 1, !last[0].isWide {
                rows[rows.count - 1].append(card)
            } else {
                rows.append([card])
            }
        }
        return rows
    }
}

/// Cartes affichées dans le Profil (réglage `profileCards`). Le cerveau, animé et plus gourmand, est coupé par défaut,
/// même pour une installation existante ; les autres cartes sont affichées. Une carte masquée n'est ni calculée ni
/// dessinée. Lu champ par champ : un champ absent ou illisible prend sa valeur par défaut ; un champ inconnu (carte
/// d'une version plus récente) reste dans le réglage enregistré.
struct ProfileCards: Codable, Equatable {
    var rhythm = true
    var days = true
    var brain = false
    var words = true
    var tics = true
    var fixes = true
    var languages = true
    var apps = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        let defaults = ProfileCards()
        rhythm = value(.rhythm, defaults.rhythm)
        days = value(.days, defaults.days)
        brain = value(.brain, defaults.brain)
        words = value(.words, defaults.words)
        tics = value(.tics, defaults.tics)
        fixes = value(.fixes, defaults.fixes)
        languages = value(.languages, defaults.languages)
        apps = value(.apps, defaults.apps)
    }

    subscript(card: ProfileCard) -> Bool {
        get {
            switch card {
            case .rhythm: rhythm
            case .days: days
            case .brain: brain
            case .words: words
            case .tics: tics
            case .fixes: fixes
            case .languages: languages
            case .apps: apps
            }
        }
        set {
            switch card {
            case .rhythm: rhythm = newValue
            case .days: days = newValue
            case .brain: brain = newValue
            case .words: words = newValue
            case .tics: tics = newValue
            case .fixes: fixes = newValue
            case .languages: languages = newValue
            case .apps: apps = newValue
            }
        }
    }

    /// Cartes affichées, dans l'ordre de l'écran.
    var shown: [ProfileCard] { ProfileCard.allCases.filter { self[$0] } }

    /// Parties du profil à calculer : seulement celles des cartes affichées.
    var parts: ProfileBuilder.Parts {
        var parts: ProfileBuilder.Parts = []
        for card in shown {
            if let part = card.part { parts.insert(part) }
        }
        return parts
    }
}
