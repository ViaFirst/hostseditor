import AppKit

/// Main menu. Its key equivalents travel the responder chain, so text fields and custom
/// views get standard behaviour (also in a menu-bar app while one of its windows is open).
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Hide HostsEditor"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit HostsEditor"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "HostsEditor", to: main)

        let file = NSMenu(title: L("File"))
        file.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: L("File"), to: main)

        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: #selector(EditActions.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo"), action: #selector(EditActions.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: L("Edit"), to: main)
        return main
    }

    private static func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}

/// Responder-chain actions views may implement (NSResponder declares no undo:/redo: of its own).
@objc protocol EditActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}
