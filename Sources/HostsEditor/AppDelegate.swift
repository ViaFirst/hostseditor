import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    /// LSUIElement in Info.plist decides: menu-bar utility (no Dock icon) or windowed app.
    static let isMenuBarApp = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false

    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        if Self.isMenuBarApp {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "HostsEditor")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    // MARK: Menu-bar menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(L("Open HostsEditor"), #selector(openWindow)))
        menu.addItem(.separator())
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

    @objc private func openWindow() { showWindow() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 360),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "HostsEditor"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ContentView(model: model))
            w.center()
            w.delegate = self
            window = w
        }
        if Self.isMenuBarApp { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Menu-bar apps go back to no Dock icon and hand focus to the previous app.
        guard Self.isMenuBarApp else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.isMenuBarApp
    }
}
