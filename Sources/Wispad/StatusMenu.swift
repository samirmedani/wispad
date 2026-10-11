import AppKit
import WispadCore

/// Menu de la barre : l'état d'abord, puis l'action utile maintenant, puis les écrans. Les actions sont des
/// méthodes du délégué de l'app (la cible), nommées ici par leur sélecteur pour que le menu reste testable.
@MainActor
enum StatusMenu {
    static func items(model: AppModel, target: AnyObject?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: String, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key)
            item.target = target
            items.append(item)
            return item
        }
        func note(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            items.append(item)
        }
        let coordinator = model.coordinator
        note("● " + state(model))
        let relays = model.relayLines()
        for line in relays { note("⇄ " + line) }
        if !relays.isEmpty { _ = add(String(localized: "Réessayer les services maintenant"), "retryServices") }
        items.append(.separator())
        switch coordinator.phase {
        case .listening:
            _ = add(String(localized: "Terminer la dictée"), "toggleDictation")
            _ = add(String(localized: "Annuler la dictée (Échap)"), "cancelDictation")
        case .starting:
            note(String(localized: "Dicter (mains libres)"))
            _ = add(String(localized: "Annuler la dictée (Échap)"), "cancelDictation")
        case .finishing:
            _ = add(String(localized: "Dicter (mains libres)"), "toggleDictation")
            _ = add(String(localized: "Annuler la transcription en cours (Échap)"), "cancelDictation")
        case .idle, .failure:
            _ = add(String(localized: "Dicter (mains libres)"), "toggleDictation")
        }
        add(String(localized: "Copier la dernière dictée"), "copyLastDictation").isEnabled = model.history.contains { !$0.finalText.isEmpty }
        // Un mot appris à tort se retire en un clic, sans ouvrir la fenêtre.
        for term in model.recentlyLearned where model.dictionary.contains(where: { $0.term == term }) {
            add(String(localized: "Retirer « \(term) » du dictionnaire"), "removeLearned:").representedObject = term
        }
        items.append(.separator())
        let today = model.usageSummary(for: .today)
        let dictations = model.history.filter { Calendar.current.isDateInToday($0.createdAt) && !$0.finalText.isEmpty }.count
        let incomplete = today.hasUnpricedCalls || model.usageLoadFailed
        let amount = UsagePresentation.amount(today.totalUSD, incomplete: incomplete)
        let spent = incomplete ? String(localized: "Aujourd'hui : \(amount) (minimum)") : String(localized: "Aujourd'hui : \(amount) estimés")
        let count = dictations == 1 ? String(localized: "1 dictée") : String(localized: "\(dictations) dictées")
        _ = add("\(spent) · \(count)", "openUsage")
        items.append(.separator())
        _ = add(String(localized: "Ouvrir Wispad"), "openHome")
        _ = add(String(localized: "Historique"), "openHistory")
        _ = add(String(localized: "Dictionnaire"), "openDictionary")
        _ = add(String(localized: "Réglages…"), "openSettings", key: ",")
        items.append(.separator())
        _ = add(String(localized: "Quitter Wispad"), "quit", key: "q")
        return items
    }

    private static func state(_ model: AppModel) -> String {
        let shortcut = KeyLabels.describe(keyCode: model.settings.keyCode, modifiers: model.settings.modifierFlags)
        switch model.coordinator.phase {
        case .idle:
            return model.setupWarning ?? String(localized: "Prêt · double appui sur \(shortcut) : mains libres, maintenu : dictée courte")
        case .starting:
            return String(localized: "Préparation de l'écoute…")
        case .listening(let mode):
            return mode == .toggle ? String(localized: "Écoute en continu") : String(localized: "Écoute en cours")
        case .finishing:
            let count = model.coordinator.finishingCount
            return count > 1 ? String(localized: "\(count) dictées en cours de transcription") : String(localized: "Transcription en cours")
        case .failure(let message):
            return message
        }
    }
}
