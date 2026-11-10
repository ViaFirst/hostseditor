import AppKit

/// Command-line self-tests, so the app can be verified without clicking it:
///   HostsEditor --self-test             parser/writer/store checks on temp files, PASS/FAIL, exit 1 on failure
///   HostsEditor --render-test <out.png> renders the editor with sample data into a PNG
/// Neither touches the real /etc/hosts.
@MainActor
enum SelfTest {
    static let macDefault = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost

    """

    static let sample = macDefault + """

    # Local WordPress sites
    127.0.0.1   acf.local www.acf.local   # LocalWP
    #127.0.0.1  technovision.local
    # 10.0.0.12 nas.home
    192.168.1.50\tprinter.lan

    # Block
    0.0.0.0 ads.example.com tracker.example.com
    fe80::1%lo0\tlocalhost
    """

    /// Returns true when a test needs the run loop (it calls exit() itself when done).
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--self-test") { selfTest() }
        if args.contains("--menu-dump") { menuDump() }
        if let i = args.firstIndex(of: "--render-test"), i + 1 < args.count {
            renderTest(out: args[i + 1])
            return true
        }
        return false
    }

    private static var failures = 0
    private static func check(_ ok: Bool, _ message: String) {
        print(ok ? "PASS" : "FAIL", message)
        if !ok { failures += 1 }
    }

    private static func selfTest() {
        // Parsing the stock macOS file
        let def = HostsDocument.parse(macDefault)
        check(def.header.count == 6, "header kept (\(def.header.count) lines)")
        check(def.rows.count == 3 && def.rows.allSatisfy(\.isSystem), "3 system entries")
        check(def.serialized() == macDefault, "stock file round-trips byte for byte")

        // A mixed file
        let doc = HostsDocument.parse(sample)
        check(doc.serialized() == sample, "mixed file round-trips byte for byte (no trailing newline)")
        let kinds = doc.rows.map { $0.isComment ? "c" : ($0.enabled ? "on" : "off") }
        check(kinds == ["on", "on", "on", "c", "on", "off", "off", "on", "c", "on", "on"], "row kinds \(kinds)")
        let acf = doc.rows[4]
        check(acf.ip == "127.0.0.1" && acf.hostnames == "acf.local www.acf.local" && acf.comment == "LocalWP", "inline comment parsed")
        check(doc.rows[3].comment == "Local WordPress sites" && doc.rows[3].blankLinesBefore == 1, "comment row + blank line")
        check(doc.rows[6].ip == "10.0.0.12" && !doc.rows[6].enabled, "'# ip host' is a disabled entry")
        check(doc.rows[10].isSystem && HostsDocument.isIP("fe80::1%lo0"), "IPv6 with zone")

        // Editing
        var edited = doc
        edited.rows[5].enabled = true
        edited.rows[4].enabled = false
        let text = edited.serialized()
        check(text.contains("\n127.0.0.1\ttechnovision.local\n"), "enabling writes a clean line")
        check(text.contains("\n# 127.0.0.1\tacf.local www.acf.local # LocalWP\n"), "disabling comments the line out")
        check(text.contains("192.168.1.50\tprinter.lan"), "untouched line kept as is")
        check(HostsDocument.parse(text).rows.map(\.signature) == edited.rows.map(\.signature), "edited text parses back to the same rows")
        var hosts = HostsRow.entry(ip: "1.2.3.4", hostnames: "")
        hosts.hostnames = HostsDocument.normalizeHosts(" a.test,  b.test\tc.test ")
        check(hosts.hostnames == "a.test b.test c.test", "hostnames normalized")

        // Validation
        check(HostsRow.entry(ip: "300.1.1.1", hostnames: "a").validationError != nil, "bad IPv4 rejected")
        check(HostsRow.entry(ip: "1.1.1.1", hostnames: "").validationError != nil, "empty hostnames rejected")
        check(HostsRow.entry(ip: "1.1.1.1", hostnames: "bad_host!").validationError != nil, "bad hostname rejected")
        check(HostsRow.entry(ip: "::1", hostnames: "my-app.test").validationError == nil, "good IPv6 entry accepted")
        check(!HostsRow.entry(ip: "127.0.0.1", hostnames: "localhost my.test").isSystem, "localhost + custom name is editable")
        let junk = HostsDocument.parse("127.0.0.1 a\nnot an entry\n")
        check(junk.rows.count == 2 && junk.serialized() == "127.0.0.1 a\nnot an entry\n", "junk line kept verbatim")

        // Reordering
        var items = Array(0..<6)
        let moved = HostsDocument.move(&items, from: [1, 2], to: 5)
        check(items == [0, 3, 4, 1, 2, 5] && moved == IndexSet([3, 4]), "move down \(items)")
        items = Array(0..<6)
        HostsDocument.move(&items, from: [4], to: 0)
        check(items == [4, 0, 1, 2, 3, 5], "move up \(items)")
        items = Array(0..<3)
        HostsDocument.move(&items, from: [0], to: 3)
        check(items == [1, 2, 0], "move to end \(items)")

        // Sorting inside comment-delimited groups
        let messy = HostsDocument.parse("""
        127.0.0.1 localhost
        10.0.0.9 zeta.test
        10.0.0.10 www.alpha.test alpha.test

        # 9.9.9.9 beta.test
        ## Local - Start ##
        ::1 site.local
        127.0.0.1 site.local
        ::1 app.local
        127.0.0.1 app.local
        ## Local - End ##

        """)
        let byDomain = HostsDocument.sorted(messy.rows, by: .domain)
        check(byDomain.map { $0.isComment ? "#" : $0.hostnameList[0] + "@" + $0.ip } ==
              ["localhost@127.0.0.1", "www.alpha.test@10.0.0.10", "beta.test@9.9.9.9", "zeta.test@10.0.0.9", "#",
               "app.local@127.0.0.1", "app.local@::1", "site.local@127.0.0.1", "site.local@::1", "#"],
              "sort by domain keeps groups, system first, IPv4 before IPv6")
        check(byDomain.map(\.blankLinesBefore) == messy.rows.map(\.blankLinesBefore), "blank lines stay in place")
        let byIP = HostsDocument.sorted(messy.rows, by: .ip)
        check(byIP.prefix(4).map(\.ip) == ["127.0.0.1", "9.9.9.9", "10.0.0.9", "10.0.0.10"], "sort by IP is numeric \(byIP.prefix(4).map(\.ip))")
        let onFirst = HostsDocument.sorted(messy.rows, by: .enabledFirst)
        check(onFirst[3].hostnameList[0] == "beta.test" && !onFirst[3].enabled, "disabled entries go last in their group")
        check(HostsDocument.sorted(byDomain, by: .domain).map(\.id) == byDomain.map(\.id), "sorting twice changes nothing")

        // Duplicates
        let dups = HostsDocument.parse("1.1.1.1 a.test b.test\n# 1.1.1.1 b.test a.test\n#1.1.1.1 c.test\n#1.1.1.1 c.test\n2.2.2.2 a.test\n")
        let dedup = HostsDocument.removingDuplicates(dups.rows)
        check(dedup.removed == 2 && dedup.rows.count == 3, "duplicates removed (\(dedup.removed))")
        check(dedup.rows[0].enabled && !dedup.rows[1].enabled, "kept copy stays enabled; disabled pair stays disabled")

        // Menu model: LocalWP pairs merge, servers become alternatives, sections from comments, A–Z
        let menuDoc = HostsDocument.parse("""
        127.0.0.1 localhost
        172.19.0.2 reuth.org.uk www.reuth.org.uk
        #209.35.197.53 reuth.org.uk www.reuth.org.uk
        172.19.0.3 files.budget.co.il
        ## Local - Start ##
        ::1 budget.local #Local Site
        127.0.0.1 budget.local #Local Site
        ::1 acf.local
        127.0.0.1 acf.local
        ::1 www.acf.local
        127.0.0.1 www.acf.local
        ## Local - End ##
        172.19.0.9 stg.example.com
        """)
        let sections = HostsMenuModel.build(menuDoc.rows)
        check(sections.count == 3 && sections[0].title == nil && sections[1].title == "Local" && sections[2].title == nil, "menu sections \(sections.map { $0.title ?? "-" })")
        check(sections[0].entries.map(\.title) == ["files.budget.co.il", "reuth.org.uk"], "server block A–Z, www twin hidden")
        check(sections[0].entries[1].hasAlternatives && sections[0].entries[1].rows.count == 2, "two servers for one site = alternatives")
        check(sections[1].entries.map(\.title) == ["acf.local", "budget.local"], "LocalWP pairs merged and sorted")
        check(!sections[1].entries[0].hasAlternatives && sections[1].entries[0].ips == "::1, 127.0.0.1", "127.0.0.1 + ::1 is one switch")
        check(sections[1].entries[0].rows.count == 4, "www. lines merged into the site item")

        // Store on a temp file
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HostsEditorTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hosts")
        try? sample.write(to: file, atomically: true, encoding: .utf8)
        let store = HostsStore(url: file)
        store.backupFolder = dir.appendingPathComponent("Backups")
        store.load()
        check(store.loadError == nil && store.rows.count == 11 && !store.isDirty, "store loads clean")
        store.update("toggle") { $0[5].enabled = true }
        check(store.isDirty, "edit makes it dirty")
        store.undoManager.undo()
        check(!store.isDirty, "undo makes it clean again")
        store.undoManager.redo()
        check(store.isDirty && store.rows[5].enabled, "redo")
        store.update("move") { HostsDocument.move(&$0, from: [9], to: 3) }
        store.update("add") { $0.append(.entry(ip: "127.0.0.1", hostnames: "")) }
        check(store.problems.count == 1 && store.problems[0].index == 11, "new empty entry reported as a problem")
        store.update("fix") { $0[11].hostnames = "new.test" }
        check(store.problems.isEmpty, "no problems after fix")
        do { try store.apply() } catch { check(false, "apply: \(error)") }
        let written = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(!store.isDirty && written.contains("127.0.0.1\ttechnovision.local") && written.hasSuffix("127.0.0.1\tnew.test"), "apply writes the file")
        check(written.range(of: "# Local WordPress sites")!.lowerBound > written.range(of: "0.0.0.0 ads")!.lowerBound, "moved row written in its new place")
        check(Backups.list(store.backupFolder).count == 1, "backup saved")
        let backup = Backups.list(store.backupFolder).first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        check(backup == sample, "backup holds the previous file")
        check(!store.changedOnDisk, "no outside change yet")
        try? (written + "\n1.1.1.1 other.app\n").write(to: file, atomically: true, encoding: .utf8)
        check(store.changedOnDisk, "outside change detected")

        // Backup retention
        let bdir = dir.appendingPathComponent("Retention")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<5 { _ = try? Backups.save("v\(i)", in: bdir, limit: 3, now: base.addingTimeInterval(Double(i))) }
        check(Backups.list(bdir).count == 3, "retention keeps 3 of 5")

        // Shell quoting for the admin command
        check(HostsWriter.quote("/a b/it's") == "'/a b/it'\\''s'", "shell quoting")
        check(Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier == "com.viafirst.hostseditor", "bundle id")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// Prints the menu-bar menu for the real hosts file (read only): `HostsEditor --menu-dump`.
    private static func menuDump() {
        let text = (try? String(contentsOf: HostsStore.defaultURL, encoding: .utf8)) ?? ""
        for section in HostsMenuModel.build(HostsDocument.parse(text).rows) {
            print("== \(section.title ?? "(no title)")")
            for e in section.entries {
                let state = e.allOn ? "[x]" : (e.anyOn ? "[-]" : "[ ]")
                print(state, e.title, "—", e.hasAlternatives ? "choose: " + e.rows.map { ($0.enabled ? "*" : "") + $0.ip }.joined(separator: " | ") : e.ips)
            }
        }
        exit(0)
    }

    /// Shows the editor with sample data in a window below the desktop, then draws it into a PNG.
    private static func renderTest(out: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HostsEditorRender-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("hosts")
        try? sample.write(to: file, atomically: true, encoding: .utf8)
        let store = HostsStore(url: file)
        store.load()
        store.update("demo") { rows in
            rows[5].enabled = true
            rows.append(.entry(ip: "127.0.0.1", hostnames: "", comment: ""))
        }
        let editor = EditorViewController(store: store)
        let size = CGSize(width: 780, height: 480)
        let window = NSWindow(contentRect: CGRect(origin: NSScreen.screens.first?.frame.origin ?? .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentViewController = editor
        window.setContentSize(size)
        editor.view.wantsLayer = true
        window.orderFrontRegardless()
        editor.table.selectRowIndexes([4], byExtendingSelection: false)
        print("layout:", AppLayout.direction == .rightToLeft ? "rtl" : "ltr")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let view = editor.view
            view.layoutSubtreeIfNeeded()
            // Controls (search field, buttons) draw in layers that cacheDisplay misses: render the layer tree.
            let scale: CGFloat = 2
            guard let layer = view.layer,
                  let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { exit(1) }
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
            ctx.scaleBy(x: scale, y: scale)
            if layer.isGeometryFlipped || view.isFlipped {
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            try? FileManager.default.removeItem(at: dir)
            print("wrote", out)
            exit(0)
        }
    }
}
