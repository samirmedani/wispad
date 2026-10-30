import Foundation
import Observation
import SwiftUI
import WispadCore

/// Version affichée dans la barre latérale, comparée à la dernière release publiée sur GitHub. Un build de
/// développement montre aussi son retard sur main quand aucune release plus récente n'est disponible. Requêtes
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
    /// Comparaison du commit public ; remplacée dans les tests, y compris pour un commit local inconnu de GitHub.
    @ObservationIgnored var fetchFreshness: @Sendable (URL) async -> BuildFreshness = { await BuildStatus.fetchBuildFreshness($0) }
    /// Versions publiées depuis celle qui tourne, jusqu'à la plus récente, la plus récente d'abord : lues dès qu'une
    /// nouvelle version est trouvée, pour que la fenêtre de mise à jour les montre aussitôt, même si GitHub ne répond
    /// plus à son ouverture.
    private(set) var missedReleases: [ReleaseInfo] = []
    /// Lecture des dernières releases ; remplacée dans les tests.
    @ObservationIgnored var fetchHistory: @Sendable () async -> [ReleaseInfo]? = { await BuildStatus.fetchReleaseHistory() }
    /// Version pour laquelle les versions sautées sont lues (ou en cours de lecture) : une seule requête par version.
    @ObservationIgnored private var missedFor: SemanticVersion?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Recherche demandée à la main (barre latérale, Réglages › Aide) : en cours, puis son résultat quelques secondes.
    private(set) var manualPhase: ManualCheckPhase = .idle
    /// Vrai pendant la pause qui suit une recherche à la main : les boutons sont grisés.
    private(set) var coolingDown = false
    @ObservationIgnored private var manualLimit = ManualUpdateCheck()
    @ObservationIgnored private var phaseToken = 0
    @ObservationIgnored private var cooldownTask: Task<Void, Never>?
    /// Durée d'affichage du résultat d'une recherche à la main.
    static let resultDuration: Duration = .seconds(4)

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

    /// Versions sautées jusqu'à `release`, si elles sont déjà lues.
    func missed(for release: ReleaseInfo) -> [ReleaseInfo]? {
        missedReleases.first?.version == release.version ? missedReleases : nil
    }

    /// Lit une fois les versions publiées depuis celle qui tourne, jusqu'à `release` ; rien sans réponse de GitHub
    /// (nouvel essai à la prochaine vérification ou à l'ouverture de la fenêtre).
    func loadMissedReleases(for release: ReleaseInfo) async {
        guard missedFor != release.version, let current = version.flatMap(SemanticVersion.init) else { return }
        missedFor = release.version
        guard let all = await fetchHistory() else {
            if missedFor == release.version { missedFor = nil }
            return
        }
        guard missedFor == release.version else { return }
        missedReleases = ReleaseCheck.missed(all, after: current, upTo: release)
    }

    /// Release plus récente que celle qui tourne, s'il y en a une.
    var available: ReleaseInfo? {
        if case .available(let release) = display { return release }
        return nil
    }

    /// La release publique est prioritaire, y compris pour une installation compilée localement. Le diagnostic du
    /// commit reste un complément des builds de développement ; il ne masque jamais une mise à jour disponible.
    func start(delay: Duration = .seconds(5)) {
        guard task == nil else { return }
        let fetch = fetchLatest
        task = Task(priority: .utility) { [weak self] in
            // Après le démarrage : ni le lancement ni la première dictée n'attendent GitHub.
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                let result = await fetch()
                self?.apply(result)
                _ = await self?.refreshFreshness(after: result)
                try? await Task.sleep(for: .seconds(ReleaseCheck.delay(after: result)))
            }
        }
    }

    /// Recherche tout de suite, même requête que la vérification automatique, qui continue à son rythme. Une à la
    /// fois, au plus une par minute (plus tard si GitHub limite l'API). Rend la release plus récente trouvée, ou nil.
    @discardableResult
    func checkNow() async -> ReleaseInfo? {
        guard manualPhase != .checking, manualLimit.remaining(at: Date()) == 0 else { return nil }
        manualPhase = .checking
        let outcome: ManualCheckOutcome
        var found: ReleaseInfo?
        let result = await fetchLatest()
        manualLimit.record(result, at: Date())
        apply(result)
        let checkedFreshness = await refreshFreshness(after: result)
        switch result {
        case .release:
            found = available
            // Un commit privé ne rend pas une recherche de release réussie « impossible ».
            if found != nil {
                outcome = .available
            } else if case .behind = checkedFreshness {
                outcome = .behind
            } else {
                outcome = .upToDate
            }
        case .rateLimited: outcome = .rateLimited
        case .unusable, .unreachable:
            switch checkedFreshness {
            case .upToDate: outcome = .upToDate
            case .behind: outcome = .behind
            case .unknown, nil: outcome = .failed
            }
        }
        show(outcome)
        return found
    }

    /// Le complément de diagnostic n'ajoute aucune requête quand GitHub limite l'API ou qu'une release est proposée.
    /// Une comparaison inconnue (commit privé, réseau) conserve le dernier état connu.
    private func refreshFreshness(after result: ReleaseCheckResult) async -> BuildFreshness? {
        guard kind == .development, available == nil,
              let commit, let url = BuildFreshnessCheck.compareURL(commit: commit) else { return nil }
        if case .rateLimited = result { return nil }
        let checked = await fetchFreshness(url)
        if checked != .unknown { freshness = checked }
        return checked
    }

    /// Résultat affiché quelques secondes, puis la pause grise les boutons jusqu'à la prochaine recherche permise.
    private func show(_ outcome: ManualCheckOutcome) {
        manualPhase = .finished(outcome)
        phaseToken += 1
        let token = phaseToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.resultDuration)
            guard let self, self.phaseToken == token else { return }
            self.manualPhase = .idle
        }
        let wait = manualLimit.remaining(at: Date())
        guard wait > 0 else { return }
        coolingDown = true
        cooldownTask?.cancel()
        cooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.coolingDown = false
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

    /// Les 20 dernières releases (notes des versions sautées, fenêtre de mise à jour) ; nil sans réponse lisible.
    nonisolated static func fetchReleaseHistory() async -> [ReleaseInfo]? {
        guard let data = await fetchGitHub(ReleaseCheck.historyURL) else { return nil }
        return ReleaseCheck.releases(from: data)
    }

    /// Release d'une version (« Nouveautés de cette version ») ; nil si GitHub ne la connaît pas ou ne répond pas.
    nonisolated static func fetchRelease(_ version: SemanticVersion) async -> ReleaseInfo? {
        guard let data = await fetchGitHub(ReleaseCheck.tagURL(version)) else { return nil }
        return ReleaseCheck.release(from: data)
    }

    /// Corps d'une réponse 200 de l'API publique, 8 s au plus ; nil sinon.
    private nonisolated static func fetchGitHub(_ url: URL) async -> Data? {
        let session = URLSession(configuration: githubConfiguration(timeout: ReleaseCheck.timeout))
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: githubRequest(url)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private nonisolated static func fetchBuildFreshness(_ url: URL) async -> BuildFreshness {
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

/// Recherche à la main : rien, en cours, puis son résultat.
enum ManualCheckPhase: Equatable {
    case idle
    case checking
    case finished(ManualCheckOutcome)
}

enum ManualCheckOutcome: Equatable {
    case upToDate
    case available
    /// Build de développement en retard sur la branche principale.
    case behind
    case failed
    case rateLimited

    var message: String {
        switch self {
        case .upToDate: return String(localized: "Wispad est à jour")
        case .available: return String(localized: "Nouvelle version trouvée")
        case .behind: return String(localized: "Nouveaux commits sur GitHub")
        case .failed: return String(localized: "Recherche impossible : réessaie plus tard")
        case .rateLimited: return String(localized: "GitHub limite les recherches : réessaie plus tard")
        }
    }

    var symbol: String {
        switch self {
        case .upToDate: return "checkmark.circle.fill"
        case .available, .behind: return "arrow.down.circle.fill"
        case .failed, .rateLimited: return "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .upToDate: return .green
        case .available, .behind: return Theme.brand
        case .failed, .rateLimited: return .orange
        }
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
