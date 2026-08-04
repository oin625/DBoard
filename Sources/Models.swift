import Foundation

// MARK: - 数据模型

enum ViewMode: String { case priority, project }

enum ItemPriority: String, CaseIterable, Comparable {
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

enum ItemStatus: String {
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

    /// 用于卡片主显示的标题：优先用需求名，其次用描述
    var displayTitle: String {
        if !headerTitle.isEmpty { return headerTitle }
        if !title.isEmpty && title != "（待补充）" { return title }
        return "（未命名）"
    }

    var daysRemaining: Int? {
        guard let deadline = deadline else { return nil }
        return Self.parseDaysRemaining(from: deadline)
    }

    var isUrgent: Bool {
        guard let days = daysRemaining else { return false }
        return days <= 3
    }

    private static func parseDaysRemaining(from dateStr: String) -> Int? {
        let parts = dateStr.split(separator: ".")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]) else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let targetDate = calendar.date(from: components) else { return nil }
        let days = calendar.dateComponents([.day], from: now, to: targetDate).day ?? 0
        return max(0, days)
    }
}

struct Milestone {
    let date: String       // "6.15", "6.22"
    let content: String    // 描述文字
}

struct TodoItem {
    var text: String
    var isCompleted: Bool
    var linkedDItem: String?    // → D008 关联
    var note: String?           // 💬 备注
    var isCarriedOver: Bool = false  // 顺延项（只读，不可在今日直接勾选）

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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin/sync_dboard.sh"
    }()

    static func read() -> String? {
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    static func write(_ content: String) {
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
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
        var inProgressBlock = false
        var inTodoSection = false

        // 零碎：按日期分区收集
        var todoSections: [(date: String, items: [TodoItem])] = []
        var currentTodoDate: String = ""
        var currentTodos: [TodoItem] = []

        func flushItem() {
            guard let item = currentDItem, let prio = currentPriority else { return }
            items.append(DItem(
                id: item.id,
                project: item.project,
                title: currentDescription ?? "",
                headerTitle: currentHeaderTitle,
                status: item.status,
                priority: prio,
                deadline: item.deadline,
                branch: item.branch,
                startDate: item.startDate,
                milestones: currentMilestones
            ))
            currentDItem = nil
            currentDescription = nil
            currentHeaderTitle = ""
            currentMilestones = []
            inProgressBlock = false
        }

        func flushTodoSection() {
            if !currentTodoDate.isEmpty && !currentTodos.isEmpty {
                todoSections.append((date: currentTodoDate, items: currentTodos))
            }
            currentTodos = []
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

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
                // 日期块标题：### 2026-06-23
                if trimmed.hasPrefix("### ") {
                    flushTodoSection()
                    currentTodoDate = trimmed
                        .replacingOccurrences(of: "### ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
                // 引用行备注：> 💬 xxx  → 附加到上一个 todo
                if trimmed.hasPrefix("> 💬") {
                    let note = trimmed
                        .replacingOccurrences(of: "> 💬", with: "")
                        .replacingOccurrences(of: ">", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !note.isEmpty, !currentTodos.isEmpty {
                        currentTodos[currentTodos.count - 1].note = note
                    }
                    continue
                }
                // todo 行
                if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                    let isCompleted = trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")
                    var text = trimmed
                        .replacingOccurrences(of: "- [ ]", with: "")
                        .replacingOccurrences(of: "- [x]", with: "")
                        .replacingOccurrences(of: "- [X]", with: "")
                        .trimmingCharacters(in: .whitespaces)

                    // 提取关联 D 编号
                    var linked: String? = nil
                    if let range = text.range(of: "→\\s*(D\\d{3})", options: .regularExpression) {
                        let match = String(text[range])
                        if let dRange = match.range(of: "D\\d{3}", options: .regularExpression) {
                            linked = String(match[dRange])
                        }
                    }
                    // 清理关联标记
                    text = text.replacingOccurrences(of: "→\\s*D\\d{3}", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "`", with: "")
                        .trimmingCharacters(in: .whitespaces)

                    // 分离备注 💬
                    var note: String? = nil
                    if let noteRange = text.range(of: "💬") {
                        note = String(text[noteRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                        if note?.isEmpty == true { note = nil }
                        text = String(text[..<noteRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    }

                    currentTodos.append(TodoItem(text: text, isCompleted: isCompleted, linkedDItem: linked, note: note))
                    continue
                }
                continue
            }

            // D 条目标题行
            if currentPriority != nil, trimmed.hasPrefix("### D") {
                flushItem()
                guard let idRange = trimmed.range(of: "D\\d{3}", options: .regularExpression) else { continue }
                let id = String(trimmed[idRange])

                var project = ""
                if let s = trimmed.range(of: "【"), let e = trimmed.range(of: "】") {
                    project = String(trimmed[s.upperBound..<e.lowerBound])
                }

                var status: ItemStatus = .pending
                for s in [ItemStatus.inProgress, .completed, .suspended, .pending] {
                    if trimmed.contains(s.rawValue) { status = s; break }
                }

                var deadline: String? = nil
                if let r = trimmed.range(of: "🎯(\\d+\\.\\d+)", options: .regularExpression) {
                    deadline = String(trimmed[r]).replacingOccurrences(of: "🎯", with: "")
                }

                // 提取开始时间 📅6.15
                var startDate: String? = nil
                if let r = trimmed.range(of: "📅(\\d+\\.\\d+)", options: .regularExpression) {
                    startDate = String(trimmed[r]).replacingOccurrences(of: "📅", with: "")
                }

                currentDItem = (id: id, project: project, status: status, deadline: deadline, branch: nil, startDate: startDate)
                currentHeaderTitle = ""
                // 从标题行提取需求名：【项目】后面的文字，去掉状态/日期标记
                if let projEnd = trimmed.range(of: "】") {
                    var after = String(trimmed[projEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
                    // 去掉 #状态、📅、🎯 及其日期
                    after = after.replacingOccurrences(of: "#[\\u4e00-\\u9fa5]+", with: "", options: .regularExpression)
                    after = after.replacingOccurrences(of: "📅[^🎯]*", with: "", options: .regularExpression)
                    after = after.replacingOccurrences(of: "→?🎯", with: "", options: .regularExpression)
                    after = after.replacingOccurrences(of: "\\d+\\.\\d+", with: "", options: .regularExpression)
                    // 压缩多余空白
                    after = after.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                    currentHeaderTitle = after
                }
                continue
            }

            // D 条目字段
            if currentDItem != nil {
                if trimmed.hasPrefix("- **分支**") {
                    let branch = trimmed
                        .replacingOccurrences(of: "- **分支**", with: "")
                        .replacingOccurrences(of: "：", with: "")
                        .replacingOccurrences(of: ":", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    currentDItem?.branch = branch
                    inProgressBlock = false
                }
                if trimmed.hasPrefix("- **描述**") {
                    currentDescription = trimmed
                        .replacingOccurrences(of: "- **描述**", with: "")
                        .replacingOccurrences(of: "：", with: "")
                        .replacingOccurrences(of: ":", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    inProgressBlock = false
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

        // 构建 TodoSection：今天 + 所有历史日期块（按日期倒序，昨天在前）
        var todaySec: TodoSection? = nil
        var prevSecs: [TodoSection] = []

        for sec in todoSections.reversed() {
            if sec.date == todayStr {
                todaySec = TodoSection(dateLabel: sec.date, items: sec.items, isToday: true)
            } else {
                prevSecs.append(TodoSection(dateLabel: sec.date, items: sec.items, isToday: false))
            }
        }

        return (items, todaySec, prevSecs, syncTime)
    }
}

// MARK: - 文件写入操作

enum FileMutator {
    /// 切换需求状态（替换标题行里的 #状态 标记）
    static func setStatus(id: String, newStatusRaw: String) -> Bool {
        guard var content = CacheFile.read() else { return false }
        var lines = content.components(separatedBy: "\n")
        let pattern = "### " + id + "(?![0-9])"
        for i in 0..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.range(of: pattern, options: .regularExpression) != nil {
                for s in [ItemStatus.pending, .inProgress, .completed, .suspended] {
                    if lines[i].contains(s.rawValue) {
                        lines[i] = lines[i].replacingOccurrences(of: s.rawValue, with: newStatusRaw)
                        break
                    }
                }
                content = lines.joined(separator: "\n")
                CacheFile.write(content)
                return true
            }
        }
        return false
    }

    /// 按文本内容匹配切换 todo 状态（用于顺延项，不限定日期块）
    static func toggleTodoByText(_ searchText: String) -> Bool {
        guard var content = CacheFile.read() else { return false }
        var lines = content.components(separatedBy: "\n")

        var inTodo = false
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## 📝") { inTodo = true; continue }
            if !inTodo { continue }
            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                // 匹配文本内容（去掉 checkbox 前缀后比较）
                let body = trimmed
                    .replacingOccurrences(of: "- [ ] ", with: "")
                    .replacingOccurrences(of: "- [x] ", with: "")
                    .replacingOccurrences(of: "- [X] ", with: "")
                if searchText.contains(body) || body.contains(searchText) || body == searchText {
                    if trimmed.hasPrefix("- [ ]") {
                        let dateFmt = DateFormatter()
                        dateFmt.dateFormat = "M.d HH:mm"
                        let dateStr = dateFmt.string(from: Date())
                        lines[i] = lines[i].replacingOccurrences(of: "- [ ]", with: "- [x]") + " ✅\(dateStr)"
                    } else {
                        lines[i] = lines[i]
                            .replacingOccurrences(of: "- [x]", with: "- [ ]")
                            .replacingOccurrences(of: "- [X]", with: "- [ ]")
                        if let r = lines[i].range(of: "\\s*✅[\\d.]+ ?\\d{1,2}:\\d{2}", options: .regularExpression) {
                            lines[i].removeSubrange(r)
                        }
                    }
                    content = lines.joined(separator: "\n")
                    CacheFile.write(content)
                    return true
                }
            }
        }
        return false
    }

    /// 切换第 index 个 todo 的完成状态（0-based，今日日期块内）
    static func toggleTodo(index: Int) -> Bool {
        guard var content = CacheFile.read() else { return false }
        var lines = content.components(separatedBy: "\n")

        let todayStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        var inTodo = false
        var inTodayBlock = false
        var todoIdx = 0
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## 📝") { inTodo = true; continue }
            if !inTodo { continue }
            if trimmed.hasPrefix("### ") {
                let dateStr = trimmed.replacingOccurrences(of: "### ", with: "").trimmingCharacters(in: .whitespaces)
                inTodayBlock = (dateStr == todayStr)
                todoIdx = 0
                continue
            }
            if !inTodayBlock { continue }
            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                if todoIdx == index {
                    if trimmed.hasPrefix("- [ ]") {
                        // 打钩：追加完成时间
                        let timeFmt = DateFormatter()
                        timeFmt.dateFormat = "HH:mm"
                        let timeStr = timeFmt.string(from: Date())
                        lines[i] = lines[i].replacingOccurrences(of: "- [ ]", with: "- [x]") + " ✅\(timeStr)"
                    } else {
                        // 取消勾选：移除 ✅ 时间标记
                        lines[i] = lines[i]
                            .replacingOccurrences(of: "- [x]", with: "- [ ]")
                            .replacingOccurrences(of: "- [X]", with: "- [ ]")
                        // 移除 ✅HH:mm 或 ✅ HH:mm
                        if let r = lines[i].range(of: "\\s*✅\\d{1,2}:\\d{2}", options: .regularExpression) {
                            lines[i].removeSubrange(r)
                        }
                    }
                    content = lines.joined(separator: "\n")
                    CacheFile.write(content)
                    return true
                }
                todoIdx += 1
            }
        }
        return false
    }

    /// 编辑第 index 个 todo 的正文（保留完成状态、备注、关联）
    static func editTodo(index: Int, newText: String) -> Bool {
        guard var content = CacheFile.read() else { return false }
        var lines = content.components(separatedBy: "\n")

        let todayStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        var inTodo = false
        var inTodayBlock = false
        var todoIdx = 0
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## 📝") { inTodo = true; continue }
            if !inTodo { continue }
            if trimmed.hasPrefix("### ") {
                let dateStr = trimmed.replacingOccurrences(of: "### ", with: "").trimmingCharacters(in: .whitespaces)
                inTodayBlock = (dateStr == todayStr)
                todoIdx = 0
                continue
            }
            if !inTodayBlock { continue }
            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                if todoIdx == index {
                    // 保留 checkbox 前缀
                    let prefix: String
                    if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                        prefix = "- [x] "
                    } else {
                        prefix = "- [ ] "
                    }
                    // 保留备注
                    var note = ""
                    if let r = lines[i].range(of: "💬") {
                        note = " " + String(lines[i][r.lowerBound...])
                    }
                    // 保留关联
                    var link = ""
                    if let r = lines[i].range(of: "`→\\s*D\\d{3}`", options: .regularExpression) {
                        link = " " + String(lines[i][r])
                    }
                    lines[i] = prefix + newText + link + note
                    content = lines.joined(separator: "\n")
                    CacheFile.write(content)
                    return true
                }
                todoIdx += 1
            }
        }
        return false
    }

    /// 删除第 index 个 todo（0-based，今日日期块内）
    static func deleteTodo(index: Int) -> Bool {
        guard var content = CacheFile.read() else { return false }
        var lines = content.components(separatedBy: "\n")

        let todayStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        var inTodo = false
        var inTodayBlock = false
        var todoIdx = 0
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## 📝") { inTodo = true; continue }
            if !inTodo { continue }
            if trimmed.hasPrefix("### ") {
                let dateStr = trimmed.replacingOccurrences(of: "### ", with: "").trimmingCharacters(in: .whitespaces)
                inTodayBlock = (dateStr == todayStr)
                todoIdx = 0
                continue
            }
            if !inTodayBlock { continue }
            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                if todoIdx == index {
                    lines.remove(at: i)
                    content = lines.joined(separator: "\n")
                    CacheFile.write(content)
                    return true
                }
                todoIdx += 1
            }
        }
        return false
    }

    /// 按文本内容匹配删除 todo（用于顺延项，不限定日期块）
    static func deleteTodoByText(_ searchText: String) -> Bool {
        guard var content = CacheFile.read() else { return false }
        var lines = content.components(separatedBy: "\n")

        var inTodo = false
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## 📝") { inTodo = true; continue }
            if !inTodo { continue }
            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                let body = trimmed
                    .replacingOccurrences(of: "- [ ] ", with: "")
                    .replacingOccurrences(of: "- [x] ", with: "")
                    .replacingOccurrences(of: "- [X] ", with: "")
                if searchText.contains(body) || body.contains(searchText) || body == searchText {
                    lines.remove(at: i)
                    content = lines.joined(separator: "\n")
                    CacheFile.write(content)
                    return true
                }
            }
        }
        return false
    }

    /// 新增一条今日零碎
    static func addTodo(text: String) -> Bool {
        guard var content = CacheFile.read() else { return false }
        var lines = content.components(separatedBy: "\n")

        let todayStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        let newLine = "- [ ] \(text)"

        // 找零碎区块
        var todoSectionStart = -1
        var lastDateHeaderIdx = -1
        var lastDateStr = ""
        var lastTodoLineIdx = -1

        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## 📝") {
                todoSectionStart = i
                continue
            }
            if todoSectionStart >= 0 {
                if trimmed.hasPrefix("### ") {
                    lastDateHeaderIdx = i
                    lastDateStr = trimmed.replacingOccurrences(of: "### ", with: "").trimmingCharacters(in: .whitespaces)
                    lastTodoLineIdx = i
                }
                if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                    lastTodoLineIdx = i
                }
            }
        }

        if todoSectionStart < 0 {
            // 没有零碎区块，在文件末尾创建
            lines.append("")
            lines.append("## 📝 零碎事项（日清日结）")
            lines.append("")
            lines.append("### \(todayStr)")
            lines.append("")
            lines.append(newLine)
        } else if lastDateStr == todayStr {
            // 今天的日期块已存在，追加到最后一条 todo 后面
            lines.insert(newLine, at: lastTodoLineIdx + 1)
        } else {
            // 今天的日期块不存在，在最后一条 todo 后面新建
            let insertAt = lastTodoLineIdx >= 0 ? lastTodoLineIdx + 1 : todoSectionStart + 1
            lines.insert(contentsOf: ["", "### \(todayStr)", "", newLine], at: insertAt)
        }

        content = lines.joined(separator: "\n")
        CacheFile.write(content)
        return true
    }

    /// 给第 index 个 todo 添加/替换备注（今日日期块内）
    static func addNote(index: Int, note: String) -> Bool {
        guard var content = CacheFile.read() else { return false }
        var lines = content.components(separatedBy: "\n")

        let todayStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        var inTodo = false
        var inTodayBlock = false
        var todoIdx = 0
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## 📝") { inTodo = true; continue }
            if !inTodo { continue }
            if trimmed.hasPrefix("### ") {
                let dateStr = trimmed.replacingOccurrences(of: "### ", with: "").trimmingCharacters(in: .whitespaces)
                inTodayBlock = (dateStr == todayStr)
                todoIdx = 0
                continue
            }
            if !inTodayBlock { continue }
            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                if todoIdx == index {
                    var base = lines[i]
                    if let r = base.range(of: "💬") {
                        base = String(base[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    } else {
                        base = base.trimmingCharacters(in: .whitespaces)
                    }
                    lines[i] = base + " 💬" + note
                    content = lines.joined(separator: "\n")
                    CacheFile.write(content)
                    return true
                }
                todoIdx += 1
            }
        }
        return false
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

