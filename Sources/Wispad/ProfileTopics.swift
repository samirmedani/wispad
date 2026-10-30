import Foundation
import SwiftUI
import WispadCore

/// Analyse par sujets du Profil : l'état d'une relecture lancée à la main, et son dernier résultat, gardé sur ce Mac.
@MainActor
@Observable
final class ProfileTopicsController {
    static let shared = ProfileTopicsController()

    enum State: Equatable {
        case idle
        case running(done: Int, total: Int)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var analysis: TopicAnalysis?
    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var cancelRequested = false
    private var retry: RetryState

    typealias Analyze = @Sendable (
        [TopicSource], SpeechRequest, Bool, String, TopicAnalysis?,
        @escaping @Sendable (UsageEvent) async -> Void,
        @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> TopicAnalysis

    private let analyze: Analyze
    private let defaults: UserDefaults
    private static let storageKey = "profileTopicAnalysis.v1"
    private static let retryKey = "profileTopicRetry.v1"

    /// Persisté avant l'envoi : un arrêt du processus ou une annulation ne relance pas l'analyse au prochain réveil.
    private struct RetryState: Codable {
        var attempts = 0
        var nextAutomaticAttempt: Date?

        mutating func begin(at now: Date) {
            attempts = min(max(attempts, 0), 2) + 1
            let waits: [TimeInterval] = [6 * 3_600, 24 * 3_600, 7 * 86_400]
            nextAutomaticAttempt = now.addingTimeInterval(waits[attempts - 1])
        }
    }

    init(defaults: UserDefaults = .standard, analyze: @escaping Analyze = { sources, speech, portrait, stats, previous, onUsage, progress in
        try await TopicAnalyzer.run(sources: sources, speech: speech, portrait: portrait, stats: stats,
                                    previous: previous, onUsage: onUsage, progress: progress).analysis
    }) {
        self.defaults = defaults
        self.analyze = analyze
        retry = defaults.data(forKey: Self.retryKey).flatMap { try? JSONDecoder().decode(RetryState.self, from: $0) } ?? RetryState()
        if let data = defaults.data(forKey: Self.storageKey) {
            analysis = try? JSONDecoder().decode(TopicAnalysis.self, from: data)
        }
    }

    var isRunning: Bool { task != nil }

    private func saveRetry() {
        if let data = try? JSONEncoder().encode(retry) { defaults.set(data, forKey: Self.retryKey) }
    }

    func canAttemptAutomatically(at now: Date) -> Bool {
        retry.nextAutomaticAttempt.map { now >= $0 } ?? true
    }

    /// Relit l'historique avec le premier service de correction : tout (« full »), ou seulement les dictées arrivées
    /// depuis la dernière analyse. Les appels comptent dans la consommation, puis le résultat est gardé.
    func start(model: AppModel, portrait: Bool, stats: String, full: Bool, now: Date = Date()) {
        guard !isRunning else { return }
        let sources = model.history.map(TopicSource.init)
        let speech = model.speechRequest(context: nil)
        let previous = full ? nil : analysis?.pruned(keeping: Set(sources.map(\.id)))
        let read = previous?.newSources(in: sources) ?? sources
        let id = UUID()
        runID = id
        cancelRequested = false
        retry.begin(at: now)
        saveRetry()
        state = .running(done: 0, total: max(1, TopicAnalyzer.batches(read).count))
        let analyze = self.analyze
        task = Task { [weak self] in
            defer {
                if let self, self.runID == id {
                    self.task = nil
                    self.runID = nil
                }
            }
            do {
                let result = try await analyze(sources, speech, portrait, stats, previous, { event in
                    // Compté même si l'utilisateur a annulé ou effacé le résultat pendant l'appel.
                    await MainActor.run { model.recordUsage(event) }
                }, { [weak self] done, total in
                    await MainActor.run {
                        guard let self, self.runID == id, !self.cancelRequested else { return }
                        self.state = .running(done: done, total: total)
                    }
                })
                guard let self, self.runID == id else { return }
                guard !Task.isCancelled, !self.cancelRequested else { self.state = .idle; return }
                self.analysis = result
                if let data = try? JSONEncoder().encode(result) { self.defaults.set(data, forKey: Self.storageKey) }
                self.retry = RetryState()
                self.saveRetry()
                self.state = .idle
            } catch {
                guard let self, self.runID == id else { return }
                if Task.isCancelled || self.cancelRequested || error is CancellationError { self.state = .idle }
                else { self.state = .failed(String(localized: "L'analyse n'a pas abouti : le service de correction n'a pas répondu. Réessaie plus tard.")) }
            }
        }
    }

    /// Mise à jour hebdomadaire : après une tentative interrompue ou ratée, attendre 6 h, 24 h puis 7 jours.
    /// Le lancement manuel reste possible ; les tentatives et leur échéance survivent à une relance de l'app.
    func runIfDue(model: AppModel, now: Date = Date()) {
        let settings = model.settings
        guard settings.profileTopicsEnabled, settings.profileTopicsWeekly, !isRunning, let analysis,
              canAttemptAutomatically(at: now), model.dependencies.isOnline(),
              TextCleaner.services(model.speechRequest(context: nil)).first != nil else { return }
        let sources = model.history.map(TopicSource.init)
        guard analysis.isDueForWeeklyUpdate(sources: sources, now: now) else { return }
        start(model: model, portrait: settings.profilePortraitEnabled, stats: Self.stats(for: model), full: false, now: now)
    }

    /// Chiffres donnés au portrait.
    static func stats(for model: AppModel) -> String {
        let profile = ProfileBuilder.build(records: model.history)
        let peak = profile.byHour.indices.max { profile.byHour[$0] < profile.byHour[$1] } ?? 0
        return "\(profile.words) mots dictés en \(profile.dictations) dictées, \(profile.activeDays) jours actifs, pic vers \(peak) h, \(profile.englishDictations) dictées surtout en anglais."
    }

    func cancel() {
        cancelRequested = true
        task?.cancel()
        // La tâche conserve son créneau jusqu'à la fin des requêtes : aucun chevauchement, même si le
        // transport met un instant à terminer son annulation. Ses derniers usages restent comptés.
        if task == nil { state = .idle }
    }

    #if DEBUG
    /// Aperçus : un résultat fictif, sans appel.
    func inject(_ analysis: TopicAnalysis) {
        self.analysis = analysis
    }
    #endif

    /// Efface le résultat gardé (interrupteur coupé).
    func forget() {
        cancel()
        analysis = nil
        defaults.removeObject(forKey: Self.storageKey)
    }
}

/// Le cerveau du Profil : par mots (sur ce Mac, gratuit) ou par sujets (une IA relit l'historique, sur demande).
struct BrainSection: View {
    @Environment(AppModel.self) private var model
    var wordGraph: WordGraph
    var profile: DictationProfile
    @Binding var selected: Int?
    var hide: (String) -> Void

    @State private var mode: Mode = .words
    private var controller: ProfileTopicsController { .shared }

    enum Mode: Hashable {
        case words
        case topics
    }

    var body: some View {
        let existing = Set(model.history.map(\.id))
        let topicGraph = controller.analysis.map { WordGraph.topics($0.pruned(keeping: existing)) } ?? .empty
        let showsTopics = mode == .topics
        BrainCard(
            graph: showsTopics ? (model.settings.profileTopicsEnabled ? topicGraph : .empty) : wordGraph,
            selected: $selected,
            hide: showsTopics ? nil : hide,
            caption: showsTopics
                ? String(localized: "Tes sujets, lus par une IA dans tout ton historique et rangés en grandes catégories. Un sujet est relié à sa catégorie, et à un autre quand tu en parles dans les mêmes dictées.")
                : String(localized: "Tes mots les plus fréquents, reliés quand tu les dis dans les mêmes dictées. Chaque couleur est une famille de sujets."),
            emptyText: showsTopics
                ? String(localized: "Lance l'analyse pour voir tes sujets.")
                : String(localized: "Encore quelques dictées et ton cerveau prendra forme."),
            modePicker: AnyView(
                Picker(String(localized: "Cerveau"), selection: Binding(get: { mode }, set: { mode = $0; selected = nil })) {
                    Text("Mots").tag(Mode.words)
                    Text("Sujets · IA").tag(Mode.topics)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            ),
            accessory: showsTopics ? AnyView(TopicsControls(profile: profile)) : nil,
            openHistory: { filter in
                model.historyFilter = filter
                model.selectedSection = .history
            }
        )
        .onChange(of: controller.analysis) { selected = nil }
        .onAppear {
            if model.settings.profileTopicsEnabled, controller.analysis != nil { mode = .topics }
        }
    }
}

/// Réglages et état de l'analyse par sujets : interrupteurs, coûts estimés, lancement, progression, résultat.
private struct TopicsControls: View {
    @Environment(AppModel.self) private var model
    var profile: DictationProfile
    private var controller: ProfileTopicsController { .shared }

    var body: some View {
        let speech = model.speechRequest(context: nil)
        let service = TextCleaner.services(speech).first
        let sources = model.history.map(TopicSource.init)
        let portrait = model.settings.profilePortraitEnabled
        let everything = TopicAnalyzer.estimate(sources, model: service?.model, portrait: false)
        let portraitOnly = TopicEstimate(batches: 0, tokens: TopicAnalyzer.portraitTokens,
                                         costUSD: service.flatMap { Pricing.tokenCost(model: $0.model, tokens: TopicAnalyzer.portraitTokens, at: Date()) })
        let weekly = TopicAnalyzer.weeklyEstimate(sources, model: service?.model, portrait: portrait)
        VStack(alignment: .leading, spacing: 10) {
            option(title: String(localized: "Analyser mes sujets avec l'IA"),
                   detail: String(localized: "Une IA relit tout ton historique (\(sources.count) dictées) pour en tirer tes sujets et tes catégories. Elle utilise ta clé de correction : \(cost(everything, service: service))."),
                   isOn: Binding(get: { model.settings.profileTopicsEnabled }, set: { on in
                       model.settings.profileTopicsEnabled = on
                       if !on {
                           model.settings.profilePortraitEnabled = false
                           model.settings.profileTopicsWeekly = false
                           controller.forget()
                       }
                       model.saveSettings()
                   }))
            if model.settings.profileTopicsEnabled {
                option(title: String(localized: "Écrire mon portrait"),
                       detail: String(localized: "Trois phrases sur ce qui t'occupe, d'après tes sujets et tes chiffres : \(cost(portraitOnly, service: service)) de plus à chaque analyse."),
                       isOn: Binding(get: { model.settings.profilePortraitEnabled }, set: {
                           model.settings.profilePortraitEnabled = $0
                           model.saveSettings()
                       }))
                option(title: String(localized: "Mettre à jour chaque semaine"),
                       detail: String(localized: "Une fois par semaine, seules les nouvelles dictées sont relues, sans rien te demander. À ton rythme actuel : \(cost(weekly, service: service)) par semaine."),
                       isOn: Binding(get: { model.settings.profileTopicsWeekly }, set: {
                           model.settings.profileTopicsWeekly = $0
                           model.saveSettings()
                       }))
                status(service: service, sources: sources, portrait: portrait, everything: everything)
            }
        }
        .font(.system(size: 12))
    }

    private func option(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }

    @ViewBuilder
    private func status(service: CleanupService?, sources: [TopicSource], portrait: Bool, everything: TopicEstimate) -> some View {
        switch controller.state {
        case .running(let done, let total):
            HStack(spacing: 10) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 160)
                Text("Lot \(done) sur \(total)").monospacedDigit().foregroundStyle(.secondary)
                Button(String(localized: "Arrêter")) { controller.cancel() }.buttonStyle(.borderless)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                if case .failed(let message) = controller.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                let fresh = controller.analysis?.newSources(in: sources) ?? []
                if let analysis = controller.analysis {
                    Text(summary(analysis, fresh: fresh.count)).foregroundStyle(.secondary)
                    if let text = analysis.portrait, portrait {
                        Text(text)
                            .font(.system(size: 13))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.brand.opacity(0.08)))
                            .textSelection(.enabled)
                    }
                }
                if service == nil {
                    Text("Aucune clé de correction active : ajoute-en une dans Fournisseurs.").foregroundStyle(.orange)
                } else if controller.analysis == nil {
                    let price = cost(TopicAnalyzer.estimate(sources, model: service?.model, portrait: portrait), service: service)
                    Button { launch(full: true) } label: {
                        Label(String(localized: "Lancer l'analyse · \(price)"), systemImage: "sparkles")
                    }
                    .disabled(sources.isEmpty)
                } else {
                    HStack(spacing: 10) {
                        let update = TopicAnalyzer.estimate(fresh, model: service?.model, portrait: portrait)
                        Button { launch(full: false) } label: {
                            Label(fresh.isEmpty ? String(localized: "À jour")
                                  : String(localized: "Mettre à jour · \(fresh.count) nouvelles dictées · \(cost(update, service: service, short: true))"),
                                  systemImage: fresh.isEmpty ? "checkmark" : "sparkles")
                        }
                        .disabled(fresh.isEmpty)
                        Button { launch(full: true) } label: {
                            Text("Tout relire · \(cost(TopicEstimate(batches: everything.batches, tokens: everything.tokens, costUSD: everything.costUSD), service: service, short: true))")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Relit tout l'historique, par exemple après avoir changé de modèle de correction."))
                    }
                }
            }
        }
    }

    private func launch(full: Bool) {
        controller.start(model: model, portrait: model.settings.profilePortraitEnabled,
                         stats: ProfileTopicsController.stats(for: model), full: full)
    }

    private func cost(_ estimate: TopicEstimate, service: CleanupService?, short: Bool = false) -> String {
        let tokens = (estimate.tokens.input + estimate.tokens.output).formatted(.number.notation(.compactName).locale(appLocale))
        let price: String? = estimate.costUSD.map { usd in
            // Sous 0,001 $, « ≈ 0,00 $ » ferait croire à un appel gratuit.
            usd < 0.001 ? "< " + MoneyFormat.price(0.001) : "≈ " + MoneyFormat.price(usd)
        }
        if service?.provider == CleanupChoice.providerName(account: CleanupModel.localAccount) {
            return short ? String(localized: "gratuit") : String(localized: "environ \(tokens) jetons, gratuit avec ton modèle local \(service?.model ?? "")")
        }
        if short { return price ?? String(localized: "environ \(tokens) jetons") }
        guard let service else { return String(localized: "environ \(tokens) jetons") }
        if let price { return String(localized: "environ \(tokens) jetons, \(price) avec \(service.label)") }
        return String(localized: "environ \(tokens) jetons avec \(service.label), prix inconnu")
    }

    private func summary(_ analysis: TopicAnalysis, fresh: Int) -> String {
        let date = analysis.analyzedAt.formatted(.dateTime.day().month(.wide).hour().minute().locale(appLocale))
        let spent = analysis.costUSD.map { MoneyFormat.price(max($0, 0.0001)) } ?? String(localized: "coût inconnu")
        let base = String(localized: "Analysé le \(date) · \(analysis.dictationCount) dictées · \(analysis.service) · \(spent)")
        return fresh > 0 ? base + " · " + String(localized: "\(fresh) nouvelles dictées depuis") : base
    }
}
