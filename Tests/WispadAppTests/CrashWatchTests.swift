import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Veille de relance après plantage : seulement pour la version publiée, jamais pour un outil ou un aperçu.
struct CrashWatchTests {
    @Test func onlyThePublishedAppIsWatched() {
        #expect(CrashWatch.shouldWatch(arguments: ["Wispad"], kind: .release))
        #expect(CrashWatch.shouldWatch(arguments: ["Wispad", "--background", "--recovered"], kind: .release))
        #expect(!CrashWatch.shouldWatch(arguments: ["Wispad"], kind: .development))
        #expect(!CrashWatch.shouldWatch(arguments: ["Wispad", "--offscreen"], kind: .release))
        #expect(!CrashWatch.shouldWatch(arguments: ["Wispad", "--status-diagnostic"], kind: .release))
    }

    @Test func theWatchRelaunchesOnlyAfterACrashReport() {
        let arguments = CrashWatch.arguments(pid: 42, app: URL(fileURLWithPath: "/Applications/Wispad.app"),
                                             guardFile: URL(fileURLWithPath: "/tmp/garde"))
        #expect(arguments.first == "-c")
        #expect(Array(arguments.suffix(3)) == ["42", "/Applications/Wispad.app", "/tmp/garde"])
        let script = CrashWatch.script
        #expect(script.contains("Wispad-*.ips"))
        #expect(script.contains("--background --recovered"))
        #expect(script.contains("-mmin -2"))
        #expect(!script.contains("activate"))
    }
}
