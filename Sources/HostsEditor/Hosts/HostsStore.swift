import AppKit

/// The hosts file being edited: the document, undo, dirty state, apply with backup.
@MainActor
final class HostsStore {
    let url: URL
    var backupFolder = Backups.defaultFolder
    private(set) var doc = HostsDocument()
    /// File content at the last load/apply, to notice edits made by other apps.
    private(set) var diskText = ""
    /// Serialized form of the loaded document: the document is dirty when it serializes differently.
    private var cleanText = ""
    private(set) var loadError: String?
    let undoManager = UndoManager()
    private var observers: [() -> Void] = []

    /// /etc/hosts, or HOSTSEDITOR_FILE for tests and experiments.
    static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["HOSTSEDITOR_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/etc/hosts")
    }

    init(url: URL) { self.url = url }

    var rows: [HostsRow] { doc.rows }
    var isDirty: Bool { doc.serialized() != cleanText }
    var changedOnDisk: Bool { (try? String(contentsOf: url, encoding: .utf8)) != diskText }

    func observe(_ handler: @escaping () -> Void) { observers.append(handler) }
    private func changed() { observers.forEach { $0() } }

    func load() {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            diskText = text
            doc = .parse(text)
            cleanText = doc.serialized()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            log.error("load failed: \(error.localizedDescription, privacy: .public)")
        }
        undoManager.removeAllActions()
        changed()
    }

    /// Every edit goes through here, so it can be undone.
    func update(_ actionName: String, notify: Bool = true, _ change: (inout [HostsRow]) -> Void) {
        let before = doc.rows
        change(&doc.rows)
        guard doc.rows != before else { return }
        registerUndo(restoring: before, actionName)
        if notify { changed() }
    }

    private func registerUndo(restoring rows: [HostsRow], _ actionName: String) {
        let current = doc.rows
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.doc.rows = rows
                store.registerUndo(restoring: current, actionName)
                store.changed()
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Changed rows that can't be written: (row index, message). Untouched lines from disk are left alone.
    var problems: [(index: Int, message: String)] {
        doc.rows.enumerated().compactMap { i, r in
            r.isModified ? r.validationError.map { (i, $0) } : nil
        }
    }

    /// Backs up what is on disk now, writes the document (asking for the admin password when needed),
    /// flushes the DNS cache and reloads.
    func apply() throws {
        let text = doc.serialized()
        if let current = try? String(contentsOf: url, encoding: .utf8) {
            try Backups.save(current, in: backupFolder)
        }
        try HostsWriter.write(text, to: url)
        load()
    }
}

enum Backups {
    static var defaultFolder: URL { AppPaths.support.appendingPathComponent("Backups", isDirectory: true) }
    /// How many backups to keep: `defaults write com.viafirst.hostseditor backupLimit -int 50`.
    static var limit: Int {
        let v = UserDefaults.standard.integer(forKey: "backupLimit")
        return v > 0 ? v : 30
    }

    @discardableResult
    static func save(_ text: String, in folder: URL, limit: Int = Backups.limit, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var url = folder.appendingPathComponent("hosts-\(f.string(from: now)).txt")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("hosts-\(f.string(from: now))-\(n).txt")
            n += 1
        }
        try Data(text.utf8).write(to: url)
        prune(folder, keep: limit)
        return url
    }

    static func list(_ folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.filter { $0.lastPathComponent.hasPrefix("hosts-") }
            .sorted { (date($0), $0.lastPathComponent) > (date($1), $1.lastPathComponent) }
    }

    static func prune(_ folder: URL, keep: Int) {
        for old in list(folder).dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }
}

enum HostsWriter {
    enum WriteError: LocalizedError {
        case cancelled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return L("Cancelled")
            case .failed(let message): return message
            }
        }
    }

    static func write(_ text: String, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        if FileManager.default.isWritableFile(atPath: target.path) {
            // Not atomic on purpose: rewriting in place keeps the file's owner and permissions.
            try Data(text.utf8).write(to: target)
            return
        }
        let pending = AppPaths.support.appendingPathComponent("hosts.pending")
        try Data(text.utf8).write(to: pending)
        defer { try? FileManager.default.removeItem(at: pending) }
        let shell = "/bin/cat \(quote(pending.path)) > \(quote(target.path))"
            + " && /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder 2>/dev/null; true"
        try runAsAdmin(shell)
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `do shell script … with administrator privileges`: the system password / Touch ID dialog.
    /// Standard Additions run in-process, so no Automation permission is involved.
    private static func runAsAdmin(_ shell: String) throws {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let prompt = L("HostsEditor wants to save changes to /etc/hosts.")
        let source = "do shell script \"\(esc(shell))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw WriteError.cancelled }
        throw WriteError.failed(error[NSAppleScript.errorMessage] as? String ?? L("Could not write /etc/hosts."))
    }
}
