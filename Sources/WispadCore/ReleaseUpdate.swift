import Foundation

// MARK: - Version

/// Version X.Y.Z (semver) d'une release (tag « v0.1.2 ») ou de l'app (`CFBundleShortVersionString`).
/// Pré-version comprise (« 1.0.0-beta.2 ») ; les métadonnées de build (« +abc ») sont ignorées.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Identifiants de pré-version (« beta », « 2 ») ; vide pour une version finale.
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// « v1.2.3 », « 1.2.3 », « v1.2.3-beta.1 », « 1.2.3+build.5 ». Nil pour tout le reste : « 1.2 », « 1.2.3.4 »,
    /// « v01.2.3 », « latest », « 1.2.x ».
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") {
            let build = rest[rest.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false)
            guard build.allSatisfy({ Self.isIdentifier($0) }) else { return nil }
            rest = rest[..<plus]
        }
        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let parts = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ Self.isIdentifier($0) && !Self.hasLeadingZero($0) }) else { return nil }
            prerelease = parts.map { String($0) }
            rest = rest[..<dash]
        }
        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var values: [Int] = []
        for part in numbers {
            guard Self.isNumeric(part), !Self.hasLeadingZero(part), let value = Int(part) else { return nil }
            values.append(value)
        }
        self.init(major: values[0], minor: values[1], patch: values[2], prerelease: prerelease)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Même numéro : une pré-version passe avant la version finale.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            return precedes(left, right)
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// Identifiants de pré-version : les numériques entre eux par valeur et avant les autres, comparés en ASCII.
    private static func precedes(_ left: String, _ right: String) -> Bool {
        let leftNumeric = isNumeric(Substring(left))
        let rightNumeric = isNumeric(Substring(right))
        if leftNumeric && rightNumeric {
            return left.count == right.count ? left < right : left.count < right.count
        }
        if leftNumeric != rightNumeric { return leftNumeric }
        return left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private static func isNumeric(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isIdentifier(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// « 01 » : refusé pour un nombre (semver), permis dans un identifiant alphanumérique (« 0a »).
    private static func hasLeadingZero(_ part: Substring) -> Bool {
        isNumeric(part) && part.count > 1 && part.first == "0"
    }
}

// MARK: - Release publiée

/// Disque d'installation (`Wispad.dmg`) d'une release.
public struct DiskImageAsset: Equatable, Sendable {
    public var url: URL
    /// Taille annoncée par GitHub, en octets.
    public var size: Int64?
    /// Empreinte SHA-256 annoncée par GitHub, en hexadécimal minuscule.
    public var sha256: String?

    public init(url: URL, size: Int64? = nil, sha256: String? = nil) {
        self.url = url
        self.size = size
        self.sha256 = sha256
    }
}

/// Dernière release publiée sur GitHub, telle que l'app s'en sert.
public struct ReleaseInfo: Equatable, Sendable, Identifiable {
    public var version: SemanticVersion
    /// Tag d'origine (« v0.1.2 »).
    public var tag: String
    /// Notes de version, en markdown, telles que publiées.
    public var notes: String
    /// Page de la release sur GitHub.
    public var pageURL: URL
    /// Disque d'installation ; nil s'il manque : seule la page de la release est proposée.
    public var diskImage: DiskImageAsset?
    /// Date de publication annoncée par GitHub.
    public var publishedAt: Date?

    public var id: String { tag }

    public init(version: SemanticVersion, tag: String, notes: String, pageURL: URL, diskImage: DiskImageAsset?,
                publishedAt: Date? = nil) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.pageURL = pageURL
        self.diskImage = diskImage
        self.publishedAt = publishedAt
    }
}

/// Réponse de `GET /repos/…/releases/latest`, lue sans réseau.
public enum ReleaseCheckResult: Equatable, Sendable {
    /// Dernière release lisible.
    case release(ReleaseInfo)
    /// Rien d'exploitable : aucune release publiée (404), tag mal formé, brouillon, pré-version, réponse illisible.
    case unusable
    /// Limite de l'API publique atteinte (403, 429) : nouvel essai plus tard, sans rien afficher.
    case rateLimited(retryAfter: TimeInterval?)
    /// Hors ligne, délai dépassé ou GitHub en panne (5xx) : nouvel essai plus tôt, sans rien afficher.
    case unreachable
}

/// Vérification des releases : l'adresse interrogée, la lecture de la réponse et le délai avant la suivante.
public enum ReleaseCheck {
    public static let repository = BuildFreshnessCheck.repository
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Versions sautées montrées au plus, et releases lues pour les trouver (une seule requête).
    public static let maximumMissed = 30
    /// Les 30 dernières releases : notes des versions sautées, dans la fenêtre de mise à jour.
    public static let historyURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=\(maximumMissed)")!

    /// Release d'une version donnée (« Nouveautés de cette version »).
    public static func tagURL(_ version: SemanticVersion) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/tags/v\(version.description)")!
    }
    /// Toutes les releases : repli quand la page d'une release est inconnue.
    public static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    /// Disque d'installation publié avec chaque release (`scripts/release.sh`).
    public static let diskImageName = "Wispad.dmg"
    /// Au lancement, puis toutes les 6 heures.
    public static let interval: TimeInterval = 6 * 3600
    /// Après un échec réseau : nouvel essai dans 30 minutes.
    public static let retryInterval: TimeInterval = 30 * 60
    /// Limite de l'API atteinte sans délai annoncé : nouvel essai dans une heure.
    public static let rateLimitDelay: TimeInterval = 3600
    /// Jamais deux demandes à moins de 5 minutes d'écart.
    public static let minimumDelay: TimeInterval = 5 * 60
    public static let timeout: TimeInterval = 8
    /// Garde-fou : le disque de Wispad pèse quelques Mo.
    public static let maximumDiskImageBytes: Int64 = 512 * 1_048_576

    /// Réponse de l'API publique → résultat. `statusCode` 0 : aucune réponse (hors ligne, délai dépassé).
    /// `retryAfter` et `rateLimitReset` : en-têtes `Retry-After` (secondes) et `X-RateLimit-Reset` (date Unix).
    public static func result(statusCode: Int, data: Data, retryAfter: String? = nil, rateLimitReset: String? = nil,
                              now: Date = Date()) -> ReleaseCheckResult {
        switch statusCode {
        case 200:
            guard let info = release(from: data) else { return .unusable }
            return .release(info)
        case 403, 429:
            return .rateLimited(retryAfter: waitingTime(retryAfter: retryAfter, rateLimitReset: rateLimitReset, now: now))
        case 0, 408, 500...599:
            return .unreachable
        default:
            return .unusable
        }
    }

    /// Attente avant la vérification suivante.
    public static func delay(after result: ReleaseCheckResult) -> TimeInterval {
        switch result {
        case .release, .unusable: return interval
        case .unreachable: return retryInterval
        case .rateLimited(let retryAfter): return min(interval, max(minimumDelay, retryAfter ?? rateLimitDelay))
        }
    }

    /// `sha256:<64 caractères hexadécimaux>` → hexadécimal minuscule ; nil pour tout autre format.
    public static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return hex
    }

    /// Release lue dans le corps d'une réponse 200 ; nil si le tag n'est pas une version ou si ce n'est pas une
    /// release publiée.
    public static func release(from data: Data) -> ReleaseInfo? {
        guard let latest = try? JSONDecoder().decode(GitHubRelease.self, from: data) else { return nil }
        return info(latest)
    }

    /// Réponse de `releases?per_page=20` : les releases publiées et lisibles, une illisible écartée seule.
    public static func releases(from data: Data) -> [ReleaseInfo] {
        let list = (try? JSONDecoder().decode([LenientElement<GitHubRelease>].self, from: data)) ?? []
        return list.compactMap { $0.value.flatMap(info) }
    }

    /// Versions que la fenêtre de mise à jour présente : toutes celles publiées après la version installée, jusqu'à
    /// la plus récente, de la plus récente à la plus ancienne (`maximumMissed` au plus). La plus récente y est
    /// toujours.
    public static func missed(_ releases: [ReleaseInfo], after current: SemanticVersion?, upTo latest: ReleaseInfo) -> [ReleaseInfo] {
        var seen: Set<SemanticVersion> = [latest.version]
        var older: [ReleaseInfo] = []
        for release in releases.sorted(by: { $0.version > $1.version }) where release.version < latest.version {
            guard let current, release.version > current, seen.insert(release.version).inserted else { continue }
            older.append(release)
        }
        return Array(([latest] + older).prefix(maximumMissed))
    }

    private static func info(_ latest: GitHubRelease) -> ReleaseInfo? {
        guard latest.draft != true, latest.prerelease != true,
              let version = SemanticVersion(latest.tagName) else { return nil }
        let uploaded = (latest.assets ?? []).compactMap { $0.value }.first { candidate in
            candidate.name == diskImageName && (candidate.state ?? "uploaded") == "uploaded"
        }
        return ReleaseInfo(
            version: version,
            tag: latest.tagName,
            notes: latest.body ?? "",
            pageURL: pageURL(latest.htmlURL, tag: latest.tagName),
            diskImage: uploaded.flatMap { diskImage($0) },
            publishedAt: latest.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    /// Page de la release : celle annoncée si elle est bien sur le dépôt, sinon reconstruite depuis le tag.
    static func pageURL(_ announced: String?, tag: String) -> URL {
        if let announced, let url = URL(string: announced),
           isOnRepository(url, path: "/\(repository)/releases/") {
            return url
        }
        return releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
    }

    /// Le disque doit venir des releases du dépôt, en HTTPS, avec une taille plausible.
    private static func diskImage(_ asset: GitHubAsset) -> DiskImageAsset? {
        guard let url = URL(string: asset.browserDownloadURL),
              isOnRepository(url, path: "/\(repository)/releases/download/") else { return nil }
        if let size = asset.size, size <= 0 || size > maximumDiskImageBytes { return nil }
        return DiskImageAsset(url: url, size: asset.size, sha256: sha256(fromDigest: asset.digest))
    }

    private static func isOnRepository(_ url: URL, path prefix: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https" && components.host == "github.com" && components.path.hasPrefix(prefix)
    }

    private static func waitingTime(retryAfter: String?, rateLimitReset: String?, now: Date) -> TimeInterval? {
        if let seconds = retryAfter.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }),
           seconds.isFinite, seconds >= 0 {
            return seconds
        }
        if let reset = rateLimitReset.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }), reset.isFinite {
            let wait = reset - now.timeIntervalSince1970
            return wait > 0 ? wait : nil
        }
        return nil
    }
}

/// Réponse de `releases/latest`, seulement les champs utiles.
private struct GitHubRelease: Decodable {
    var tagName: String
    var body: String?
    var htmlURL: String?
    var draft: Bool?
    var prerelease: Bool?
    var assets: [LenientElement<GitHubAsset>]?
    var publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
        case publishedAt = "published_at"
    }
}

private struct GitHubAsset: Decodable {
    var name: String
    var browserDownloadURL: String
    var size: Int64?
    var state: String?
    var digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case state
        case digest
    }
}

/// Élément illisible d'une liste : nil, sans faire échouer ses voisins.
private struct LenientElement<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

// MARK: - Affichage

/// Origine de la version qui tourne.
public enum BuildKind: Equatable, Sendable {
    /// Release publiée sur GitHub : disque signé Developer ID et notarisé, construit par `scripts/release.sh`.
    case release
    /// Build compilé depuis les sources (Xcode, `scripts/build.sh`, `scripts/install.sh`).
    case development

    /// Clé Info.plist que seul `scripts/release.sh` ajoute (booléen vrai), avant de signer l'app.
    public static let infoKey = "WispadRelease"

    public init(info: [String: Any]?) {
        let value = info?[Self.infoKey]
        let flagged = (value as? Bool) == true
            || (value as? String).map { ["1", "true", "yes"].contains($0.lowercased()) } == true
        self = flagged ? .release : .development
    }
}

/// Ce que la barre latérale affiche sous la version.
/// Recherche de mise à jour demandée à la main : jamais deux à moins d'une minute ; quand GitHub dit que sa limite est
/// atteinte, pas avant l'heure annoncée (un quart d'heure sans indication, six heures au plus).
public struct ManualUpdateCheck: Equatable, Sendable {
    public static let cooldown: TimeInterval = 60
    public static let rateLimitPause: TimeInterval = 15 * 60
    /// Prochaine recherche permise ; nil avant la première.
    public private(set) var availableAt: Date?

    public init() {}

    /// Secondes avant la prochaine recherche permise ; 0 si elle l'est.
    public func remaining(at now: Date) -> TimeInterval {
        guard let availableAt else { return 0 }
        return max(0, availableAt.timeIntervalSince(now))
    }

    /// Recherche faite à ce moment, avec ce résultat (nil : build de développement).
    public mutating func record(_ result: ReleaseCheckResult?, at now: Date) {
        var pause = Self.cooldown
        if case .rateLimited(let retryAfter) = result {
            pause = min(ReleaseCheck.interval, max(Self.cooldown, retryAfter ?? Self.rateLimitPause))
        }
        availableAt = now.addingTimeInterval(pause)
    }
}

public enum UpdateDisplay: Equatable, Sendable {
    /// Build de développement : retard sur la branche principale (« N commits de retard »), comme avant les releases.
    case development(BuildFreshness)
    /// Release à jour (ou plus récente que la dernière publiée).
    case upToDate
    /// Une release plus récente est publiée.
    case available(ReleaseInfo)
    /// Seule la version : GitHub pas encore lu ou injoignable, ou version de l'app illisible.
    case unknown

    public static func make(kind: BuildKind, installed: String, latest: ReleaseInfo?, freshness: BuildFreshness) -> UpdateDisplay {
        guard kind == .release else { return .development(freshness) }
        guard let latest, let current = SemanticVersion(installed) else { return .unknown }
        return latest.version > current ? .available(latest) : .upToDate
    }
}

/// Rappel discret d'une nouvelle version dans la bulle : une seule fois par version.
public enum UpdateReminder {
    /// Vrai si cette version n'a pas encore été rappelée, ni une plus récente.
    public static func shouldRemind(_ version: SemanticVersion, lastReminded: String) -> Bool {
        guard let last = SemanticVersion(lastReminded) else { return true }
        return version > last
    }
}

// MARK: - Notes de version

/// Bloc des notes de version, en markdown simple. La mise en forme dans la ligne (gras, italique, lien, `code`)
/// reste dans le texte : l'app la rend.
public enum ReleaseNoteBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(String, String)
    case paragraph(String)
    case code(String)
}

/// Découpe des notes de version : titres (#), puces (-, *, +), listes numérotées, paragraphes, blocs de code (```).
/// Lignes de séparation ignorées, citations (>) lues comme du texte.
public enum ReleaseNotes {
    /// Garde-fou d'affichage : au-delà, la suite reste sur la page de la release.
    public static let maximumBlocks = 200

    public static func blocks(_ markdown: String) -> [ReleaseNoteBlock] {
        var blocks: [ReleaseNoteBlock] = []
        var paragraph: [String] = []
        var fence: [String]?
        func closeParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let code = fence {
                if line.hasPrefix("```") {
                    blocks.append(.code(code.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence?.append(raw)
                }
                continue
            }
            if line.hasPrefix("```") {
                closeParagraph()
                fence = []
            } else if line.isEmpty || isRule(line) {
                closeParagraph()
            } else if let block = heading(line) ?? bullet(line) ?? numbered(line) {
                closeParagraph()
                blocks.append(block)
            } else if line.hasPrefix(">") {
                let quoted = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if quoted.isEmpty { closeParagraph() } else { paragraph.append(quoted) }
            } else {
                paragraph.append(line)
            }
        }
        if let code = fence, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        closeParagraph()
        return Array(blocks.prefix(maximumBlocks))
    }

    private static func heading(_ line: String) -> ReleaseNoteBlock? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: level, text: text)
    }

    private static func bullet(_ line: String) -> ReleaseNoteBlock? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .bullet(text)
        }
        return nil
    }

    private static func numbered(_ line: String) -> ReleaseNoteBlock? {
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .numbered(String(digits), text)
    }

    /// « --- », « *** », « _ _ _ » : simple séparation.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }
}

// MARK: - Notes prêtes à montrer

/// Notes d'une version telles que la fenêtre de mise à jour les montre : une phrase d'accroche, puis des rubriques
/// (Nouveau, Corrigé, Amélioré) faites de points « titre : détail ». Ce qui ne sert que sur GitHub y reste : les
/// citations (conseil pour une ancienne version bloquée) et l'empreinte SHA-256 du disque.
public struct ReleaseDigest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case new, fixed, improved
        case other(String)
    }

    public struct Item: Equatable, Sendable {
        /// Ce qui change, en gras (« Taille de la bulle ») ; nil pour un point d'une seule phrase.
        public var title: String?
        public var text: String

        public init(title: String? = nil, text: String) {
            self.title = title
            self.text = text
        }
    }

    public struct Section: Equatable, Sendable {
        public var kind: Kind
        public var items: [Item]

        public init(kind: Kind, items: [Item]) {
            self.kind = kind
            self.items = items
        }
    }

    public var headline: String?
    public var sections: [Section]

    public init(headline: String? = nil, sections: [Section] = []) {
        self.headline = headline
        self.sections = sections
    }

    public var isEmpty: Bool { headline == nil && sections.allSatisfy { $0.items.isEmpty } }
}

extension ReleaseNotes {
    public static func digest(_ markdown: String) -> ReleaseDigest {
        let kept = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix(">") && !trimmed.lowercased().hasPrefix("sha-256") && !trimmed.lowercased().hasPrefix("sha256")
            }
            .joined(separator: "\n")
        var digest = ReleaseDigest()
        func add(_ item: ReleaseDigest.Item) {
            if digest.sections.isEmpty { digest.sections.append(ReleaseDigest.Section(kind: .other(""), items: [])) }
            digest.sections[digest.sections.count - 1].items.append(item)
        }
        for block in blocks(kept) {
            switch block {
            case .heading(_, let text):
                digest.sections.append(ReleaseDigest.Section(kind: kind(text), items: []))
            case .bullet(let text), .numbered(_, let text):
                add(item(text))
            case .paragraph(let text):
                var prose: [String] = []
                func flush() {
                    guard !prose.isEmpty else { return }
                    let joined = prose.joined(separator: " ")
                    prose.removeAll()
                    if digest.headline == nil, digest.sections.isEmpty { digest.headline = joined } else { add(ReleaseDigest.Item(text: joined)) }
                }
                for line in text.components(separatedBy: "\n") {
                    if let title = boldLine(line) {
                        flush()
                        digest.sections.append(ReleaseDigest.Section(kind: kind(title), items: []))
                    } else {
                        prose.append(line)
                    }
                }
                flush()
            case .code:
                continue
            }
        }
        digest.sections.removeAll { $0.items.isEmpty }
        return digest
    }

    /// « **Nouveau** » seul sur sa ligne : un titre de rubrique.
    private static func boldLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 4, trimmed.hasPrefix("**"), trimmed.hasSuffix("**") else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
        return inner.isEmpty || inner.contains("**") ? nil : inner
    }

    private static func kind(_ title: String) -> ReleaseDigest.Kind {
        let key = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        if ["nouveau", "nouveaute", "nouveautes", "new"].contains(key) { return .new }
        if ["corrige", "corriges", "correction", "corrections", "correctifs", "fixed", "fixes"].contains(key) { return .fixed }
        if ["ameliore", "amelioration", "ameliorations", "improved", "improvements"].contains(key) { return .improved }
        return .other(title)
    }

    /// « Taille de la bulle : de 80 % à 160 %. » → titre « Taille de la bulle », détail « De 80 % à 160 %. ». Un
    /// point sans début court avant « : » reste une seule phrase.
    static func item(_ text: String) -> ReleaseDigest.Item {
        guard let colon = text.range(of: " : ") else { return ReleaseDigest.Item(text: text) }
        let lead = text[..<colon.lowerBound].replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        let rest = text[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !lead.isEmpty, lead.count <= 90, !rest.isEmpty, !lead.contains(". ") else { return ReleaseDigest.Item(text: text) }
        return ReleaseDigest.Item(title: lead, text: rest.prefix(1).uppercased() + rest.dropFirst())
    }
}
