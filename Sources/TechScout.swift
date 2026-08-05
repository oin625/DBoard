import SwiftUI
import UserNotifications
import Combine

// MARK: - 数据模型

struct TechScoutItem: Codable, Identifiable {
    let source: String
    let title: String
    let titleCn: String?
    let url: String
    let score: Int
    let comments: Int?
    let summary: String?
    let key: String
    let time: String?
    let author: String?
    let description: String?
    let subreddit: String?
    var detail: String? = nil

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case source, title, url, score, comments, summary, key, time, author, description, subreddit, detail
        case titleCn = "title_cn"
    }

    /// 展示标题：优先中文，fallback 英文
    var displayTitle: String {
        if let cn = titleCn, !cn.isEmpty { return cn }
        return title
    }

    var sourceColor: Color {
        switch source {
        case "HN": return Color(hex: "#ff6600")
        case "GH": return Color(hex: "#333333")
        case "PH": return Color(hex: "#da552f")
        case "X": return Color(hex: "#1da1f2")
        case "RD": return Color(hex: "#ff4500")
        case "TC": return Color(hex: "#0a9e01")
        case "VG": return Color(hex: "#e5127d")
        case "AT": return Color(hex: "#ff4e00")
        case "DM": return Color(hex: "#4285f4")
        case "OA": return Color(hex: "#10a37f")
        case "MT": return Color(hex: "#1f1f1f")
        case "SW": return Color(hex: "#8e44ad")
        default: return Color(hex: "#666666")
        }
    }
}

struct TechScoutPayload: Codable {
    let timestamp: Double
    let items: [TechScoutItem]
}

// MARK: - ViewModel

final class TechScoutViewModel: ObservableObject {
    @Published var items: [TechScoutItem] = []
    @Published var lastUpdate: Date? = nil

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var lastNotifyTime: TimeInterval = 0  // 0 表示从未通知过
    private let notifyDebounce: TimeInterval = 30  // 30 秒防抖（测试用，生产环境改为 300）
    private var lastProcessedTimestamp: Double = 0  // 记录上次处理的 pending.json 时间戳

    private static let pendingPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/tech-scout-pending.json"
    }()

    init() {
        requestNotificationPermission()
        startWatching()
        // 启动时尝试加载一次
        reload()
    }

    func reload() {
        NSLog("DBoard TechScout: reload() called")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.pendingPath)),
              let payload = try? JSONDecoder().decode(TechScoutPayload.self, from: data) else {
            NSLog("DBoard TechScout: failed to read/parse pending.json")
            return
        }

        NSLog("DBoard TechScout: loaded \(payload.items.count) items, timestamp=\(payload.timestamp)")
        let firstLoad = lastProcessedTimestamp == 0
        let isNewData = !firstLoad && payload.timestamp > lastProcessedTimestamp
        lastProcessedTimestamp = payload.timestamp

        DispatchQueue.main.async {
            self.items = payload.items
            self.lastUpdate = Date(timeIntervalSince1970: payload.timestamp)
        }

        // 只有新数据才检查是否发通知（避免启动时对旧数据发通知）
        if isNewData && !payload.items.isEmpty {
            NSLog("DBoard TechScout: new data detected, count=\(payload.items.count)")
            let now = Date().timeIntervalSince1970
            if now - lastNotifyTime > notifyDebounce {
                lastNotifyTime = now
                sendNotification(count: payload.items.count, firstTitle: payload.items.first?.displayTitle ?? "")
            }
        } else {
            NSLog("DBoard TechScout: not new data or debounce failed")
        }
    }

    // MARK: - 历史留存(tech-scout-history.json, 生产端保留30天)

    @Published var historyDays: [(day: String, items: [TechScoutItem])] = []
    private var historyRaw: [[String: Any]] = []
    private static let historyPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/tech-scout-history.json"
    }()

    func loadHistory() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.historyPath)),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd"
            let dec = JSONDecoder()
            var groups: [String: [TechScoutItem]] = [:]
            for e in arr {
                let ts = (e["timestamp"] as? Double) ?? 0
                let day = fmt.string(from: Date(timeIntervalSince1970: ts))
                if let d = try? JSONSerialization.data(withJSONObject: e),
                   let item = try? dec.decode(TechScoutItem.self, from: d) {
                    groups[day, default: []].append(item)
                }
            }
            let days = groups.keys.sorted(by: >).map { (day: $0, items: Array(groups[$0]!.reversed())) }
            DispatchQueue.main.async {
                self.historyRaw = arr
                self.historyDays = days
            }
        }
    }

    func deleteDay(_ day: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd"
        historyRaw.removeAll { e in
            let ts = (e["timestamp"] as? Double) ?? 0
            return fmt.string(from: Date(timeIntervalSince1970: ts)) == day
        }
        persistHistory()
    }

    func clearAllHistory() {
        historyRaw = []
        persistHistory()
    }

    private func persistHistory() {
        if let d = try? JSONSerialization.data(withJSONObject: historyRaw, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: Self.historyPath), options: .atomic)
        }
        loadHistory()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("DBoard TechScout: notification permission granted=\(granted), error=\(error?.localizedDescription ?? "none")")
        }
    }

    private func sendNotification(count: Int, firstTitle: String) {
        NSLog("DBoard TechScout: sending notification for \(count) items")

        let content = UNMutableNotificationContent()
        content.title = "📡 前线科技资讯"
        content.body = "发现 \(count) 条大新闻" + (firstTitle.isEmpty ? "" : "：\(firstTitle)")
        content.sound = .default

        let request = UNNotificationRequest(identifier: "tech-scout-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            NSLog("DBoard TechScout: notification add error=\(error?.localizedDescription ?? "none")")
        }
    }

    private func startWatching() {
        let path = Self.pendingPath
        // 确保文件存在
        if !FileManager.default.fileExists(atPath: path) {
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
        }

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename],
            queue: .main
        )

        fileMonitor?.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.reload()
            }
        }

        fileMonitor?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        fileMonitor?.resume()
    }

    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    deinit {
        fileMonitor?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }
}

// MARK: - 窗口控制器

final class TechScoutWindowController {
    private var window: NSWindow?
    private var viewModel: TechScoutViewModel

    init(viewModel: TechScoutViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = TechScoutView()
            .environmentObject(viewModel)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let hostingController = NSHostingController(rootView: contentView)

        let win = NSWindow(contentViewController: hostingController)
        win.title = "前线科技资讯"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.setContentSize(NSSize(width: 560, height: 660))
        win.styleMask = [.titled, .closable, .resizable]
        win.center()
        win.isReleasedWhenClosed = false
        // 原生毛玻璃需要窗口透明才能透出桌面壁纸
        win.isOpaque = false
        win.backgroundColor = .clear
        win.contentMinSize = NSSize(width: 480, height: 420)
        win.contentMaxSize = NSSize(width: 2600, height: 2200)
        win.setFrameAutosaveName("DBoardTechScoutWindow")
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]  // 跟随当前桌面 + 保留全屏能力(赋值会覆盖默认行为集)
        win.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        window = win
    }
}

// MARK: - SwiftUI 视图

struct TechScoutView: View {
    @EnvironmentObject var vm: TechScoutViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var showHistory = false
    @State private var selectedDay = ""
    @State private var confirmClearDay = false
    @State private var confirmClearAll = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — D板同款手写体标题
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("前线科技资讯")
                        .font(fm.font(26))
                        .foregroundStyle(theme.current.accentGradient)
                    HStack(spacing: 6) {
                        Text("自动聚合全网科技热点")
                        if !vm.items.isEmpty {
                            Text("·")
                            Text("\(vm.items.count) 条")
                        }
                    }
                    .font(fm.font(12))
                    .foregroundStyle(theme.current.textTertiary)
                }
                Spacer()
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showHistory.toggle()
                        if showHistory { vm.loadHistory() }
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: showHistory ? "antenna.radiowaves.left.and.right" : "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .bold))
                        Text(showHistory ? "回到最新" : "历史")
                    }
                    .font(fm.font(12))
                    .foregroundStyle(theme.current.accentPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(theme.current.accentPrimary.opacity(0.1)))
                }
                .buttonStyle(SmoothButtonStyle())
                .padding(.top, 6)
                if let date = vm.lastUpdate {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text(date, style: .time)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.current.textTertiary)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 10)

            // Content
            ScrollView {
                LazyVStack(spacing: 12) {
                    if showHistory {
                        historySection
                    } else if vm.items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 36))
                                .foregroundStyle(.tertiary)
                            Text("暂无新闻，等一下再来 ☕")
                                .font(fm.font(14))
                                .foregroundStyle(theme.current.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                    } else {
                        ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                            TechScoutCard(item: item, rank: index + 1) { vm.openURL(item.url) }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 520, minHeight: 600)
        .focusEffectDisabled()
        .background(ThemeBackground().environmentObject(theme).environmentObject(ThemeManager.shared))
    }

    private var currentDay: String {
        if !selectedDay.isEmpty, vm.historyDays.contains(where: { $0.day == selectedDay }) { return selectedDay }
        return vm.historyDays.first?.day ?? ""
    }

    @ViewBuilder
    private var historySection: some View {
        if vm.historyDays.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("暂无历史留存")
                    .font(fm.font(13))
                    .foregroundStyle(theme.current.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(vm.historyDays, id: \.day) { g in
                        let sel = currentDay == g.day
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedDay = g.day
                                confirmClearDay = false
                            }
                        }) {
                            Text("\(g.day) · \(g.items.count)")
                                .font(fm.font(12))
                                .foregroundStyle(sel ? .white : theme.current.textSecondary)
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(Capsule().fill(sel
                                    ? AnyShapeStyle(theme.current.accentGradient)
                                    : AnyShapeStyle(theme.current.textTertiary.opacity(0.1))))
                        }
                        .buttonStyle(SmoothButtonStyle())
                    }
                }
            }
            HStack {
                Button(action: {
                    if confirmClearDay {
                        vm.deleteDay(currentDay)
                        confirmClearDay = false
                    } else {
                        confirmClearDay = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { confirmClearDay = false }
                    }
                }) {
                    Text(confirmClearDay ? "确认清空 \(currentDay)?" : "清空这天")
                        .font(fm.font(11))
                        .foregroundStyle(confirmClearDay ? .white : Color(hex: "#ff6b6b"))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(confirmClearDay ? Color(hex: "#ff6b6b") : Color(hex: "#ff6b6b").opacity(0.1)))
                }
                .buttonStyle(SmoothButtonStyle())
                Spacer()
                Button(action: {
                    if confirmClearAll {
                        vm.clearAllHistory()
                        confirmClearAll = false
                    } else {
                        confirmClearAll = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { confirmClearAll = false }
                    }
                }) {
                    Text(confirmClearAll ? "确认清空全部历史?" : "清空全部")
                        .font(fm.font(11))
                        .foregroundStyle(confirmClearAll ? .white : Color(hex: "#ff6b6b"))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(confirmClearAll ? Color(hex: "#ff6b6b") : Color(hex: "#ff6b6b").opacity(0.1)))
                }
                .buttonStyle(SmoothButtonStyle())
            }
            let dayItems = vm.historyDays.first(where: { $0.day == currentDay })?.items ?? []
            ForEach(Array(dayItems.enumerated()), id: \.offset) { idx, item in
                TechScoutCard(item: item, rank: idx + 1) { vm.openURL(item.url) }
            }
        }
    }
}

struct TechScoutCard: View {
    let item: TechScoutItem
    let rank: Int
    let onOpen: () -> Void
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var hovered = false
    @State private var expanded = false
    @State private var showFull = false
    @State private var loadingFull = false
    @State private var fullText: String? = nil     // 按需抓取, 只存内存
    @State private var fetchFailed = false

    struct RemoteComment: Identifiable {
        let id = UUID()
        let author: String
        let text: String
        let time: String
    }
    @State private var hotComments: [RemoteComment] = []
    @State private var newComments: [RemoteComment] = []
    @State private var loadingComments = false
    @State private var commentsFetched = false
    @State private var phase = ""
    @State private var articleCompiling = false
    @State private var commentsCompiling = false
    @State private var compiledOnce = false

    private var hasDetail: Bool {
        !(item.detail ?? "").isEmpty
    }

    /// 点"展开原文": 并行抓取 -> 秒开英文占位 -> 两路AI并行翻译, 好一路换一路
    private func toggleFull() {
        if compiledOnce {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showFull.toggle() }
            return
        }
        guard !loadingFull else { return }
        loadingFull = true
        fetchFailed = false
        phase = "抓取中…"
        DispatchQueue.global(qos: .userInitiated).async {
            var text = ""
            var raw: [(String, String, Double)] = []
            let g = DispatchGroup()
            g.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                text = Self.fetchArticleText(item.url); g.leave()
            }
            g.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                raw = item.source == "HN" ? Self.fetchHNComments(item.key)
                    : (item.source == "RD" ? Self.fetchRedditComments(item.url) : [])
                g.leave()
            }
            g.wait()
            let hotRaw = Array(raw.prefix(3))
            let hotTexts = Set(hotRaw.map { $0.1 })
            let newRaw = Array(raw.sorted { $0.2 > $1.2 }.filter { !hotTexts.contains($0.1) }.prefix(2))
            DispatchQueue.main.async {
                loadingFull = false
                if text.count <= 200 && raw.isEmpty {
                    fetchFailed = true
                    return
                }
                compiledOnce = true
                // 英文占位立即展开, AI 好了逐路替换
                fullText = text.count > 200 ? text : nil
                hotComments = hotRaw.map { RemoteComment(author: $0.0, text: $0.1, time: Self.relTime($0.2)) }
                newComments = newRaw.map { RemoteComment(author: $0.0, text: $0.1, time: Self.relTime($0.2)) }
                articleCompiling = fullText != nil
                commentsCompiling = !hotComments.isEmpty || !newComments.isEmpty
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showFull = true }
            }
            // 正文翻译(独立进程)
            if text.count > 200 {
                DispatchQueue.global(qos: .userInitiated).async {
                    let cn = Self.aiText("把这篇英文文章忠实编译为流畅中文(300-500字), 用两个换行分段, 保留关键数字/产品名/公司名原文, 丢弃导航菜单/目录/订阅提示等碎片, 只输出正文, 不要任何解释:\n\n" + String(text.prefix(2600)))
                    DispatchQueue.main.async {
                        if let cn = cn, cn.count > 50 {
                            withAnimation(.easeInOut(duration: 0.25)) { fullText = cn }
                        }
                        articleCompiling = false
                    }
                }
            }
            // 评论翻译(独立进程, 与正文并行)
            if !hotRaw.isEmpty || !newRaw.isEmpty {
                DispatchQueue.global(qos: .userInitiated).async {
                    let all = hotRaw + newRaw
                    let joined = all.enumerated()
                        .map { "[\($0.offset)] \(String($0.element.1.prefix(350)))" }
                        .joined(separator: "\n---\n")
                    let out = Self.aiText("逐条把下面英文评论翻译成中文, 保留原语气, 输出格式与输入一致([序号] 译文, 条目间用\n---\n分隔), 不要任何解释:\n\n" + joined)
                    DispatchQueue.main.async {
                        if let out = out {
                            var cns: [Int: String] = [:]
                            for part in out.components(separatedBy: "---") {
                                let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                                if let m = t.range(of: "^\\[(\\d+)\\]\\s*", options: .regularExpression) {
                                    let idxStr = t[m].trimmingCharacters(in: CharacterSet(charactersIn: "[] \n"))
                                    if let idx = Int(idxStr) {
                                        cns[idx] = String(t[m.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }
                            }
                            if !cns.isEmpty {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    hotComments = hotRaw.enumerated().map { i, c in
                                        RemoteComment(author: c.0, text: cns[i] ?? c.1, time: Self.relTime(c.2)) }
                                    newComments = newRaw.enumerated().map { i, c in
                                        RemoteComment(author: c.0, text: cns[i + hotRaw.count] ?? c.1, time: Self.relTime(c.2)) }
                                }
                            }
                        }
                        commentsCompiling = false
                    }
                }
            }
        }
    }

    /// 粗提取正文纯文本(与 scout.py 同思路): 去脚本样式 -> 取 <article> -> 去标签 -> 保留段落
    private static func fetchArticleText(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "" }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (Macintosh) DBoard", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var html = ""
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data { html = String(decoding: d, as: UTF8.self) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 14)
        guard !html.isEmpty else { return "" }
        var h = html
        for tag in ["script", "style", "nav", "header", "footer", "aside", "form", "svg", "figure"] {
            h = h.replacingOccurrences(of: "(?is)<\(tag)[^>]*>.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        if let r = h.range(of: "(?is)<article[^>]*>.*?</article>", options: .regularExpression) {
            h = String(h[r])
        }
        h = h.replacingOccurrences(of: "(?i)</p>|<br[^>]*>|</h[1-6]>|</li>", with: "\n", options: .regularExpression)
        h = h.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#8217;": "'", "&#8216;": "'",
                        "&#8220;": "\u{201C}", "&#8221;": "\u{201D}", "&nbsp;": " ", "&#160;": " ", "&#38;": "&"]
        for (k, v) in entities { h = h.replacingOccurrences(of: k, with: v) }
        h = h.replacingOccurrences(of: "&[a-zA-Z#0-9]{2,8};", with: " ", options: .regularExpression)
        let lines = h.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces)
                     .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression) }
            .filter { $0.count > 2 }
        return String(lines.joined(separator: "\n\n").prefix(9000))
    }

    // ---------- 评论: HN(Algolia) / Reddit(.json), 按需抓取只存内存 ----------

    private func fetchComments() {
        guard !commentsFetched && !loadingComments else { return }
        guard item.source == "HN" || item.source == "RD" else { return }
        loadingComments = true
        DispatchQueue.global(qos: .userInitiated).async {
            let all: [(String, String, Double)] = item.source == "HN"
                ? Self.fetchHNComments(item.key)
                : Self.fetchRedditComments(item.url)
            let hot = all.prefix(3).map { RemoteComment(author: $0.0, text: $0.1, time: Self.relTime($0.2)) }
            let hotTexts = Set(hot.map { $0.text })
            let latest = all.sorted { $0.2 > $1.2 }
                .filter { !hotTexts.contains($0.1) }
                .prefix(2)
                .map { RemoteComment(author: $0.0, text: $0.1, time: Self.relTime($0.2)) }
            DispatchQueue.main.async {
                hotComments = hot
                newComments = Array(latest)
                loadingComments = false
                commentsFetched = true
            }
        }
    }

    private static func httpJSON(_ urlString: String) -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh) DBoard", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var result: Any? = nil
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data { result = try? JSONSerialization.jsonObject(with: d) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        return result
    }

    private static func stripCommentHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "(?i)<p>|<br[^>]*>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
        let ents = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&#x2F;": "/"]
        for (k, v) in ents { t = t.replacingOccurrences(of: k, with: v) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HN: Algolia items API, children 即按热度排列的一级评论
    private static func fetchHNComments(_ storyId: String) -> [(String, String, Double)] {
        guard let root = httpJSON("https://hn.algolia.com/api/v1/items/\(storyId)") as? [String: Any],
              let children = root["children"] as? [[String: Any]] else { return [] }
        var out: [(String, String, Double)] = []
        for c in children {
            guard let text = c["text"] as? String, !text.isEmpty,
                  let author = c["author"] as? String else { continue }
            let ts = (c["created_at_i"] as? Double) ?? 0
            out.append((author, String(stripCommentHTML(text).prefix(600)), ts))
            if out.count >= 12 { break }
        }
        return out
    }

    /// Reddit: permalink + .json, 默认 best 排序即热评
    private static func fetchRedditComments(_ permalink: String) -> [(String, String, Double)] {
        var link = permalink
        if link.hasSuffix("/") { link.removeLast() }
        guard let arr = httpJSON(link + ".json?limit=15") as? [Any], arr.count > 1,
              let listing = arr[1] as? [String: Any],
              let data = listing["data"] as? [String: Any],
              let children = data["children"] as? [[String: Any]] else { return [] }
        var out: [(String, String, Double)] = []
        for c in children {
            guard (c["kind"] as? String) == "t1",
                  let d = c["data"] as? [String: Any],
                  let body = d["body"] as? String, !body.isEmpty, body != "[deleted]",
                  let author = d["author"] as? String, author != "AutoModerator" else { continue }
            let ts = (d["created_utc"] as? Double) ?? 0
            out.append((author, String(body.prefix(600)), ts))
            if out.count >= 12 { break }
        }
        return out
    }

    private static func relTime(_ ts: Double) -> String {
        guard ts > 0 else { return "" }
        let diff = Date().timeIntervalSince1970 - ts
        if diff < 3600 { return "\(Int(diff / 60))分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600))小时前" }
        return "\(Int(diff / 86400))天前"
    }

    /// 单次 qodercli 纯文本调用(Efficient, 禁工具), 失败返回 nil
    private static func aiText(_ prompt: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/qodercli")
        proc.arguments = ["-m", "Efficient", "--tools", "", "-p", prompt]
        var env = ProcessInfo.processInfo.environment
        env["BUN_OPTIONS"] = "--preload=" + NSHomeDirectory() + "/.loongsuite-pilot/hooks/qodercli-token-intercept.mjs"
        env["PATH"] = (env["PATH"] ?? "") + ":" + NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(100)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.4) }
        if proc.isRunning { proc.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    @ViewBuilder
    private func commentRow(_ c: RemoteComment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("@\(c.author)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.current.textSecondary)
                if !c.time.isEmpty {
                    Text(c.time)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.current.textMuted)
                }
            }
            Text(c.text)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.current.textPrimary.opacity(0.78))
                .lineSpacing(2)
                .lineLimit(8)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.current.textTertiary.opacity(0.05)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 排名徽章 + 来源 + 热度
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(rank <= 3 ? Color.white : theme.current.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(rank <= 3
                        ? AnyShapeStyle(theme.current.accentGradient)
                        : AnyShapeStyle(theme.current.textTertiary.opacity(0.12))))

                Text(item.source)
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(item.sourceColor.opacity(0.85)))

                Spacer()

                HStack(spacing: 10) {
                    Label("\(item.score)", systemImage: "flame.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(hex: "#e8927c"))
                    if let c = item.comments, c > 0 {
                        Label("\(c)", systemImage: "bubble.right")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.current.textTertiary)
                    }
                }
            }

            // 中文标题(手写体, 主视觉)
            Text(item.displayTitle)
                .font(fm.font(17))
                .foregroundStyle(hovered ? theme.current.accentPrimary : theme.current.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // 一句话导读(AI 生成, 比标题多讲"为什么值得看")
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(fm.font(13))
                    .foregroundStyle(theme.current.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let desc = item.description, !desc.isEmpty {
                Text(desc)
                    .font(fm.font(12))
                    .foregroundStyle(theme.current.textSecondary)
                    .lineLimit(2)
            }

            // 展开的详情正文(AI 提炼的事实要点)
            if expanded, let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(fm.font(13))
                    .foregroundStyle(theme.current.textPrimary.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(theme.current.accentPrimary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(theme.current.accentPrimary.opacity(0.15)))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 展开的完整原文(点击时现场抓取, 不落盘)
            if showFull, let full = fullText {
                HStack(spacing: 5) {
                    if articleCompiling {
                        ProgressView().controlSize(.mini)
                        Text("AI 中文编译中，先看英文…")
                    } else {
                        Text("AI 中文编译 · 关键数字与产品名保留原文")
                    }
                }
                .font(fm.font(11))
                .foregroundStyle(theme.current.textTertiary)
                ScrollView {
                    Text(full)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.current.textPrimary.opacity(0.8))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 320)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(theme.current.textTertiary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(theme.current.separator.opacity(0.6)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if fetchFailed {
                Button(action: onOpen) {
                    Label("原文抓取失败（可能反爬/付费墙），点此用浏览器打开", systemImage: "exclamationmark.triangle")
                        .font(fm.font(11))
                        .foregroundStyle(Color(hex: "#e8927c"))
                }
                .buttonStyle(SmoothButtonStyle())
            }

            // 评论区(HN/Reddit): 随原文展开一起出现
            if (showFull || fetchFailed) && (loadingComments || !hotComments.isEmpty || !newComments.isEmpty) {
                VStack(alignment: .leading, spacing: 6) {
                    if loadingComments {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("评论加载中…").font(fm.font(11)).foregroundStyle(theme.current.textTertiary)
                        }
                    }
                    if !hotComments.isEmpty {
                        Text(commentsCompiling ? "💬 热评（AI 翻译中…）" : "💬 热评")
                            .font(fm.font(12))
                            .foregroundStyle(theme.current.accentPrimary)
                        ForEach(hotComments) { c in commentRow(c) }
                    }
                    if !newComments.isEmpty {
                        Text("🕐 最新")
                            .font(fm.font(12))
                            .foregroundStyle(theme.current.accentPrimary)
                        ForEach(newComments) { c in commentRow(c) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 英文原标题(弱化为脚注)
            if let cn = item.titleCn, !cn.isEmpty, cn != item.title {
                Text(item.title)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.current.textMuted)
                    .lineLimit(1)
            }

            // 元信息行
            HStack(spacing: 10) {
                if let time = item.time, !time.isEmpty {
                    Text(time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.current.textMuted)
                }
                if let sub = item.subreddit, !sub.isEmpty {
                    Text("r/\(sub)")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.current.textMuted)
                }
                Spacer()
                if hasDetail {
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { expanded.toggle() }
                    }) {
                        HStack(spacing: 3) {
                            Text(expanded ? "收起" : "展开详情")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        }
                        .font(fm.font(11))
                        .foregroundStyle(theme.current.accentPrimary)
                    }
                    .buttonStyle(SmoothButtonStyle())
                }
                Button(action: toggleFull) {
                    HStack(spacing: 3) {
                        if loadingFull {
                            ProgressView().controlSize(.mini)
                            Text(phase.isEmpty ? "处理中…" : phase)
                        } else {
                            Text(showFull ? "收起原文" : "展开原文")
                            Image(systemName: showFull ? "chevron.up" : "doc.text")
                        }
                    }
                    .font(fm.font(11))
                    .foregroundStyle(theme.current.accentPrimary)
                    .opacity(hovered || showFull || loadingFull ? 1 : 0.55)
                }
                .buttonStyle(SmoothButtonStyle())
                .disabled(loadingFull)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity))
                .shadow(color: .black.opacity(hovered ? 0.10 : 0.04), radius: hovered ? 11 : 5, y: hovered ? 4 : 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovered ? theme.current.accentPrimary.opacity(0.35) : theme.current.separator.opacity(0.5))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(hovered ? 1.008 : 1.0)
        .offset(y: hovered ? -1 : 0)
        .onTapGesture {
            if hasDetail {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { expanded.toggle() }
            } else {
                toggleFull()
            }
        }
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovered)
    }
}
