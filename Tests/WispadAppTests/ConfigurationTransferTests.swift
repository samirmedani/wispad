import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Export puis import d'une configuration entre deux installations de test : réglages et dictionnaire passent, les
/// clés et les réglages de l'appareil jamais.
@MainActor
struct ConfigurationTransferTests {
    @MainActor private final class Install {
        let directory: URL
        var keys: [String: String] = [:]
        var model: AppModel!
        var copied: [String] = []

        init(_ configure: (inout AppSettings) -> Void) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-config-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dependencies = AppDependencies()
            dependencies.loadKey = { [weak self] in self?.keys[$0] }
            dependencies.refreshKeys = { true }
            dependencies.copyText = { [weak self] in self?.copied.append($0) }
            dependencies.playCue = { _, _ in }
            var settings = AppSettings()
            settings.onboardingCompleted = true
            configure(&settings)
            model = try AppModel(supportDirectory: directory, settings: settings, dependencies: dependencies)
            model.overlay.displaysPanel = false
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private let judge = DictionaryJudge(kind: .jev, provider: "TypeSafe", model: "jev-latest")

    private func source() throws -> Install {
        let install = try Install { settings in
            settings.microphoneUID = "micro-usb-du-mac-a"
            settings.launchAtLogin = true
            settings.disabledKeys = ["openai"]
            settings.localModelURL = CleanupModel.ollamaURL
            settings.soundsVolume = 0.4
            settings.bubbleSize = 1.3
            settings.bubbleStyle = .glass
            settings.dateFormat.separator = .dot
            settings.lastSection = .usage
        }
        install.keys = ["xai": "xai-cle-de-test-0000", "deepseek": "sk-cle-de-test-1111"]
        try install.model.store.addTerm("Wispad", origin: .user)
        try install.model.store.addTerm("Seedance", origin: .learned(judge), heard: "sidance", source: .fieldCorrection,
                                        createdAt: Date(timeIntervalSince1970: 1_792_000_000))
        install.model.reloadDictionary()
        return install
    }

    @Test func exportCarriesSettingsAndDictionaryButNoKeyNorDeviceSetting() throws {
        let install = try source()
        let file = install.model.exportConfiguration()
        let text = String(decoding: try file.encoded(), as: UTF8.self)
        #expect(!text.contains("xai-cle-de-test-0000") && !text.contains("sk-cle-de-test-1111"))
        for key in AppSettings.deviceOnlyKeys { #expect(file.settings[key] == nil, "\(key)") }
        #expect(file.settings["soundsVolume"] as? Double == 0.4)
        #expect(file.settings["bubbleStyle"] as? String == "glass")
        #expect(file.dictionary.map(\.term) == ["Seedance", "Wispad"])
        #expect(file.dictionary[0].origin == .learned(judge))
        #expect(file.notes.count == 5)

        let prompt = try install.model.agentPrompt(for: file)
        #expect(prompt.contains("wispad-configuration"))
        #expect(prompt.contains("open -a Wispad wispad-configuration.json"))
        #expect(!prompt.contains("xai-cle-de-test-0000"))
    }

    @Test func importAppliesWhatTheFileCarriesAndKeepsThisDevice() throws {
        let file = try ConfigurationFile.read(try source().model.exportConfiguration().encoded())
        let target = try Install { settings in
            settings.microphoneUID = "micro-integre-du-mac-b"
            settings.launchAtLogin = false
            settings.localModelURL = ""
        }
        try target.model.store.addTerm("wispad", origin: .user)
        target.model.reloadDictionary()

        let pending = target.model.prepareImport(file)
        #expect(pending.settingsChanges >= 4)
        #expect(pending.newTerms.map(\.term) == ["Seedance"])

        let result = target.model.applyImport(pending, settings: true, dictionary: true)
        let settings = target.model.settings
        #expect(settings.soundsVolume == 0.4)
        #expect(settings.bubbleSize == 1.3)
        #expect(settings.bubbleStyle == .glass)
        #expect(settings.dateFormat.separator == .dot)
        #expect(settings.microphoneUID == "micro-integre-du-mac-b")
        #expect(settings.launchAtLogin == false)
        #expect(settings.disabledKeys.isEmpty)
        #expect(settings.localModelURL.isEmpty)
        #expect(settings.lastSection != .usage)
        #expect(result.terms == 1)
        let seedance = try #require(target.model.dictionary.first { $0.term == "Seedance" })
        #expect(seedance.origin == .learned(judge))
        #expect(seedance.heard == "sidance")
        #expect(seedance.createdAt == Date(timeIntervalSince1970: 1_792_000_000))
        #expect(target.model.dictionary.filter { $0.term.lowercased() == "wispad" }.count == 1)
        #expect(target.model.pendingConfigurationImport == nil)
    }

    /// Valeur illisible ici (autre plateforme, version plus récente) : ce réglage garde sa valeur actuelle.
    @Test func unreadableImportedValueKeepsTheCurrentOne() throws {
        var current = AppSettings()
        current.soundsVolume = 0.7
        current.bubbleSize = 1.0
        let updated = current.applying(["soundsVolume": "fort", "bubbleSize": 1.5, "reglageFutur": true,
                                        "microphoneUID": "micro-d-un-autre-mac"])
        #expect(updated.soundsVolume == 0.7)
        #expect(updated.bubbleSize == 1.5)
        #expect(updated.microphoneUID == current.microphoneUID)
        #expect(current.changes(applying: ["bubbleSize": 1.0]) == 0)
        #expect(current.changes(applying: ["bubbleSize": 1.5]) == 1)
    }

    @Test func choosingOnlyTheDictionaryLeavesSettingsAlone() throws {
        let file = try source().model.exportConfiguration()
        let target = try Install { _ in }
        let before = target.model.settings
        let pending = target.model.prepareImport(file)
        target.model.applyImport(pending, settings: false, dictionary: true)
        #expect(target.model.settings == before)
        #expect(target.model.dictionary.count == 2)
    }
}
