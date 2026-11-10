import Darwin
import Foundation

/// One line of the hosts file below the header: an entry (enabled or commented out) or a comment.
struct HostsRow: Equatable {
    let id: UUID
    var isComment: Bool
    var enabled: Bool
    var ip: String
    var hostnames: String
    /// Inline comment of an entry, or the text of a comment row (without the leading "#").
    var comment: String
    /// Empty lines above this row; they travel with it when it is moved.
    var blankLinesBefore: Int
    /// The line as read from disk. Written back byte-for-byte while the fields still match `rawSignature`,
    /// so untouched lines keep their original spacing.
    var raw: String?
    var rawSignature: String?

    init(id: UUID = UUID(), isComment: Bool = false, enabled: Bool = true, ip: String = "",
         hostnames: String = "", comment: String = "", blankLinesBefore: Int = 0) {
        self.id = id
        self.isComment = isComment
        self.enabled = enabled
        self.ip = ip
        self.hostnames = hostnames
        self.comment = comment
        self.blankLinesBefore = blankLinesBefore
    }

    static func entry(ip: String, hostnames: String, comment: String = "", enabled: Bool = true) -> HostsRow {
        HostsRow(enabled: enabled, ip: ip, hostnames: hostnames, comment: comment)
    }

    static func commentRow(_ text: String) -> HostsRow {
        HostsRow(isComment: true, comment: text)
    }

    var signature: String { "\(isComment)|\(enabled)|\(ip)|\(hostnames)|\(comment)" }
    var isModified: Bool { raw == nil || rawSignature != signature }
    var hostnameList: [String] { hostnames.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }

    var line: String {
        if !isModified, let raw { return raw }
        if isComment { return comment.isEmpty ? "#" : "# " + comment }
        var s = ip + "\t" + HostsDocument.normalizeHosts(hostnames)
        if !comment.isEmpty { s += " # " + comment }
        return enabled ? s : "# " + s
    }

    /// The loopback/broadcast lines macOS needs. Protected: they can't be switched off or deleted.
    var isSystem: Bool {
        guard !isComment, enabled else { return false }
        let names = hostnameList
        return ["127.0.0.1", "::1", "255.255.255.255", "fe80::1%lo0"].contains(ip)
            && !names.isEmpty && names.allSatisfy { $0 == "localhost" || $0 == "broadcasthost" }
    }

    var ipIsValid: Bool { isComment || HostsDocument.isIP(ip) }
    var hostnamesAreValid: Bool {
        isComment || (!hostnameList.isEmpty && hostnameList.allSatisfy(HostsDocument.isHostname))
    }

    var validationError: String? {
        if isComment { return nil }
        if !HostsDocument.isIP(ip) { return String(format: L("Invalid IP address: %@"), ip) }
        let names = hostnameList
        if names.isEmpty { return L("Add at least one hostname") }
        if let bad = names.first(where: { !HostsDocument.isHostname($0) }) {
            return String(format: L("Invalid hostname: %@"), bad)
        }
        return nil
    }
}

/// The hosts file: header comment block (kept verbatim) + rows.
struct HostsDocument: Equatable {
    var header: [String] = []
    var rows: [HostsRow] = []
    var trailingBlankLines = 0
    var endsWithNewline = true

    static func parse(_ text: String) -> HostsDocument {
        var doc = HostsDocument()
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() } else { doc.endsWithNewline = false }
        let firstEntry = lines.firstIndex { parseEntry($0) != nil } ?? lines.count
        doc.header = Array(lines[..<firstEntry])
        var blanks = 0
        for line in lines[firstEntry...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { blanks += 1; continue }
            var row: HostsRow
            if let e = parseEntry(line) {
                row = .entry(ip: e.ip, hostnames: e.hostnames, comment: e.comment, enabled: e.enabled)
            } else if t.hasPrefix("#") {
                var text = t.dropFirst()
                if text.first == " " { text = text.dropFirst() }
                row = .commentRow(String(text))
            } else {
                // A line that is neither an entry nor a comment: shown as an (invalid) entry, kept as is.
                let body = t.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                row = .entry(ip: parts.first ?? "", hostnames: parts.dropFirst().joined(separator: " "))
            }
            row.blankLinesBefore = blanks
            blanks = 0
            row.raw = line
            row.rawSignature = row.signature
            doc.rows.append(row)
        }
        doc.trailingBlankLines = blanks
        return doc
    }

    func serialized() -> String {
        var out = header
        for r in rows {
            out += Array(repeating: "", count: r.blankLinesBefore)
            out.append(r.line)
        }
        out += Array(repeating: "", count: trailingBlankLines)
        let text = out.joined(separator: "\n")
        return endsWithNewline && !out.isEmpty ? text + "\n" : text
    }

    /// "1.2.3.4  a b" or "# 1.2.3.4 a  # note" -> fields; nil when the line is not an entry.
    static func parseEntry(_ line: String) -> (enabled: Bool, ip: String, hostnames: String, comment: String)? {
        var s = line.trimmingCharacters(in: .whitespaces)
        var enabled = true
        if s.hasPrefix("#") {
            enabled = false
            s = String(s.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" }))
        }
        var comment = ""
        if let hash = s.firstIndex(of: "#") {
            comment = s[s.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            s = String(s[..<hash])
        }
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2, isIP(parts[0]), parts.dropFirst().allSatisfy(isHostname) else { return nil }
        return (enabled, parts[0], parts.dropFirst().joined(separator: " "), comment)
    }

    static func normalizeHosts(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).joined(separator: " ")
    }

    static func isIP(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return true }
        // IPv6 may carry a zone: fe80::1%lo0
        let addr = s.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        return addr.contains(":") && inet_pton(AF_INET6, addr, &v6) == 1
    }

    static func isHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        return s.range(of: #"^[A-Za-z0-9_]([A-Za-z0-9_.-]*[A-Za-z0-9_])?$"#, options: .regularExpression) != nil
    }

    /// Moves the items at `source` so they land before index `destination` (indexes of the original array).
    /// Returns where the moved items are now.
    @discardableResult
    static func move<T>(_ items: inout [T], from source: IndexSet, to destination: Int) -> IndexSet {
        let moving = source.map { items[$0] }
        let before = source.count(in: 0..<destination)
        for i in source.reversed() { items.remove(at: i) }
        let at = destination - before
        items.insert(contentsOf: moving, at: at)
        return IndexSet(at..<(at + moving.count))
    }
}
