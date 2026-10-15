import Testing
@testable import WispadCore

/// Raccourci toujours fiable : jamais mort (un appui ignoré) ni bloqué (dictée qui reste ouverte, touche avalée à
/// tort) après une écoute coupée par macOS, une veille, un écran verrouillé, une autre session, une saisie
/// sécurisée, un relâchement que l'écoute n'a pas vu, des appuis très rapides ou un raccourci modifié pendant une
/// dictée. L'écoute est menée comme par KeyboardTap, sans macOS (`Keyboard`).
struct HotkeyReliabilityTests {
    private let fn = ChordMatcher.functionKeyCode
    private let option = ModifierMask.option
    private let space = 49
    private let f5 = 96
    private let f6 = 97
    private let escape = HotkeyLogic.escapeKeyCode
    /// macOS marque les touches F de fn : l'enregistrement garde ce drapeau dans le raccourci.
    private let fKey = ModifierMask.function

    private func fnDown(_ time: Int) -> KeyEvent {
        KeyEvent(phase: .flags, keyCode: fn, flags: ModifierMask.function, time: time)
    }

    private func fnUp(_ time: Int) -> KeyEvent {
        KeyEvent(phase: .flags, keyCode: fn, flags: 0, time: time)
    }

    private func key(_ phase: KeyPhase, _ keyCode: Int, _ flags: UInt64 = 0, autorepeat: Bool = false, at time: Int) -> KeyEvent {
        KeyEvent(phase: phase, keyCode: keyCode, flags: flags, autorepeat: autorepeat, time: time)
    }

    // MARK: - Écoute coupée par macOS (lenteur, saisie sécurisée), puis rendue

    @Test func aHoldWhoseReleaseIsLostDuringACutStopsWhenListeningComesBack() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.advance(to: 1_200)
        #expect(keyboard.effects == [.startPushToTalk])
        // Coupée par macOS (`tapDisabledByTimeout` ou `tapDisabledByUserInput`) : fn est relâchée sans être vue.
        keyboard.held = false
        keyboard.resume(at: 2_000)
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
        #expect(!keyboard.logic.chordDown)
        // Le raccourci répond aussitôt, maintien comme double appui.
        keyboard.press(fnDown(3_000))
        keyboard.advance(to: 3_200)
        keyboard.release(fnUp(3_500))
        keyboard.press(fnDown(4_000))
        keyboard.release(fnUp(4_050))
        keyboard.press(fnDown(4_150))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk, .startPushToTalk, .stopPushToTalk, .startToggle])
    }

    @Test func aPressLostDuringACutNeverStartsADictation() {
        var keyboard = Keyboard()
        // fn enfoncée pendant la coupure : rien n'est vu, la reprise la trouve tenue.
        keyboard.held = true
        keyboard.resume(at: 1_100)
        keyboard.advance(to: 1_400)
        // Seul son relâchement est vu : aucun geste, même long.
        keyboard.release(fnUp(1_500))
        keyboard.advance(to: 3_000)
        #expect(keyboard.effects.isEmpty)
        keyboard.press(fnDown(3_000))
        keyboard.advance(to: 3_200)
        #expect(keyboard.effects == [.startPushToTalk])
    }

    @Test func aResumeWhileTheKeyIsStillHeldKeepsTheHoldUntilItsRealRelease() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.advance(to: 1_200)
        keyboard.resume(at: 1_500)
        #expect(keyboard.effects == [.startPushToTalk])
        keyboard.release(fnUp(2_500))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
    }

    @Test func aCustomShortcutHeldDuringACutIsReleasedAndTheKeyGoesBackToTheApp() {
        var keyboard = Keyboard(HotkeyConfig(keyCode: space, modifierFlags: option))
        #expect(keyboard.press(key(.down, space, option, at: 1_000)).swallow)
        keyboard.advance(to: 1_200)
        keyboard.held = false
        keyboard.resume(at: 1_600)
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
        // Une espace tapée ensuite atteint l'app, enfoncement et relâchement.
        #expect(!keyboard.see(key(.down, space, at: 2_000)).swallow)
        #expect(!keyboard.see(key(.up, space, at: 2_080)).swallow)
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
    }

    @Test func escapeAndPasteHeldDuringACutAreNeverSwallowedAfterward() {
        var keyboard = Keyboard(HotkeyConfig(capturing: true, paste: .standard))
        #expect(keyboard.see(key(.down, escape, at: 1_000)).swallow)
        #expect(keyboard.see(key(.down, PasteShortcut.vKeyCode, ModifierMask.control | option, at: 1_100)).swallow)
        keyboard.resume(at: 1_500)
        keyboard.config = HotkeyConfig(paste: .standard)
        #expect(!keyboard.see(key(.down, escape, at: 2_000)).swallow)
        #expect(!keyboard.see(key(.up, escape, at: 2_080)).swallow)
        #expect(!keyboard.see(key(.down, PasteShortcut.vKeyCode, at: 2_200)).swallow)
        #expect(keyboard.cancels == 1)
        #expect(keyboard.pastes == 1)
    }

    // MARK: - Écoute retirée (autorisation retirée dans Réglages Système), puis rendue

    @Test func aHoldWhoseListeningIsWithdrawnIsForgottenAndTheShortcutWorksOnceItComesBack() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.advance(to: 1_200)
        #expect(keyboard.effects == [.startPushToTalk])
        // Autorisation retirée, fn encore tenue : plus rien ne sera vu. Le geste est oublié sans effet, l'app arrête
        // la dictée elle-même et dit pourquoi.
        keyboard.lose()
        #expect(keyboard.effects == [.startPushToTalk])
        #expect(!keyboard.logic.chordDown)
        #expect(keyboard.logic.engine.isIdle)
        // Autorisation rendue : maintien comme double appui répondent dès le premier appui.
        keyboard.held = false
        keyboard.press(fnDown(30_000))
        keyboard.advance(to: 30_200)
        keyboard.release(fnUp(30_500))
        keyboard.press(fnDown(31_000))
        keyboard.release(fnUp(31_050))
        keyboard.press(fnDown(31_150))
        #expect(keyboard.effects == [.startPushToTalk, .startPushToTalk, .stopPushToTalk, .startToggle])
    }

    @Test func aWithdrawnListeningNeverStartsAPendingPressOrKeepsHandsFreeLatched() {
        var keyboard = Keyboard()
        // Premier appui en attente de son maintien quand l'écoute est retirée : il ne démarrera jamais.
        keyboard.press(fnDown(1_000))
        keyboard.lose()
        keyboard.advance(to: 2_000)
        #expect(keyboard.effects.isEmpty)
        // Mains libres retiré : l'appui suivant, écoute rendue, commence un nouveau geste au lieu d'arrêter.
        keyboard.held = false
        keyboard.press(fnDown(3_000))
        keyboard.release(fnUp(3_050))
        keyboard.press(fnDown(3_150))
        #expect(keyboard.effects == [.startToggle])
        keyboard.lose()
        keyboard.release(fnUp(3_200))
        keyboard.press(fnDown(5_000))
        keyboard.advance(to: 5_200)
        #expect(keyboard.effects == [.startToggle, .startPushToTalk])
    }

    @Test func escapeAndPasteSwallowedWhenTheListeningIsWithdrawnAreNeverSwallowedAfterward() {
        var keyboard = Keyboard(HotkeyConfig(capturing: true, paste: .standard))
        #expect(keyboard.see(key(.down, escape, at: 1_000)).swallow)
        #expect(keyboard.see(key(.down, PasteShortcut.vKeyCode, ModifierMask.control | option, at: 1_100)).swallow)
        keyboard.lose()
        keyboard.config = HotkeyConfig(paste: .standard)
        #expect(!keyboard.see(key(.up, escape, at: 2_000)).swallow)
        #expect(!keyboard.see(key(.up, PasteShortcut.vKeyCode, at: 2_050)).swallow)
        #expect(!keyboard.see(key(.down, escape, at: 2_100)).swallow)
        #expect(keyboard.cancels == 1)
        #expect(keyboard.pastes == 1)
    }

    // MARK: - Relâchement jamais vu, écoute restée active (veille, écran verrouillé, autre session, saisie sécurisée)

    @Test func aHoldReleasedWhileListeningSawNothingStopsAtTheNextCheck() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.advance(to: 1_200)
        // Écran verrouillé, autre session ou saisie sécurisée : l'écoute reste active mais ne reçoit rien, et
        // macOS ne la coupe pas. Rien d'autre ne termine la dictée, même une minute plus tard.
        keyboard.held = false
        keyboard.advance(to: 61_000)
        #expect(keyboard.logic.engine.isPushing)
        // La surveillance de 3 s lit la touche réelle : la dictée s'arrête et le raccourci est libre.
        keyboard.check(at: 61_000)
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
        #expect(!keyboard.logic.chordDown)
        keyboard.press(fnDown(62_000))
        keyboard.advance(to: 62_200)
        keyboard.release(fnUp(62_500))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk, .startPushToTalk, .stopPushToTalk])
    }

    @Test func theCheckLeavesAHeldKeyAloneDuringALongHold() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        for check in stride(from: 3_000, through: 30_000, by: 3_000) {
            keyboard.check(at: check)
        }
        #expect(keyboard.effects == [.startPushToTalk])
        keyboard.release(fnUp(31_000))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
    }

    @Test func theCheckNeverBreaksAPressAwaitingItsHold() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        // La touche est déjà levée mais son relâchement n'est pas encore traité quand la surveillance passe.
        keyboard.held = false
        keyboard.check(at: 1_050)
        keyboard.see(fnUp(1_040), processedAt: 1_060)
        // C'était le premier appui d'un double appui : il compte toujours.
        keyboard.press(fnDown(1_200))
        #expect(keyboard.effects == [.startToggle])
    }

    @Test func handsFreeWhoseReleaseWasNeverSeenStaysOnAndTheNextPressStopsIt() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.release(fnUp(1_050))
        keyboard.press(fnDown(1_150))
        keyboard.held = false
        keyboard.check(at: 3_000)
        #expect(keyboard.effects == [.startToggle])
        #expect(keyboard.logic.engine.isToggleLatched)
        keyboard.press(fnDown(5_000))
        keyboard.release(fnUp(5_080))
        #expect(keyboard.effects == [.startToggle, .stopToggle])
    }

    @Test func theCheckNeverReleasesAnEscapeHeldDuringTheDictation() {
        var keyboard = Keyboard(HotkeyConfig(capturing: true))
        #expect(keyboard.see(key(.down, escape, at: 1_000)).swallow)
        keyboard.check(at: 3_000)
        keyboard.config = HotkeyConfig()
        #expect(keyboard.see(key(.down, escape, autorepeat: true, at: 3_100)).swallow)
        #expect(keyboard.see(key(.up, escape, at: 3_200)).swallow)
        #expect(keyboard.cancels == 1)
    }

    @Test func aReleaseNeverReceivedFreesTheShortcutOnceTheHoldWaitGivesUp() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        // Veille ou session quittée aussitôt après l'appui : fn est relâchée sans que rien ne soit vu. L'horloge
        // des frappes ne compte pas la veille ; le réveil du maintien lit la touche levée, attend puis abandonne.
        keyboard.held = false
        keyboard.advance(to: 2_000)
        #expect(keyboard.effects.isEmpty)
        #expect(!keyboard.logic.chordDown)
        // L'appui suivant n'est pas perdu.
        keyboard.press(fnDown(2_500))
        keyboard.advance(to: 2_700)
        keyboard.release(fnUp(3_000))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
    }

    @Test func aLateReleaseStillDecidesBetweenATapAndAHold() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.held = false
        // Relâchement réel à +80 ms, traité après le réveil du maintien : c'est un simple appui…
        keyboard.see(fnUp(1_080), processedAt: 1_300)
        #expect(keyboard.effects.isEmpty)
        #expect(!keyboard.logic.chordDown)
        // … et l'appui suivant forme un double appui.
        keyboard.press(fnDown(1_310))
        #expect(keyboard.effects == [.startToggle])
    }

    // MARK: - Saisie sécurisée (champ de mot de passe)

    @Test func secureInputDuringAHoldNeverLeavesTheDictationOpen() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.advance(to: 1_200)
        // Un champ de mot de passe prend la saisie : macOS coupe l'écoute alors que fn est encore tenue.
        keyboard.resume(at: 1_500)
        #expect(keyboard.effects == [.startPushToTalk])
        // fn relâchée pendant la saisie sécurisée : la surveillance trouve l'écoute de nouveau coupée.
        keyboard.held = false
        keyboard.resume(at: 4_500)
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
        // Saisie sécurisée terminée : le raccourci répond.
        keyboard.press(fnDown(6_000))
        keyboard.advance(to: 6_200)
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk, .startPushToTalk])
    }

    @Test func anEscapeWhoseReleaseWasLostIsNeverSwallowedAgainAtRest() {
        var keyboard = Keyboard(HotkeyConfig(capturing: true))
        #expect(keyboard.see(key(.down, escape, at: 1_000)).swallow)
        #expect(keyboard.see(key(.down, escape, autorepeat: true, at: 1_500)).swallow)
        // Relâchement perdu (champ de mot de passe, écoute muette) ; la dictée est annulée, Wispad au repos.
        keyboard.config = HotkeyConfig()
        let next = keyboard.see(key(.down, escape, at: 5_000))
        #expect(!next.swallow)
        #expect(!next.cancel)
        #expect(!keyboard.see(key(.up, escape, at: 5_080)).swallow)
        #expect(keyboard.cancels == 1)
    }

    @Test func anEscapeWhoseReleaseWasLostStillCancelsTheNextDictation() {
        var keyboard = Keyboard(HotkeyConfig(capturing: true))
        _ = keyboard.see(key(.down, escape, at: 1_000))
        let next = keyboard.see(key(.down, escape, at: 5_000))
        #expect(next.cancel)
        #expect(next.swallow)
        #expect(keyboard.see(key(.up, escape, at: 5_080)).swallow)
        #expect(keyboard.cancels == 2)
    }

    // MARK: - Touche de modification relâchée sans être vue (état collé)

    @Test func aModifierReleasedUnseenEndsTheCustomShortcutAtTheNextEventThatShowsIt() {
        var keyboard = Keyboard(HotkeyConfig(keyCode: space, modifierFlags: option))
        keyboard.press(key(.down, space, option, at: 1_000))
        keyboard.advance(to: 1_200)
        // ⌥ relâchée sans être vue : la frappe suivante porte les modificateurs réels.
        _ = keyboard.see(KeyEvent(phase: .flags, keyCode: 56, flags: ModifierMask.shift, time: 2_000))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
        keyboard.release(key(.up, space, ModifierMask.shift, at: 2_100))
        keyboard.press(key(.down, space, option, at: 3_000))
        keyboard.advance(to: 3_200)
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk, .startPushToTalk])
    }

    @Test func aKeyReleasedWithItsModifierUnseenEndsAtItsOwnRelease() {
        var keyboard = Keyboard(HotkeyConfig(keyCode: space, modifierFlags: option))
        keyboard.press(key(.down, space, option, at: 1_000))
        keyboard.advance(to: 1_200)
        let up = keyboard.release(key(.up, space, at: 1_500))
        #expect(up.swallow)
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
        #expect(!keyboard.logic.chordDown)
    }

    @Test func thePasteShortcutPastesAgainAfterItsReleaseWasLost() {
        let ctrlOpt = ModifierMask.control | option
        var keyboard = Keyboard(HotkeyConfig(paste: .standard))
        _ = keyboard.see(key(.down, PasteShortcut.vKeyCode, ctrlOpt, at: 1_000))
        #expect(keyboard.see(key(.down, PasteShortcut.vKeyCode, ctrlOpt, autorepeat: true, at: 1_500)).swallow)
        // ⌃⌥ et V relâchées sans être vues, puis le raccourci de nouveau : il recolle, une seule fois.
        #expect(keyboard.see(key(.down, PasteShortcut.vKeyCode, ctrlOpt, at: 4_000)).pasteLast)
        #expect(keyboard.see(key(.up, PasteShortcut.vKeyCode, ctrlOpt, at: 4_080)).swallow)
        #expect(keyboard.pastes == 2)
        #expect(keyboard.effects.isEmpty)
    }

    // MARK: - Appuis très rapides, répétition automatique

    @Test func autorepeatOfACustomShortcutNeverStartsOrRestartsIt() {
        var keyboard = Keyboard(HotkeyConfig(keyCode: f5, modifierFlags: fKey))
        keyboard.press(key(.down, f5, fKey, at: 1_000))
        for time in stride(from: 1_033, through: 2_000, by: 33) {
            #expect(keyboard.see(key(.down, f5, fKey, autorepeat: true, at: time)).swallow)
        }
        keyboard.release(key(.up, f5, fKey, at: 2_010))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
        // Répétition d'un appui que l'écoute n'a pas vu commencer : elle reste à l'app et ne démarre rien.
        keyboard.held = true
        for time in stride(from: 3_033, through: 3_500, by: 33) {
            #expect(!keyboard.see(key(.down, f5, fKey, autorepeat: true, at: time)).swallow)
        }
        #expect(!keyboard.release(key(.up, f5, fKey, at: 3_510)).swallow)
        keyboard.advance(to: 5_000)
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
    }

    @Test func tripleAndQuadrupleTapsAlternateWithoutSticking() {
        var keyboard = Keyboard()
        for (index, time) in stride(from: 1_000, to: 1_800, by: 200).enumerated() {
            keyboard.press(fnDown(time))
            keyboard.release(fnUp(time + 50))
            #expect(!keyboard.logic.chordDown, "appui \(index + 1)")
        }
        // 2ᵉ appui : mains libres ; 3ᵉ : arrêt ; 4ᵉ : nouveau premier appui, sans effet.
        keyboard.advance(to: 3_000)
        #expect(keyboard.effects == [.startToggle, .stopToggle])
        keyboard.press(fnDown(3_000))
        keyboard.advance(to: 3_200)
        #expect(keyboard.effects == [.startToggle, .stopToggle, .startPushToTalk])
    }

    @Test func burstsOfVeryFastPressesNeverLeaveTheShortcutDeadOrStuck() {
        forAll(1_200, seed: 0x7261_7069_6465, { Burst.fast(&$0) }) { burst in
            var keyboard = Keyboard()
            let end = play(burst, on: &keyboard) + 2_000
            keyboard.advance(to: end)
            return deadOrStuck(&keyboard, at: end).map { "\($0) — \(burst)" }
        }
    }

    @Test func burstsWithPressesAndReleasesLostNeverLeaveTheShortcutDeadOrStuck() {
        forAll(1_200, seed: 0x7065_7264_7565, { Burst.lossy(&$0) }) { burst in
            var keyboard = Keyboard()
            let time = play(burst, on: &keyboard)
            // Plus rien n'est perdu : macOS rend l'écoute qu'il avait coupée, ou la surveillance de 3 s passe sur
            // une écoute restée active.
            if burst.resumed { keyboard.resume(at: time) }
            keyboard.check(at: time + 3_000)
            keyboard.advance(to: time + 5_000)
            return deadOrStuck(&keyboard, at: time + 5_000).map { "\($0) — \(burst)" }
        }
    }

    // MARK: - Raccourci modifié pendant une dictée

    @Test func recordingFnWhileFnIsTheShortcutNeverStartsADictation() {
        var keyboard = Keyboard(HotkeyConfig(recording: true))
        // Réglages › Raccourci › Modifier, puis fn tenue un instant pour la choisir.
        keyboard.press(fnDown(1_000))
        keyboard.advance(to: 1_300)
        keyboard.release(fnUp(1_300))
        #expect(keyboard.effects.isEmpty)
        #expect(keyboard.captured == [fn])
        #expect(!keyboard.logic.chordDown)
        // Enregistrement terminé : le premier maintien dicte.
        keyboard.config = HotkeyConfig()
        keyboard.press(fnDown(2_000))
        keyboard.advance(to: 2_200)
        keyboard.release(fnUp(2_500))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
    }

    @Test func aHoldInProgressWhenRecordingStartsStopsAtItsRelease() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.advance(to: 1_200)
        // Modifier cliqué pendant le maintien : fn relâchée est enregistrée et termine la dictée.
        keyboard.config.recording = true
        keyboard.release(fnUp(2_000))
        #expect(keyboard.captured == [fn])
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
        #expect(!keyboard.logic.chordDown)
    }

    @Test func recordingAnotherKeyWhileFnIsHeldEndsTheHold() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.advance(to: 1_200)
        keyboard.config.recording = true
        let recorded = keyboard.see(key(.down, f5, fKey, at: 1_500))
        #expect(recorded.swallow)
        #expect(keyboard.captured == [f5])
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
    }

    @Test func aCustomShortcutReplacedWhileHeldStopsAtItsReleaseAndTheNewOneWorks() {
        var keyboard = Keyboard(HotkeyConfig(keyCode: f5, modifierFlags: fKey))
        keyboard.press(key(.down, f5, fKey, at: 1_000))
        keyboard.advance(to: 1_200)
        // Nouveau raccourci (F6) choisi pendant que F5 dicte encore : F5 relâchée termine la dictée.
        keyboard.config = HotkeyConfig(keyCode: f6, modifierFlags: fKey)
        keyboard.release(key(.up, f5, fKey, at: 2_000))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk])
        keyboard.press(key(.down, f6, fKey, at: 3_000))
        keyboard.advance(to: 3_200)
        keyboard.release(key(.up, f6, fKey, at: 3_500))
        #expect(keyboard.effects == [.startPushToTalk, .stopPushToTalk, .startPushToTalk, .stopPushToTalk])
    }

    @Test func handsFreeContinuesWhileTheShortcutIsChangedAndTheNewOneStopsIt() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.release(fnUp(1_050))
        keyboard.press(fnDown(1_150))
        keyboard.release(fnUp(1_250))
        // Réglages › Raccourci › Modifier pendant la dictée mains libres, puis F5.
        keyboard.config.recording = true
        #expect(keyboard.see(key(.down, f5, fKey, at: 3_000)).swallow)
        #expect(keyboard.captured == [f5])
        keyboard.config = HotkeyConfig(keyCode: f5, modifierFlags: fKey)
        _ = keyboard.see(key(.up, f5, fKey, at: 3_080))
        #expect(keyboard.effects == [.startToggle])
        keyboard.press(key(.down, f5, fKey, at: 5_000))
        keyboard.release(key(.up, f5, fKey, at: 5_080))
        #expect(keyboard.effects == [.startToggle, .stopToggle])
    }

    @Test func recordingFnAgainDuringHandsFreeLeavesItRunningUntilTheNextPress() {
        var keyboard = Keyboard()
        keyboard.press(fnDown(1_000))
        keyboard.release(fnUp(1_050))
        keyboard.press(fnDown(1_150))
        keyboard.release(fnUp(1_250))
        keyboard.config.recording = true
        keyboard.press(fnDown(3_000))
        keyboard.release(fnUp(3_100))
        #expect(keyboard.captured == [fn])
        #expect(keyboard.effects == [.startToggle])
        keyboard.config.recording = false
        keyboard.press(fnDown(5_000))
        keyboard.release(fnUp(5_080))
        #expect(keyboard.effects == [.startToggle, .stopToggle])
    }

    // MARK: - Rafales

    /// Joue une rafale comme l'écoute la recevrait ; rend l'instant où elle se termine. Les frappes sont traitées
    /// dans l'ordre, parfois en retard (fil de l'écoute occupé), jamais avant d'avoir eu lieu.
    private func play(_ burst: Burst, on keyboard: inout Keyboard) -> Int {
        var time = 1_000
        var processed = time
        for tap in burst.taps {
            let press = time + tap.gap
            let release = press + tap.length
            processed = max(press, processed)
            if tap.pressSeen {
                keyboard.press(fnDown(press), processedAt: processed)
            } else {
                keyboard.advance(to: press)
                keyboard.held = true
            }
            if let resume = tap.resume {
                keyboard.resume(at: press + resume)
            }
            processed = max(release + tap.lateRelease, processed)
            if tap.releaseSeen {
                keyboard.release(fnUp(release), processedAt: processed)
            } else {
                keyboard.advance(to: release)
                keyboard.held = false
            }
            time = release
            if let check = tap.check {
                keyboard.check(at: release + check)
                time = release + check
            }
        }
        return max(time, processed, keyboard.now)
    }

    /// Après une rafale, touche relâchée et écoute rendue : rien n'est resté enfoncé ni ouvert, chaque maintien
    /// s'est arrêté, les mains libres alternent, et le raccourci répond encore (arrêt, puis maintien). Rend ce qui
    /// cloche, ou nil.
    private func deadOrStuck(_ keyboard: inout Keyboard, at time: Int) -> String? {
        if keyboard.logic.chordDown { return "accord resté enfoncé" }
        if keyboard.logic.engine.isPushing { return "maintien jamais arrêté" }
        let starts = keyboard.effects.filter { $0 == .startPushToTalk }.count
        let stops = keyboard.effects.filter { $0 == .stopPushToTalk }.count
        if starts != stops { return "\(starts) maintiens pour \(stops) arrêts" }
        let toggles = keyboard.effects.filter { $0 == .startToggle || $0 == .stopToggle }
        let alternating = toggles.enumerated().allSatisfy { $0.element == ($0.offset.isMultiple(of: 2) ? .startToggle : .stopToggle) }
        if !alternating { return "mains libres dans le désordre : \(toggles)" }
        var next = time
        if keyboard.logic.engine.isToggleLatched {
            keyboard.press(fnDown(next))
            keyboard.release(fnUp(next + 60))
            next += 1_000
            keyboard.advance(to: next)
            if keyboard.effects.last != .stopToggle { return "mains libres qu'un appui n'arrête pas" }
        }
        let before = keyboard.effects.count
        keyboard.press(fnDown(next))
        keyboard.advance(to: next + 300)
        keyboard.release(fnUp(next + 400))
        let answer = Array(keyboard.effects.dropFirst(before))
        return answer == [.startPushToTalk, .stopPushToTalk] ? nil : "maintien suivant sans réponse : \(answer)"
    }
}

/// Rafale d'appuis sur fn tirée d'une graine fixe.
private struct Burst: CustomStringConvertible {
    var taps: [Tap]
    /// À la fin, macOS rend l'écoute qu'il avait coupée ; sinon seule la surveillance passe, sur une écoute restée active.
    var resumed = false

    /// Appuis très rapides, tous vus ; des relâchements traités en retard.
    static func fast(_ g: inout SeededGenerator) -> Burst {
        Burst(taps: (0..<g.int(1...14)).map { _ in
            Tap(gap: g.int(0...420), length: g.int(0...420), lateRelease: g.chance(50) ? g.int(0...150) : 0)
        })
    }

    /// Chaque frappe peut se perdre (écoute coupée ou muette : veille, verrou, autre session, saisie sécurisée) ;
    /// l'écoute coupée est parfois rendue pendant un appui, la surveillance passe parfois après un relâchement.
    static func lossy(_ g: inout SeededGenerator) -> Burst {
        let taps = (0..<g.int(1...14)).map { _ in
            let length = g.int(0...700)
            return Tap(
                gap: g.int(0...700), length: length, pressSeen: !g.chance(25), releaseSeen: !g.chance(25),
                resume: g.chance(33) ? g.int(0...length) : nil, check: g.chance(33) ? g.int(0...3_000) : nil
            )
        }
        return Burst(taps: taps, resumed: g.chance(50))
    }

    var description: String {
        (resumed ? "écoute rendue à la fin ; " : "") + taps.map(\.description).joined(separator: " ")
    }
}

/// Un appui d'une rafale : silence avant l'enfoncement et durée de l'appui (ms), relâchement traité en retard,
/// frappes perdues, écoute rendue pendant l'appui (ms après l'enfoncement), surveillance après le relâchement.
private struct Tap: CustomStringConvertible {
    var gap: Int
    var length: Int
    var lateRelease = 0
    var pressSeen = true
    var releaseSeen = true
    var resume: Int?
    var check: Int?

    var description: String {
        var text = "+\(gap)\(pressSeen ? "" : "~")↓\(length)\(releaseSeen ? "" : "~")↑"
        if lateRelease > 0 { text += " tard \(lateRelease)" }
        if let resume { text += " rendue \(resume)" }
        if let check { text += " vérifiée \(check)" }
        return "[\(text)]"
    }
}

/// L'écoute du clavier comme KeyboardTap la mène, sans macOS : frappes horodatées (traitées à leur heure ou en
/// retard), réveils prévus par le geste, reprise quand macOS rend l'écoute (`resync`) et surveillance de 3 s
/// (`reconcile`). `held` est l'état matériel du raccourci, que KeyboardTap lit au réveil et à la surveillance.
private struct Keyboard {
    var logic = HotkeyLogic()
    var config: HotkeyConfig
    var held = false
    private(set) var now = 0
    private(set) var wake: Int?
    private(set) var effects: [GestureEffect] = []
    private(set) var captured: [Int] = []
    private(set) var cancels = 0
    private(set) var pastes = 0

    init(_ config: HotkeyConfig = HotkeyConfig()) {
        self.config = config
    }

    /// Le raccourci enfoncé, vu par l'écoute (traité à `processedAt`, par défaut à son heure).
    @discardableResult
    mutating func press(_ event: KeyEvent, processedAt: Int? = nil) -> HotkeyOutput {
        advance(to: event.time)
        held = true
        return see(event, processedAt: processedAt)
    }

    /// Le raccourci relâché, vu par l'écoute.
    @discardableResult
    mutating func release(_ event: KeyEvent, processedAt: Int? = nil) -> HotkeyOutput {
        advance(to: event.time)
        held = false
        return see(event, processedAt: processedAt)
    }

    /// Une frappe vue par l'écoute : les réveils échus avant son traitement passent d'abord.
    @discardableResult
    mutating func see(_ event: KeyEvent, processedAt: Int? = nil) -> HotkeyOutput {
        advance(to: processedAt ?? event.time)
        return apply(logic.handle(event, config: config))
    }

    /// Le temps passe : chaque réveil échu lit l'état réel de la touche.
    mutating func advance(to time: Int) {
        while let due = wake, due <= time {
            wake = nil
            now = max(now, due)
            apply(logic.tick(at: due, keyStillDown: held))
        }
        now = max(now, time)
    }

    /// macOS rend l'écoute qu'il avait coupée (ou la surveillance la trouve coupée) : reprise sur la touche réelle.
    mutating func resume(at time: Int) {
        advance(to: time)
        apply(logic.resync(keyPhysicallyDown: held, at: now))
    }

    /// Surveillance de 3 s, écoute restée active.
    mutating func check(at time: Int) {
        advance(to: time)
        apply(logic.reconcile(keyPhysicallyDown: held, at: now))
    }

    /// Autorisation retirée : l'écoute est retirée, son réveil annulé et le geste oublié, comme dans KeyboardTap.
    mutating func lose() {
        wake = nil
        logic.listeningLost()
    }

    @discardableResult
    private mutating func apply(_ output: HotkeyOutput) -> HotkeyOutput {
        if case .reschedule(let time) = output.wake { wake = time }
        effects += output.effects
        if let keyCode = output.capturedKeyCode { captured.append(keyCode) }
        if output.cancel { cancels += 1 }
        if output.pasteLast { pastes += 1 }
        return output
    }
}
