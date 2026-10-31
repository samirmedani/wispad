import AppKit
import SwiftUI
import WispadCore

// MARK: - Réglages › Aide › Aide et retours

/// Aide et retours : signaler un problème (et copier le diagnostic à coller dans le ticket), faire enquêter son agent IA,
/// proposer une idée, poser une question. Les pages GitHub s'ouvrent dans le navigateur ; les copies vont dans le
/// presse-papiers, avec un message en bas de la fenêtre. Wispad n'envoie rien lui-même.
struct HelpSection: View {
    @Environment(AppModel.self) private var model
    @State private var preparing: HelpCopy?

    var body: some View {
        Section {
            LabeledContent {
                copyButton(.diagnostic)
            } label: {
                pageLink(.reportProblem)
                Text(HelpText.reportSummary)
            }
            LabeledContent {
                copyButton(.agentPrompt)
            } label: {
                Label(HelpText.agentTitle, systemImage: "sparkles")
                Text(HelpText.agentSummary)
            }
            pageLink(.proposeIdea)
            pageLink(.askQuestion)
        } header: {
            SectionTitle(title: SettingsPresentation.helpTitle, summary: SettingsPresentation.helpSummary)
        }
    }

    private func pageLink(_ page: HelpPage) -> some View {
        Button {
            page.open()
        } label: {
            Label(page.title, systemImage: page.symbol)
        }
        .buttonStyle(.link)
        .hoverFeedback()
    }

    private func copyButton(_ kind: HelpCopy) -> some View {
        Button {
            copy(kind)
        } label: {
            Label(preparing == kind ? String(localized: "Préparation…") : kind.title, systemImage: "doc.on.doc")
        }
        .disabled(preparing != nil)
        .hoverFeedback()
        .help(kind.help)
    }

    private func copy(_ kind: HelpCopy) {
        guard preparing == nil else { return }
        preparing = kind
        Task {
            switch kind {
            case .diagnostic: await model.copyDiagnostic()
            case .agentPrompt: await model.copyAgentPrompt()
            }
            preparing = nil
        }
    }
}

enum HelpCopy: Equatable {
    case diagnostic
    case agentPrompt

    var title: String {
        switch self {
        case .diagnostic: return String(localized: "Copier le diagnostic")
        case .agentPrompt: return String(localized: "Copier le prompt")
        }
    }

    var help: String {
        switch self {
        case .diagnostic: return String(localized: "Le même rapport que « Exporter le diagnostic… », prêt à coller dans un ticket.")
        case .agentPrompt: return String(localized: "Des consignes et le diagnostic, à coller dans ton agent IA.")
        }
    }
}

/// Textes de la section, à part de la vue pour être testés.
enum HelpText {
    static let reportSummary = String(localized: "Un ticket public sur GitHub. Colles-y le diagnostic : il ne contient rien de dicté.")
    static let agentTitle = String(localized: "Enquêter avec ton agent IA")
    static let agentSummary = String(localized: "Pour Codex, Claude Code… : il cherche la cause sur ce Mac et prépare avec toi un ticket anonyme.")
}

extension AppModel {
    /// Réglages › Aide › Copier le diagnostic : le rapport de l'export, prêt à coller dans un ticket.
    func copyDiagnostic() async {
        let report = await diagnosticReport()
        dependencies.copyText(AppDiagnostics.clipboardText(report))
        statusBanner = String(localized: "Diagnostic copié : colle-le dans ton ticket.")
    }

    /// Réglages › Aide › Copier le prompt : consignes pour un agent IA, diagnostic compris.
    func copyAgentPrompt() async {
        let context = AgentHelpPrompt.context(model: self)
        let report = await diagnosticReport()
        dependencies.copyText(AgentHelpPrompt.make(context, report: report))
        statusBanner = String(localized: "Prompt copié : colle-le dans Codex, Claude Code ou ton agent IA.")
    }

    /// Autorisations relues sur place, comme pour l'export : le rapport montre l'état du moment.
    private func diagnosticReport() async -> DiagnosticReport {
        refreshPermissions()
        return await AppDiagnostics.report(snapshot: AppDiagnostics.snapshot(model: self), store: store)
    }
}

// MARK: - Prompt pour un agent IA

/// « Enquêter avec ton agent IA » : un prompt à coller dans Codex, Claude Code ou un autre agent. Il dit où regarder sur
/// ce Mac (journaux de Wispad, latence.log, diagnostic joint), ce qu'il ne faut jamais lire (dictées, audio, clés),
/// comment chercher la cause, puis comment préparer un ticket GitHub anonyme, publié seulement avec l'accord de
/// l'utilisateur. N'y entrent que les versions de Wispad et de macOS, le type de Mac, le fournisseur de voix et le
/// rapport de diagnostic (sans texte dicté, audio, contexte, chemin ni clé).
enum AgentHelpPrompt {
    struct Context: Equatable {
        /// « 0.7.7 · 1e861a2 », comme le champ du formulaire de bug.
        var version: String
        /// « macOS 26.0.1 ».
        var macOS: String
        /// « Apple Silicon » ou « Intel ».
        var mac: String
        /// Fournisseur de voix : « xAI », « OpenAI ».
        var voice: String
        /// Formulaire de bug prérempli (version de Wispad et de macOS).
        var bugReportURL: URL
    }

    @MainActor
    static func context(model: AppModel, status: BuildStatus = .shared,
                        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Context {
        let version = [status.version?.trimmingCharacters(in: .whitespacesAndNewlines), status.commit]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return Context(
            version: version.isEmpty ? "—" : version,
            macOS: "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            mac: AppDiagnostics.macKind,
            voice: model.settings.provider.displayName,
            bugReportURL: status.bugReportURL(system: system)
        )
    }

    static func make(_ context: Context, report: DiagnosticReport) -> String {
        let repository = BuildFreshnessCheck.repository
        let subsystem = AppIdentity.bundleID
        let json = AppDiagnostics.fitted(report).json
        let fence = "```"
        return """
        \(String(localized: "Aide-moi à comprendre un problème avec Wispad, l'app de dictée vocale open source pour macOS (https://github.com/\(repository)), puis à le signaler à ses développeurs."))

        \(String(localized: "Le problème : [décris ici ce qui se passe, ce que tu faisais et depuis quand]"))
        \(String(localized: "Si je n'ai rien décrit, demande-le-moi d'abord."))

        \(String(localized: "Ce Mac : Wispad \(context.version), \(context.macOS), \(context.mac). Voix : \(context.voice)."))

        \(String(localized: "Règles, à chaque étape :"))
        - \(String(localized: "Dans ~/Library/Application Support/Wispad, lis seulement latence.log. La base wispad.sqlite, les dossiers Audio et benchmarks et le fichier api-keys.json contiennent mes dictées et mes clés : n'y touche pas, et ne me demande aucune clé API."))
        - \(String(localized: "Ne change rien sur ce Mac sans mon accord : ni réglage, ni autorisation, ni fichier."))
        - \(String(localized: "Le ticket sera public : rien de personnel ne doit y entrer (étape 5)."))

        \(String(localized: "1. Rassemble les faits"))
        - \(String(localized: "Journaux de Wispad, sans texte dicté : /usr/bin/log show --last 1h --style compact --predicate 'subsystem == \"\(subsystem)\"'. Remonte plus loin (--last 6h, --last 1d) si le problème est plus ancien. Catégories : raccourci, audio, transcription, insertion, bulle, cles, stockage, reglages, apprentissage, seconde-ecoute, mise-a-jour, migration."))
        - \(String(localized: "latence.log : une ligne par dictée, sans texte, avec les délais entre l'appui, la bulle, le micro et le collage."))
        - \(String(localized: "Le diagnostic à la fin de ce message : autorisations (micro, accessibilité, surveillance de l'entrée), écoute du raccourci, bulle, état de la dictée, fournisseur de voix, correction et sons ; pour les dernières tentatives de dictée, l'origine, le résultat, la durée de chaque étape et les services appelés, relais compris."))
        - \(String(localized: "Autorisations : Réglages Système › Confidentialité et sécurité › Microphone, Accessibilité et Surveillance de l'entrée."))
        - \(String(localized: "Pour un autre réglage, demande-moi de le lire dans Wispad (Réglages, Fournisseurs)."))
        - \(String(localized: "Une version plus récente corrige peut-être déjà le problème : \(ReleaseCheck.releasesURL.absoluteString)"))

        \(String(localized: "2. Trouve la cause"))
        \(String(localized: "Compare ce que je décris avec les journaux, latence.log et le diagnostic : heure, autorisation manquante, raccourci qui n'écoute plus, service en échec, relais, délai anormal. Explique-moi simplement ce que tu as trouvé et ce que je peux essayer, et attends mon accord avant d'agir."))

        \(String(localized: "3. Vérifie que le problème n'est pas déjà signalé"))
        \(String(localized: "gh issue list --repo \(repository) --state all --search \"<mots-clés>\", ou https://github.com/\(repository)/issues. S'il l'est déjà, propose-moi d'y ajouter mes informations plutôt que d'ouvrir un nouveau ticket."))

        \(String(localized: "4. Prépare le ticket, en français ou en anglais, sur le modèle du formulaire de bug"))
        - \(String(localized: "Titre : court et précis."))
        - \(String(localized: "Ce qui se passe."))
        - \(String(localized: "Pour le reproduire : étapes numérotées."))
        - \(String(localized: "Ce que j'attendais."))
        - \(String(localized: "Version de Wispad : \(context.version). Version de macOS : \(context.macOS)."))
        - \(String(localized: "Fournisseur de transcription : \(context.voice). Type de Mac : \(context.mac)."))
        - \(String(localized: "Les extraits utiles des journaux et du diagnostic, dans un bloc <details>."))
        - \(String(localized: "Les captures d'écran utiles : dis-moi lesquelles faire, sans rien de personnel à l'écran."))

        \(String(localized: "5. Anonymise tout"))
        \(String(localized: "Retire, ou remplace par un exemple neutre : textes dictés et transcriptions, noms de personnes, e-mails, numéros de téléphone, nom d'utilisateur et chemins personnels (/Users/…), nom de l'ordinateur, adresses IP, numéros de série, clés API et jetons, contenu de mes apps et de mes fenêtres. Le nom d'une app peut rester s'il aide à reproduire le problème."))

        \(String(localized: "6. Publie seulement avec mon accord"))
        \(String(localized: "Montre-moi le titre et le texte complets du ticket. Si je dis oui et que gh est installé et connecté : gh issue create --repo \(repository) --title \"…\" --body-file <fichier>. Sinon, ouvre ce formulaire prérempli et dis-moi quoi coller dans chaque champ : \(context.bugReportURL.absoluteString)"))

        \(String(localized: "Diagnostic de Wispad (aucun texte dicté, audio, contexte d'app ni clé) :"))

        \(fence)json
        \(json)
        \(fence)
        """
    }
}
