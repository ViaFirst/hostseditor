import AppKit
import ServiceManagement

/// Window + menu-bar app: the editor window opens at launch; closing it leaves the status item
/// (quick on/off for entries) and removes the Dock icon until the window is opened again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let store = HostsStore(url: HostsStore.defaultURL)
    lazy var editor = EditorViewController(store: store)
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        store.load()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "network", accessibilityDescription: "HostsEditor")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        menu.userInterfaceLayoutDirection = AppLayout.direction
        item.menu = menu
        statusItem = item

        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    /// Picks up edits made by other apps (Docker, a terminal) when nothing is pending here.
    func applicationDidBecomeActive(_ notification: Notification) {
        if !store.isDirty && store.changedOnDisk { store.load() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Apply your changes to /etc/hosts before quitting?")
        alert.informativeText = L("Changes that are not applied are lost.")
        alert.addButton(withTitle: L("Apply"))
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return editor.applyNow() ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    // MARK: Status-bar menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = store.rows.filter { !$0.isComment && !$0.isSystem }
        if entries.isEmpty {
            let none = NSMenuItem(title: L("No entries yet"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for r in entries {
            var title = r.hostnames.isEmpty ? r.ip : r.hostnames
            if title.count > 60 { title = String(title.prefix(57)) + "…" }
            let i = NSMenuItem(title: title, action: #selector(toggleFromMenu(_:)), keyEquivalent: "")
            i.target = self
            i.state = r.enabled ? .on : .off
            i.representedObject = r.id
            i.toolTip = r.ip + (r.comment.isEmpty ? "" : " — " + r.comment)
            menu.addItem(i)
        }
        menu.addItem(.separator())
        if store.isDirty {
            menu.addItem(item(L("Apply Changes"), #selector(applyFromMenu)))
        }
        menu.addItem(item(L("Open HostsEditor"), #selector(openWindow)))
        menu.addItem(item(L("Show Backups in Finder"), #selector(showBackups(_:))))
        let login = item(L("Launch at Login"), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit HostsEditor"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    /// A switch in the menu is applied right away (one password prompt). Cancelled -> the switch is undone.
    @objc private func toggleFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let i = store.rows.firstIndex(where: { $0.id == id }) else { return }
        let on = !store.rows[i].enabled
        store.update(on ? L("Enable Entry") : L("Disable Entry")) { $0[i].enabled = on }
        NSApp.activate(ignoringOtherApps: true)   // the password dialog and alerts come to the front
        if !editor.applyNow() { store.undoManager.undo() }
    }

    @objc private func applyFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        editor.applyNow()
    }

    @objc private func openWindow() { showWindow() }

    @objc func showBackups(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: store.backupFolder, withIntermediateDirectories: true)
        if let latest = Backups.list(store.backupFolder).first {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        } else {
            NSWorkspace.shared.open(store.backupFolder)
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Window

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 480),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "HostsEditor"
            w.subtitle = store.url.path
            w.isReleasedWhenClosed = false
            w.contentViewController = editor
            w.setContentSize(CGSize(width: 780, height: 480))
            w.center()
            w.setFrameAutosaveName("EditorWindow")
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app; focus returns to the previous app.
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }
}
