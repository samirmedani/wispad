import SwiftUI
import WispadCore

/// Fournisseurs : en tête, une vue d'ensemble (ce qui marche, ce qui manque, le bouton qui règle) ; puis le modèle de
/// la voix et celui de la correction, choisis dans un sélecteur en cartes ; les clés API ; et, repliés dans « Réglages
/// avancés », les relais, la vérification, les mots appris, le modèle local, la source des clés et l'état des services.
/// L'écran est lu une fois par affichage (`ProvidersSnapshot`) : les listes de modèles ne se calculent qu'à
/// l'ouverture du sélecteur.
struct ProvidersView: View {
    @Environment(AppModel.self) private var model
    @State private var picker: ModelPickerKind?
    @State private var keyEntry: KeyEntryHost?
    @State private var advanced = false

    #if DEBUG
    /// Aperçus : réglages avancés dépliés.
    static var previewAdvanced = false
    #endif

    var body: some View {
        let snapshot = ProvidersSnapshot(model: model)
        FormScreen(title: String(localized: "Fournisseurs"), subtitle: String(localized: "Où ta voix est transcrite, et ce qui corrige le texte.")) {
            OverviewSection(snapshot: snapshot, picker: $picker, keyEntry: $keyEntry)
            ModelsSection(snapshot: snapshot, picker: $picker)
            APIKeysSection(snapshot: snapshot, keyEntry: $keyEntry)
            AdvancedToggleSection(expanded: $advanced, attention: snapshot.advancedNeedsAttention)
            if advanced {
                RelaysSection(snapshot: snapshot, picker: $picker)
                LearningSection(snapshot: snapshot, keyEntry: $keyEntry)
                LocalModelSection()
                KeySourceSection()
                ServiceStatusSection()
            }
        }
        .sheet(item: $picker, onDismiss: {
            if case .picker = keyEntry { keyEntry = nil }
        }) { kind in
            ModelPickerSheet(kind: kind, snapshot: snapshot, keyEntry: $keyEntry, openAdvanced: { advanced = true })
                .environment(model)
                .tint(Theme.brand)
        }
        // Liste des modèles de chaque clé de correction, relue au plus une fois par jour.
        .task(id: model.cleanupKeys.keys.sorted()) {
            await TextModelDirectory.shared.refresh(keys: model.cleanupKeys)
        }
        #if DEBUG
        .onAppear { if Self.previewAdvanced { advanced = true } }
        #endif
    }
}

// MARK: - Vue d'ensemble

/// Ce qui marche, ce qui manque, et le bouton qui règle. Relue chaque minute : un service mis de côté est repris avec
/// le temps.
private struct OverviewSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    var snapshot: ProvidersSnapshot
    @Binding var picker: ModelPickerKind?
    @Binding var keyEntry: KeyEntryHost?
    @State private var checking = false
    @State private var reloading = false

    var body: some View {
        // Un service mis de côté ou repris change la vue d'ensemble tout de suite ; l'expiration, à la minute.
        let _ = model.health
        Section {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                card(ProvidersOverview.make(snapshot, paused: model.relayLines()))
            }
        }
    }

    private func card(_ overview: ProvidersOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                OverviewGlyph(tone: overview.tone)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: overview.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(verbatim: overview.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !overview.actions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(overview.actions.enumerated()), id: \.element) { index, action in
                                actionButton(action, prominent: index == 0)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                Spacer(minLength: 0)
            }
            if case .overview(let expected) = keyEntry {
                KeyEntryForm(expected: expected) { keyEntry = nil }
                    .padding(.leading, 48)
            }
            ForEach(overview.rows) { gap in
                Divider().padding(.leading, 48)
                gapRow(gap)
            }
            if !overview.paused.isEmpty {
                Divider().padding(.leading, 48)
                pausedRow(overview.paused)
            }
        }
        .padding(.vertical, 6)
        .animation(reduceMotion ? nil : Theme.spring, value: overview)
    }

    /// Une autre clé à régler : pastille, ce qui ne sert pas, et le bouton qui règle.
    private func gapRow(_ gap: KeyGap) -> some View {
        HStack(spacing: 12) {
            ProviderTile(account: gap.account, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: gap.title)
                    .font(.system(size: 13, weight: .medium))
                Text(verbatim: gap.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if gap.stored {
                Button(String(localized: "Rallumer")) { perform(.enableKey(gap.account)) }
                    .hoverFeedback()
            } else if !snapshot.readOnlyKeys, keyEntry != .overview(gap.account) {
                Button(String(localized: "Ajouter la clé")) { perform(.addKey(gap.account)) }
                    .hoverFeedback()
            }
        }
        .padding(.leading, 48)
    }

    /// Services en pause et relais pris à leur place, quand le titre parle d'autre chose.
    private func pausedRow(_ lines: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(OverlayStyle.relay)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line).font(.callout)
                }
            }
            Spacer(minLength: 8)
            actionButton(.retryServices, prominent: false)
        }
        .padding(.leading, 48)
    }

    @ViewBuilder
    private func actionButton(_ action: ProvidersOverview.Action, prominent: Bool) -> some View {
        let button = Button(label(action)) { perform(action) }
            .disabled(busy(action))
        if prominent {
            button.buttonStyle(.borderedProminent).hoverFeedback()
        } else {
            button.hoverFeedback()
        }
    }

    private func label(_ action: ProvidersOverview.Action) -> String {
        switch action {
        case .reload:
            if reloading { return String(localized: "Lecture…") }
            if snapshot.readOnlyKeys { return String(localized: "Recharger depuis la source") }
            return snapshot.keyStore == .vault ? String(localized: "Recharger depuis le coffre") : String(localized: "Réessayer")
        case .addKey(let account):
            return account.map { String(localized: "Ajouter la clé \(ProviderName.of($0))") } ?? String(localized: "Ajouter une clé")
        case .enableKey(let account):
            return String(localized: "Rallumer la clé \(ProviderName.of(account))")
        case .useVoice(let provider):
            return String(localized: "Dicter avec \(provider.displayName)")
        case .retryServices:
            return checking ? String(localized: "Vérification…") : String(localized: "Réessayer maintenant")
        case .choose(let kind):
            return kind == .voiceRelay || kind == .correctionRelay ? String(localized: "Choisir un autre relais")
                : String(localized: "Choisir un autre modèle")
        }
    }

    private func busy(_ action: ProvidersOverview.Action) -> Bool {
        switch action {
        case .reload: return reloading
        case .retryServices: return checking
        case .addKey(let account): return keyEntry == .overview(account)
        default: return false
        }
    }

    private func perform(_ action: ProvidersOverview.Action) {
        switch action {
        case .reload:
            reloading = true
            Task {
                await model.refreshKeys()
                reloading = false
            }
        case .addKey(let account):
            model.keysMessage = nil
            keyEntry = .overview(account)
        case .enableKey(let account):
            withAnimation(reduceMotion ? nil : Theme.spring) { model.setKeyEnabled(account, true) }
        case .useVoice(let provider):
            withAnimation(reduceMotion ? nil : Theme.spring) { model.chooseVoice(provider, model: model.liveModel(for: provider)) }
        case .retryServices:
            checking = true
            Task {
                await model.checkDownServices()
                checking = false
            }
        case .choose(let kind):
            picker = kind
        }
    }
}

/// Pastille de la vue d'ensemble : verte quand tout est prêt, verte du relais quand un service est en pause, orange
/// quand un choix ne sert pas, rouge de la marque quand on ne peut pas dicter.
private struct OverviewGlyph: View {
    var tone: ProvidersOverview.Tone

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(color.gradient))
            .shadow(color: color.opacity(0.3), radius: 5, y: 2)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch tone {
        case .ready: return "checkmark"
        case .relay: return "arrow.triangle.branch"
        case .attention: return "exclamationmark"
        case .blocked: return "key.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .ready: return .green
        case .relay: return OverlayStyle.relay
        case .attention: return .orange
        case .blocked: return Theme.brand
        }
    }
}

// MARK: - Modèles

/// Les deux choix qui comptent : le modèle de la voix et celui de la correction, chacun dans un bouton qui ouvre le
/// sélecteur en cartes.
private struct ModelsSection: View {
    @Environment(AppModel.self) private var model
    var snapshot: ProvidersSnapshot
    @Binding var picker: ModelPickerKind?

    /// Largeur réservée à l'interrupteur de la correction : les deux boutons de modèle s'alignent.
    private static let switchWidth: CGFloat = 40

    var body: some View {
        Section {
            ModelRow(symbol: "waveform", tint: Theme.brand, title: String(localized: "Voix"),
                     summary: String(localized: "Transcrit pendant que tu parles.")) {
                ModelSummaryButton(summary: snapshot.voiceSummary, help: String(localized: "Choisir le modèle de la voix")) {
                    picker = .voice
                }
                .padding(.trailing, Self.switchWidth + 12)
            }
            ModelRow(symbol: "wand.and.stars", tint: .purple, title: String(localized: "Correction"),
                     summary: String(localized: "Ponctuation, mots mal entendus, mise en forme.")) {
                ModelSummaryButton(summary: snapshot.correctionSummary, help: String(localized: "Choisir le modèle de correction")) {
                    picker = .correction
                }
                .disabled(!snapshot.cleanupEnabled)
                Toggle(String(localized: "Corriger le texte avant insertion"), isOn: Binding(
                    get: { snapshot.cleanupEnabled },
                    set: { model.setSetting(\.cleanupEnabled, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(width: Self.switchWidth, alignment: .trailing)
            }
        } header: {
            Text("Modèles")
        }
    }
}

/// Une étape : pastille, titre et rôle en une ligne, puis son choix à droite.
private struct ModelRow<Control: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var summary: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(verbatim: summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            HStack(spacing: 12) { control }
        }
        .padding(.vertical, 4)
    }
}

/// Bouton d'un choix de modèle : pastille du fournisseur, nom, précision (fournisseur et prix) ou ce qui l'empêche de
/// servir, en orange. Ouvre le sélecteur.
struct ModelSummaryButton: View {
    var summary: ModelSummary
    var help: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.interactionPreviewHover) private var previewHover
    @State private var hovering = false

    private var highlighted: Bool { isEnabled && (hovering || previewHover) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let account = summary.account {
                    ProviderTile(account: account, size: 24)
                } else {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: summary.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let warning = summary.warning {
                        // Discret : la vue d'ensemble porte l'alerte et le bouton qui règle.
                        HStack(spacing: 5) {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                            Text(verbatim: warning)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else {
                        Text(verbatim: summary.caption)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 280, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(highlighted ? Theme.brand.opacity(0.06) : Theme.subtleFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(highlighted ? Theme.brand.opacity(0.35) : Theme.cardBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: highlighted)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(Text(verbatim: "\(summary.title), \(summary.warning ?? summary.caption)"))
    }
}

/// Pastille d'un fournisseur : sa couleur et un signe simple, sans logo officiel.
struct ProviderTile: View {
    var account: String
    var size: CGFloat = 28
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        glyph
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(shape.fill(tint.gradient))
            .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0), lineWidth: 1))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch account {
        case ProviderID.xai.rawValue, APIKeys.xaiManagement:
            Text(verbatim: "xAI")
                .font(.system(size: size * 0.34, weight: .heavy, design: .rounded))
        default:
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
        }
    }

    private var symbol: String {
        switch account {
        case ProviderID.openAI.rawValue: return "circle.hexagongrid.fill"
        case CleanupModel.deepSeekAccount: return "fish.fill"
        case APIKeys.typesafe: return "checkmark.seal.fill"
        case CleanupModel.localAccount: return "laptopcomputer"
        default: return "key.fill"
        }
    }

    private var tint: Color {
        switch account {
        case ProviderID.xai.rawValue, APIKeys.xaiManagement: return Color(white: 0.12)
        case ProviderID.openAI.rawValue: return Color(red: 0.06, green: 0.64, blue: 0.5)
        case CleanupModel.deepSeekAccount: return Color(red: 0.3, green: 0.42, blue: 1)
        case APIKeys.typesafe: return Color(red: 0.49, green: 0.36, blue: 1)
        default: return .gray
        }
    }
}

// MARK: - Clés API

/// Page où chaque fournisseur crée ses clés.
enum ProviderLinks {
    static func createKey(_ account: String) -> URL? {
        switch account {
        case ProviderID.xai.rawValue: return URL(string: "https://console.x.ai")
        case ProviderID.openAI.rawValue: return URL(string: "https://platform.openai.com/api-keys")
        case CleanupModel.deepSeekAccount: return URL(string: "https://platform.deepseek.com/api_keys")
        default: return nil
        }
    }
}

/// Clés enregistrées, masquées, chacune avec son interrupteur (et sa corbeille hors coffre), puis « Ajouter une clé ».
private struct APIKeysSection: View {
    @Environment(AppModel.self) private var model
    var snapshot: ProvidersSnapshot
    @Binding var keyEntry: KeyEntryHost?

    var body: some View {
        let accounts = APIKeys.accounts.filter { snapshot.stored.contains($0) }
        Section {
            if !snapshot.keysReachable {
                Label(snapshot.keyStore == .vault ? String(localized: "Coffre injoignable") : String(localized: "Clés illisibles"),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if accounts.isEmpty {
                Text("Aucune clé pour l'instant.")
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts, id: \.self) { account in
                APIKeyListRow(account: account)
            }
            if snapshot.readOnlyKeys {
                Text("Ta source de clés se lit seulement : ajoute une clé dans ton serveur ou ton gestionnaire, puis recharge.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                AddKeyRow(keyEntry: $keyEntry)
            }
            if let message = model.keysMessage, keyEntry == nil {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if snapshot.keyStore == .vault {
                Button {
                    Task { await model.refreshKeys() }
                } label: {
                    Label(snapshot.readOnlyKeys ? String(localized: "Recharger depuis la source") : String(localized: "Recharger depuis le coffre"),
                          systemImage: "arrow.clockwise")
                }
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
        switch snapshot.keyStore {
        case .vault where snapshot.readOnlyKeys:
            return String(localized: "Clés lues sur ta source à chaque lancement et gardées en mémoire : rien n'est écrit sur ce Mac.")
        case .vault:
            return String(localized: "Clés lues dans ton coffre de secrets et gardées en mémoire : rien n'est écrit sur ce Mac. Pour en supprimer une, passe par ton coffre.")
        case .file:
            return String(localized: "Chaque clé est vérifiée chez son fournisseur, puis gardée sur ce Mac, lisible par ton seul compte.")
        }
    }
}

/// Une clé enregistrée : pastille, nom, rôle, clé masquée, interrupteur, et corbeille pour le fichier de l'app.
struct APIKeyListRow: View {
    @Environment(AppModel.self) private var model
    var account: String
    @State private var confirmsDeletion = false

    var body: some View {
        let enabled = model.isKeyEnabled(account)
        let title = APIKeys.title(account)
        HStack(spacing: 12) {
            ProviderTile(account: account, size: 26)
                .opacity(enabled ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text(enabled ? APIKeys.purpose(account) : String(localized: "Coupée : gardée, mais Wispad ne s'en sert pas"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
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
    }
}

/// « Ajouter une clé » : ouvre la saisie ici. Ouverte aussi tant qu'une clé saisie est en cours de vérification
/// (retour sur l'écran pendant une vérification).
private struct AddKeyRow: View {
    @Environment(AppModel.self) private var model
    @Binding var keyEntry: KeyEntryHost?

    var body: some View {
        if keyEntry == .keys || (keyEntry == nil && !model.newKeyDraft.isEmpty) {
            KeyEntryForm(expected: nil) { keyEntry = nil }
        } else {
            Button {
                model.keysMessage = nil
                keyEntry = .keys
            } label: {
                Label("Ajouter une clé", systemImage: "plus")
            }
            .hoverFeedback()
        }
    }
}

/// Saisie d'une clé : on colle, le fournisseur s'affiche d'après la forme de la clé, puis elle est vérifiée chez lui
/// seul et enregistrée (`AppModel.addKey`). `expected` : fournisseur attendu, pour l'invite et le lien « Créer une
/// clé » ; une clé collée d'un autre fournisseur est reconnue et rangée chez le sien.
struct KeyEntryForm: View {
    @Environment(AppModel.self) private var model
    var expected: String?
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField(String(localized: "Nouvelle clé"), text: Binding(
                    get: { model.newKeyDraft },
                    set: { model.newKeyDraft = $0 }
                ), prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
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
            if let message = model.keysMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            links
        }
        .onAppear {
            focused = true
            // Une clé sans forme reconnue (TypeSafe) va au fournisseur attendu, sans avoir à le choisir.
            if let expected, model.newKeyAccount == nil { model.newKeyAccount = expected }
        }
    }

    private var prompt: String {
        expected.map { String(localized: "Colle ta clé \(ProviderName.of($0))") } ?? String(localized: "Colle la clé ici")
    }

    private var draft: String { APIKeyFormat.normalize(model.newKeyDraft) }

    private var canAdd: Bool {
        !model.addingKey && !draft.isEmpty && !model.candidateAccounts(for: draft).isEmpty
    }

    /// Fournisseur reconnu à la forme de la clé, au fil de la saisie ; sinon le choix à faire.
    @ViewBuilder private var recognition: some View {
        if draft.isEmpty {
            if expected == nil {
                hint(String(localized: "Colle une clé xAI, OpenAI, DeepSeek ou TypeSafe : son fournisseur est reconnu tout seul."), symbol: "info.circle")
            }
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

    /// « Créer une clé xAI », ou les pages des fournisseurs de voix et de correction.
    @ViewBuilder private var links: some View {
        let accounts = expected.map { [$0] } ?? [ProviderID.xai.rawValue, ProviderID.openAI.rawValue, CleanupModel.deepSeekAccount]
        let pages = accounts.compactMap { account in ProviderLinks.createKey(account).map { (account, $0) } }
        if !pages.isEmpty {
            HStack(spacing: 12) {
                Text(pages.count == 1 ? String(localized: "Pas encore de clé ?") : String(localized: "Créer une clé :"))
                    .foregroundStyle(.secondary)
                ForEach(pages, id: \.0) { account, url in
                    Link(destination: url) {
                        Label(pages.count == 1 ? String(localized: "Créer une clé \(APIKeys.title(account))") : APIKeys.title(account),
                              systemImage: "arrow.up.right.square")
                    }
                    .hoverFeedback()
                }
            }
            .font(.callout)
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
        Task { if await model.addKey() { onClose() } }
    }

    private func close() {
        model.newKeyDraft = ""
        model.newKeyAccount = nil
        model.keysMessage = nil
        onClose()
    }
}

// MARK: - Réglages avancés

/// « Réglages avancés » : replié par défaut ; une pastille orange signale un relais qui attend sa clé.
private struct AdvancedToggleSection: View {
    @Binding var expanded: Bool
    var attention: Bool
    @Environment(\.interactionReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            Button {
                withAnimation(reduceMotion ? nil : Theme.spring) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: "slider.horizontal.3", tint: .secondary, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Réglages avancés")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("Relais, vérification, mots appris, modèle local, source des clés.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if attention, !expanded {
                        StatusChip(text: String(localized: "À régler"), tint: .orange)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? String(localized: "Masquer les réglages avancés") : String(localized: "Afficher les réglages avancés"))
        }
    }
}

/// Relais de la voix et de la correction, et vérification sur l'enregistrement complet.
private struct RelaysSection: View {
    @Environment(AppModel.self) private var model
    var snapshot: ProvidersSnapshot
    @Binding var picker: ModelPickerKind?

    var body: some View {
        Section {
            LabeledContent {
                ModelSummaryButton(summary: snapshot.voiceRelaySummary, help: String(localized: "Choisir le relais de la voix")) {
                    picker = .voiceRelay
                }
            } label: {
                Text("Relais de la voix")
                Text("Prend la main si \(snapshot.voice.provider.displayName) ne répond pas.")
            }
            LabeledContent {
                Toggle(String(localized: "Vérifier sur l'enregistrement complet"), isOn: Binding(
                    get: { snapshot.verifyWithFile },
                    set: { model.setSetting(\.verifyWithFile, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            } label: {
                Text("Vérifier sur l'enregistrement complet")
                Text(verbatim: snapshot.verificationSummary)
            }
            LabeledContent {
                ModelSummaryButton(summary: snapshot.correctionRelaySummary, help: String(localized: "Choisir le relais de la correction")) {
                    picker = .correctionRelay
                }
                .disabled(!snapshot.cleanupEnabled)
            } label: {
                Text("Relais de la correction")
                Text(verbatim: correctionRelayLine)
            }
        } header: {
            Text("Relais et vérification")
        } footer: {
            Text("Un relais reprend la même demande quand le premier fournisseur ne répond pas.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var correctionRelayLine: String {
        guard snapshot.cleanupEnabled else { return String(localized: "Coupée : le texte est collé tel que transcrit.") }
        return snapshot.primary.map { String(localized: "Prend la main si \($0.provider) ne répond pas.") }
            ?? String(localized: "Prend la main si le premier modèle ne répond pas.")
    }
}

/// Mots appris : l'interrupteur, et qui juge qu'un mot corrigé entre au dictionnaire.
private struct LearningSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    var snapshot: ProvidersSnapshot
    @Binding var keyEntry: KeyEntryHost?

    var body: some View {
        Section {
            LabeledContent {
                Toggle(String(localized: "Apprendre de mes corrections"), isOn: Binding(
                    get: { snapshot.learnCorrections },
                    set: { model.setSetting(\.learnCorrections, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            } label: {
                Text("Apprendre de mes corrections")
                Text("Ajoute au dictionnaire les noms que tu corriges ou que la correction répare souvent.")
            }
            LabeledContent {
                if snapshot.jevStored {
                    PillPicker(options: [false, true], selection: Binding(
                        get: { snapshot.jevActive },
                        set: { jev in withAnimation(reduceMotion ? nil : Theme.spring) { model.chooseJudge(jev: jev) } }
                    ), title: { $0 ? String(localized: "Jev (TypeSafe)") : String(localized: "Comme la correction") })
                } else if !snapshot.readOnlyKeys, keyEntry != .learning {
                    Button(String(localized: "Ajouter une clé TypeSafe")) {
                        model.keysMessage = nil
                        keyEntry = .learning
                    }
                    .hoverFeedback()
                }
            } label: {
                Text("Qui choisit les mots")
                Text(verbatim: snapshot.learningSummary)
            }
            .disabled(!snapshot.learnCorrections)
            if keyEntry == .learning {
                KeyEntryForm(expected: APIKeys.typesafe) { keyEntry = nil }
            }
        } header: {
            Text("Mots appris")
        }
    }
}

/// Serveur de modèles choisi dans Fournisseurs › Réglages avancés › Modèle local.
enum LocalModelPreset: Hashable, CaseIterable {
    case none
    case ollama
    case lmStudio
    case custom

    var label: String {
        switch self {
        case .none: return String(localized: "Aucun")
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .custom: return String(localized: "Autre adresse")
        }
    }
}

/// Modèle local : un serveur de modèles sur ce Mac, compatible OpenAI (Ollama, LM Studio, llama.cpp…). Sans clé ni
/// coût, il corrige les dictées et lit les sujets du Profil sans que le texte quitte le Mac.
struct LocalModelSection: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    private typealias Preset = LocalModelPreset

    private var directory: TextModelDirectory { .shared }
    private var account: String { CleanupModel.localAccount }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 12) {
                    PillPicker(options: Preset.allCases, selection: Binding(get: { preset }, set: { choose($0) }), title: { $0.label })
                    if preset != .none {
                        Toggle(String(localized: "Utiliser le modèle local"), isOn: Binding(
                            get: { model.isKeyEnabled(account) },
                            set: { model.setKeyEnabled(account, $0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            } label: {
                Text("Serveur")
                Text("L'app qui fait tourner le modèle sur ton Mac.")
            }
            if preset == .custom {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField(String(localized: "Adresse du serveur"), text: $draft, prompt: Text(verbatim: "http://localhost:8080/v1"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .onSubmit { save(draft) }
                        Button(String(localized: "Enregistrer")) { save(draft) }
                            .disabled(TextCleaner.localBase(draft) == nil)
                    }
                } label: {
                    Text("Adresse")
                    Text("Compatible OpenAI, avec son « /v1 ».")
                }
            }
            if preset != .none {
                statusLine
            }
        } header: {
            Text("Modèle local")
        } footer: {
            Text("Gratuit et privé : le texte reste sur ton Mac. Lance Ollama ou LM Studio avec un modèle, puis choisis-le dans Correction.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear { draft = model.settings.localModelURL }
        .task(id: model.settings.localModelURL) { await check() }
    }

    @ViewBuilder
    private var statusLine: some View {
        let found = directory.listings[account]?.identifiers.filter(TextModelCatalog.isTextModel) ?? []
        HStack(spacing: 8) {
            if directory.loading.contains(account) {
                ProgressView().controlSize(.small)
                Text("Recherche du serveur…").foregroundStyle(.secondary)
            } else if directory.failed.contains(account) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Aucun serveur ne répond à \(model.settings.localModelURL). Lance-le, puis réessaie.")
                    .foregroundStyle(.orange)
            } else if found.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Le serveur répond, mais n'a aucun modèle de texte : télécharges-en un.").foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(found.count == 1 ? String(localized: "1 modèle : \(found[0])")
                     : String(localized: "\(found.count) modèles : \(found.prefix(3).joined(separator: ", "))\(found.count > 3 ? "…" : "")"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(String(localized: "Réessayer")) { Task { await check() } }
                .buttonStyle(.borderless)
                .disabled(directory.loading.contains(account))
        }
        .font(.system(size: 12))
    }

    private var preset: Preset {
        switch model.settings.localModelURL {
        case "": return .none
        case CleanupModel.ollamaURL: return .ollama
        case CleanupModel.lmStudioURL: return .lmStudio
        default: return .custom
        }
    }

    private func choose(_ preset: Preset) {
        switch preset {
        case .none:
            save("")
            if model.settings.cleanupChoice.account == account { model.settings.cleanupChoice = .automatic }
            if model.settings.cleanupRelay.account == account { model.settings.cleanupRelay = .off }
            model.saveSettings()
        case .ollama: save(CleanupModel.ollamaURL)
        case .lmStudio: save(CleanupModel.lmStudioURL)
        case .custom:
            draft = model.settings.localModelURL.isEmpty ? "http://localhost:8080/v1" : model.settings.localModelURL
            save(draft)
        }
    }

    private func save(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || TextCleaner.localBase(trimmed) != nil else { return }
        model.settings.localModelURL = trimmed
        model.saveSettings()
    }

    private func check() async {
        guard let url = model.key(account) else { return }
        await directory.refresh(keys: [account: url], force: true)
    }
}

/// Source des clés : ce Mac, un coffre de secrets, ou un serveur ou gestionnaire lu par une commande.
private struct KeySourceSection: View {
    var body: some View {
        Section {
            KeySourceRow()
        } header: {
            Text("Source des clés")
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

/// Fournisseurs › Réglages avancés › Source des clés, « Où sont tes clés ? » : sur ce Mac, ou lues sur un serveur ou dans un gestionnaire de
/// secrets par une commande où « {name} » devient le nom de la clé. Un coffre configuré à part (variable
/// WISPAD_SECRET_COMMAND ou préférence wispad.secretCommand) garde la main et n'est pas modifiable ici.
struct KeySourceRow: View {
    @Environment(AppModel.self) private var model
    @State private var remote = false
    @State private var command = ""
    @State private var testing = false
    @State private var report: String?
    @State private var reportOK = false
    /// Commande dont le test a réussi : « Utiliser » ne vaut que pour elle.
    @State private var tested: String?

    struct Template: Identifiable {
        var id: String { name }
        var name: String
        var command: String
    }

    #if DEBUG
    /// Aperçus : source distante affichée sans toucher aux préférences du Mac.
    static var previewCommand: String?
    #endif

    static let templates = [
        Template(name: String(localized: "Serveur par SSH"), command: "ssh mon-serveur 'cat ~/.secrets/{name}'"),
        Template(name: "1Password", command: "op read \"op://Wispad/{name}/credential\""),
        Template(name: "Doppler", command: "doppler secrets get {name} --plain"),
        Template(name: "Infisical", command: "infisical secrets get {name} --plain --silent"),
        Template(name: "Bitwarden", command: "bws secret get {name} | jq -r .value"),
        Template(name: String(localized: "Adresse web (curl)"), command: "curl -fsS -H \"Authorization: Bearer $WISPAD_TOKEN\" https://mon-serveur/secrets/{name} || exit 1")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.dependencies.keyStore == .vault, APIKeys.Vault.canWrite, !isPreview {
                Label(String(localized: "Clés lues dans ton coffre de secrets (\(APIKeys.Vault.tool?.lastPathComponent ?? ""))."),
                      systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Où sont tes clés ?").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Picker(String(localized: "Où sont tes clés ?"), selection: Binding(get: { remote }, set: { value in
                        remote = value
                        report = nil
                        if !value, model.usesRemoteKeySource { Task { await model.setRemoteKeySource(nil) } }
                    })) {
                        Text("Sur ce Mac").tag(false)
                        Text("Serveur ou gestionnaire").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if remote {
                    Text("Une commande lancée dans ton terminal, où {name} devient le nom de la clé (WISPAD_XAI_API_KEY, WISPAD_OPENAI_API_KEY, WISPAD_DEEPSEEK_API_KEY…). Elle écrit la clé et rien d'autre ; code 1 ou rien : clé absente.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField(String(localized: "Commande"), text: $command, prompt: Text(verbatim: "ssh mon-serveur 'cat ~/.secrets/{name}'"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Menu(String(localized: "Modèles")) {
                            ForEach(Self.templates) { template in
                                Button(template.name) { command = template.command; report = nil }
                            }
                        }
                        .fixedSize()
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await test() }
                        } label: {
                            if testing { ProgressView().controlSize(.small) } else { Text("Tester") }
                        }
                        .disabled(testing || !command.contains("{name}"))
                        Button(String(localized: "Utiliser cette source")) {
                            Task {
                                await model.setRemoteKeySource(trimmed)
                                report = String(localized: "Source enregistrée : les clés sont relues à chaque lancement.")
                                reportOK = true
                                tested = trimmed
                            }
                        }
                        .disabled(tested != trimmed || testing || !command.contains("{name}"))
                        .help(String(localized: "Teste d'abord la commande."))
                        if let report, !reportOK || tested == trimmed {
                            Label(report, systemImage: reportOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(reportOK ? .green : .orange)
                                .lineLimit(2)
                        }
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            #if DEBUG
            if let preview = Self.previewCommand {
                remote = true
                command = preview
                report = String(localized: "3 clés trouvées : xAI, OpenAI, DeepSeek")
                reportOK = true
                tested = preview
                return
            }
            #endif
            let current = APIKeys.Vault.remoteCommand()
            remote = current != nil
            command = current ?? UserDefaults.standard.string(forKey: "wispad.remoteCommand") ?? ""
            tested = current
        }
    }

    private var trimmed: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isPreview: Bool {
        #if DEBUG
        return Self.previewCommand != nil
        #else
        return false
        #endif
    }

    /// Lit chaque clé avec la commande, sans la choisir : dit lesquelles sont trouvées, jamais leur valeur.
    private func test() async {
        testing = true
        defer { testing = false }
        let checked = trimmed
        let results = await APIKeys.Vault.probe(command: checked)
        let found = results.filter(\.found).map { APIKeys.title($0.account) }
        if results.contains(where: { !$0.reachable }) && found.isEmpty {
            report = String(localized: "La commande n'a pas répondu : vérifie-la dans ton terminal.")
            reportOK = false
        } else if found.isEmpty {
            report = String(localized: "La commande répond, mais aucune clé n'a été trouvée.")
            reportOK = false
        } else {
            report = found.count == 1 ? String(localized: "1 clé trouvée : \(found[0])")
                : String(localized: "\(found.count) clés trouvées : \(found.joined(separator: ", "))")
            reportOK = true
            tested = checked
        }
    }
}
