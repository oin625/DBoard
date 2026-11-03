import Foundation

/// Delivery notes use complete source sentences, independently of the dashboard's short summaries.
/// The generator extracts recorded facts; it does not infer implementation from a requirement.
enum DemandDeliveryDocument {
    static let formatVersion = 2

    private enum Kind { case implementation, verification, followUp, operation, state }

    static func render(_ plan: DemandDeliveryPlan) -> String {
        let item = plan.item
        let spell = DemandPromptSections(stored: item.prompt)
        let records = item.milestones.filter {
            $0.content != DemandDeliveryPlan.feedbackSummary &&
            !$0.content.contains("开发仓库与分支") && $0.content != "已更新开发仓库与分支。"
        }
        let scopes = item.changes.isEmpty ? [""] : item.changes.map(\.id)
        var implementations: [(scope: String, record: Milestone, parts: [String])] = []
        for scope in scopes {
            if let record = records.last(where: {
                (scope.isEmpty || changeIDs($0.fullContent).contains(scope)) && !implementationParts($0).isEmpty
            }) {
                implementations.append((scope, record, implementationParts(record)))
            }
        }
        let goal = spell.intent.trimmed.isEmpty
            ? (item.title == "（待补充）" ? item.displayTitle : item.title) : spell.intent
        var lines = ["# " + item.displayTitle + " · 技术交付说明", "",
            "需求：[" + plan.link.no + "](" + plan.link.url + ") · D板 " + item.id, "",
            "## 改造目标", ""]
        // Once implementation is recorded, the goal introduces the problem, rather than
        // repeating the entire original design (which later changes may have replaced).
        let goalParts = sentences(goal)
        append(implementations.isEmpty ? goalParts : Array(goalParts.prefix(2)), to: &lines)
        if !spell.supplement.trimmed.isEmpty {
            lines += ["### 补充约束", ""]
            append(sentences(spell.supplement), to: &lines)
        }

        lines += ["## 关键实现与变更", ""]
        if !plan.technicalNotes.isEmpty {
            lines += ["根据交付分支中已记录的接口说明整理：", "", plan.technicalNotes, ""]
            for change in item.changes where !implementations.contains(where: { $0.scope == change.id }) {
                lines += ["### " + change.id + " · 追加要求", "", "尚无可用的实现明细，以下要求不代表已完成：", ""]
                append(sentences(change.intent), to: &lines, bullets: true)
            }
        } else if item.changes.isEmpty {
            if let implementation = implementations.first {
                append(implementation.parts, to: &lines, bullets: true)
            } else {
                lines += ["暂无实现明细，完成情况待确认。", ""]
            }
        } else {
            lines += ["以下摘自最近的实现记录；追加要求不会被当作已完成。", ""]
            for change in item.changes {
                lines += ["### " + change.id, ""]
                if let implementation = implementations.first(where: { $0.scope == change.id }) {
                    append(implementation.parts, to: &lines, bullets: true)
                } else {
                    lines += ["尚无可用的实现明细，以下为追加要求：", ""]
                    append(sentences(change.intent), to: &lines, bullets: true)
                }
            }
        }

        lines += ["## 工程与分支", ""]
        append(plan.projects.map { $0.name + "：`" + $0.branch + "`" }, to: &lines, bullets: true)
        lines += ["## 当前状态与验证", ""]
        if let latest = records.last {
            append(sentences(latest.content), to: &lines)
            let detailParts = sentences(latest.details)
            // The latest record owns submission/deployment status. Earlier "not pushed"
            // statements must not survive a later successful push.
            append(detailParts.filter {
                let category = kind($0)
                return category != .implementation && category != .operation
            }, to: &lines, bullets: true)
            let latestHasVerification = detailParts.contains { kind($0) == .verification } ||
                sentences(latest.content).contains { kind($0) == .verification }
            let newestImplementation = records.last { record in
                implementations.contains { $0.record.fullContent == record.fullContent }
            }
            if let previous = newestImplementation, previous.fullContent != latest.fullContent {
                let notes = sentences(previous.details).filter {
                    kind($0) == .followUp || (!latestHasVerification && kind($0) == .verification)
                }
                if !notes.isEmpty {
                    lines += ["实现记录补充（" + previous.date + "；后续确认结果以最新记录为准）：", ""]
                    append(notes, to: &lines, bullets: true)
                }
            }
        } else {
            lines += ["未记录开发与验证结果，完成情况待确认。", ""]
        }
        lines += ["本文整理 D板已有记录；提交交付物不代表验收或上线。"]
        return lines.joined(separator: "\n")
    }

    private static func implementationParts(_ record: Milestone) -> [String] {
        // Structured records have a short headline and separate detail; legacy records
        // keep all facts in content. Never run either through DemandProgress.summary.
        let headline = record.content.replacingOccurrences(of: #"^\[C[0-9/]+\]\s*"#,
            with: "", options: .regularExpression)
        guard !starts(headline, ["计划", "拟", "准备", "待实现", "尚未开发", "正在设计"]),
              !record.content.contains("未改代码"), !record.content.contains("未修改代码"),
              !record.content.contains("阻塞"), !record.content.contains("尚未开始") else { return [] }
        let source = record.details.trimmed.isEmpty ? record.content : record.details
        return sentences(source).filter { kind($0) == .implementation }
    }

    private static func kind(_ part: String) -> Kind {
        let text = part.replacingOccurrences(of: #"^\[C[0-9]+\]\s*"#,
            with: "", options: .regularExpression)
        // Operational bookkeeping is distinct from the code that was delivered.
        if starts(text, ["仓库：", "分支：", "工作区", "本地HEAD", "HEAD", "push", "提交", "已提交",
                         "本轮已提交", "已成功push", "本地outputs", "已记录", "用户指定", "用户继续",
                         "用户已", "本轮只核查", "本轮未读取", "本轮未改", "未改代码"]) { return .operation }
        if text.contains("测试") || text.contains("构建") || text.contains("diff") ||
            text.contains("差异检查") || text.contains("回读") || text.contains("未重跑") { return .verification }
        if starts(text, ["待", "需", "下一步", "重点待", "注意", "确认前", "无法", "尚无",
                         "计划", "拟", "准备", "将", "正在", "建议", "预计"]) ||
            text.contains("仍待确认") || text.contains("尚未回复") || text.contains("尚未答复") ||
            text.contains("字段契约阻塞") { return .followUp }
        if starts(text, ["开发完成", "完成情况", "代码未", "改动未", "尚未", "未提交", "未部署",
                         "未推送", "未做", "接口文档", "文档已", "DWS", "详见", "见doc", "本轮暂存"]) {
            return .state
        }
        // Preserve unfamiliar domain facts instead of requiring a hard-coded API vocabulary.
        return .implementation
    }

    private static func starts(_ text: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { text.hasPrefix($0) }
    }

    private static func changeIDs(_ text: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: #"\bC[0-9]{3,}\b"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    /// Split at actual sentence boundaries; never cut off a parameter or an exception
    /// merely because it falls after character 80/120. URLs and code spans remain intact.
    static func sentences(_ text: String, splitClauses: Bool = true) -> [String] {
        var output: [String] = []
        var fenced = false
        var block: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmed
            if line.hasPrefix("```") {
                block.append(line)
                fenced.toggle()
                if !fenced { output.append(block.joined(separator: "\n")); block = [] }
                continue
            }
            if fenced { block.append(raw); continue }
            if line.isEmpty || line.hasPrefix("<!--") || line.hasPrefix("![") || line.hasPrefix("#") { continue }
            let clean = line.replacingOccurrences(of: #"^(?:[-*•]\s+|[0-9]+[.、]\s*)"#,
                with: "", options: .regularExpression)
            var sentence = ""
            var code = false
            for character in clean {
                if character == "`" { code.toggle() }
                sentence.append(character)
                if !code && ("。！？".contains(character) || (splitClauses && "；;".contains(character))) {
                    if !sentence.trimmed.isEmpty { output.append(sentence.trimmed) }
                    sentence = ""
                }
            }
            if !sentence.trimmed.isEmpty { output.append(sentence.trimmed) }
        }
        if !block.isEmpty { output.append(block.joined(separator: "\n") + "\n```") }
        // A status clause can share a sentence with an unresolved technical constraint.
        // Keep both intact so only the historical delivery status can be omitted.
        output = output.flatMap { part -> [String] in
            guard starts(part, ["代码未", "改动未"]), let comma = part.firstIndex(of: "，") else { return [part] }
            return [String(part[...comma]), String(part[part.index(after: comma)...])]
        }
        var seen = Set<String>()
        return output.filter { seen.insert($0).inserted }
    }

    private static func append(_ parts: [String], to lines: inout [String], bullets: Bool = false) {
        // Separate complete sentences with whitespace; paragraphs stay readable without
        // changing technical statements or treating ellipses as a summary.
        for part in parts where !part.trimmed.isEmpty {
            lines += [(bullets && !part.hasPrefix("```") ? "- " : "") + part, ""]
        }
    }
}
