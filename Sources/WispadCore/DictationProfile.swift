import Foundation

/// Profil de dictée : ce que l'historique dit de ta façon de parler. Tout est calculé sur ce Mac, à partir des
/// dictées conservées ; rien ne part chez un fournisseur.
public struct DictationProfile: Equatable, Sendable {
    public struct Count: Equatable, Sendable, Identifiable {
        public var label: String
        public var count: Int
        public var id: String { label }

        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    /// Mot dit puis remplacé par la correction (« cloud » → « Claude »), et combien de fois.
    public struct Fix: Equatable, Sendable, Identifiable {
        public var heard: String
        public var written: String
        public var count: Int
        public var id: String { heard + "→" + written }
    }

    public struct Longest: Equatable, Sendable {
        public var words: Int
        public var date: Date
    }

    public var words: Int
    public var dictations: Int
    public var audioSeconds: Double
    public var wordsPerMinute: Double?
    /// Plus longue dictée, en mots, et sa date.
    public var longest: Longest?
    /// Jours d'affilée avec au moins une dictée : la série en cours (jusqu'à aujourd'hui ou hier) et la meilleure.
    public var currentStreak: Int
    public var bestStreak: Int
    public var activeDays: Int
    /// Dictées par heure de la journée (24 cases) et par jour de la semaine (7 cases, lundi d'abord).
    public var byHour: [Int]
    public var byWeekday: [Int]
    /// Mots dictés par jour, du plus ancien au plus récent, sur les derniers jours (voir heatmapDays).
    public var daily: [Int]
    public var topWords: [Count]
    public var tics: [Count]
    public var fixes: [Fix]
    public var apps: [Count]
    /// Dictées surtout en anglais / surtout en français.
    public var englishDictations: Int
    public var frenchDictations: Int

    public static let heatmapDays = 18 * 7
}

public enum ProfileBuilder {
    /// Mots qui ne disent rien du sujet : articles, pronoms, liaisons, verbes très courants (français et anglais).
    public static let stopWords: Set<String> = Set("""
    a à ai aie aient aies ait alors as au aucun aussi autre aux avec avoir avons avez bah ben bien bon c ça car ce ceci \
    cela celle celles celui cet cette ces chez ci comme comment d dans de des du donc dont elle elles en encore es est \
    et étaient était été être eu eux fait faire fais faut fois font hein il ils j je jusqu l la là le les leur leurs lui \
    m ma mais me même mes moi mon n ne ni non nos notre nous o on ont ou où oui par parce pas peu peut plus pour \
    pourquoi qu quand que quel quelle quelles quels qui quoi s sa sans se ses si sien soit son sont sous suis sur t ta \
    te tes toi ton tous tout toute toutes très tu un une va vais vas veux voilà vont vos votre vous vu y euh genre \
    trop juste après avant déjà ici rien chose choses truc trucs ok okay dire dit dis avais avait aura serait sera \
    faudrait pourrait peux veut vraiment enfin bref puis cas coup temps beaucoup peut-être ouais nan également \
    the and or but if of to in on at for with by from as is are was were be been being it its this that these those i \
    you he she we they me him her us them my your his our their do does did have has had not no yes so just like \
    what which who when where why how all any can could would should will about there here then than too very also
    """.split(whereSeparator: { $0.isWhitespace }).map { String($0) })

    /// Tics de langage cherchés dans la transcription brute, avant correction.
    public static let ticPhrases = ["euh", "genre", "en fait", "tu vois", "du coup", "voilà", "bah", "ben",
                                    "en gros", "par exemple", "bref", "hein", "quoi", "you know", "like", "basically"]

    /// Mot montrable dans le profil : des lettres, pas d'adresse, de lien, de numéro ni de mot démesuré.
    public static func isShowable(_ word: String) -> Bool {
        guard (3...24).contains(word.count), word.contains(where: \.isLetter) else { return false }
        return !word.contains(where: { $0.isNumber || "@/\\:_=#.".contains($0) })
    }

    /// Mots d'un texte, en minuscules, apostrophes et ponctuation retirées (« l'appli » → « appli »).
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" || $0 == "’" || $0 == "@" || $0 == "/" || $0 == ".") })
            .map { token -> String in
                var word = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "-'’."))
                if let apostrophe = word.firstIndex(where: { $0 == "'" || $0 == "’" }) {
                    word = String(word[word.index(after: apostrophe)...])
                }
                return word
            }
            .filter { !$0.isEmpty }
    }

    /// Mots qui comptent d'une dictée : montrables, hors mots vides et mots masqués.
    public static func meaningful(_ text: String, hidden: Set<String> = []) -> [String] {
        tokens(text).filter { !stopWords.contains($0) && isShowable($0) && !hidden.contains($0) }
    }

    public static func build(
        records: [DictationRecord],
        hidden: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DictationProfile {
        let words = records.reduce(0) { $0 + $1.wordCount }
        let audio = records.reduce(0) { $0 + max(0, $1.durationSeconds) }
        let longest = records.max { $0.wordCount < $1.wordCount }.map { DictationProfile.Longest(words: $0.wordCount, date: $0.createdAt) }

        var byHour = Array(repeating: 0, count: 24)
        var byWeekday = Array(repeating: 0, count: 7)
        var days: [Date: Int] = [:]
        var wordCounts: [String: Int] = [:]
        var ticCounts: [String: Int] = [:]
        var fixCounts: [String: DictationProfile.Fix] = [:]
        var appCounts: [String: Int] = [:]
        var english = 0, french = 0

        for record in records {
            byHour[calendar.component(.hour, from: record.createdAt)] += 1
            // Lundi d'abord : dimanche (1) devient 6.
            byWeekday[(calendar.component(.weekday, from: record.createdAt) + 5) % 7] += 1
            days[calendar.startOfDay(for: record.createdAt), default: 0] += record.wordCount
            for word in meaningful(record.finalText, hidden: hidden) { wordCounts[word, default: 0] += 1 }
            let raw = " " + tokens(record.rawText).joined(separator: " ") + " "
            for tic in ticPhrases {
                let count = raw.components(separatedBy: " \(tic) ").count - 1
                if count > 0 { ticCounts[tic, default: 0] += count }
            }
            if let app = record.targetApp, !app.isEmpty { appCounts[app, default: 0] += 1 }
            if TranscriptLanguage.guess(record.finalText) == .english { english += 1 } else { french += 1 }
        }
        // Corrections d'écoute, sur les 1 500 dernières dictées : un mot dit, remplacé par un mot écrit.
        for record in records.prefix(1_500) where record.rawText != record.finalText {
            let heard = tokens(record.rawText), written = tokens(record.finalText)
            for hunk in CorrectionLearner.replacements(heard, written) where hunk.oldWords.count == 1 && hunk.newWords.count == 1 {
                let old = hunk.oldWords[0], new = hunk.newWords[0]
                guard CorrectionLearner.key(old) != CorrectionLearner.key(new), isShowable(old), isShowable(new),
                      !hidden.contains(old), !hidden.contains(new) else { continue }
                fixCounts[old + "→" + new, default: DictationProfile.Fix(heard: old, written: new, count: 0)].count += 1
            }
        }

        let today = calendar.startOfDay(for: now)
        let daily = (0..<DictationProfile.heatmapDays).reversed().map { offset -> Int in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return 0 }
            return days[day] ?? 0
        }
        let streak = streaks(Set(days.keys), today: today, calendar: calendar)

        return DictationProfile(
            words: words,
            dictations: records.count,
            audioSeconds: audio,
            wordsPerMinute: audio >= 10 ? Double(words) / (audio / 60) : nil,
            longest: longest,
            currentStreak: streak.current,
            bestStreak: streak.best,
            activeDays: days.count,
            byHour: byHour,
            byWeekday: byWeekday,
            daily: daily,
            topWords: top(wordCounts, limit: 40),
            tics: top(ticCounts, limit: 8),
            fixes: fixCounts.values.filter { $0.count >= 2 }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.heard < $1.heard }
                .prefix(8).map { $0 },
            apps: top(appCounts, limit: 6),
            englishDictations: english,
            frenchDictations: french
        )
    }

    static func top(_ counts: [String: Int], limit: Int) -> [DictationProfile.Count] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { DictationProfile.Count(label: $0.key, count: $0.value) }
    }

    /// Série en cours (comptée seulement si elle touche aujourd'hui ou hier) et meilleure série.
    static func streaks(_ days: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, best: Int) {
        var best = 0, run = 0
        var previous: Date?
        for day in days.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day { run += 1 } else { run = 1 }
            best = max(best, run)
            previous = day
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return (0, best) }
        var current = 0
        var cursor: Date? = days.contains(today) ? today : days.contains(yesterday) ? yesterday : nil
        while let day = cursor, days.contains(day) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        return (current, best)
    }
}

/// Le « cerveau » : les mots fréquents reliés quand ils reviennent dans les mêmes dictées, regroupés en familles,
/// placés en 3D par un calcul de forces (le même résultat à chaque calcul).
public struct WordGraph: Equatable, Sendable {
    public struct Node: Equatable, Sendable, Identifiable {
        public var id: Int
        public var word: String
        public var count: Int
        public var cluster: Int
        public var x: Double
        public var y: Double
        public var z: Double
    }

    public struct Edge: Equatable, Sendable {
        public var a: Int
        public var b: Int
        public var weight: Int
    }

    public var nodes: [Node]
    public var edges: [Edge]

    public static let empty = WordGraph(nodes: [], edges: [])

    /// Voisins d'un mot, du lien le plus fort au plus faible.
    public func neighbors(of id: Int) -> [(node: Node, weight: Int)] {
        edges.compactMap { edge -> (node: Node, weight: Int)? in
            if edge.a == id { return (nodes[edge.b], edge.weight) }
            if edge.b == id { return (nodes[edge.a], edge.weight) }
            return nil
        }
        .sorted { $0.weight > $1.weight }
    }

    public static func build(records: [DictationRecord], hidden: Set<String> = [], size: Int = 48) -> WordGraph {
        let documents = records.prefix(3_000).map { Set(ProfileBuilder.meaningful($0.finalText, hidden: hidden)) }
        var frequency: [String: Int] = [:]
        for words in documents { for word in words { frequency[word, default: 0] += 1 } }
        let chosen = ProfileBuilder.top(frequency.filter { $0.value >= 2 }, limit: size).map(\.label)
        guard chosen.count >= 2 else { return .empty }
        let index = Dictionary(uniqueKeysWithValues: chosen.enumerated().map { ($0.element, $0.offset) })
        let n = chosen.count
        var pairs: [Int: Int] = [:]
        for words in documents {
            let ids = words.compactMap { index[$0] }.sorted()
            for i in ids.indices { for j in ids.indices where j > i { pairs[ids[i] * n + ids[j], default: 0] += 1 } }
        }
        // Liens forts seulement : les 4 meilleurs de chaque mot, vus ensemble au moins deux fois.
        var kept: Set<Int> = []
        for node in 0..<n {
            let mine = pairs.filter { ($0.key / n == node || $0.key % n == node) && $0.value >= 2 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4)
            kept.formUnion(mine.map(\.key))
        }
        let edges = kept.sorted().map { Edge(a: $0 / n, b: $0 % n, weight: pairs[$0] ?? 0) }
        let families = clusters(count: n, edges: edges)
        let positions = layout(count: n, edges: edges, clusters: families)
        let nodes = chosen.enumerated().map { offset, word in
            Node(id: offset, word: word, count: frequency[word] ?? 0, cluster: families[offset],
                 x: positions[offset].x, y: positions[offset].y, z: positions[offset].z)
        }
        return WordGraph(nodes: nodes, edges: edges)
    }

    /// Familles par propagation d'étiquettes pondérée, renumérotées de la plus grande à la plus petite.
    static func clusters(count: Int, edges: [Edge]) -> [Int] {
        var label = Array(0..<count)
        for _ in 0..<12 {
            var changed = false
            for node in 0..<count {
                var score: [Int: Int] = [:]
                for edge in edges where edge.a == node || edge.b == node {
                    score[label[edge.a == node ? edge.b : edge.a], default: 0] += edge.weight
                }
                if let best = score.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key,
                   best != label[node] {
                    label[node] = best
                    changed = true
                }
            }
            if !changed { break }
        }
        var sizes: [Int: Int] = [:]
        for value in label { sizes[value, default: 0] += 1 }
        let order = sizes.keys.sorted { (sizes[$0] ?? 0) != (sizes[$1] ?? 0) ? (sizes[$0] ?? 0) > (sizes[$1] ?? 0) : $0 < $1 }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return label.map { rank[$0] ?? 0 }
    }

    struct Point { var x = 0.0, y = 0.0, z = 0.0 }

    /// Positions 3D dans la sphère unité : départ sur une spirale de Fibonacci, puis attraction le long des liens,
    /// répulsion entre tous (moindre dans une même famille) et légère gravité vers le centre.
    static func layout(count: Int, edges: [Edge], clusters: [Int]) -> [Point] {
        var p: [Point] = (0..<count).map { i in
            let y = 1 - 2 * (Double(i) + 0.5) / Double(count)
            let r = (1 - y * y).squareRoot()
            let theta = Double(i) * 2.399963229728653
            return Point(x: cos(theta) * r, y: y, z: sin(theta) * r)
        }
        let maxWeight = Double(edges.map(\.weight).max() ?? 1)
        for step in 0..<220 {
            let cooling = 0.32 * (1 - Double(step) / 220) + 0.02
            var force = Array(repeating: Point(), count: count)
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let dx = p[i].x - p[j].x, dy = p[i].y - p[j].y, dz = p[i].z - p[j].z
                    var push = 0.09 / max(dx * dx + dy * dy + dz * dz, 0.01)
                    if clusters[i] == clusters[j] { push *= 0.85 }
                    force[i].x += dx * push; force[i].y += dy * push; force[i].z += dz * push
                    force[j].x -= dx * push; force[j].y -= dy * push; force[j].z -= dz * push
                }
            }
            for edge in edges {
                let dx = p[edge.b].x - p[edge.a].x, dy = p[edge.b].y - p[edge.a].y, dz = p[edge.b].z - p[edge.a].z
                let pull = 0.03 * (0.4 + 0.6 * Double(edge.weight) / maxWeight)
                force[edge.a].x += dx * pull; force[edge.a].y += dy * pull; force[edge.a].z += dz * pull
                force[edge.b].x -= dx * pull; force[edge.b].y -= dy * pull; force[edge.b].z -= dz * pull
            }
            for i in 0..<count {
                var f = Point(x: force[i].x - p[i].x * 0.02, y: force[i].y - p[i].y * 0.02, z: force[i].z - p[i].z * 0.02)
                let length = (f.x * f.x + f.y * f.y + f.z * f.z).squareRoot()
                if length > 1 { f = Point(x: f.x / length, y: f.y / length, z: f.z / length) }
                p[i].x += f.x * cooling; p[i].y += f.y * cooling; p[i].z += f.z * cooling
            }
        }
        let cx = p.map(\.x).reduce(0, +) / Double(count)
        let cy = p.map(\.y).reduce(0, +) / Double(count)
        let cz = p.map(\.z).reduce(0, +) / Double(count)
        p = p.map { Point(x: $0.x - cx, y: $0.y - cy, z: $0.z - cz) }
        // Rayon du 90e centile : un mot isolé loin du reste n'écrase pas tout le nuage au centre.
        let distances = p.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }.sorted()
        let radius = distances.isEmpty ? 1 : distances[min(distances.count - 1, distances.count * 9 / 10)]
        guard radius > 0 else { return p }
        return p.map { point in
            let scaled = Point(x: point.x / radius, y: point.y / radius, z: point.z / radius)
            let length = (scaled.x * scaled.x + scaled.y * scaled.y + scaled.z * scaled.z).squareRoot()
            return length > 1.15 ? Point(x: scaled.x * 1.15 / length, y: scaled.y * 1.15 / length, z: scaled.z * 1.15 / length) : scaled
        }
    }
}
