import Foundation
import Testing
@testable import WispadApp

struct OnboardingSettingsTests {
    @Test func freshInstallStartsWithTheGuideAndPrivateDefaults() {
        let fresh = AppSettings()
        #expect(!fresh.onboardingCompleted)
        #expect(!fresh.useWindowContext)
    }

    @Test func existingInstallSkipsTheGuideAndKeepsItsContext() throws {
        let saved = Data(#"{"provider":"xai","cleanupEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: saved)
        #expect(settings.onboardingCompleted)
        #expect(settings.useWindowContext)
    }
}
