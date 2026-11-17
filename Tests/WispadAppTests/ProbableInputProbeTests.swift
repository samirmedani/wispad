import AppKit
import Testing
@testable import WispadApp
@testable import WispadCore

/// Sonde en lecture seule du champ probable, sur une vraie fenêtre ouverte : seulement à la demande,
/// `WISPAD_PROBE_FIELDS=<identifiant de l'app> swift test --filter ProbableInputProbeTests`. Elle lit l'arbre
/// d'accessibilité de la fenêtre active de cette app, affiche chaque candidat et son score, et n'écrit rien.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WISPAD_PROBE_FIELDS"] != nil))
struct ProbableInputProbeTests {
    @Test func probeTheActiveWindowOfAnApp() throws {
        let bundle = try #require(ProcessInfo.processInfo.environment["WISPAD_PROBE_FIELDS"])
        let app = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first)
        let pid = app.processIdentifier
        let field = InsertionField.read(pid: pid)
        let kind = field.kind(bundleID: bundle)
        print("focus : rôle=\(field.role ?? "aucun") genre=\(kind)")
        ProbableInput.inspect = { candidates, scene in
            print("fenêtre \(scene.window.integral) strict=\(scene.strict) complet=\(scene.complete)")
            let dialog = candidates.contains { $0.inDialog }
            for candidate in candidates {
                let score = InputTargeting.score(candidate, in: scene, dialogPresent: dialog)
                let frame = candidate.frame.offsetBy(dx: -scene.window.minX, dy: -scene.window.minY).integral
                print(String(format: "  %6.2f", score), candidate.role, frame, "lettres=\(candidate.length)",
                      "indice=\(candidate.hint.count) car.", "repère=\(candidate.landmark)", "liste=\(candidate.inList)",
                      "modale=\(candidate.inDialog)", "classes=\(candidate.domClasses.prefix(3).joined(separator: "."))",
                      "id=\(candidate.domIdentifier)")
            }
        }
        defer { ProbableInput.inspect = nil }
        let started = Date()
        let target = ProbableInput.scan(.init(pid: pid, bundleID: bundle, focus: field.element, strict: kind == .unknown))
        print("choix : \(target == nil ? "aucun" : "un champ") en \(Int(Date().timeIntervalSince(started) * 1_000)) ms")
    }
}

