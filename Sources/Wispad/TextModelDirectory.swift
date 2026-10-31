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
    /// Comptes dont la lecture est en cours, et ceux dont la dernière lecture n'a pas répondu.
    private(set) var loading: Set<String> = []
    private(set) var failed: Set<String> = []

    /// Lecture de la liste d'un compte ; remplaçable dans les tests.
    var fetch: @Sendable (_ url: URL, _ key: String) async -> [String]? = { url, key in
        var request = URLRequest(url: url)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return TextModelCatalog.identifiers(in: data)
    }

    private let defaults: UserDefaults
    private static let storageKey = "textModelListings.v1"
    static let freshness: TimeInterval = 24 * 3_600

    #if DEBUG
    /// Aperçus : listes fictives gardées en mémoire. Rien n'est demandé aux fournisseurs ni enregistré sur ce Mac.
    private(set) var previewOnly = false

    func usePreviewListings(_ identifiers: [String: [String]]) {
        previewOnly = true
        for (account, list) in identifiers { listings[account] = Listing(identifiers: list, loadedAt: Date()) }
    }
    #endif

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
        #if DEBUG
        if previewOnly { return }
        #endif
        await withTaskGroup(of: (String, [String]?).self) { group in
            for (account, key) in keys where !key.isEmpty && !loading.contains(account) {
                if !force, let listing = listings[account], now.timeIntervalSince(listing.loadedAt) < Self.freshness { continue }
                guard let url = TextModelCatalog.listURL(account: account, key: key) else { continue }
                loading.insert(account)
                let fetch = self.fetch
                // Le serveur local n'a pas de clé : sa « clé » est son adresse, jamais envoyée en en-tête.
                let header = account == CleanupModel.localAccount ? "" : key
                group.addTask { (account, await fetch(url, header)) }
            }
            for await (account, identifiers) in group {
                loading.remove(account)
                if let identifiers {
                    failed.remove(account)
                    listings[account] = Listing(identifiers: identifiers, loadedAt: now)
                } else {
                    failed.insert(account)
                    // Un serveur local éteint ne garde pas une ancienne liste : ses modèles ne sont plus là.
                    if account == CleanupModel.localAccount { listings[account] = nil }
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
