import Testing
@testable import WispadApp

/// Après une mise à jour en un clic, la nouvelle version ne rouvre aucune fenêtre : la bulle seule le confirme.
@MainActor
struct QuietUpdateRelaunchTests {
    @Test func anUpdateNeverReopensTheWindow() {
        #expect(AppDelegate.launchSection(["Wispad", "--updated", "--section", "home"]) == nil)
        #expect(AppDelegate.launchSection(["Wispad", "--updated"]) == nil)
        #expect(AppDelegate.launchSection(["Wispad", "--section", "usage"]) == .usage)
        #expect(AppDelegate.launchSection(["Wispad", "--section"]) == nil)
    }
}
