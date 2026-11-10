import Foundation

/// AI-owned snapshot; original records and user-owned corrections remain independent.
struct DemandHandoff: Decodable {
    struct Sections: Decodable {
        let completed: String
        let pending: String
        let decisions: String
        let verification: String
    }
    struct Resource: Decodable {
        let topic: String
        let source: String
        let when_to_read: String
    }
    struct Decision: Decodable {
        let decision: String
        let reason: String
        let checked_at: String
    }
    let version: Int
    let sections: Sections
    let references: [String]
    let resources: [Resource]?
    let policy: String?
    let covered_count: Int
    let compacted_count: Int
    let updated_at: String
    let compacted_at: String?
    let last_decision: Decision

    static let prefix = "<!-- dboard-handoff:v1:"
    static let notesField = "- **交接补充**"

    static func read(_ block: [String]) throws -> DemandHandoff? {
        let rows = block.filter { $0.hasPrefix(prefix) }
        guard !rows.isEmpty else { return nil }
        guard rows.count == 1, let row = rows.first, row.hasSuffix(" -->"),
              let data = Data(base64Encoded: String(row.dropFirst(prefix.count).dropLast(4))),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.covered_count >= 0,
              value.policy == nil || value.policy == "task-state-v2",
              (value.resources ?? []).allSatisfy({
                  !$0.topic.trimmed.isEmpty && !$0.source.trimmed.isEmpty && !$0.when_to_read.trimmed.isEmpty
              }),
              value.compacted_count >= 0, value.compacted_count <= value.covered_count,
              !value.sections.pending.trimmed.isEmpty,
              ["compact", "skip"].contains(value.last_decision.decision),
              !value.last_decision.reason.trimmed.isEmpty else {
            throw NSError(domain: "DemandHandoff", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "交接摘要无法读取，原记录仍保留；请核对本地数据"])
        }
        return value
    }

    static func notes(_ block: [String]) -> String {
        guard let index = block.firstIndex(where: { $0.hasPrefix(notesField) }) else { return "" }
        let first = String(block[index].dropFirst(notesField.count))
            .replacingOccurrences(of: "^\\s*[：:]?\\s*", with: "", options: .regularExpression)
        var rows = [first]
        var next = index + 1
        while next < block.count && block[next].hasPrefix("    ") {
            rows.append(String(block[next].dropFirst(4)))
            next += 1
        }
        return rows.joined(separator: "\n").trimmed
    }
}
