import SwiftUI
import WispadCore

/// Fournisseurs : le modèle de chaque étape d'une dictée, les clés API et l'état des services.
struct ProvidersView: View {
    var body: some View {
        FormScreen(title: String(localized: "Fournisseurs"), subtitle: String(localized: "Où ta voix est transcrite, et ce qui corrige le texte.")) {
            ModelStepsSection()
            APIKeysSection()
            LocalModelSection()
            ServiceStatusSection()
        }
    }
}

// MARK: - Modèles

/// Ce qu'une étape fait maintenant, et sur quel ton l'afficher.
struct StepStatus: Equatable {
    enum Tone: Equatable {
        /// L'étape travaille : modèle, relais, prix.
        case ready
        /// L'étape ne peut pas travailler comme choisi (clé absente ou coupée).
        case warning
        /// Étape coupée par son interrupteur.
        case off
    }

    var text: String
    var tone: Tone
}

/// Fournisseurs › Modèles : les quatre étapes d'une dictée, numérotées dans leur ordre. Chacune a son choix, la voix et
/// la correction leur relais au choix, puis une ligne qui dit ce que l'étape fait maintenant (modèle réel, relais, prix).
struct ModelStepsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion

    /// Largeur réservée aux interrupteurs : le sélecteur du relais s'aligne sur celui du modèle, au-dessus.
    private static let switchWidth: CGFloat = 40

    var body: some View {
        let speech = model.speechRequest(context: nil)
        let services = TextCleaner.services(speech)
        // Service principal hors panne en cours : celui que le relais ne peut pas doubler.
        let primary = TextCleaner.services({ var calm = speech; calm.cleanupPrimaryDown = false; return calm }()).first
        Section {
            VStack(spacing: 0) {
                ModelStepRow(number: 1, title: String(localized: "Voix en direct"),
                             summary: String(localized: "Transcrit pendant que tu parles."),
                             status: voiceStatus, isLast: false,
                             relayTitle: String(localized: "Relais si \(model.settings.provider.displayName) ne répond pas")) {
                    voicePicker
                } relay: {
                    voiceRelayPicker
                }
                ModelStepRow(number: 2, title: String(localized: "Vérification"),
                             summary: String(localized: "Réécoute l'enregistrement complet à la fin."),
                             status: verifyStatus, isLast: false) {
                    Toggle(String(localized: "Vérifier sur l'enregistrement complet"), isOn: Binding(
                        get: { model.settings.verifyWithFile },
                        set: { model.settings.verifyWithFile = $0; model.saveSettings() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                ModelStepRow(number: 3, title: String(localized: "Correction"),
                             summary: String(localized: "Ponctuation, mots mal entendus, mise en forme."),
                             status: correctionStatus(services: services, speech: speech), isLast: false,
                             relayTitle: primary.map { String(localized: "Relais si \($0.provider) ne répond pas") } ?? String(localized: "Relais")) {
                    HStack(spacing: 12) {
                        correctionPicker
                            .disabled(!model.settings.cleanupEnabled)
                        Toggle(String(localized: "Corriger le texte avant insertion"), isOn: Binding(
                            get: { model.settings.cleanupEnabled },
                            set: { model.settings.cleanupEnabled = $0; model.saveSettings() }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .frame(width: Self.switchWidth, alignment: .trailing)
                    }
                } relay: {
                    cleanupRelayPicker(primary: primary)
                        .disabled(!model.settings.cleanupEnabled)
                        .padding(.trailing, Self.switchWidth + 12)
                }
                ModelStepRow(number: 4, title: String(localized: "Mots appris"),
                             summary: String(localized: "Décide si un mot corrigé entre au dictionnaire."),
                             status: learningStatus(services: services), isLast: true) {
                    HStack(spacing: 12) {
                        judgePicker
                            .disabled(!model.settings.learnCorrections)
                        Toggle(String(localized: "Apprendre de mes corrections"), isOn: Binding(
                            get: { model.settings.learnCorrections },
                            set: { model.settings.learnCorrections = $0; model.saveSettings() }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .frame(width: Self.switchWidth, alignment: .trailing)
                    }
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("Modèles")
        } footer: {
            Text("Un modèle par étape, dans l'ordre d'une dictée, et un relais au choix pour la voix et la correction : il prend la main quand le premier ne répond pas. Seuls les fournisseurs dont la clé est active se choisissent : ajoute les autres juste en dessous.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Étape 1 : voix en direct

    private struct VoiceChoice: Hashable {
        var provider: ProviderID
        var model: String
    }

    private var voicePicker: some View {
        Picker(String(localized: "Modèle de la voix en direct"), selection: Binding(
            get: { VoiceChoice(provider: model.settings.provider, model: model.settings.liveModel) },
            set: { choice in
                guard model.hasKey(choice.provider) else { return }
                withAnimation(reduceMotion ? nil : Theme.spring) {
                    model.selectProvider(choice.provider)
                    model.settings.liveModel = choice.model
                    model.saveSettings()
                }
            }
        )) {
            ForEach(ProviderID.allCases) { provider in
                Section(provider.displayName) {
                    ForEach(ProviderCatalog.models(for: provider)) { item in
                        Text(option(provider.displayName, item.displayName,
                                    availability(provider.rawValue) ?? (item.recommended ? String(localized: "recommandé") : nil)))
                            .tag(VoiceChoice(provider: provider, model: item.id))
                            .selectionDisabled(!model.hasKey(provider))
                    }
                }
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var voiceStatus: StepStatus {
        let provider = model.settings.provider
        let other: ProviderID = provider == .xai ? .openAI : .xai
        guard model.hasKey(provider) else {
            let name = provider.displayName
            let text: String
            switch (model.hasStoredKey(account: provider.rawValue), model.hasKey(other)) {
            case (true, true): text = String(localized: "Clé \(name) coupée : rallume-la, ou choisis un modèle \(other.displayName).")
            case (true, false): text = String(localized: "Clé \(name) coupée : rallume-la dans Clés API pour dicter.")
            case (false, true): text = String(localized: "Aucune clé \(name) : ajoute-la, ou choisis un modèle \(other.displayName).")
            case (false, false): text = String(localized: "Aucune clé \(name) : ajoute-la dans Clés API pour dicter.")
            }
            return StepStatus(text: text, tone: .warning)
        }
        let chosen = ProviderCatalog.liveModel(id: model.settings.liveModel, provider: provider)
        let price = MoneyFormat.price(chosen.streamingUSDPerHour)
        if let relay = model.chosenVoiceRelay, !model.hasKey(relay.provider) {
            return StepStatus(text: String(localized: "\(price)/h en direct · relais \(relay.provider.displayName) sans clé active : ajoute-la, ou choisis « Aucun relais »."),
                              tone: .warning)
        }
        if let relay = model.voiceRelayModel(for: provider), model.hasKey(relay.provider) {
            let relayPrice = MoneyFormat.price(relay.streamingUSDPerHour)
            return StepStatus(text: String(localized: "\(price)/h en direct · relais \(relay.provider.displayName) : \(relayPrice)/h"), tone: .ready)
        }
        return StepStatus(text: String(localized: "\(price)/h en direct · sans relais"), tone: .ready)
    }

    /// Relais affiché : le choix enregistré, ou tant qu'il n'y en a pas, le recommandé de l'autre fournisseur s'il a
    /// une clé active (« Aucun relais » sinon).
    private var displayedVoiceRelay: String {
        if let chosen = model.chosenVoiceRelay { return chosen.id }
        let other = model.settings.provider.other
        if model.settings.voiceRelay == AppSettings.voiceRelayOff || !model.hasKey(other) { return AppSettings.voiceRelayOff }
        return other.defaultLiveModel
    }

    private var voiceRelayPicker: some View {
        let other = model.settings.provider.other
        return Picker(String(localized: "Relais de la voix"), selection: Binding(
            get: { displayedVoiceRelay },
            set: { choice in
                guard choice == AppSettings.voiceRelayOff || model.hasKey(other) else { return }
                model.settings.voiceRelay = choice
                model.saveSettings()
            }
        )) {
            Text("Aucun relais").tag(AppSettings.voiceRelayOff)
            Section(other.displayName) {
                ForEach(ProviderCatalog.models(for: other)) { item in
                    Text(option(other.displayName, item.displayName,
                                availability(other.rawValue) ?? (item.recommended ? String(localized: "recommandé") : nil)))
                        .tag(item.id)
                        .selectionDisabled(!model.hasKey(other))
                }
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    // MARK: Étape 2 : vérification

    private var verifyStatus: StepStatus {
        guard model.settings.verifyWithFile else {
            return StepStatus(text: String(localized: "Coupée : seul le texte reçu en direct compte."), tone: .off)
        }
        let provider = model.settings.provider
        guard model.hasKey(provider) else {
            return StepStatus(text: String(localized: "Suit la voix, qui n'a pas de clé active."), tone: .warning)
        }
        let chosen = ProviderCatalog.liveModel(id: model.settings.liveModel, provider: provider)
        let price = MoneyFormat.price(chosen.batchUSDPerHour)
        return StepStatus(text: String(localized: "Même fournisseur que la voix : \(provider.displayName) \(chosen.fileDisplayName) · \(price)/h"),
                          tone: .ready)
    }

    // MARK: Étape 3 : correction

    private var correctionPicker: some View {
        CleanupModelMenu(title: String(localized: "Modèle de correction"), selection: Binding(
            get: { model.settings.cleanupChoice },
            set: { choice in
                guard choice.account.map({ model.hasKey(account: $0) }) ?? true else { return }
                model.settings.cleanupChoice = choice
                if model.settings.cleanupRelay == choice { model.settings.cleanupRelay = .off }
                model.saveSettings()
            }
        ), neutral: .automatic, neutralLabel: String(localized: "Automatique · selon tes clés"))
    }

    /// Relais de la correction : « Aucun relais » ou un modèle dont la clé est active, autre que le service principal.
    private func cleanupRelayPicker(primary: CleanupService?) -> some View {
        CleanupModelMenu(title: String(localized: "Relais de la correction"), selection: Binding(
            get: { model.displayedCleanupRelay },
            set: { choice in
                guard choice == .off || (choice.account.map { model.hasKey(account: $0) } ?? false) else { return }
                model.settings.cleanupRelay = choice
                model.saveSettings()
            }
        ), neutral: .off, neutralLabel: String(localized: "Aucun relais"),
           excluded: primary.flatMap { CleanupChoice(providerName: $0.provider, model: $0.model) })
    }

    private func correctionStatus(services: [CleanupService], speech: SpeechRequest) -> StepStatus {
        guard model.settings.cleanupEnabled else {
            return StepStatus(text: String(localized: "Coupée : le texte est collé tel que transcrit."), tone: .off)
        }
        guard let first = services.first else {
            return StepStatus(text: String(localized: "Aucune clé active pour corriger : le texte est collé tel que transcrit."), tone: .warning)
        }
        let choice = model.settings.cleanupChoice
        if let name = choice.providerName, speech.chosenCleanupKey == nil {
            let text = services.count > 1
                ? String(localized: "Pas de clé \(name) active : correction automatique par \(first.label), puis \(services[1].label) si besoin.")
                : String(localized: "Pas de clé \(name) active : correction automatique par \(first.label).")
            return StepStatus(text: text, tone: .warning)
        }
        if let name = model.settings.cleanupRelay.providerName, speech.relayCleanupKey == nil {
            return StepStatus(text: String(localized: "Maintenant : \(first.label) · relais \(name) sans clé active : ajoute-la, ou choisis « Aucun relais »."),
                              tone: .warning)
        }
        let text = services.count > 1
            ? String(localized: "Maintenant : \(first.label) · relais : \(services[1].label)")
            : String(localized: "Maintenant : \(first.label) · sans relais")
        return StepStatus(text: text, tone: .ready)
    }

    // MARK: Étape 4 : mots appris

    private enum JudgeChoice: Hashable {
        /// Le modèle de correction juge seul.
        case correction
        /// Jev (TypeSafe) note d'abord ; le modèle de correction tranche les cas douteux.
        case jev
    }

    /// Jev n'a pas d'autre usage que les mots appris : le choisir allume la clé TypeSafe, « Comme la correction » la coupe.
    private var judgePicker: some View {
        Picker(String(localized: "Modèle qui choisit les mots appris"), selection: Binding(
            get: { model.hasKey(account: APIKeys.typesafe) ? JudgeChoice.jev : .correction },
            set: { choice in
                guard model.hasStoredKey(account: APIKeys.typesafe) else { return }
                model.setKeyEnabled(APIKeys.typesafe, choice == .jev)
            }
        )) {
            Text("Comme la correction").tag(JudgeChoice.correction)
            Text(option(APIKeys.title(APIKeys.typesafe), "Jev",
                        model.hasStoredKey(account: APIKeys.typesafe) ? nil : String(localized: "aucune clé")))
                .tag(JudgeChoice.jev)
                .selectionDisabled(!model.hasStoredKey(account: APIKeys.typesafe))
        }
        .labelsHidden()
        .fixedSize()
    }

    private func learningStatus(services: [CleanupService]) -> StepStatus {
        guard model.settings.learnCorrections else {
            return StepStatus(text: String(localized: "Coupé : aucun mot n'est appris de tes corrections."), tone: .off)
        }
        if model.hasKey(account: APIKeys.typesafe) {
            let text = services.first.map { String(localized: "Jev note chaque mot ; en cas de doute, \($0.label) tranche.") }
                ?? String(localized: "Jev note chaque mot, seul : aucun modèle de correction actif.")
            return StepStatus(text: text, tone: .ready)
        }
        guard let first = services.first else {
            return StepStatus(text: String(localized: "Aucun modèle actif : aucun mot n'est appris."), tone: .warning)
        }
        return StepStatus(text: String(localized: "Maintenant : \(first.label), comme la correction."), tone: .ready)
    }

    // MARK: Libellés

    /// « xAI · Grok Voice Transcribe 2.0 · recommandé » : fournisseur, modèle, puis une précision facultative.
    private func option(_ provider: String, _ name: String, _ note: String?) -> String {
        [provider, name, note].compactMap { $0 }.joined(separator: " · ")
    }

    /// Pourquoi un fournisseur ne se choisit pas : « aucune clé » ou « clé coupée » ; nil si sa clé est active.
    private func availability(_ account: String) -> String? {
        guard !model.hasKey(account: account) else { return nil }
        return model.hasStoredKey(account: account) ? String(localized: "clé coupée") : String(localized: "aucune clé")
    }
}

/// Une étape numérotée : pastille, titre et rôle, contrôle à droite, relais au choix s'il y en a un, puis ce que
/// l'étape fait maintenant. Un trait relie la pastille à celle de l'étape suivante.
struct ModelStepRow<Control: View, Relay: View>: View {
    var number: Int
    var title: String
    var summary: String
    var status: StepStatus
    var isLast: Bool
    var relayTitle: String = ""
    @ViewBuilder var control: Control
    @ViewBuilder var relay: Relay

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                StepBadge(number: number, tone: status.tone)
                if !isLast {
                    Capsule()
                        .fill(Theme.brand.opacity(0.22))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 30)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    control
                }
                .frame(minHeight: 30)
                if Relay.self != EmptyView.self {
                    HStack(alignment: .center, spacing: 16) {
                        Label {
                            Text(relayTitle)
                        } icon: {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundStyle(Theme.brand)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        relay
                    }
                    .frame(minHeight: 26)
                }
                StepStatusLine(status: status)
            }
            .padding(.bottom, isLast ? 0 : 22)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Étape \(number) : \(title)"))
    }
}

extension ModelStepRow where Relay == EmptyView {
    init(number: Int, title: String, summary: String, status: StepStatus, isLast: Bool, @ViewBuilder control: () -> Control) {
        self.init(number: number, title: title, summary: summary, status: status, isLast: isLast, control: control, relay: { EmptyView() })
    }
}

/// Pastille numérotée d'une étape : rouge de la marque quand l'étape travaille, orange quand elle ne peut pas, grise
/// quand elle est coupée.
struct StepBadge: View {
    var number: Int
    var tone: StepStatus.Tone

    var body: some View {
        Text(verbatim: String(number))
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tone == .off ? Color.secondary : Color.white)
            .frame(width: 30, height: 30)
            .background {
                switch tone {
                case .ready:
                    Circle().fill(Theme.brand.gradient)
                case .warning:
                    Circle().fill(Color.orange.gradient)
                case .off:
                    Circle().fill(Theme.subtleFill)
                        .overlay(Circle().strokeBorder(Theme.cardBorder, lineWidth: 1))
                }
            }
            .shadow(color: shadow, radius: 5, y: 2)
            .accessibilityHidden(true)
    }

    private var shadow: Color {
        switch tone {
        case .ready: return Theme.brand.opacity(0.3)
        case .warning: return Color.orange.opacity(0.3)
        case .off: return .clear
        }
    }
}

/// Ce que l'étape fait maintenant, dans un bandeau discret ; orange quand elle ne peut pas travailler comme choisi.
struct StepStatusLine: View {
    var status: StepStatus

    var body: some View {
        Label {
            Text(status.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(status.tone == .warning ? Color.orange : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(status.tone == .warning ? Color.orange.opacity(0.12) : Theme.subtleFill)
        }
    }

    private var symbol: String {
        switch status.tone {
        case .ready: return "arrow.turn.down.right"
        case .warning: return "exclamationmark.triangle.fill"
        case .off: return "pause.circle"
        }
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
            KeySourceRow()
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
            if model.usesRemoteKeySource {
                Text("Ta source de clés se lit seulement : ajoute une clé dans ton serveur ou ton gestionnaire, puis recharge.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                AddKeyRow()
            }
            if let message = model.keysMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.dependencies.keyStore == .vault {
                Button(model.usesRemoteKeySource ? String(localized: "Recharger depuis la source") : String(localized: "Recharger depuis le coffre")) {
                    Task { await model.refreshKeys() }
                }
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
        case .vault where model.usesRemoteKeySource:
            return String(localized: "Les clés sont lues sur ta source à chaque lancement et restent en mémoire : rien n'est écrit sur ce Mac.")
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

/// Fournisseurs › Modèle local : un serveur de modèles sur ce Mac, compatible OpenAI (Ollama, LM Studio, llama.cpp…).
/// Sans clé ni coût, il corrige les dictées et lit les sujets du Profil sans que le texte quitte le Mac.
struct LocalModelSection: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    private enum Preset: String, CaseIterable, Identifiable {
        case none, ollama, lmStudio, custom
        var id: String { rawValue }
    }

    private var directory: TextModelDirectory { .shared }
    private var account: String { CleanupModel.localAccount }

    var body: some View {
        Section {
            SettingRow(text: SettingText(title: String(localized: "Serveur"),
                                         summary: String(localized: "L'app qui fait tourner le modèle sur ton Mac."))) {
                Picker(String(localized: "Serveur"), selection: Binding(get: { preset }, set: choose)) {
                    Text("Aucun").tag(Preset.none)
                    Text("Ollama").tag(Preset.ollama)
                    Text("LM Studio").tag(Preset.lmStudio)
                    Text("Autre adresse").tag(Preset.custom)
                }
                .labelsHidden()
                .fixedSize()
                if preset != .none {
                    Toggle(String(localized: "Utiliser le modèle local"), isOn: Binding(
                        get: { model.isKeyEnabled(account) },
                        set: { model.setKeyEnabled(account, $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            if preset == .custom {
                SettingRow(text: SettingText(title: String(localized: "Adresse"),
                                             summary: String(localized: "Compatible OpenAI, avec son « /v1 »."))) {
                    TextField(String(localized: "Adresse du serveur"), text: $draft, prompt: Text(verbatim: "http://localhost:8080/v1"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit { save(draft) }
                    Button(String(localized: "Enregistrer")) { save(draft) }
                        .disabled(TextCleaner.localBase(draft) == nil)
                }
            }
            if preset != .none {
                statusLine
            }
        } header: {
            Text("Modèle local")
        } footer: {
            Text("Gratuit et privé : la correction et l'analyse des sujets tournent sur ton Mac, le texte ne part nulle part. Plus lent qu'un modèle en ligne, surtout au premier appel. Lance Ollama ou LM Studio avec un modèle téléchargé, puis choisis-le dans Correction.")
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

/// Fournisseurs › Clés API › « Où sont tes clés ? » : sur ce Mac, ou lues sur un serveur ou dans un gestionnaire de
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
