import AppKit

/// Table that reports Delete / Space by physical key code (works in any keyboard layout).
final class RowsTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onToggle: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, mods.isEmpty) {
        case (51, true), (117, true): onDelete?()      // Delete, Forward Delete
        case (49, true): onToggle?()                    // Space
        default: super.keyDown(with: event)
        }
    }
}

/// The editor: search field, table of entries (checkbox, IP, hostnames, comment), bottom bar.
@MainActor
final class EditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                  NSTextFieldDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    let store: HostsStore
    let table = RowsTableView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: L("Apply"), target: nil, action: nil)
    private let revertButton = NSButton(title: L("Revert"), target: nil, action: nil)
    private let removeButton = NSButton()
    /// Indexes into `store.rows` shown in the table (the search filter).
    private var visible: [Int] = []
    private static let dragType = NSPasteboard.PasteboardType("com.viafirst.hostseditor.row")

    enum Col: String, CaseIterable { case on, ip, hosts, comment }

    init(store: HostsStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        store.observe { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 480))
        root.userInterfaceLayoutDirection = AppLayout.direction

        search.placeholderString = L("Search")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)

        let columns: [(Col, String, CGFloat, CGFloat)] = [
            (.on, "", 26, 26), (.ip, L("IP Address"), 170, 90),
            (.hosts, L("Hostnames"), 320, 120), (.comment, L("Comment"), 220, 80),
        ]
        for (col, title, width, minWidth) in columns {
            let c = NSTableColumn(identifier: .init(col.rawValue))
            c.title = title
            c.width = width
            c.minWidth = minWidth
            if col == .on { c.maxWidth = width; c.resizingMask = [] }
            table.addTableColumn(c)
        }
        table.userInterfaceLayoutDirection = AppLayout.direction
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.onToggle = { [weak self] in self?.toggleSelected() }
        table.autosaveName = "HostsTable"
        table.autosaveTableColumns = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = barButton("plus", L("Add Entry"), #selector(addEntry(_:)))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: L("Delete"))
        removeButton.bezelStyle = .smallSquare
        removeButton.toolTip = L("Delete")
        removeButton.target = self
        removeButton.action = #selector(delete(_:))
        removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let addComment = barButton("text.bubble", L("Add Comment"), #selector(addComment(_:)))
        let sort = NSPopUpButton(frame: .zero, pullsDown: true)
        sort.bezelStyle = .smallSquare
        sort.toolTip = L("Sort and clean up")
        sort.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let sortTitle = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sortTitle.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: L("Sort and clean up"))
        sort.menu?.addItem(sortTitle)
        for item in Self.sortMenuItems() { sort.menu?.addItem(item) }
        sort.menu?.userInterfaceLayoutDirection = AppLayout.direction

        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        revertButton.target = self
        revertButton.action = #selector(revertChanges(_:))
        applyButton.target = self
        applyButton.action = #selector(applyChanges(_:))
        applyButton.bezelColor = .controlAccentColor
        applyButton.toolTip = L("Write the changes to /etc/hosts (⌘S)")

        let bar = NSStackView(views: [add, removeButton, addComment, sort, status, revertButton, applyButton])
        bar.userInterfaceLayoutDirection = AppLayout.direction
        bar.orientation = .horizontal
        bar.distribution = .fill
        bar.spacing = 6
        bar.setCustomSpacing(14, after: sort)
        bar.setCustomSpacing(14, after: status)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for v in [search, scroll, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        view = root
        reload()
    }

    private func barButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.bezelStyle = .smallSquare
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    // MARK: Refresh

    private var filter: String { search.stringValue.trimmingCharacters(in: .whitespaces).lowercased() }

    func reload() {
        guard isViewLoaded else { return }
        let q = filter
        visible = store.rows.indices.filter { i in
            guard !q.isEmpty else { return true }
            let r = store.rows[i]
            return [r.ip, r.hostnames, r.comment].contains { $0.lowercased().contains(q) }
        }
        let selected = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selected.filteredIndexSet { $0 < visible.count }, byExtendingSelection: false)
        updateBar()
    }

    private func updateBar() {
        let entries = store.rows.filter { !$0.isComment }
        var text: String
        if let error = store.loadError {
            text = String(format: L("Cannot read %@: %@"), store.url.path, error)
        } else {
            text = String(format: L("Entries: %d · Off: %d"), entries.count, entries.filter { !$0.enabled }.count)
            if store.isDirty { text += " · " + L("Unsaved changes") }
        }
        status.stringValue = text
        applyButton.isEnabled = store.isDirty
        revertButton.isEnabled = store.isDirty
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
        view.window?.isDocumentEdited = store.isDirty
    }

    @objc private func searchChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search { reload() }
    }

    func focusSearch() { view.window?.makeFirstResponder(search) }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateBar() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let col = Col(rawValue: tableColumn.identifier.rawValue), row < visible.count else { return nil }
        let r = store.rows[visible[row]]
        if col == .on {
            let id = NSUserInterfaceItemIdentifier("check")
            let box = tableView.makeView(withIdentifier: id, owner: self) as? NSButton
                ?? {
                    let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
                    b.identifier = id
                    return b
                }()
            box.state = r.enabled ? .on : .off
            box.isHidden = r.isComment
            box.isEnabled = !r.isSystem
            box.toolTip = r.isSystem ? L("System entry, protected") : (r.enabled ? L("Enabled") : L("Disabled"))
            return box
        }
        let cell = textCell(tableView, col)
        configure(cell.textField!, col, r)
        return cell
    }

    private func textCell(_ tableView: NSTableView, _ col: Col) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("cell-" + col.rawValue)
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier(col.rawValue)
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func configure(_ f: NSTextField, _ col: Col, _ r: HostsRow) {
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let dim: NSColor = r.enabled ? .labelColor : .tertiaryLabelColor
        f.placeholderString = nil
        f.toolTip = nil
        // Addresses and names are Latin: keep them left-to-right even in the Hebrew UI.
        f.baseWritingDirection = .leftToRight
        f.alignment = AppLayout.direction == .rightToLeft ? .right : .left
        switch col {
        case .ip:
            f.stringValue = r.isComment ? "#" : r.ip
            f.font = mono
            f.isEditable = !r.isComment && !r.isSystem
            f.textColor = r.isComment ? .tertiaryLabelColor : (r.ipIsValid ? dim : .systemRed)
            f.placeholderString = r.isComment ? nil : "127.0.0.1"
        case .hosts:
            if r.isComment {
                f.stringValue = r.comment
                f.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask)
                f.textColor = .secondaryLabelColor
                f.baseWritingDirection = .natural
                f.placeholderString = L("Comment")
                f.isEditable = true
            } else {
                f.stringValue = r.hostnames
                f.font = mono
                f.textColor = r.hostnamesAreValid ? dim : .systemRed
                f.placeholderString = L("example.test www.example.test")
                f.isEditable = !r.isSystem
            }
        case .comment:
            f.stringValue = r.isComment ? "" : r.comment
            f.font = .systemFont(ofSize: NSFont.systemFontSize)
            f.textColor = r.enabled ? .secondaryLabelColor : .tertiaryLabelColor
            f.baseWritingDirection = .natural
            f.isEditable = !r.isComment
        case .on:
            break
        }
        if r.isSystem { f.toolTip = L("System entry, protected") }
        else if r.isModified, let error = r.validationError { f.toolTip = error }
    }

    // MARK: Editing

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== search,
              let col = Col(rawValue: field.identifier?.rawValue ?? "") else { return }
        let row = table.row(for: field)
        guard row >= 0, row < visible.count else { return }
        let i = visible[row]
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        // No table reload here: Tab may already be moving the editor to the next cell.
        store.update(L("Edit Entry"), notify: false) { rows in
            switch col {
            case .ip: rows[i].ip = value
            case .hosts:
                if rows[i].isComment { rows[i].comment = value } else { rows[i].hostnames = HostsDocument.normalizeHosts(value) }
            case .comment: rows[i].comment = value
            case .on: break
            }
        }
        configure(field, col, store.rows[i])
        updateBar()
    }

    @objc private func toggled(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, row < visible.count else { return }
        let i = visible[row]
        let on = sender.state == .on
        store.update(on ? L("Enable Entry") : L("Disable Entry")) { $0[i].enabled = on }
    }

    private func toggleSelected() {
        let idx = table.selectedRowIndexes.map { visible[$0] }.filter { !store.rows[$0].isComment && !store.rows[$0].isSystem }
        guard !idx.isEmpty else { NSSound.beep(); return }
        let turnOn = idx.contains { !store.rows[$0].enabled }
        store.update(turnOn ? L("Enable Entry") : L("Disable Entry")) { rows in
            for i in idx { rows[i].enabled = turnOn }
        }
    }

    private func insertionIndex() -> Int {
        table.selectedRowIndexes.last.map { visible[$0] + 1 } ?? store.rows.count
    }

    private func insertAndEdit(_ row: HostsRow, actionName: String, editColumn: Col) {
        if !search.stringValue.isEmpty { search.stringValue = ""; reload() }
        let at = insertionIndex()
        store.update(actionName) { $0.insert(row, at: at) }
        table.selectRowIndexes([at], byExtendingSelection: false)
        table.scrollRowToVisible(at)
        if let c = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == editColumn.rawValue }) {
            table.editColumn(c, row: at, with: nil, select: true)
        }
    }

    @objc func addEntry(_ sender: Any?) {
        insertAndEdit(.entry(ip: "127.0.0.1", hostnames: ""), actionName: L("Add Entry"), editColumn: .hosts)
    }

    @objc func addComment(_ sender: Any?) {
        insertAndEdit(.commentRow(""), actionName: L("Add Comment"), editColumn: .hosts)
    }

    @objc func delete(_ sender: Any?) { removeSelected() }

    private func removeSelected() {
        let all = IndexSet(table.selectedRowIndexes.map { visible[$0] })
        let removable = all.filteredIndexSet { !store.rows[$0].isSystem }
        guard !removable.isEmpty else { NSSound.beep(); return }
        let first = removable.first!
        store.update(L("Delete")) { rows in
            for i in removable.reversed() { rows.remove(at: i) }
        }
        let next = min(first, visible.count - 1)
        table.selectRowIndexes(next >= 0 ? [next] : [], byExtendingSelection: false)
    }

    // MARK: Sort / clean up

    /// Shared by the bottom-bar pull-down and the Entries menu (targets go through the responder chain).
    static func sortMenuItems() -> [NSMenuItem] {
        [
            NSMenuItem(title: L("Sort by Domain"), action: #selector(sortByDomain(_:)), keyEquivalent: ""),
            NSMenuItem(title: L("Sort by IP Address"), action: #selector(sortByIP(_:)), keyEquivalent: ""),
            NSMenuItem(title: L("Sort: Enabled First"), action: #selector(sortEnabledFirst(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: L("Remove Duplicates"), action: #selector(removeDuplicates(_:)), keyEquivalent: ""),
        ]
    }

    @objc func sortByDomain(_ sender: Any?) { sort(.domain) }
    @objc func sortByIP(_ sender: Any?) { sort(.ip) }
    @objc func sortEnabledFirst(_ sender: Any?) { sort(.enabledFirst) }

    private func sort(_ order: HostsSortOrder) {
        view.window?.makeFirstResponder(table)
        if !search.stringValue.isEmpty { search.stringValue = "" }
        store.update(L("Sort")) { rows in rows = HostsDocument.sorted(rows, by: order) }
        reload()
    }

    @objc func removeDuplicates(_ sender: Any?) {
        view.window?.makeFirstResponder(table)
        let result = HostsDocument.removingDuplicates(store.rows)
        store.update(L("Remove Duplicates")) { rows in rows = result.rows }
        let alert = NSAlert()
        alert.messageText = result.removed == 0 ? L("No duplicates found")
            : String(format: L("Duplicates removed: %d"), result.removed)
        if result.removed > 0 { alert.informativeText = L("Not written yet: press Apply to save, or Undo (⌘Z).") }
        alert.runModal()
    }

    // MARK: Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard filter.isEmpty else { return nil }   // reordering a filtered list would be ambiguous
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === table else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        var source = IndexSet()
        info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            if let s = (item.item as? NSPasteboardItem)?.string(forType: Self.dragType), let i = Int(s) { source.insert(i) }
        }
        guard !source.isEmpty else { return false }
        var moved = IndexSet()
        store.update(L("Move")) { rows in moved = HostsDocument.move(&rows, from: source, to: row) }
        table.selectRowIndexes(moved, byExtendingSelection: false)
        return true
    }

    // MARK: Apply / revert

    @objc func applyChanges(_ sender: Any?) { _ = applyNow() }

    /// Validates, checks for edits made by other apps, writes. Returns true when the file was written.
    @discardableResult
    func applyNow() -> Bool {
        view.window?.makeFirstResponder(nil)   // commit the cell being edited
        let problems = store.problems
        if !problems.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("Some entries need fixing")
            alert.informativeText = problems.prefix(6)
                .map { String(format: L("Line %d: %@"), $0.index + 1, $0.message) }.joined(separator: "\n")
            alert.runModal()
            if let first = problems.first, let row = visible.firstIndex(of: first.index) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
            return false
        }
        if store.changedOnDisk {
            let alert = NSAlert()
            alert.messageText = L("/etc/hosts was changed by another app")
            alert.informativeText = L("Overwrite it with your version, or reload it and lose your unsaved changes?")
            alert.addButton(withTitle: L("Overwrite"))
            alert.addButton(withTitle: L("Reload"))
            alert.addButton(withTitle: L("Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: store.load(); return false
            default: return false
            }
        }
        do {
            try store.apply()
            return true
        } catch HostsWriter.WriteError.cancelled {
            return false
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not write /etc/hosts.")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    @objc func revertChanges(_ sender: Any?) {
        guard store.isDirty else { return }
        let alert = NSAlert()
        alert.messageText = L("Discard unsaved changes?")
        alert.informativeText = L("The list goes back to what /etc/hosts contains now.")
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { store.load() }
    }

    @objc func reloadFromDisk(_ sender: Any?) {
        if store.isDirty { revertChanges(sender) } else { store.load() }
    }

    @objc func performFindPanelAction(_ sender: Any?) { focusSearch() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(delete(_:)): return !table.selectedRowIndexes.isEmpty
        case #selector(applyChanges(_:)), #selector(revertChanges(_:)): return store.isDirty
        default: return true
        }
    }
}
