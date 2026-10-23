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
                    Text(model.hasKey(provider) ? provider.displayName : String(localized: "\(provider.displayName) · sans clé active"))
                        .tag(provider)
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

/// Clés enregistrées, masquées, chacune avec son interrupteur (et sa corbeille hors coffre), puis « Ajouter une
/// clé » : le fournisseur d'une clé collée est reconnu à sa forme, puis la clé est vérifiée chez lui seul.
struct APIKeysSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let accounts = APIKeys.accounts.filter { model.hasStoredKey(account: $0) }
        Section {
            if !model.keysReachable {
                Label(model.dependencies.keyStore == .vault ? String(localized: "Coffre injoignable") : String(localized: "Clés illisibles"),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if accounts.isEmpty {
                Text("Aucune clé pour l'instant. Ajoute celle de ton fournisseur de voix, xAI ou OpenAI, pour dicter.")
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts, id: \.self) { account in
                APIKeyListRow(account: account)
            }
            AddKeyRow()
            if let message = model.keysMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.dependencies.keyStore == .vault {
                Button("Recharger depuis le coffre") { Task { await model.refreshKeys() } }
                    .hoverFeedback()
            }
        } header: {
            Text("Clés API")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recommandé : xAI pour la voix, DeepSeek pour la correction, la moins chère. Facultatif : Jev (TypeSafe) pour mieux choisir les mots à apprendre. Chaque service se remplace par un autre dont tu as la clé.")
                Text(footer)
                Text(model.dependencies.keyStore == .vault
                     ? String(localized: "Une clé coupée reste dans le coffre, mais Wispad ne s'en sert plus. Pour en supprimer une, passe par l'outil de ton coffre.")
                     : String(localized: "Une clé coupée reste enregistrée, mais Wispad ne s'en sert plus."))
            }
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

/// Une clé enregistrée : nom, rôle, clé masquée, interrupteur, et corbeille pour le fichier de l'app.
struct APIKeyListRow: View {
    @Environment(AppModel.self) private var model
    var account: String
    @State private var confirmsDeletion = false

    var body: some View {
        let enabled = model.isKeyEnabled(account)
        let title = APIKeys.title(account)
        LabeledContent {
            HStack(spacing: 12) {
                if case .rejected = model.keyChecks[account] {
                    StatusChip(text: String(localized: "Refusée"), tint: .red)
                }
                Text(model.maskedKey(account))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Toggle(String(localized: "Utiliser la clé \(title)"), isOn: Binding(
                    get: { enabled },
                    set: { model.setKeyEnabled(account, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(enabled ? String(localized: "Wispad utilise cette clé") : String(localized: "Clé coupée : gardée, mais pas utilisée"))
                if model.dependencies.keyStore.allowsDeletion {
                    // Corbeille discrète : la confirmation porte l'alerte.
                    Button {
                        confirmsDeletion = true
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .hoverFeedback()
                    .help(String(localized: "Supprimer la clé"))
                    .accessibilityLabel(String(localized: "Supprimer la clé \(title)"))
                    .confirmationDialog(String(localized: "Supprimer la clé \(title) ?"), isPresented: $confirmsDeletion) {
                        Button(String(localized: "Supprimer"), role: .destructive) { Task { await model.removeKey(account) } }
                    } message: {
                        Text("Elle est effacée de ce Mac. Tu pourras en ajouter une autre à tout moment.")
                    }
                }
            }
        } label: {
            Text(title)
            Text(enabled ? APIKeys.purpose(account) : String(localized: "Coupée : gardée, mais Wispad ne s'en sert pas"))
        }
    }
}

/// « Ajouter une clé » : on colle, le fournisseur s'affiche tout seul, puis la clé est vérifiée chez lui et
/// enregistrée. Une clé sans signe distinctif (TypeSafe) demande seulement de choisir son fournisseur.
struct AddKeyRow: View {
    @Environment(AppModel.self) private var model
    @State private var open = false
    @FocusState private var focused: Bool

    var body: some View {
        // Ouverte aussi tant qu'une clé est en cours de saisie (retour sur l'écran pendant une vérification).
        if open || !model.newKeyDraft.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SecureField(String(localized: "Nouvelle clé"), text: Binding(
                        get: { model.newKeyDraft },
                        set: { model.newKeyDraft = $0 }
                    ), prompt: Text("Colle la clé ici"))
                    .labelsHidden()
                    .focused($focused)
                    .onSubmit(add)
                    Button("Annuler", action: close)
                        .hoverFeedback()
                    Button(model.addingKey ? String(localized: "Vérification…") : String(localized: "Ajouter"), action: add)
                        .buttonStyle(.borderedProminent)
                        .hoverFeedback()
                        .disabled(!canAdd)
                }
                recognition
            }
            .onAppear { focused = true }
        } else {
            Button {
                model.keysMessage = nil
                open = true
            } label: {
                Label("Ajouter une clé", systemImage: "plus")
            }
            .hoverFeedback()
        }
    }

    private var draft: String { APIKeyFormat.normalize(model.newKeyDraft) }

    private var canAdd: Bool {
        !model.addingKey && !draft.isEmpty && !model.candidateAccounts(for: draft).isEmpty
    }

    /// Fournisseur reconnu à la forme de la clé, au fil de la saisie ; sinon le choix à faire.
    @ViewBuilder private var recognition: some View {
        if draft.isEmpty {
            hint(String(localized: "Colle une clé xAI, OpenAI, DeepSeek ou TypeSafe : son fournisseur est reconnu tout seul."), symbol: "info.circle")
        } else {
            switch APIKeyFormat.guess(draft) {
            case .account(let account):
                let title = APIKeys.title(account)
                hint(model.hasStoredKey(account: account)
                     ? String(localized: "Clé \(title) reconnue : elle remplacera la clé actuelle.")
                     : String(localized: "Clé \(title) reconnue."),
                     symbol: "checkmark.circle.fill", tint: .green)
            case .xai:
                hint(String(localized: "Clé xAI reconnue : la vérification dira si c'est une clé d'API ou de gestion."),
                     symbol: "checkmark.circle.fill", tint: .green)
            case .unsupported(let service):
                hint(String(localized: "Clé \(service) : Wispad ne s'en sert pas."), symbol: "xmark.circle.fill", tint: .red)
            case .unknown:
                HStack(spacing: 10) {
                    Picker("Fournisseur", selection: Binding(
                        get: { model.newKeyAccount },
                        set: { model.newKeyAccount = $0 }
                    )) {
                        Text("Choisir…").tag(String?.none)
                        ForEach(APIKeys.accounts, id: \.self) { account in
                            Text(APIKeys.title(account)).tag(String?.some(account))
                        }
                    }
                    .fixedSize()
                    Text("Fournisseur non reconnu à la forme de la clé : choisis-le.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func hint(_ text: String, symbol: String, tint: Color = .secondary) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func add() {
        guard canAdd else { return }
        Task { if await model.addKey() { open = false } }
    }

    private func close() {
        model.newKeyDraft = ""
        model.newKeyAccount = nil
        open = false
    }
}

// MARK: - Correction

struct CorrectionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            LabeledContent("Service de correction") {
                Text(service)
            }
        } header: {
            Text("Correction")
        } footer: {
            Text("DeepSeek d'abord s'il a une clé, puis OpenAI, puis le modèle du fournisseur de voix. Seul le texte part, jamais l'audio.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var service: String {
        guard model.settings.cleanupEnabled else { return String(localized: "Coupée dans Réglages") }
        guard let name = model.correctionServiceName else { return String(localized: "Aucune clé active") }
        return String(localized: "Automatique : \(name)")
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
