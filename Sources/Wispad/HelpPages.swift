import AppKit
import WispadCore

/// Aide et retours (Réglages, menu de la barre, menu Aide) : pages GitHub du projet, ouvertes dans le navigateur
/// sans montrer la fenêtre de Wispad. Le ticket de bug ne reprend que la version de la barre latérale et celle de
/// macOS ; idées et questions vont dans les Discussions.
enum HelpPage: CaseIterable {
    case reportProblem
    case proposeIdea
    case askQuestion

    var title: String {
        switch self {
        case .reportProblem: return String(localized: "Signaler un problème")
        case .proposeIdea: return String(localized: "Proposer une idée")
        case .askQuestion: return String(localized: "Poser une question")
        }
    }

    var symbol: String {
        switch self {
        case .reportProblem: return "ladybug"
        case .proposeIdea: return "lightbulb"
        case .askQuestion: return "questionmark.circle"
        }
    }

    @MainActor var url: URL {
        switch self {
        case .reportProblem: return BuildStatus.shared.bugReportURL()
        case .proposeIdea: return FeedbackLinks.ideasURL
        case .askQuestion: return FeedbackLinks.questionsURL
        }
    }

    @MainActor func open() {
        NSWorkspace.shared.open(url)
    }
}
