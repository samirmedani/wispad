import SwiftUI
import WispadCore

/// Fournisseurs : qui transcrit la voix, les clés API et le service qui corrige le texte.
struct ProvidersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FormScreen(title: String(localized: "Fournisseurs"), subtitle: String(localized: "Où ta voix est transcrite, et ce qui corrige le texte.")) {
            TranscriptionSection()
            APIKeysSection()
            CorrectionSection()
            ServiceStatusSection()
        }
    }
}

// MARK: - Transcription

struct TranscriptionSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            Picker("Fournisseur", selection: Binding(
                get: { model.settings.provider },
                set: { provider in withAnimation(reduceMotion ? nil : Theme.spring) { model.selectProvider(provider) } }
            )) {
                ForEach(ProviderID.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            Picker("Modèle", selection: Binding(
                get: { model.settings.liveModel },
                set: {
                    model.settings.liveModel = $0
                    model.saveSettings()
                }
            )) {
                ForEach(ProviderCatalog.models(for: model.settings.provider)) { item in
                    Text(item.recommended ? String(localized: "\(item.displayName) · recommandé") : item.displayName).tag(item.id)
                }
            }
        } header: {
            Text("Transcription")
        } footer: {
            Text(footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        let chosen = ProviderCatalog.liveModel(id: model.settings.liveModel, provider: model.settings.provider)
        return String(localized: "\(chosen.localizedCostSummary). L'audio part chez \(model.settings.provider.displayName) ; s'il ne répond pas et qu'une clé de l'autre fournisseur est enregistrée, le même enregistrement part chez celui-ci.")
    }
}

// MARK: - Clés API

struct APIKeysSection: View {
    @Environment(AppModel.self) private var model
    @State private var showsAdvanced = false

    var body: some View {
        Section {
            APIKeyRow(account: ProviderID.xai.rawValue, title: "xAI", purpose: String(localized: "Voix recommandée, correction Grok"))
            APIKeyRow(account: ProviderID.openAI.rawValue, title: "OpenAI", purpose: String(localized: "Voix, relais et correction"))
            APIKeyRow(account: CleanupModel.deepSeekAccount, title: "DeepSeek", purpose: String(localized: "Correction la moins chère"))
            DisclosureGroup("Clés facultatives", isExpanded: $showsAdvanced) {
                APIKeyRow(account: APIKeys.xaiManagement, title: String(localized: "Gestion xAI"), purpose: String(localized: "Affiche le solde prépayé xAI"))
                if model.dependencies.keyStore == .vault || model.hasKey(account: APIKeys.typesafe) {
                    APIKeyRow(account: APIKeys.typesafe, title: "TypeSafe", purpose: String(localized: "Jev, premier avis sur les mots à apprendre"))
                }
            }
            if model.dependencies.keyStore == .vault {
                Button("Recharger depuis le coffre") { Task { await model.refreshKeys() } }
                    .hoverFeedback()
            }
        } header: {
            Text("Clés API")
        } footer: {
            Text(footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        switch model.dependencies.keyStore {
        case .vault:
            return String(localized: "Les clés viennent de ton coffre de secrets et restent en mémoire, rien n'est écrit sur ce Mac. Une nouvelle clé est enregistrée dans le coffre.")
        case .file:
            return String(localized: "Chaque clé est vérifiée auprès du fournisseur, puis enregistrée sur ce Mac, lisible par ton seul compte. Elle ne sert qu'aux appels de Wispad, payés directement à ce fournisseur.")
        }
    }
}

/// Une clé : état, saisie, vérification puis enregistrement, et suppression dans le fichier local.
struct APIKeyRow: View {
    @Environment(AppModel.self) private var model
    var account: String
    var title: String
    var purpose: String
    @State private var editing = false

    var body: some View {
        let stored = model.hasKey(account: account)
        let verifying = model.verifyingKeys.contains(account)
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                HStack(spacing: 8) {
                    if stored {
                        StatusChip(text: String(localized: "Enregistrée"), tint: .green)
                    } else if model.keysReachable {
                        StatusChip(text: String(localized: "Absente"), tint: .orange)
                    } else {
                        StatusChip(text: model.dependencies.keyStore == .vault ? String(localized: "Coffre injoignable") : String(localized: "Clés illisibles"), tint: .red)
                    }
                    if stored, !editing {
                        Button("Remplacer") { editing = true }
                            .hoverFeedback()
                        if model.dependencies.keyStore.allowsDeletion {
                            Button("Supprimer", role: .destructive) { Task { await model.removeKey(account) } }
                                .hoverFeedback()
                        }
                    }
                }
            } label: {
                Text(title)
                Text(purpose)
            }
            if !stored || editing {
                HStack {
                    SecureField("Clé \(title)", text: Binding(
                        get: { model.keyDrafts[account] ?? "" },
                        set: { model.keyDrafts[account] = $0 }
                    ), prompt: Text("Colle la clé ici"))
                    .labelsHidden()
                    Button(verifying ? String(localized: "Vérification…") : String(localized: "Enregistrer")) {
                        Task {
                            await model.verifyAndStoreKey(account)
                            if model.keyDrafts[account] == nil { editing = false }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .hoverFeedback()
                    .disabled(verifying || (model.keyDrafts[account] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let message = model.keyMessages[account] {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Correction

struct CorrectionSection: View {
    var body: some View {
        Section {
            LabeledContent("Service de correction") {
                Text("Automatique, selon tes clés")
            }
        } header: {
            Text("Correction")
        } footer: {
            Text("DeepSeek d'abord s'il a une clé, puis OpenAI, puis le modèle du fournisseur de voix. Seul le texte part, jamais l'audio.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - État des services

/// Services mis de côté après deux échecs, et relais pris à leur place. Contrôlés toutes les minutes ;
/// « Réessayer » le fait tout de suite.
struct ServiceStatusSection: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false
    /// La mise de côté expire avec le temps : la liste est relue chaque minute.
    @State private var minute = 0

    var body: some View {
        let _ = minute
        let lines = model.relayLines()
        Section {
            if lines.isEmpty {
                Label("Tous les services répondent", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "arrow.triangle.branch")
                        .foregroundStyle(OverlayStyle.relay)
                }
                Button(checking ? String(localized: "Vérification…") : String(localized: "Réessayer maintenant")) {
                    checking = true
                    Task {
                        await model.checkDownServices()
                        checking = false
                    }
                }
                .hoverFeedback()
                .disabled(checking)
            }
        } header: {
            Text("État des services")
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        minute += 1
                    }
                }
        } footer: {
            Text("Après deux échecs de suite, un service est mis de côté et ses dictées passent par le relais. Il est réessayé chaque minute, et repris au plus tard après 30 minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
