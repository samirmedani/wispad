import Foundation
import Observation
import WispadCore

/// Version affichée dans la barre latérale, et ce qui la suit : pour une release, la dernière version publiée sur
/// GitHub ; pour un build de développement, le retard sur la branche principale du dépôt public. Une requête GitHub
/// sans clé ni cookie, en arrière-plan : au lancement, puis toutes les 6 heures.
@MainActor
@Observable
final class BuildStatus {
    static let shared = BuildStatus()

    /// Clé Info.plist renseignée à la compilation (`scripts/build-commit.sh`).
    static let commitInfoKey = "WispadBuildCommit"

    /// Version de l'Info.plist ; nil si elle manque (« — » dans la barre latérale).
    let version: String?
    let commit: String?
    /// Release publiée (clé `WispadRelease` ajoutée par `scripts/release.sh`) ou build compilé depuis les sources.
    let kind: BuildKind
    /// Build de développement : commits de `main` absents de cette version.
    private(set) var freshness: BuildFreshness = .unknown
    /// Release : dernière version lue sur GitHub, gardée quand une vérification échoue (hors ligne, limite de l'API).
    private(set) var latest: ReleaseInfo?
    /// Appelé à chaque vérification qui trouve une version plus récente ; le rappel n'a lieu qu'une fois par version.
    @ObservationIgnored var onAvailable: (@MainActor (ReleaseInfo) -> Void)?
    /// Lecture de la dernière release ; remplacée dans les tests, qui n'ont jamais de réseau.
    @ObservationIgnored var fetchLatest: @Sendable () async -> ReleaseCheckResult = { await BuildStatus.fetchLatestRelease() }
    @ObservationIgnored private var task: Task<Void, Never>?

    init(info: [String: Any]? = Bundle.main.infoDictionary) {
        version = info?["CFBundleShortVersionString"] as? String
        commit = BuildFreshnessCheck.shortCommit(info?[Self.commitInfoKey] as? String)
        kind = BuildKind(info: info)
    }

    /// « Wispad 0.1.2 » pour une release ; « Wispad 0.1.0 · abc1234 » pour un build de développement, sans commit si
    /// la compilation n'a pas pu le lire.
    var versionLine: String {
        let name = AppIdentity.displayName + " " + (version ?? "—")
        guard kind == .development, let commit else { return name }
        return name + " · " + commit
    }

    /// Ticket de bug prérempli avec la version et le commit affichés ici, et la version de macOS ; rien d'autre.
    func bugReportURL(system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> URL {
        FeedbackLinks.bugReportURL(version: version, commit: commit, system: system)
    }

    /// Ce que la barre latérale montre sous la version.
    var display: UpdateDisplay {
        UpdateDisplay.make(kind: kind, installed: version ?? "", latest: latest, freshness: freshness)
    }

    /// Release plus récente que celle qui tourne, s'il y en a une.
    var available: ReleaseInfo? {
        if case .available(let release) = display { return release }
        return nil
    }

    /// Lance la vérification périodique : la dernière release pour une release ; le retard sur `main` pour un build de
    /// développement (sans commit gravé, rien n'est demandé).
    func start(delay: Duration = .seconds(5)) {
        guard task == nil else { return }
        switch kind {
        case .release:
            let fetch = fetchLatest
            task = Task(priority: .utility) { [weak self] in
                // Après le démarrage : ni le lancement ni la première dictée n'attendent GitHub.
                try? await Task.sleep(for: delay)
                while !Task.isCancelled {
                    let result = await fetch()
                    self?.apply(result)
                    try? await Task.sleep(for: .seconds(ReleaseCheck.delay(after: result)))
                }
            }
        case .development:
            guard let commit, let url = BuildFreshnessCheck.compareURL(commit: commit) else { return }
            task = Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: delay)
                while !Task.isCancelled {
                    let result = await Self.fetchFreshness(url)
                    self?.freshness = result
                    try? await Task.sleep(for: .seconds(BuildFreshnessCheck.interval))
                }
            }
        }
    }

    /// Réponse lue : une release lisible remplace la précédente ; un échec (hors ligne, limite de l'API, tag mal
    /// formé, réponse illisible) ne change rien à l'écran et ne dit rien.
    func apply(_ result: ReleaseCheckResult) {
        guard case .release(let release) = result else { return }
        latest = release
        if let available { onAvailable?(available) }
    }

    /// `GET /repos/samirmedani/wispad/releases/latest`, sans clé ni cookie, 8 s au plus.
    nonisolated static func fetchLatestRelease() async -> ReleaseCheckResult {
        let session = URLSession(configuration: githubConfiguration(timeout: ReleaseCheck.timeout))
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: githubRequest(ReleaseCheck.latestURL))
            let http = response as? HTTPURLResponse
            return ReleaseCheck.result(
                statusCode: http?.statusCode ?? 0,
                data: data,
                retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                rateLimitReset: http?.value(forHTTPHeaderField: "X-RateLimit-Reset")
            )
        } catch {
            // Hors ligne ou délai dépassé : rien à l'écran, nouvel essai plus tôt.
            return .unreachable
        }
    }

    private nonisolated static func fetchFreshness(_ url: URL) async -> BuildFreshness {
        let session = URLSession(configuration: githubConfiguration(timeout: BuildFreshnessCheck.timeout))
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: githubRequest(url)) else { return .unknown }
        return BuildFreshnessCheck.freshness(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    private nonisolated static func githubConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// API publique de GitHub : aucune clé, un en-tête User-Agent (exigé par GitHub), rien d'autre.
    private nonisolated static func githubRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.displayName, forHTTPHeaderField: "User-Agent")
        return request
    }
}

extension BuildFreshness {
    /// Texte de la barre latérale ; nil quand seule la version s'affiche.
    var label: String? {
        switch self {
        case .upToDate: return String(localized: "À jour")
        case .behind(1): return String(localized: "1 commit de retard")
        case .behind(let count): return String(localized: "\(count) commits de retard")
        case .unknown: return nil
        }
    }
}
