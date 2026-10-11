import Foundation
import os

/// Identité de l'app, en un seul endroit : identifiant, dossier de données, base et journaux.
enum AppIdentity {
    static let bundleID = "com.yatofix.wispad"
    static let displayName = "Wispad"
    /// Dossier dans ~/Library/Application Support.
    static let supportFolderName = "Wispad"
    static let databaseName = "wispad.sqlite"
}

extension Logger {
    /// Journal système de Wispad pour une catégorie. Jamais de texte dicté, de contexte ni de clé.
    static func wispad(_ category: String) -> Logger {
        Logger(subsystem: AppIdentity.bundleID, category: category)
    }
}

enum AppPaths {
    static func supportDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = root.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Audio", isDirectory: true), withIntermediateDirectories: true)
        return url
    }
}
