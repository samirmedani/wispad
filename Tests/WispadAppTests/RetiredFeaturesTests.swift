import Foundation
import Testing
@testable import WispadApp

/// Nettoyage des fichiers des fonctions retirées, sur un dossier temporaire (jamais le vrai).
struct RetiredFeaturesTests {
    private struct Fixture {
        let support: URL

        init() throws {
            support = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-retired-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func dispose() {
            try? FileManager.default.removeItem(at: support)
        }
    }

    @Test func downloadedLocalModelsAreRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let model = fixture.support.appendingPathComponent("\(RetiredFeatures.modelsFolderName)/Parakeet/parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("modèle fictif".utf8).write(to: model.appendingPathComponent("Encoder.mlmodelc"))

        let report = RetiredFeatures.run(supportDirectory: fixture.support)

        #expect(report.removedModels)
        #expect(!FileManager.default.fileExists(atPath: fixture.support.appendingPathComponent(RetiredFeatures.modelsFolderName).path))
        #expect(RetiredFeatures.run(supportDirectory: fixture.support) == RetiredFeatures.Report())
    }

    @Test func cleanInstallIsLeftUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        #expect(RetiredFeatures.run(supportDirectory: fixture.support) == RetiredFeatures.Report())
    }
}
