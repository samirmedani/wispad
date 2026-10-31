import Foundation
import Observation
import WispadCore

/// Ce dont dépend le calcul du Profil.
struct ProfileRequest: Equatable, Sendable {
    var period: StatsPeriod
    /// Début du jour : « Aujourd'hui », les séries et la grille des jours changent à minuit.
    var day: Date
    /// Révision de l'historique (`AppModel.historyRevision`).
    var history: Int
    var hidden: [String]
    var parts: ProfileBuilder.Parts
    var brain: Bool
    var typingWPM: Double

    @MainActor
    init(model: AppModel, now: Date = Date()) {
        let settings = model.settings
        period = settings.profilePeriod
        day = Calendar.current.startOfDay(for: now)
        history = model.historyRevision
        hidden = settings.profileHiddenWords
        parts = settings.profileCards.parts
        brain = settings.profileCards.brain
        typingWPM = settings.typingWPM
    }

    /// Un calcul fait pour cette demande vaut pour `other` : mêmes entrées, et au moins ses cartes.
    func covers(_ other: ProfileRequest) -> Bool {
        period == other.period && day == other.day && history == other.history && hidden == other.hidden
            && typingWPM == other.typingWPM && parts.isSuperset(of: other.parts) && (brain || !other.brain)
    }
}

/// Le Profil calculé : chiffres et cartes, cerveau si sa carte est affichée.
struct ProfileSnapshot: Sendable {
    var request: ProfileRequest
    var profile: DictationProfile
    var savedSeconds: Double
    var graph: WordGraph?

    /// Calcul complet, hors du fil principal : seulement les cartes demandées, chaque dictée découpée une fois.
    static func compute(_ request: ProfileRequest, records: [DictationRecord], now: Date = Date()) -> ProfileSnapshot {
        let result = ProfileBuilder.analyze(records: records, hidden: Set(request.hidden), parts: request.parts,
                                            graph: request.brain, now: now)
        let samples = records.map {
            DictationSample(createdAt: $0.createdAt, wordCount: $0.wordCount, durationSeconds: $0.durationSeconds,
                            usageCategory: $0.usageCategory)
        }
        let summary = StatsCalculator.summary(samples: samples, typingWordsPerMinute: request.typingWPM)
        return ProfileSnapshot(request: request, profile: result.profile, savedSeconds: summary.savedSeconds, graph: result.graph)
    }

    /// La carte a été calculée : la montrer ne ferait pas voir un chiffre vide.
    func has(_ card: ProfileCard) -> Bool {
        card.part.map { request.parts.contains($0) } ?? (graph != nil)
    }
}

/// Ce dont dépendent les sujets affichés : l'historique, l'analyse gardée, le modèle de correction et le portrait.
struct TopicsRequest: Equatable, Sendable {
    var history: Int
    var analysis: TopicAnalysis?
    var model: String?
    var portrait: Bool
}

/// Sujets prêts à afficher : leur cerveau et les coûts estimés des analyses possibles.
struct TopicsSnapshot: Sendable {
    var request: TopicsRequest
    /// Cerveau par sujets, sans les dictées supprimées depuis l'analyse ; vide sans analyse.
    var graph: WordGraph
    var dictations: Int
    /// Analyse de tout l'historique (première analyse ou « Tout relire »), portrait compris s'il est demandé.
    var launch: TopicEstimate
    /// Une semaine type : les dictées des 4 dernières semaines divisées par 4.
    var weekly: TopicEstimate
    /// Dictées arrivées depuis l'analyse, et le coût de leur lecture.
    var fresh: Int
    var update: TopicEstimate

    static func compute(_ request: TopicsRequest, sources: [TopicSource]) -> TopicsSnapshot {
        let existing = Set(sources.map(\.id))
        let fresh = request.analysis?.newSources(in: sources) ?? []
        return TopicsSnapshot(
            request: request,
            graph: request.analysis.map { WordGraph.topics($0.pruned(keeping: existing)) } ?? .empty,
            dictations: sources.count,
            launch: TopicAnalyzer.estimate(sources, model: request.model, portrait: request.portrait),
            weekly: TopicAnalyzer.weeklyEstimate(sources, model: request.model, portrait: request.portrait),
            fresh: fresh.count,
            update: TopicAnalyzer.estimate(fresh, model: request.model, portrait: request.portrait)
        )
    }
}

/// Calculs du Profil, hors du fil principal et gardés en mémoire. Rouvrir le Profil montre aussitôt le dernier
/// calcul ; une nouvelle dictée, une autre période ou une carte rallumée le refont en arrière-plan, et l'écran garde
/// l'ancien jusque-là. Une carte masquée n'est pas calculée. Les sujets (leur cerveau et les coûts estimés) suivent le
/// même chemin. Rien n'est écrit sur le disque.
@MainActor
@Observable
final class ProfileLoader {
    static let shared = ProfileLoader()

    private(set) var snapshot: ProfileSnapshot?
    private(set) var topics: TopicsSnapshot?
    @ObservationIgnored private var pending: ProfileRequest?
    @ObservationIgnored private var pendingTopics: TopicsRequest?
    /// Calculs en cours (exposés pour les tests).
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private(set) var topicsTask: Task<Void, Never>?

    /// Demande le Profil pour ces entrées : déjà calculé, rien à faire ; sinon un calcul en arrière-plan.
    func load(_ request: ProfileRequest, model: AppModel) {
        if let snapshot, snapshot.request.covers(request) {
            // Un calcul lancé pour une autre demande (période changée puis remise) ne doit pas remplacer celui-ci.
            task?.cancel()
            task = nil
            pending = nil
            return
        }
        guard pending != request else { return }
        task?.cancel()
        pending = request
        let records = model.records(in: request.period)
        task = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                ProfileSnapshot.compute(request, records: records)
            }.value
            guard let self, !Task.isCancelled, self.pending == request else { return }
            self.snapshot = computed
            self.pending = nil
            self.task = nil
        }
    }

    /// Profil préparé à l'ouverture de la fenêtre : le premier passage dans Profil le trouve déjà calculé.
    func prepare(_ model: AppModel) {
        load(ProfileRequest(model: model), model: model)
    }

    /// Demande les sujets (cerveau et coûts) pour ces entrées ; calculés en arrière-plan s'ils ont changé.
    func loadTopics(_ request: TopicsRequest, model: AppModel) {
        if topics?.request == request {
            topicsTask?.cancel()
            topicsTask = nil
            pendingTopics = nil
            return
        }
        guard pendingTopics != request else { return }
        topicsTask?.cancel()
        pendingTopics = request
        let sources = model.history.map(TopicSource.init)
        topicsTask = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                TopicsSnapshot.compute(request, sources: sources)
            }.value
            guard let self, !Task.isCancelled, self.pendingTopics == request else { return }
            self.topics = computed
            self.pendingTopics = nil
            self.topicsTask = nil
        }
    }
}
