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
        let sections = HostsMenuModel.build(store.rows)
        if sections.isEmpty {
            let none = NSMenuItem(title: L("No entries yet"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (n, section) in sections.enumerated() {
            if n > 0 { menu.addItem(.separator()) }
            if let title = section.title { menu.addItem(.sectionHeader(title: title)) }
            for entry in section.entries { menu.addItem(menuItem(for: entry)) }
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

    private static func short(_ s: String) -> String { s.count > 60 ? String(s.prefix(57)) + "…" : s }

    /// One item per site: a switch for all its lines (127.0.0.1 + ::1), or a submenu when the names
    /// point at different servers (pick one, the others go off).
    private func menuItem(for entry: HostsMenuModel.Entry) -> NSMenuItem {
        let item = NSMenuItem(title: Self.short(entry.title), action: nil, keyEquivalent: "")
        item.state = entry.allOn ? .on : (entry.anyOn ? .mixed : .off)
        if entry.hasAlternatives {
            let sub = NSMenu()
            sub.userInterfaceLayoutDirection = AppLayout.direction
            for r in entry.rows {
                let alt = NSMenuItem(title: r.ip, action: #selector(chooseAlternative(_:)), keyEquivalent: "")
                alt.target = self
                alt.state = r.enabled ? .on : .off
                alt.representedObject = [r.id] + entry.rows.map(\.id).filter { $0 != r.id }
                if !r.comment.isEmpty { alt.setSubtitle(r.comment) }
                sub.addItem(alt)
            }
            sub.addItem(.separator())
            let off = NSMenuItem(title: L("Turn All Off"), action: #selector(turnAllOff(_:)), keyEquivalent: "")
            off.target = self
            off.representedObject = entry.rows.map(\.id)
            off.isEnabled = entry.anyOn
            sub.addItem(off)
            item.submenu = sub
            item.setSubtitle(entry.rows.first(where: \.enabled).map(\.ip) ?? L("Off"))
        } else {
            item.action = #selector(toggleFromMenu(_:))
            item.target = self
            item.representedObject = entry.rows.map(\.id)
            item.setSubtitle(entry.ips)
        }
        return item
    }

    /// A switch in the menu is applied right away (one password prompt). Cancelled -> the switch is undone.
    private func changeAndApply(_ actionName: String, _ change: (inout [HostsRow]) -> Void) {
        store.update(actionName, change)
        NSApp.activate(ignoringOtherApps: true)   // the password dialog and alerts come to the front
        if store.isDirty && !editor.applyNow() { store.undoManager.undo() }
    }

    @objc private func toggleFromMenu(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [UUID] else { return }
        let rows = store.rows.filter { ids.contains($0.id) }
        let on = !rows.allSatisfy(\.enabled)
        changeAndApply(on ? L("Enable Entry") : L("Disable Entry")) { rows in
            for i in rows.indices where ids.contains(rows[i].id) { rows[i].enabled = on }
        }
    }

    /// representedObject: [chosen id, other ids of the same site]. Chosen on -> it alone is enabled.
    @objc private func chooseAlternative(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [UUID], let chosen = ids.first,
              let place = store.rows.first(where: { $0.id == chosen }).map({ HostsMenuModel.ipClass($0.ip) }) else { return }
        let turnOn = sender.state != .on
        changeAndApply(turnOn ? L("Enable Entry") : L("Disable Entry")) { rows in
            // Lines pointing at the chosen place (127.0.0.1 and ::1 count as one) go on, the rest off.
            for i in rows.indices where ids.contains(rows[i].id) {
                let samePlace = HostsMenuModel.ipClass(rows[i].ip) == place
                rows[i].enabled = turnOn ? samePlace : (samePlace ? false : rows[i].enabled)
            }
        }
    }

    @objc private func turnAllOff(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [UUID] else { return }
        changeAndApply(L("Disable Entry")) { rows in
            for i in rows.indices where ids.contains(rows[i].id) { rows[i].enabled = false }
        }
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


extension NSMenuItem {
    /// Grey second line (macOS 14.4+); older systems show the text as a tooltip.
    func setSubtitle(_ text: String) {
        if #available(macOS 14.4, *) { subtitle = text } else { toolTip = text }
    }
}
