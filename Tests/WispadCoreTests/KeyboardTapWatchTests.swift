import Testing
@testable import WispadCore

/// Autorisations retirées puis rendues pendant que Wispad tourne : l'écoute du clavier n'est jamais réarmée sans
/// les autorisations de son installation (elle retiendrait les frappes de tout le Mac), elle revient avec elles, et
/// aucune vérification ne tente plus que ce que la surveillance de 3 s permet.
struct KeyboardTapWatchTests {
    private let all = KeyboardPermissions(listen: true, accessibility: true)
    private let noListen = KeyboardPermissions(listen: false, accessibility: true)
    private let noAccessibility = KeyboardPermissions(listen: true, accessibility: false)
    private let none = KeyboardPermissions(listen: false, accessibility: false)

    @Test func cutsByMacOSAreReenabledWhileThePermissionsStay() {
        var watch = KeyboardTapWatch()
        watch.installed(with: all)
        // Lenteur, saisie sécurisée, veille : rien n'a changé côté autorisations, comme avant.
        #expect(watch.installedTap(enabled: false, permissions: all) == .reenable)
        #expect(watch.installedTap(enabled: true, permissions: all) == .keep)
        #expect(!watch.withdrawn(all))
    }

    @Test func aWithdrawnPermissionIsNeverReenabled() {
        var watch = KeyboardTapWatch()
        watch.installed(with: all)
        for withdrawn in [noListen, noAccessibility, none] {
            // Coupée par macOS ou encore active : retirée dans les deux cas, jamais réarmée.
            #expect(watch.withdrawn(withdrawn))
            #expect(watch.installedTap(enabled: false, permissions: withdrawn) == .remove)
            #expect(watch.installedTap(enabled: true, permissions: withdrawn) == .remove)
        }
    }

    @Test func aPermissionGivenAfterTheInstallationIsNotRequired() {
        var watch = KeyboardTapWatch()
        // Installée avec la seule accessibilité : la surveillance des entrées, donnée puis retirée, ne la retire pas.
        watch.installed(with: noListen)
        #expect(watch.installedTap(enabled: true, permissions: all) == .keep)
        #expect(watch.installedTap(enabled: true, permissions: noListen) == .keep)
        #expect(watch.installedTap(enabled: false, permissions: noListen) == .reenable)
        #expect(watch.installedTap(enabled: true, permissions: none) == .remove)
    }

    @Test func noTapIsTriedBeforeInputMonitoringLikeAtLaunch() {
        let watch = KeyboardTapWatch()
        #expect(watch.missingTap(none) == .keep)
        #expect(watch.missingTap(noListen) == .keep)
        #expect(watch.missingTap(noAccessibility) == .install)
        #expect(watch.missingTap(all) == .install)
    }

    @Test func aRemovedTapComesBackWhenItsPermissionsDo() {
        var watch = KeyboardTapWatch()
        watch.installed(with: all)
        // Surveillance des entrées retirée : rien n'est tenté tant qu'elle manque.
        #expect(watch.missingTap(noListen) == .keep)
        #expect(watch.missingTap(none) == .keep)
        // Rendue : l'écoute est réinstallée à la vérification suivante.
        #expect(watch.missingTap(all) == .install)
        // Accessibilité seule retirée : une écoute neuve est tentée, comme au lancement ; macOS dit si elle tient.
        #expect(watch.missingTap(noAccessibility) == .install)
    }

    @Test func anAccessibilityOnlyTapComesBackWithAccessibility() {
        var watch = KeyboardTapWatch()
        watch.installed(with: noListen)
        #expect(watch.missingTap(none) == .keep)
        #expect(watch.missingTap(noListen) == .install)
    }

    @Test func aLongWithdrawalNeverRearmsNorRetries() {
        var watch = KeyboardTapWatch()
        watch.installed(with: all)
        // Une heure de vérifications toutes les 3 s, autorisation toujours retirée : ni réarmement ni nouvel essai.
        var decisions: [KeyboardTapWatch.Decision] = []
        for _ in 0..<1_200 {
            decisions.append(watch.installedTap(enabled: false, permissions: noListen))
            decisions.append(watch.missingTap(noListen))
        }
        #expect(!decisions.contains(.reenable))
        #expect(!decisions.contains(.install))
        // Une réinstallation réussie devient la nouvelle référence.
        watch.installed(with: noAccessibility)
        #expect(watch.installedTap(enabled: false, permissions: noAccessibility) == .reenable)
    }
}
