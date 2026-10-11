import Foundation
import Testing
@testable import WispadCore

struct OnboardingFlowTests {
    // MARK: Progression

    @Test func stepsFollowTheGuideOrder() {
        #expect(OnboardingStep.allCases == [.welcome, .permissions, .microphone, .provider, .shortcut, .trial, .finish])
        #expect(OnboardingStep.welcome.next == .permissions)
        #expect(OnboardingStep.finish.next == nil)
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.trial.previous == .shortcut)
    }

    @Test func checkedStepsNeedSuccessToContinue() {
        #expect(OnboardingFlow.canContinue(.welcome, status: .todo))
        #expect(OnboardingFlow.canContinue(.finish, status: .todo))
        for step in OnboardingStep.allCases where step.isChecked {
            #expect(!OnboardingFlow.canContinue(step, status: .todo))
            #expect(!OnboardingFlow.canContinue(step, status: .inProgress))
            #expect(!OnboardingFlow.canContinue(step, status: .failed(.silence)))
            #expect(OnboardingFlow.canContinue(step, status: .succeeded))
        }
    }

    @Test func laterIsOfferedOnlyWhereDictationStillWorks() {
        #expect(OnboardingStep.allCases.filter(\.allowsLater) == [.microphone, .shortcut, .trial])
    }

    @Test func resumeReadsTheSavedStepTolerantly() {
        #expect(OnboardingFlow.resumeStep(saved: nil) == .welcome)
        #expect(OnboardingFlow.resumeStep(saved: "permissions") == .permissions)
        #expect(OnboardingFlow.resumeStep(saved: "tryIt") == .welcome)
        #expect(OnboardingFlow.resumeStep(saved: "finish") == .welcome)
    }

    @Test func eachProblemPointsToTheStepThatFixesIt() {
        #expect(OnboardingFlow.stepToFix(.permission(.accessibility, .waiting)) == .permissions)
        #expect(OnboardingFlow.stepToFix(.silence) == .microphone)
        #expect(OnboardingFlow.stepToFix(.key(.rejected(401))) == .provider)
        #expect(OnboardingFlow.stepToFix(.noKeyEvent) == .shortcut)
        #expect(OnboardingFlow.stepToFix(.trial(.paste)) == .permissions)
        #expect(OnboardingFlow.stepToFix(.trial(.network)) == nil)
    }

    // MARK: Autorisations

    @Test func permissionStatesFollowMacOSAnswers() {
        #expect(PermissionsCheck.microphone(granted: true, denied: false, requested: false) == .granted)
        #expect(PermissionsCheck.microphone(granted: false, denied: true, requested: false) == .denied)
        #expect(PermissionsCheck.microphone(granted: false, denied: false, requested: true) == .waiting)
        #expect(PermissionsCheck.microphone(granted: false, denied: false, requested: false) == .notRequested)
        #expect(PermissionsCheck.accessibility(trusted: false, requested: true) == .waiting)
        #expect(PermissionsCheck.accessibility(trusted: true, requested: false) == .granted)
    }

    @Test func inputMonitoringGrantedWithoutListenerNeedsARelaunch() {
        #expect(PermissionsCheck.inputMonitoring(trusted: true, listening: true, requested: true) == .granted)
        #expect(PermissionsCheck.inputMonitoring(trusted: true, listening: false, requested: true) == .needsRelaunch)
        #expect(PermissionsCheck.inputMonitoring(trusted: false, listening: false, requested: true) == .waiting)
        #expect(PermissionsCheck.inputMonitoring(trusted: true, listening: false, requested: true, settling: true) == .waiting)
        let states: [PermissionKind: PermissionState] = [.microphone: .granted, .accessibility: .granted, .inputMonitoring: .needsRelaunch]
        #expect(PermissionsCheck.needsRelaunch(states))
        #expect(PermissionsCheck.status(states) == .failed(.permission(.inputMonitoring, .needsRelaunch)))
    }

    @Test func permissionsSucceedOnlyWhenAllAreGranted() {
        var states: [PermissionKind: PermissionState] = [:]
        #expect(PermissionsCheck.status(states) == .todo)
        #expect(PermissionsCheck.next(states) == .microphone)
        states[.microphone] = .granted
        #expect(PermissionsCheck.status(states) == .inProgress)
        #expect(PermissionsCheck.next(states) == .accessibility)
        states[.accessibility] = .granted
        states[.inputMonitoring] = .waiting
        #expect(PermissionsCheck.status(states) == .inProgress)
        states[.inputMonitoring] = .granted
        #expect(PermissionsCheck.status(states) == .succeeded)
        #expect(PermissionsCheck.next(states) == nil)
        states[.microphone] = .denied
        #expect(PermissionsCheck.status(states) == .failed(.permission(.microphone, .denied)))
    }

    @Test func settingsPanesAreTheRightOnes() {
        #expect(PermissionKind.microphone.settingsAnchor == "Privacy_Microphone")
        #expect(PermissionKind.accessibility.settingsAnchor == "Privacy_Accessibility")
        #expect(PermissionKind.inputMonitoring.settingsAnchor == "Privacy_ListenEvent")
    }

    // MARK: Micro

    @Test func levelsAreMeasuredInDecibels() {
        #expect(SignalLevel.decibels(rms: 1) == 0)
        #expect(abs(SignalLevel.decibels(rms: 0.1) + 20) < 0.0001)
        #expect(SignalLevel.decibels(rms: 0) == SignalLevel.silence)
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        let level = samples.withUnsafeBufferPointer { SignalLevel.decibels(samples: $0) }
        #expect(abs(level - 20 * log10(0.5)) < 0.0001)
        #expect(SignalLevel.meterFraction(-80) == 0)
        #expect(SignalLevel.meterFraction(0) == 1)
        #expect(SignalLevel.meterFraction(-35) == 0.5)
    }

    @Test func voiceAboveTheRoomIsDetected() {
        var detector = VoiceDetector()
        for _ in 0..<20 { detector.add(level: -62, seconds: 0.05) }
        #expect(!detector.detected)
        for _ in 0..<14 { detector.add(level: -28, seconds: 0.05) }
        #expect(detector.detected)
        #expect(detector.progress == 1)
    }

    @Test func clicksAndSteadyNoiseAreNotAVoice() {
        var click = VoiceDetector()
        for _ in 0..<20 { click.add(level: -60, seconds: 0.05) }
        for _ in 0..<4 { click.add(level: -20, seconds: 0.05) }
        for _ in 0..<20 { click.add(level: -60, seconds: 0.05) }
        #expect(!click.detected)

        var fan = VoiceDetector()
        for _ in 0..<200 { fan.add(level: -32, seconds: 0.05) }
        #expect(!fan.detected)

        var whisper = VoiceDetector()
        for _ in 0..<100 { whisper.add(level: -75, seconds: 0.05) }
        for _ in 0..<40 { whisper.add(level: -55, seconds: 0.05) }
        #expect(!whisper.detected)
    }

    @Test func voiceIsHeardOverANoisyRoom() {
        var detector = VoiceDetector()
        for _ in 0..<60 { detector.add(level: -40, seconds: 0.05) }
        for _ in 0..<16 { detector.add(level: -24, seconds: 0.05) }
        #expect(detector.detected)
    }

    @Test func microphoneStepSucceedsOnlyWithARealVoice() {
        var detector = VoiceDetector()
        #expect(MicrophoneCheck.status(permission: .granted, hasInputDevice: true, meterFailed: false, detector: detector) == .todo)
        #expect(MicrophoneCheck.status(permission: .denied, hasInputDevice: true, meterFailed: false, detector: detector) == .failed(.permission(.microphone, .denied)))
        #expect(MicrophoneCheck.status(permission: .granted, hasInputDevice: false, meterFailed: false, detector: detector) == .failed(.noInputDevice))
        #expect(MicrophoneCheck.status(permission: .granted, hasInputDevice: true, meterFailed: true, detector: detector) == .failed(.microphoneUnavailable))
        detector.add(level: -70, seconds: 1)
        #expect(MicrophoneCheck.status(permission: .granted, hasInputDevice: true, meterFailed: false, detector: detector) == .inProgress)
        detector.add(level: -70, seconds: MicrophoneCheck.silenceTimeout)
        #expect(MicrophoneCheck.status(permission: .granted, hasInputDevice: true, meterFailed: false, detector: detector) == .failed(.silence))
        detector.add(level: -25, seconds: 1)
        #expect(MicrophoneCheck.status(permission: .granted, hasInputDevice: true, meterFailed: false, detector: detector) == .succeeded)
    }

    @Test func unpluggedMicrophoneFallsBackToTheSystemOne() {
        #expect(InputDeviceChoice.effectiveUID(saved: "usb-mic", available: ["builtin", "usb-mic"]) == "usb-mic")
        #expect(InputDeviceChoice.effectiveUID(saved: "usb-mic", available: ["builtin"]) == nil)
        #expect(InputDeviceChoice.effectiveUID(saved: nil, available: ["builtin"]) == nil)
    }

    // MARK: Fournisseur

    @Test func keyAnswersAreReadLikeTheProvidersScreen() {
        #expect(KeyCheck.from(httpStatus: 200) == .valid)
        #expect(KeyCheck.from(httpStatus: 401) == .rejected(401))
        #expect(KeyCheck.from(httpStatus: 403) == .rejected(403))
        #expect(KeyCheck.from(httpStatus: 500) == .unverified(500))
    }

    @Test func providerStepNeedsAValidVoiceKey() {
        #expect(ProviderCheck.status(voice: .missing) == .todo)
        #expect(ProviderCheck.status(voice: .verifying) == .inProgress)
        #expect(ProviderCheck.status(voice: .valid) == .succeeded)
        #expect(ProviderCheck.status(voice: .rejected(401)) == .failed(.key(.rejected(401))))
        #expect(ProviderCheck.status(voice: .offline) == .failed(.key(.offline)))
    }

    // MARK: Touche

    @Test func anyKeyPressConfirmsTheShortcut() {
        var probe = ShortcutProbe()
        #expect(ShortcutCheck.status(probe: probe, waited: 1, inputMonitoring: .granted) == .todo)
        #expect(ShortcutCheck.status(probe: probe, waited: ShortcutCheck.patience, inputMonitoring: .granted) == .failed(.noKeyEvent))
        #expect(ShortcutCheck.status(probe: probe, waited: 1, inputMonitoring: .waiting) == .failed(.permission(.inputMonitoring, .waiting)))
        probe.notePress()
        #expect(ShortcutCheck.status(probe: probe, waited: 1, inputMonitoring: .granted) == .succeeded)
        probe.note(.startPushToTalk)
        probe.note(.startToggle)
        #expect(probe.sawHold && probe.sawHandsFree)
    }

    @Test func fnSettingMattersOnlyForTheFnShortcut() {
        #expect(ShortcutCheck.fnSettingMatters(shortcutIsFn: true, fnUsage: 2))
        #expect(!ShortcutCheck.fnSettingMatters(shortcutIsFn: true, fnUsage: 0))
        #expect(!ShortcutCheck.fnSettingMatters(shortcutIsFn: true, fnUsage: nil))
        #expect(!ShortcutCheck.fnSettingMatters(shortcutIsFn: false, fnUsage: 2))
    }

    // MARK: Essai

    @Test func trialFailuresNameTheirCause() {
        #expect(TrialCheck.failure(for: .inserted, online: true) == nil)
        #expect(TrialCheck.failure(for: .microphoneDenied, online: true) == .microphone)
        #expect(TrialCheck.failure(for: .keyUnavailable, online: true) == .key)
        #expect(TrialCheck.failure(for: .transcriptionFailed, online: false) == .network)
        #expect(TrialCheck.failure(for: .transcriptionFailed, online: true) == .provider)
        #expect(TrialCheck.failure(for: .noSpeech, online: true) == .noSpeech)
        #expect(TrialCheck.failure(for: .insertionFailed, online: true) == .paste)
        #expect(TrialCheck.failure(for: .cancelled, online: true) == .cancelled)
    }

    @Test func trialSucceedsOnlyWhenTheDictationLandsInTheField() {
        #expect(TrialCheck.status(dictating: false, outcome: nil, online: true, textArrived: true, waited: 0) == .todo)
        #expect(TrialCheck.status(dictating: true, outcome: nil, online: true, textArrived: false, waited: 0) == .inProgress)
        #expect(TrialCheck.status(dictating: false, outcome: .inserted, online: true, textArrived: true, waited: 0) == .succeeded)
        #expect(TrialCheck.status(dictating: false, outcome: .pasteSent, online: true, textArrived: false, waited: 0.5) == .inProgress)
        #expect(TrialCheck.status(dictating: false, outcome: .pasteSent, online: true, textArrived: false, waited: TrialCheck.pasteGrace) == .failed(.trial(.paste)))
        #expect(TrialCheck.status(dictating: false, outcome: .transcriptionFailed, online: false, textArrived: false, waited: 0) == .failed(.trial(.network)))
    }
}
