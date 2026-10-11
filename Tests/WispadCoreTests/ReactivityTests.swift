import os
import XCTest
@testable import WispadCore

/// Raccourci hors du fil principal, Échap, fin de session et raccord des dictées.
final class HotkeyLogicTests: XCTestCase {
    private let fn = ChordMatcher.functionKeyCode
    private let fnFlags = ModifierMask.function
    private let listening = HotkeyConfig(capturing: true)
    private let idle = HotkeyConfig()

    private func fnDown(_ time: Int) -> KeyEvent { KeyEvent(phase: .flags, keyCode: fn, flags: fnFlags, time: time) }
    private func fnUp(_ time: Int) -> KeyEvent { KeyEvent(phase: .flags, keyCode: fn, flags: 0, time: time) }
    private func escape(_ phase: KeyPhase, flags: UInt64 = 0, autorepeat: Bool = false) -> KeyEvent {
        KeyEvent(phase: phase, keyCode: HotkeyLogic.escapeKeyCode, flags: flags, autorepeat: autorepeat, time: 0)
    }

    func testHoldStartsAfterThresholdUsingEventTimes() {
        var logic = HotkeyLogic()
        let down = logic.handle(fnDown(1_000), config: idle)
        XCTAssertTrue(down.swallow)
        XCTAssertEqual(down.pressedAt, 1_000)
        XCTAssertEqual(down.wake, .reschedule(1_170))
        XCTAssertTrue(down.effects.isEmpty)
        XCTAssertEqual(logic.tick(at: 1_170, keyStillDown: true).effects, [.startPushToTalk])
        XCTAssertEqual(logic.handle(fnUp(2_000), config: listening).effects, [.stopPushToTalk])
    }

    func testShortPressWhoseReleaseArrivesLateNeverOpensTheMicrophone() {
        var logic = HotkeyLogic()
        _ = logic.handle(fnDown(1_000), config: idle)
        // Le réveil passe avant que le relâchement (à +80 ms) soit traité, mais la touche est déjà levée.
        let wake = logic.tick(at: 1_170, keyStillDown: false)
        XCTAssertTrue(wake.effects.isEmpty)
        XCTAssertEqual(wake.wake, .reschedule(1_200))
        // Le relâchement arrive ensuite, horodaté à l'instant réel : simple appui, rien ne démarre.
        XCTAssertTrue(logic.handle(fnUp(1_080), config: idle).effects.isEmpty)
        XCTAssertTrue(logic.tick(at: 1_400, keyStillDown: false).effects.isEmpty)
    }

    func testDoublePressStartsImmediatelyAndWaitsForTheNextPressToStop() {
        var logic = HotkeyLogic()
        _ = logic.handle(fnDown(1_000), config: idle)
        _ = logic.handle(fnUp(1_050), config: idle)
        let secondDown = logic.handle(fnDown(1_150), config: idle)
        XCTAssertTrue(secondDown.swallow)
        XCTAssertEqual(secondDown.pressedAt, 1_150)
        XCTAssertEqual(secondDown.effects, [.startToggle])
        XCTAssertEqual(secondDown.wake, .reschedule(nil))
        XCTAssertTrue(logic.chordDown)
        // Ni une répétition ni un réveil déjà en vol ne transforme le deuxième appui en maintien.
        XCTAssertTrue(logic.handle(fnDown(1_200), config: listening).effects.isEmpty)
        XCTAssertTrue(logic.tick(at: 1_400, keyStillDown: true).effects.isEmpty)
        XCTAssertTrue(logic.handle(fnUp(1_600), config: listening).effects.isEmpty)
        XCTAssertTrue(logic.engine.isToggleLatched)
        XCTAssertEqual(logic.handle(fnDown(2_000), config: listening).effects, [.stopToggle])
        XCTAssertTrue(logic.handle(fnUp(2_100), config: idle).effects.isEmpty)
    }

    func testLostSecondReleaseKeepsHandsFreeAndTheNextPressCanStopIt() {
        var logic = HotkeyLogic()
        _ = logic.handle(fnDown(1_000), config: idle)
        _ = logic.handle(fnUp(1_050), config: idle)
        XCTAssertEqual(logic.handle(fnDown(1_150), config: idle).effects, [.startToggle])
        XCTAssertTrue(logic.tick(at: 1_400, keyStillDown: false).effects.isEmpty)
        // La reprise constate le relâchement perdu : mains libres reste actif, le clavier est recalé.
        let resync = logic.resync(keyPhysicallyDown: false, at: 1_500)
        XCTAssertTrue(resync.effects.isEmpty)
        XCTAssertEqual(resync.wake, .reschedule(nil))
        XCTAssertFalse(logic.chordDown)
        XCTAssertTrue(logic.engine.isToggleLatched)
        XCTAssertEqual(logic.handle(fnDown(2_000), config: listening).effects, [.stopToggle])
        XCTAssertTrue(logic.handle(fnUp(2_100), config: idle).effects.isEmpty)
    }

    func testLostReleaseIsAbandonedInsteadOfBlockingTheShortcut() {
        var logic = HotkeyLogic()
        _ = logic.handle(fnDown(1_000), config: idle)
        XCTAssertTrue(logic.tick(at: 1_700, keyStillDown: false).effects.isEmpty)
        // Geste abandonné : un nouvel appui long fonctionne.
        _ = logic.handle(fnUp(1_710), config: idle)
        _ = logic.handle(fnDown(2_000), config: idle)
        XCTAssertEqual(logic.tick(at: 2_170, keyStillDown: true).effects, [.startPushToTalk])
    }

    func testEscapeCancelsOnlyWhileListeningAndNeverReachesTheApp() {
        var logic = HotkeyLogic()
        let down = logic.handle(escape(.down), config: listening)
        XCTAssertTrue(down.swallow)
        XCTAssertTrue(down.cancel)
        XCTAssertTrue(logic.handle(escape(.down, autorepeat: true), config: idle).swallow)
        XCTAssertTrue(logic.handle(escape(.up), config: idle).swallow)
        // Hors écoute : Échap appartient à l'app.
        let free = logic.handle(escape(.down), config: idle)
        XCTAssertFalse(free.swallow)
        XCTAssertFalse(free.cancel)
        XCTAssertFalse(logic.handle(escape(.up), config: idle).swallow)
    }

    func testEscapeWhileADictationFinishesCancelsItButStaysInTheApp() {
        var logic = HotkeyLogic()
        let finishing = HotkeyConfig(pending: true)
        let down = logic.handle(escape(.down), config: finishing)
        XCTAssertTrue(down.cancel)
        XCTAssertFalse(down.swallow)
        XCTAssertFalse(logic.handle(escape(.up), config: finishing).swallow)
        XCTAssertFalse(logic.handle(escape(.down, flags: ModifierMask.command), config: finishing).cancel)
    }

    func testLostReleaseOfASinglePressNeverStartsADictation() {
        var logic = HotkeyLogic()
        _ = logic.handle(fnDown(1_000), config: idle)
        // Le relâchement (à +80 ms) se perd pendant une coupure de l'écoute ; la reprise tombe après le seuil.
        let resync = logic.resync(keyPhysicallyDown: false, at: 1_300)
        XCTAssertTrue(resync.effects.isEmpty)
        XCTAssertEqual(resync.wake, .reschedule(nil))
        XCTAssertTrue(logic.tick(at: 1_400, keyStillDown: false).effects.isEmpty)
        // Le raccourci reste vivant : un vrai maintien démarre ensuite.
        _ = logic.handle(fnDown(2_000), config: idle)
        XCTAssertEqual(logic.tick(at: 2_170, keyStillDown: true).effects, [.startPushToTalk])
    }

    func testEscapeWithModifiersOrWhileRecordingTheShortcutIsLeftAlone() {
        var logic = HotkeyLogic()
        let forceQuit = logic.handle(escape(.down, flags: ModifierMask.command | ModifierMask.option), config: listening)
        XCTAssertFalse(forceQuit.swallow)
        XCTAssertFalse(forceQuit.cancel)
        let recording = HotkeyConfig(recording: true, capturing: true)
        XCTAssertFalse(logic.handle(escape(.down), config: recording).cancel)
        // fn tenue n'empêche pas Échap d'annuler.
        XCTAssertTrue(logic.handle(escape(.down, flags: ModifierMask.function), config: listening).cancel)
    }

    func testEndingASessionKeepsANewGestureInProgress() {
        var logic = HotkeyLogic()
        _ = logic.handle(fnDown(1_000), config: idle)
        _ = logic.tick(at: 1_170, keyStillDown: true)
        _ = logic.handle(fnUp(1_500), config: listening)
        // Nouvel appui pendant que la dictée précédente se termine.
        _ = logic.handle(fnDown(1_600), config: idle)
        logic.endSession()
        XCTAssertEqual(logic.tick(at: 1_770, keyStillDown: true).effects, [.startPushToTalk])
        XCTAssertEqual(logic.handle(fnUp(2_000), config: listening).effects, [.stopPushToTalk])
    }

    func testEndingAHandsFreeSessionFromTheBubbleResetsTheLatch() {
        var logic = HotkeyLogic()
        _ = logic.handle(fnDown(1_000), config: idle)
        _ = logic.handle(fnUp(1_050), config: idle)
        XCTAssertEqual(logic.handle(fnDown(1_150), config: idle).effects, [.startToggle])
        XCTAssertTrue(logic.handle(fnUp(1_200), config: idle).effects.isEmpty)
        logic.endSession()
        // Le prochain appui ne « termine » pas une dictée déjà finie : il commence un geste.
        let next = logic.handle(fnDown(3_000), config: idle)
        XCTAssertTrue(next.effects.isEmpty)
        XCTAssertEqual(next.wake, .reschedule(3_170))
    }

    func testResyncReplaysALostRelease() {
        var logic = HotkeyLogic()
        _ = logic.handle(fnDown(1_000), config: idle)
        _ = logic.tick(at: 1_170, keyStillDown: true)
        XCTAssertTrue(logic.chordDown)
        let resync = logic.resync(keyPhysicallyDown: false, at: 5_000)
        XCTAssertEqual(resync.effects, [.stopPushToTalk])
        XCTAssertFalse(logic.chordDown)
        XCTAssertTrue(logic.resync(keyPhysicallyDown: false, at: 6_000).effects.isEmpty)
    }

    func testShortcutCaptureIsReported() {
        var logic = HotkeyLogic()
        let recording = HotkeyConfig(recording: true)
        let output = logic.handle(KeyEvent(phase: .down, keyCode: 2, flags: ModifierMask.command, time: 10), config: recording)
        XCTAssertEqual(output.capturedKeyCode, 2)
        XCTAssertEqual(output.capturedFlags, ModifierMask.command)
        XCTAssertTrue(output.swallow)
    }

    func testOtherKeysPassThrough() {
        var logic = HotkeyLogic()
        let letter = logic.handle(KeyEvent(phase: .down, keyCode: 0, flags: 0, time: 10), config: listening)
        XCTAssertFalse(letter.swallow)
        XCTAssertTrue(letter.isQuiet)
    }
}

final class SmartJoinTests: XCTestCase {
    func testConsecutiveDictationsAreSeparatedBySpace() {
        XCTAssertEqual(SmartJoin.adjust("Deuxième phrase.", before: "Première phrase."), " Deuxième phrase.")
        XCTAssertEqual(SmartJoin.adjust("et la suite", before: "je pense que"), " et la suite")
        XCTAssertEqual(SmartJoin.adjust("Bonjour", before: "Note :"), " Bonjour")
    }

    func testNoSpaceWhenNotNeededOrUnknown() {
        XCTAssertEqual(SmartJoin.adjust("Bonjour", before: nil), "Bonjour")
        XCTAssertEqual(SmartJoin.adjust("Bonjour", before: ""), "Bonjour")
        XCTAssertEqual(SmartJoin.adjust("Bonjour", before: "Salut "), "Bonjour")
        XCTAssertEqual(SmartJoin.adjust("Bonjour", before: "ligne\n"), "Bonjour")
        XCTAssertEqual(SmartJoin.adjust("avion", before: "l'"), "avion")
        XCTAssertEqual(SmartJoin.adjust("entre parenthèses", before: "("), "entre parenthèses")
        XCTAssertEqual(SmartJoin.adjust(", et ensuite", before: "fini"), ", et ensuite")
        XCTAssertEqual(SmartJoin.adjust("", before: "fini"), "")
    }
}

final class PCMRelayTests: XCTestCase {
    func testAudioCapturedBeforeTheStreamIsSentFirstAndInOrder() {
        let relay = PCMRelay()
        relay.push(Data([1, 2]))
        relay.push(Data([3, 4]))
        XCTAssertEqual(relay.bufferedBytes, 4)
        let received = OSAllocatedUnfairLock(initialState: [Data]())
        relay.attach { data in received.withLock { $0.append(data) } }
        relay.push(Data([5, 6]))
        XCTAssertEqual(received.withLock { $0 }, [Data([1, 2, 3, 4]), Data([5, 6])])
        XCTAssertEqual(relay.bufferedBytes, 0)
        // Fin de l'écoute : plus rien ne part.
        relay.close()
        relay.push(Data([7, 8]))
        XCTAssertEqual(received.withLock { $0 }.count, 2)
    }

    func testLongWaitKeepsOnlyTheMostRecentAudio() {
        let relay = PCMRelay()
        relay.push(Data(repeating: 0, count: PCMRelay.limit))
        relay.push(Data(repeating: 1, count: 10))
        XCTAssertEqual(relay.bufferedBytes, PCMRelay.limit)
    }
}

final class SmartJoinContextTests: XCTestCase {
    func testAccessibilityReadingIsUsedWhenTheAppShowsIt() {
        XCTAssertEqual(SmartJoin.textBefore(read: "Première phrase.", previous: nil, previousConfirmed: false), "Première phrase.")
        XCTAssertNil(SmartJoin.textBefore(read: nil, previous: nil, previousConfirmed: false))
    }

    func testPreviousPasteFillsInWhenTheAppIsLate() {
        // L'app n'a pas encore exposé le collage précédent : Wispad sait ce qui précède le curseur.
        XCTAssertEqual(SmartJoin.textBefore(read: "", previous: "Première phrase.", previousConfirmed: false), "Première phrase.")
        XCTAssertEqual(SmartJoin.textBefore(read: nil, previous: "Première phrase.", previousConfirmed: true), "Première phrase.")
        XCTAssertEqual(SmartJoin.adjust("Deuxième phrase.", before: SmartJoin.textBefore(read: "", previous: "Première phrase.", previousConfirmed: false)), " Deuxième phrase.")
    }

    func testConfirmedPasteTrustsWhereTheCursorIsNow() {
        // Collage constaté puis curseur déplacé en début de ligne : rien n'est ajouté.
        XCTAssertEqual(SmartJoin.textBefore(read: "", previous: "Première phrase.", previousConfirmed: true), "")
        XCTAssertEqual(SmartJoin.textBefore(read: "texte. Première phrase.", previous: "Première phrase.", previousConfirmed: false), "texte. Première phrase.")
    }
}

final class GestureWakeTests: XCTestCase {
    func testEarlyWakeIsRescheduledInsteadOfLeavingTheGestureStuck() {
        var engine = GestureEngine()
        _ = engine.keyDown(at: 0)
        XCTAssertEqual(engine.tick(at: 168), GestureStep(nextWakeMilliseconds: 170))
        XCTAssertEqual(engine.tick(at: 170).effects, [.startPushToTalk])
        var gap = GestureEngine()
        _ = gap.keyDown(at: 0)
        _ = gap.keyUp(at: 50)
        XCTAssertEqual(gap.tick(at: 300), GestureStep(nextWakeMilliseconds: 330))
    }
}

final class MenuTextTests: XCTestCase {
    private func speech(provider: ProviderID = .xai, deepSeek: Bool, openAI: Bool, deepSeekDown: Bool = false) -> SpeechRequest {
        SpeechRequest(
            provider: provider, liveModel: provider.defaultLiveModel, fileModel: provider.defaultLiveModel,
            apiKey: "fixture-voice", language: .french, keyterms: [], prompt: "",
            cleanupKey: deepSeek ? "fixture-deepseek" : nil,
            fallbackKey: openAI ? "fixture-openai" : nil,
            cleanupPrimaryDown: deepSeekDown
        )
    }

    func testCorrectionPlanFollowsTheKeysInTheVault() {
        let deepSeek = "DeepSeek \(CleanupModel.deepSeek)"
        let relay = "OpenAI \(CleanupModel.openAIFallback)"
        XCTAssertEqual(TextCleaner.plan(speech(deepSeek: true, openAI: true)).steps, [deepSeek, relay])
        XCTAssertEqual(TextCleaner.plan(speech(deepSeek: true, openAI: true)).maxSeconds, 5)
        XCTAssertEqual(TextCleaner.plan(speech(deepSeek: true, openAI: false)).steps, [deepSeek, "xAI \(ProviderID.xai.defaultCleanupModel)"])
        XCTAssertEqual(TextCleaner.plan(speech(deepSeek: false, openAI: true)).steps, [relay])
        XCTAssertEqual(TextCleaner.plan(speech(deepSeek: false, openAI: true)).maxSeconds, 4)
        XCTAssertEqual(TextCleaner.plan(speech(provider: .openAI, deepSeek: false, openAI: false)).steps, ["OpenAI \(ProviderID.openAI.defaultCleanupModel)"])
        // DeepSeek en pause : le relais passe devant.
        XCTAssertEqual(TextCleaner.plan(speech(deepSeek: true, openAI: true, deepSeekDown: true)).steps, [relay, deepSeek])
    }

    func testPricesAreWrittenTheFrenchWay() {
        XCTAssertEqual(MoneyFormat.price(0.2, locale: Locale(identifier: "fr_FR")), "0,20 $")
        XCTAssertEqual(MoneyFormat.price(0.075, locale: Locale(identifier: "fr_FR")), "0,075 $")
        XCTAssertEqual(ProviderCatalog.models[0].costSummary, "En direct 0,20 $/h · fichier 0,10 $/h")
        XCTAssertEqual(Pricing.rateDescription(model: CleanupModel.openAIFallback), "\(CleanupModel.openAIFallback) : 0,75 $ / 4,50 $ par million de jetons")
        XCTAssertEqual(Pricing.rateDescription(model: "jev-latest"), "jev-latest : 0,042 $ (sortie gratuite) par million de jetons")
        XCTAssertNil(Pricing.rateDescription(model: "modele-inconnu"))
        // Tarif plein de DeepSeek, avec la remise hors heures pleines dite en clair ; fichier OpenAI sous son nom.
        XCTAssertEqual(Pricing.rateDescription(model: CleanupModel.deepSeek), "\(CleanupModel.deepSeek) : 0,30 $ / 1,20 $ par million de jetons, moitié prix hors heures pleines")
        XCTAssertEqual(Pricing.rateDescription(model: "gpt-transcribe"), "gpt-transcribe : fichier 0,27 $/h")
    }
}
