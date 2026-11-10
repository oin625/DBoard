import Foundation

/// Cloud documents contain a public overview, not an executable cache snapshot.
/// Keep this projection aligned with Tools/dboard_overview.py (shared-fixture tests).
enum DemandOverview {
    static let receiptPrefix = "<!-- synced-overview:v1: "
    static let nodePrefix = "<!-- synced-node: "
    static let header = "# 进行时 · 需求总览\n\n> 本文只展示需求概况和当前进度；完整咒言、资料、变更、工程分支与历史记录保存在 D板本机。"
    static let headings = ["## 🔴 重要且紧急", "## 🟡 重要不紧急", "## 🟠 紧急不重要", "## 🟢 不紧急不重要"]

    enum ReadError: LocalizedError {
        case invalid
        var errorDescription: String? { "需求总览无法可靠生成，未同步；请检查重复字段、编号或变更记录。" }
    }

    static func compact(_ value: String) -> String {
        var text = value.components(separatedBy: "\n").map(\.trimmed).filter {
            !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") &&
                !$0.hasPrefix("![") && !$0.hasPrefix("```")
        }.joined(separator: " ")
        text = text.replacingOccurrences(of: #"https?://[^\s]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"/(?:Users|home|tmp|work)/[^\s，。；]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        return DemandProgress.summary(text)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func usefulProgress(_ value: String) -> Bool {
        let text = value.replacingOccurrences(of: #"^\[C[0-9/]+\]\s*"#, with: "", options: .regularExpression).trimmed
        return !text.isEmpty && text != "已更新开发仓库与分支。" &&
            text.range(of: #"^已记录.*(?:开发仓库与分支|工作树及开发分支|工作树及开发分支。)[。]?$"#,
                       options: .regularExpression) == nil &&
            text.range(of: #"^已在独立工作区重放[0-9]+个文件，Luban收到[0-9]+条事件，代码及Git状态保持一致[。]?$"#,
                       options: .regularExpression) == nil
    }

    private static func field(_ name: String, in block: [String]) throws -> String {
        let tag = "- **" + name + "**"
        let indices = block.indices.filter { block[$0].hasPrefix(tag) }
        guard indices.count <= 1 else { throw ReadError.invalid }
        guard let index = indices.first else { return "" }
        var first = String(block[index].dropFirst(tag.count)).trimmed
        if first.hasPrefix("：") || first.hasPrefix(":") { first.removeFirst() }
        var parts = [first]
        var next = index + 1
        while next < block.count && block[next].hasPrefix("    ") {
            parts.append(String(block[next].dropFirst(4))); next += 1
        }
        return parts.joined(separator: "\n").trimmed
    }

    private static func items(_ content: String) throws -> [(DItem, [String])] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let sourceHeadings = lines.filter { $0.range(of: #"^### [DP][0-9]"#, options: .regularExpression) != nil }
        guard sourceHeadings.allSatisfy({
            $0.range(of: #"^### [DP][0-9]{3,}(?=【|\s|$)"#, options: .regularExpression) != nil
        }) else { throw ReadError.invalid }
        let parsed = CacheParser.parse(content: "## 🟡\n" + normalized).items
        guard Set(parsed.map(\.id)).count == parsed.count, parsed.count == sourceHeadings.count else {
            throw ReadError.invalid
        }
        return try parsed.map { item in
            guard item.changeReadError == nil, let range = DItemStore.blockRange(lines, id: item.id) else { throw ReadError.invalid }
            let block = Array(lines[range])
            guard ItemStatus.allValues.filter({ block[0].contains($0.rawValue) }).count == 1 else { throw ReadError.invalid }
            for name in ["项目", "描述", "概括", "需求流", "进度"] { _ = try field(name, in: block) }
            if !(try field("需求流", in: block)).isEmpty && item.reqFlow?.isValid != true { throw ReadError.invalid }
            return (item, block)
        }
    }

    private static func renderItem(_ item: DItem, block: [String]) throws -> String {
        let projects = DemandRepositoryEntries.parse(item.project).map(DemandDeliveryProject.name)
        var seen = Set<String>()
        let project = projects.filter { seen.insert($0).inserted }.joined(separator: "；")
        let publicTitle = item.isIncident ? item.headerTitle : item.displayTitle
        let title = compact(publicTitle.replacingOccurrences(of: #"\s*✅[0-9]{4}-[0-9]{2}-[0-9]{2}"#,
            with: "", options: .regularExpression))
        let dates = matches(#"[📅🎯](?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})"#, in: block[0])
        var heading = "### " + item.id + (project.isEmpty ? " " : "【" + project + "】") +
            (title.isEmpty ? "（未命名）" : title) + " " + item.status.rawValue
        if !dates.isEmpty { heading += " " + dates.joined(separator: "→") }
        if let stamp = matches(#"✅[0-9]{4}-[0-9]{2}-[0-9]{2}"#, in: block[0]).first { heading += " " + stamp }
        var overview = try field("概括", in: block)
        if overview.isEmpty && !item.isIncident { overview = item.title }
        if ["（待补充）", "待补充"].contains(overview) { overview = "" }
        if overview.isEmpty && !item.isIncident {
            let goal = compact(DemandPromptSections(stored: item.prompt).intent)
            overview = String(goal.prefix { !"。！？；;\n".contains($0) }).trimmed
        }
        overview = compact(overview)
        let records = item.milestones.map { Milestone(date: $0.date, content: compact($0.summary)) }
        let mentioned = Set(matches(#"\bC[0-9]{3,}\b"#, in: records.map(\.content).joined(separator: "\n")))
        let pending = item.changes.filter { !mentioned.contains($0.id) }.count
        let progress = records.last { usefulProgress($0.content) }
        var lines = [heading]
        if !overview.isEmpty { lines += ["- **概括**：" + overview] }
        if pending > 0 {
            var text = "新增 " + String(pending) + " 项变更待处理。"
            if let progress { text += "上次进度（" + progress.date + "）：" + progress.content }
            lines += ["- **进度**：", "    - " + (progress?.date ?? "待处理") + ": " + text]
        } else if let progress {
            lines += ["- **进度**：", "    - " + progress.date + ": " + progress.content]
        }
        if let link = item.reqFlow, link.isValid { lines += ["- **需求流**：" + link.markdown] }
        return lines.joined(separator: "\n")
    }

    static func render(_ content: String) throws -> String {
        let entries = try items(content)
        var lines = [header, ""]
        for (index, priority) in ItemPriority.allCases.enumerated() {
            let group = entries.filter { $0.0.priority == priority }
            if !group.isEmpty {
                lines += [headings[index], ""]
                for (item, block) in group { lines += [try renderItem(item, block: block), ""] }
            }
        }
        if entries.isEmpty { lines += ["暂无需求。", ""] }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    static func archiveBlock(_ block: [String]) throws -> [String] {
        let entries = try items(block.joined(separator: "\n"))
        guard entries.count == 1 else { throw ReadError.invalid }
        return try renderItem(entries[0].0, block: entries[0].1).components(separatedBy: "\n")
    }

    static func hash(_ content: String) throws -> String { ContentRevision.hash(try render(content)) }

    static func matchesReceipt(_ content: String) -> Bool {
        let receipts = content.components(separatedBy: "\n").filter { $0.hasPrefix(receiptPrefix) }
        guard receipts.count == 1, let receipt = receipts.first, receipt.hasSuffix(" -->"),
              let current = try? hash(content) else { return false }
        return String(receipt.dropFirst(receiptPrefix.count).dropLast(4)) == current
    }
}

private extension ItemStatus {
    static var allValues: [Self] { [.pending, .inProgress, .completed, .suspended] }
}
