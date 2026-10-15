import Foundation
import XCTest
@testable import WispadCore

final class GestureEngineTests: XCTestCase {
    func testSingleTapDoesNothing() {
        var engine = GestureEngine()
        XCTAssertEqual(engine.keyDown(at: 0).effects, [])
        XCTAssertEqual(engine.keyUp(at: 80).effects, [])
        XCTAssertEqual(engine.tick(at: 80 + 280).effects, [])
        XCTAssertFalse(engine.isToggleLatched)
        XCTAssertFalse(engine.isPushing)
    }

    func testHoldDoesNotStartBeforeThreshold() {
        var engine = GestureEngine()
        _ = engine.keyDown(at: 0)
        XCTAssertEqual(engine.tick(at: 169).effects, [])
        XCTAssertFalse(engine.isPushing)
        XCTAssertEqual(engine.tick(at: 170).effects, [.startPushToTalk])
        XCTAssertTrue(engine.isPushing)
        XCTAssertEqual(engine.keyUp(at: 900).effects, [.stopPushToTalk])
        XCTAssertFalse(engine.isPushing)
    }

    func testDoubleTapStartsAndSingleTapStopsToggle() {
        var engine = GestureEngine()
        _ = engine.keyDown(at: 0)
        _ = engine.keyUp(at: 60)
        XCTAssertEqual(engine.keyDown(at: 160), GestureStep(effects: [.startToggle]))
        XCTAssertTrue(engine.isToggleLatched)
        XCTAssertEqual(engine.keyUp(at: 220).effects, [])
        XCTAssertTrue(engine.isToggleLatched)

        XCTAssertEqual(engine.keyDown(at: 1_000).effects, [.stopToggle])
        XCTAssertFalse(engine.isToggleLatched)
        XCTAssertEqual(engine.keyUp(at: 1_050).effects, [])
        XCTAssertEqual(engine.tick(at: 1_400).effects, [])
    }

    func testStoppingTapDoesNotArmANewGesture() {
        var engine = GestureEngine()
        engine.noteExternalToggleStart()
        XCTAssertEqual(engine.keyDown(at: 0).effects, [.stopToggle])
        XCTAssertEqual(engine.keyUp(at: 40).effects, [])
        // Un appui juste après l'arrêt est un nouveau premier appui, pas la suite d'un double appui.
        _ = engine.keyDown(at: 120)
        XCTAssertEqual(engine.keyUp(at: 160).effects, [])
        XCTAssertEqual(engine.tick(at: 160 + 280).effects, [])
        XCTAssertFalse(engine.isToggleLatched)
    }

    func testSlowSecondTapIsNotADouble() {
        var engine = GestureEngine()
        _ = engine.keyDown(at: 0)
        _ = engine.keyUp(at: 40)
        XCTAssertEqual(engine.tick(at: 320).effects, [])
        _ = engine.keyDown(at: 400)
        XCTAssertEqual(engine.keyUp(at: 450).effects, [])
        XCTAssertFalse(engine.isToggleLatched)
    }

    func testHoldingTheSecondPressKeepsHandsFreeMode() {
        var engine = GestureEngine()
        _ = engine.keyDown(at: 0)
        _ = engine.keyUp(at: 40)
        XCTAssertEqual(engine.keyDown(at: 100).effects, [.startToggle])
        XCTAssertTrue(engine.isToggleLatched)
        XCTAssertEqual(engine.keyDown(at: 150).effects, [])
        XCTAssertEqual(engine.tick(at: 269).effects, [])
        XCTAssertEqual(engine.tick(at: 270).effects, [])
        XCTAssertEqual(engine.keyUp(at: 600).effects, [])
        XCTAssertTrue(engine.isToggleLatched)
        XCTAssertFalse(engine.isPushing)
        XCTAssertEqual(engine.keyDown(at: 700).effects, [.stopToggle])
    }

    func testSecondPressAfterTheGapDoesNotStartWithoutAHold() {
        var engine = GestureEngine()
        _ = engine.keyDown(at: 0)
        _ = engine.keyUp(at: 40)
        // Même sans réveil de fin d'intervalle, un appui tardif reste un nouveau premier appui.
        XCTAssertEqual(engine.keyDown(at: 321), GestureStep(nextWakeMilliseconds: 491))
        XCTAssertEqual(engine.keyUp(at: 380).effects, [])
        XCTAssertFalse(engine.isToggleLatched)
    }

    func testEndingHandsFreeBeforeTheSecondReleaseDoesNotRearmTheMicrophone() {
        var engine = GestureEngine()
        _ = engine.keyDown(at: 0)
        _ = engine.keyUp(at: 40)
        XCTAssertEqual(engine.keyDown(at: 100).effects, [.startToggle])
        engine.endSession()
        XCTAssertFalse(engine.isToggleLatched)
        XCTAssertEqual(engine.keyUp(at: 600).effects, [])
        XCTAssertEqual(engine.keyDown(at: 700), GestureStep(nextWakeMilliseconds: 870))
    }

    func testPressDuringToggleStopsEvenWhenHeld() {
        var engine = GestureEngine()
        engine.noteExternalToggleStart()
        XCTAssertEqual(engine.keyDown(at: 0).effects, [.stopToggle])
        XCTAssertEqual(engine.tick(at: 170).effects, [])
        XCTAssertEqual(engine.keyUp(at: 400).effects, [])
        XCTAssertFalse(engine.isToggleLatched)
        XCTAssertFalse(engine.isPushing)
    }
}

final class TextPipelineTests: XCTestCase {
    func testKeytermsDropDuplicatesAndLimitLength() {
        let terms = KeytermList.sanitize([
            " OpenAI ",
            "openai",
            "xAI",
            String(repeating: "A", count: 80),
            "bad<term>"
        ], limit: 3, maxCharacters: 50)
        XCTAssertEqual(terms.count, 3)
        XCTAssertEqual(terms[0], "OpenAI")
        XCTAssertEqual(terms[1], "xAI")
        XCTAssertEqual(terms[2].count, 50)
    }

    func testContextHintsKeepTechnicalTokens() {
        let hints = ContextTerms.hints(from: "Je vais ouvrir SwiftUI et RevenueCat avec Grok 4.7")
        XCTAssertTrue(hints.contains("SwiftUI"))
        XCTAssertTrue(hints.contains("RevenueCat"))
        XCTAssertTrue(hints.contains("Grok"))
        XCTAssertFalse(hints.contains("Je"))
        XCTAssertFalse(hints.contains("vais"))
    }

    func testCorrectionKeepsDictionaryAndStripsWrapper() {
        let request = CorrectionRequest(
            transcript: "euh on fait la réunion mardi non mercredi",
            dictionary: ["SwiftUI"],
            appName: "Notes",
            selectedText: "brouillon",
            nearbyText: "RevenueCat"
        )
        let prompt = CorrectionPrompt.userText(request)
        XCTAssertTrue(prompt.contains("SwiftUI"))
        XCTAssertTrue(prompt.contains("RevenueCat"))
        XCTAssertTrue(prompt.contains("brouillon"))
        let cleaned = CorrectionPrompt.cleanModelOutput("\"On fait la réunion mercredi.\"", fallback: "brut")
        XCTAssertEqual(cleaned, "On fait la réunion mercredi.")
        XCTAssertEqual(CorrectionPrompt.cleanModelOutput("   ", fallback: "brut"), "brut")
    }

    func testAssemblerTrustsFinalTranscriptAndRevisesPartials() {
        var assembler = TranscriptAssembler()
        assembler.apply(.partial(text: "Je vais chez", isFinal: false, speechFinal: false, endSeconds: nil))
        XCTAssertEqual(assembler.displayText, "Je vais chez")
        assembler.apply(.partial(text: "Je vais chez OpenAI", isFinal: false, speechFinal: false, endSeconds: nil))
        XCTAssertEqual(assembler.displayText, "Je vais chez OpenAI")
        assembler.apply(.done(text: "Je vais chez OpenAI demain."))
        XCTAssertEqual(assembler.bestText, "Je vais chez OpenAI demain.")
    }

    func testAssemblerStitchesUtteranceFinals() {
        var assembler = TranscriptAssembler()
        assembler.apply(.partial(text: "Bonjour", isFinal: true, speechFinal: true, endSeconds: 0.4))
        assembler.apply(.partial(text: "tout le monde", isFinal: true, speechFinal: true, endSeconds: 1.1))
        XCTAssertEqual(assembler.bestText, "Bonjour tout le monde")
        XCTAssertTrue(assembler.endingFinalized)
        XCTAssertEqual(assembler.finalizedCoverageEnd ?? 0, 1.1, accuracy: 0.001)
    }

    func testUsageClassification() {
        XCTAssertEqual(UsageClassifier.classify(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"), .development)
        XCTAssertEqual(UsageClassifier.classify(bundleIdentifier: "com.apple.mail", appName: "Mail"), .email)
        XCTAssertEqual(UsageClassifier.classify(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome"), .browser)
        XCTAssertEqual(UsageClassifier.classify(bundleIdentifier: "com.example.unknown", appName: "Autre"), .other)
    }
}

final class StatsAndRetentionTests: XCTestCase {
    func testWordsPerMinuteAndTimeSaved() {
        let sample = DictationSample(createdAt: Date(), wordCount: 80, durationSeconds: 60)
        let summary = StatsCalculator.summary(samples: [sample], typingWordsPerMinute: 40)
        XCTAssertEqual(summary.words, 80)
        XCTAssertEqual(summary.wordsPerMinute ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(summary.savedSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(DurationFormat.saved(45_240), "12h 34m")
    }

    func testPeriodFilterUsesLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let today = DictationSample(createdAt: now.addingTimeInterval(-60), wordCount: 1, durationSeconds: 1)
        let old = DictationSample(createdAt: now.addingTimeInterval(-3 * 86_400), wordCount: 1, durationSeconds: 1)
        let filtered = StatsCalculator.filter(samples: [today, old], period: .today, now: now, calendar: calendar)
        XCTAssertEqual(filtered.count, 1)
    }

    func testRetentionDeletesExpiredThenOldest() {
        let now = Date()
        let files = [
            StoredAudio(id: "old", path: "a", bytes: 800, createdAt: now.addingTimeInterval(-300), expiresAt: nil),
            StoredAudio(id: "new", path: "b", bytes: 800, createdAt: now.addingTimeInterval(-10), expiresAt: nil),
            StoredAudio(id: "expired", path: "c", bytes: 100, createdAt: now.addingTimeInterval(-50), expiresAt: now.addingTimeInterval(-1))
        ]
        let victims = RetentionPolicy.idsToDelete(files: files, now: now, maxBytes: 1_000)
        XCTAssertEqual(victims, ["expired", "old"])
    }

    func testSuccessfulInsertionCanDropAudioImmediately() {
        XCTAssertTrue(RetentionPolicy.shouldDeleteImmediately(mode: .deleteOnSuccess, insertionSucceeded: true))
        XCTAssertFalse(RetentionPolicy.shouldDeleteImmediately(mode: .deleteOnSuccess, insertionSucceeded: false))
    }
}

final class AudioAndStoreTests: XCTestCase {
    func testWavHeaderAndResample() throws {
        let header = WAVHeader.make(dataBytes: 2, sampleRate: 16_000)
        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(String(data: header.prefix(4), encoding: .ascii), "RIFF")
        let input = Data([0x00, 0x00, 0x10, 0x00])
        let output = PCM16Resampler.resample(input, from: 8_000, to: 16_000)
        XCTAssertGreaterThan(output.count, input.count)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-\(UUID().uuidString).wav")
        let stream = try WAVStream(url: url, sampleRate: 16_000)
        stream.append(Data(repeating: 0, count: 32_000))
        stream.close()
        let file = try Data(contentsOf: url)
        XCTAssertEqual(file.count, 44 + 32_000)
        XCTAssertEqual(stream.durationSeconds, 1, accuracy: 0.001)
        try? FileManager.default.removeItem(at: url)
    }

    func testHistoryRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-\(UUID().uuidString).sqlite")
        let store = try HistoryStore(path: url.path)
        let record = DictationRecord(
            finalText: "Bonjour OpenAI.",
            rawText: "bonjour openai",
            durationSeconds: 1.5,
            wordCount: 2,
            provider: "xai",
            model: "grok-voice-transcribe-2.0",
            targetApp: "Notes",
            targetBundle: "com.apple.Notes",
            usageCategory: "notes",
            insertionStatus: InsertionStatus.inserted.rawValue,
            audioPath: "/tmp/a.wav",
            audioExpiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.insert(record)
        try store.addTerm("SwiftUI")
        try store.addTerm("SwiftUI")
        let loaded = try store.dictations()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].finalText, "Bonjour OpenAI.")
        XCTAssertEqual(loaded[0].audioPath, "/tmp/a.wav")
        XCTAssertEqual(try store.dictionary().map(\.term), ["SwiftUI"])
        try store.updateStatus(id: record.id, status: InsertionStatus.failed.rawValue)
        XCTAssertEqual(try store.dictations()[0].insertionStatus, "failed")
        try store.deleteDictation(id: record.id)
        XCTAssertTrue(try store.dictations().isEmpty)
        try? FileManager.default.removeItem(at: url)
    }

    func testInsertionRouteRefusesSecureFields() {
        XCTAssertEqual(
            InsertionPlanner.route(isSecureField: true, secureInputActive: false, accessibilityTrusted: true),
            .refuseSecure
        )
        XCTAssertEqual(
            InsertionPlanner.route(isSecureField: false, secureInputActive: true, accessibilityTrusted: true),
            .refuseSecure
        )
        XCTAssertEqual(
            InsertionPlanner.route(isSecureField: false, secureInputActive: false, accessibilityTrusted: false),
            .keepOnly
        )
        XCTAssertEqual(
            InsertionPlanner.route(isSecureField: false, secureInputActive: false, accessibilityTrusted: true),
            .paste
        )
    }

    func testInsertionCheckNeedsAVisibleChange() {
        XCTAssertTrue(InsertionCheck.confirms(before: "Bonjour ", after: "Bonjour Réunion mercredi.", inserted: "Réunion mercredi."))
        // Éditeur riche : espaces insécables ou retours réécrits.
        XCTAssertTrue(InsertionCheck.confirms(before: "", after: "Réunion\u{00A0}mercredi.", inserted: "Réunion mercredi."))
        // Valeur inchangée ou illisible : on ne peut rien prouver.
        XCTAssertFalse(InsertionCheck.confirms(before: "Réunion mercredi.", after: "Réunion mercredi.", inserted: "Réunion mercredi."))
        XCTAssertFalse(InsertionCheck.confirms(before: nil, after: nil, inserted: "Réunion"))
        XCTAssertFalse(InsertionCheck.confirms(before: "a", after: "ab", inserted: "Réunion"))
        // Éditeur riche (Claude, ChatGPT dans Chrome) : liste rendue sans tirets, apostrophe typographique.
        XCTAssertTrue(InsertionCheck.confirms(before: "", after: "Courses\nAcheter du lait\nPayer le loyer",
                                              inserted: "Courses :\n- Acheter du lait\n- Payer le loyer"))
        XCTAssertTrue(InsertionCheck.confirms(before: nil, after: "J’ai fini.", inserted: "J'ai fini."))
        // Texte court déjà présent : il doit apparaître une fois de plus.
        XCTAssertTrue(InsertionCheck.confirms(before: "OK merci", after: "OK merci OK", inserted: "OK"))
        XCTAssertFalse(InsertionCheck.confirms(before: "OK merci", after: "OK merci !", inserted: "OK"))
    }

    func testOpenAIDeltasThenCompleted() {
        var assembler = TranscriptAssembler()
        assembler.apply(OpenAITranscriptEvent.delta("On "))
        assembler.apply(OpenAITranscriptEvent.delta("fait la réunion"))
        XCTAssertEqual(assembler.displayText, "On fait la réunion")
        assembler.apply(OpenAITranscriptEvent.completed("On fait la réunion mercredi."))
        XCTAssertEqual(assembler.bestText, "On fait la réunion mercredi.")
    }
}

final class ChordAndSpendTests: XCTestCase {
    private let fnLeft = ModifierMask.function

    func testDefaultChordHoldEdges() {
        let down = ChordMatcher.step(
            phase: .down, keyCode: 123, flags: fnLeft,
            configuredKey: 123, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: false, recording: false
        )
        XCTAssertEqual(down.edge, .down)
        XCTAssertTrue(down.swallow)
        let held = ChordMatcher.step(
            phase: .down, keyCode: 123, flags: fnLeft,
            configuredKey: 123, configuredFlags: fnLeft,
            autorepeat: true, chordIsDown: true, recording: false
        )
        XCTAssertNil(held.edge)
        XCTAssertTrue(held.swallow)
        let up = ChordMatcher.step(
            phase: .up, keyCode: 123, flags: fnLeft,
            configuredKey: 123, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: true, recording: false
        )
        XCTAssertEqual(up.edge, .up)
        XCTAssertFalse(up.chordIsDown)
    }

    func testPlainLeftArrowIsNotTheShortcut() {
        let down = ChordMatcher.step(
            phase: .down, keyCode: 123, flags: 0,
            configuredKey: 123, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: false, recording: false
        )
        XCTAssertFalse(down.swallow)
        XCTAssertNil(down.edge)
    }

    func testRecordingCapturesShortcutAndIgnoresFunctionAlone() {
        let fn = ChordMatcher.step(
            phase: .down, keyCode: 63, flags: fnLeft,
            configuredKey: 123, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: false, recording: true
        )
        XCTAssertNil(fn.capturedKeyCode)
        XCTAssertFalse(fn.swallow)
        let captured = ChordMatcher.step(
            phase: .down, keyCode: 49, flags: ModifierMask.option,
            configuredKey: 123, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: false, recording: true
        )
        XCTAssertEqual(captured.capturedKeyCode, 49)
        XCTAssertEqual(captured.capturedFlags, ModifierMask.option)
        XCTAssertTrue(captured.swallow)
        XCTAssertNil(captured.edge)
    }

    func testReleasingFunctionEndsTheChord() {
        let transition = ChordMatcher.step(
            phase: .flags, keyCode: 63, flags: 0,
            configuredKey: 123, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: true, recording: false
        )
        XCTAssertEqual(transition.edge, .up)
        XCTAssertFalse(transition.swallow)
        XCTAssertFalse(transition.chordIsDown)
    }

    func testFunctionAloneHoldEdges() {
        let fnKey = ChordMatcher.functionKeyCode
        let down = ChordMatcher.step(
            phase: .flags, keyCode: fnKey, flags: fnLeft,
            configuredKey: fnKey, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: false, recording: false
        )
        XCTAssertEqual(down.edge, .down)
        let up = ChordMatcher.step(
            phase: .flags, keyCode: fnKey, flags: 0,
            configuredKey: fnKey, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: true, recording: false
        )
        XCTAssertEqual(up.edge, .up)
        let withShift = ChordMatcher.step(
            phase: .flags, keyCode: 56, flags: fnLeft | ModifierMask.shift,
            configuredKey: fnKey, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: false, recording: false
        )
        XCTAssertNil(withShift.edge)
    }

    func testFunctionComboEndsFunctionAloneChord() {
        let fnKey = ChordMatcher.functionKeyCode
        let combo = ChordMatcher.step(
            phase: .down, keyCode: 123, flags: fnLeft,
            configuredKey: fnKey, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: true, recording: false
        )
        XCTAssertEqual(combo.edge, .up)
        XCTAssertFalse(combo.swallow)
    }

    func testRecordingCapturesFunctionAloneOnRelease() {
        let fnKey = ChordMatcher.functionKeyCode
        let released = ChordMatcher.step(
            phase: .flags, keyCode: fnKey, flags: 0,
            configuredKey: 123, configuredFlags: fnLeft,
            autorepeat: false, chordIsDown: false, recording: true
        )
        XCTAssertEqual(released.capturedKeyCode, fnKey)
        XCTAssertEqual(released.capturedFlags, fnLeft)
    }

    func testSpendLedgerStopsAtFiveDollars() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-spend-\(UUID().uuidString).json")
        let ledger = SpendLedger(url: url, capUSD: 5)
        try ledger.reserve(4.5)
        XCTAssertEqual(ledger.spent(), 4.5, accuracy: 0.0001)
        XCTAssertThrowsError(try ledger.reserve(0.6))
        XCTAssertEqual(ledger.spent(), 4.5, accuracy: 0.0001)
        try ledger.reserve(0.5)
        XCTAssertEqual(ledger.spent(), 5, accuracy: 0.0001)
        try? FileManager.default.removeItem(at: url)
    }
}

final class SpectrumTests: XCTestCase {
    private func tone(_ frequency: Double, amplitude: Double, count: Int = 1_024) -> Data {
        var values = (0..<count).map { index in
            Int16(amplitude * 32_767 * sin(2 * .pi * frequency * Double(index) / 16_000))
        }
        return Data(bytes: &values, count: count * 2)
    }

    func testSilenceIsFlat() {
        let analyzer = SpectrumAnalyzer()
        let bands = analyzer.bands(pcm16: Data(count: 2_048))
        XCTAssertEqual(bands.count, SpectrumAnalyzer.bandCount)
        XCTAssertTrue(bands.allSatisfy { $0 == 0 })
    }

    func testToneLandsInItsBand() {
        let low = SpectrumAnalyzer().bands(pcm16: tone(200, amplitude: 0.05))
        let high = SpectrumAnalyzer().bands(pcm16: tone(3_500, amplitude: 0.05))
        XCTAssertEqual(low.firstIndex(of: low.max()!), 0)
        XCTAssertEqual(high.firstIndex(of: high.max()!), SpectrumAnalyzer.bandCount - 1)
        XCTAssertGreaterThan(low[0], 0.5)
    }

    func testFirstChunkWaitsForAFullWindow() {
        let bands = SpectrumAnalyzer().bands(pcm16: tone(250, amplitude: 0.5, count: 100))
        XCTAssertTrue(bands.allSatisfy { $0 == 0 })
    }
}

final class UsageTests: XCTestCase {
    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    func testDeepSeekPeakAndOffPeakPrices() {
        let tokens = TokenUsage(input: 1_000_000, cachedInput: 0, output: 1_000_000)
        // Mercredi 08 h UTC : heures pleines.
        let peak = Pricing.tokenCost(model: CleanupModel.deepSeek, tokens: tokens, at: utc("2026-09-30T08:00:00Z"))!
        XCTAssertEqual(peak, 1.50, accuracy: 0.0001)
        // Mercredi 12 h UTC puis samedi 08 h UTC : moitié prix.
        let offPeak = Pricing.tokenCost(model: CleanupModel.deepSeek, tokens: tokens, at: utc("2026-09-30T12:00:00Z"))!
        XCTAssertEqual(offPeak, 0.75, accuracy: 0.0001)
        let weekend = Pricing.tokenCost(model: CleanupModel.deepSeek, tokens: tokens, at: utc("2026-10-03T08:00:00Z"))!
        XCTAssertEqual(weekend, 0.75, accuracy: 0.0001)
    }

    func testGrokAndUnknownModelPrices() {
        let tokens = TokenUsage(input: 50_000, cachedInput: 50_000, output: 10_000)
        XCTAssertEqual(Pricing.tokenCost(model: "grok-4.7", tokens: tokens, at: Date())!, 0.10 + 0.025 + 0.06, accuracy: 0.0001)
        XCTAssertEqual(Pricing.tokenCost(model: "gpt-5.6-luna", tokens: tokens, at: Date())!, 0.01 + 0.001 + 0.012, accuracy: 0.0001)
        XCTAssertNil(Pricing.tokenCost(model: "unpriced-model", tokens: tokens, at: Date()))
    }

    func testXAIAudioPrices() {
        let stream = UsageEvent.transcription(provider: .xai, streaming: true, model: "grok-voice-transcribe-2.0", audioSeconds: 3_600)
        let file = UsageEvent.transcription(provider: .xai, streaming: false, model: "grok-voice-transcribe-2.0", audioSeconds: 3_600)
        XCTAssertEqual(stream.costUSD!, 0.20, accuracy: 0.0001)
        XCTAssertEqual(file.costUSD!, 0.10, accuracy: 0.0001)
        XCTAssertEqual(stream.api, .xaiStreaming)
        let failed = UsageEvent.transcription(provider: .xai, streaming: true, model: "grok-voice-transcribe-2.0", audioSeconds: 60, succeeded: false)
        XCTAssertNil(failed.costUSD)
    }

    func testParsesDeepSeekAndOpenAIStyleUsage() {
        let deepSeek = TokenUsage.parse(["prompt_tokens": 120, "completion_tokens": 30, "prompt_cache_hit_tokens": 100])
        XCTAssertEqual(deepSeek, TokenUsage(input: 20, cachedInput: 100, output: 30))
        let xai = TokenUsage.parse(["prompt_tokens": 50, "completion_tokens": 10, "prompt_tokens_details": ["cached_tokens": 8]])
        XCTAssertEqual(xai, TokenUsage(input: 42, cachedInput: 8, output: 10))
        XCTAssertNil(TokenUsage.parse(nil))
    }

    func testSummaryGroupsByAPIAndPeriod() {
        let now = utc("2026-10-01T12:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let events = [
            UsageEvent(createdAt: now, api: .deepSeekCleanup, model: CleanupModel.deepSeek, tokens: TokenUsage(input: 10, output: 5), costUSD: 0.001),
            UsageEvent(createdAt: now, api: .deepSeekCleanup, model: CleanupModel.deepSeek, costUSD: 0, succeeded: false),
            UsageEvent(createdAt: now, api: .xaiStreaming, model: "grok-voice-transcribe-2.0", audioSeconds: 30, costUSD: 0.002),
            UsageEvent(createdAt: now, api: .openAICleanup, model: "gpt-5.6-luna", costUSD: nil),
            UsageEvent(createdAt: utc("2026-09-20T12:00:00Z"), api: .xaiStreaming, model: "grok-voice-transcribe-2.0", audioSeconds: 60, costUSD: 0.5)
        ]
        let today = UsageSummary.make(events: events, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(today.totalUSD, 0.003, accuracy: 0.000001)
        XCTAssertEqual(today.cost(provider: "xAI"), 0.002, accuracy: 0.000001)
        XCTAssertTrue(today.hasUnpricedCalls)
        let deepSeek = today.rows.first { $0.api == .deepSeekCleanup }!
        XCTAssertEqual(deepSeek.requests, 2)
        XCTAssertEqual(deepSeek.failures, 1)
        XCTAssertEqual(deepSeek.tokens.output, 5)
        let all = UsageSummary.make(events: events, period: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.totalUSD, 0.503, accuracy: 0.000001)
        XCTAssertEqual(all.rows.first?.api, .xaiStreaming)
    }

    func testStoreKeepsUsageIncludingUnknownCost() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-usage-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try HistoryStore(path: path)
        let priced = UsageEvent(api: .xaiFile, model: "grok-voice-transcribe-2.0", audioSeconds: 4.5, costUSD: 0.000125, latencyMs: 450)
        let unpriced = UsageEvent(api: .openAICleanup, model: "gpt-5.6-luna", tokens: TokenUsage(input: 3, cachedInput: 2, output: 1), costUSD: nil, succeeded: false)
        try store.insertUsage(priced)
        try store.insertUsage(unpriced)
        try store.deleteAllDictations()
        let loaded = try store.usageEvents()
        XCTAssertEqual(loaded.count, 2)
        let roundTrip = loaded.first { $0.id == priced.id }!
        XCTAssertEqual(roundTrip.api, .xaiFile)
        XCTAssertEqual(roundTrip.costUSD!, 0.000125, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.latencyMs, 450)
        let other = loaded.first { $0.id == unpriced.id }!
        XCTAssertNil(other.costUSD)
        XCTAssertFalse(other.succeeded)
        XCTAssertEqual(other.tokens, TokenUsage(input: 3, cachedInput: 2, output: 1))
    }

    func testMoneyKeepsSmallAmountsReadable() {
        XCTAssertEqual(MoneyFormat.usd(0, locale: Locale(identifier: "fr_FR")), "0,00 $")
        XCTAssertEqual(MoneyFormat.usd(0.00012, locale: Locale(identifier: "fr_FR")), "0,00012 $")
        XCTAssertEqual(MoneyFormat.usd(0.1234, locale: Locale(identifier: "fr_FR")), "0,1234 $")
        XCTAssertEqual(MoneyFormat.usd(12.5, locale: Locale(identifier: "fr_FR")), "12,50 $")
    }
}

final class CorrectionLearnerTests: XCTestCase {
    private func learn(_ inserted: String, before: String, after: String, known: [String] = []) -> [String] {
        CorrectionLearner.candidates(inserted: inserted, before: before, after: after, known: known).map(\.corrected)
    }

    func testMisheardBrandIsLearned() {
        let text = "J'ai testé Sidance hier soir."
        XCTAssertEqual(learn(text, before: text, after: "J'ai testé Seedance hier soir."), ["Seedance"])
    }

    func testSplitWordFixedIntoOneTerm() {
        let text = "On passe par open router demain."
        XCTAssertEqual(learn(text, before: text, after: "On passe par OpenRouter demain."), ["OpenRouter"])
    }

    func testCasingFixOfAProperNoun() {
        let text = "Le modèle openai répond vite."
        XCTAssertEqual(learn(text, before: text, after: "Le modèle OpenAI répond vite."), ["OpenAI"])
    }

    func testGrammarAndRewordingAreIgnored() {
        let text = "Les maison sont belles."
        XCTAssertEqual(learn(text, before: text, after: "Les maisons sont belles."), [])
        let other = "Je viens demain matin."
        XCTAssertEqual(learn(other, before: other, after: "Je viens jeudi matin."), [])
        XCTAssertEqual(learn(other, before: other, after: "Finalement je ne viens pas du tout."), [])
    }

    func testEditsOutsideTheDictationAreIgnored() {
        let before = "Note de Pierre. J'ai testé Seedance."
        let after = "Note de Pierrot. J'ai testé Seedance."
        XCTAssertEqual(learn("J'ai testé Seedance.", before: before, after: after), [])
    }

    func testCorrectionStillFoundWhenTheUserKeepsTyping() {
        let text = "Demain on montre Sidance au client."
        let after = "Demain on montre Seedance au client. Puis on fait le point sur le budget."
        XCTAssertEqual(learn(text, before: text, after: after), ["Seedance"])
    }

    func testChangedDigitsAreAContentEditNotAMishearing() {
        // Le 5 octobre, « DDR3 » modifié à la main en « DDR4 4G » avait été appris, et poussait ensuite vers DDR4.
        let text = "Je vais trier les barrettes de DDR3."
        XCTAssertEqual(learn(text, before: text, after: "Je vais trier les barrettes de DDR4 4G."), [])
        let cpu = "Mon PC a un i7 récent."
        XCTAssertEqual(learn(cpu, before: cpu, after: "Mon PC a un i9 récent."), [])
        // Mêmes chiffres, seule l'écriture change : c'est bien un terme mal entendu.
        let model = "On teste gpt 5 demain."
        XCTAssertEqual(learn(model, before: model, after: "On teste GPT-5 demain."), ["GPT-5"])
    }

    func testKnownTermsAndNoChangeLearnNothing() {
        let text = "J'ai testé Sidance."
        XCTAssertEqual(learn(text, before: text, after: "J'ai testé Seedance.", known: ["seedance"]), [])
        XCTAssertEqual(learn(text, before: text, after: text), [])
        XCTAssertEqual(learn("absent", before: text, after: "J'ai testé Seedance."), [])
    }

    func testPunctuationAroundTheWordIsKept() {
        let text = "Regarde Sidance, c'est fou."
        XCTAssertEqual(learn(text, before: text, after: "Regarde Seedance, c'est fou."), ["Seedance"])
    }

    func testCandidateKeepsWhatWasHeard() {
        let text = "On passe par open router demain."
        XCTAssertEqual(
            CorrectionLearner.candidates(inserted: text, before: text, after: "On passe par OpenRouter demain.", known: []),
            [CorrectionLearner.Candidate(heard: "open router", corrected: "OpenRouter")]
        )
    }
}

final class RelayTests: XCTestCase {
    private func speech(deepSeek: Bool, openAI: Bool, down: Bool = false) -> SpeechRequest {
        SpeechRequest(provider: .xai, liveModel: "m", fileModel: "m", apiKey: "xai", language: .french, keyterms: [], prompt: "",
                      cleanupKey: deepSeek ? "ds" : nil, fallbackKey: openAI ? "oa" : nil, cleanupPrimaryDown: down)
    }

    func testCleanupOrderDeepSeekThenOpenAI() {
        XCTAssertEqual(TextCleaner.routes(speech(deepSeek: true, openAI: true)).map(\.model), [CleanupModel.deepSeek, CleanupModel.openAIFallback])
        XCTAssertEqual(TextCleaner.routes(speech(deepSeek: true, openAI: true)).map(\.isFallback), [false, true])
        // Sans clé OpenAI, Grok prend le relais.
        XCTAssertEqual(TextCleaner.routes(speech(deepSeek: true, openAI: false)).map(\.model), [CleanupModel.deepSeek, "grok-4.7"])
        XCTAssertEqual(TextCleaner.routes(speech(deepSeek: false, openAI: false)).map(\.model), ["grok-4.7"])
    }

    func testDeepSeekDownGoesLast() {
        let routes = TextCleaner.routes(speech(deepSeek: true, openAI: true, down: true))
        XCTAssertEqual(routes.map(\.model), [CleanupModel.openAIFallback, CleanupModel.deepSeek])
        XCTAssertTrue(routes[0].isFallback)
    }

    func testServiceIsPausedAfterTwoFailuresThenRetried() {
        var health = ServiceHealth()
        let start = Date()
        health.record("DeepSeek", succeeded: false, at: start)
        XCTAssertFalse(health.isDown("DeepSeek", now: start))
        health.record("DeepSeek", succeeded: false, at: start)
        XCTAssertTrue(health.isDown("DeepSeek", now: start.addingTimeInterval(600)))
        XCTAssertEqual(health.downServices(now: start.addingTimeInterval(600)), ["DeepSeek"])
        XCTAssertFalse(health.isDown("DeepSeek", now: start.addingTimeInterval(1_801)))
        health.record("DeepSeek", succeeded: true)
        XCTAssertFalse(health.isDown("DeepSeek", now: start))
    }

    func testOpenAIRelayPricing() {
        XCTAssertEqual(Pricing.tokenCost(model: CleanupModel.openAIFallback, tokens: TokenUsage(input: 1_000_000, output: 1_000_000), at: Date())!, 5.25, accuracy: 1e-9)
    }
}

final class TermJudgeTests: XCTestCase {
    private let candidates = [
        CorrectionLearner.Candidate(heard: "Sidance", corrected: "Seedance"),
        CorrectionLearner.Candidate(heard: "commande", corrected: "Commande")
    ]

    func testOnlyApprovedCandidatesAreKept() {
        XCTAssertEqual(TermJudge.parse(#"{"garder": ["Seedance"]}"#, candidates: candidates), ["Seedance"])
        XCTAssertEqual(TermJudge.parse(#"{"garder": []}"#, candidates: candidates), [])
    }

    func testUserSpellingWinsAndInventedTermsAreDropped() {
        // Le modèle ne peut ajouter que ce que l'utilisateur a corrigé, avec son orthographe.
        XCTAssertEqual(TermJudge.parse(#"{"garder": ["seedance", "OpenRouter"]}"#, candidates: candidates), ["Seedance"])
    }

    func testWrappedOrBrokenAnswers() {
        XCTAssertEqual(TermJudge.parse("```json\n{\"garder\": [\"Seedance\"]}\n```", candidates: candidates), ["Seedance"])
        XCTAssertEqual(TermJudge.parse("Oui, Seedance.", candidates: candidates), [])
        XCTAssertEqual(TermJudge.parse(#"{"garder": "Seedance"}"#, candidates: candidates), [])
    }

    func testPromptCarriesOnlyTheDictationAndTheCorrections() {
        let text = TermJudge.userText(candidates, dictated: "J'ai testé Sidance, passe la commande.")
        XCTAssertEqual(text, """
        Phrase dictée : J'ai testé Sidance, passe la commande.
        Corrections :
        1. « Sidance » → « Seedance »
        2. « commande » → « Commande »
        """)
    }

    func testLongDictationIsClippedAroundTheWord() {
        let long = String(repeating: "blabla ", count: 200) + "Sidance" + String(repeating: " suite", count: 200)
        let excerpt = TermJudge.excerpt(long, around: "Sidance", limit: 100)
        XCTAssertTrue(excerpt.contains("Sidance"))
        XCTAssertLessThanOrEqual(excerpt.count, 102)
    }

    func testJevDecidesClearCasesAndAsksForDoubtfulOnes() {
        let words = ["Seedance", "Commande", "Notion", "Cursor"].map { CorrectionLearner.Candidate(heard: $0.lowercased(), corrected: $0) }
        let scores = [0.9, 0.05, 0.8, 0.4]
        let jev = DictionaryJudge(kind: .jev, provider: "TypeSafe", model: "jev-fixture")
        let model = DictionaryJudge(kind: .correctionModel, provider: "DeepSeek", model: "modele-fixture")
        func kept(secondOpinion approved: [String]?) -> [String] {
            let answer = approved.map { TermJudge.ModelAnswer(approved: $0, judge: model) }
            return TermJudge.decide(words, scores: scores, jev: jev, secondOpinion: answer).map(\.term)
        }
        // Second avis : oui à Notion et Cursor ; Cursor reste refusé car Jev est sous 0,5.
        XCTAssertEqual(kept(secondOpinion: ["Notion", "Cursor"]), ["Seedance", "Notion"])
        XCTAssertEqual(kept(secondOpinion: []), ["Seedance"])
        // Pas de second avis : Jev seul, seuil 0,7.
        XCTAssertEqual(kept(secondOpinion: nil), ["Seedance", "Notion"])
    }

    func testJevAnswerIsReadInCandidateOrder() throws {
        let data = Data(#"{"model":"jev-1.13.0","answers":{"c1":{"type":"noul","noul":0.04},"c0":{"type":"noul","noul":0.93}},"usage":{"input_tokens":500,"output_tokens":20}}"#.utf8)
        let parsed = try XCTUnwrap(JevJudge.parse(data, count: 2))
        XCTAssertEqual(parsed.scores, [0.93, 0.04])
        XCTAssertEqual(parsed.inputTokens, 500)
        XCTAssertNil(JevJudge.parse(data, count: 3))
        XCTAssertEqual(Pricing.tokenCost(model: "jev-1.13.0", tokens: TokenUsage(input: 1_000_000, output: 50), at: Date()), 0.042)
    }

    func testNoKeyMeansNoCallAndNothingLearned() async {
        let speech = SpeechRequest(provider: .xai, liveModel: "m", fileModel: "m", apiKey: "", language: .french, keyterms: [], prompt: "")
        let judgement = await TermJudge.judge(candidates, dictated: "x", speech: speech)
        XCTAssertEqual(judgement, TermJudgement(kept: []))
    }
}

final class BandTimelineTests: XCTestCase {
    func testFramesOfAPacketArePlayedOneHopApart() {
        var timeline = BandTimeline(bandCount: 1)
        timeline.push([[0.1], [0.2], [0.3]], arrival: 10, hopSeconds: 0.016)
        XCTAssertEqual(timeline.current(at: 10), [0.1])
        XCTAssertEqual(timeline.current(at: 10.017), [0.2])
        XCTAssertEqual(timeline.current(at: 10.04), [0.3])
        XCTAssertEqual(timeline.current(at: 11), [0.3])
    }

    func testNextPacketFollowsWithoutOverlap() {
        var timeline = BandTimeline(bandCount: 1)
        timeline.push([[0.1], [0.2]], arrival: 0, hopSeconds: 0.016)
        // Le paquet suivant arrive un peu tôt : il se range après le précédent.
        timeline.push([[0.5]], arrival: 0.01, hopSeconds: 0.016)
        XCTAssertEqual(timeline.current(at: 0.017), [0.2])
        XCTAssertEqual(timeline.current(at: 0.033), [0.5])
    }

    func testBacklogNeverGrowsBeyondTheLimit() {
        var timeline = BandTimeline(bandCount: 1)
        timeline.push(Array(repeating: [0.1], count: 30), arrival: 0, hopSeconds: 0.016)
        timeline.push([[0.9]], arrival: 0.01, hopSeconds: 0.016)
        XCTAssertEqual(timeline.current(at: 0.011), [0.9])
    }

    func testFramesNobodyReadsDoNotPileUp() {
        // Écran en veille pendant dix minutes de dictée mains libres : le micro continue, le spectre n'est plus lu.
        var timeline = BandTimeline(bandCount: 1)
        var arrival = 0.0
        for packet in 0..<6_000 {
            timeline.push(Array(repeating: [Float(packet % 100) / 100], count: 6), arrival: arrival, hopSeconds: 0.016)
            arrival += 0.1
        }
        // Une seconde d'images au plus, au lieu des 36 000 de l'écoute.
        XCTAssertLessThanOrEqual(timeline.pendingFrames, 80)
        // L'écran revient : la dernière image due s'affiche, comme sans oubli.
        XCTAssertEqual(timeline.current(at: arrival + 1), [0.99])
        XCTAssertEqual(timeline.pendingFrames, 0)
    }

    func testFramesStillReadAreNeverDropped() {
        var timeline = BandTimeline(bandCount: 1)
        timeline.push([[0.1], [0.2], [0.3]], arrival: 10, hopSeconds: 0.016)
        // Paquet suivant juste après : le précédent n'a pas encore été lu, il reste entier dans la file.
        timeline.push([[0.4]], arrival: 10.05, hopSeconds: 0.016)
        XCTAssertEqual(timeline.pendingFrames, 4)
        XCTAssertEqual(timeline.current(at: 10), [0.1])
        XCTAssertEqual(timeline.current(at: 10.05), [0.4])
    }

    func testAnalyzerSlicesAPacketIntoHops() {
        var samples = (0..<1_600).map { Int16(3_000 * sin(Double($0) * 0.1)) }
        let data = Data(bytes: &samples, count: samples.count * 2)
        // Six hops complets ; les 64 derniers échantillons attendent le prochain paquet micro.
        XCTAssertEqual(SpectrumAnalyzer().frames(pcm16: data, hop: 256).count, 6)
    }
}
