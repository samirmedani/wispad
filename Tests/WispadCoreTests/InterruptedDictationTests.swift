import Foundation
import Testing
@testable import WispadCore

/// Dictée interrompue par une fermeture inattendue : audio réparé et retrouvé au lancement suivant.
struct InterruptedDictationTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wispad-interrompue-\(UUID().uuidString).wav")
    }

    @Test func aFileLeftOpenByACrashGetsItsRealLength() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Une seconde d'audio écrite, jamais fermée : l'en-tête dit encore 0 octet, comme après un plantage.
        let stream = try WAVStream(url: url, sampleRate: 16_000)
        stream.append(Data(repeating: 1, count: 32_000))
        let duration = try #require(WAVStream.repair(url: url))
        #expect(abs(duration - 1.0) < 0.001)
        let header = try Data(contentsOf: url).prefix(44)
        #expect(header == WAVHeader.make(dataBytes: 32_000, sampleRate: 16_000))
        stream.close()
    }

    @Test func anEmptyOrMissingFileIsNotRepaired() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WAVStream.repair(url: url) == nil)
        let stream = try WAVStream(url: url, sampleRate: 16_000)
        stream.close()
        #expect(WAVStream.repair(url: url) == nil)
    }

    @Test func theNoteIsReadOnceAndExpires() throws {
        let defaults = try #require(UserDefaults(suiteName: "wispad-interrompue-\(UUID().uuidString)"))
        let now = Date()
        let note = InterruptedDictation(path: "/tmp/fictif.wav", provider: "xai", model: "grok-voice-transcribe-2.0",
                                        appName: "Notes", bundleID: "com.apple.Notes", savedAt: now.addingTimeInterval(-60))
        note.save(defaults: defaults)
        #expect(InterruptedDictation.take(defaults: defaults, now: now)?.path == "/tmp/fictif.wav")
        #expect(InterruptedDictation.take(defaults: defaults, now: now) == nil)
        note.save(defaults: defaults)
        #expect(InterruptedDictation.take(defaults: defaults, now: now.addingTimeInterval(InterruptedDictation.lifetime + 120)) == nil)
    }
}
