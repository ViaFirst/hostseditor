import Darwin
import Foundation

enum HostsSortOrder: CaseIterable {
    case domain, ip, enabledFirst
}

extension HostsDocument {
    /// "www.acf.local" and "acf.local" sort together.
    static func domainKey(_ row: HostsRow) -> String {
        let n = (row.hostnameList.first ?? "").lowercased()
        return n.hasPrefix("www.") ? String(n.dropFirst(4)) : n
    }

    /// Numeric key: IPv4 before IPv6, each by its bytes; invalid addresses last.
    static func ipKey(_ ip: String) -> [Int] {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            return [4] + withUnsafeBytes(of: &v4) { $0.map(Int.init) }
        }
        let addr = String(ip.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if inet_pton(AF_INET6, addr, &v6) == 1 {
            return [6] + withUnsafeBytes(of: &v6) { $0.map(Int.init) }
        }
        return [9]
    }

    /// Sorts entries inside each group. A comment row starts a group and stays where it is, so blocks such as
    /// LocalWP's "## Local - Start ##" keep their entries. System lines stay first; blank lines stay in place.
    static func sorted(_ rows: [HostsRow], by order: HostsSortOrder) -> [HostsRow] {
        func less(_ a: (Int, HostsRow), _ b: (Int, HostsRow)) -> Bool {
            let (ia, x) = a, (ib, y) = b
            if x.isSystem != y.isSystem { return x.isSystem }
            switch order {
            case .domain:
                if domainKey(x) != domainKey(y) { return domainKey(x) < domainKey(y) }
                if ipKey(x.ip) != ipKey(y.ip) { return ipKey(x.ip).lexicographicallyPrecedes(ipKey(y.ip)) }
            case .ip:
                if ipKey(x.ip) != ipKey(y.ip) { return ipKey(x.ip).lexicographicallyPrecedes(ipKey(y.ip)) }
                if domainKey(x) != domainKey(y) { return domainKey(x) < domainKey(y) }
            case .enabledFirst:
                if x.enabled != y.enabled { return x.enabled }
                if domainKey(x) != domainKey(y) { return domainKey(x) < domainKey(y) }
            }
            return ia < ib   // stable
        }
        var out: [HostsRow] = []
        var bucket: [HostsRow] = []
        func flush() {
            let blanks = bucket.map(\.blankLinesBefore)
            var sortedBucket = bucket.enumerated().map { ($0.offset, $0.element) }.sorted(by: less).map(\.1)
            for i in sortedBucket.indices { sortedBucket[i].blankLinesBefore = blanks[i] }
            out += sortedBucket
            bucket = []
        }
        for r in rows {
            if r.isComment { flush(); out.append(r) } else { bucket.append(r) }
        }
        flush()
        return out
    }

    /// Removes entries with the same IP and the same set of hostnames (the first one stays; it is enabled if
    /// any of the copies was). Comment rows are left alone.
    static func removingDuplicates(_ rows: [HostsRow]) -> (rows: [HostsRow], removed: Int) {
        var out: [HostsRow] = []
        var seen: [String: Int] = [:]
        var removed = 0
        for r in rows {
            guard !r.isComment else { out.append(r); continue }
            let key = r.ip.lowercased() + "|" + r.hostnameList.map { $0.lowercased() }.sorted().joined(separator: " ")
            if let kept = seen[key] {
                if r.enabled { out[kept].enabled = true }
                removed += 1
            } else {
                seen[key] = out.count
                out.append(r)
            }
        }
        return (out, removed)
    }
}

/// What the menu-bar menu shows: sections (from comment rows), and in each one entries merged by hostnames
/// (127.0.0.1 + ::1 lines of one site become one item), sorted A–Z.
enum HostsMenuModel {
    struct Section {
        var title: String?
        var entries: [Entry]
    }

    struct Entry {
        var title: String
        var rows: [HostsRow]
        /// The same names point at different servers: chosen in a submenu instead of one switch.
        var hasAlternatives: Bool {
            Set(rows.map { HostsMenuModel.ipClass($0.ip) }).count > 1
        }
        var allOn: Bool { rows.allSatisfy(\.enabled) }
        var anyOn: Bool { rows.contains(where: \.enabled) }
        var ips: String {
            var seen = Set<String>()
            return rows.map(\.ip).filter { seen.insert($0).inserted }.joined(separator: ", ")
        }
    }

    /// Loopback addresses count as one place: "127.0.0.1" and "::1" for a site are not alternatives.
    static func ipClass(_ ip: String) -> String {
        if ip == "::1" || ip.hasPrefix("127.") || ip == "0.0.0.0" { return "local" }
        return ip
    }

    /// "acf.local www.acf.local" -> "acf.local" (www. twins hidden).
    static func displayName(_ names: [String]) -> String {
        let lower = Set(names.map { $0.lowercased() })
        var seen = Set<String>()
        return names.filter { n in
            let l = n.lowercased()
            if l.hasPrefix("www."), lower.contains(String(l.dropFirst(4))) { return false }
            return seen.insert(l).inserted
        }.joined(separator: ", ")
    }

    /// "## Local - Start ##" -> "Local"; nil for "## Local - End ##" (it closes the block) and empty comments.
    static func sectionTitle(_ comment: String) -> String? {
        var t = comment.trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
        let lower = t.lowercased()
        if lower.hasSuffix(" end") || lower == "end" { return nil }
        if let suffix = [" - start", " start"].first(where: lower.hasSuffix) { t = String(t.dropLast(suffix.count)) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "-: \t"))
        return t.isEmpty ? nil : t
    }

    /// Lines for "x.local" and "www.x.local" (LocalWP writes them separately) belong to one item.
    static func mergeKey(_ names: [String]) -> String {
        Set(names.map { n -> String in
            let l = n.lowercased()
            return l.hasPrefix("www.") ? String(l.dropFirst(4)) : l
        }).sorted().joined(separator: " ")
    }

    static func build(_ rows: [HostsRow]) -> [Section] {
        var sections: [Section] = [Section(title: nil, entries: [])]
        var index: [String: Int] = [:]
        for r in rows {
            if r.isComment {
                sections.append(Section(title: sectionTitle(r.comment), entries: []))
                index = [:]
                continue
            }
            guard !r.isSystem, !r.hostnameList.isEmpty else { continue }
            let key = mergeKey(r.hostnameList)
            let s = sections.count - 1
            if let i = index[key] {
                sections[s].entries[i].rows.append(r)
                sections[s].entries[i].title = displayName(sections[s].entries[i].rows.flatMap(\.hostnameList))
            } else {
                index[key] = sections[s].entries.count
                sections[s].entries.append(Entry(title: displayName(r.hostnameList), rows: [r]))
            }
        }
        return sections.compactMap { s in
            guard !s.entries.isEmpty else { return nil }
            var s = s
            s.entries.sort { a, b in
                let ka = HostsDocument.domainKey(a.rows[0]), kb = HostsDocument.domainKey(b.rows[0])
                return ka != kb ? ka < kb : a.title < b.title
            }
            return s
        }
    }
}
