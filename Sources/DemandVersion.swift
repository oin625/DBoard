import Foundation

/// A new iteration keeps an immutable, readable baseline without copying old execution events.
struct DemandVersion: Codable, Equatable {
    struct Repository: Codable, Equatable {
        let path: String
        let branch: String
        var role: String? = nil
    }
    let number: Int
    let parentID: String
    let rootID: String
    let parentTitle: String
    let sourceRevision: String
    let background: String
    let repositories: [Repository]

    var label: String { "\(number).0" }
    static let prefix = "<!-- dboard-version:v1:"
    private static let suffix = " -->"

    enum ReadError: LocalizedError {
        case invalid
        var errorDescription: String? { "上一版本的背景记录无法读取，请检查数据后重试" }
    }

    var isValid: Bool {
        number >= 2 && number < Int.max &&
        [parentID, rootID].allSatisfy { $0.range(of: #"^[DP][0-9]{3,}$"#, options: .regularExpression) != nil } &&
        !parentTitle.trimmed.isEmpty && !background.trimmed.isEmpty &&
        sourceRevision.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil &&
        repositories.allSatisfy { !$0.path.trimmed.isEmpty && !$0.branch.trimmed.isEmpty }
    }

    static func read(_ lines: [String]) throws -> Self? {
        let records = lines.filter { $0.hasPrefix(prefix) }
        guard records.count <= 1 else { throw ReadError.invalid }
        guard let line = records.first else { return nil }
        guard line.hasSuffix(suffix),
              let data = Data(base64Encoded: String(line.dropFirst(prefix.count).dropLast(suffix.count))),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { throw ReadError.invalid }
        return value
    }

    var stored: String {
        get throws {
            guard isValid else { throw ReadError.invalid }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return Self.prefix + (try encoder.encode(self)).base64EncodedString() + Self.suffix
        }
    }

    static func archiveNotes(_ block: [String]) -> [String] {
        var notes = block.filter { $0.hasPrefix("- 📝") }
        if let index = block.firstIndex(where: { $0.hasPrefix("- **归档历史**") }) {
            var end = index + 1
            while end < block.count && block[end].hasPrefix("    ") {
                notes.append(String(block[end].dropFirst(4)))
                end += 1
            }
        }
        return notes
    }

    static func baseline(item: DItem, block: [String]) throws -> String {
        guard item.changeReadError == nil, item.versionReadError == nil, item.chatReadError == nil else { throw ReadError.invalid }
        var text = ["上一版本：\(item.id)「\(item.displayTitle)」",
                    "以下是归档时的历史背景，不能当作本轮已完成的成果；先核对实际代码。"]
        if !item.project.isEmpty { text.append("项目：" + item.project) }
        if !item.title.isEmpty && item.title != "（待补充）" { text.append("说明：" + item.title) }
        let spell = DemandPromptSections(stored: item.prompt).assembled
        if !spell.isEmpty { text.append(spell) }
        if let branch = item.branch, !branch.isEmpty && branch != "待定" { text.append("归档时的分支：" + branch) }
        if let link = item.reqFlow { text.append("原需求流（背景）：" + link.markdown) }
        if let chats = item.chatLinks { text.append("原关联群聊（背景）：\n" + chats.assembled) }
        text.append("历史进度：")
        text.append(item.milestones.isEmpty ? "未记录，需查看实际代码。" :
            item.milestones.map { $0.date + "：" + $0.fullContent }.joined(separator: "\n"))
        for change in item.changes { text.append("历史变更 " + change.id + "：\n" + change.intent) }
        text.append(contentsOf: archiveNotes(block))
        if let previous = item.version { text.append("更早版本的背景：\n" + previous.background) }
        return text.joined(separator: "\n")
    }


    static func environmentHints(_ block: [String]) throws -> [Repository] {
        guard let line = block.first(where: { $0.hasPrefix("<!-- dboard-ai-feedback:v1:") }) else { return [] }
        let prefix = "<!-- dboard-ai-feedback:v1:"
        guard line.hasSuffix(" -->"), let data = Data(base64Encoded: String(line.dropFirst(prefix.count).dropLast(4))),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadError.invalid }
        guard let raw = object["environment_repositories"] else { return [] }
        guard let rows = raw as? [[String: String]] else { throw ReadError.invalid }
        return try rows.map {
            guard let path = $0["path"], let branch = $0["branch"], let role = $0["role"],
                  !path.isEmpty, !branch.isEmpty, ["integration", "release"].contains(role) else { throw ReadError.invalid }
            return Repository(path: path, branch: branch, role: role)
        }
    }

    static func repositoryHints(_ block: [String], item: DItem) throws -> [Repository] {
        let records = block.filter { $0.hasPrefix("<!-- dboard-ai-feedback:v1:") }
        guard records.count <= 1 else { throw ReadError.invalid }
        if let record = records.first {
            let prefix = "<!-- dboard-ai-feedback:v1:"
            guard record.hasSuffix(" -->"),
                  let data = Data(base64Encoded: String(record.dropFirst(prefix.count).dropLast(4))),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["repositories"] as? [[String: String]] else { throw ReadError.invalid }
            let repositories = try raw.map { repo -> Repository in
                guard let path = repo["path"], let branch = repo["branch"], !path.isEmpty, !branch.isEmpty else {
                    throw ReadError.invalid
                }
                return Repository(path: path, branch: branch)
            }
            return repositories
        }
        return item.version?.repositories ?? []
    }
}
