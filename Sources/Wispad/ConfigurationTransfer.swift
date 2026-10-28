import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WispadCore

// MARK: - Réglages exportés

extension AppSettings {
    /// Réglages propres à un appareil, jamais exportés et jamais remplacés par un import : le micro, l'ouverture à
    /// la connexion, les clés coupées, le serveur de modèle local, l'état du premier lancement et de la navigation.
    static let deviceOnlyKeys: Set<String> = [
        "microphoneUID", "launchAtLogin", "disabledKeys", "localModelURL", "onboardingCompleted", "onboardingResume",
        "githubStarClicked", "updateRemindedVersion", "lastSection", "settingsTab",
    ]

    /// Réglages à exporter, clé par clé, sans ceux de l'appareil.
    var exportedObject: [String: Any] {
        Self.encodedObject(self).filter { !Self.deviceOnlyKeys.contains($0.key) }
    }

    /// Ces réglages, auxquels ceux du fichier s'appliquent par-dessus ; ceux de l'appareil restent. Un réglage du
    /// fichier illisible ici (version plus récente, autre plateforme) garde sa valeur actuelle.
    func applying(_ imported: [String: Any]) -> AppSettings {
        var merged = Self.encodedObject(self)
        let current = merged
        for (key, value) in imported where !Self.deviceOnlyKeys.contains(key) {
            merged[key] = value
        }
        guard var result = Self.decodedObject(merged) else { return self }
        // Valeur importée illisible : la lecture tolérante l'a remplacée par le défaut ; on garde la valeur actuelle.
        let reread = Self.encodedObject(result)
        var restored = reread
        for (key, value) in imported where !Self.deviceOnlyKeys.contains(key) {
            if let now = reread[key], !StoredJSON.same(now, value), let previous = current[key] { restored[key] = previous }
        }
        if !StoredJSON.same(restored, reread), let fixed = Self.decodedObject(restored) { result = fixed }
        return result
    }

    /// Nombre de réglages que l'import changerait.
    func changes(applying imported: [String: Any]) -> Int {
        let before = Self.encodedObject(self), after = Self.encodedObject(applying(imported))
        return after.filter { key, value in !(before[key].map { StoredJSON.same($0, value) } ?? false) }.count
    }
}

// MARK: - Import en attente

/// Un fichier de configuration lu, montré avant d'être appliqué.
struct ConfigurationImport: Identifiable {
    let id = UUID()
    var file: ConfigurationFile
    var settingsChanges: Int
    var newTerms: [ConfigurationFile.Term]
}

extension AppModel {
    /// Configuration de cet appareil : réglages (sans ceux de l'appareil) et dictionnaire, jamais les clés.
    func exportConfiguration(now: Date = Date()) -> ConfigurationFile {
        let info = Bundle.main.infoDictionary
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let origin = ConfigurationFile.Origin(
            version: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            platform: "macOS",
            system: "\(system.majorVersion).\(system.minorVersion)" + (system.patchVersion > 0 ? ".\(system.patchVersion)" : "")
        )
        let settings = self.settings.exportedObject
        let terms = dictionary.sorted { $0.createdAt < $1.createdAt }.map(ConfigurationFile.Term.init)
        let notes = ConfigurationText.notes(exportedAt: now, origin: origin, settings: settings.count, terms: terms.count)
        return ConfigurationFile(exportedAt: now, origin: origin, notes: notes, settings: settings, dictionary: terms)
    }

    /// Prépare l'import d'un fichier : ce qu'il changerait, montré avant d'appliquer.
    func prepareImport(_ file: ConfigurationFile) -> ConfigurationImport {
        ConfigurationImport(file: file, settingsChanges: settings.changes(applying: file.settings),
                            newTerms: file.newTerms(comparedTo: dictionary.map(\.term)))
    }

    /// Ouvre un fichier (Réglages › Importer, Finder, agent) : il est montré avant tout changement ; un fichier qui
    /// n'est pas une configuration de Wispad est signalé, rien ne change.
    func openConfiguration(at url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            statusBanner = String(localized: "Impossible de lire ce fichier.")
            return
        }
        do {
            pendingConfigurationImport = prepareImport(try ConfigurationFile.read(data))
        } catch {
            statusBanner = String(localized: "Ce fichier n'est pas une configuration de Wispad.")
        }
    }

    /// Applique un import : réglages par-dessus ceux de l'appareil, termes absents ajoutés avec leur origine.
    @discardableResult
    func applyImport(_ pending: ConfigurationImport, settings applySettings: Bool, dictionary applyDictionary: Bool) -> (settings: Int, terms: Int) {
        var changed = 0
        if applySettings {
            let updated = settings.applying(pending.file.settings)
            changed = settings.changes(applying: pending.file.settings)
            settings = updated
            saveSettings()
            // Sans application (tests), rien à repeindre.
            if NSApp != nil { AppearanceSwitcher.apply(updated.appearance, animated: true) }
            overlay.bubbleStyleChanged()
            settleRelays()
        }
        var added = 0
        if applyDictionary {
            for term in pending.file.newTerms(comparedTo: dictionary.map(\.term)) {
                let stored = persist("import du dictionnaire") {
                    try store.addTerm(term.term, origin: term.origin, heard: term.heard, source: term.source,
                                      createdAt: term.addedAt ?? Date())
                }
                if stored { added += 1 }
            }
            reloadDictionary()
        }
        pendingConfigurationImport = nil
        statusBanner = ConfigurationText.imported(settings: changed, terms: added)
        return (changed, added)
    }

    /// Prompt à coller dans un agent (Codex, Claude Code…) : il installe Wispad sur l'autre appareil et applique la
    /// configuration, que le prompt contient. Jamais de clé : l'agent les demande une par une.
    func agentPrompt(for file: ConfigurationFile) throws -> String {
        let json = String(decoding: try file.encoded(), as: UTF8.self)
        return ConfigurationText.agentPrompt(origin: file.origin, exportedAt: file.exportedAt, json: json)
    }
}

// MARK: - Textes

enum ConfigurationText {
    static func dateLine(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(appLocale))
    }

    static func originLine(_ origin: ConfigurationFile.Origin, exportedAt: Date) -> String {
        let platform = origin.platform.isEmpty ? "" : " " + String(localized: "sur \(origin.platform) \(origin.system)")
        return String(localized: "Exportée le \(dateLine(exportedAt)) depuis \(origin.app) \(origin.version)") + platform
    }

    static func notes(exportedAt: Date, origin: ConfigurationFile.Origin, settings: Int, terms: Int) -> [String] {
        [
            String(localized: "Configuration de Wispad.") + " " + originLine(origin, exportedAt: exportedAt) + ".",
            String(localized: "Contenu : \(settings) réglages (voix, correction, mise en forme, raccourcis, sons, bulle, apparence) et \(terms) termes du dictionnaire."),
            String(localized: "Jamais inclus : les clés API, l'historique des dictées et l'audio. Les clés s'ajoutent sur chaque appareil."),
            String(localized: "Propres à chaque appareil, non inclus : le micro, l'ouverture à la connexion, les clés coupées et le modèle local."),
            String(localized: "Pour l'importer : Wispad › Réglages › Général › Importer, ou ouvre ce fichier avec Wispad."),
        ]
    }

    static func imported(settings: Int, terms: Int) -> String {
        let settingsText = settings == 1 ? String(localized: "1 réglage changé") : String(localized: "\(settings) réglages changés")
        let termsText = terms == 1 ? String(localized: "1 terme ajouté") : String(localized: "\(terms) termes ajoutés")
        return String(localized: "Configuration importée : \(settingsText), \(termsText).")
    }

    static func agentPrompt(origin: ConfigurationFile.Origin, exportedAt: Date, json: String) -> String {
        let fence = "```"
        return """
        \(String(localized: "Configure Wispad, l'app de dictée vocale, sur cet appareil avec ma configuration ci-dessous."))

        1. \(String(localized: "Installe Wispad s'il ne l'est pas : télécharge la dernière version sur https://github.com/samirmedani/wispad/releases/latest (Wispad.dmg pour macOS), puis place l'app dans Applications."))
        2. \(String(localized: "Enregistre la configuration ci-dessous, telle quelle, dans un fichier wispad-configuration.json."))
        3. \(String(localized: "Ouvre ce fichier avec Wispad (sur macOS : open -a Wispad wispad-configuration.json) et laisse-moi confirmer l'import dans la fenêtre qui s'ouvre."))
        4. \(String(localized: "Les clés API ne font pas partie de la configuration : demande-les-moi une par une et ajoute-les dans Wispad › Fournisseurs › Clés API. Ne les écris dans aucun fichier."))
        5. \(String(localized: "Vérifie avec moi les autorisations de Wispad (micro, accessibilité, surveillance de l'entrée), puis fais une dictée d'essai."))

        \(originLine(origin, exportedAt: exportedAt)) :

        \(fence)json
        \(json)
        \(fence)
        """
    }
}

// MARK: - Réglages › Général › Configuration

struct ConfigurationSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            SettingRow(text: SettingText(title: String(localized: "Exporter"),
                                         summary: String(localized: "Un fichier lisible : sa date, son contenu, tes réglages et ton dictionnaire."))) {
                Button(String(localized: "Exporter…")) { export() }
                    .hoverFeedback()
            }
            SettingRow(text: SettingText(title: String(localized: "Importer"),
                                         summary: String(localized: "Montre ce que contient le fichier avant de changer quoi que ce soit."))) {
                Button(String(localized: "Importer…")) { importFile() }
                    .hoverFeedback()
            }
            SettingRow(text: SettingText(title: String(localized: "Configurer avec ton agent"),
                                         summary: String(localized: "Un prompt pour Codex, Claude Code ou un autre agent : il installe Wispad sur l'autre appareil et applique ta configuration."))) {
                Button(String(localized: "Copier le prompt")) { copyPrompt() }
                    .hoverFeedback()
            }
        } header: {
            SectionTitle(title: String(localized: "Configuration"),
                         summary: String(localized: "Passe tes réglages et ton dictionnaire d'un appareil à l'autre. Les clés API n'en font jamais partie."))
        }
    }

    static func fileName(_ date: Date = Date()) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        return "Wispad-configuration-\(day).json"
    }

    private func export() {
        let file = model.exportConfiguration()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(file.exportedAt)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try file.encoded().write(to: url, options: .atomic)
            model.statusBanner = String(localized: "Configuration exportée : \(url.lastPathComponent).")
        } catch {
            model.statusBanner = String(localized: "Impossible d'écrire le fichier de configuration.")
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openConfiguration(at: url)
    }

    private func copyPrompt() {
        guard let prompt = try? model.agentPrompt(for: model.exportConfiguration()) else { return }
        model.dependencies.copyText(prompt)
        model.statusBanner = String(localized: "Prompt copié : colle-le dans ton agent, sur l'autre appareil.")
    }
}

// MARK: - Fenêtre d'import

/// Ce que contient le fichier, avant tout changement : provenance, réglages qui changeraient, termes nouveaux. Chaque
/// partie se coche ; les clés et les réglages de l'appareil ne bougent jamais.
struct ConfigurationImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var pending: ConfigurationImport
    @State private var importSettings = true
    @State private var importDictionary = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                IconBadge(symbol: "square.and.arrow.down", tint: Theme.brand, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Importer une configuration").font(.system(size: 20, weight: .bold))
                    Text(ConfigurationText.originLine(pending.file.origin, exportedAt: pending.file.exportedAt))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            if pending.file.isNewerFormat {
                Label(String(localized: "Fichier d'une version plus récente : ce que cette version ne connaît pas est ignoré."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            VStack(spacing: 0) {
                choice(isOn: $importSettings, symbol: "slider.horizontal.3", title: String(localized: "Réglages"),
                       detail: pending.settingsChanges == 0 ? String(localized: "Identiques à ceux de ce Mac")
                           : pending.settingsChanges == 1 ? String(localized: "1 réglage changera")
                           : String(localized: "\(pending.settingsChanges) réglages changeront"),
                       enabled: pending.settingsChanges > 0)
                Divider().padding(.leading, 52)
                choice(isOn: $importDictionary, symbol: "character.book.closed", title: String(localized: "Dictionnaire"),
                       detail: dictionaryDetail, enabled: !pending.newTerms.isEmpty)
            }
            .card()
            Label(String(localized: "Restent ceux de ce Mac : les clés API, le micro, l'ouverture à la connexion, les clés coupées et le modèle local."),
                  systemImage: "lock")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "Annuler"), role: .cancel) {
                    model.pendingConfigurationImport = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Importer")) {
                    model.applyImport(pending, settings: importSettings && pending.settingsChanges > 0,
                                      dictionary: importDictionary && !pending.newTerms.isEmpty)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!(importSettings && pending.settingsChanges > 0) && !(importDictionary && !pending.newTerms.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var dictionaryDetail: String {
        let total = pending.file.dictionary.count
        let fresh = pending.newTerms.count
        if total == 0 { return String(localized: "Aucun terme dans le fichier") }
        if fresh == 0 { return String(localized: "Les \(total) termes sont déjà dans ton dictionnaire") }
        let preview = pending.newTerms.prefix(4).map(\.term).joined(separator: ", ") + (fresh > 4 ? "…" : "")
        return fresh == 1 ? String(localized: "1 nouveau terme : \(preview)")
            : String(localized: "\(fresh) nouveaux termes sur \(total) : \(preview)")
    }

    private func choice(isOn: Binding<Bool>, symbol: String, title: String, detail: String, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, tint: enabled ? Theme.brand : .secondary, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!enabled)
        }
        .padding(14)
        .opacity(enabled ? 1 : 0.6)
    }
}
