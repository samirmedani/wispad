import Foundation
import Testing
@testable import WispadCore

struct ErrorReportTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wispad-reports-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func report(_ id: String, expected: String = "Et si tu commences ?") -> ErrorReport {
        ErrorReport(dictationID: id, dictatedAt: Date(), expected: expected, heard: "Et si je commence.",
                    written: "Et si je commence.", language: "fr", provider: "xai", model: "fixture", durationSeconds: 2)
    }

    @Test func savesTheReportAndAPrivateCopyOfTheAudio() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        try Data([1, 2, 3]).write(to: audio)
        let saved = try ErrorReportArchive.save(report("A"), audio: audio, in: root.appendingPathComponent("signalements"))
        #expect(saved.audioFile == "audio.wav")
        // L'audio d'origine peut être purgé : la copie reste.
        try FileManager.default.removeItem(at: audio)
        let all = ErrorReportArchive.all(in: root.appendingPathComponent("signalements"))
        #expect(all.count == 1)
        #expect(all.first?.report.expected == "Et si tu commences ?")
        #expect(all.first?.audio.map { (try? Data(contentsOf: $0)) == Data([1, 2, 3]) } == true)
        let json = root.appendingPathComponent("signalements/A/report.json").path
        let permissions = try FileManager.default.attributesOfItem(atPath: json)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func aSecondReportReplacesTheTextAndKeepsTheAudio() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("source.wav")
        try Data([1]).write(to: audio)
        try ErrorReportArchive.save(report("A"), audio: audio, in: root)
        try FileManager.default.removeItem(at: audio)
        try ErrorReportArchive.save(report("A", expected: "Et si tu commençais ?"), audio: nil, in: root)
        let all = ErrorReportArchive.all(in: root)
        #expect(all.count == 1)
        #expect(all.first?.report.expected == "Et si tu commençais ?")
        #expect(all.first?.audio != nil)
        #expect(ErrorReportArchive.report(for: "A", in: root)?.audioFile == "audio.wav")
    }
}
