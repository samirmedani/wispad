import Foundation
import Testing
@testable import WispadCore

/// Fichier de configuration : lisible, complet à l'aller-retour, tolérant à la lecture, jamais trompé par un autre JSON.
@Suite struct ConfigurationFileTests {
    private let judge = DictionaryJudge(kind: .correctionModel, provider: "DeepSeek", model: "deepseek-flash")

    private func sample() -> ConfigurationFile {
        ConfigurationFile(
            exportedAt: Date(timeIntervalSince1970: 1_793_200_000),
            origin: .init(version: "0.6.0", build: "33", platform: "macOS", system: "26.1"),
            notes: ["Configuration de Wispad."],
            settings: ["soundsVolume": 0.4, "bubbleStyle": "glass", "tones": ["email": "polished"]],
            dictionary: [
                .init(term: "Wispad", addedAt: Date(timeIntervalSince1970: 1_792_000_000), origin: .user),
                .init(term: "Seedance", addedAt: Date(timeIntervalSince1970: 1_792_100_000), origin: .learned(judge),
                      heard: "sidance", source: .fieldCorrection),
                .init(term: "Ancien"),
            ]
        )
    }

    @Test func roundTripKeepsEverything() throws {
        let file = sample()
        let data = try file.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""format" : "wispad-configuration""#))
        #expect(text.contains(#""exportedAt" : "2026-10-28T"#))
        let read = try ConfigurationFile.read(data)
        #expect(read.exportedAt == file.exportedAt)
        #expect(read.origin == file.origin)
        #expect(read.notes == file.notes)
        #expect(read.dictionary == file.dictionary)
        #expect(read.settings["soundsVolume"] as? Double == 0.4)
        #expect((read.settings["tones"] as? [String: String])?["email"] == "polished")
        #expect(!read.isNewerFormat)
    }

    @Test func otherFilesAreRefusedAndNewerOnesRead() throws {
        #expect(throws: ConfigurationFile.ReadError.unreadable) { try ConfigurationFile.read(Data("pas du json".utf8)) }
        #expect(throws: ConfigurationFile.ReadError.notAConfiguration) { try ConfigurationFile.read(Data(#"{"name": "autre"}"#.utf8)) }
        let newer = try ConfigurationFile.read(Data(#"""
        {"format": "wispad-configuration", "formatVersion": 7, "futur": {"x": 1}, "settings": {"bubbleSize": 1.2},
         "dictionary": [{"term": " Codex "}, {"term": ""}, {"pas": "un terme"}, {"term": "Grok", "origin": "jev"}]}
        """#.utf8))
        #expect(newer.isNewerFormat)
        #expect(newer.settings["bubbleSize"] as? Double == 1.2)
        #expect(newer.dictionary.map(\.term) == ["Codex", "Grok"])
        // Juge incomplet : origine inconnue, jamais une erreur.
        #expect(newer.dictionary[1].origin == .unknown)
    }

    @Test func onlyMissingTermsAreNew() {
        let file = sample()
        #expect(file.newTerms(comparedTo: ["wispad", "Autre"]).map(\.term) == ["Seedance", "Ancien"])
        #expect(file.newTerms(comparedTo: ["WISPAD", "seedance", "ancien"]).isEmpty)
    }
}
