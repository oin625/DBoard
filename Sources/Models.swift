import Foundation
import Darwin

// MARK: - 数据模型

enum ViewMode: String { case priority, project }

enum ItemPriority: String, CaseIterable, Comparable, Codable {
    case p0 = "🔴"
    case p1 = "🟡"
    case p2 = "🟠"
    case p3 = "🟢"

    var title: String {
        switch self {
        case .p0: return "重要且紧急"
        case .p1: return "重要不紧急"
        case .p2: return "紧急不重要"
        case .p3: return "不紧急不重要"
        }
    }

    /// 分组圆点颜色（hex）：P0红警示、P1蓝主色、P2/P3灰度
    var dotColor: String {
        switch self {
        case .p0: return "#ff3b30"
        case .p1: return "#007aff"
        case .p2: return "#8e8e93"
        case .p3: return "#c7c7cc"
        }
    }

    /// CSS 类名 key
    var key: String {
        switch self {
        case .p0: return "p0"
        case .p1: return "p1"
        case .p2: return "p2"
        case .p3: return "p3"
        }
    }

    static func < (lhs: ItemPriority, rhs: ItemPriority) -> Bool {
        let order: [ItemPriority] = [.p0, .p1, .p2, .p3]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

enum ItemStatus: String, Codable {
    case pending = "#待开始"
    case inProgress = "#进行中"
    case completed = "#已完成"
    case suspended = "#挂起"

    var label: String {
        switch self {
        case .pending: return "待开始"
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        case .suspended: return "挂起"
        }
    }

    /// 状态文字颜色（hex，用于 HTML）
    var hexColor: String {
        switch self {
        case .pending: return "#aeaeb2"
        case .inProgress: return "#007aff"
        case .completed: return "#34c759"
        case .suspended: return "#ff9500"
        }
    }

    /// CSS 类名 key（用于 pill 配色）
    var key: String {
        switch self {
        case .pending: return "pending"
        case .inProgress: return "progress"
        case .completed: return "done"
        case .suspended: return "suspended"
        }
    }
}

struct DItem {
    let id: String              // D001, D002, ...
    let project: String         // 【项目名】
    let title: String           // 描述字段
    let headerTitle: String     // ### 标题行里的需求名（如"三渠统一"）
    var status: ItemStatus
    let priority: ItemPriority
    let deadline: String?       // "7.30"
    let branch: String?
    let startDate: String?      // "6.15"
    let milestones: [Milestone] // 进度里程碑
    var reqFlow: ReqFlowLink? = nil // 用户明确选择的正式需求
    var prompt: String = ""       // 为 AI 提前准备的输入上下文
    var changes: [DemandChange] = []
    var changeReadError: String? = nil
    var version: DemandVersion? = nil
    var versionReadError: String? = nil
    var chatLinks: DemandChatLinks? = nil
    var chatReadError: String? = nil
    var execution: DemandExecution? = nil
    var executionScope: String = ""
    var executionReadError: String? = nil
    var executionRepositories: [DemandVersion.Repository] = []
    var environmentRepositories: [DemandVersion.Repository] = []
    var technicalPlan: DemandTechnicalPlan? = nil
    var technicalPlanReadError: String? = nil
    var executionCodeReview: DemandCodeReview? = nil
    var debugPageNotNeeded = false
    var debugPageReadError: String? = nil
    var reminder: String = ""    // 用户自定义的单行进展提醒
    var releaseChecklist = DemandReleaseChecklist()
    var releaseChecklistReadError: String? = nil
    var handoff: DemandHandoff? = nil
    var handoffReadError: String? = nil
    var handoffNotes = ""
    var kind: DemandKind = .development
    var incidentClosure: IncidentClosure?
    var incidentExperienceReview: IncidentExperienceReview?
    var incidentReadError: String?

    /// 用于卡片主显示的标题：优先用需求名，其次用描述
    var displayTitle: String {
        if !headerTitle.isEmpty { return headerTitle }
        if !title.isEmpty && title != "（待补充）" { return title }
        return "（未命名）"
    }

    var daysRemaining: Int? {
        guard let deadline = deadline else { return nil }
        return DemandDates.daysRemaining(start: startDate, deadline: deadline)
    }

    var isUrgent: Bool {
        guard status == .pending || status == .inProgress else { return false }
        if priority == .p0 { return true }
        guard let days = daysRemaining else { return false }
        return days <= 3
    }

    var deadlineLabel: String? {
        guard let days = daysRemaining else { return nil }
        if days < 0 { return "逾期 \(-days) 天" }
        return days == 0 ? "今天截止" : "剩余 \(days) 天"
    }
}

struct Milestone {
    let date: String       // "6.15", "6.22"
    let content: String    // 一句话概括；旧记录保留原正文
    var details: String = "" // 仅保存在本地的明细
}

struct TodoItem {
    var text: String
    var isCompleted: Bool
    var linkedDItem: String?    // → D008 关联
    var note: String?           // 💬 备注
    var isCarriedOver: Bool = false
    var origin: TodoOrigin? = nil
    var completedAt: String? = nil
    var id: String { origin?.id ?? "fixture:\(text)" }

    /// 主文字（去掉备注后）
    var mainText: String {
        text
    }
}

/// 零碎日期区块，携带日期字符串和该日期下的 todo 列表
struct TodoSection {
    let dateLabel: String       // "2026-06-23"
    let items: [TodoItem]
    let isToday: Bool

    var allCompleted: Bool { !items.isEmpty && items.allSatisfy { $0.isCompleted } }
    var doneCount: Int { items.filter { $0.isCompleted }.count }
    var totalCount: Int { items.count }

    /// 短日期展示："6月23日"
    var shortDate: String {
        let parts = dateLabel.split(separator: "-")
        guard parts.count == 3,
              let m = Int(parts[1]),
              let d = Int(parts[2]) else { return dateLabel }
        return "\(m)月\(d)日"
    }
}

// MARK: - 缓存文件路径

enum CacheFile {
    static let path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/demand-center-cache.md"
    }()

    static let syncScript: String = {
        if let bundled = Bundle.main.path(forResource: "sync_dboard", ofType: "sh") { return bundled }
        return NSHomeDirectory() + "/work/code/other/DBoard/sync_dboard.sh"
    }()

    static func withLock<T>(at url: URL? = nil, _ body: () -> T) -> T? {
        let fd = open((url?.path ?? path) + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    static func read() -> String? {
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    @discardableResult
    static func write(_ content: String) -> Bool {
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }
}

// MARK: - 解析器

enum CacheParser {
    static func parse() -> (items: [DItem], todaySec: TodoSection?, prevSecs: [TodoSection], syncTime: String?) {
        guard let content = CacheFile.read() else { return ([], nil, [], nil) }
        return parse(content: content)
    }

    static func parse(content: String) -> (items: [DItem], todaySec: TodoSection?, prevSecs: [TodoSection], syncTime: String?) {
        var items: [DItem] = []
        var syncTime: String? = nil

        // 今天的日期字符串 "2026-06-24"
        let todayStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        var currentPriority: ItemPriority? = nil
        var currentDItem: (id: String, project: String, status: ItemStatus, deadline: String?, branch: String?, startDate: String?)? = nil
        var currentDescription: String? = nil
        var currentHeaderTitle: String = ""
        var currentMilestones: [Milestone] = []
        var currentReqFlow: ReqFlowLink? = nil
        var currentPromptLines: [String] = []
        var currentChangeLines: [String] = []
        var currentChangeFieldCount = 0
        var currentVersionLines: [String] = []
        var currentChatLines: [String] = []
        var inChatBlock = false
        var inChangeBlock = false
        var inPromptBlock = false
        var inProgressBlock = false
        var inProgressDetails = false
        var inDescriptionBlock = false
        var lastLineWasTodo = false
        var inTodoSection = false

        // 零碎：按日期分区收集
        var todoSections: [(date: String, items: [TodoItem])] = []
        var currentTodoDate: String = ""
        var currentTodos: [TodoItem] = []

        func flushItem() {
            guard let item = currentDItem, let prio = currentPriority else { return }
            let changeResult = Result {
                guard currentChangeFieldCount <= 1 && !(currentChangeFieldCount == 1 && currentChangeLines.joined(separator: "\n").isEmpty) else {
                    throw DemandChanges.ReadError.invalid
                }
                return try DemandChanges.decode(currentChangeLines.joined(separator: "\n"))
            }
            var changeError: String?
            if case .failure(let error) = changeResult { changeError = error.localizedDescription }
            let versionResult = Result { try DemandVersion.read(currentVersionLines) }
            var versionError: String?
            if case .failure(let error) = versionResult { versionError = error.localizedDescription }
            let chatResult = Result { try DemandChatLinksCodec.read(currentChatLines) }
            var chatError: String?
            if case .failure(let error) = chatResult { chatError = error.localizedDescription }
            items.append(DItem(
                id: item.id,
                project: item.project,
                title: (currentDescription ?? "").trimmingCharacters(in: .newlines),
                headerTitle: currentHeaderTitle,
                status: item.status,
                priority: prio,
                deadline: item.deadline,
                branch: item.branch,
                startDate: item.startDate,
                milestones: currentMilestones.map {
                    var record = $0
                    if record.details.hasSuffix("\n") { record.details.removeLast() }
                    return record
                },
                reqFlow: currentReqFlow,
                prompt: currentPromptLines.joined(separator: "\n"),
                changes: (try? changeResult.get()) ?? [],
                changeReadError: changeError,
                version: (try? versionResult.get()) ?? nil,
                versionReadError: versionError,
                chatLinks: (try? chatResult.get()) ?? nil,
                chatReadError: chatError
            ))
            currentDItem = nil
            currentDescription = nil
            currentHeaderTitle = ""
            currentMilestones = []
            currentReqFlow = nil
            currentPromptLines = []
            currentChangeLines = []
            currentChangeFieldCount = 0
            currentVersionLines = []
            currentChatLines = []
            inChatBlock = false
            inChangeBlock = false
            inPromptBlock = false
            inProgressBlock = false
            inDescriptionBlock = false
        }

        func flushTodoSection() {
            if !currentTodoDate.isEmpty && !currentTodos.isEmpty {
                todoSections.append((date: currentTodoDate, items: currentTodos))
            }
            currentTodos = []
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Consume local detail before recognizing headings or other cache fields.
            if inProgressBlock && line.hasPrefix("        "), !currentMilestones.isEmpty {
                let detail = String(line.dropFirst(8))
                if detail == "明细：" && !inProgressDetails {
                    inProgressDetails = true
                } else {
                    let index = currentMilestones.count - 1
                    currentMilestones[index].details += detail + "\n"
                }
                continue
            }
            if line.hasPrefix("- **") && !line.hasPrefix("- **进度**") { inProgressBlock = false }
            if inChangeBlock {
                if line.hasPrefix("    ") {
                    currentChangeLines.append(String(line.dropFirst(4)))
                    continue
                }
                inChangeBlock = false
            }
            if inChatBlock {
                if line.hasPrefix("    ") {
                    currentChatLines.append(line)
                    continue
                }
                inChatBlock = false
            }
            // 提示词的每一行缩进四格；先消费原文，内部 Markdown 不参与缓存结构解析。
            if inPromptBlock {
                if line.hasPrefix("    ") {
                    currentPromptLines.append(String(line.dropFirst(4)))
                    continue
                }
                inPromptBlock = false
            }
            if currentDItem != nil && line.hasPrefix(DemandVersion.prefix) {
                currentVersionLines.append(line)
                inDescriptionBlock = false
                inProgressBlock = false
                continue
            }
            if currentDItem != nil && (line.hasPrefix(DemandExecution.prefix) || line.hasPrefix(DemandDebugPagePolicy.prefix) || line.hasPrefix(DemandReleaseChecklist.prefix) || line.hasPrefix(DemandTechnicalPlan.prefix)) {
                inDescriptionBlock = false
                inProgressBlock = false
                continue
            }
            if inDescriptionBlock {
                if line.hasPrefix("- **") || line.hasPrefix("## ") || line.hasPrefix("### ") || trimmed == "---" {
                    inDescriptionBlock = false
                } else {
                    let continuation = line.hasPrefix("    ") ? String(line.dropFirst(4)) : line
                    currentDescription = (currentDescription ?? "") + "\n" + continuation
                    continue
                }
            }

            // 同步时间
            if trimmed.hasPrefix("<!-- synced:") {
                syncTime = trimmed
                    .replacingOccurrences(of: "<!-- synced:", with: "")
                    .replacingOccurrences(of: "-->", with: "")
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            // 优先级区块
            let prioMap: [(String, ItemPriority)] = [
                ("## 🔴", .p0), ("## 🟡", .p1), ("## 🟠", .p2), ("## 🟢", .p3)
            ]
            var hitPrio = false
            for (prefix, prio) in prioMap {
                if trimmed.hasPrefix(prefix) {
                    flushItem()
                    currentPriority = prio
                    inTodoSection = false
                    hitPrio = true
                    break
                }
            }
            if hitPrio { continue }

            // 零碎区块
            if trimmed.hasPrefix("## 📝") {
                flushItem()
                inTodoSection = true
                currentPriority = nil
                continue
            }

            if inTodoSection {
                // 引用备注只归属紧邻的 todo，与写入定位规则一致
                let previousWasTodo = lastLineWasTodo
                lastLineWasTodo = trimmed.hasPrefix("- [") || (previousWasTodo && trimmed.hasPrefix("> 💬"))
                // 日期块标题：### 2026-06-23
                if trimmed.hasPrefix("### ") {
                    flushTodoSection()
                    currentTodoDate = trimmed
                        .replacingOccurrences(of: "### ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
                if trimmed.hasPrefix("> 💬"), previousWasTodo, !currentTodos.isEmpty {
                    let note = String(trimmed.dropFirst("> 💬".count)).trimmed
                    let index = currentTodos.count - 1
                    currentTodos[index].note = [currentTodos[index].note, note].compactMap { $0 }.joined(separator: " ")
                    currentTodos[index].origin?.lines.append(line)
                    continue
                }
                if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                    currentTodos.append(TodoStore.parse(line, date: currentTodoDate, occurrence: currentTodos.count))
                    continue
                }
                continue
            }

            // D 条目标题行
            if currentPriority != nil, trimmed.hasPrefix("### D") || trimmed.hasPrefix("### P") {
                flushItem()
                guard let idRange = trimmed.range(of: #"^### [DP][0-9]{3,}(?=【|\s|$)"#, options: .regularExpression) else { continue }
                let id = String(trimmed[idRange].dropFirst(4))

                var project = ""
                if let s = trimmed.range(of: "【"), let e = trimmed.range(of: "】") {
                    project = String(trimmed[s.upperBound..<e.lowerBound])
                }

                var status: ItemStatus = .pending
                for s in [ItemStatus.inProgress, .completed, .suspended, .pending] {
                    if trimmed.contains(s.rawValue) { status = s; break }
                }

                var deadline: String? = nil
                if let r = trimmed.range(of: #"🎯(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})(?![0-9.-])"#, options: .regularExpression) {
                    deadline = String(trimmed[r]).replacingOccurrences(of: "🎯", with: "")
                }

                // 提取开始时间 📅6.15
                var startDate: String? = nil
                if let r = trimmed.range(of: #"📅(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})(?![0-9.-])"#, options: .regularExpression) {
                    startDate = String(trimmed[r]).replacingOccurrences(of: "📅", with: "")
                }

                currentDItem = (id: id, project: project, status: status, deadline: deadline, branch: nil, startDate: startDate)
                currentHeaderTitle = ""
                // 从标题行提取需求名：【项目】后面的文字，去掉状态/日期标记
                if let projEnd = trimmed.range(of: "】") {
                    var after = String(trimmed[projEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
                    for status in [ItemStatus.pending, .inProgress, .completed, .suspended] {
                        after = after.replacingOccurrences(of: status.rawValue, with: "")
                    }
                    after = after.replacingOccurrences(of: #"→?[📅🎯](?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})"#,
                        with: "", options: .regularExpression)
                    // 压缩多余空白
                    after = after.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                    currentHeaderTitle = after
                }
                continue
            }

            // D 条目字段
            if currentDItem != nil {
                if line.hasPrefix(DemandChatLinksCodec.field) {
                    currentChatLines.append(line)
                    inChatBlock = true
                    inProgressBlock = false
                    continue
                }
                if line.hasPrefix(DemandChanges.field) {
                    currentChangeFieldCount += 1
                    inChangeBlock = true
                    inProgressBlock = false
                    continue
                }
                if line.hasPrefix("- **提示词**") {
                    let inline = DemandPrompt.read([line])
                    currentPromptLines = inline.isEmpty ? [] : [inline]
                    inPromptBlock = true
                    inProgressBlock = false
                    continue
                }
                if trimmed.hasPrefix("- **需求流**") {
                    currentReqFlow = ReqFlowLink.parseField(trimmed)
                    inProgressBlock = false
                    continue
                }
                if trimmed.hasPrefix("- **分支**") {
                    let branch = trimmed
                        .replacingOccurrences(of: "^- \\*\\*分支\\*\\*\\s*[：:]?\\s*", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    currentDItem?.branch = branch
                    inProgressBlock = false
                }
                if trimmed.hasPrefix("- **描述**") {
                    currentDescription = trimmed
                        .replacingOccurrences(of: "^- \\*\\*描述\\*\\*\\s*[：:]?\\s*", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    inProgressBlock = false
                    inDescriptionBlock = true
                    continue
                }
                // 进度区块开始
                if trimmed.hasPrefix("- **进度**") {
                    inProgressBlock = true
                    continue
                }
                // 进度里程碑行：    - 6.15: xxx
                if inProgressBlock && trimmed.hasPrefix("- ") {
                    let body = String(trimmed.dropFirst(2))
                    if let colonIdx = body.firstIndex(of: ":") {
                        let dateStr = String(body[body.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        let desc = String(body[body.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                        // 简单验证是否像日期 "6.15" 或 "6.22"
                        if dateStr.range(of: "^\\d{1,2}\\.\\d{1,2}$", options: .regularExpression) != nil {
                            currentMilestones.append(Milestone(date: dateStr, content: desc))
                            inProgressDetails = false
                        }
                    }
                }
                // 遇到非 - 开头且不是空行，退出进度块
                if inProgressBlock && !trimmed.hasPrefix("-") && !trimmed.isEmpty {
                    inProgressBlock = false
                }
            }
        }

        flushItem()
        flushTodoSection()
        let sourceLines = content.components(separatedBy: "\n")
        for index in items.indices {
            guard let range = DItemStore.blockRange(sourceLines, id: items[index].id) else { continue }
            let block = Array(sourceLines[range])
            do {
                items[index].kind = try DemandIncident.kind(block)
                items[index].incidentClosure = try IncidentClosure.read(block)
                items[index].incidentExperienceReview = try IncidentExperienceReview.read(block)
            } catch { items[index].incidentReadError = error.localizedDescription }
            items[index].reminder = DemandReminder.read(block)
            items[index].handoffNotes = DemandHandoff.notes(block)
            do { items[index].handoff = try DemandHandoff.read(block) }
            catch { items[index].handoffReadError = error.localizedDescription }
            do { items[index].releaseChecklist = try DemandReleaseChecklist.read(block) }
            catch { items[index].releaseChecklistReadError = error.localizedDescription }
            do { items[index].technicalPlan = try DemandTechnicalPlan.read(block) }
            catch { items[index].technicalPlanReadError = error.localizedDescription }
            items[index].executionScope = DemandExecution.scopeHash(block)
            do {
                items[index].execution = try DemandExecution.read(block)
                items[index].executionRepositories = try DemandVersion.repositoryHints(block, item: items[index])
                items[index].environmentRepositories = try DemandVersion.environmentHints(block)
            }
            catch { items[index].executionReadError = error.localizedDescription }
            do { items[index].debugPageNotNeeded = try DemandDebugPagePolicy.read(block) }
            catch { items[index].debugPageReadError = error.localizedDescription }
        }

        // 构建 TodoSection：今天 + 所有历史日期块（按日期倒序，昨天在前）
        var todaySec: TodoSection? = nil
        var prevSecs: [TodoSection] = []

        var byDate: [String: [TodoItem]] = [:]
        for sec in todoSections { byDate[sec.date, default: []].append(contentsOf: sec.items) }
        for date in byDate.keys.sorted(by: >) {
            let section = TodoSection(dateLabel: date, items: byDate[date]!, isToday: date == todayStr)
            if section.isToday { todaySec = section }
            else { prevSecs.append(section) }
        }

        return (items, todaySec, prevSecs, syncTime)
    }
}

// MARK: - 文件写入操作

enum FileMutator {
    /// 切换需求状态（替换标题行里的 #状态 标记）
    static func setStatus(id: String, newStatusRaw: String, at url: URL? = nil) -> Bool {
        let states = [ItemStatus.pending, .inProgress, .completed, .suspended]
        guard id.range(of: #"^[DP][0-9]{3,}$"#, options: .regularExpression) != nil,
              states.contains(where: { $0.rawValue == newStatusRaw }) else { return false }
        let file = url ?? URL(fileURLWithPath: CacheFile.path)
        return CacheFile.withLock(at: file) {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { return false }
            var lines = content.components(separatedBy: "\n")
            let indices = lines.indices.filter { lines[$0].range(of: "^### " + id + "(?![0-9])", options: .regularExpression) != nil }
            guard indices.count == 1, let index = indices.first,
                  let state = states.first(where: { lines[index].contains($0.rawValue) }),
                  let marker = lines[index].range(of: state.rawValue, options: .backwards) else { return false }
            lines[index].replaceSubrange(marker, with: newStatusRaw)
            do { try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8); return true }
            catch { return false }
        } ?? false
    }

}

// MARK: - HTML 转义

func escapeHtml(_ s: String?) -> String {
    guard let s = s else { return "" }
    return s
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// 项目名 hash 取一个主题色（hex）
func projColor(_ name: String) -> String {
    let palette = ["#007aff", "#5856d6", "#ff9500", "#34c759", "#ff2d55", "#af52de", "#ff3b30", "#00c7be", "#a2845e"]
    var h = 0
    for c in name.unicodeScalars { h = (h &* 31 &+ Int(c.value)) & 0x7fffffff }
    return palette[abs(h) % palette.count]
}

