import SwiftUI
import Cocoa

// MARK: - ViewModel (查询语义 = audi LogsHistClient + /api/logs-hist/query)
// 重构纪律: 本文件的 API 与数据流冻结, UI 改版只许调用, 不许增删改这里的逻辑。

final class LogSearchViewModel: ObservableObject {

    /// JSON 弹窗里 traceId/spanId 值可单击附加(audi 无, 属既有资产)
    static let attachedFilterFields = ["traceId", "spanId"]
    static let allowedPageSizes = [20, 50, 100, 200]
    static let deepPageLimit = 10_000          // 页码 × 每页 ≤ 10000 (Kibana from+size 上限)
    static let maxSpan: TimeInterval = 15 * 86_400   // 生产日志保留 15 天

    // MARK: Published (表单)

    @Published var env: String {
        didSet { UserDefaults.standard.set(env, forKey: "dboard_logsearch_env") }
    }
    @Published var appName = ""
    @Published var kwInput = ""
    @Published var kwTags: [KWTag] = []
    /// 被排除的应用: 以 NOT app.name:x 参与服务端查询(侧栏应用菜单 × 操作)
    @Published private(set) var excludedApps: [String] = []
    /// 被"暂时隐藏"的应用: 不动查询, 仅本地隐藏当前页里它的行(侧栏菜单操作)
    @Published var mutedApps: Set<String> = []
    /// 只看 ERROR: 本地过滤, 只展示当前结果里的 ERROR 行(⌘E 可反复开关)
    @Published var errOnly = false
    /// 当前页结果里出现过的应用(按条数降序), 驱动侧栏应用列表
    @Published private(set) var detectedApps: [AppCount] = []
    @Published var start: Date
    @Published var end: Date
    @Published var activePreset: String? = "today"
    @Published var pageSize: Int {
        didSet {
            guard Self.allowedPageSizes.contains(pageSize) else {
                if pageSize != 50 { pageSize = 50 }
                return
            }
            UserDefaults.standard.set(pageSize, forKey: "dboard_logsearch_page_size")
            // 换每页条数回第 1 页重查(对齐 audi 换 size 即重置页码), 避免页边界错位
            if !rows.isEmpty { runQuery(1) }
        }
    }
    @Published var isPinned: Bool {
        didSet { UserDefaults.standard.set(isPinned, forKey: "dboard_logsearch_pinned") }
    }

    // MARK: Published (结果)

    @Published private(set) var page = 1
    @Published private(set) var rows: [LogEntry] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published var errorMsg: String?

    // MARK: Published (联想/历史)

    @Published private(set) var recentApps: [String] = []
    @Published private(set) var recentHistory: [LogHistoryEntry] = []

    private var reqID = 0   // 竞态防串(对齐 audi requestIdRef)

    // MARK: Init

    init() {
        self.env = UserDefaults.standard.string(forKey: "dboard_logsearch_env") ?? "prod"
        let storedSize = UserDefaults.standard.integer(forKey: "dboard_logsearch_page_size")
        self.pageSize = Self.allowedPageSizes.contains(storedSize) ? storedSize : 50
        self.isPinned = UserDefaults.standard.bool(forKey: "dboard_logsearch_pinned")
        let today = Self.presetRange("today")!
        self.start = today.0
        self.end = today.1
        self.recentApps = UserDefaults.standard.stringArray(forKey: "dboard_logsearch_recent_apps") ?? []
        // 历史存储换到 v3(结构对齐 audi {app, tags}); 旧格式直接作废, 不背迁移包袱
        if let data = UserDefaults.standard.data(forKey: "dboard_logsearch_history_v3"),
           let entries = try? JSONDecoder().decode([LogHistoryEntry].self, from: data) {
            self.recentHistory = entries
        }
    }

    // MARK: 派生

    var activeKeywords: [String] { kwTags.filter { !$0.disabled }.map(\.text) }
    var totalPages: Int { max(1, Int((Double(total) / Double(max(pageSize, 1))).rounded(.up))) }

    // MARK: 时间预设 (audi timePreset 语义)

    static let presets: [(key: String, label: String)] = [
        ("m5", "最近5分钟"), ("h1", "最近1小时"), ("today", "今天"),
        ("yesterday", "昨天"), ("d3", "最近3天"), ("d15", "最近15天"),
    ]

    static func presetRange(_ key: String) -> (Date, Date)? {
        let now = Date()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        switch key {
        case "m5": return (now.addingTimeInterval(-300), now)
        case "h1": return (now.addingTimeInterval(-3600), now)
        case "today": return (dayStart, dayStart.addingTimeInterval(86_399))
        case "yesterday":
            let y = cal.date(byAdding: .day, value: -1, to: dayStart)!
            return (y, y.addingTimeInterval(86_399))
        case "d3", "d15":
            let n = key == "d3" ? 3 : 15
            let s = cal.date(byAdding: .day, value: -(n - 1), to: dayStart)!
            return (s, dayStart.addingTimeInterval(86_399))
        default: return nil
        }
    }

    func applyTemplate(app: String?, env: String?, tags: [String]) {
        if let e = env, !e.isEmpty { self.env = e }
        if let a = app, !a.isEmpty { appName = a }
        kwInput = ""
        kwTags = tags.map { KWTag(text: $0) }
    }

    func applyPreset(_ key: String) {
        guard let r = Self.presetRange(key) else { return }
        start = r.0
        end = r.1
        activePreset = key
    }

    /// 用户手动改时间(DatePicker): 预设高亮熄灭; 非法区间立刻提示(校验与 runQuery 同一把尺)
    func setCustomTime(_ newStart: Date? = nil, _ newEnd: Date? = nil) {
        if let newStart { start = newStart }
        if let newEnd { end = newEnd }
        activePreset = nil
        if start >= end {
            errorMsg = "结束时间必须晚于开始时间"
        } else if end.timeIntervalSince(start) > Self.maxSpan {
            errorMsg = "时间范围最长 15 天(生产日志保留期)"
        } else {
            errorMsg = nil
        }
    }

    // MARK: Tag 操作 (audi upsertTag/toggleTag/removeTag)

    static func upsert(_ tags: [KWTag], _ text: String) -> [KWTag] {
        guard !text.isEmpty else { return tags }
        if tags.contains(where: { $0.text == text }) {
            return tags.map { $0.text == text ? KWTagEnable($0) : $0 }
        }
        return tags + [KWTag(text: text)]
    }

    func addTag(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        kwTags = Self.upsert(kwTags, t)
        kwInput = ""
    }

    func toggleTag(_ id: UUID) {
        kwTags = kwTags.map { $0.id == id ? KWTagToggle($0) : $0 }
        scheduleRerun()
    }

    func removeTag(_ id: UUID) {
        kwTags.removeAll { $0.id == id }
        scheduleRerun()
    }

    /// 条件变化后自动重查(只在已发起过查询后生效; 0.3s 防抖连点)
    private var rerunTimer: Timer?
    private var hasSearched = false
    private func scheduleRerun() {
        guard hasSearched else { return }
        rerunTimer?.invalidate()
        rerunTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.runQuery(1)
        }
    }

    // MARK: 查询 (audi runQuery)

    @discardableResult
    func runQuery(_ targetPage: Int = 1, overrideTags: [KWTag]? = nil) -> Bool {
        // 输入框里未回车的关键词照常参与本次查询, 成功后晋升为正式 tag(对齐 audi pending 语义)
        let pending = kwInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = overrideTags ?? kwTags
        var merged = tags.filter { !$0.disabled }.map(\.text)
        if !pending.isEmpty, !merged.contains(pending) { merged.append(pending) }
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !merged.isEmpty || !app.isEmpty else {
            errorMsg = "请输入至少一个关键词或应用名"
            return false
        }
        if !app.isEmpty, !Self.isValidApp(app) {
            errorMsg = "应用名非法(1-40 位字母数字/._-)"
            return false
        }
        if merged.contains(where: { $0.utf16.count > 200 }) {
            errorMsg = "单个关键词长度不能超过 200"
            return false
        }
        guard start < end else {
            errorMsg = "结束时间必须晚于开始时间"
            return false
        }
        if end.timeIntervalSince(start) > Self.maxSpan {
            errorMsg = "时间范围最长 15 天(生产日志保留期)"
            return false
        }
        if targetPage * pageSize > Self.deepPageLimit {
            errorMsg = "深翻页超限(页码 × 每页 ≤ 10000), 请缩小时间范围或加关键词"
            return false
        }

        perform(queryStr: Self.buildLuceneQuery(app: app, tags: merged, excluded: excludedApps),
                page: targetPage,
                promote: pending.isEmpty ? nil : (tags, pending),
                remember: (app, merged))
        return true
    }

    // MARK: 应用操作 (侧栏应用列表: 只看它 / 暂时隐藏 / 排除 / 恢复)

    /// 暂时隐藏/恢复该应用的行(纯本地视图过滤, 不重新查询)
    func toggleMute(_ app: String) {
        if mutedApps.contains(app) { mutedApps.remove(app) }
        else { mutedApps.insert(app) }
    }

    /// 只看该应用(保留关键词与排除项)
    func appDrill(_ app: String) {
        guard !app.isEmpty, app != "unknown" else { return }
        // 不含就别动 Set: @Published 的写操作即使内容没变也会广播一次全量重排
        if mutedApps.contains(app) { mutedApps.remove(app) }
        appName = app
        runQuery(1)
    }

    /// 把该应用排除出结果(NOT 子句服务端重查)
    func excludeApp(_ app: String) {
        guard !app.isEmpty, !excludedApps.contains(app) else { return }
        excludedApps.append(app)
        runQuery(1)
    }

    /// 恢复被排除的应用
    func restoreApp(_ app: String) {
        guard excludedApps.contains(app) else { return }
        excludedApps.removeAll { $0 == app }
        runQuery(1)
    }

    /// 应用名固化入口(输入框回车/联想选中): 变成筛选态并查询
    func setApp(_ name: String) {
        appName = name
        runQuery(1)
    }

    /// 移除应用过滤并重查
    func clearApp() {
        appName = ""
        if !rows.isEmpty { runQuery(1) }
    }

    /// 点词钻取(对齐 audi drill): 词上 tag 并立即重查
    func drill(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        let next = Self.upsert(kwTags, w)
        kwTags = next
        runQuery(1, overrideTags: next)
    }

    /// JSON 弹窗里 traceId/spanId 值单击 → 追加 `field:value` 原生透传 tag
    func attachFilter(field: String, value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.attachedFilterFields.contains(field), !v.isEmpty else { return }
        addTag("\(field):\(v)")
        runQuery(1)
    }

    /// 查看某行前后 5 分钟: 表单切到"仅该应用 + ±5min"(所见即所查), 不记历史
    func searchAround(_ entry: LogEntry) {
        guard let center = Self.parseLogDate(entry.timestamp) else {
            errorMsg = "无法识别这条日志的时间"
            return
        }
        appName = (entry.app.isEmpty || entry.app == "unknown") ? "" : entry.app
        kwTags = []
        kwInput = ""
        start = center.addingTimeInterval(-300)
        end = center.addingTimeInterval(300)
        activePreset = nil
        let app = appName
        perform(queryStr: app.isEmpty ? "*"
                     : Self.buildLuceneQuery(app: app, tags: [], excluded: excludedApps),
                page: 1, promote: nil, remember: nil)
    }

    /// Ctrl+Shift+L: 剪贴板原文作为一个短语 tag, 前后 2 小时直接查
    func searchClipboardText(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        appName = ""
        kwTags = [KWTag(text: value)]
        kwInput = ""
        let now = Date()
        start = now.addingTimeInterval(-7200)
        end = now.addingTimeInterval(7200)
        activePreset = nil
        runQuery(1, overrideTags: kwTags)
    }

    func debugSearch(_ q: String) {
        kwTags = [KWTag(text: q)]
        kwInput = ""
        runQuery(1, overrideTags: kwTags)
    }

    /// 历史重跑(对齐 audi applyHistory): 恢复 app+tags 并立即查
    func applyHistory(_ entry: LogHistoryEntry) {
        appName = entry.app
        kwTags = entry.tags.map { KWTag(text: $0) }
        kwInput = ""
        runQuery(1, overrideTags: kwTags)
    }

    func clearHistory() {
        recentHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: "dboard_logsearch_history_v3")
    }

    func rememberApp(_ name: String) {
        let app = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { return }
        recentApps.removeAll { $0 == app }
        recentApps.insert(app, at: 0)
        if recentApps.count > 10 { recentApps = Array(recentApps.prefix(10)) }
        UserDefaults.standard.set(recentApps, forKey: "dboard_logsearch_recent_apps")
    }

    private func pushHistory(app: String, tags: [String]) {
        let entry = LogHistoryEntry(app: app, tags: tags)
        recentHistory.removeAll { $0.dedupKey == entry.dedupKey }
        recentHistory.insert(entry, at: 0)
        if recentHistory.count > 8 { recentHistory = Array(recentHistory.prefix(8)) }
        guard let data = try? JSONEncoder().encode(recentHistory) else { return }
        UserDefaults.standard.set(data, forKey: "dboard_logsearch_history_v3")
    }

    // MARK: 查询串构建 (audi buildLuceneQuery 逐字对齐 + 应用排除扩展)

    static func buildLuceneQuery(app: String, tags: [String], excluded: [String] = []) -> String {
        var parts: [String] = []
        if !app.isEmpty { parts.append("app.name:\(app)") }
        for t in tags {
            // 已含 Lucene 语法(:、AND、OR)的原样透传; 否则短语查询防分词噪音
            let hasOp = t.range(of: #"\s(AND|OR)\s+"#, options: [.regularExpression, .caseInsensitive]) != nil
            if t.contains(":") || hasOp {
                parts.append(t)
            } else {
                let esc = t.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                parts.append("\"\(esc)\"")
            }
        }
        // 排除的应用走服务端 NOT(而非前端假过滤), 分页 total 保持诚实
        for e in excluded.sorted() where !e.isEmpty {
            let esc = e.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("NOT app.name:\(esc)")
        }
        return parts.joined(separator: " AND ")
    }

    private static func isValidApp(_ app: String) -> Bool {
        let ns = app as NSString
        return appRegex.matches(in: app, range: NSRange(location: 0, length: ns.length))
            .contains { $0.range == NSRange(location: 0, length: ns.length) }
    }
    private static let appRegex = try! NSRegularExpression(pattern: #"[\w.\-]{1,40}"#)

    // MARK: 执行

    private func perform(queryStr: String, page p: Int,
                         promote: (tags: [KWTag], pending: String)?,
                         remember: (app: String, tags: [String])?) {
        reqID += 1
        let token = reqID
        loading = true
        errorMsg = nil
        hasSearched = true
        // rows 不清空: 清空 → 整个 List 拆掉换成 spinner → 回填, 三次 teardown/rebuild
        // 串在一帧里就是"卡一下再跳"。留着上一次结果 + 顶部线性进度条 + 轻微压暗,
        // 新数据到达时只做一次原位替换。
        let envVal = env
        let sizeVal = pageSize
        let sStr = Self.serverFmt.string(from: start)
        let eStr = Self.serverFmt.string(from: end)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let parsed = self.runHTTP(queryStr: queryStr, env: envVal,
                                      start: sStr, end: eStr, page: p, size: sizeVal)
            DispatchQueue.main.async {
                guard self.reqID == token else { return }   // 竞态防串
                self.loading = false
                if let err = parsed.error {
                    self.errorMsg = err
                    self.rows = []
                    self.total = 0
                    return
                }
                if let promote {
                    self.kwTags = Self.upsert(promote.tags, promote.pending)
                    self.kwInput = ""
                }
                self.rows = parsed.entries
                self.total = parsed.total
                self.page = p
                // 应用统计: 只反映当前页(dubbo 拆行可能同 app 多行, 计数按行)
                var counts: [String: Int] = [:]
                for e in parsed.entries where !e.app.isEmpty && e.app != "unknown" {
                    counts[e.app, default: 0] += 1
                }
                self.detectedApps = counts.map { AppCount(name: $0.key, count: $0.value) }
                    .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
                if let remember, p == 1 {
                    self.pushHistory(app: remember.app, tags: remember.tags)
                    if !remember.app.isEmpty { self.rememberApp(remember.app) }
                }
            }
        }
    }

    // MARK: HTTP (直接调日志平台 kibana/query, 与 audi 走同一网关能力)

    private static let baseURL = "https://pre-i0-nczgateway.tmallyc-inc.com/gateway/i0"
    private static let tokenPath = "/Users/zz/work/tmyc/llmWiki/projects/auto/.token"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30
        cfg.httpShouldUsePipelining = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private func loadToken() -> String? {
        (try? String(contentsOfFile: Self.tokenPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runHTTP(queryStr: String, env: String, start: String, end: String,
                         page: Int, size: Int) -> ParseResult {
        guard let token = loadToken(), !token.isEmpty else {
            return ParseResult(entries: [], total: 0, error: "未找到日志平台凭证")
        }
        let body: [String: Any] = [
            "env_type": env, "log_type": 1,
            "start_time": start, "end_time": end, "query_str": queryStr,
            "page": page, "size": size,
        ]
        guard let url = URL(string: "\(Self.baseURL)/logmanager/api/v1/kibana/query") else {
            return ParseResult(entries: [], total: 0, error: "日志平台地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "content-type")
        req.setValue("https://x.tmallyc-inc.com", forHTTPHeaderField: "origin")
        req.setValue("https://x.tmallyc-inc.com", forHTTPHeaderField: "referer")
        req.setValue(token, forHTTPHeaderField: "token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        // 同步等待(在后台线程), 复用 URLSession 连接池 (keep-alive)
        let semaphore = DispatchSemaphore(value: 0)
        var result: ParseResult?
        let task = Self.session.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = ParseResult(entries: [], total: 0, error: error.localizedDescription)
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = ParseResult(entries: [], total: 0, error: "HTTP \(http.statusCode)")
            } else if let data, let str = String(data: data, encoding: .utf8) {
                result = Self.parseJSON(str)
            } else {
                result = ParseResult(entries: [], total: 0, error: "日志平台未返回数据")
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            task.cancel()
            return ParseResult(entries: [], total: 0, error: "查询超时")
        }
        return result ?? ParseResult(entries: [], total: 0, error: "未知错误")
    }

    // MARK: 解析

    struct ParseResult {
        let entries: [LogEntry]
        let total: Int
        let error: String?
    }

    static func parseJSON(_ raw: String) -> ParseResult {
        let jsonStr = raw.firstIndex(of: "{").map { String(raw[$0...]) } ?? raw
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = obj["data"] as? [String: Any] else {
            return ParseResult(entries: [], total: 0, error: "返回数据格式异常")
        }
        let total = (dataDict["total"] as? Int) ?? 0
        guard let list = dataDict["result_list"] as? [[String: Any]] else {
            return ParseResult(entries: [], total: total, error: nil)
        }
        var entries: [LogEntry] = []
        for item in list {
            let message = (item["message"] as? String) ?? ""
            let appName = (item["app"] as? [String: Any])?["name"] as? String
                ?? (item["app_name"] as? String) ?? "unknown"
            let logInfo = item["log"] as? [String: Any]
            let logTime = logInfo?["time"] as? String
                ?? (item["time"] as? String) ?? ""
            let filePath = (logInfo?["file"] as? [String: Any])?["path"] as? String ?? ""
            let logicalMessages: [String]
            if filePath.hasSuffix("/dubbo-access.log"), message.contains("\n") {
                logicalMessages = message.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else {
                logicalMessages = [message]
            }
            for logicalMessage in logicalMessages {
                let flat = logicalMessage.replacingOccurrences(of: "\n", with: " ")
                let blocks = LogJSONBlock.extract(from: logicalMessage)
                entries.append(LogEntry(
                    app: appName,
                    timestamp: dubboTimestamp(in: logicalMessage) ?? logTime,
                    level: extractLevel(logicalMessage),
                    detail: logicalMessage,
                    flatText: flat,
                    isHuge: LogEntry.judgeHuge(flat, blocks: blocks),
                    traceId: extractTraceId(logicalMessage),
                    jsonBlocks: blocks
                ))
            }
        }
        return ParseResult(entries: entries, total: total, error: nil)
    }

    private static let dubboTimestampRegex = try! NSRegularExpression(
        pattern: #"\[DUBBO\]\s+\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+)"#)

    private static func dubboTimestamp(in message: String) -> String? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = dubboTimestampRegex.firstMatch(in: message, range: range),
              let valueRange = Range(match.range(at: 1), in: message) else { return nil }
        return String(message[valueRange])
    }

    /// 对齐 audi extractLevel: 无结构化字段, 从消息正文正则匹配级别
    private static let levelRegex = try! NSRegularExpression(
        pattern: #"\b(ERROR|WARN|WARNING|INFO|DEBUG|FATAL|TRACE)\b"#)
    private static let traceRegex = try! NSRegularExpression(
        pattern: #"traceId[=:]\s*"?([0-9a-fA-F]{16,})"?"#)

    private static func extractLevel(_ msg: String) -> String {
        let firstLine = msg.components(separatedBy: .newlines).first ?? msg
        let ns = NSRange(firstLine.startIndex..., in: firstLine)
        guard let m = levelRegex.firstMatch(in: firstLine, range: ns),
              let r = Range(m.range, in: firstLine) else { return "" }
        let lv = String(firstLine[r]).uppercased()
        return lv == "WARNING" ? "WARN" : lv
    }

    private static func extractTraceId(_ msg: String) -> String? {
        let ns = NSRange(msg.startIndex..., in: msg)
        guard let m = traceRegex.firstMatch(in: msg, range: ns),
              let r = Range(m.range(at: 1), in: msg) else { return nil }
        return String(msg[r])
    }

    private static func parseLogDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
                        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static let serverFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
