import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Modèle de test de Fournisseurs : clés fictives en mémoire, jamais lues dans un coffre ni vérifiées.
@MainActor
private final class ProvidersFixture {
    let directory: URL
    var model: AppModel!
    /// Clés enregistrées, par compte.
    var stored: [String: String]

    init(keys accounts: [String] = ["xai", "openai", "deepseek"], store: KeyStoreKind = .file) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-providers-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stored = Dictionary(uniqueKeysWithValues: accounts.map { ($0, "fixture-" + $0) })
        var dependencies = AppDependencies()
        dependencies.keyStore = store
        dependencies.loadKey = { [weak self] account in self?.stored[account] }
        dependencies.saveKey = { [weak self] account, key in
            self?.stored[account] = key
            return true
        }
        dependencies.refreshKeys = { true }
        dependencies.copyText = { _ in }
        dependencies.requestMicrophone = { false }
        model = try AppModel(supportDirectory: directory, settings: AppSettings(), dependencies: dependencies)
    }

    var snapshot: ProvidersSnapshot { ProvidersSnapshot(model: model) }
    var overview: ProvidersOverview { ProvidersOverview.make(snapshot, paused: model.relayLines()) }

    func dispose() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Fournisseurs : la vue d'ensemble dit une chose par cause, avec le bouton qui règle ; les choix du sélecteur gardent
/// les règles d'origine (clé active exigée, relais échangé ou remis sur « Aucun relais »).
@MainActor
struct ProvidersScreenTests {
    /// Sans aucune clé : un seul message et un seul bouton, au lieu d'un bandeau par étape (voix, vérification,
    /// correction, mots appris).
    @Test func withoutAnyKeyTheScreenSaysOneThing() throws {
        let f = try ProvidersFixture(keys: [])
        defer { f.dispose() }
        let overview = f.overview
        #expect(overview.tone == .blocked)
        #expect(overview.title == "Ajoute une clé pour dicter")
        #expect(overview.actions == [.addKey(nil)])
        #expect(overview.rows.isEmpty)
        #expect(f.snapshot.gaps.map(\.account) == ["xai"])
    }

    /// Un coffre injoignable cache tout le reste : les clés manquantes n'en sont que la conséquence.
    @Test func unreadableKeysHideEverythingElse() throws {
        let f = try ProvidersFixture(keys: [], store: .vault)
        defer { f.dispose() }
        f.model.keysReachable = false
        #expect(f.overview.title == "Coffre de secrets injoignable")
        #expect(f.overview.actions == [.reload])
    }

    /// Une clé de correction seule : il manque la voix, et rien d'autre n'est signalé.
    @Test func aCorrectionKeyAloneAsksForAVoiceKey() throws {
        let f = try ProvidersFixture(keys: ["deepseek"])
        defer { f.dispose() }
        let overview = f.overview
        #expect(overview.tone == .blocked)
        #expect(overview.title == "Ajoute ta clé xAI pour dicter")
        #expect(overview.detail == "Une clé xAI ou OpenAI suffit pour dicter.")
        #expect(overview.actions == [.addKey("xai")])
        #expect(overview.rows.isEmpty)
    }

    /// Clé de la voix coupée, l'autre fournisseur prêt : la rallumer, ou dicter avec lui en un clic.
    @Test func aVoiceKeyTurnedOffOffersTheOtherProvider() throws {
        let f = try ProvidersFixture()
        defer { f.dispose() }
        f.model.setKeyEnabled("xai", false)
        let overview = f.overview
        #expect(overview.title == "Ta clé xAI est coupée")
        #expect(overview.actions == [.enableKey("xai"), .useVoice(.openAI)])
        #expect(overview.rows.isEmpty)
        #expect(f.snapshot.voiceSummary.warning == "Clé xAI coupée")

        f.model.chooseVoice(.openAI, model: f.model.liveModel(for: .openAI))
        #expect(f.model.settings.provider == .openAI)
        #expect(f.overview.tone == .ready)
    }

    /// Une clé coupée qui sert aux deux relais : un seul avertissement, qui nomme les deux.
    @Test func aKeyUsedTwiceIsOneWarning() async throws {
        let f = try ProvidersFixture()
        defer { f.dispose() }
        await f.model.refreshKeys()
        f.model.setKeyEnabled("openai", false)
        let snapshot = f.snapshot
        #expect(snapshot.gaps == [KeyGap(account: "openai", stored: true, roles: [.voiceRelay, .correctionRelay])])
        #expect(snapshot.advancedNeedsAttention)
        let overview = f.overview
        #expect(overview.tone == .attention)
        #expect(overview.title == "Les relais ne serviront pas")
        #expect(overview.actions == [.enableKey("openai")])
    }

    /// Modèle de correction choisi sans clé active : la vue d'ensemble dit qui corrige à sa place.
    @Test func aChosenCorrectionWithoutKeyNamesItsStandIn() throws {
        let f = try ProvidersFixture()
        defer { f.dispose() }
        f.model.chooseCleanup(.openAILuna)
        f.model.setKeyEnabled("openai", false)
        let overview = f.overview
        #expect(overview.title == "La correction ne passe pas par OpenAI")
        #expect(overview.detail == "Sa clé est coupée : DeepSeek Flash corrige en attendant.")
        #expect(overview.actions == [.enableKey("openai"), .choose(.correction)])
        #expect(f.snapshot.correctionSummary.warning == "Clé OpenAI coupée")
    }

    /// Deux clés en cause : une ligne chacune, dans l'ordre d'une dictée.
    @Test func twoCausesMakeTwoRows() async throws {
        let f = try ProvidersFixture()
        defer { f.dispose() }
        await f.model.refreshKeys()
        f.model.chooseCleanup(.deepSeekFlash)
        f.model.setKeyEnabled("openai", false)
        f.model.setKeyEnabled("deepseek", false)
        let overview = f.overview
        #expect(overview.tone == .attention)
        #expect(overview.title == "2 réglages attendent une clé")
        #expect(overview.rows.map(\.account) == ["openai", "deepseek"])
        #expect(overview.rows.map(\.roles) == [[.voiceRelay, .correctionRelay], [.correction]])
    }

    /// Un service mis de côté : la vue d'ensemble dit par où passent les dictées, et propose de réessayer.
    @Test func aPausedServiceIsShownWithItsRelay() async throws {
        let f = try ProvidersFixture()
        defer { f.dispose() }
        await f.model.refreshKeys()
        f.model.health.record(ServiceHealth.deepSeek, succeeded: false)
        f.model.health.record(ServiceHealth.deepSeek, succeeded: false)
        let overview = f.overview
        #expect(overview.tone == .relay)
        #expect(overview.detail == "DeepSeek en pause : correction via OpenAI gpt-5.4-mini")
        #expect(overview.actions == [.retryServices])
    }

    /// Tout est prêt : une phrase dit qui transcrit et qui corrige.
    @Test func everythingReadyNamesTheVoiceAndTheCorrection() throws {
        let f = try ProvidersFixture()
        defer { f.dispose() }
        let overview = f.overview
        #expect(overview.tone == .ready)
        #expect(overview.detail == "Ta voix passe par xAI, DeepSeek corrige le texte.")
        #expect(f.snapshot.correctionSummary == ModelSummary(account: "deepseek", title: "Automatique", caption: "DeepSeek Flash"))
    }

    /// Les choix du sélecteur gardent les règles des anciens menus.
    @Test func choicesKeepTheirRules() throws {
        let f = try ProvidersFixture(keys: ["xai", "deepseek"])
        defer { f.dispose() }
        // Voix : un fournisseur sans clé active ne se choisit pas.
        f.model.chooseVoice(.openAI, model: "gpt-live-transcribe")
        #expect(f.model.settings.provider == .xai)
        // Relais de la voix : l'autre fournisseur sans clé, seul « Aucun relais » se choisit.
        f.model.chooseVoiceRelay("gpt-live-transcribe")
        #expect(f.model.settings.voiceRelay.isEmpty)
        f.model.chooseVoiceRelay(AppSettings.voiceRelayOff)
        #expect(f.model.displayedVoiceRelay == AppSettings.voiceRelayOff)
        // Relais de la correction : une clé active est exigée.
        f.model.chooseCleanupRelay(.openAIMini)
        #expect(f.model.settings.cleanupRelay == .automatic)
        f.model.chooseCleanupRelay(.grok)
        #expect(f.model.settings.cleanupRelay == .grok)
        // Correction : prendre le modèle du relais remet le relais sur « Aucun relais ».
        f.model.chooseCleanup(.grok)
        #expect(f.model.settings.cleanupChoice == .grok)
        #expect(f.model.settings.cleanupRelay == .off)
        // Correction : un modèle sans clé active ne se choisit pas ; « Automatique » toujours.
        f.model.chooseCleanup(.openAILuna)
        #expect(f.model.settings.cleanupChoice == .grok)
        f.model.chooseCleanup(.automatic)
        #expect(f.model.settings.cleanupChoice == .automatic)
    }

    /// Prendre pour la voix le fournisseur du relais : l'ancien modèle de voix devient le relais.
    @Test func takingTheRelayProviderForTheVoiceSwapsThem() async throws {
        let f = try ProvidersFixture()
        defer { f.dispose() }
        await f.model.refreshKeys()
        #expect(f.model.displayedVoiceRelay == "gpt-live-transcribe")
        f.model.chooseVoice(.openAI, model: "gpt-4o-mini-transcribe")
        #expect(f.model.settings.provider == .openAI)
        #expect(f.model.settings.liveModel == "gpt-4o-mini-transcribe")
        #expect(f.model.settings.voiceRelay == "grok-voice-transcribe-2.0")
        #expect(f.snapshot.voiceRelay?.id == "grok-voice-transcribe-2.0")
    }

    /// Jev ne se choisit qu'avec une clé TypeSafe enregistrée : le choisir l'allume, « Comme la correction » la coupe.
    @Test func jevFollowsTheTypeSafeKey() throws {
        let f = try ProvidersFixture(keys: ["xai"])
        defer { f.dispose() }
        f.model.chooseJudge(jev: false)
        #expect(f.model.isKeyEnabled(APIKeys.typesafe))
        f.stored[APIKeys.typesafe] = "fixture-typesafe"
        f.model.chooseJudge(jev: false)
        #expect(!f.model.hasKey(account: APIKeys.typesafe))
        f.model.chooseJudge(jev: true)
        #expect(f.model.hasKey(account: APIKeys.typesafe))
        #expect(f.snapshot.learningSummary == "Jev note chaque mot ; en cas de doute, Grok 4.7 tranche.")
    }
}
