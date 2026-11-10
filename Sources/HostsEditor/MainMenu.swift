import AppKit

/// Main menu. Items without a target travel the responder chain (EditorViewController, NSWindow,
/// text fields), so ⌘Z/⌘C/⌘S work wherever the focus is.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Hide HostsEditor"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit HostsEditor"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "HostsEditor", to: main)

        let file = NSMenu(title: L("File"))
        file.addItem(withTitle: L("Apply Changes"), action: #selector(EditorViewController.applyChanges(_:)), keyEquivalent: "s")
        file.addItem(withTitle: L("Revert to File"), action: #selector(EditorViewController.revertChanges(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("Reload from Disk"), action: #selector(EditorViewController.reloadFromDisk(_:)), keyEquivalent: "r")
        file.addItem(withTitle: L("Show Backups in Finder"), action: #selector(AppDelegate.showBackups(_:)), keyEquivalent: "")
        file.addItem(.separator())
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
        // ⌘⌫, not a bare ⌫: a bare Delete must keep deleting characters in text fields.
        edit.addItem(withTitle: L("Delete"), action: #selector(EditorViewController.delete(_:)), keyEquivalent: "\u{8}")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Find"), action: #selector(EditorViewController.performFindPanelAction(_:)), keyEquivalent: "f")
        add(edit, title: L("Edit"), to: main)

        let entries = NSMenu(title: L("Entries"))
        entries.addItem(withTitle: L("Add Entry"), action: #selector(EditorViewController.addEntry(_:)), keyEquivalent: "n")
        let comment = entries.addItem(withTitle: L("Add Comment"), action: #selector(EditorViewController.addComment(_:)), keyEquivalent: "n")
        comment.keyEquivalentModifierMask = [.command, .shift]
        entries.addItem(.separator())
        for item in EditorViewController.sortMenuItems() { entries.addItem(item) }
        add(entries, title: L("Entries"), to: main)

        let window = NSMenu(title: L("Window"))
        window.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        add(window, title: L("Window"), to: main)
        NSApp.windowsMenu = window
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
