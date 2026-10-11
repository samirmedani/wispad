import SwiftUI
import WispadCore

// Premier lancement guidé : chaque étape vérifie vraiment ce qu'elle annonce
// (autorisations, voix au micro, clé acceptée, touche reçue, dictée collée) avant de laisser continuer.

extension OnboardingStep {
    /// Nom court, dans la barre de progression.
    var label: String {
        switch self {
        case .welcome: return String(localized: "Bienvenue")
        case .permissions: return String(localized: "Autorisations")
        case .microphone: return String(localized: "Micro")
        case .provider: return String(localized: "Fournisseur")
        case .shortcut: return String(localized: "Touche")
        case .trial: return String(localized: "Essai")
        case .finish: return String(localized: "Fin")
        }
    }

    var title: String {
        switch self {
        case .welcome: return String(localized: "Bienvenue dans Wispad")
        case .permissions: return String(localized: "Trois autorisations macOS")
        case .microphone: return String(localized: "Teste ton micro")
        case .provider: return String(localized: "Ton fournisseur de transcription")
        case .shortcut: return String(localized: "La touche fn")
        case .trial: return String(localized: "Un vrai essai")
        case .finish: return String(localized: "Tout est prêt")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return String(localized: "Tu parles, Wispad écrit le texte là où se trouve ton curseur, dans n'importe quelle app.")
        case .permissions: return String(localized: "Toutes dès maintenant : Wispad vérifie chacune en direct.")
        case .microphone: return String(localized: "Choisis ton micro et dis quelques mots. Rien n'est enregistré ni envoyé.")
        case .provider: return String(localized: "Ta voix part directement chez ce fournisseur, avec ta clé API. Elle est vérifiée avant d'être enregistrée.")
        case .shortcut: return String(localized: "Deux gestes pour dicter. Appuie une fois sur la touche pour vérifier que Wispad la reçoit.")
        case .trial: return String(localized: "Dicte pour de vrai dans le champ ci-dessous : le texte transcrit et corrigé s'y écrit.")
        case .finish: return String(localized: "Wispad tourne dans la barre des menus. Dicte où tu veux.")
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "sparkles"
        case .permissions: return "lock.shield"
        case .microphone: return "mic.fill"
        case .provider: return "key.fill"
        case .shortcut: return "keyboard"
        case .trial: return "text.cursor"
        case .finish: return "checkmark.seal.fill"
        }
    }
}

extension PermissionKind {
    var title: String {
        switch self {
        case .microphone: return String(localized: "Microphone")
        case .accessibility: return String(localized: "Accessibilité")
        case .inputMonitoring: return String(localized: "Surveillance des entrées")
        }
    }

    /// Pourquoi, en une ligne.
    var reason: String {
        switch self {
        case .microphone: return String(localized: "Pour entendre ta voix, seulement pendant une dictée.")
        case .accessibility: return String(localized: "Pour coller le texte dans l'app où tu écris.")
        case .inputMonitoring: return String(localized: "Pour reconnaître la touche fn partout sur le Mac.")
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        }
    }

    /// Chemin exact dans Réglages Système pour l'activer.
    var settingsPath: String {
        switch self {
        case .microphone:
            return String(localized: "Réglages Système › Confidentialité et sécurité › Microphone : active Wispad.")
        case .accessibility:
            return String(localized: "Réglages Système › Confidentialité et sécurité › Accessibilité : active Wispad. Absent de la liste ? Ajoute-le avec +.")
        case .inputMonitoring:
            return String(localized: "Réglages Système › Confidentialité et sécurité › Surveillance de l'entrée : active Wispad. Absent de la liste ? Ajoute-le avec +.")
        }
    }
}

/// Textes d'un problème : ce qui ne va pas, puis la marche à suivre.
@MainActor
enum OnboardingCopy {
    static func issue(_ issue: OnboardingIssue, provider: ProviderID, keyStore: KeyStoreKind) -> (title: String, detail: String) {
        switch issue {
        case .permission(let kind, .needsRelaunch):
            return (String(localized: "Relance nécessaire : \(kind.title)"),
                    String(localized: "macOS n'applique cette autorisation qu'au prochain lancement de Wispad. La configuration reprendra ici."))
        case .permission(let kind, .denied):
            return (String(localized: "Accès refusé : \(kind.title)"), kind.settingsPath)
        case .permission(let kind, _):
            return (String(localized: "Autorisation manquante : \(kind.title)"), kind.settingsPath)
        case .noInputDevice:
            return (String(localized: "Aucun micro trouvé"),
                    String(localized: "Branche un micro ou un casque, puis réessaie."))
        case .microphoneUnavailable:
            return (String(localized: "Le micro n'a pas pu s'ouvrir"),
                    String(localized: "Choisis un autre micro ou réessaie : une autre app l'utilise peut-être."))
        case .silence:
            return (String(localized: "Aucune voix entendue"),
                    String(localized: "Vérifie que c'est le bon micro, qu'il n'est pas coupé, et que le volume d'entrée (Réglages Système › Son › Entrée) n'est pas au minimum."))
        case .key(let check):
            return key(check, provider: provider, keyStore: keyStore)
        case .noKeyEvent:
            return (String(localized: "Wispad ne reçoit pas la touche"),
                    String(localized: "Vérifie que Wispad est activé dans Réglages Système › Confidentialité et sécurité › Surveillance de l'entrée. Si tu viens de l'activer, relance Wispad."))
        case .trial(let failure):
            return trial(failure)
        }
    }

    static func key(_ check: KeyCheck, provider: ProviderID, keyStore: KeyStoreKind) -> (title: String, detail: String) {
        switch check {
        case .rejected(let status):
            return (String(localized: "Clé refusée par \(provider.displayName) (HTTP \(status))"),
                    String(localized: "Copie à nouveau la clé depuis la console du fournisseur, en entier et sans espace."))
        case .unverified(let status):
            return (String(localized: "Vérification impossible (HTTP \(status))"),
                    String(localized: "Le fournisseur n'a pas confirmé la clé. Réessaie dans un instant."))
        case .offline:
            return (String(localized: "Pas de connexion"),
                    String(localized: "La clé n'a pas pu être vérifiée. Vérifie le réseau, puis réessaie."))
        case .notSaved:
            return (String(localized: "Clé valide, mais non enregistrée"),
                    String(localized: "Impossible d'enregistrer la clé \(keyStore.place). Réessaie."))
        case .missing, .verifying, .valid:
            return ("", "")
        }
    }

    static func trial(_ failure: TrialFailure) -> (title: String, detail: String) {
        switch failure {
        case .microphone:
            return (String(localized: "Le micro ne s'est pas ouvert"),
                    String(localized: "Vérifie l'autorisation du micro et le micro choisi, puis réessaie."))
        case .key:
            return (String(localized: "Clé du fournisseur indisponible"),
                    String(localized: "Ajoute ou vérifie ta clé à l'étape Fournisseur."))
        case .network:
            return (String(localized: "Pas de connexion"),
                    String(localized: "La dictée n'a pas pu partir chez le fournisseur. Vérifie le réseau, puis réessaie."))
        case .provider:
            return (String(localized: "Le fournisseur n'a pas transcrit"),
                    String(localized: "Il a refusé ou n'a pas répondu : vérifie ta clé et le crédit de ton compte, puis réessaie."))
        case .noSpeech:
            return (String(localized: "Rien entendu"),
                    String(localized: "Maintiens fn pendant toute la phrase et parle normalement, puis relâche."))
        case .paste:
            return (String(localized: "Le texte n'est pas arrivé dans le champ"),
                    String(localized: "Clique dans le champ avant de dicter et garde Wispad au premier plan. Vérifie aussi l'autorisation Accessibilité."))
        case .cancelled:
            return (String(localized: "Dictée annulée"),
                    String(localized: "Échap annule l'écoute. Recommence quand tu veux."))
        case .storage:
            return (String(localized: "Enregistrement local impossible"),
                    String(localized: "La dictée n'a pas pu être gardée sur ce Mac. Réessaie."))
        }
    }
}

// MARK: - Écran

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    @Bindable var controller: OnboardingController

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgress(controller: controller)
                .padding(.horizontal, 40)
                .padding(.top, 36)
            ScrollView {
                VStack(spacing: 22) {
                    header
                    content
                        .id(controller.step)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            Divider().opacity(0.5)
            footer
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .animation(reduceMotion ? nil : Theme.spring, value: controller.step)
        .onAppear { controller.resume() }
        .onDisappear { controller.suspend() }
        .task(id: controller.step) {
            // Sondage léger : autorisations accordées dans Réglages Système, attentes, réussite de l'essai.
            while !Task.isCancelled {
                controller.tick()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        .onChange(of: model.coordinator.isListening) { _, listening in
            if listening { controller.dictationStarted() }
        }
        .onChange(of: model.lastCompletion) { _, _ in controller.noteTrialProgress() }
        .onChange(of: controller.trialText) { _, _ in controller.noteTrialProgress() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            if controller.step == .welcome {
                BubbleDemo()
                    .padding(.bottom, 10)
            } else {
                IconBadge(symbol: controller.step.symbol, tint: Theme.brand, size: 40)
            }
            Text(controller.step.title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
            Text(controller.step.subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 540)
        }
    }

    @ViewBuilder private var content: some View {
        switch controller.step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep(controller: controller)
        case .microphone: MicrophoneStep(controller: controller)
        case .provider: ProviderStep(controller: controller)
        case .shortcut: ShortcutStep(controller: controller)
        case .trial: TrialStep(controller: controller)
        case .finish: FinishStep(controller: controller)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if controller.step.previous != nil, controller.step != .finish {
                Button("Retour") { controller.back() }
                    .hoverFeedback()
            }
            if controller.replay {
                Button("Quitter la configuration") { model.completeOnboarding() }
                    .hoverFeedback()
            }
            Spacer()
            if controller.step.allowsLater, !controller.canContinue {
                Button("Plus tard") { controller.later() }
                    .hoverFeedback()
            }
            switch controller.step {
            case .welcome:
                Button("Commencer") { controller.advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .hoverFeedback()
            case .finish:
                Button("Terminer") { controller.finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .hoverFeedback()
            default:
                Button("Continuer") { controller.advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canContinue)
                    .hoverFeedback()
            }
        }
    }
}

// MARK: - Barre de progression

private struct OnboardingProgress: View {
    var controller: OnboardingController
    @Environment(\.interactionReduceMotion) private var reduceMotion

    private enum Marker: Equatable {
        case done, current, problem, skipped, upcoming
    }

    private func marker(_ step: OnboardingStep) -> Marker {
        if step == controller.step {
            return controller.currentStatus.issue == nil ? .current : .problem
        }
        guard step.index < controller.step.index else { return .upcoming }
        if controller.skipped.contains(step) { return .skipped }
        return !step.isChecked || controller.status(step).isSucceeded ? .done : .skipped
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                let state = marker(step)
                VStack(spacing: 6) {
                    dot(state, step: step)
                    Text(step.label)
                        .font(.system(size: 11, weight: state == .current || state == .problem ? .semibold : .regular))
                        .foregroundStyle(state == .upcoming ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minWidth: 64)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibility(step, state))
                if step != OnboardingStep.allCases.last {
                    Capsule()
                        .fill(step.index < controller.step.index ? Theme.brand.opacity(0.55) : Theme.subtleFill)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 18)
                }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : Theme.quick, value: controller.step)
    }

    @ViewBuilder private func dot(_ state: Marker, step: OnboardingStep) -> some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Color.green)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            case .current:
                Circle().fill(Theme.brand)
                Text("\(step.index + 1)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
            case .problem:
                Circle().fill(Color.red)
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            case .skipped:
                Circle().fill(Color.orange.opacity(0.18))
                Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
            case .upcoming:
                Circle().fill(Theme.subtleFill)
                Text("\(step.index + 1)").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func accessibility(_ step: OnboardingStep, _ state: Marker) -> String {
        switch state {
        case .done: return String(localized: "\(step.label) : réussi")
        case .current: return String(localized: "\(step.label) : en cours")
        case .problem: return String(localized: "\(step.label) : problème")
        case .skipped: return String(localized: "\(step.label) : plus tard")
        case .upcoming: return String(localized: "\(step.label) : à faire")
        }
    }
}

// MARK: - Composants

/// État d'une étape : à faire, en cours, réussi (✓) ou problème (✗) avec la marche à suivre.
private struct StepBanner<Actions: View>: View {
    enum Tone: Equatable {
        case waiting, working, success, problem

        var tint: Color {
            switch self {
            case .waiting: return .secondary
            case .working: return Theme.brand
            case .success: return .green
            case .problem: return .red
            }
        }
    }

    var tone: Tone
    var title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch tone {
                case .waiting:
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                case .working:
                    ProgressView().controlSize(.small)
                case .success:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .problem:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .font(.system(size: 18))
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) { actions }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.tint.opacity(tone == .waiting ? 0.06 : 0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tone.tint.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

extension StepBanner where Actions == EmptyView {
    init(tone: Tone, title: String, detail: String? = nil) {
        self.init(tone: tone, title: title, detail: detail) { EmptyView() }
    }
}

/// Bouton qui renvoie à l'étape où se règle un problème.
private struct FixStepButton: View {
    var controller: OnboardingController
    var issue: OnboardingIssue

    var body: some View {
        if let target = OnboardingFlow.stepToFix(issue), target != controller.step {
            Button(String(localized: "Revoir l'étape « \(target.label) »")) { controller.go(to: target) }
                .hoverFeedback()
        }
    }
}

/// La bulle de dictée en miniature : verre noir et spectre de la voix. Immobile si « réduire les animations ».
private struct BubbleDemo: View {
    @Environment(\.interactionReduceMotion) private var reduceMotion
    private static let bars = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0.6 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<Self.bars, id: \.self) { index in
                    Capsule()
                        .fill(index == Self.bars / 2 ? OverlayStyle.red : Color.white.opacity(0.92))
                        .frame(width: 3.5, height: 6 + 20 * height(index, time: time))
                }
            }
            .frame(width: 168, height: 44)
            .background(Capsule().fill(OverlayStyle.background))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .accessibilityHidden(true)
    }

    /// Graves au centre, comme la vraie bulle ; une respiration lente qui évoque la parole.
    private func height(_ index: Int, time: Double) -> Double {
        let center = Double(Self.bars - 1) / 2
        let distance = abs(Double(index) - center) / center
        let envelope = 1 - 0.65 * distance
        let wave = 0.5 + 0.5 * sin(time * 5.2 + Double(index) * 0.9) * sin(time * 1.3 + Double(index) * 0.35)
        return max(0.08, envelope * wave)
    }
}

// MARK: - Étapes

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WelcomeLine(symbol: "checklist", text: String(localized: "Quelques minutes pour tout vérifier : autorisations, micro, clé, touche, puis une vraie dictée."))
            WelcomeLine(symbol: "lock.shield", text: String(localized: "Ta voix part directement chez le fournisseur de ton choix, sans passer par un serveur de Wispad."))
            WelcomeLine(symbol: "heart", text: String(localized: "Gratuit et open source. Tu paies tes fournisseurs directement."))
        }
        .padding(18)
        .card()
    }
}

private struct WelcomeLine: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: symbol, tint: Theme.brand, size: 26)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionsStep: View {
    @Environment(AppModel.self) private var model
    var controller: OnboardingController

    var body: some View {
        let status = controller.status(.permissions)
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    OnboardingPermissionRow(controller: controller, kind: kind)
                    if kind != PermissionKind.allCases.last { Divider().padding(.leading, 52) }
                }
            }
            .padding(.vertical, 6)
            .card()
            switch status {
            case .succeeded:
                StepBanner(tone: .success, title: String(localized: "Toutes les autorisations sont accordées"))
            case .failed(let issue):
                let text = OnboardingCopy.issue(issue, provider: model.settings.provider, keyStore: model.dependencies.keyStore)
                StepBanner(tone: .problem, title: text.title, detail: text.detail) {
                    if PermissionsCheck.needsRelaunch(controller.permissions) {
                        Button("Relancer Wispad") { controller.relaunch() }
                            .buttonStyle(.borderedProminent)
                            .hoverFeedback()
                    }
                }
            case .inProgress:
                StepBanner(tone: .working, title: String(localized: "En attente de Réglages Système"),
                           detail: String(localized: "Active Wispad dans le panneau ouvert, puis reviens ici : l'état se met à jour tout seul."))
            case .todo:
                StepBanner(tone: .waiting, title: String(localized: "Clique sur Autoriser pour chacune"),
                           detail: String(localized: "macOS affiche sa demande ou ouvre le bon panneau de Réglages Système."))
            }
        }
    }
}

private struct OnboardingPermissionRow: View {
    var controller: OnboardingController
    var kind: PermissionKind

    var body: some View {
        let state = controller.permissions[kind] ?? .notRequested
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                IconBadge(symbol: kind.symbol, tint: state == .granted ? .green : (state == .denied ? .red : .orange), size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.system(size: 13, weight: .semibold))
                    Text(kind.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                chip(state)
                action(state)
            }
            if state == .waiting || state == .denied {
                Text(kind.settingsPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 42)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func chip(_ state: PermissionState) -> some View {
        switch state {
        case .granted: return StatusChip(text: String(localized: "Autorisé"), tint: .green)
        case .notRequested: return StatusChip(text: String(localized: "À autoriser"), tint: .secondary)
        case .waiting: return StatusChip(text: String(localized: "En attente"), tint: .orange)
        case .denied: return StatusChip(text: String(localized: "Refusé"), tint: .red)
        case .needsRelaunch: return StatusChip(text: String(localized: "Relance nécessaire"), tint: .orange)
        }
    }

    @ViewBuilder private func action(_ state: PermissionState) -> some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .notRequested:
            Button("Autoriser") { controller.request(kind) }
                .buttonStyle(.borderedProminent)
                .hoverFeedback()
        case .waiting, .denied:
            Button("Ouvrir Réglages Système") { controller.openSettings(kind) }
                .hoverFeedback()
        case .needsRelaunch:
            Button("Relancer Wispad") { controller.relaunch() }
                .hoverFeedback()
        }
    }
}

private struct MicrophoneStep: View {
    @Environment(AppModel.self) private var model
    var controller: OnboardingController

    var body: some View {
        let status = controller.status(.microphone)
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Micro", selection: Binding(
                    get: { controller.effectiveMicrophoneUID ?? "" },
                    set: { controller.selectMicrophone($0) }
                )) {
                    Text(systemLabel).tag("")
                    ForEach(controller.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                LevelMeter(fraction: SignalLevel.meterFraction(controller.level), voiced: controller.detector.detected)
                HStack(spacing: 8) {
                    ProgressView(value: controller.detector.progress)
                        .tint(controller.detector.detected ? .green : Theme.brand)
                        .frame(maxWidth: 160)
                    Text(controller.detector.detected ? String(localized: "Voix détectée") : String(localized: "Voix à détecter"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Label("Le test reste sur ce Mac : seul le niveau du son est lu, rien n'est enregistré ni envoyé.", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .card()
            switch status {
            case .succeeded:
                StepBanner(tone: .success, title: String(localized: "Ta voix est bien captée"),
                           detail: String(localized: "Ce micro servira à chaque dictée. Tu peux en changer dans Réglages."))
            case .failed(let issue):
                let text = OnboardingCopy.issue(issue, provider: model.settings.provider, keyStore: model.dependencies.keyStore)
                StepBanner(tone: .problem, title: text.title, detail: text.detail) {
                    Button("Réessayer") { controller.startMicrophoneTest() }
                        .hoverFeedback()
                    FixStepButton(controller: controller, issue: issue)
                }
            case .inProgress, .todo:
                StepBanner(tone: .working, title: String(localized: "Dis quelques mots…"),
                           detail: String(localized: "Par exemple : « Bonjour Wispad, je teste mon micro. »"))
            }
        }
    }

    private var systemLabel: String {
        guard let name = controller.systemInput?.name else { return String(localized: "Micro du système") }
        return String(localized: "Micro du système (\(name))")
    }
}

/// Vumètre réel : un segment par tranche de niveau, vert quand une voix est reconnue.
private struct LevelMeter: View {
    var fraction: Double
    var voiced: Bool
    @Environment(\.interactionReduceMotion) private var reduceMotion
    private static let segments = 28

    var body: some View {
        let lit = Int((fraction * Double(Self.segments)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<Self.segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < lit ? color(index) : Theme.subtleFill)
                    .frame(height: 22)
            }
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: lit)
        .accessibilityElement()
        .accessibilityLabel(Text("Niveau du micro"))
        .accessibilityValue(Text(verbatim: "\(Int((fraction * 100).rounded())) %"))
    }

    private func color(_ index: Int) -> Color {
        if index >= Self.segments - 3 { return .red }
        if index >= Self.segments - 8 { return .orange }
        return voiced ? .green : Theme.brand
    }
}

private struct ProviderStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    var controller: OnboardingController

    var body: some View {
        let status = controller.status(.provider)
        let provider = model.settings.provider
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Fournisseur", selection: Binding(
                    get: { model.settings.provider },
                    set: { chosen in
                        withAnimation(reduceMotion ? nil : Theme.spring) { model.selectProvider(chosen) }
                        controller.checkStoredKeys()
                    }
                )) {
                    ForEach(ProviderID.allCases) { item in
                        Text(item == .xai ? String(localized: "\(item.displayName) · recommandé") : item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(ProviderCatalog.liveModel(id: model.settings.liveModel, provider: provider).localizedCostSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Divider()
                OnboardingKeyField(controller: controller, account: provider.rawValue, title: String(localized: "Clé \(provider.displayName)"),
                                   createURL: OnboardingKeyField.createURL(provider.rawValue))
            }
            .padding(18)
            .card()
            switch status {
            case .succeeded:
                StepBanner(tone: .success, title: String(localized: "Clé \(provider.displayName) valide"),
                           detail: String(localized: "Vérifiée auprès de \(provider.displayName), et enregistrée \(model.dependencies.keyStore.place)."))
            case .failed(let issue):
                let text = OnboardingCopy.issue(issue, provider: provider, keyStore: model.dependencies.keyStore)
                StepBanner(tone: .problem, title: text.title, detail: text.detail)
            case .inProgress:
                StepBanner(tone: .working, title: String(localized: "Vérification auprès de \(provider.displayName)…"))
            case .todo:
                StepBanner(tone: .waiting, title: String(localized: "Colle ta clé \(provider.displayName)"),
                           detail: String(localized: "Pas encore de clé ? Crée-la dans la console du fournisseur avec le lien ci-dessus."))
            }
            CorrectionCard(controller: controller)
        }
    }
}

/// Correction facultative : mêmes clés vérifiées, et les réglages de contexte proposés au premier lancement.
private struct CorrectionCard: View {
    @Environment(AppModel.self) private var model
    var controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Correction du texte").font(.system(size: 13, weight: .semibold))
                StatusChip(text: String(localized: "Facultative"), tint: .secondary)
                Spacer()
                Toggle("Corriger le texte", isOn: binding(\.cleanupEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text("Ponctuation, majuscules, « euh » et reprises retirés. Sans clé de correction, le fournisseur de voix s'en charge.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.settings.cleanupEnabled {
                OnboardingKeyField(controller: controller, account: CleanupModel.deepSeekAccount,
                                   title: String(localized: "Clé DeepSeek · la moins chère"),
                                   createURL: OnboardingKeyField.createURL(CleanupModel.deepSeekAccount))
                if model.settings.provider != .openAI {
                    OnboardingKeyField(controller: controller, account: ProviderID.openAI.rawValue,
                                       title: String(localized: "Clé OpenAI · relais"),
                                       createURL: OnboardingKeyField.createURL(ProviderID.openAI.rawValue))
                }
                Divider()
                Toggle("Comprendre le sujet grâce à la fenêtre active", isOn: binding(\.useWindowContext))
                Text("La fin de la conversation visible (2 000 caractères au plus) et tes dernières dictées dans la même app partent avec la dictée chez le service de correction. Rien n'est enregistré ni journalisé.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Apprendre de mes corrections", isOn: binding(\.learnCorrections))
            }
        }
        .padding(18)
        .card()
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.saveSettings() }
        )
    }
}

/// Saisie d'une clé, vérifiée chez le fournisseur avant d'être enregistrée (même chemin que Fournisseurs).
private struct OnboardingKeyField: View {
    @Environment(AppModel.self) private var model
    var controller: OnboardingController
    var account: String
    var title: String
    var createURL: URL?
    @State private var replacing = false

    /// Page de création de clé de chaque fournisseur.
    static func createURL(_ account: String) -> URL? {
        switch account {
        case ProviderID.xai.rawValue: return URL(string: "https://console.x.ai")
        case ProviderID.openAI.rawValue: return URL(string: "https://platform.openai.com/api-keys")
        case CleanupModel.deepSeekAccount: return URL(string: "https://platform.deepseek.com/api_keys")
        default: return nil
        }
    }

    var body: some View {
        let check = controller.keyCheck(account)
        let verifying = check == .verifying
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .medium))
                chip(check)
                Spacer()
                if let createURL {
                    Link(destination: createURL) {
                        Label("Créer une clé", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12))
                    }
                    .hoverFeedback()
                }
            }
            if check == .valid, !replacing {
                Button("Remplacer la clé") { replacing = true }
                    .font(.system(size: 12))
                    .hoverFeedback()
            } else {
                HStack {
                    SecureField(title, text: Binding(
                        get: { model.keyDrafts[account] ?? "" },
                        set: { model.keyDrafts[account] = $0 }
                    ), prompt: Text("Colle la clé ici"))
                    .labelsHidden()
                    .onSubmit { verify() }
                    Button(verifying ? String(localized: "Vérification…") : String(localized: "Vérifier")) { verify() }
                        .buttonStyle(.borderedProminent)
                        .hoverFeedback()
                        .disabled(verifying || (model.keyDrafts[account] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func verify() {
        Task {
            await model.verifyAndStoreKey(account)
            if model.keyChecks[account] == .valid { replacing = false }
        }
    }

    private func chip(_ check: KeyCheck) -> some View {
        switch check {
        case .valid: return StatusChip(text: String(localized: "Valide"), tint: .green)
        case .verifying: return StatusChip(text: String(localized: "Vérification…"), tint: .orange)
        case .missing: return StatusChip(text: String(localized: "Absente"), tint: .secondary)
        case .rejected: return StatusChip(text: String(localized: "Refusée"), tint: .red)
        case .unverified, .offline: return StatusChip(text: String(localized: "Non vérifiée"), tint: .orange)
        case .notSaved: return StatusChip(text: String(localized: "Non enregistrée"), tint: .red)
        }
    }
}

private struct ShortcutStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.interactionReduceMotion) private var reduceMotion
    var controller: OnboardingController

    var body: some View {
        let status = controller.status(.shortcut)
        let probe = controller.probe
        let key = KeyLabels.describe(keyCode: model.settings.keyCode, modifiers: model.settings.modifierFlags)
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                GestureCard(keys: [key], title: String(localized: "Maintenir"),
                            detail: String(localized: "Dictée tant que tu tiens la touche ; relâche pour écrire."),
                            seen: probe.sawHold)
                GestureCard(keys: [key, key], title: String(localized: "Double appui"),
                            detail: String(localized: "Mains libres ; un appui de plus arrête et écrit."),
                            seen: probe.sawHandsFree)
            }
            HStack(spacing: 14) {
                Text(key)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .frame(width: 64, height: 52)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(probe.presses > 0 ? Color.green.opacity(0.18) : Theme.raised)
                            .shadow(color: .black.opacity(0.18), radius: 0, y: 2)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(probe.presses > 0 ? Color.green : Theme.cardBorder, lineWidth: probe.presses > 0 ? 2 : 1)
                    }
                    .scaleEffect(probe.presses > 0 && !reduceMotion ? 1.04 : 1)
                    .animation(reduceMotion ? nil : Theme.spring, value: probe.presses)
                VStack(alignment: .leading, spacing: 4) {
                    Text(probe.presses > 0 ? String(localized: "Appuis reçus : \(probe.presses)") : String(localized: "Appuie une fois sur \(key)"))
                        .font(.system(size: 13, weight: .semibold))
                    Text("Pendant ce test, aucune dictée ne démarre : Wispad vérifie seulement qu'il reçoit la touche.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .card()
            switch status {
            case .succeeded:
                StepBanner(tone: .success, title: String(localized: "Touche détectée"),
                           detail: String(localized: "Essaie aussi de la maintenir ou de l'appuyer deux fois : chaque geste reconnu s'allume ci-dessus."))
            case .failed(let issue):
                let text = OnboardingCopy.issue(issue, provider: model.settings.provider, keyStore: model.dependencies.keyStore)
                StepBanner(tone: .problem, title: text.title, detail: fnDetail(text.detail)) {
                    if controller.fnSettingMatters {
                        Button("Ouvrir Réglages Clavier") { controller.openKeyboardSettings() }
                            .hoverFeedback()
                    }
                    if PermissionsCheck.needsRelaunch(controller.permissions) {
                        Button("Relancer Wispad") { controller.relaunch() }
                            .hoverFeedback()
                    }
                    FixStepButton(controller: controller, issue: issue)
                }
            case .inProgress, .todo:
                StepBanner(tone: .waiting, title: String(localized: "En attente de la touche…"),
                           detail: controller.fnSettingMatters
                               ? String(localized: "Conseil : dans Réglages Système › Clavier, règle « Touche fn/🌐 » sur « Ne rien faire ».")
                               : nil)
            }
        }
    }

    private func fnDetail(_ detail: String) -> String {
        guard controller.fnSettingMatters else { return detail }
        return detail + " " + String(localized: "Dans Réglages Système › Clavier, règle aussi « Touche fn/🌐 » sur « Ne rien faire ».")
    }
}

private struct GestureCard: View {
    var keys: [String]
    var title: String
    var detail: String
    var seen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(label: key) }
                Spacer()
                if seen {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Reconnu"))
                }
            }
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct TrialStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var controller: OnboardingController
    @FocusState private var focused: Bool

    var body: some View {
        let status = controller.status(.trial)
        let key = KeyLabels.describe(keyCode: model.settings.keyCode, modifiers: model.settings.modifierFlags)
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label(String(localized: "Clique dans le champ, maintiens \(key), dis la phrase, puis relâche."), systemImage: "hand.point.up.left")
                    .font(.system(size: 13, weight: .medium))
                Text("« Salut, je teste Wispad, euh non, je dicte mon premier message. »")
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .italic()
                    .foregroundStyle(Theme.brand)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $controller.trialText)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(10)
                    .frame(height: 120)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(focused ? Theme.brand.opacity(0.6) : Theme.cardBorder, lineWidth: focused ? 2 : 1)
                    }
                    .accessibilityLabel(Text("Champ d'essai"))
            }
            .padding(18)
            .card()
            switch status {
            case .succeeded:
                StepBanner(tone: .success, title: String(localized: "Bravo, tout marche !"), detail: summary) {
                    Button("Dicter encore") { retry() }
                        .hoverFeedback()
                }
            case .failed(let issue):
                let text = OnboardingCopy.issue(issue, provider: model.settings.provider, keyStore: model.dependencies.keyStore)
                StepBanner(tone: .problem, title: text.title, detail: text.detail) {
                    Button("Réessayer") { retry() }
                        .buttonStyle(.borderedProminent)
                        .hoverFeedback()
                    FixStepButton(controller: controller, issue: issue)
                }
            case .inProgress:
                StepBanner(tone: .working, title: model.coordinator.isListening
                           ? String(localized: "Je t'écoute…")
                           : String(localized: "Transcription et correction…"))
            case .todo:
                StepBanner(tone: .waiting, title: String(localized: "Prêt : maintiens \(key) et parle"),
                           detail: String(localized: "Ou appuie deux fois pour dicter mains libres, puis une fois pour arrêter."))
            }
        }
        .onAppear { focused = true }
    }

    private var summary: String? {
        guard let summary = controller.trialSummary else { return nil }
        let words = summary.words == 1 ? String(localized: "1 mot") : String(localized: "\(summary.words) mots")
        guard summary.seconds > 0 else { return words }
        let seconds = summary.seconds.formatted(.number.precision(.fractionLength(1)).locale(appLocale))
        return String(localized: "\(words) · \(seconds) s de parole. Tu peux dicter partout sur ton Mac.")
    }

    private func retry() {
        controller.retryTrial()
        focused = true
    }
}

private struct FinishStep: View {
    @Environment(AppModel.self) private var model
    var controller: OnboardingController

    var body: some View {
        let key = KeyLabels.describe(keyCode: model.settings.keyCode, modifiers: model.settings.modifierFlags)
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                GestureCard(keys: [key], title: String(localized: "Maintenir"),
                            detail: String(localized: "Pour une phrase : parle en tenant la touche, relâche pour écrire."), seen: false)
                GestureCard(keys: [key, key], title: String(localized: "Double appui"),
                            detail: String(localized: "Mains libres, pour un long texte : un appui arrête. Échap annule."), seen: false)
            }
            if !controller.skipped.isEmpty {
                let names = OnboardingStep.allCases.filter { controller.skipped.contains($0) }.map(\.label).joined(separator: ", ")
                StepBanner(tone: .waiting, title: String(localized: "Étapes laissées pour plus tard : \(names)"),
                           detail: String(localized: "Tu pourras les refaire avec Réglages › Revoir la configuration."))
            }
            HStack {
                Button("Ouvrir les Réglages") { controller.finish(openSettings: true) }
                    .hoverFeedback()
                Spacer()
            }
        }
    }
}
