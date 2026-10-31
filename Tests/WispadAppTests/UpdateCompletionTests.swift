import Foundation
import Testing
@testable import WispadApp
@testable import WispadCore

/// Relais entre l'ancienne version, qui finit l'installation, et la nouvelle, qui rouvre la fenêtre de mise à jour.
struct UpdateCompletionTests {
    private func defaults() -> UserDefaults {
        let name = "wispad-tests-relais-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let release = ReleaseInfo(
        version: SemanticVersion("0.7.7")!, tag: "v0.7.7", notes: "Installation visible jusqu'au bout.",
        pageURL: URL(string: "https://github.com/samirmedani/wispad/releases/tag/v0.7.7")!, diskImage: nil,
        publishedAt: Date(timeIntervalSince1970: 1_793_400_000)
    )

    @Test func theNewVersionReadsTheInstallationOnce() {
        let store = defaults()
        let now = Date()
        UpdateCompletion.save(release, from: "0.7.6", defaults: store, now: now)
        let completion = UpdateCompletion.take(version: "0.7.7", defaults: store, now: now.addingTimeInterval(4))
        #expect(completion == UpdateCompletion(release: release, previous: "0.7.6"))
        #expect(UpdateCompletion.take(version: "0.7.7", defaults: store, now: now) == nil)
    }

    /// Une note d'une autre version, ou trop vieille, ne décrit pas ce lancement : elle est effacée sans servir.
    @Test func anotherVersionOrAnOldNoteIsIgnored() {
        let store = defaults()
        let now = Date()
        UpdateCompletion.save(release, from: "0.7.6", defaults: store, now: now)
        #expect(UpdateCompletion.take(version: "0.7.6", defaults: store, now: now) == nil)
        #expect(store.dictionary(forKey: UpdateCompletion.defaultsKey) == nil)
        UpdateCompletion.save(release, from: "0.7.6", defaults: store, now: now)
        #expect(UpdateCompletion.take(version: "0.7.7", defaults: store,
                                      now: now.addingTimeInterval(UpdateCompletion.lifetime + 1)) == nil)
        #expect(UpdateCompletion.take(version: nil, defaults: store, now: now) == nil)
    }
}
