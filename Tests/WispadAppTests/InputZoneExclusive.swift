import Testing
@testable import WispadApp

/// La zone de saisie retenue (`InputZoneTracker`) tient dans un seul emplacement pour toute l'app, et un changement
/// d'écran l'efface. Les tests qui la lisent, la notent ou simulent des écrans passent un par un, quelle que soit leur
/// suite : sinon l'un efface, entre deux attentes d'un autre, la zone que celui-ci vient de faire noter (vu sur la CI
/// le 14 octobre).
struct InputZoneExclusive: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // Seuls les tests prennent le verrou : une suite qui le garderait bloquerait ses propres tests.
        guard testCase != nil else { return try await function() }
        await InputZoneLock.shared.acquire()
        do {
            try await function()
        } catch {
            await InputZoneLock.shared.release()
            throw error
        }
        await InputZoneLock.shared.release()
    }
}

extension Trait where Self == InputZoneExclusive {
    static var inputZoneExclusive: Self { Self() }
}

/// Verrou asynchrone, premier arrivé premier servi.
actor InputZoneLock {
    static let shared = InputZoneLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
