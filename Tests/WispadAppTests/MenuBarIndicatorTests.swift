import Foundation
import Testing
@testable import WispadApp

/// Point de la barre des menus : une couleur par étape de la dictée, le vert seulement juste après un texte livré.
struct MenuBarIndicatorTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func eachPhaseHasItsDot() {
        #expect(MenuBarIndicator.state(phase: .starting, deliveredAt: nil, now: now) == .starting)
        #expect(MenuBarIndicator.state(phase: .finishing, deliveredAt: nil, now: now) == .finishing)
        #expect(MenuBarIndicator.state(phase: .failure("x"), deliveredAt: nil, now: now) == .failure)
        #expect(MenuBarIndicator.state(phase: .idle, deliveredAt: nil, now: now) == .none)
    }

    @Test func listeningShowsNoDotEvenRightAfterADelivery() {
        // La tête pleine en rouge signale déjà l'écoute ; un point vert de la dictée précédente la brouillerait.
        let delivered = now.addingTimeInterval(-0.2)
        #expect(MenuBarIndicator.state(phase: .listening(.pushToTalk), deliveredAt: delivered, now: now) == .none)
        #expect(MenuBarIndicator.state(phase: .listening(.toggle), deliveredAt: delivered, now: now) == .none)
    }

    @Test func greenDotLastsBrieflyAfterDelivery() {
        #expect(MenuBarIndicator.state(phase: .idle, deliveredAt: now.addingTimeInterval(-0.5), now: now) == .delivered)
        let expired = now.addingTimeInterval(-MenuBarIndicator.deliveredDuration)
        #expect(MenuBarIndicator.state(phase: .idle, deliveredAt: expired, now: now) == .none)
        // Horloge reculée : pas de point vert sans fin.
        #expect(MenuBarIndicator.state(phase: .idle, deliveredAt: now.addingTimeInterval(5), now: now) == .none)
    }

    @Test func onlyIdleAndListeningHideTheDot() {
        #expect(MenuBarIndicator.none.color == nil)
        for indicator in [MenuBarIndicator.starting, .finishing, .delivered, .failure] {
            #expect(indicator.color != nil)
            #expect(indicator.accessibilityLabel != nil)
        }
    }
}
