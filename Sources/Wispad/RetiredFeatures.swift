import Foundation
import os

/// Nettoyage, à chaque lancement, des fichiers que des fonctions retirées ont laissés : modèles de transcription
/// locale téléchargés par Wispad. Leurs réglages sont effacés par `AppSettings.removeRetiredKeys`. Rien n'échoue si
/// ces fichiers n'existent pas ; une installation propre n'est pas touchée.
enum RetiredFeatures {
    /// Dossier des modèles locaux téléchargés par Wispad, dans Application Support/Wispad.
    static let modelsFolderName = "Models"

    struct Report: Equatable {
        var removedModels = false
    }

    private static let log = Logger.wispad("migration")

    /// Lancement normal : dossier Application Support réel.
    static func runAtLaunch() {
        guard let support = try? AppPaths.supportDirectory() else { return }
        let report = run(supportDirectory: support)
        if report != Report() {
            log.notice("fonctions retirées : modèles=\(report.removedModels, privacy: .public)")
        }
    }

    /// Cœur du nettoyage, sans dépendance au système : testé sur un dossier temporaire.
    static func run(supportDirectory: URL) -> Report {
        var report = Report()
        let models = supportDirectory.appendingPathComponent(modelsFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: models.path) {
            report.removedModels = (try? FileManager.default.removeItem(at: models)) != nil
        }
        return report
    }
}
