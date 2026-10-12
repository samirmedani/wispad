import Foundation
import Observation
import WispadCore

/// Version affichée dans la barre latérale et retard sur la branche principale du dépôt public.
/// Une requête GitHub sans clé ni cookie, en arrière-plan : au lancement, puis toutes les 6 heures.
@MainActor
@Observable
final class BuildStatus {
    static let shared = BuildStatus()

    /// Clé Info.plist renseignée à la compilation (`scripts/build-commit.sh`).
    static let commitInfoKey = "WispadBuildCommit"

    /// Version de l'Info.plist ; nil si elle manque (« — » dans la barre latérale).
    let version: String?
    let commit: String?
    private(set) var freshness: BuildFreshness = .unknown
    @ObservationIgnored private var task: Task<Void, Never>?

    init(info: [String: Any]? = Bundle.main.infoDictionary) {
        version = info?["CFBundleShortVersionString"] as? String
        commit = BuildFreshnessCheck.shortCommit(info?[Self.commitInfoKey] as? String)
    }

    /// « Wispad 0.1.0 · abc1234 », sans commit si la compilation n'a pas pu le lire.
    var versionLine: String {
        [AppIdentity.displayName + " " + (version ?? "—"), commit].compactMap { $0 }.joined(separator: " · ")
    }

    /// Ticket de bug prérempli avec la version et le commit affichés ici, et la version de macOS ; rien d'autre.
    func bugReportURL(system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> URL {
        FeedbackLinks.bugReportURL(version: version, commit: commit, system: system)
    }

    /// Lance la vérification périodique. Sans commit gravé, rien n'est demandé.
    func start(delay: Duration = .seconds(5)) {
        guard task == nil, let commit, let url = BuildFreshnessCheck.compareURL(commit: commit) else { return }
        task = Task(priority: .utility) { [weak self] in
            // Après le démarrage : ni le lancement ni la première dictée n'attendent GitHub.
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                let result = await Self.fetch(url)
                self?.freshness = result
                try? await Task.sleep(for: .seconds(BuildFreshnessCheck.interval))
            }
        }
    }

    private nonisolated static func fetch(_ url: URL) async -> BuildFreshness {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = BuildFreshnessCheck.timeout
        configuration.timeoutIntervalForResource = BuildFreshnessCheck.timeout
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.displayName, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request) else { return .unknown }
        return BuildFreshnessCheck.freshness(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
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
