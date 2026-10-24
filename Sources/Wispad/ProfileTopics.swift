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

    private let defaults: UserDefaults
    private static let storageKey = "profileTopicAnalysis.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            analysis = try? JSONDecoder().decode(TopicAnalysis.self, from: data)
        }
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Relit tout l'historique avec le premier service de correction, enregistre les appels dans la consommation,
    /// puis garde le résultat.
    func start(model: AppModel, portrait: Bool, stats: String) {
        guard !isRunning else { return }
        let sources = model.history.map(TopicSource.init)
        let speech = model.speechRequest(context: nil)
        state = .running(done: 0, total: max(1, TopicAnalyzer.batches(sources).count))
        task = Task { [weak self] in
            do {
                let result = try await TopicAnalyzer.run(sources: sources, speech: speech, portrait: portrait, stats: stats) { done, total in
                    await MainActor.run { self?.state = .running(done: done, total: total) }
                }
                for event in result.usage { model.recordUsage(event) }
                guard let self else { return }
                self.analysis = result.analysis
                if let data = try? JSONEncoder().encode(result.analysis) { self.defaults.set(data, forKey: Self.storageKey) }
                self.state = .idle
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(String(localized: "L'analyse n'a pas abouti : le service de correction n'a pas répondu. Réessaie plus tard."))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
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
        let topicGraph = controller.analysis.map(WordGraph.topics) ?? .empty
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
            accessory: showsTopics ? AnyView(TopicsControls(profile: profile)) : nil
        )
        .onChange(of: controller.analysis) { selected = nil }
        .onAppear {
            if model.settings.profileTopicsEnabled, controller.analysis != nil { mode = .topics }
        }
    }
}

/// Réglages et état de l'analyse par sujets : interrupteurs, coût estimé, lancement, progression, résultat.
private struct TopicsControls: View {
    @Environment(AppModel.self) private var model
    var profile: DictationProfile
    private var controller: ProfileTopicsController { .shared }

    var body: some View {
        let speech = model.speechRequest(context: nil)
        let service = TextCleaner.services(speech).first
        let sources = model.history.map(TopicSource.init)
        let topics = TopicAnalyzer.estimate(sources, model: service?.model, portrait: false)
        let withPortrait = TopicAnalyzer.estimate(sources, model: service?.model, portrait: true)
        VStack(alignment: .leading, spacing: 10) {
            option(title: String(localized: "Analyser mes sujets avec l'IA"),
                   detail: String(localized: "Une IA relit tout ton historique (\(sources.count) dictées) pour en tirer tes sujets et tes catégories. Elle utilise ta clé de correction : \(cost(topics, service: service))."),
                   isOn: Binding(get: { model.settings.profileTopicsEnabled }, set: { on in
                       model.settings.profileTopicsEnabled = on
                       if !on { model.settings.profilePortraitEnabled = false; controller.forget() }
                       model.saveSettings()
                   }))
            if model.settings.profileTopicsEnabled {
                option(title: String(localized: "Écrire mon portrait"),
                       detail: String(localized: "Trois phrases sur ce qui t'occupe, d'après tes sujets et tes chiffres : \(cost(TopicEstimate(batches: 1, tokens: TokenUsage(input: 1_400, cachedInput: 0, output: 260), costUSD: diff(withPortrait, topics)), service: service)) de plus."),
                       isOn: Binding(get: { model.settings.profilePortraitEnabled }, set: {
                           model.settings.profilePortraitEnabled = $0
                           model.saveSettings()
                       }))
                status(service: service, estimate: model.settings.profilePortraitEnabled ? withPortrait : topics)
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
    private func status(service: CleanupService?, estimate: TopicEstimate) -> some View {
        let price = cost(estimate, service: service)
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
                if let analysis = controller.analysis {
                    let fresh = model.history.filter { $0.createdAt > (analysis.newestDictation ?? .distantPast) }.count
                    Text(summary(analysis, fresh: fresh)).foregroundStyle(.secondary)
                    if let portrait = analysis.portrait, model.settings.profilePortraitEnabled {
                        Text(portrait)
                            .font(.system(size: 13))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.brand.opacity(0.08)))
                            .textSelection(.enabled)
                    }
                }
                if service == nil {
                    Text("Aucune clé de correction active : ajoute-en une dans Fournisseurs.").foregroundStyle(.orange)
                } else {
                    Button {
                        controller.start(model: model, portrait: model.settings.profilePortraitEnabled, stats: stats)
                    } label: {
                        Label(controller.analysis == nil ? String(localized: "Lancer l'analyse · \(price)")
                              : String(localized: "Relancer l'analyse · \(price)"), systemImage: "sparkles")
                    }
                    .disabled(model.history.isEmpty)
                }
            }
        }
    }

    private func cost(_ estimate: TopicEstimate, service: CleanupService?) -> String {
        let tokens = (estimate.tokens.input + estimate.tokens.output).formatted(.number.notation(.compactName).locale(appLocale))
        guard let service else { return String(localized: "environ \(tokens) jetons") }
        if let usd = estimate.costUSD {
            return String(localized: "environ \(tokens) jetons, ≈ \(MoneyFormat.price(max(usd, 0.0001))) avec \(service.label)")
        }
        return String(localized: "environ \(tokens) jetons avec \(service.label), prix inconnu")
    }

    private func diff(_ a: TopicEstimate, _ b: TopicEstimate) -> Double? {
        guard let x = a.costUSD, let y = b.costUSD else { return nil }
        return max(0, x - y)
    }

    private func summary(_ analysis: TopicAnalysis, fresh: Int) -> String {
        let date = analysis.analyzedAt.formatted(.dateTime.day().month(.wide).hour().minute().locale(appLocale))
        let spent = analysis.costUSD.map { MoneyFormat.price(max($0, 0.0001)) } ?? String(localized: "coût inconnu")
        let base = String(localized: "Analysé le \(date) · \(analysis.dictationCount) dictées · \(analysis.service) · \(spent)")
        return fresh > 0 ? base + " · " + String(localized: "\(fresh) nouvelles dictées depuis") : base
    }

    private var stats: String {
        let peak = profile.byHour.indices.max { profile.byHour[$0] < profile.byHour[$1] } ?? 0
        return "\(profile.words) mots dictés en \(profile.dictations) dictées, \(profile.activeDays) jours actifs, pic vers \(peak) h, \(profile.englishDictations) dictées surtout en anglais."
    }
}
