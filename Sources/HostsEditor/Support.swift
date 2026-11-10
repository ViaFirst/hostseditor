import AppKit
import os

/// Localized UI string. English text is the key, so a missing translation falls back to English.
/// Translations: Resources/Localization/<lang>.lproj/Localizable.strings
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.viafirst.hostseditor", category: "app")

enum Permissions {
    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case automation = "Privacy_Automation"
    }

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum AppPaths {
    /// ~/Library/Application Support/HostsEditor/ (created on first use).
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HostsEditor", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

enum AppLayout {
    /// Direction of the language the app runs in. AppKit leaves `NSApp` left-to-right when Hebrew comes
    /// only from AppleLanguages (per-app language), so set this on stack views, menus and SwiftUI roots.
    static let direction: NSUserInterfaceLayoutDirection = {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.Language(identifier: lang).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }()
}
