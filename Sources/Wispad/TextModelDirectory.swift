import Foundation
import SwiftUI
import WispadCore

/// Modèles de texte de chaque clé active, lus chez le fournisseur (« /models ») et gardés sur ce Mac un jour.
/// Sans liste lue (pas de réseau, clé refusée), les modèles d'origine restent proposés.
@MainActor
@Observable
final class TextModelDirectory {
    static let shared = TextModelDirectory()

    /// Liste lue d'un compte et son heure de lecture.
    struct Listing: Codable, Equatable {
        var identifiers: [String]
        var loadedAt: Date
    }

    private(set) var listings: [String: Listing] = [:]
    /// Comptes dont la lecture est en cours.
    private(set) var loading: Set<String> = []

    /// Lecture de la liste d'un compte ; remplaçable dans les tests.
    var fetch: @Sendable (_ url: URL, _ key: String) async -> [String]? = { url, key in
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return TextModelCatalog.identifiers(in: data)
    }

    private let defaults: UserDefaults
    private static let storageKey = "textModelListings.v1"
    static let freshness: TimeInterval = 24 * 3_600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: Listing].self, from: data) {
            listings = stored
        }
    }

    /// Modèles de texte d'un compte : la liste lue, ou les modèles d'origine.
    func models(account: String) -> [TextModel] {
        guard let listing = listings[account] else { return TextModelCatalog.defaults(account: account) }
        return TextModelCatalog.usable(listing.identifiers, account: account)
    }

    /// Relit la liste des comptes dont la clé est donnée, si elle a plus d'un jour ou si « force ».
    func refresh(keys: [String: String], force: Bool = false, now: Date = Date()) async {
        await withTaskGroup(of: (String, [String]?).self) { group in
            for (account, key) in keys where !key.isEmpty && !loading.contains(account) {
                if !force, let listing = listings[account], now.timeIntervalSince(listing.loadedAt) < Self.freshness { continue }
                guard let url = TextModelCatalog.listURL(account: account) else { continue }
                loading.insert(account)
                let fetch = self.fetch
                group.addTask { (account, await fetch(url, key)) }
            }
            for await (account, identifiers) in group {
                loading.remove(account)
                if let identifiers, !identifiers.isEmpty {
                    listings[account] = Listing(identifiers: identifiers, loadedAt: now)
                }
            }
        }
        if let data = try? JSONEncoder().encode(listings) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

extension AppModel {
    /// Clés actives des comptes qui peuvent corriger.
    var cleanupKeys: [String: String] {
        Dictionary(uniqueKeysWithValues: CleanupChoice.accounts.compactMap { account in key(account).map { (account, $0) } })
    }
}

extension TextModel.Speed {
    var label: String {
        switch self {
        case .fast: return String(localized: "Rapides")
        case .balanced: return String(localized: "Équilibrés")
        case .slow: return String(localized: "Lents")
        }
    }

    var short: String {
        switch self {
        case .fast: return String(localized: "rapide")
        case .balanced: return String(localized: "moyen")
        case .slow: return String(localized: "lent")
        }
    }
}

/// Menu d'un modèle de correction : par fournisseur, les modèles d'origine d'abord, puis tous les modèles de texte de
/// la clé dans un sous-menu, rangés par rapidité, chacun avec son coût estimé pour 100 dictées.
struct CleanupModelMenu: View {
    @Environment(AppModel.self) private var model
    var title: String
    @Binding var selection: CleanupChoice
    /// Première ligne du menu : « Automatique » ou « Aucun relais ».
    var neutral: CleanupChoice
    var neutralLabel: String
    /// Modèle déjà en premier : il ne se choisit pas comme relais.
    var excluded: CleanupChoice?

    private var directory: TextModelDirectory { .shared }

    var body: some View {
        let latencies = TextModelCatalog.medianLatencies(model.usage)
        Menu {
            pick(neutral, label: neutralLabel)
            ForEach(CleanupChoice.accounts, id: \.self) { account in
                let name = CleanupChoice.providerName(account: account) ?? account
                Section(name) {
                    if model.hasKey(account: account) {
                        let all = TextModelCatalog.sorted(withSelection(directory.models(account: account), account: account),
                                                          latencies: latencies)
                        ForEach(all.filter(\.isRecommended)) { item in
                            pick(item.choice, label: line(item, latencies: latencies, note: String(localized: "recommandé")))
                        }
                        Menu(String(localized: "Tous les modèles \(name) (\(all.count))")) {
                            ForEach(TextModel.Speed.allCases, id: \.self) { speed in
                                let group = all.filter { TextModelCatalog.speed($0.model, measuredMilliseconds: latencies[$0.model]) == speed }
                                if !group.isEmpty {
                                    Section(speed.label) {
                                        ForEach(group) { item in
                                            pick(item.choice, label: line(item, latencies: latencies, note: nil))
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        Text(model.hasStoredKey(account: account) ? String(localized: "Clé coupée") : String(localized: "Aucune clé : ajoute-la plus bas"))
                    }
                }
            }
        } label: {
            Text(currentLabel)
        }
        .accessibilityLabel(title)
        .fixedSize()
        .task(id: model.cleanupKeys.keys.sorted()) {
            await directory.refresh(keys: model.cleanupKeys)
        }
    }

    /// Le modèle choisi reste dans la liste même si le fournisseur ne le propose plus.
    private func withSelection(_ models: [TextModel], account: String) -> [TextModel] {
        guard selection.account == account, let chosen = selection.model,
              !models.contains(where: { $0.model == chosen }) else { return models }
        return models + [TextModel(account: account, model: chosen)]
    }

    private var currentLabel: String {
        if selection == neutral { return neutralLabel }
        guard let provider = selection.providerName, let name = selection.model else { return neutralLabel }
        return "\(provider) · \(name)"
    }

    @ViewBuilder
    private func pick(_ choice: CleanupChoice, label: String) -> some View {
        Button {
            selection = choice
        } label: {
            if choice == selection {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
        .disabled(choice == excluded && choice != neutral)
    }

    /// « gpt-4.1-mini · rapide · ≈ 0,05 $ / 100 dictées ».
    private func line(_ item: TextModel, latencies: [String: Int], note: String?) -> String {
        let measured = latencies[item.model]
        var parts = [item.model]
        if let measured {
            parts.append(String(localized: "≈ \(CallText.latency(measured)) chez toi"))
        } else {
            parts.append(TextModelCatalog.speed(item.model).short)
        }
        if let cost = TextModelCatalog.costPerHundred(item.model) {
            parts.append(String(localized: "≈ \(MoneyFormat.price(cost)) / 100 dictées"))
        } else {
            parts.append(String(localized: "prix inconnu"))
        }
        if let note { parts.append(note) }
        if item.choice == excluded { parts.append(String(localized: "déjà en premier")) }
        return parts.joined(separator: " · ")
    }
}
