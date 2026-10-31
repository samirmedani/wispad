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
    /// Cerveau masqué : rien n'est relu, une carte qu'on ne voit pas ne coûte rien.
    func runIfDue(model: AppModel, now: Date = Date()) {
        let settings = model.settings
        guard settings.profileCards.brain, settings.profileTopicsEnabled, settings.profileTopicsWeekly, !isRunning, let analysis,
              canAttemptAutomatically(at: now), model.dependencies.isOnline(),
              TextCleaner.services(model.speechRequest(context: nil)).first != nil else { return }
        let sources = model.history.map(TopicSource.init)
        guard analysis.isDueForWeeklyUpdate(sources: sources, now: now) else { return }
        start(model: model, portrait: settings.profilePortraitEnabled, stats: Self.stats(for: model), full: false, now: now)
    }

    /// Chiffres donnés au portrait : seules les parties du profil qu'il cite sont calculées.
    static func stats(for model: AppModel) -> String {
        let profile = ProfileBuilder.build(records: model.history, parts: [.rhythm, .languages])
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

    /// « Sujets · IA » allumé ou coupé (Profil › Personnaliser). Coupé : le portrait et la mise à jour de chaque
    /// semaine le sont aussi, et le résultat gardé est effacé.
    func setEnabled(_ on: Bool, model: AppModel) {
        model.settings.profileTopicsEnabled = on
        if !on {
            model.settings.profilePortraitEnabled = false
            model.settings.profileTopicsWeekly = false
            forget()
        }
        model.saveSettings()
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

/// Le cerveau du Profil : par mots (sur ce Mac, gratuit) ou, avec « Sujets · IA », par sujets (une IA relit
/// l'historique, à la demande). Le cerveau des sujets et les coûts estimés sont calculés hors du fil principal
/// (`ProfileLoader`).
struct BrainSection: View {
    @Environment(AppModel.self) private var model
    var wordGraph: WordGraph
    @Binding var selected: Int?
    var hide: (String) -> Void

    @State private var mode: Mode = .words
    private var controller: ProfileTopicsController { .shared }
    private var loader: ProfileLoader { .shared }

    enum Mode: Hashable {
        case words
        case topics
    }

    #if DEBUG
    /// Aperçus : onglet ouvert d'emblée.
    static var previewMode: Mode?
    #endif

    var body: some View {
        let topicsOn = model.settings.profileTopicsEnabled
        let showsTopics = topicsOn && mode == .topics
        let analysis = controller.analysis
        let service = topicsOn ? TextCleaner.services(model.speechRequest(context: nil)).first : nil
        let request = topicsOn ? TopicsRequest(history: model.historyRevision, analysis: analysis, model: service?.model,
                                               portrait: model.settings.profilePortraitEnabled) : nil
        let topics = loader.topics
        // Sujets analysés mais leur cerveau pas encore dessiné (premier passage) : une attente, plutôt que « pas assez ».
        let drawing = analysis != nil && topics?.request.analysis != analysis
        BrainCard(
            graph: showsTopics ? (analysis == nil ? .empty : topics?.graph ?? .empty) : wordGraph,
            selected: $selected,
            hide: showsTopics ? nil : hide,
            caption: !showsTopics
                ? String(localized: "Tes mots les plus fréquents, reliés quand tu les dis ensemble. Une couleur par famille.")
                : analysis == nil ? nil : String(localized: "Tes grands sujets, trouvés par l'IA dans tes dictées."),
            emptyText: showsTopics
                ? String(localized: "Pas encore assez de sujets pour dessiner ton cerveau.")
                : String(localized: "Encore quelques dictées et ton cerveau prendra forme."),
            modePicker: topicsOn ? AnyView(picker) : nil,
            placeholder: !showsTopics ? nil
                : analysis == nil ? AnyView(TopicsIntro(topics: topics, service: service))
                : drawing ? AnyView(ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)) : nil,
            footer: showsTopics && analysis != nil ? AnyView(TopicsResult(topics: topics, service: service)) : nil,
            openHistory: { filter in
                model.historyFilter = filter
                model.selectedSection = .history
            }
        )
        .task(id: request) {
            if let request { loader.loadTopics(request, model: model) }
        }
        .onChange(of: analysis) { selected = nil }
        // « Sujets · IA » allumé dans Personnaliser : son onglet s'ouvre ; coupé, retour aux mots.
        .onChange(of: topicsOn) { _, on in
            mode = on ? .topics : .words
            selected = nil
        }
        .onAppear {
            if topicsOn, analysis != nil { mode = .topics }
            #if DEBUG
            if let preview = Self.previewMode { mode = preview }
            #endif
        }
    }

    private var picker: some View {
        Picker(String(localized: "Cerveau"), selection: Binding(get: { mode }, set: { mode = $0; selected = nil })) {
            Text("Mots").tag(Mode.words)
            Text("Sujets · IA").tag(Mode.topics)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Les sujets avant la première analyse : une image, ce qui sera relu et par qui, puis le lancement avec son coût.
/// Rien n'est envoyé avant le clic.
private struct TopicsIntro: View {
    @Environment(AppModel.self) private var model
    var topics: TopicsSnapshot?
    var service: CleanupService?
    private var controller: ProfileTopicsController { .shared }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            Image("ProfileTopicsIllustration")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tes dictées, rangées par sujets")
                        .font(.system(size: 17, weight: .semibold))
                    Text("L'IA lit ton historique et trouve tes grands thèmes.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    let count = topics?.dictations ?? model.history.count
                    TopicChip(symbol: "text.bubble",
                              text: count == 1 ? String(localized: "1 dictée") : String(localized: "\(count) dictées"))
                    if let service {
                        ProviderBadge(provider: service.provider)
                            .help(service.label)
                    }
                }
                action
                if service != nil, controller.analysis == nil {
                    TopicsOptions(topics: topics, service: service)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var action: some View {
        if case .running(let done, let total) = controller.state {
            TopicsProgress(done: done, total: total)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let message) = controller.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let service {
                    let launch = topics?.launch
                    Button {
                        controller.start(model: model, portrait: model.settings.profilePortraitEnabled,
                                         stats: ProfileTopicsController.stats(for: model), full: true)
                    } label: {
                        Label(launch.map { String(localized: "Lancer l'analyse · \(TopicCost.text($0, service: service, short: true))") }
                              ?? String(localized: "Lancer l'analyse"),
                              systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(launch == nil || topics?.dictations == 0)
                    .help(launch.map { TopicCost.text($0, service: service) } ?? "")
                } else {
                    NoCorrectionKey()
                }
            }
        }
    }
}

/// Les sujets après une analyse, sous leur cerveau : portrait, date, dictées relues, coût réel, puis la mise à jour et
/// les options.
private struct TopicsResult: View {
    @Environment(AppModel.self) private var model
    var topics: TopicsSnapshot?
    var service: CleanupService?
    private var controller: ProfileTopicsController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let message) = controller.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let analysis = controller.analysis {
                if let text = analysis.portrait, model.settings.profilePortraitEnabled {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                        Text(text)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.brand.opacity(0.08)))
                }
                HStack(spacing: 6) {
                    TopicChip(symbol: "calendar", text: analysis.analyzedAt.formatted(.dateTime.day().month(.abbreviated).locale(appLocale)))
                        .help(String(localized: "Analysé le \(analysis.analyzedAt.formatted(.dateTime.day().month(.wide).hour().minute().locale(appLocale)))"))
                    TopicChip(symbol: "text.bubble",
                              text: analysis.dictationCount == 1 ? String(localized: "1 dictée") : String(localized: "\(analysis.dictationCount) dictées"))
                    TopicChip(symbol: "dollarsign.circle",
                              text: analysis.costUSD.map { MoneyFormat.price(max($0, 0.0001)) } ?? String(localized: "coût inconnu"))
                        .help(analysis.service)
                }
            }
            FlowLayout(spacing: 8) {
                HStack(spacing: 10) { actions }
                if service != nil {
                    TopicsOptions(topics: topics, service: service)
                }
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var actions: some View {
        if case .running(let done, let total) = controller.state {
            TopicsProgress(done: done, total: total)
        } else if let service {
            let fresh = topics?.fresh ?? 0
            Button {
                launch(full: false)
            } label: {
                Label(fresh == 0 ? String(localized: "À jour")
                      : String(localized: "Mettre à jour · \(fresh) nouvelles dictées · \(topics.map { TopicCost.text($0.update, service: service, short: true) } ?? "…")"),
                      systemImage: fresh == 0 ? "checkmark" : "sparkles")
            }
            .disabled(fresh == 0)
            if let launch = topics?.launch {
                Button {
                    self.launch(full: true)
                } label: {
                    Text("Tout relire · \(TopicCost.text(launch, service: service, short: true))")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Relit tout l'historique, par exemple après avoir changé de modèle de correction."))
            }
        } else {
            NoCorrectionKey()
        }
    }

    private func launch(full: Bool) {
        controller.start(model: model, portrait: model.settings.profilePortraitEnabled,
                         stats: ProfileTopicsController.stats(for: model), full: full)
    }
}

/// Portrait écrit et mise à jour de chaque semaine, en pastilles avec leur coût.
private struct TopicsOptions: View {
    @Environment(AppModel.self) private var model
    var topics: TopicsSnapshot?
    var service: CleanupService?

    var body: some View {
        let portrait = TopicEstimate(batches: 0, tokens: TopicAnalyzer.portraitTokens,
                                     costUSD: service.flatMap { Pricing.tokenCost(model: $0.model, tokens: TopicAnalyzer.portraitTokens, at: Date()) })
        HStack(spacing: 6) {
            Toggle(String(localized: "Portrait"), isOn: Binding(get: { model.settings.profilePortraitEnabled }, set: {
                model.settings.profilePortraitEnabled = $0
                model.saveSettings()
            }))
            .toggleStyle(ChipToggleStyle(symbol: "text.quote", detail: TopicCost.text(portrait, service: service, short: true)))
            .help(String(localized: "Trois phrases sur ce qui t'occupe, d'après tes sujets et tes chiffres, à chaque analyse."))
            Toggle(String(localized: "Chaque semaine"), isOn: Binding(get: { model.settings.profileTopicsWeekly }, set: {
                model.settings.profileTopicsWeekly = $0
                model.saveSettings()
            }))
            .toggleStyle(ChipToggleStyle(symbol: "arrow.triangle.2.circlepath",
                                         detail: topics.map { TopicCost.text($0.weekly, service: service, short: true) }))
            .help(String(localized: "Une fois par semaine, seules les nouvelles dictées sont relues, sans rien te demander."))
        }
    }
}

private struct TopicsProgress: View {
    var done: Int
    var total: Int
    private var controller: ProfileTopicsController { .shared }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(width: 160)
            Text("Lot \(done) sur \(total)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(String(localized: "Arrêter")) { controller.cancel() }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 12))
    }
}

/// Sans clé de correction active, pas d'analyse : le lien mène à Fournisseurs.
private struct NoCorrectionKey: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Label(String(localized: "Aucune clé de correction active"), systemImage: "key.fill")
                .foregroundStyle(.orange)
            Button(String(localized: "Fournisseurs")) { model.selectedSection = .providers }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 12))
    }
}

/// Repère en pastille : une icône et un texte court.
private struct TopicChip: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text).monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.subtleFill))
    }
}

/// Option en pastille : allumée, elle est cochée et teintée ; son coût suit son nom.
private struct ChipToggleStyle: ToggleStyle {
    var symbol: String
    var detail: String?

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : symbol)
                    .foregroundStyle(configuration.isOn ? Theme.brand : Color.secondary)
                configuration.label
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(configuration.isOn ? Theme.brand.opacity(0.12) : Theme.subtleFill))
            .contentShape(Capsule())
        }
        .buttonStyle(HoverButtonStyle())
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? Text("Activé") : Text("Désactivé"))
    }
}

/// Coût d'une analyse en clair : court (« ≈ 0,05 $ », « gratuit ») sur les boutons, détaillé (jetons, service) en
/// bulle d'aide.
private enum TopicCost {
    static func text(_ estimate: TopicEstimate, service: CleanupService?, short: Bool = false) -> String {
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
}
