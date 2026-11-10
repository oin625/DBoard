import Foundation

/// Demand identities come from headings and structured links, never arbitrary log or business text.
enum DemandNumbering {
    static func number(_ id: String) -> Int? {
        guard id.range(of: #"^[DP][0-9]{3,}$"#, options: .regularExpression) != nil else { return nil }
        return Int(id.dropFirst())
    }

    static func reservedIDs(in content: String) -> Set<String> {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        var ids = Set<String>()
        for line in normalized.components(separatedBy: "\n") {
            guard let range = line.range(of: #"^### [DP][0-9]{3,}(?=【|\s|$)"#,
                                         options: .regularExpression) else { continue }
            ids.insert(String(line[range].dropFirst(4)))
        }
        let parsed = CacheParser.parse(content: "## 🟡\n" + normalized)
        for item in parsed.items where ids.contains(item.id) {
            if let version = item.version {
                ids.insert(version.parentID)
                ids.insert(version.rootID)
            }
        }
        let sections = parsed.prevSecs + (parsed.todaySec.map { [$0] } ?? [])
        for section in sections {
            for todo in section.items {
                if let linked = todo.linkedDItem, number(linked) != nil { ids.insert(linked) }
            }
        }
        return ids
    }

    static func nextID(contents: [String], reserving explicitIDs: [String], lastAssigned: Int,
                       kind: DemandKind = .development) -> String {
        let ids = contents.reduce(into: Set(explicitIDs)) { $0.formUnion(reservedIDs(in: $1)) }
        let maximum = max(lastAssigned, ids.filter { $0.hasPrefix(kind.idPrefix) }.compactMap(number).max() ?? 0)
        return kind.idPrefix + String(format: "%03ld", maximum + 1)
    }
}
