import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if SelfTest.runIfRequested() {
        app.setActivationPolicy(.accessory)
        app.run()
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppDelegate.isMenuBarApp ? .accessory : .regular)
    app.run()
}
