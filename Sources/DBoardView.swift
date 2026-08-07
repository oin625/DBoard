import SwiftUI
import Cocoa

/// 原生毛玻璃: NSVisualEffectView 透出桌面壁纸
struct NativeBlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

// MARK: - 通用皮肤背景(背景图 + 遮罩 + 毛玻璃 + orb 光球)
struct ThemeBackground: View {
    @EnvironmentObject var theme: ThemeManager
    var body: some View {
        if theme.current.nativeBlur {
            // 原生毛玻璃: 直接透出桌面壁纸, 不加任何自己的颜色
            NativeBlurView()
                .ignoresSafeArea()
        } else {
            // 用 Color 铺底(保证自身不撑大布局), 所有装饰层用 overlay 叠加
            theme.current.background
                .overlay(backgroundImageLayer)
                .overlay(overlayLayer)
                .overlay(orbLayer)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var backgroundImageLayer: some View {
        if let imgName = theme.current.backgroundImage,
           let nsImg = Self.loadImage(imgName) {
            GeometryReader { geo in
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: theme.current.backgroundBlur)
            }
        }
    }

    @ViewBuilder
    private var overlayLayer: some View {
        if theme.current.overlayOpacity > 0 {
            theme.current.overlayColor
                .opacity(theme.current.overlayOpacity)
        }
    }

    @ViewBuilder
    private var orbLayer: some View {
        if theme.current.glowEnabled {
            GeometryReader { g in
                Circle()
                    .fill(theme.current.orbA.opacity(0.25))
                    .frame(width: g.size.width * 0.6)
                    .blur(radius: 60)
                    .offset(x: -g.size.width * 0.2, y: -g.size.height * 0.1)
                Circle()
                    .fill(theme.current.orbB.opacity(0.2))
                    .frame(width: g.size.width * 0.5)
                    .blur(radius: 50)
                    .offset(x: g.size.width * 0.3, y: g.size.height * 0.4)
                Circle()
                    .fill(theme.current.orbC.opacity(0.15))
                    .frame(width: g.size.width * 0.4)
                    .blur(radius: 40)
                    .offset(x: g.size.width * 0.1, y: g.size.height * 0.7)
            }
            .allowsHitTesting(false)
        }
    }

    /// 从 App bundle Resources/ 加载图片
    private static func loadImage(_ name: String) -> NSImage? {
        // 先试 bundle named
        if let img = NSImage(named: name) { return img }
        // 再试 bundle path (Resources/ 目录)
        let bundle = Bundle.main
        for ext in ["png", "jpg", "jpeg"] {
            if let path = bundle.path(forResource: name, ofType: ext) {
                return NSImage(contentsOfFile: path)
            }
        }
        // 最后试绝对路径(开发时)
        let devPath = bundle.bundlePath + "/Contents/Resources/" + name
        for ext in ["", ".png", ".jpg"] {
            let p = devPath + ext
            if let img = NSImage(contentsOfFile: p) { return img }
        }
        return nil
    }
}

/// 卡片背景修饰器: 根据主题决定用纯色还是毛玻璃
struct ThemeCardBackground: ViewModifier {
    @EnvironmentObject var theme: ThemeManager
    func body(content: Content) -> some View {
        if theme.current.cardMaterial {
            content
                .background(.ultraThinMaterial)
                .background(theme.current.cardFill.opacity(0.25))
        } else {
            content
                .background(theme.current.cardFill.opacity(theme.current.cardFillOpacity))
        }
    }
}

extension View {
    func themeCardBackground() -> some View {
        self.modifier(ThemeCardBackground())
    }
}

// MARK: - Color 扩展
extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b)
    }
}

// MARK: - 毛玻璃背景
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - ViewModel
final class DBoardViewModel: ObservableObject {
    @Published var items: [DItem] = []
    @Published var todaySec: TodoSection? = nil
    @Published var prevSecs: [TodoSection] = []
    @Published var syncTime: String? = nil
    /// 昨天（最近一个历史块），兼容旧引用
    var prevSec: TodoSection? { prevSecs.first }
    @Published var viewMode: ViewMode = .priority
    @Published var syncText: String = ""
    @Published var syncKind: SyncKind = .idle
    @Published var expandedIDs: Set<String> = []
    @Published var paletteOpen = false
    @Published var paletteQuery = ""
    @Published var paletteSel = 0
    @Published var selectedID: String? = nil

    enum SyncKind { case idle, pending, syncing, done, fail }

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var lastSelfWrite: Date = .distantPast
    private var syncDebounce: DispatchWorkItem?
    private let syncDelay: TimeInterval = 30

    init() {
        reload()
        startWatching()
    }

    @Published var newTodoText = ""

    var urgentCount: Int { items.filter { $0.isUrgent }.count }
    var inProgressCount: Int { items.filter { $0.status == .inProgress }.count }
    var todayTodos: [TodoItem] { todaySec?.items ?? [] }
    var doneCount: Int { todayTodos.filter { $0.isCompleted }.count }
    var totalCount: Int { todayTodos.count }
    var allDone: Bool { totalCount > 0 && doneCount == totalCount }

    func reload() {
        let r = CacheParser.parse()
        items = r.items
        syncTime = r.syncTime

        // 把历史未完成项顺延显示在今日零碎顶部
        var carriedOver: [TodoItem] = []
        for sec in r.prevSecs {
            for item in sec.items where !item.isCompleted {
                var carried = item
                carried.text = "[\(sec.shortDate)顺延] " + carried.text
                carried.isCarriedOver = true
                carriedOver.append(carried)
            }
        }

        if let today = r.todaySec {
            let merged = carriedOver + today.items
            todaySec = TodoSection(dateLabel: today.dateLabel, items: merged, isToday: true)
        } else if !carriedOver.isEmpty {
            let todayStr: String = {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
            }()
            todaySec = TodoSection(dateLabel: todayStr, items: carriedOver, isToday: true)
        } else {
            todaySec = r.todaySec
        }

        // 保留所有历史块用于展示（不过滤）
        prevSecs = r.prevSecs
        updateSyncDisplay()
    }

    func updateSyncDisplay() {
        if let t = syncTime, let time = t.split(separator: "T").last {
            let parts = time.split(separator: ":")
            if parts.count >= 2 { syncText = "最近同步 \(parts[0]):\(parts[1])"; syncKind = .idle; return }
        }
        syncText = "未同步"; syncKind = .idle
    }

    func toggleExpanded(_ id: String) {
        var s = expandedIDs
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        expandedIDs = s
    }
    func expandAll() { expandedIDs = Set(items.map { $0.id }) }
    func collapseAll() { expandedIDs = [] }
    func setViewMode(_ m: ViewMode) { viewMode = m }

    func toggleTodo(_ idx: Int) {
        guard let sec = todaySec, idx < sec.items.count else { return }
        let item = sec.items[idx]
        lastSelfWrite = Date()

        if item.isCarriedOver {
            // 顺延项：按原始文本在文件中匹配（去掉"[X月X日顺延] "前缀）
            var originalText = item.text
            if let r = originalText.range(of: "^\\[.*?顺延\\]\\s*", options: .regularExpression) {
                originalText = String(originalText[r.upperBound...])
            }
            _ = FileMutator.toggleTodoByText(originalText)
        } else {
            // 今日项：计算真实 index（排除 carriedOver 项）
            let realIdx = sec.items.prefix(idx).filter { !$0.isCarriedOver }.count
            _ = FileMutator.toggleTodo(index: realIdx)
        }

        var arr = sec.items
        arr[idx].isCompleted.toggle()
        todaySec = TodoSection(dateLabel: sec.dateLabel, items: arr, isToday: sec.isToday)
        scheduleSync()
    }

    func addTodo(_ text: String) {
        guard !text.isEmpty else { return }
        lastSelfWrite = Date()
        _ = FileMutator.addTodo(text: text)
        if var sec = todaySec {
            sec = TodoSection(dateLabel: sec.dateLabel, items: sec.items + [TodoItem(text: text, isCompleted: false, linkedDItem: nil, note: nil)], isToday: sec.isToday)
            todaySec = sec
        } else {
            let todayStr = Self.todayStr()
            todaySec = TodoSection(dateLabel: todayStr, items: [TodoItem(text: text, isCompleted: false, linkedDItem: nil, note: nil)], isToday: true)
        }
        scheduleSync()
    }

    func editTodo(_ idx: Int, newText: String) {
        guard let sec = todaySec, idx < sec.items.count, !newText.isEmpty else { return }
        lastSelfWrite = Date()
        _ = FileMutator.editTodo(index: idx, newText: newText)
        var arr = sec.items
        arr[idx].text = newText
        todaySec = TodoSection(dateLabel: sec.dateLabel, items: arr, isToday: sec.isToday)
        scheduleSync()
    }

    func deleteTodo(_ idx: Int) {
        guard let sec = todaySec, idx < sec.items.count else { return }
        let item = sec.items[idx]
        lastSelfWrite = Date()

        if item.isCarriedOver {
            // 顺延项：按原始文本在历史块中删除（去掉"[X月X日顺延] "前缀）
            var originalText = item.text
            if let r = originalText.range(of: "^\\[.*?顺延\\]\\s*", options: .regularExpression) {
                originalText = String(originalText[r.upperBound...])
            }
            _ = FileMutator.deleteTodoByText(originalText)
        } else {
            // 今日项：计算真实 index（排除 carriedOver 项）
            let realIdx = sec.items.prefix(idx).filter { !$0.isCarriedOver }.count
            _ = FileMutator.deleteTodo(index: realIdx)
        }

        var arr = sec.items
        arr.remove(at: idx)
        todaySec = TodoSection(dateLabel: sec.dateLabel, items: arr, isToday: sec.isToday)
        scheduleSync()
    }

    func addNote(_ idx: Int, note: String) {
        guard let sec = todaySec, idx < sec.items.count else { return }
        lastSelfWrite = Date()
        _ = FileMutator.addNote(index: idx, note: note)
        var arr = sec.items
        arr[idx].note = note.isEmpty ? nil : note
        todaySec = TodoSection(dateLabel: sec.dateLabel, items: arr, isToday: sec.isToday)
        scheduleSync()
    }

    private static func todayStr() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    // MARK: 命令面板
    struct PaletteEntry: Identifiable {
        let id = UUID()
        let label: String
        let sub: String
        let icon: String
        let action: () -> Void
    }
    var paletteEntries: [PaletteEntry] {
        var es: [PaletteEntry] = []
        let q = paletteQuery.lowercased()
        let acts: [(String, String, () -> Void)] = [
            ("切换视图", "command", { self.setViewMode(self.viewMode == .priority ? .project : .priority); self.paletteOpen = false }),
            ("展开全部需求", "arrow.up.left.and.arrow.down.right", { self.expandAll(); self.paletteOpen = false }),
            ("折叠全部需求", "arrow.down.right.and.arrow.up.left", { self.collapseAll(); self.paletteOpen = false }),
            ("同步钉钉", "bolt", { self.doSyncNow(); self.paletteOpen = false }),
            ("刷新", "arrow.clockwise", { self.reload(); self.paletteOpen = false }),
        ]
        for a in acts {
            if q.isEmpty || a.0.lowercased().contains(q) {
                es.append(PaletteEntry(label: a.0, sub: "动作", icon: a.1, action: a.2))
            }
        }
        for it in items {
            if q.isEmpty || it.displayTitle.lowercased().contains(q) || it.id.lowercased().contains(q) {
                let id = it.id
                es.append(PaletteEntry(label: it.displayTitle, sub: id, icon: "doc.text", action: { self.expandedIDs.insert(id); self.paletteOpen = false }))
            }
        }
        return es
    }
    func paletteMove(_ d: Int) {
        let n = paletteEntries.count
        guard n > 0 else { return }
        paletteSel = (paletteSel + d + n) % n
    }
    func paletteRun() {
        guard paletteEntries.indices.contains(paletteSel) else { return }
        paletteEntries[paletteSel].action()
    }

    // MARK: 键盘选中导航
    func moveSel(_ d: Int) {
        let ids = items.map { $0.id }
        guard !ids.isEmpty else { return }
        let cur = selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        selectedID = ids[(cur + d + ids.count) % ids.count]
    }
    func activateSel() { if let id = selectedID { toggleExpanded(id) } }

    func cycleStatus(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let order: [ItemStatus] = [.pending, .inProgress, .completed, .suspended]
        let cur = order.firstIndex(of: item.status) ?? 0
        let next = order[(cur + 1) % order.count]
        lastSelfWrite = Date()
        _ = FileMutator.setStatus(id: id, newStatusRaw: next.rawValue)
        var arr = items
        if let i = arr.firstIndex(where: { $0.id == id }) { arr[i].status = next }
        items = arr
        scheduleSync()
    }

    func cycleToStatus(_ id: String, target: ItemStatus) {
        lastSelfWrite = Date()
        _ = FileMutator.setStatus(id: id, newStatusRaw: target.rawValue)
        var arr = items
        if let i = arr.firstIndex(where: { $0.id == id }) { arr[i].status = target }
        items = arr
        scheduleSync()
    }

    private func startWatching() {
        let path = CacheFile.path
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        fileMonitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: [.write, .rename, .delete], queue: .main)
        fileMonitor?.setEventHandler { [weak self] in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.lastSelfWrite) < 0.6 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.reload() }
        }
        fileMonitor?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 { close(fd); self?.fileDescriptor = -1 }
        }
        fileMonitor?.resume()
    }

    func scheduleSync() {
        syncDebounce?.cancel()
        syncText = "⏳ \(Int(syncDelay))s 后同步"; syncKind = .pending
        let work = DispatchWorkItem { [weak self] in self?.doSync() }
        syncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + syncDelay, execute: work)
    }
    func doSyncNow() { syncDebounce?.cancel(); syncDebounce = nil; doSync() }

    private func doSync() {
        syncText = "正在同步钉钉…"; syncKind = .syncing
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = [CacheFile.syncScript]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            var ok = false
            do { try task.run(); task.waitUntilExit(); ok = (task.terminationStatus == 0) } catch { ok = false }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.syncText = ok ? "✅ 已同步钉钉" : "⚠ 同步失败"
                self.syncKind = ok ? .done : .fail
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.reload() }
            }
        }
    }

    // MARK: - AI 对话
    struct AIMessage: Identifiable {
        let id = UUID()
        let role: Role
        let text: String
        let time: Date
        enum Role { case user, assistant }
    }

    @Published var aiInput = ""
    @Published var aiReply = ""
    @Published var aiLoading = false
    @Published var aiStatus = "" // 实时状态：思考中/正在读文件/调用工具…
    @Published var aiHistory: [AIMessage] = []
    @Published var aiHistoryExpanded: Bool = false
    /// 会话 ID：第一次调用创建，后续 --resume 续接
    private var aiSessionID: String? = nil
    /// 是否已首次创建过会话（决定用 --session-id 还是 --resume）
    @Published private(set) var aiSessionCreated: Bool = false
    var hasAISession: Bool { aiSessionCreated }

    func resetAIConversation() {
        aiSessionID = nil
        aiSessionCreated = false
        aiReply = "🔄 已开启新会话"
        aiHistory = []
        aiHistoryExpanded = false
    }

    /// 手滑把待办打进 AI 框的纠错出口：⌘⏎ 或点 ➕ 直接落今日零碎，不发 AI
    func addTodoFromAIBar() {
        let text = aiInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !aiLoading else { return }
        aiInput = ""
        addTodo(text)
        aiReply = "➕ 已加为今日零碎：\(text)"
    }

    func runAI() {
        let prompt = aiInput.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty, !aiLoading else { return }
        aiInput = ""
        aiLoading = true
        aiReply = ""
        aiStatus = "启动中…"
        aiHistory.append(AIMessage(role: .user, text: prompt, time: Date()))

        // 首次调用生成 UUID；后续复用
        if aiSessionID == nil {
            aiSessionID = UUID().uuidString.lowercased()
        }
        let sid = aiSessionID!
        let firstTime = !aiSessionCreated

        let systemPrompt = """
        你现在是 DBoard 菜单栏 App 的对话助手，用户对你说的每一句话都是关于 D板 的操作。

        必做第一步：立即用 Read 工具读取 ~/.claude/skills/d-board/SKILL.md，然后严格按里面的规则执行本次任务。这个对话框里的所有请求都必须走 d-board skill 的流程（本地缓存 + 钉钉进行中文档 + 钉钉已完成归档三处同步）。

        本地缓存路径：\(CacheFile.path)

        直接执行，不要询问用户。完成后用一两句中文简短汇报做了什么。不要输出文件全文，不要长篇解释。
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let task = Process()
            task.environment = ProcessInfo.processInfo.environment
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")

            // qodercli: 极致模型, stream-json 与 claude 同构无需改解析; BUN_OPTIONS 为 token 拦截钩子
            let home = NSHomeDirectory()
            let qodercli = "BUN_OPTIONS=--preload=\(home)/.loongsuite-pilot/hooks/qodercli-token-intercept.mjs \(home)/.local/bin/qodercli -m Ultimate"
            let commonFlags = "--output-format stream-json --dangerously-skip-permissions"
            let cmd: String
            if firstTime {
                cmd = "\(qodercli) -p \(Self.shellEscape(prompt)) --append-system-prompt \(Self.shellEscape(systemPrompt)) --session-id \(sid) \(commonFlags)"
            } else {
                cmd = "\(qodercli) -p \(Self.shellEscape(prompt)) --resume \(sid) \(commonFlags)"
            }
            task.arguments = ["-l", "-c", cmd]

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            var finalReply = ""
            var lineBuffer = ""
            var timedOut = false

            // 流式读取 stdout
            let handle = outPipe.fileHandleForReading
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                if let chunk = String(data: data, encoding: .utf8) {
                    lineBuffer += chunk
                    while let nlRange = lineBuffer.range(of: "\n") {
                        let line = String(lineBuffer[..<nlRange.lowerBound])
                        lineBuffer.removeSubrange(..<nlRange.upperBound)
                        if let (status, replyText) = Self.parseStreamLine(line) {
                            DispatchQueue.main.async {
                                if !status.isEmpty { self.aiStatus = status }
                                if let r = replyText { finalReply = r }
                            }
                        }
                    }
                }
            }

            do {
                try task.run()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    task.waitUntilExit()
                    group.leave()
                }
                if group.wait(timeout: .now() + .seconds(180)) == .timedOut {
                    timedOut = true
                    task.terminate()
                    _ = group.wait(timeout: .now() + .seconds(3))
                    if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                }
                handle.readabilityHandler = nil
                let success = !timedOut && task.terminationStatus == 0
                if success && firstTime {
                    DispatchQueue.main.async { self.aiSessionCreated = true }
                } else if !success {
                    DispatchQueue.main.async {
                        self.aiSessionID = nil
                        self.aiSessionCreated = false
                    }
                }
            } catch {
                finalReply = "⚠️ 调用失败: \(error.localizedDescription)"
                DispatchQueue.main.async {
                    self.aiSessionID = nil
                    self.aiSessionCreated = false
                }
            }

            if timedOut {
                finalReply = "⏱ 超过 180s 未返回，已中断。" + (finalReply.isEmpty ? "" : "\n" + finalReply)
            }

            DispatchQueue.main.async {
                let reply = finalReply.isEmpty ? "✅ 已完成（无输出）" : finalReply
                self.aiReply = reply
                self.aiHistory.append(AIMessage(role: .assistant, text: reply, time: Date()))
                self.aiLoading = false
                self.aiStatus = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.reload() }
            }
        }
    }

    /// 解析 stream-json 单行，返回 (状态描述, 最终回复文本?)
    /// 状态描述用于实时更新 UI；最终回复只在 assistant message 出现时返回
    private static func parseStreamLine(_ line: String) -> (String, String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "system":
            let subtype = (json["subtype"] as? String) ?? ""
            if subtype == "init" { return ("初始化会话…", nil) }
            if subtype == "hook_started" { return ("加载 hook…", nil) }
            if subtype == "thinking_tokens" {
                let tokens = json["estimated_tokens"] as? Int ?? 0
                return ("思考中… (\(tokens) tokens)", nil)
            }
            return ("", nil)

        case "assistant":
            // message.content 是数组，可能有 text/tool_use 等
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    let btype = block["type"] as? String ?? ""
                    if btype == "tool_use" {
                        let name = block["name"] as? String ?? "工具"
                        var detail = ""
                        if let input = block["input"] as? [String: Any] {
                            if let path = input["file_path"] as? String { detail = " \((path as NSString).lastPathComponent)" }
                            else if let cmd = input["command"] as? String { detail = " \(cmd.prefix(30))" }
                        }
                        return ("🔧 调用 \(name)\(detail)", nil)
                    }
                    if btype == "text", let text = block["text"] as? String {
                        return ("✨ 生成回复中…", text)
                    }
                }
            }
            return ("", nil)

        case "user":
            // tool_result 回来了
            return ("📥 收到工具结果", nil)

        case "result":
            // 最终结果，通常包含 result 字段
            if let result = json["result"] as? String {
                return ("✅ 完成", result)
            }
            return ("✅ 完成", nil)

        default:
            return nil
        }
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    deinit {
        fileMonitor?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }
}

// MARK: - 根视图
struct DBoardRootView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @State private var monitor: Any?
    var popoverMode: Bool = false   // popover 模式才挂下拉撕出手势

    var body: some View {
        ZStack {
            // 皮肤背景(背景图 + 遮罩 + orb 光球)
            ThemeBackground()
                .environmentObject(theme)

            VStack(spacing: 0) {
                HeaderView(popoverMode: popoverMode)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        NeedsSection()
                        PrevSection()
                        TodaySection()
                    }
                    .padding(.bottom, 12)
                }
                AIChatBar()  // 2026-07-28 已切换 qodercli(-m Ultimate) + d-board skill, 恢复入口
                FooterView()
            }
            if vm.paletteOpen {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { vm.paletteOpen = false }
                    CommandPalette().environmentObject(vm).padding(.top, 50)
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 380, idealWidth: 420, maxWidth: .infinity, minHeight: 480, idealHeight: 640, maxHeight: .infinity)
        .focusEffectDisabled()
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak vm] event in
                return Self.handleKey(event, vm: vm)
            }
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }

    static func handleKey(_ event: NSEvent, vm: DBoardViewModel?) -> NSEvent? {
        guard let vm = vm else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let c = (event.charactersIgnoringModifiers ?? "").lowercased()
        // ⌘K
        if mods.contains(.command) && c == "k" { vm.paletteOpen.toggle(); vm.paletteQuery = ""; vm.paletteSel = 0; return nil }
        if vm.paletteOpen {
            switch event.keyCode {
            case 53: vm.paletteOpen = false; return nil      // esc
            case 125: vm.paletteMove(1); return nil          // ↓
            case 126: vm.paletteMove(-1); return nil         // ↑
            case 36: vm.paletteRun(); return nil             // enter
            default: return event
            }
        }
        let typing = event.window?.firstResponder is NSTextView
        if typing { return event }
        if c == "j" { vm.moveSel(1); return nil }
        if c == "k" { vm.moveSel(-1); return nil }
        if event.keyCode == 36 { vm.activateSel(); return nil }   // enter
        if event.keyCode == 53 {  // esc
            if vm.selectedID != nil {
                vm.selectedID = nil
            } else {
                // 没有选中项，关闭窗口
                event.window?.orderOut(nil)
            }
            return nil
        }
        return event
    }
}

// MARK: - 命令面板
struct CommandPalette: View {
    @EnvironmentObject var vm: DBoardViewModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索需求或动作…", text: $vm.paletteQuery)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
            }
            .padding(13)
            .overlay(Divider(), alignment: .bottom)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(vm.paletteEntries.enumerated()), id: \.element.id) { i, e in
                        PaletteRow(entry: e, selected: i == vm.paletteSel)
                    }
                }
                .padding(5)
            }
        }
        .frame(width: 320, height: 360)
        .focusEffectDisabled()
        .background(RoundedRectangle(cornerRadius: 13).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        .onAppear { focused = true }
        .onChange(of: vm.paletteQuery) { _ in vm.paletteSel = 0 }
    }
}

struct PaletteRow: View {
    @EnvironmentObject var fm: FontManager
    let entry: DBoardViewModel.PaletteEntry
    let selected: Bool
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: entry.icon).font(fm.font(14))
                .foregroundStyle(selected ? Color.blue : Color.gray.opacity(0.6)).frame(width: 14)
            Text(entry.label).font(fm.font(16))
                .foregroundStyle(selected ? Color.blue : Color.primary)
            Spacer()
            Text(entry.sub).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.gray.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? Color.blue.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { entry.action() }
    }
}

// MARK: - Header
struct HeaderView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var showHandle = false
    var popoverMode: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // 双击标题可脱出为独立窗口, hover 时显示提示图标
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.current.textMuted.opacity(showHandle ? 0.5 : 0))
                .frame(width: 14)
                .animation(.easeInOut(duration: 0.2), value: showHandle)
                .help("双击标题栏可脱出为独立窗口")
            Text("我的需求看板")
                .font(fm.font(22))
                .foregroundStyle(theme.current.accentGradient)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            if vm.urgentCount > 0 {
                Text("\(vm.urgentCount) 紧急").font(fm.font(13))
                    .foregroundStyle(Color(hex: "#ef4444"))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color(hex: "#ef4444").opacity(0.1)))
                    .contentTransition(.numericText())
            }
            if vm.inProgressCount > 0 {
                Text("\(vm.inProgressCount) 进行中").font(fm.font(14))
                    .foregroundStyle(theme.current.textTertiary)
                    .contentTransition(.numericText())
            }
            HeaderIconButton(icon: "chart.line.uptrend.xyaxis", help: "A股行情") {
                NotificationCenter.default.post(name: .init("openETF"), object: nil)
            }
            HeaderIconButton(icon: "antenna.radiowaves.left.and.right", help: "前线科技资讯") {
                NotificationCenter.default.post(name: .init("openTechScout"), object: nil)
            }
            HeaderIconButton(icon: "bubble.left.and.bubble.right", help: "钉钉待回复") {
                NotificationCenter.default.post(name: .init("openReplyInbox"), object: nil)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 20)
        .contentShape(Rectangle())
        .onHover { showHandle = $0 }
        // 下拉撕出(与 Skills/BizMap/SysMon 同一套手感); 双击脱出作为旧入口保留
        .tearOffHandle("DBoardPanel", enabled: popoverMode)
        .onTapGesture(count: 2) {
            // 双击标题区 -> 脱出为独立窗口
            if let app = NSApp.delegate as? AppDelegate {
                app.detachPanel()
            }
        }
    }
}

// 头部图标按钮: hover 高亮放大 + 按压回弹
struct HeaderIconButton: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(fm.font(15))
                .foregroundStyle(hovered ? theme.current.accentPrimary : theme.current.textTertiary)
                .padding(6)
                .background(Circle().fill(theme.current.accentPrimary.opacity(hovered ? 0.12 : 0)))
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.85, hoverScale: 1.0))
        .scaleEffect(hovered ? 1.12 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
        .help(help)
    }
}

// MARK: - 需求分组
struct NeedsSection: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager

    var groups: [(String, Color, [DItem])] {
        if vm.viewMode == .project {
            var order: [String] = []
            var g: [String: [DItem]] = [:]
            for it in vm.items {
                if g[it.project] == nil { order.append(it.project) }
                g[it.project, default: []].append(it)
            }
            return order.map { ($0, Color(hex: projColor($0)), g[$0]!) }
        } else {
            return ItemPriority.allCases.compactMap { p in
                let arr = vm.items.filter { $0.priority == p }
                return arr.isEmpty ? nil : (p.title, Color(hex: p.dotColor), arr)
            }
        }
    }

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.element.0) { gi, grp in
            HStack(spacing: 6) {
                Circle().fill(grp.1).frame(width: 7, height: 7)
                Text(grp.0).font(fm.font(20)).foregroundStyle(theme.current.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            VStack(spacing: 12) {
                ForEach(Array(grp.2.enumerated()), id: \.element.id) { i, item in
                    ItemCardView(item: item, appearDelay: Double(i) * 0.04 + Double(gi) * 0.02)
                }
            }
            .padding(.horizontal, 4)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: vm.items.count)
    }
}

// MARK: - 需求卡片
struct ItemCardView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let item: DItem
    var appearDelay: Double = 0
    @State private var hovered = false
    @State private var appeared = false
    var expanded: Bool { vm.expandedIDs.contains(item.id) }
    var pcolor: Color { Color(hex: item.priority.dotColor) }
    var projC: Color { Color(hex: projColor(item.project)) }
    var showDesc: Bool { !item.title.isEmpty && item.title != "（待补充）" && item.title != item.displayTitle }
    var hasBranch: Bool { (item.branch?.isEmpty == false && item.branch != "待定") }
    var hasCycle: Bool { item.startDate != nil }
    var hasProgress: Bool { !item.milestones.isEmpty }
    var hasDetail: Bool { showDesc || hasBranch || hasCycle || hasProgress }

    var body: some View {
        Button(action: { vm.toggleExpanded(item.id) }) {
            cardContent
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.985, hoverScale: 1.0))
        .contextMenu { contextMenuContent }
        .opacity(appeared ? 1 : 0)
        .offset(y: hovered ? -2 : 0)
        .shadow(color: .black.opacity(hovered ? 0.1 : 0.06), radius: hovered ? 12 : 8, y: hovered ? 4 : 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovered)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: expanded)
        .onHover { hovered = $0 }
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(appearDelay)) { appeared = true }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            cardMeta
            if expanded {
                cardDetails
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(vm.selectedID == item.id ? pcolor.opacity(0.06) : Color.clear)
        )
        .padding(.horizontal, 12)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var cardHeader: some View {
        HStack(spacing: 8) {
            Circle().fill(pcolor).frame(width: 8, height: 8)
            Text(item.displayTitle)
                .font(fm.font(17))
                .lineLimit(expanded ? nil : 2)
                .foregroundStyle(theme.current.textPrimary)
            Spacer()
            if let dl = item.daysRemaining {
                if item.isUrgent {
                    Text("\(dl)天")
                        .font(fm.font(13))
                        .foregroundStyle(Color(hex: "#ef4444"))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: "#ef4444").opacity(0.1)))
                } else {
                    Text("\(dl)天").font(fm.font(13)).foregroundStyle(theme.current.textTertiary)
                }
            }
            Image(systemName: "chevron.right").font(fm.font(13))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(theme.current.chrome)
        }
    }

    @ViewBuilder
    private var cardMeta: some View {
        HStack(spacing: 6) {
            Text(item.id).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.current.textTertiary)
            Text("·").font(fm.font(13)).foregroundStyle(theme.current.separator)
            Text(item.project).font(fm.font(13)).foregroundStyle(theme.current.textTertiary)
            Text("·").font(fm.font(13)).foregroundStyle(theme.current.separator)
            StatusPill(status: item.status) { vm.cycleStatus(item.id) }
            Spacer()
        }
    }

    @ViewBuilder
    private var cardDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            if hasDetail {
                if showDesc {
                    HStack(alignment: .top, spacing: 6) {
                        Text("描述").font(fm.font(14)).foregroundStyle(Color(hex: "#94a3b8")).frame(width: 30, alignment: .leading)
                        Text(item.title).font(fm.font(14)).foregroundStyle(Color(hex: "#334155"))
                    }
                }
                if hasBranch, let b = item.branch {
                    HStack(spacing: 6) {
                        Text("分支").font(fm.font(14)).foregroundStyle(Color(hex: "#94a3b8")).frame(width: 30, alignment: .leading)
                        Text(b).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: "#667eea"))
                    }
                }
                if let sd = item.startDate {
                    HStack(spacing: 6) {
                        Text("周期").font(fm.font(14)).foregroundStyle(Color(hex: "#94a3b8")).frame(width: 30, alignment: .leading)
                        Text("\(sd)\(item.deadline.map { " → \($0)" } ?? "")").font(fm.font(14)).foregroundStyle(Color(hex: "#334155"))
                    }
                }
                if hasProgress {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(item.milestones.enumerated()), id: \.offset) { _, ms in
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: "#667eea")).frame(width: 5, height: 5)
                                Text(ms.date).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: "#94a3b8"))
                                Text(ms.content).font(fm.font(14)).foregroundStyle(Color(hex: "#475569"))
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
            } else {
                Text("暂无详情，对 Claude 说「更新 \(item.id)」补充").font(fm.font(14)).foregroundStyle(Color(hex: "#cbd5e1"))
            }
        }
        .padding(.top, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button { vm.toggleExpanded(item.id) } label: {
            Label(expanded ? "折叠" : "展开详情", systemImage: expanded ? "chevron.up" : "chevron.down")
        }
        Divider()
        if let b = item.branch, !b.isEmpty, b != "待定" {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(b, forType: .string)
            } label: {
                Label("复制分支名", systemImage: "doc.on.doc")
            }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.id, forType: .string)
        } label: {
            Label("复制编号 \(item.id)", systemImage: "number")
        }
        Divider()
        Menu("切换状态") {
            ForEach([ItemStatus.pending, .inProgress, .completed, .suspended], id: \.rawValue) { s in
                Button {
                    if item.status != s { vm.cycleToStatus(item.id, target: s) }
                } label: {
                    HStack {
                        Text(s.label)
                        if item.status == s { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }
}

// MARK: - 状态药丸
struct StatusPill: View {
    @EnvironmentObject var fm: FontManager
    let status: ItemStatus
    let onTap: () -> Void
    @State private var pop = false
    @State private var hovered = false
    var fg: Color {
        switch status {
        case .pending: return Color(hex: "#8e8e93")
        case .inProgress: return Color(hex: "#007aff")
        case .completed: return Color(hex: "#34c759")
        case .suspended: return Color(hex: "#ff9500")
        }
    }
    var body: some View {
        Text(status.label).font(fm.font(13))
            .foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [fg.opacity(0.15), fg.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .scaleEffect(pop ? 1.15 : (hovered ? 1.08 : 1))
            .id(status)
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .onTapGesture {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { pop = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pop = false }
                }
                onTap()
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: hovered)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: status)
    }
}

// MARK: - 昨日归档
struct PrevSection: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var expanded = false
    @State private var showHistory = false
    var body: some View {
        if let prev = vm.prevSec {
            // 昨天：保持原有逻辑
            if prev.allCompleted {
                Button { expanded.toggle() } label: {
                    HStack {
                        Text("\(prev.shortDate) 已完成").font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                        Spacer()
                        Text("\(prev.doneCount)/\(prev.totalCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.current.chrome)
                        Image(systemName: "chevron.right").font(.system(size: 9)).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(theme.current.chrome)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                if expanded {
                    ForEach(Array(prev.items.filter { $0.isCompleted }.enumerated()), id: \.offset) { _, td in
                        TodoRow(idx: -1, todo: td, readOnly: true)
                    }
                }
            } else {
                let done = prev.items.filter { $0.isCompleted }
                if !done.isEmpty {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: "#34c759")).frame(width: 7, height: 7)
                            Text("\(prev.shortDate) 已完成 \(done.count) 项").font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 9)).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(theme.current.chrome)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if expanded {
                        ForEach(Array(done.enumerated()), id: \.offset) { _, td in
                            TodoRow(idx: -1, todo: td, readOnly: true)
                        }
                    }
                }
            }

            // 更早历史下拉框
            if vm.prevSecs.count > 1 {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showHistory.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(fm.font(13)).foregroundStyle(theme.current.chrome)
                        Text("更早历史 · \(vm.prevSecs.count - 1) 天").font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9)).rotationEffect(.degrees(showHistory ? 90 : 0)).foregroundStyle(theme.current.chrome)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                if showHistory {
                    ForEach(Array(vm.prevSecs.dropFirst()), id: \.dateLabel) { sec in
                        HistoryBlockView(sec: sec)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

// MARK: - 历史日期块
struct HistoryBlockView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let sec: TodoSection
    @State private var expanded = false
    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
            HStack {
                Text(sec.shortDate).font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                Spacer()
                Text("\(sec.doneCount) 项已完成").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.current.chrome)
                Image(systemName: "chevron.right").font(.system(size: 9)).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(theme.current.chrome)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        if expanded {
            ForEach(Array(sec.items.filter { $0.isCompleted }.enumerated()), id: \.offset) { _, td in
                TodoRow(idx: -1, todo: td, readOnly: true)
            }
        }
    }
}

// MARK: - 今日零碎
struct TodaySection: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("今日零碎").font(fm.font(20)).foregroundStyle(theme.current.textSecondary)
                Spacer()
                Text("\(vm.doneCount)/\(vm.totalCount)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.current.textTertiary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)

            // 醒目的添加行
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(theme.current.accentGradient)
                        .frame(width: 24, height: 24)
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                TextField("添加今日零碎…", text: $vm.newTodoText)
                    .font(fm.font(17))
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.current.textPrimary)
                    .onSubmit {
                        let text = vm.newTodoText.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        vm.newTodoText = ""
                        vm.addTodo(text)
                    }
                if !vm.newTodoText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("回车添加").font(fm.font(12)).foregroundStyle(theme.current.textMuted)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.current.accentPrimary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(theme.current.accentPrimary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    )
            )
            .padding(.horizontal, 16).padding(.vertical, 4)

            if vm.todayTodos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet").font(.system(size: 28)).foregroundStyle(Color(hex: "#e2e8f0"))
                    Text("暂无今日零碎").font(fm.font(15)).foregroundStyle(Color(hex: "#cbd5e1"))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            }

            ForEach(Array(vm.todayTodos.enumerated()), id: \.offset) { idx, td in
                TodoRow(idx: idx, todo: td, readOnly: false)
                    .id("today-\(idx)")
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: vm.allDone)
    }
}

// MARK: - 零碎行
struct TodoRow: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let idx: Int
    let todo: TodoItem
    let readOnly: Bool
    @State private var pop = false
    @State private var checkBounce = false
    @State private var hovered = false
    @State private var editingText = false
    @State private var editingNote = false
    @State private var textBuf = ""
    @State private var noteBuf = ""
    @FocusState private var textFocused: Bool
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    if !readOnly {
                        vm.toggleTodo(idx)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { checkBounce = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { checkBounce = false }
                        }
                    }
                } label: {
                    ZStack {
                        Circle().stroke(todo.isCompleted ? Color(hex: "#34c759") : (hovered ? Color(hex: "#667eea") : Color(hex: "#cbd5e1")), lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        if todo.isCompleted {
                            Circle().fill(Color(hex: "#34c759").opacity(0.3)).frame(width: 18, height: 18)
                                .scaleEffect(pop ? 1.7 : 1).opacity(pop ? 0 : 0.6)
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .contentShape(Circle())
                    .background(todo.isCompleted ? Color(hex: "#34c759") : .clear, in: Circle())
                    .scaleEffect(todo.isCompleted && pop ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                .disabled(readOnly)
                .onChange(of: todo.isCompleted) { done in
                    if done {
                        pop = false
                        withAnimation(.easeOut(duration: 0.5)) { pop = true }
                    }
                }

                if editingText && !readOnly {
                    TextField(todo.text, text: $textBuf, onCommit: {
                        if !textBuf.isEmpty { vm.editTodo(idx, newText: textBuf) }
                        editingText = false
                    })
                    .font(fm.font(16))
                    .focused($textFocused)
                    .textFieldStyle(.plain)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.4)))
                } else {
                    Text(todo.text).font(fm.font(16))
                        .strikethrough(todo.isCompleted, color: theme.current.chrome)
                        .foregroundStyle(todo.isCompleted ? theme.current.textMuted : theme.current.textPrimary)
                        .animation(.easeInOut(duration: 0.35), value: todo.isCompleted)
                        .onTapGesture(count: 2) {
                            if !readOnly { textBuf = todo.text; editingText = true; textFocused = true }
                        }
                }

                Spacer()
                if !readOnly && hovered && !editingText {
                    HStack(spacing: 1) {
                        IconBtn("pencil") { textBuf = todo.text; editingText = true; textFocused = true }
                        IconBtn("message") { noteBuf = todo.note ?? ""; editingNote = true; noteFocused = true }
                        IconBtn("xmark", color: .red) { vm.deleteTodo(idx) }
                    }
                    .transition(.opacity)
                }
            }

            if editingNote && !readOnly {
                TextField("备注…", text: $noteBuf, axis: .vertical)
                    .font(fm.font(14))
                    .focused($noteFocused)
                    .textFieldStyle(.plain)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 5).stroke(Color.blue.opacity(0.4)))
                    .onSubmit {
                        vm.addNote(idx, note: noteBuf); editingNote = false
                    }
            } else if let note = todo.note {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "message").font(.system(size: 9)).foregroundStyle(theme.current.chrome)
                    Text(note).font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                }.padding(.leading, 28)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .scaleEffect(checkBounce ? 1.02 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(hovered && !readOnly ? Color.black.opacity(0.02) : .clear)
        )
        .contextMenu {
            if !readOnly {
                Button {
                    textBuf = todo.text; editingText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { textFocused = true }
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button {
                    noteBuf = todo.note ?? ""; editingNote = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { noteFocused = true }
                } label: {
                    Label(todo.note != nil ? "编辑备注" : "添加备注", systemImage: "message")
                }
                Divider()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(todo.text, forType: .string)
                } label: {
                    Label("复制内容", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive) { vm.deleteTodo(idx) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .onHover { hovered = $0 }
    }
}

struct IconBtn: View {
    @EnvironmentObject var fm: FontManager
    let icon: String
    var color: Color = .secondary
    let action: () -> Void
    init(_ icon: String, color: Color = .secondary, action: @escaping () -> Void) {
        self.icon = icon; self.color = color; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(fm.font(14)).foregroundStyle(color)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AI 对话栏
struct AIChatBar: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var shimmer: CGFloat = 0

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 6) {
            // 历史面板（点击徽章展开）
            if vm.aiHistoryExpanded && !vm.aiHistory.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("对话历史 · \(vm.aiHistory.count) 条").font(fm.font(13)).foregroundStyle(theme.current.textTertiary)
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { vm.aiHistoryExpanded = false }
                        } label: {
                            Image(systemName: "chevron.down").font(fm.font(13)).foregroundStyle(theme.current.textMuted)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(vm.aiHistory) { msg in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(msg.role == .user ? "🙋" : "✨")
                                            .font(fm.font(13))
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(msg.text)
                                                .font(fm.font(14))
                                                .foregroundStyle(msg.role == .user ? theme.current.textSecondary : theme.current.textPrimary)
                                                .textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(Self.timeFmt.string(from: msg.time))
                                                .font(.system(size: 8, design: .monospaced))
                                                .foregroundStyle(theme.current.chrome)
                                        }
                                    }
                                    .id(msg.id)
                                    .padding(.horizontal, 12).padding(.vertical, 3)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                        .onChange(of: vm.aiHistory.count) { _ in
                            if let last = vm.aiHistory.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.current.cardFill.opacity(0.75))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.current.accentPrimary.opacity(0.15)))
                )
                .padding(.horizontal, 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // AI 回复区域
            if vm.aiLoading || !vm.aiReply.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(colors: [theme.current.accentPrimary, theme.current.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    if vm.aiLoading {
                        HStack(spacing: 4) {
                            Text(vm.aiStatus.isEmpty ? "思考中" : vm.aiStatus).font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                                .lineLimit(1)
                                .animation(.easeInOut(duration: 0.2), value: vm.aiStatus)
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        }
                    } else {
                        Text(vm.aiReply)
                            .font(fm.font(14))
                            .foregroundStyle(theme.current.textSecondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if !vm.aiLoading && !vm.aiReply.isEmpty {
                        Button { vm.aiReply = "" } label: {
                            Image(systemName: "xmark").font(fm.font(13))
                                .foregroundStyle(theme.current.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.current.accentPrimary.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.current.accentPrimary.opacity(0.1)))
                )
                .padding(.horizontal, 12)
            }

            // 输入栏
            HStack(spacing: 8) {
                Button {
                    guard !vm.aiHistory.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { vm.aiHistoryExpanded.toggle() }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "sparkles")
                            .font(fm.font(15))
                            .foregroundStyle(
                                LinearGradient(colors: [theme.current.accentPrimary, theme.current.accentSecondary], startPoint: .leading, endPoint: .trailing)
                            )
                        if !vm.aiHistory.isEmpty {
                            Text("\(vm.aiHistory.count)")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3).padding(.vertical, 0.5)
                                .background(Capsule().fill(LinearGradient(colors: [theme.current.accentPrimary, theme.current.accentSecondary], startPoint: .leading, endPoint: .trailing)))
                                .offset(x: 6, y: -6)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(vm.aiHistory.isEmpty ? "AI 对话" : (vm.aiHistoryExpanded ? "收起历史" : "查看对话历史"))
                TextField(vm.hasAISession ? "继续问 AI…" : "🤖 问 AI：改需求状态、查看板…", text: $vm.aiInput)
                    .font(fm.font(15))
                    .textFieldStyle(.plain)
                    .onSubmit { vm.runAI() }
                    .disabled(vm.aiLoading)
                if vm.hasAISession && !vm.aiLoading {
                    Button { vm.resetAIConversation() } label: {
                        Image(systemName: "arrow.counterclockwise.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.current.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("开启新会话")
                }
                if vm.aiLoading {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                } else if !vm.aiInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 打错框的纠错出口：绿色 ➕ 直接加为今日零碎，不发 AI
                    Button { vm.addTodoFromAIBar() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(hex: "#10b981"))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("⌘⏎ 加为今日零碎（不问 AI）")
                    Button { vm.runAI() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(
                                LinearGradient(colors: [theme.current.accentPrimary, theme.current.accentSecondary], startPoint: .top, endPoint: .bottom)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("⏎ 发送给 AI")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity))
                    .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
            )
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Color.black.opacity(0.06).frame(height: 1)
        }
    }
}

// MARK: - Footer
struct FooterView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    var body: some View {
        HStack(spacing: 6) {
            // 引擎心跳: 值守/资讯/同步 三个 daemon 的死活 + 同步动作反馈
            EngineStrip()
            Spacer()
            FooterButton(vm.viewMode == .project ? "按项目" : "按优先级") { vm.setViewMode(vm.viewMode == .project ? .priority : .project) }
            FooterButton(vm.expandedIDs.isEmpty ? "展开" : "折叠") {
                if vm.expandedIDs.isEmpty { vm.expandAll() } else { vm.collapseAll() }
            }
            Button { vm.paletteOpen.toggle() } label: {
                Text("⌘K").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(theme.current.textTertiary)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.04)))
            }.buttonStyle(SmoothButtonStyle(scale: 0.88))
            FooterButtonIcon("arrow.clockwise") { vm.reload() }
            FooterButtonIcon("bolt") { vm.doSyncNow() }
            Menu {
                ForEach(DBoardTheme.all) { t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.4)) { ThemeManager.shared.current = t }
                    } label: {
                        Label(t.name, systemImage: t.icon)
                    }
                }
            } label: {
                Image(systemName: "paintbrush").font(fm.font(13)).foregroundStyle(theme.current.textMuted)
                    .padding(3)
            }
            .menuStyle(.borderlessButton)
            Menu {
                ForEach(DBoardFont.all) { f in
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { FontManager.shared.current = f }
                    } label: {
                        Label(f.name, systemImage: fm.current.id == f.id ? "checkmark" : "textformat")
                    }
                }
            } label: {
                Image(systemName: "textformat").font(fm.font(13)).foregroundStyle(theme.current.textMuted)
                    .padding(3)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .overlay(alignment: .top) {
            Color.black.opacity(0.06).frame(height: 1)
        }
    }
}

struct FooterButton: View {
    @EnvironmentObject var fm: FontManager
    let title: String
    let action: () -> Void
    @State private var hovered = false
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(fm.font(13)).foregroundStyle(hovered ? Color(hex: "#6366f1") : Color(hex: "#94a3b8"))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color(hex: "#6366f1").opacity(0.12) : Color.clear))
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.9))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
    }
}

struct FooterButtonIcon: View {
    @EnvironmentObject var fm: FontManager
    let icon: String
    let action: () -> Void
    @State private var hovered = false
    init(_ icon: String, action: @escaping () -> Void) { self.icon = icon; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(fm.font(14)).foregroundStyle(hovered ? Color(hex: "#6366f1") : Color(hex: "#94a3b8"))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color(hex: "#6366f1").opacity(0.12) : Color.clear))
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.9))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
    }
}
