import SwiftUI
import Cocoa

// MARK: - 需求条目直接编辑（不经 AI）
// 规则对齐 ~/.claude/skills/d-board/SKILL.md：
//   改本地缓存 → sync_dboard.sh 覆盖进行中文档；完成 = 追加到归档文档 + 从缓存移除

struct DItemDraft {
    var id: String
    var name: String
    var project: String
    var desc: String
    var branch: String
    var status: ItemStatus
    var priority: ItemPriority
    var start: String
    var deadline: String

    init(from it: DItem) {
        id = it.id
        name = it.headerTitle
        project = it.project
        desc = (it.title == "（待补充）") ? "" : it.title
        branch = (it.branch == "待定") ? "" : (it.branch ?? "")
        status = it.status
        priority = it.priority
        start = it.startDate ?? ""
        deadline = it.deadline ?? ""
    }

    init(newID: String, priority: ItemPriority) {
        id = newID; name = ""; project = ""; desc = ""; branch = ""
        status = .pending; self.priority = priority
        start = DItemStore.today(); deadline = ""
    }

    var headerLine: String {
        var h = "### \(id)【\(project.trimmed)】\(name.trimmed) \(status.rawValue)"
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
        guard let s = lines.firstIndex(where: { $0.trimmed.range(of: pattern, options: .regularExpression) != nil }) else { return nil }
        var e = s + 1
        while e < lines.count && !isBoundary(lines[e].trimmed) { e += 1 }
        while e > s + 1 && lines[e - 1].trimmed.isEmpty { e -= 1 }
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
        guard let t = lines.firstIndex(where: { $0.trimmed.hasPrefix(priority.sectionPrefix) }) else {
            lines.append(""); lines.append(contentsOf: block); return
        }
        var k = t + 1
        while k < lines.count && !(lines[k].trimmed.hasPrefix("## ") || lines[k].trimmed == "---") { k += 1 }
        var r = k - 1
        while r > t && lines[r].trimmed.isEmpty { r -= 1 }
        var chunk = [""] + block
        let after = r + 1
        if after >= lines.count || !lines[after].trimmed.isEmpty { chunk.append("") }
        lines.insert(contentsOf: chunk, at: after)
    }

    /// 设置顶层字段 `- **key**：value`（空值删除该行）
    private static func setField(_ block: inout [String], key: String, value: String) {
        let tag = "- **\(key)**"
        let v = value.trimmed
        if let i = block.firstIndex(where: { $0.hasPrefix(tag) }) {
            if v.isEmpty { block.remove(at: i) } else { block[i] = "\(tag)：\(v)" }
            return
        }
        guard !v.isEmpty else { return }
        let order = ["项目", "分支", "描述"]
        // 放在排序上排它前面的字段之后，否则紧跟标题
        var pos = 1
        for k in order.prefix(while: { $0 != key }) {
            if let i = block.firstIndex(where: { $0.hasPrefix("- **\(k)**") }) { pos = i + 1 }
        }
        block.insert("\(tag)：\(v)", at: min(pos, block.count))
    }

    private static func mutate(_ body: (inout [String]) -> Bool) -> Bool {
        guard let content = CacheFile.read() else { return false }
        var lines = content.components(separatedBy: "\n")
        guard body(&lines) else { return false }
        CacheFile.write(lines.joined(separator: "\n"))
        return true
    }

    static func save(_ d: DItemDraft, original: DItem) -> Bool {
        mutate { lines in
            guard let r = blockRange(lines, id: d.id) else { return false }
            var block = Array(lines[r])
            let o = DItemDraft(from: original)
            if d.headerLine != o.headerLine { block[0] = d.headerLine }
            if d.project != o.project { setField(&block, key: "项目", value: d.project) }
            if d.branch != o.branch { setField(&block, key: "分支", value: d.branch) }
            if d.desc != o.desc { setField(&block, key: "描述", value: d.desc) }
            if d.priority != original.priority {
                _ = cut(&lines, r)
                insert(&lines, block: block, priority: d.priority)
            } else {
                lines.replaceSubrange(r, with: block)
            }
            return true
        }
    }

    static func setPriority(id: String, _ p: ItemPriority) -> Bool {
        mutate { lines in
            guard let r = blockRange(lines, id: id) else { return false }
            let block = cut(&lines, r)
            insert(&lines, block: block, priority: p)
            return true
        }
    }

    static func appendProgress(id: String, text: String) -> Bool {
        mutate { lines in
            guard let r = blockRange(lines, id: id) else { return false }
            var block = Array(lines[r])
            let entry = "    - \(today()): \(text.trimmed)"
            if let p = block.firstIndex(where: { $0.hasPrefix("- **进度**") }) {
                var e = p + 1
                while e < block.count && (block[e].hasPrefix(" ") || block[e].hasPrefix("\t")) && !block[e].trimmed.isEmpty { e += 1 }
                block.insert(entry, at: e)
            } else {
                block.append("- **进度**：")
                block.append(entry)
            }
            lines.replaceSubrange(r, with: block)
            return true
        }
    }

    static func create(_ d: DItemDraft) -> Bool {
        var block = [d.headerLine]
        if !d.project.trimmed.isEmpty { block.append("- **项目**：\(d.project.trimmed)") }
        if !d.branch.trimmed.isEmpty { block.append("- **分支**：\(d.branch.trimmed)") }
        block.append("- **描述**：\(d.desc.trimmed.isEmpty ? "（待补充）" : d.desc.trimmed)")
        let ok = mutate { lines in insert(&lines, block: block, priority: d.priority); return true }
        if ok, let n = Int(d.id.dropFirst()) { UserDefaults.standard.set(n, forKey: "dboard.lastDID") }
        return ok
    }

    @discardableResult
    static func delete(id: String) -> [String]? {
        var removed: [String]? = nil
        _ = mutate { lines in
            guard let r = blockRange(lines, id: id) else { return false }
            removed = cut(&lines, r)
            return true
        }
        return removed
    }

    static func blockText(id: String) -> [String]? {
        guard let c = CacheFile.read() else { return nil }
        let lines = c.components(separatedBy: "\n")
        guard let r = blockRange(lines, id: id) else { return nil }
        return Array(lines[r])
    }

    /// 下一个编号：缓存里出现过的最大 D 号（含零碎里的 → Dxxx）与历史水位取大
    static func nextID() -> String {
        var mx = UserDefaults.standard.integer(forKey: "dboard.lastDID")
        if let c = CacheFile.read() {
            let re = try! NSRegularExpression(pattern: "D(\\d{3})(?![0-9])")
            for m in re.matches(in: c, range: NSRange(c.startIndex..., in: c)) {
                if let r = Range(m.range(at: 1), in: c), let n = Int(c[r]) { mx = max(mx, n) }
            }
        }
        return String(format: "D%03d", mx + 1)
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
        try? ("\n" + block.joined(separator: "\n") + "\n").write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "export PATH=\"\(home)/.qoderwork/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; dws doc update --node \"$1\" --content-file \"$2\" --mode append", "_", node, tmp]
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return s.contains("\"success\"") ? nil : String(s.prefix(200))
    }
}

// MARK: - ViewModel 操作
extension DBoardViewModel {
    private func afterWrite(_ ok: Bool, fail: String) {
        if !ok { flash(fail); return }
        markSelfWrite()
        reload()
        scheduleSync()
    }

    func flash(_ msg: String) {
        syncText = msg; syncKind = .fail
    }

    func saveItem(_ d: DItemDraft, original: DItem) {
        markSelfWrite()
        afterWrite(DItemStore.save(d, original: original), fail: "⚠ 保存失败：没找到 \(d.id)")
    }

    func setPriority(_ id: String, _ p: ItemPriority) {
        markSelfWrite()
        afterWrite(DItemStore.setPriority(id: id, p), fail: "⚠ 调整优先级失败")
    }

    func appendProgress(_ id: String, _ text: String) {
        guard !text.trimmed.isEmpty else { return }
        markSelfWrite()
        afterWrite(DItemStore.appendProgress(id: id, text: text), fail: "⚠ 追加进度失败")
    }

    func createItem(_ d: DItemDraft) {
        guard !d.name.trimmed.isEmpty else { return }
        markSelfWrite()
        afterWrite(DItemStore.create(d), fail: "⚠ 新建失败")
        expandedIDs.insert(d.id)
    }

    func deleteItem(_ item: DItem) {
        let a = NSAlert()
        a.messageText = "删除 \(item.id)「\(item.displayTitle)」？"
        a.informativeText = "直接从 D板 删掉，不进归档。要留档请用「完成并归档」。"
        a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        markSelfWrite()
        afterWrite(DItemStore.delete(id: item.id) != nil, fail: "⚠ 删除失败")
    }

    /// 完成并归档：先追加到归档文档，成功后才从缓存移除，避免丢数据
    func archiveItem(_ item: DItem) {
        guard var block = DItemStore.blockText(id: item.id) else { flash("⚠ 没找到 \(item.id)"); return }
        let a = NSAlert()
        a.messageText = "完成并归档 \(item.id)「\(item.displayTitle)」？"
        a.informativeText = "追加到钉钉「已完成」文档，并从 D板 移除。"
        a.addButton(withTitle: "归档"); a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var head = block[0]
        for s in [ItemStatus.pending, .inProgress, .suspended] { head = head.replacingOccurrences(of: s.rawValue, with: ItemStatus.completed.rawValue) }
        block[0] = head + " ✅" + f.string(from: Date())
        block.append("- 📝 \(DItemStore.today()) 完成 ✅")
        syncText = "正在归档 \(item.id)…"; syncKind = .syncing
        DispatchQueue.global(qos: .userInitiated).async {
            let err = DItemStore.pushToArchive(block)
            DispatchQueue.main.async {
                if let err = err {
                    self.flash("⚠ 归档失败：\(err)")
                    return
                }
                self.markSelfWrite()
                DItemStore.delete(id: item.id)
                self.reload()
                self.doSyncNow()
            }
        }
    }
}

// MARK: - 编辑表单（编辑 / 新建共用）
struct DItemEditForm: View {
    @EnvironmentObject var theme: ThemeManager
    @State var draft: DItemDraft
    var isNew: Bool = false
    let onSave: (DItemDraft) -> Void
    let onCancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isNew {
                Text("新建 \(draft.id)").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.current.textSecondary)
            }
            field("名称", $draft.name, "需求名").focused($nameFocused)
            field("项目", $draft.project, "仓库 / 项目")
            HStack(spacing: 8) {
                label("优先级")
                Picker("", selection: $draft.priority) {
                    ForEach(ItemPriority.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
                Picker("", selection: $draft.status) {
                    ForEach([ItemStatus.pending, .inProgress, .suspended, .completed], id: \.rawValue) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize()
                Spacer()
            }
            HStack(spacing: 8) {
                label("周期")
                box(TextField("开始 如 10.22", text: $draft.start))
                Text("→").font(.system(size: 12)).foregroundStyle(theme.current.textMuted)
                box(TextField("截止 如 11.15", text: $draft.deadline))
            }
            field("分支", $draft.branch, "可选")
            HStack(alignment: .top, spacing: 8) {
                label("描述")
                box(TextField("做什么、为什么", text: $draft.desc, axis: .vertical).lineLimit(1...5))
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "创建" : "保存") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmed.isEmpty)
            }
            .controlSize(.small)
        }
        .font(.system(size: 13))
        .onAppear { if isNew { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameFocused = true } } }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(theme.current.textMuted).frame(width: 36, alignment: .leading)
    }

    private func box<V: View>(_ v: V) -> some View {
        v.textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.current.textPrimary.opacity(0.06)))
    }

    private func field(_ l: String, _ b: Binding<String>, _ ph: String) -> some View {
        HStack(spacing: 8) { label(l); box(TextField(ph, text: b)) }
    }
}

// MARK: - 新建需求入口
struct NewItemRow: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @State private var draft: DItemDraft? = nil

    var body: some View {
        Group {
            if let d = draft {
                DItemEditForm(draft: d, isNew: true, onSave: { nd in
                    vm.createItem(nd)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { draft = nil }
                }, onCancel: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { draft = nil }
                })
                .padding(.horizontal, 14).padding(.vertical, 12)
                .cardStyle(theme.current)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        draft = DItemDraft(newID: DItemStore.nextID(), priority: .p1)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("新建需求").font(.system(size: 12))
                        Spacer()
                    }
                    .foregroundStyle(theme.current.textTertiary)
                    .padding(.horizontal, 20).padding(.top, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
