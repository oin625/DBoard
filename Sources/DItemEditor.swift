import SwiftUI
import Cocoa

// MARK: - 需求条目直接编辑（不经 AI）
// 规则对齐 ~/.claude/skills/d-board/SKILL.md：
//   完成统一保存到已完成记录，完整快照仍可在面板查看、恢复或开启新版本。

struct DItemDraft: Codable, Equatable {
    var id: String
    var name: String
    var project: String
    var desc: String
    var branch: String
    var status: ItemStatus
    var priority: ItemPriority
    var start: String
    var deadline: String
    var reqFlow: ReqFlowLink? = nil
    var prompt: String = ""
    var version: DemandVersion? = nil
    var chatLinks: DemandChatLinks? = nil
    var kind: DemandKind? = nil
    var effectiveKind: DemandKind { kind ?? .development }
    var isIncident: Bool { effectiveKind == .incident }
    var promptSections: DemandPromptSections {
        get { DemandPromptSections(stored: prompt) }
        set { prompt = newValue.stored }
    }

    init(from it: DItem) {
        id = it.id
        name = it.headerTitle
        project = DemandRepositoryEntries.parse(it.project).joined(separator: "\n")
        desc = (it.title == "（待补充）") ? "" : it.title
        branch = (it.branch == "待定") ? "" : (it.branch ?? "")
        status = it.status
        priority = it.priority
        start = it.startDate ?? ""
        deadline = it.deadline ?? ""
        reqFlow = it.reqFlow
        prompt = it.prompt
        version = it.version
        chatLinks = it.chatLinks
        kind = it.kind
    }

    init(newID: String, priority: ItemPriority) {
        id = newID; name = ""; project = ""; desc = ""; branch = ""
        status = .pending; self.priority = priority
        start = DemandDates.today(); deadline = ""
    }

    var projectFieldValue: String { DemandRepositoryEntries.parse(project).joined(separator: "；") }

    var hasUserInput: Bool {
        [name, project, desc, branch, deadline, prompt].contains { !$0.trimmed.isEmpty }
            || isIncident || reqFlow != nil || version != nil || chatLinks?.isEmpty == false || priority != .p1 || status != .pending
            || start != DemandDates.today()
    }

    var headerLine: String {
        var h = "### \(id)【\(projectFieldValue)】\(name.trimmed) \(status.rawValue)"
        let s = start.trimmed, d = deadline.trimmed
        if !s.isEmpty && !d.isEmpty { h += " 📅\(s)→🎯\(d)" }
        else if !s.isEmpty { h += " 📅\(s)" }
        else if !d.isEmpty { h += " 🎯\(d)" }
        return h
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension ItemPriority {
    var sectionPrefix: String {
        switch self {
        case .p0: return "## 🔴"
        case .p1: return "## 🟡"
        case .p2: return "## 🟠"
        case .p3: return "## 🟢"
        }
    }
}

enum DItemStore {
    static func today() -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: Date())
        return "\(c.month!).\(c.day!)"
    }

    private static func isBoundary(_ t: String) -> Bool {
        t.hasPrefix("### ") || t.hasPrefix("## ") || t == "---"
    }

    /// 条目块 [start, end)，end 不含尾部空行
    static func blockRange(_ lines: [String], id: String) -> Range<Int>? {
        let pattern = "^### " + id + "(?![0-9])"
        guard let s = lines.firstIndex(where: { $0.range(of: pattern, options: .regularExpression) != nil }) else { return nil }
        var e = s + 1
        while e < lines.count && !isBoundary(lines[e]) { e += 1 }
        while e > s + 1 && lines[e - 1].trimmed.isEmpty && !lines[e - 1].hasPrefix("    ") { e -= 1 }
        return s..<e
    }

    /// 切出条目块（连同其后一个空行）
    private static func cut(_ lines: inout [String], _ r: Range<Int>) -> [String] {
        let block = Array(lines[r])
        var upper = r.upperBound
        if upper < lines.count && lines[upper].trimmed.isEmpty { upper += 1 }
        lines.removeSubrange(r.lowerBound..<upper)
        return block
    }

    /// 插到对应优先级区块末尾
    private static func insert(_ lines: inout [String], block: [String], priority: ItemPriority) {
        guard let t = lines.firstIndex(where: { $0.hasPrefix(priority.sectionPrefix) }) else {
            lines.append(""); lines.append(contentsOf: block); return
        }
        var k = t + 1
        while k < lines.count && !(lines[k].hasPrefix("## ") || lines[k] == "---") { k += 1 }
        var r = k - 1
        while r > t && lines[r].trimmed.isEmpty && !lines[r].hasPrefix("    ") { r -= 1 }
        var chunk = [""] + block
        let after = r + 1
        if after >= lines.count || !lines[after].trimmed.isEmpty { chunk.append("") }
        lines.insert(contentsOf: chunk, at: after)
    }

    /// 设置顶层字段 `- **key**：value`（空值删除该行）
    private static func setField(_ block: inout [String], key: String, value: String) {
        let tag = "- **\(key)**"
        let v = value.trimmed
        let fields = v.components(separatedBy: "\n")
        let replacement = v.isEmpty ? [] : ["\(tag)：\(fields[0])"] + fields.dropFirst().map { "    " + $0 }
        if let i = block.firstIndex(where: { $0.hasPrefix(tag) }) {
            var end = i + 1
            if key == "描述" {
                while end < block.count && !block[end].hasPrefix("- **") && !isBoundary(block[end]) { end += 1 }
            }
            block.replaceSubrange(i..<end, with: replacement)
            return
        }
        guard !v.isEmpty else { return }
        let order = ["项目", "分支", "需求流", "描述"]
        // 放在排序上排它前面的字段之后，否则紧跟标题
        var pos = 1
        for k in order.prefix(while: { $0 != key }) {
            if let i = block.firstIndex(where: { $0.hasPrefix("- **\(k)**") }) { pos = i + 1 }
        }
        block.insert(contentsOf: replacement, at: min(pos, block.count))
    }

    static func mutate(at url: URL? = nil, _ body: (inout [String]) -> Bool) -> Bool {
        CacheFile.withLock(at: url) {
            let content: String?
            if let url { content = try? String(contentsOf: url, encoding: .utf8) }
            else { content = CacheFile.read() }
            guard let content else { return false }
            var lines = content.components(separatedBy: "\n")
            guard body(&lines) else { return false }
            let updated = lines.joined(separator: "\n")
            if let url {
                do { try updated.write(to: url, atomically: true, encoding: .utf8); return true }
                catch { return false }
            }
            return CacheFile.write(updated)
        } ?? false
    }

    static func setDebugPageNotNeeded(id: String, value: Bool, expected: Bool, at url: URL? = nil) -> Bool {
        mutate(at: url) { lines in
            let matches = CacheParser.parse(content: lines.joined(separator: "\n")).items.filter { $0.id == id }
            guard matches.count == 1, matches[0].status != .completed,
                  let range = blockRange(lines, id: id) else { return false }
            var block = Array(lines[range])
            do {
                let current = try DemandDebugPagePolicy.read(block)
                guard current == expected || current == value else { return false }
                try DemandDebugPagePolicy.set(&block, notNeeded: value)
                lines.replaceSubrange(range, with: block)
                return true
            } catch { return false }
        }
    }

    static func appendChange(id: String, intent: String, at url: URL? = nil) -> DemandChange? {
        guard !intent.trimmed.isEmpty else { return nil }
        var added: DemandChange?
        let saved = mutate(at: url) { lines in
            guard CacheParser.parse(content: lines.joined(separator: "\n")).items.filter({ $0.id == id }).count == 1,
                  let range = blockRange(lines, id: id) else { return false }
            var block = Array(lines[range])
            do {
                var changes = try DemandChanges.read(block)
                let previous = changes.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
                guard previous < Int.max else { return false }
                let number = previous + 1
                let change = DemandChange(id: String(format: "C%03ld", number), createdAt: Date(), intent: intent)
                changes.append(change)
                try DemandChanges.set(&block, changes: changes)
                lines.replaceSubrange(range, with: block)
                added = change
                return true
            } catch { return false }
        }
        return saved ? added : nil
    }

    static func save(_ draft: DItemDraft, original: DItem, at url: URL? = nil) -> Bool {
        var d = draft
        guard d.validationError == nil else { return false }
        d.status = d.scheduledStatus
        return mutate(at: url) { lines in
            if let link = d.reqFlow {
                guard link.isValid,
                      ReqFlowLinkQueries.linkedItem(for: link,
                        in: CacheParser.parse(content: lines.joined(separator: "\n")).items,
                        excludingID: d.id) == nil else { return false }
            }
            guard let r = blockRange(lines, id: d.id) else { return false }
            var block = Array(lines[r])
            let o = DItemDraft(from: original)
            guard original.incidentReadError == nil else { return false }
            if d.effectiveKind != o.effectiveKind {
                guard (try? DemandIncident.kind(block)) == o.effectiveKind else { return false }
                setField(&block, key: "类型", value: d.isIncident ? DemandKind.incident.rawValue : "")
            }
            if d.headerLine != o.headerLine { block[0] = d.headerLine }
            if d.projectFieldValue != o.projectFieldValue { setField(&block, key: "项目", value: d.projectFieldValue) }
            if d.branch != o.branch { setField(&block, key: "分支", value: d.branch) }
            if d.desc != o.desc {
                setField(&block, key: "描述", value: d.desc)
                setField(&block, key: "概括", value: "")
            }
            if d.reqFlow != o.reqFlow { setField(&block, key: "需求流", value: d.reqFlow?.markdown ?? "") }
            if d.chatLinks != o.chatLinks {
                do {
                    guard try DemandChatLinksCodec.read(block) == o.chatLinks else { return false }
                    try DemandChatLinksCodec.set(&block, links: d.chatLinks)
                } catch { return false }
            }
            if d.prompt != o.prompt {
                guard DemandPrompt.read(block) == o.prompt else { return false }
                DemandPrompt.set(&block, value: d.prompt)
            }
            if d.priority != original.priority {
                _ = cut(&lines, r)
                insert(&lines, block: block, priority: d.priority)
            } else {
                lines.replaceSubrange(r, with: block)
            }
            return true
        }
    }

    /// Checklist mutations lock the latest cache and preserve concurrent updates to other fields.
    static func updateReleaseChecklist(id: String, at url: URL? = nil,
                                      _ update: (inout DemandReleaseChecklist) -> Bool) -> Bool {
        mutate(at: url) { lines in
            let matches = CacheParser.parse(content: lines.joined(separator: "\n")).items.filter { $0.id == id }
            guard matches.count == 1, matches[0].status != .completed, let range = blockRange(lines, id: id) else { return false }
            var block = Array(lines[range])
            do {
                var checklist = try DemandReleaseChecklist.read(block)
                guard update(&checklist) else { return false }
                try DemandReleaseChecklist.set(&block, checklist: checklist)
                lines.replaceSubrange(range, with: block)
                return true
            } catch { return false }
        }
    }

    /// User corrections do not overwrite AI snapshots or change the development scope.
    static func saveHandoffNotes(id: String, text: String, expected: String, at url: URL? = nil) -> Bool {
        let value = text.trimmed
        return mutate(at: url) { lines in
            guard CacheParser.parse(content: lines.joined(separator: "\n")).items.filter({ $0.id == id }).count == 1,
                  let range = blockRange(lines, id: id) else { return false }
            var block = Array(lines[range])
            guard block.filter({ $0.hasPrefix(DemandHandoff.notesField) }).count <= 1 else { return false }
            let current = DemandHandoff.notes(block)
            guard current == expected || current == value else { return false }
            let replacement = value.isEmpty ? [] : [DemandHandoff.notesField + "：" + value.components(separatedBy: "\n")[0]]
                + value.components(separatedBy: "\n").dropFirst().map { "    " + $0 }
            if let index = block.firstIndex(where: { $0.hasPrefix(DemandHandoff.notesField) }) {
                var end = index + 1
                while end < block.count && block[end].hasPrefix("    ") { end += 1 }
                block.replaceSubrange(index..<end, with: replacement)
            } else {
                block.insert(contentsOf: replacement, at: 1)
            }
            lines.replaceSubrange(range, with: block)
            return true
        }
    }

    /// Only the personal reminder is edited; concurrent AI updates to other fields survive.
    static func saveReminder(id: String, text: String, expected: String, at url: URL? = nil) -> Bool {
        let value = DemandReminder.singleLine(text).trimmed
        return mutate(at: url) { lines in
            let matches = CacheParser.parse(content: lines.joined(separator: "\n")).items.filter { $0.id == id }
            guard matches.count == 1, let range = blockRange(lines, id: id) else { return false }
            var block = Array(lines[range])
            guard block.filter({ $0.hasPrefix(DemandReminder.field) }).count <= 1 else { return false }
            let current = DemandReminder.read(block)
            guard current == expected || current == value else { return false }
            if let index = block.firstIndex(where: { $0.hasPrefix(DemandReminder.field) }) {
                if value.isEmpty { block.remove(at: index) }
                else { block[index] = DemandReminder.field + "：" + value }
            } else if !value.isEmpty {
                block.insert(DemandReminder.field + "：" + value, at: 1)
            }
            lines.replaceSubrange(range, with: block)
            return true
        }
    }

    /// 只修改咒言，保留编辑期间其他字段的更新；同一咒言被修改时拒绝覆盖。
    static func savePrompt(id: String, text: String, expected: String, at url: URL? = nil) -> Bool {
        mutate(at: url) { lines in
            guard let r = blockRange(lines, id: id) else { return false }
            var block = Array(lines[r])
            guard DemandPrompt.read(block) == expected else { return false }
            DemandPrompt.set(&block, value: text)
            lines.replaceSubrange(r, with: block)
            return true
        }
    }

    static func setPriority(id: String, _ p: ItemPriority, at url: URL? = nil, expectedPriority: ItemPriority? = nil) -> Bool {
        mutate(at: url) { lines in
            guard let r = blockRange(lines, id: id) else { return false }
            if let expectedPriority {
                guard expectedPriority != p,
                      let current = CacheParser.parse(content: lines.joined(separator: "\n")).items.first(where: { $0.id == id }),
                      current.priority == expectedPriority, current.status != .completed else { return false }
            }
            let block = cut(&lines, r)
            insert(&lines, block: block, priority: p)
            return true
        }
    }

    static func appendProgress(id: String, text: String, details: String = "", at url: URL? = nil) -> Bool {
        guard let entry = DemandProgress.entry(date: today(), summary: text, details: details) else { return false }
        return mutate(at: url) { lines in
            guard let r = blockRange(lines, id: id) else { return false }
            var block = Array(lines[r])
            if let p = block.firstIndex(where: { $0.hasPrefix("- **进度**") }) {
                var e = p + 1
                while e < block.count && (block[e].hasPrefix(" ") || block[e].hasPrefix("\t") || block[e].trimmed.isEmpty) { e += 1 }
                block.insert(contentsOf: entry, at: e)
            } else {
                block.append("- **进度**：")
                block.append(contentsOf: entry)
            }
            lines.replaceSubrange(r, with: block)
            return true
        }
    }

    static func create(_ draft: DItemDraft, at url: URL? = nil) -> Bool {
        var d = draft
        d.status = d.scheduledStatus
        guard d.validationError == nil else { return false }
        var block = [d.headerLine]
        if d.isIncident { block.append("- **类型**：线上排查") }
        if !d.projectFieldValue.isEmpty { block.append("- **项目**：\(d.projectFieldValue)") }
        if !d.branch.trimmed.isEmpty { block.append("- **分支**：\(d.branch.trimmed)") }
        if let link = d.reqFlow {
            guard link.isValid else { return false }
            block.append("- **需求流**：\(link.markdown)")
        }
        setField(&block, key: "描述", value: d.desc.trimmed.isEmpty ? "（待补充）" : d.desc.trimmed)
        DemandPrompt.set(&block, value: d.prompt)
        do { try DemandChatLinksCodec.set(&block, links: d.chatLinks) }
        catch { return false }
        if let version = d.version {
            guard version.parentID != d.id, version.rootID != d.id, let stored = try? version.stored else { return false }
            block.append(stored)
        }
        let ok = mutate(at: url) { lines in
            guard blockRange(lines, id: d.id) == nil else { return false }
            if let version = d.version {
                let current = CacheParser.parse(content: lines.joined(separator: "\n")).items
                guard !current.contains(where: { $0.id == version.parentID || $0.version?.sourceRevision == version.sourceRevision }) else { return false }
            }
            if let link = d.reqFlow {
                guard ReqFlowLinkQueries.linkedItem(for: link,
                    in: CacheParser.parse(content: lines.joined(separator: "\n")).items) == nil else { return false }
            }
            insert(&lines, block: block, priority: d.priority)
            return true
        }
        if ok, url == nil, let n = DemandNumbering.number(d.id) {
            let key = d.id.hasPrefix("P") ? DemandKind.incident.counterKey : DemandKind.development.counterKey
            UserDefaults.standard.set(max(n, UserDefaults.standard.integer(forKey: key)), forKey: key)
        }
        return ok
    }

    @discardableResult
    static func delete(id: String, expected: [String]? = nil, at url: URL? = nil) -> [String]? {
        var removed: [String]? = nil
        let ok = mutate(at: url) { lines in
            guard let r = blockRange(lines, id: id), expected == nil || Array(lines[r]) == expected else { return false }
            removed = cut(&lines, r)
            return true
        }
        return ok ? removed : nil
    }

    static func restore(_ block: [String], id: String, priority: ItemPriority, at url: URL? = nil) -> Bool {
        mutate(at: url) { lines in
            guard blockRange(lines, id: id) == nil else { return false }
            insert(&lines, block: block, priority: priority)
            return true
        }
    }

    /// Reopen a saved archive snapshot; unrelated records and the archive remain untouched.
    static func reopenArchive(_ record: ArchivedDemand, at url: URL? = nil) -> Bool {
        let archived = record.item
        guard archived.changeReadError == nil, archived.versionReadError == nil,
              (try? DemandVersion.repositoryHints(record.block, item: archived)) != nil else { return false }
        var block = record.original ?? record.block
        let source = CacheParser.parse(content: record.priority.sectionPrefix + "\n" + block.joined(separator: "\n")).items
        guard source.count == 1, source[0].id == archived.id,
              source[0].changeReadError == nil, source[0].versionReadError == nil else { return false }
        var draft = DItemDraft(from: archived)
        draft.status = .inProgress
        draft.start = DemandDates.today()
        draft.deadline = ""
        block[0] = draft.headerLine
        // Keep the completion notes as historical facts, outside the current execution progress.
        let notes = block.filter { $0.hasPrefix("- 📝") }
        block.removeAll { $0.hasPrefix("- 📝") }
        if !notes.isEmpty {
            let history = notes.map { "    " + $0 }
            if let index = block.firstIndex(where: { $0.hasPrefix("- **归档历史**") }) {
                var end = index + 1
                while end < block.count && block[end].hasPrefix("    ") { end += 1 }
                block.insert(contentsOf: history, at: end)
            } else { block.append(contentsOf: ["- **归档历史**："] + history) }
        }
        let entry = "    - " + today() + ": 撤销归档，恢复继续处理；历史完成情况以原记录为准。"
        if let index = block.firstIndex(where: { $0.hasPrefix("- **进度**") }) {
            var end = index + 1
            while end < block.count && block[end].hasPrefix("    ") { end += 1 }
            block.insert(entry, at: end)
        } else { block.append(contentsOf: ["- **进度**：", entry]) }
        return mutate(at: url) { lines in
            guard blockRange(lines, id: archived.id) == nil else { return false }
            let active = CacheParser.parse(content: lines.joined(separator: "\n")).items
            if let link = archived.reqFlow,
               ReqFlowLinkQueries.linkedItem(for: link, in: active) != nil { return false }
            insert(&lines, block: block, priority: record.priority)
            return true
        }
    }

    static func blockText(id: String) -> [String]? {
        guard let c = CacheFile.read() else { return nil }
        let lines = c.components(separatedBy: "\n")
        guard let r = blockRange(lines, id: id) else { return nil }
        return Array(lines[r])
    }

    /// Reserve real demand identities, including archives, pending archive writes and explicit links.
    static func nextID(reserving ids: [String] = [], kind: DemandKind = .development, at cacheURL: URL? = nil,
                       archiveURL: URL? = nil, journalURL: URL? = nil,
                       defaults: UserDefaults = .standard) -> String {
        let archive = archiveURL ?? URL(fileURLWithPath: NSHomeDirectory() + "/.claude/dboard-archive-cache.md")
        let current = cacheURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? (cacheURL == nil ? CacheFile.read() : nil)
        let archived = try? String(contentsOf: archive, encoding: .utf8)
        let journal = ArchiveJournal(url: journalURL ?? URL(fileURLWithPath: NSHomeDirectory() + "/.claude/dboard-archive-journal.json"))
        return DemandNumbering.nextID(contents: [current, archived].compactMap { $0 },
            reserving: ids + Array(journal.entries.keys),
            lastAssigned: defaults.integer(forKey: kind.counterKey), kind: kind)
    }

    // MARK: 归档到钉钉「已完成」文档
    static var archiveNodeID: String? {
        if let v = ProcessInfo.processInfo.environment["DBOARD_ARCHIVE_NODE_ID"], !v.isEmpty { return v }
        let zshrc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        guard let s = try? String(contentsOf: zshrc, encoding: .utf8) else { return nil }
        for line in s.components(separatedBy: "\n").reversed() where line.hasPrefix("export DBOARD_ARCHIVE_NODE_ID=") {
            let v = line.replacingOccurrences(of: "export DBOARD_ARCHIVE_NODE_ID=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !v.isEmpty { return v }
        }
        return nil
    }

    /// 返回 nil 表示成功，否则为错误信息
    static func pushToArchive(_ block: [String]) -> String? {
        guard let node = archiveNodeID else { return "未配置 DBOARD_ARCHIVE_NODE_ID（~/.zshrc）" }
        let tmp = NSTemporaryDirectory() + "dboard-archive-\(UUID().uuidString).md"
        do { try ("\n" + (try DemandProgress.remoteLines(block)).joined(separator: "\n") + "\n").write(toFile: tmp, atomically: true, encoding: .utf8) }
        catch { return "无法写入归档快照，本地记录未移除" }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.qoderwork/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        let result = ProcessRunner.run("/usr/bin/env", arguments: ["dws", "doc", "update", "--node", node,
            "--content-file", tmp, "--mode", "append", "--format", "json"], environment: env, timeout: 90)
        return result.businessSucceeded ? nil : "远端未确认成功，本地记录保留；请核对归档文档后恢复操作"
    }
}

// MARK: - ViewModel 操作
extension DBoardViewModel {
    @discardableResult
    func afterWrite(_ ok: Bool, fail: String, success: String = "已保存") -> Bool {
        guard ok else { flash(fail); return false }
        markSelfWrite()
        reload()
        scheduleSync()
        showFeedback(success)
        return true
    }

    func flash(_ msg: String) {
        showFeedback(msg, failed: true)
    }

    @discardableResult
    func saveItem(_ d: DItemDraft, original: DItem) -> Bool {
        if let link = d.reqFlow,
           let existing = ReqFlowLinkQueries.linkedItem(for: link, in: items, excludingID: d.id) {
            flash("该需求已关联 \(existing.id)，请打开已有 D单")
            return false
        }
        let completing = d.scheduledStatus == .completed && original.status != .completed
        var draft = d
        if completing { draft.status = original.status }
        markSelfWrite()
        guard afterWrite(DItemStore.save(draft, original: original), fail: "保存失败，请检查本地数据文件或刷新后重试") else { return false }
        if completing { completeAfterEditing(d.id) }
        return true
    }

    @discardableResult
    func savePrompt(_ item: DItem, text: String, expected: String? = nil) -> Bool {
        markSelfWrite()
        return afterWrite(DItemStore.savePrompt(id: item.id, text: text, expected: expected ?? item.prompt),
            fail: "咒言保存失败，需求可能已变更；输入已保留，请复制备份后重新打开",
            success: "咒言已保存")
    }

    @discardableResult
    func copyCurrentState(_ id: String, at url: URL? = nil, pasteboard: NSPasteboard = .general) -> Bool {
        do {
            let latest = try DItemStore.currentItem(id: id, at: url)
            let snapshot = DboardAITaskContext.readInstruction(item: latest, cacheURL: url)
            pasteboard.clearContents()
            guard pasteboard.setString(snapshot, forType: .string) else {
                flash("复制现状失败，请重试")
                return false
            }
            showFeedback("现状读取指令已复制，发给 AI 即可")
            return true
        } catch {
            flash("复制现状失败：" + error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func setDebugPageNotNeeded(_ id: String, value: Bool, at url: URL? = nil) -> Bool {
        do {
            let latest = try DItemStore.currentItem(id: id, at: url)
            guard DItemStore.setDebugPageNotNeeded(id: id, value: value,
                expected: latest.debugPageNotNeeded, at: url) else {
                flash("调试页设置保存失败，请刷新后重试")
                return false
            }
            if url == nil { reload() }
            showFeedback(value ? "已标记无需调试页，可随时撤销" : "已撤销，恢复调试页入口")
            return true
        } catch {
            flash("调试页设置保存失败：" + error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func copyReviewTask(_ id: String, at url: URL? = nil, pasteboard: NSPasteboard = .general) -> Bool {
        do {
            let latest = try DItemStore.currentItem(id: id, at: url)
            let instruction = DboardAITaskContext.reviewInstruction(item: latest, cacheURL: url)
            pasteboard.clearContents()
            guard pasteboard.setString(instruction, forType: .string) else {
                flash("代码审查指令复制失败，请重试")
                return false
            }
            showFeedback("代码审查指令已复制，发给新的 AI 即可")
            return true
        } catch {
            flash("代码审查指令复制失败：" + error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func copyDebugTask(_ id: String, at url: URL? = nil, pasteboard: NSPasteboard = .general) -> Bool {
        do {
            let latest = try DItemStore.currentItem(id: id, at: url)
            guard latest.status != .completed else {
                flash("需求已完成，请先恢复继续处理或开启新版本")
                return false
            }
            guard !latest.debugPageNotNeeded else {
                flash("已标记无需调试页，请先撤销该设置")
                return false
            }
            let instruction = DboardAITaskContext.debugInstruction(item: latest, cacheURL: url)
            pasteboard.clearContents()
            guard pasteboard.setString(instruction, forType: .string) else {
                flash("调试咒言复制失败，请重试")
                return false
            }
            showFeedback("调试咒言已复制，发给 AI 核验开发并接续调试页")
            return true
        } catch {
            flash("调试咒言复制失败：" + error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func copyChangeState(_ id: String, changeID: String, at url: URL? = nil,
                         pasteboard: NSPasteboard = .general) -> Bool {
        do {
            let latest = try DItemStore.currentItem(id: id, at: url)
            guard let change = latest.changes.first(where: { $0.id == changeID }) else {
                flash("这条变更已不存在，请重新打开")
                return false
            }
            let snapshot = DboardAITaskContext.readInstruction(item: latest, changeID: change.id, cacheURL: url)
            pasteboard.clearContents()
            guard pasteboard.setString(snapshot, forType: .string) else { flash("复制变更失败，请重试"); return false }
            showFeedback("变更 " + changeID + " 的现状读取指令已复制")
            return true
        } catch { flash("复制变更失败：" + error.localizedDescription); return false }
    }

    @discardableResult
    func appendChange(_ id: String, intent: String) -> DemandChange? {
        guard !intent.trimmed.isEmpty else { return nil }
        markSelfWrite()
        guard let change = DItemStore.appendChange(id: id, intent: intent) else {
            flash("添加变更失败，输入已保留，请刷新后重试")
            return nil
        }
        afterWrite(true, fail: "添加变更失败", success: "变更 " + change.id + " 已添加")
        return change
    }

    func setPriority(_ id: String, _ p: ItemPriority) {
        markSelfWrite()
        afterWrite(DItemStore.setPriority(id: id, p), fail: "调整优先级失败")
    }

    @discardableResult
    func appendProgress(_ id: String, _ text: String, details: String = "") -> Bool {
        guard !text.trimmed.isEmpty else { return false }
        guard DemandProgress.entry(date: DItemStore.today(), summary: text, details: details) != nil else {
            flash("概括请用一句话，最多 120 字；更多内容请放明细")
            return false
        }
        markSelfWrite()
        return afterWrite(DItemStore.appendProgress(id: id, text: text, details: details),
                          fail: "追加进度失败", success: "进度已保存")
    }

    @discardableResult
    func createItem(_ d: DItemDraft) -> Bool {
        guard !d.name.trimmed.isEmpty else { return false }
        if let link = d.reqFlow,
           let existing = ReqFlowLinkQueries.linkedItem(for: link, in: items) {
            flash("该需求已关联 \(existing.id)，请打开已有 D单")
            return false
        }
        let completing = d.scheduledStatus == .completed
        var draft = d
        if completing { draft.status = .pending }
        markSelfWrite()
        guard afterWrite(DItemStore.create(draft), fail: "新建失败，请检查是否已关联或刷新本地数据后重试", success: "需求已创建") else { return false }
        focusItem(d.id)
        if completing { completeAfterEditing(d.id) }
        return true
    }

    private func completeAfterEditing(_ id: String) {
        // Let the editor close before showing the single completion confirmation.
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.items.first(where: { $0.id == id }) else { return }
            self.completeItem(item)
        }
    }

    func deleteItem(_ item: DItem) {
        let a = NSAlert()
        a.messageText = "删除 \(item.id)「\(item.displayTitle)」？"
        a.informativeText = "直接从 D板 删掉，不进归档。要保留记录请用「完成」。"
        a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        markSelfWrite()
        guard let block = DItemStore.delete(id: item.id) else { flash("删除失败，本地记录保留"); return }
        afterWrite(true, fail: "删除失败", success: "需求已删除，可撤销")
        offerUndo("恢复 \(item.id)") { DItemStore.restore(block, id: item.id, priority: item.priority) }
    }

    /// 完成：先保存完整历史，确认成功后才移出当前需求，避免丢数据。
    func completeItem(_ item: DItem) {
        guard !archivingIDs.contains(item.id), saveReminder(item.id), saveReleaseDrafts(item.id) else { return }
        if let completionRequest { completionRequest(item); return }
        guard let original = DItemStore.blockText(id: item.id),
              let fresh = CacheParser.parse(content: item.priority.sectionPrefix + "\n" + original.joined(separator: "\n")).items.first,
              fresh.id == item.id else { flash("需求无法读取，请刷新后重试"); return }
        if let issue = DemandCompletionGate.localIssue(fresh) { flash(issue); return }
        if fresh.isIncident { finishIncident(fresh, original: original); return }
        if original.contains(where: { $0.hasPrefix("- **需求流**") }), fresh.reqFlow == nil {
            flash("正式需求关联无法读取，请重新关联后再完成"); return
        }
        if let link = fresh.reqFlow {
            archivingIDs.insert(fresh.id)
            showFeedback("正在核对 \(link.no) 的正式验收状态…")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try DemandCompletionGate.verifyAcceptance(link) }
                DispatchQueue.main.async {
                    self.archivingIDs.remove(fresh.id)
                    do {
                        try result.get()
                        guard DItemStore.blockText(id: fresh.id) == original else {
                            self.flash("核验期间需求已变化，请重新确认后完成"); return
                        }
                        self.completeValidatedItem(fresh, original: original)
                    } catch { self.flash(error.localizedDescription) }
                }
            }
        } else {
            completeValidatedItem(fresh, original: original)
        }
    }

    private func completeValidatedItem(_ item: DItem, original: [String]) {
        guard archiveJournal.readable else { flash("归档恢复记录无法读取，已停止操作；请先核对本地记录"); return }
        var existing = archiveJournal.entries[item.id].flatMap { $0.state == .removed ? nil : $0 }
        if let entry = existing, entry.original != original {
            flash("本地需求已变化，旧归档快照仍保留；请核对归档文档，不能直接移除新改动")
            return
        }
        let a = NSAlert()
        a.messageText = "完成 \(item.id)「\(item.displayTitle)」？"
        if existing?.state == .submitted {
            a.informativeText = "上次远端结果未确认。请先核对钉钉归档，避免重复追加；本地记录尚未移除。"
            a.addButton(withTitle: "已写入，仅完成本地移除")
            a.addButton(withTitle: "取消")
            a.addButton(withTitle: "确认未写入，重新完成")
            NSApp.activate(ignoringOtherApps: true)
            let response = a.runModal()
            if response == .alertFirstButtonReturn { existing?.state = .uploaded }
            else if response != .alertThirdButtonReturn { return }
        } else {
            a.informativeText = existing?.state == .uploaded
                ? "归档已确认写入，本次只重试本地移除，不会再次追加。"
                : (item.reqFlow == nil ? "请确认联调与验收已结束。\n" : "已核实关联正式需求验收完成。\n") + "完成后可在「已完成」中查看完整记录，也可恢复继续处理或开启新版本。"
            a.addButton(withTitle: existing?.state == .uploaded ? "完成本地移除" : "完成")
            a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if DemandCompletionGate.needsEmptyChecklistConfirmation(item) {
            let confirmation = NSAlert()
            confirmation.messageText = "没有上线前事项，仍然完成 \(item.id)？"
            confirmation.informativeText = "请确认本需求确实无需发布服务、执行 SQL 或其他上线动作，且联调与验收已经结束。"
            confirmation.addButton(withTitle: "确认无需上线事项并完成")
            confirmation.addButton(withTitle: "取消")
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        }
        guard DItemStore.blockText(id: item.id) == original else {
            flash("确认期间需求已变化，请刷新后重新完成"); return
        }
        if let entry = existing, entry.state == .uploaded { finishArchive(entry); return }
        guard DItemStore.archiveNodeID != nil else { flash("请先配置 DBOARD_ARCHIVE_NODE_ID，未执行归档"); return }
        var block = original
        for status in [ItemStatus.pending, .inProgress, .suspended] {
            block[0] = block[0].replacingOccurrences(of: status.rawValue, with: ItemStatus.completed.rawValue)
        }
        block[0] += " ✅" + DemandDates.today()
        block.append("- 📝 \(DemandDates.today()) 完成 ✅")
        let entry = ArchiveJournal.Entry(id: item.id, original: original, archived: block, state: .submitted, createdAt: Date())
        guard archiveJournal.save(entry) else { flash("无法保存归档恢复快照，未执行远端操作"); return }
        archivingIDs.insert(item.id)
        showFeedback("正在完成 \(item.id)，请勿重复操作")
        DispatchQueue.global(qos: .userInitiated).async {
            let error = DItemStore.pushToArchive(entry.archived)
            DispatchQueue.main.async {
                self.archivingIDs.remove(item.id)
                if let error { self.flash(error); return }
                self.finishArchive(entry)
            }
        }
    }

    private func finishArchive(_ original: ArchiveJournal.Entry) {
        var entry = original; entry.state = .uploaded
        guard archiveJournal.save(entry) else { flash("远端已写入，但恢复凭证保存失败；本地需求保留，请先核对"); return }
        guard DItemStore.delete(id: entry.id, expected: entry.original) != nil else {
            flash("归档已写入；本地移除失败或内容已变化。重试只处理本地，不重复追加")
            return
        }
        entry.state = .removed
        _ = archiveJournal.save(entry)
        demandArchives.reloadLocal()
        markSelfWrite(); reload(); scheduleSync()
        if let record = demandArchives.records.first(where: { $0.item.id == entry.id }) { focusArchive(record) }
        else { showDemands(.completed) }
        showFeedback("已完成，完整记录可在「已完成」中查看")
    }
}

// MARK: - 编辑表单（编辑 / 新建共用）
struct DItemEditForm: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @State var draft: DItemDraft
    var isNew: Bool = false
    var showChats: Bool = false
    let onSave: (DItemDraft) -> Void
    let onCancel: () -> Void
    @FocusState private var nameFocused: Bool
    @State private var choosingReqFlow = false
    @State private var detailsExpanded = false
    @State private var chatsExpanded = false
    @State private var spellExpanded = false
    var onDraftChange: ((DItemDraft) -> Void)? = nil
    var showsActions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isNew && showsActions {
                HStack {
                    Text("新建 \(draft.id)").dboardFont(size: 17, weight: .semibold)
                    Spacer()
                    Text("自动保存草稿").dboardFont(size: 11).foregroundStyle(.secondary)
                }
            }
            kindSelector

            primaryFields
            priorityFields
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup(isExpanded: $detailsExpanded) {
                    engineeringFields.padding(.top, 12)
                } label: {
                    sectionLabel("工程与安排", symbol: "slider.horizontal.3",
                                 detail: draft.project.trimmed.isEmpty ? "可选" : "\(DemandRepositoryEntries.parse(draft.project).count) 个工程")
                }.demandKeyboardID("demand-engineering-section").padding(14)
                if !draft.isIncident || draft.reqFlow != nil {
                    Divider().padding(.horizontal, 14)
                    requirementLink.padding(14)
                }
                Divider().padding(.horizontal, 14)
                DisclosureGroup(isExpanded: $chatsExpanded) {
                    DemandChatLinksFields(links: Binding(get: { draft.chatLinks ?? DemandChatLinks() },
                        set: { draft.chatLinks = $0.optional })).padding(.top, 12)
                    if let error = vm.items.first(where: { $0.id == draft.id })?.chatReadError {
                        Text(error).dboardFont(size: 11).foregroundStyle(.orange)
                    }
                } label: {
                    sectionLabel("关联群聊", symbol: "bubble.left.and.bubble.right",
                                 detail: draft.chatLinks?.isEmpty == false ? "已关联" : "可选")
                }.demandKeyboardID("demand-chats-section").padding(14)
                Divider().padding(.horizontal, 14)
                DisclosureGroup(isExpanded: $spellExpanded) {
                    DemandPromptFields(sections: $draft.promptSections, compact: true).padding(.top, 12)
                } label: {
                    sectionLabel("咒言", symbol: "wand.and.stars", detail: draft.prompt.isEmpty ? "可选" : "已填写")
                }.demandKeyboardID("demand-spell-section").padding(14)
            }.workspaceSurface()

            if let error = draft.validationError, !draft.name.trimmed.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .dboardFont(size: 11).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsActions {
                HStack(spacing: 8) {
                    Spacer()
                    Button(isNew ? "关闭" : "取消", action: cancelEditing).keyboardShortcut(.cancelAction)
                        .demandButtonStyle(WorkspaceActionStyle())
                    Button(isNew ? "创建" : "保存") { onSave(draft) }
                        .demandButtonStyle(WorkspaceActionStyle(prominent: true))
                        .keyboardShortcut(.defaultAction).disabled(draft.validationError != nil)
                }
            }
        }
        .dboardFont(size: 13).controlSize(.regular)
        .sheet(isPresented: $choosingReqFlow) {
            ReqFlowRequirementPicker(flow: vm.reqFlow, localItems: vm.items, editingID: draft.id,
                select: { requirement in
                    let previous = vm.reqFlow.prdItems.first { $0.id == draft.reqFlow?.id }
                    draft.associate(with: requirement, previous: previous)
                    choosingReqFlow = false
                    nameFocused = true
                }, openExisting: { id in
                    choosingReqFlow = false
                    onCancel()
                    if vm.newDemandWindowPresenter != nil, let item = vm.items.first(where: { $0.id == id }) {
                        vm.openDemandEditor(.inspect, item: item)
                    } else { vm.focusItem(id) }
                }, cancel: { choosingReqFlow = false })
        }
        .onExitCommand {
            if choosingReqFlow { choosingReqFlow = false }
            else { cancelEditing() }
        }
        .onAppear {
            vm.editingFormCount += 1
            detailsExpanded = !isNew || !draft.project.trimmed.isEmpty || !draft.branch.trimmed.isEmpty
                || !draft.deadline.trimmed.isEmpty
            chatsExpanded = showChats || draft.chatLinks?.isEmpty == false
            spellExpanded = !draft.prompt.isEmpty
            if isNew && !vm.newItemFormInWindow { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameFocused = true } }
        }
        .onChange(of: draft) { _, value in onDraftChange?(value) }
        .onDisappear {
            onDraftChange?(draft)
            vm.editingFormCount = max(0, vm.editingFormCount - 1)
        }
    }

    private var kindSelector: some View {
        HStack(spacing: 3) {
            ForEach(DemandKind.allCases, id: \.self) { kind in
                Button {
                    let changed = draft.effectiveKind != kind
                    draft.kind = kind
                    if isNew && changed {
                        draft.id = DItemStore.nextID(kind: kind)
                        if kind == .incident { draft.priority = .p0; draft.status = .inProgress }
                    }
                } label: {
                    Text(kind.rawValue).dboardFont(size: 12, weight: draft.effectiveKind == kind ? .semibold : .medium)
                        .foregroundStyle(draft.effectiveKind == kind ? Color.primary : .secondary)
                        .frame(width: 112, height: 30)
                        .background {
                            if draft.effectiveKind == kind {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                            }
                        }.contentShape(Rectangle())
                }.demandButtonStyle(.plain)
                    .demandKeyboardID(kind == .incident ? "demand-kind-incident" : "demand-kind-development")
                    .demandKeyboardSelected(draft.effectiveKind == kind)
                    .accessibilityAddTraits(draft.effectiveKind == kind ? .isSelected : [])
            }
        }
        .padding(3).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("任务类型").accessibilityIdentifier("demand-kind-picker")
    }

    private var primaryFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel(draft.isIncident ? "问题名称" : "需求名称")
                box(TextField(draft.isIncident ? "这次出现了什么问题" : "用一句话说明要做什么", text: $draft.name)
                    .focused($nameFocused).accessibilityLabel("名称"))
            }
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel(draft.isIncident ? "问题现象" : "描述")
                if draft.isIncident {
                    DemandSpellField(text: $draft.desc, title: "问题现象",
                        placeholder: "粘贴报错、日志或截图，补上已知的接口、单号或发生时间。",
                        height: 140, showPasteButton: true)
                } else {
                    box(TextField("简单说明背景和预期结果，也可以稍后补充", text: $draft.desc, axis: .vertical)
                        .lineLimit(2...7).accessibilityLabel("描述"))
                }
            }
        }.padding(14).workspaceSurface()
    }

    private var priorityFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("放在哪个象限")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(DemandMatrix.rows.flatMap { $0 }, id: \.self) { priority in
                    Button { draft.priority = priority } label: {
                        HStack(spacing: 7) {
                            Circle().fill(priority.color).frame(width: 6, height: 6)
                            Text(priority.title).dboardFont(size: 12, weight: .medium)
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark").dboardFont(size: 10, weight: .semibold)
                                .opacity(draft.priority == priority ? 1 : 0)
                        }
                        .padding(.horizontal, 10).frame(height: 34)
                        .foregroundStyle(draft.priority == priority ? priority.color : .secondary)
                        .background(priority.color.opacity(draft.priority == priority ? 0.075 : 0.025),
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
                            draft.priority == priority ? priority.color.opacity(0.4) : Color.primary.opacity(0.055),
                            lineWidth: draft.priority == priority ? 1 : 0.5))
                    }
                    .demandButtonStyle(.plain).accessibilityLabel(priority.title)
                    .demandKeyboardID("demand-priority-" + priority.rawValue)
                    .accessibilityAddTraits(draft.priority == priority ? .isSelected : [])
                }
            }
        }.padding(14).workspaceSurface()
    }

    private var engineeringFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("仓库 / 项目")
                PromptContextInput(text: $draft.project, title: "仓库 / 项目")
                    .overlay(alignment: .topLeading) {
                        if draft.project.isEmpty {
                            Text("每行一个仓库名或路径，支持多个")
                                .dboardFont(size: 12).foregroundStyle(.tertiary)
                                .padding(.horizontal, 8).padding(.vertical, 6).allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 36).clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("开发分支")
                box(TextField("可选", text: $draft.branch).accessibilityLabel("开发分支"))
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("开始日期")
                    box(TextField("YYYY-MM-DD", text: $draft.start).accessibilityLabel("开始日期"))
                }
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("截止日期")
                    box(TextField("可选 · YYYY-MM-DD", text: $draft.deadline).accessibilityLabel("截止日期"))
                }
            }
            HStack {
                fieldLabel("个人状态")
                Spacer()
                Picker("个人状态", selection: Binding(
                    get: { draft.scheduledStatus }, set: { draft.status = $0 })) {
                    ForEach([ItemStatus.pending, .inProgress, .suspended, .completed], id: \.rawValue) {
                        Text($0.label).tag($0)
                    }
                }.labelsHidden().frame(width: 140)
                    .demandKeyboardMenu().demandKeyboardID("demand-status-picker")
            }
            Text("开始日期到达后自动进入进行中。").dboardFont(size: 11).foregroundStyle(.secondary)
        }
    }

    private var requirementLink: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let link = draft.reqFlow {
                ReqFlowLinkedRequirementView(link: link, flow: vm.reqFlow) {
                    BizMapBoardWindowController.shared.showRequirement(link: link)
                }
                HStack(spacing: 12) {
                    Button("更换关联") { choosingReqFlow = true }
                    Button("解除关联") { draft.reqFlow = nil }
                }.dboardFont(size: 11).demandButtonStyle(.plain).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    sectionLabel("需求流", symbol: "link", detail: "可选")
                    Spacer()
                    Button("关联需求") { choosingReqFlow = true }.demandButtonStyle(WorkspaceActionStyle())
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ title: String, symbol: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).dboardFont(size: 12).foregroundStyle(.secondary).frame(width: 16)
            Text(title).dboardFont(size: 13, weight: .medium).foregroundStyle(.primary)
            Text(detail).dboardFont(size: 11).foregroundStyle(.secondary)
        }
    }

    private func cancelEditing() {
        onDraftChange?(draft)
        onCancel()
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value).dboardFont(size: 11, weight: .medium).foregroundStyle(.secondary)
    }

    private func box<V: View>(_ view: V) -> some View {
        view.textFieldStyle(.plain).dboardFont(size: 13)
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

// MARK: - 新建需求入口
struct NewItemRow: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    var embedded = false
    private var hasDraft: Bool { vm.newItemDraft?.hasUserInput == true }

    var body: some View {
        HStack(spacing: 8) {
            Button { vm.beginNewItemDraft() } label: {
                Label(hasDraft ? "继续草稿" : "新增需求 / 线上排查",
                      systemImage: hasDraft ? "doc.text" : "plus")
                    .lineLimit(1).fixedSize()
            }
            .demandButtonStyle(WorkspaceActionStyle(prominent: true))
            .accessibilityLabel(hasDraft ? "继续需求草稿" : "新增需求 / 线上排查")
            .accessibilityIdentifier("demand-new-editor").demandKeyboardID("demand-new-editor")
            if hasDraft {
                if !embedded, let name = vm.newItemDraft?.name, !name.trimmed.isEmpty {
                    Text(name).dboardFont(size: 12).foregroundStyle(.secondary).lineLimit(1)
                }
                Button(action: confirmClearDraft) { Image(systemName: "xmark").dboardFont(size: 10) }
                    .demandButtonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清空草稿")
            }
            if !embedded { Spacer(minLength: 0) }
        }
        .padding(.horizontal, embedded ? 0 : 20).padding(.vertical, embedded ? 0 : 8)
    }

    private func confirmClearDraft() {
        let alert = NSAlert()
        alert.messageText = "清空需求草稿？"
        alert.informativeText = "只清除这份未创建的草稿，已经保存的需求不受影响。"
        alert.addButton(withTitle: "清空草稿")
        alert.addButton(withTitle: "保留")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { vm.clearNewItemDraft() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn { vm.clearNewItemDraft() }
    }
}
