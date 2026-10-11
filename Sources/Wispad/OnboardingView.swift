import SwiftUI
import WispadCore

/// Étapes du premier lancement, dans l'ordre.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case voice
    case correction
    case privacy
    case permissions
    case tryIt

    var title: String {
        switch self {
        case .welcome: return String(localized: "Bienvenue dans Wispad")
        case .voice: return String(localized: "Transcription de ta voix")
        case .correction: return String(localized: "Correction du texte")
        case .privacy: return String(localized: "Ce que Wispad envoie")
        case .permissions: return String(localized: "Autorisations macOS")
        case .tryIt: return String(localized: "Essaie maintenant")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return String(localized: "Dicte partout sur ton Mac : maintiens fn, parle, relâche. Le texte s'écrit là où tu tapes.")
        case .voice: return String(localized: "Chez le fournisseur de ton choix, avec ta clé API.")
        case .correction: return String(localized: "Ponctuation, majuscules, « euh » et reprises retirés. Facultative.")
        case .privacy: return String(localized: "Plus de contexte rend la correction plus juste. Tu choisis.")
        case .permissions: return String(localized: "Trois autorisations pour écouter le raccourci, ouvrir le micro et coller le texte.")
        case .tryIt: return String(localized: "Clique dans le champ, maintiens fn et dis une phrase.")
        }
    }
}

/// Premier lancement guidé. Chaque étape réutilise les réglages et composants de l'app : rien n'est dupliqué.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep
    @State private var trial = ""
    @State private var dictationsAtStart = 0

    init(step: OnboardingStep = .welcome) {
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 40)
                .padding(.top, 44)
            content
                .frame(maxWidth: 720, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
            footer
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .task(id: step) {
            if step == .tryIt { dictationsAtStart = model.history.count }
            // Les autorisations accordées dans Réglages Système sont relues sans recharger l'écran.
            while step == .permissions, !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            if step == .welcome {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
            }
            Text(step.title)
                .font(.system(size: 26, weight: .bold))
            Text(step.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .animation(reduceMotion ? nil : Theme.quick, value: step)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            Form {
                Section {
                    FeatureLine(symbol: "keyboard", text: String(localized: "Double appui sur fn pour dicter les mains libres, un appui l'arrête. Maintiens fn pour une dictée courte, Échap pour annuler."))
                    FeatureLine(symbol: "lock.shield", text: String(localized: "Ta voix part directement chez le fournisseur de ton choix, sans passer par un serveur de Wispad."))
                    FeatureLine(symbol: "arrow.uturn.backward", text: String(localized: "Tu te reprends ? « mardi, ah non, mercredi » devient « mercredi »."))
                    FeatureLine(symbol: "heart", text: String(localized: "Gratuit et open source. Tu paies tes fournisseurs directement."))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .voice:
            Form {
                TranscriptionSection()
                Section {
                    APIKeyRow(account: model.settings.provider.rawValue, title: model.settings.provider.displayName,
                              purpose: String(localized: "Clé créée dans la console de \(model.settings.provider.displayName)"))
                } header: {
                    Text("Clé API")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .correction:
            Form {
                CorrectionSection()
                Section {
                    APIKeyRow(account: CleanupModel.deepSeekAccount, title: "DeepSeek", purpose: String(localized: "La correction la moins chère, environ 0,0001 $ par dictée"))
                    if model.settings.provider != .openAI {
                        APIKeyRow(account: ProviderID.openAI.rawValue, title: "OpenAI", purpose: String(localized: "Relais de correction"))
                    }
                } header: {
                    Text("Clés de correction")
                }
                Section {
                    Toggle("Corriger le texte avant de l'insérer", isOn: binding(\.cleanupEnabled))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .privacy:
            Form {
                Section {
                    Toggle("Comprendre le sujet grâce à la fenêtre active", isOn: binding(\.useWindowContext))
                    Text("La fin de la conversation visible (2 000 caractères au plus) et tes dernières dictées dans la même app partent avec la dictée chez le service de correction : noms, nombres et sujet sont mieux écrits. Rien n'est enregistré ni journalisé.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Contexte")
                }
                Section {
                    Toggle("Apprendre de mes corrections", isOn: binding(\.learnCorrections))
                    Text("Si tu corriges un nom mal entendu juste après une dictée, Wispad propose de l'ajouter à ton dictionnaire. Seuls le mot corrigé et la phrase dictée sont envoyés.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Dictionnaire")
                }
                Section {
                    Text("L'historique et l'audio restent sur ce Mac. Aucune donnée ne passe par Wispad : tes appels vont directement aux fournisseurs que tu as choisis.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .permissions:
            Form {
                Section {
                    PermissionRow(symbol: "keyboard", title: String(localized: "Surveillance des entrées"),
                                  detail: model.inputMonitoringTrusted ? String(localized: "Autorisée") : String(localized: "Pour reconnaître le raccourci fn"),
                                  granted: model.inputMonitoringTrusted) {
                        PermissionCenter.requestInputMonitoring()
                        model.hotkeys?.installTap()
                        model.refreshPermissions()
                    }
                    PermissionRow(symbol: "mic.fill", title: String(localized: "Microphone"),
                                  detail: model.microphoneStatus == .authorized ? String(localized: "Autorisé") : String(localized: "Ouvert seulement pendant une dictée"),
                                  granted: model.microphoneStatus == .authorized) {
                        Task {
                            _ = await PermissionCenter.requestMicrophone()
                            model.refreshPermissions()
                        }
                    }
                    PermissionRow(symbol: "accessibility", title: String(localized: "Accessibilité"),
                                  detail: model.accessibilityTrusted ? String(localized: "Autorisée") : String(localized: "Pour coller le texte dans l'app où tu écris"),
                                  granted: model.accessibilityTrusted) {
                        _ = PermissionCenter.accessibilityTrusted(prompt: true)
                        model.refreshPermissions()
                    }
                } footer: {
                    Text("macOS ouvre Réglages Système pour les deux dernières : active Wispad dans la liste, puis reviens ici.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .tryIt:
            VStack(spacing: 14) {
                TextEditor(text: $trial)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(height: 140)
                    .card()
                if model.history.count > dictationsAtStart {
                    Label("Ça marche ! Tu peux dicter partout.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let warning = model.setupWarning {
                    Label("\(warning) : reviens à l'étape concernée.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Essaie : « Bonjour, je teste Wispad, euh, non, je dicte mon premier message. »")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var footer: some View {
        HStack {
            if let previous = OnboardingStep(rawValue: step.rawValue - 1) {
                Button("Retour") { go(previous) }
                    .hoverFeedback()
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == step ? Theme.brand : Theme.subtleFill)
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            if let next = OnboardingStep(rawValue: step.rawValue + 1) {
                if step == .voice || step == .permissions {
                    Button("Plus tard") { go(next) }
                        .hoverFeedback()
                }
                Button("Continuer") { go(next) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .hoverFeedback()
            } else {
                Button("Terminer") { model.completeOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .hoverFeedback()
            }
        }
    }

    private func go(_ next: OnboardingStep) {
        withAnimation(reduceMotion ? nil : Theme.spring) { step = next }
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.saveSettings() }
        )
    }
}

private struct FeatureLine: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: symbol, tint: Theme.brand, size: 28)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
