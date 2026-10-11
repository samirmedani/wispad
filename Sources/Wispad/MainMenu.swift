import AppKit
import WispadCore

/// Actions du menu principal, prises en charge par le délégué de l'app au bout de la chaîne des répondeurs.
@MainActor @objc protocol MainMenuActions {
    func openSettings()
    func openSectionFromMenu(_ sender: NSMenuItem)
}

/// Menu principal : sans menu Édition, Cmd+V/C/X/A/Z ne marchent dans aucun champ de l'app. Réglages (⌘,) et
/// les écrans (⌘1 à ⌘6) passent par la chaîne des répondeurs jusqu'au délégué de l'app.
enum MainMenu {
    @MainActor static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "À propos de Wispad"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Réglages…"), action: #selector(MainMenuActions.openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Masquer Wispad"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quitter Wispad"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "Édition"))
        edit.addItem(withTitle: String(localized: "Annuler"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Rétablir"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Couper"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copier"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Coller"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Tout sélectionner"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let viewItem = NSMenuItem()
        let view = NSMenu(title: String(localized: "Présentation"))
        for (index, section) in AppSection.allCases.enumerated() {
            let item = view.addItem(withTitle: section.title, action: #selector(MainMenuActions.openSectionFromMenu(_:)), keyEquivalent: "\(index + 1)")
            item.tag = index
        }
        viewItem.submenu = view
        main.addItem(viewItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Fenêtre"))
        windowMenu.addItem(withTitle: String(localized: "Fermer"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: String(localized: "Réduire"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
