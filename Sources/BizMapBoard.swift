import SwiftUI
import AppKit
import Network

// MARK: - BizMap 业务地图看板
// 数据源: ~/.claude/bizmap-cache.json (由 wiki projects/业务地图/gen_bizmap.py 生成)
// 定位: 接需求时的路由器 —— 输关键词 → 高亮该查哪个服务 → 直达作战地图文档

// MARK: - 数据模型 (对齐 bizmap-cache.json)

struct BizDItem: Codable, Identifiable {
    let id: String          // D001
    let projects: [String]
    let title: String
    let status: String
}

struct BizFlowStep: Codable, Identifiable {
    let t: String       // MM-dd HH:mm
    let from: String
    let to: String
    let by: String
    // 分钟级时间戳下同一需求会出现多次来回跳转(实测有 17:46 跳三次),
    // 故 id 必须含全四元素 + 分隔符, 否则 ForEach 会因 id 重复错位
    var id: String { "\(t)|\(from)|\(to)|\(by)" }
}

struct BizDelivDoc: Codable, Identifiable {
    let t: Int          // 交付物阶段: 1方案/2设计/3开发/4测试
    let url: String
    var id: String { url }
}

struct BizDelivFile: Codable, Identifiable {
    let name: String
    let url: String
    var id: String { url }
}

struct BizPRDItem: Codable, Identifiable {
    let id: Int             // PRD 系统 id
    let no: String          // R2607030033
    let name: String
    let code: String        // SJWC / KFZ / CSZ …
    let status: String      // 中文状态名
    var completedForMe: Bool { code == "CPYSWC" || status == "承接人验收完成" }
    let pri: String?
    let dev: String?
    let scopes: [String]    // pending / mine / dept
    let services: [String]  // AI 语义标注的目标服务, 空 = 未路由
    let note: String?       // 标注依据
    let docs: [String]      // 钉钉需求文档链接(交付物)
    let url: String         // PRD 明细页
    // 以下为详情字段(旧缓存可缺)
    let desc: String?           // 需求正文
    let value: String?          // 业务价值
    let complexity: String?     // AI 复杂度评分 1~3
    let confidence: String?     // verified / evidenced / inferred
    let submitter: String?
    let owner: String?
    let pending: String?        // 当前滞留人
    let devTeam: [String]?
    let testTeam: [String]?
    let submitTime: String?
    let onlineTime: String?
    let tags: String?
    let flow: [BizFlowStep]?    // 状态流转记录
    let delivDocs: [BizDelivDoc]?    // 官方交付物链接(方案/设计/开发/测试)
    let files: [BizDelivFile]?       // 交付物附件(设计文档md等)
    let devProjects: [String]?       // 开发交付声明的 仓:分支 清单(官方事实源)
}

struct BizService: Codable, Identifiable {
    let name: String
    let tier: String
    let c: Int              // 近半年 commits
    let st: String          // active / semi / dead
    let pkg: String
    let desc: String
    let mapLevel: String    // L0 / L2
    let routing: [String]
    let related: [String]
    let branch: String
    let div: String
    let doc: String
    let dItems: [BizDItem]
    let pItems: [BizPRDItem]?   // 旧缓存无此字段, 可选保解码兼容
    let recent: String?         // AI 生成的近期变化摘要
    let newFacades: Int?        // 近期新增 Facade 数
    var id: String { name }
    var prds: [BizPRDItem] { pItems ?? [] }
}

struct BizGroup: Codable { let key: String; let label: String }
struct BizRoute: Codable { let kw: String; let primary: String; let secondary: String }
struct BizPhase: Codable { let done: [String]; let current: String; let rest: [String] }

struct BizMapCache: Codable {
    let generated: String
    let phase: BizPhase
    let groups: [BizGroup]
    let services: [BizService]
    let routes: [BizRoute]
    let dItemsAll: [BizDItem]
    let prdGenerated: String?
    let prdItemsAll: [BizPRDItem]?
}

// MARK: - ViewModel

enum BizPerspective: Hashable { case services, requirements }

/// 需求流组内分栏: 一次只看一栏, 告别 27 条平铺
enum ReqTab: String, CaseIterable {
    case notStarted = "待开始"
    case inProgress = "进行中"
    case others = "其他"
}

final class BizMapViewModel: ObservableObject {
    @Published var cache: BizMapCache?
    @Published var query: String = ""
    @Published var selected: BizService?
    @Published var loadError: String?
    @Published var regenerating = false
    @Published var genError: String?   // 生成器失败不能静默: 老数据照常展示, 但 header 要亮警告
    @Published var refreshProgress: (current: Int, total: Int, name: String, status: String)?
    private var progressTimer: Timer?
    @Published var perspective: BizPerspective = .services   // 服务视角 / 需求视角
    @Published var reqTab: ReqTab = .notStarted                // 需求流当前分栏
    @Published var expandedPRD: Set<Int> = []                  // 需求行展开详情
    @Published var syncStatus: [String: String] = [:]          // name → "synced"/"unsynced"/"syncing"/"error"
    @Published var syncChanged: Set<String> = []               // 已同步但表内字段落后于 PRD 的需求
    @Published var showTableProjects = false
    @Published var tableProjects: [TableProject] = []
    @Published var tableProjectsLoading = false
    @Published var tableProjectsLoaded = false

    func tableProjectRequirement(_ project: TableProject) -> BizPRDItem? {
        if let id = project.requirementId { return prdItems.first { $0.id == id } }
        let name = project.name.filter { !$0.isWhitespace }
        guard !name.isEmpty,
              tableProjects.filter({ $0.name.filter { !$0.isWhitespace } == name }).count <= 1 else { return nil }
        let matches = prdItems.filter { $0.name.filter { !$0.isWhitespace } == name }
        return matches.count == 1 ? matches[0] : nil
    }

    func loadTableProjects() {
        guard !tableProjectsLoading else { return }
        tableProjectsLoading = true
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let raw = self.runSyncScript(args: ["list-mine"])
            if let data = raw.data(using: .utf8),
               let resp = try? JSONDecoder().decode(TableProjectsResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.tableProjects = resp.items
                    self.tableProjectsLoading = false
                    self.tableProjectsLoaded = true
                }
            } else {
                DispatchQueue.main.async { self.tableProjectsLoading = false }
            }
        }
    }

    /// 上次 list-mine 落盘的缓存(脚本写入), 启动即读 → 弹窗秒开, 后台再静默刷新
    func readTableProjectsCache() {
        guard tableProjects.isEmpty,
              let data = try? Data(contentsOf: URL(
                fileURLWithPath: NSString(string: "~/.claude/dboard-table-projects.json").expandingTildeInPath)),
              let resp = try? JSONDecoder().decode(TableProjectsCache.self, from: data) else { return }
        tableProjects = resp.items
        tableProjectsLoaded = true
    }
    @Published var syncAllRunning = false
    @Published var authExpired = false      // PRD 登录态失效: 面板亮红色授权横幅, 拒绝静默空数据
    @Published var showCookieSheet = false
    @Published var cookieInput = ""
    @Published var cookieBusy = false
    @Published var cookieError: String?
    @Published var cookieFDAHint = false   // 提取失败因 TCC 权限 → 引导开完全磁盘访问
    private var bridgeCandidate: String?
    private var pendingBridgeRefresh = false
    private var audiSession: HTTPCookie?

    /// ⌃Q 已收到的顶级域会话也适用于 ReqFlow；后到的 Audi 投递会重新验证桥接头。
    func receiveAudiSession(_ cookie: HTTPCookie) {
        guard cookie.domain == ".tmallyc.com" || cookie.domain == "tmallyc.com" else { return }
        audiSession = cookie
        if let header = try? String(contentsOfFile: CookieBridgeServer.spoolPath, encoding: .utf8) {
            receiveBridgedCookie(header.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Chrome 扩展投递后自动验证并切换 ReqFlow 登录态；旧会话不覆盖新会话。
    func receiveBridgedCookie(_ rawHeader: String) {
        let parts = rawHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { audiSession == nil || !$0.hasPrefix("ac-session-id=") }
        let session = audiSession.map { "ac-session-id=\($0.value)" }
        let header = (parts + (session.map { [$0] } ?? [])).joined(separator: "; ")
        guard !header.isEmpty else { return }
        let current = (try? String(contentsOfFile: prdCookiePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if header == current {
            let cookieTime = (try? FileManager.default.attributesOfItem(atPath: prdCookiePath))?[.modificationDate] as? Date
            let cacheTime = (try? FileManager.default.attributesOfItem(atPath: cachePath))?[.modificationDate] as? Date
            if let cookieTime, cookieTime > (cacheTime ?? .distantPast) { refreshRequirements() }
            return
        }
        guard header != bridgeCandidate else { return }
        bridgeCandidate = header
        guard let url = cookieProbeURL else { bridgeCandidate = nil; return }
        var req = URLRequest(url: url)
        req.setValue(header, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            let valid = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
                && (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["success"] as? Bool == true
            let result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            AppReleaseWindowController.shared.recordDiagnostic(
                "reqflow auth verified=\(valid) http=\((response as? HTTPURLResponse)?.statusCode ?? 0) " +
                "hasSession=\(header.hasPrefix("session-id=") || header.contains("; session-id=")) message=\(String((result?["message"] as? String ?? "").prefix(100)))"
            )
            DispatchQueue.main.async {
                guard let self, self.bridgeCandidate == header else { return }
                self.bridgeCandidate = nil
                guard valid else { return }
                let saved = (try? String(contentsOfFile: self.prdCookiePath, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard saved != header else { self.authExpired = false; return }
                do {
                    try FileManager.default.createDirectory(atPath: (self.prdCookiePath as NSString).deletingLastPathComponent,
                                                            withIntermediateDirectories: true)
                    try header.write(toFile: self.prdCookiePath, atomically: true, encoding: .utf8)
                } catch {
                    self.cookieError = "Chrome 登录态保存失败: \(error.localizedDescription)"
                    return
                }
                self.authExpired = false
                self.showCookieSheet = false
                if self.regenerating { self.pendingBridgeRefresh = true }
                else { self.refreshRequirements() }
            }
        }.resume()
    }

    private let cachePath = NSString(string: "~/.claude/bizmap-cache.json").expandingTildeInPath
    private let refreshScript = NSString(string: "~/work/code/other/DBoard/refresh_prd.sh").expandingTildeInPath
    private let genScript = NSString(string: "~/Documents/one/projects/业务地图/gen_bizmap.py").expandingTildeInPath
    private let syncScript = NSString(string: "~/work/code/other/DBoard/sync_to_aitable.sh").expandingTildeInPath
    private let refreshServicesScript = NSString(string: "~/work/code/other/DBoard/refresh_services.sh").expandingTildeInPath
    private let progressPath = NSString(string: "~/.claude/bizmap-refresh-progress.json").expandingTildeInPath

    init(loadBackgroundData: Bool = true, projectStore: DevelopmentProjectStore = DevelopmentProjectStore(),
         statusSession: URLSession = .shared,
         statusCookie: @escaping () -> String? = { BizMapViewModel.readStatusCookie() },
         statusRefresh: (() -> Void)? = nil) {
        self.statusSession = statusSession
        self.statusCookie = statusCookie
        self.statusRefresh = statusRefresh
        self.projectStore = projectStore
        developmentProjectSnapshots = projectStore.records
        guard loadBackgroundData else { return }
        // 扩展可能在 DBoard 启动前已投递：恢复最近的桥接登录态。
        if let header = try? String(contentsOfFile: CookieBridgeServer.spoolPath, encoding: .utf8),
           !header.isEmpty {
            receiveBridgedCookie(header.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // 项目表"我参与的": 启动即读上次缓存秒开, 短暂延迟后后台静默刷新(错峰, 不抢启动资源)
        readTableProjectsCache()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.loadTableProjects()
        }
    }

    func load() {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: cachePath))
            cache = try JSONDecoder().decode(BizMapCache.self, from: data)
            loadError = nil
        } catch {
            loadError = "读取 bizmap-cache.json 失败: \(error.localizedDescription)"
        }
    }

    /// 不依赖当前视角：桥接会话到达时即使窗口未打开也刷新 ReqFlow。
    func refreshRequirements() {
        guard !regenerating else { pendingBridgeRefresh = true; return }
        regenerating = true
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let failure = self.runScript(self.refreshScript, isShell: true)
            if failure == nil {
                let _ = self.runScript(self.genScript, isShell: false)
            }
            DispatchQueue.main.async {
                let retryWithBridge = self.pendingBridgeRefresh
                self.pendingBridgeRefresh = false
                self.genError = retryWithBridge ? nil : failure
                self.authExpired = !retryWithBridge && (failure ?? "").contains("cookie 过期")
                self.load()
                self.regenerating = false
                self.checkSyncStatus()
                for item in self.myActive { self.loadDeliverableStatus(reqId: item.id) }
                if retryWithBridge { self.refreshRequirements() }
            }
        }
    }

    /// 手动刷新按当前视角执行；授权变化则直接调用 refreshRequirements。
    func regenerate() {
        guard !regenerating else { return }
        if perspective == .requirements {
            refreshRequirements()
        } else {
            regenerating = true
            // 服务视角：后台跑 refresh_services.sh + 轮询进度
            startProgressPolling()
            DispatchQueue.global().async { [weak self] in
                guard let self = self else { return }
                let failure = self.runScript(self.refreshServicesScript, isShell: true)
                DispatchQueue.main.async {
                    self.stopProgressPolling()
                    self.genError = failure
                    self.load()
                    self.regenerating = false
                    self.refreshProgress = nil
                    if self.pendingBridgeRefresh {
                        self.pendingBridgeRefresh = false
                        self.refreshRequirements()
                    }
                }
            }
        }
    }

    private func startProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let data = FileManager.default.contents(atPath: self.progressPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let current = json["current"] as? Int ?? 0
            let total = json["total"] as? Int ?? 1
            let name = json["name"] as? String ?? ""
            let status = json["status"] as? String ?? ""
            self.refreshProgress = (current, total, name, status)
        }
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
        try? FileManager.default.removeItem(atPath: progressPath)
    }

    private func runScript(_ path: String, isShell: Bool) -> String? {
        let p = Process()
        if isShell {
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [path]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [path]
        }
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.qoderwork/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        do {
            try p.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "退出码 \(p.terminationStatus)" + (msg.isEmpty ? "" : "：\(String(msg.prefix(120)))")
        } catch {
            return "启动失败: \(error.localizedDescription)"
        }
    }

    /// 需求路由: 返回 (首查集合, 次查集合) —— 与 HTML 版 route() 同一套逻辑
    var routeHits: (primary: Set<String>, secondary: Set<String>) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let c = cache else { return ([], []) }
        var p = Set<String>(), s = Set<String>()
        for r in c.routes where r.kw.lowercased().contains(q) {
            p.insert(r.primary)
            if !r.secondary.isEmpty { s.insert(r.secondary) }
        }
        for svc in c.services {
            if svc.routing.contains(where: { $0.lowercased().contains(q) }) || svc.name.lowercased().contains(q) {
                p.insert(svc.name)
            } else if svc.desc.lowercased().contains(q) {
                s.insert(svc.name)
            }
        }
        s.subtract(p)
        return (p, s)
    }

    var l2Count: Int { cache?.services.filter { $0.mapLevel == "L2" }.count ?? 0 }
    /// 关联 D 单总数(含待开始) —— 与卡片 D× 角标同口径, 避免同屏两个数字两套含义
    var dCount: Int { cache?.dItemsAll.count ?? 0 }
    var prdItems: [BizPRDItem] { cache?.prdItemsAll ?? [] }

    // MARK: PRD 快照新鲜度
    // 面板上的 ↻ 只重拼旧快照; 真正拉取需 AI(浏览器登录态 + 语义标注),
    // 所以必须把"数据多旧"摆到台面上, 不能靠人记得去问。
    var prdAgeDays: Int? {
        guard let g = cache?.prdGenerated, !g.isEmpty else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        guard let d = fmt.date(from: g) else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }

    /// nil=无快照 / 0=新鲜 / 1=偏旧(提醒) / 2=太旧(警告)
    var prdStaleLevel: Int {
        guard let d = prdAgeDays else { return prdItems.isEmpty ? -1 : 0 }
        if d >= 4 { return 2 }
        if d >= 2 { return 1 }
        return 0
    }

    /// 把刷新指令送到剪贴板: 你粘给 AI 就行, 省掉回忆措辞这一步
    func copyRefreshPrompt() -> String {
        let text = "刷新PRD"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    // MARK: 需求视角: 按名称/编号/开发/已声明工程/状态筛选
    var filteredPRD: [BizPRDItem] {
        let base = prdItems
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { p in
            p.name.lowercased().contains(q) || p.no.lowercased().contains(q)
                || (p.dev ?? "").lowercased().contains(q)
                || p.status.contains(q)
                || developmentProjectSnapshots[p.id]?.projects.contains {
                    $0.project.lowercased().contains(q) || ($0.branch?.lowercased().contains(q) ?? false)
                } == true
        }
    }

    /// 我参与的(非终态) —— 需求流首屏英雄区, 永远置顶
    var myActive: [BizPRDItem] { prdItems.filter { $0.scopes.contains("mine") && !$0.completedForMe }.sorted(by: Self.prdSort) }
    var myCompleted: [BizPRDItem] { prdItems.filter { $0.scopes.contains("mine") && $0.completedForMe }.sorted(by: Self.prdSort) }

    /// 组内分栏(排除"我的"避免重复): 待开始 / 进行中 / 其他
    func tabItems(_ t: ReqTab) -> [BizPRDItem] {
        let rest = prdItems.filter { !$0.scopes.contains("mine") }
        let notStarted: Set<String> = ["YTJ", "YJS", "SJWC"]
        let inProgress: Set<String> = ["KFZ", "CSZ"]
        var out: [BizPRDItem]
        switch t {
        case .notStarted: out = rest.filter { notStarted.contains($0.code) }
        case .inProgress: out = rest.filter { inProgress.contains($0.code) }
        case .others: out = rest.filter { !notStarted.contains($0.code) && !inProgress.contains($0.code) }
        }
        return out.sorted(by: Self.prdSort)
    }

    /// 排序: 可行动优先(待接在前) → P0 → 新编号
    static func prdSort(_ a: BizPRDItem, _ b: BizPRDItem) -> Bool {
        func stateRank(_ p: BizPRDItem) -> Int { p.code == "SJWC" ? 0 : 1 }
        func priRank(_ p: BizPRDItem) -> Int {
            switch p.pri { case "P0": return 0; case "P1": return 1; case "P2": return 2; default: return 3 }
        }
        if stateRank(a) != stateRank(b) { return stateRank(a) < stateRank(b) }
        if priRank(a) != priRank(b) { return priRank(a) < priRank(b) }
        return a.no > b.no
    }

    func service(_ name: String) -> BizService? {
        cache?.services.first { $0.name == name }
    }

    /// 打开外部链接 (PRD 明细页 / 钉钉需求文档)
    func openURL(_ s: String) {
        guard let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }

    /// 打开作战地图文档 (Obsidian 优先, 失败落默认编辑器)
    func openDoc(_ svc: BizService) {
        guard !svc.doc.isEmpty else { return }
        let enc = svc.doc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? svc.doc
        if let url = URL(string: "obsidian://open?path=\(enc)"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: svc.doc))
    }

    // MARK: - 登录态检测与 Cookie 更新

    private var prdCookiePath: String {
        NSString(string: "~/.config/dboard/prd-cookie.txt").expandingTildeInPath
    }

    private var cookieProbeURL: URL? {
        URL(string: "https://ai.tmallyc.com/prd/api/requirement/myInProgressList?pageNum=1&pageSize=1")
    }

    /// 轻量探测登录态(1 条请求)。网络异常/响应不可辨时保持原判, 不误伤
    func probeAuth() {
        let cookie = (try? String(contentsOfFile: prdCookiePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cookie.isEmpty {
            DispatchQueue.main.async { self.authExpired = true }
            return
        }
        guard let url = cookieProbeURL else { return }
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, response, err in
            var verdict: Bool?
            if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                verdict = true
            } else if err == nil, let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let msg = obj["message"] as? String ?? ""
                verdict = obj["success"] as? Bool == false
                    && (msg.contains("未登录") || msg.contains("会话已过期"))
            }
            if let verdict {
                DispatchQueue.main.async {
                    let latest = (try? String(contentsOfFile: self.prdCookiePath, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if latest == cookie { self.authExpired = verdict }
                }
            }
        }.resume()
    }

    /// 保存新 cookie → 验证 → 通过则自动刷新数据
    func saveCookieAndRefresh(_ raw: String, completion: @escaping (Bool, String?) -> Void) {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.lowercased().hasPrefix("cookie:") {
            v = String(v.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        v = v.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        guard !v.isEmpty else {
            DispatchQueue.main.async { completion(false, "cookie 不能为空") }
            return
        }
        do {
            try v.write(toFile: prdCookiePath, atomically: true, encoding: .utf8)
        } catch {
            DispatchQueue.main.async { completion(false, "写入失败: \(error.localizedDescription)") }
            return
        }
        guard let url = cookieProbeURL else { return }
        var req = URLRequest(url: url)
        req.setValue(v, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, response, err in
            guard let self else { return }
            var msg: String?
            if let e = err {
                msg = "网络异常: \(e.localizedDescription)"
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                msg = "服务端判定仍未登录，请先在浏览器重新登录 ai.tmallyc.com"
            } else if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if obj["success"] as? Bool != true {
                    msg = "验证失败: \(obj["message"] as? String ?? "接口返回异常")"
                }
            } else {
                msg = "返回的不是 JSON —— 请复制接口请求头里完整的 Cookie 值"
            }
            DispatchQueue.main.async {
                completion(msg == nil, msg)
                if msg == nil {
                    self.authExpired = false
                    self.refreshRequirements()
                }
            }
        }.resume()
    }

    /// 内嵌浏览器授权成功: 落盘 cookie → 关两个弹窗 → 刷新数据
    func applyAuthorizedCookie(_ value: String) {
        try? value.write(toFile: prdCookiePath, atomically: true, encoding: .utf8)
        authExpired = false
        showCookieSheet = false
        refreshRequirements()
    }

    func openPrivacySettings() {
        guard let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(u)
    }

    static let bridgeInstallDir = NSString(string: "~/DBoardCookieBridge").expandingTildeInPath

    /// 把桥接扩展拷到用户目录并在 Finder 展示: chrome://extensions → 开发者模式 → 加载未打包 → 选这个文件夹
    func installCookieBridge() {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("CookieBridge").path,
            NSString(string: "~/work/code/other/DBoard/Resources/CookieBridge").expandingTildeInPath,
        ].compactMap { $0 }.filter { fm.fileExists(atPath: $0 + "/manifest.json") }
        guard let src = candidates.first else {
            cookieError = "找不到 CookieBridge 扩展文件（重新跑一次 ./install.sh）"
            return
        }
        let dst = Self.bridgeInstallDir
        try? fm.removeItem(atPath: dst)
        do {
            try fm.copyItem(atPath: src, toPath: dst)
        } catch {
            cookieError = "复制扩展失败: \(error.localizedDescription)"
            return
        }
        CookieBridgeServer.shared.start()
        cookieBusy = false
        cookieError = "扩展已放到 ~/DBoardCookieBridge：去 chrome://extensions 若已加载过点「重新加载」，没加载过则开发者模式→「加载未打包」选该文件夹。之后只要 Chrome 登录着 ai.tmallyc.com，每分钟自动投递一次，无需重新登录"
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dst)])
    }

    /// 系统设置里改完 FDA 勾选后,TCC 需要进程重启才生效
    var appBundlePath: String { Bundle.main.bundlePath }

    func restartApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 0.4; open \"\(appBundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// 从浏览器 profile 的 cookie DB 提取对 ai.tmallyc.com 生效的明文 Cookie 头
    private enum CookieHarvest {
        case permission            // db 文件都拷不出来 (TCC 隐私保护)
        case encrypted(Int)        // 可读, 有 tmallyc 记录, 但 value 全为空(密文)
        case notLoggedIn           // 可读, 无 tmallyc 相关记录
        case notApplicable         // 有记录但没有一条作用于 ai.tmallyc.com
        case header(String)
    }

    private static func harvestFromDB(_ dbPath: String) -> CookieHarvest {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "dboard-ck-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let dst = dir + "/c"
        var copied = false
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: dbPath + suffix) {
            if (try? fm.copyItem(atPath: dbPath + suffix, toPath: dst + suffix)) != nil { copied = true }
        }
        guard copied else { return .permission }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [dst, "select host_key || char(9) || name || char(9) || value || char(9) || length(encrypted_value) from cookies where host_key like '%tmallyc.com';"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return .permission }
        guard p.terminationStatus == 0 else { return .permission }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var sawAny = false
        var plainRows: [(name: String, host: String, value: String)] = []
        for line in out.split(separator: "\n") {
            let c = line.components(separatedBy: "\t")
            guard c.count >= 3 else { continue }
            sawAny = true
            guard !c[2].isEmpty else { continue }
            var h = String(c[0])
            if h.hasPrefix(".") { h.removeFirst() }
            plainRows.append((name: c[1], host: h, value: c[2]))
        }
        guard sawAny else { return .notLoggedIn }
        if plainRows.isEmpty { return .encrypted(0) }   // 有记录但 value 全空 = 密文存储
        let scoped = plainRows.filter { $0.host == "tmallyc.com" || $0.host == "ai.tmallyc.com" }
        guard !scoped.isEmpty else { return .notApplicable }   // 只有 sso/api 等子域专用 cookie
        var order: [String] = []
        var dict: [String: String] = [:]
        func add(_ n: String, _ v: String) { if dict[n] == nil { order.append(n) }; dict[n] = v }
        for r in scoped where r.host == "tmallyc.com" { add(r.name, r.value) }
        for r in scoped where r.host == "ai.tmallyc.com" { add(r.name, r.value) }
        guard !order.isEmpty else { return .notApplicable }
        return .header(order.map { "\($0)=\(dict[$0] ?? "")" }.joined(separator: "; "))
    }

    // MARK: - 浏览器 Cookie 收割
    // 可读性与加密策略按 profile 而异: Qoder 系为明文 value; Chrome 受 macOS 隐私保护且值加密, 通常读不到

    private var browserCookieDBs: [String] {
        let support = NSString(string: "~/Library/Application Support").expandingTildeInPath
        var out: [String] = ["Qoder", "QoderCN", "QoderWork"].map { "\(support)/\($0)/Partitions/native-browser/Cookies" }
        let chrome = "\(support)/Google/Chrome"
        if let ps = try? FileManager.default.contentsOfDirectory(atPath: chrome) {
            for d in ps.sorted() where d == "Default" || d.hasPrefix("Profile ") {
                out.append("\(chrome)/\(d)/Cookies")
            }
        }
        return out.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func verifyCookieSync(_ v: String) -> (ok: Bool, why: String) {
        guard let url = cookieProbeURL else { return (false, "url 构造失败") }
        var req = URLRequest(url: url)
        req.setValue(v, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 15
        let sem = DispatchSemaphore(value: 0)
        var result = (false, "无响应")
        URLSession.shared.dataTask(with: req) { data, response, err in
            if let e = err { result = (false, "网络异常: \(e.localizedDescription)") }
            else if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                result = (false, "HTTP \(http.statusCode) 未登录")
            }
            else if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let msg = obj["message"] as? String ?? ""
                result = (obj["success"] as? Bool == true, msg.isEmpty ? "接口未返回明确原因" : msg)
            }
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + 20) != .success { return (false, "验证超时") }
        return result
    }

    private static func profileName(forDB db: String) -> String {
        let parts = db.components(separatedBy: "Application Support/")
        guard parts.count > 1 else { return "浏览器" }
        switch parts[1].components(separatedBy: "/").first {
        case "Google": return "Chrome"
        case let app? where app.hasPrefix("Qoder"): return app
        default: return "浏览器"
        }
    }

    /// 「从浏览器提取」: 遍历本机浏览器 profile, 找到能用的登录态直接落盘刷新
    func extractFromBrowsers() {
        guard !cookieBusy else { return }
        DispatchQueue.main.async {
            self.showCookieSheet = true
            self.cookieBusy = true
            self.cookieFDAHint = false
            self.cookieError = "正在扫描本机浏览器的登录态…"
        }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var notes: [String] = []
            var sawPermission = false
            var sawEncrypted = false
            var bridgeSeen = false
            var bridgeWhy = ""
            // Chrome 桥接扩展投递的双通道: HTTP spool + Downloads 兜底文件, 取较新者先验
            let bridgeFiles = [CookieBridgeServer.spoolPath,
                               NSString(string: "~/Downloads/DBoard-cookie.txt").expandingTildeInPath]
                .filter { (try? String(contentsOfFile: $0, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0 >= 10 }
                .sorted {
                    let a = (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date ?? .distantPast
                    let b = (try? FileManager.default.attributesOfItem(atPath: $1))?[.modificationDate] as? Date ?? .distantPast
                    return a > b
                }
            for path in bridgeFiles {
                bridgeSeen = true
                let raw = (try? String(contentsOfFile: path, encoding: .utf8) ?? "")!
                let header = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let ageStr: String = {
                    guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return "时间未知" }
                    let s = Int(Date().timeIntervalSince(m))
                    return s < 60 ? "1分钟内" : (s < 3600 ? "\(s / 60)分钟前" : "\(s / 3600)小时前")
                }()
                let verdict = self.verifyCookieSync(header)
                if verdict.ok {
                    DispatchQueue.main.async {
                        self.cookieBusy = false
                        self.applyAuthorizedCookie(header)
                    }
                    return
                }
                bridgeWhy = "桥送来的 cookie(\(ageStr)投递)被服务端拒绝: \(verdict.why)"
            }
            for db in self.browserCookieDBs {
                let profile = Self.profileName(forDB: db)
                switch Self.harvestFromDB(db) {
                case .header(let header):
                    if self.verifyCookieSync(header).ok {
                        DispatchQueue.main.async {
                            self.cookieBusy = false
                            self.applyAuthorizedCookie(header)
                        }
                        return
                    }
                    notes.append("\(profile): 读到登录态但已失效")
                case .permission:
                    sawPermission = true
                    notes.append("\(profile): 无权读取")
                case .encrypted:
                    sawEncrypted = true
                    notes.append("\(profile): Cookie 值已加密(App-Bound)，需装桥接扩展")
                case .notApplicable:
                    notes.append("\(profile): 有记录但无 ai 域登录 cookie")
                case .notLoggedIn:
                    notes.append("\(profile): 未登录过 ai.tmallyc.com")
                }
            }
            DispatchQueue.main.async {
                self.cookieBusy = false
                if sawPermission { self.cookieFDAHint = true }
                var msg: String
                if bridgeSeen {
                    msg = "未能自动提取 — " + bridgeWhy
                    if sawEncrypted { msg += "；Chrome 值受 App-Bound 加密，靠的就是这个桥，请在 Chrome 重新登录 ai.tmallyc.com 后稍等 30 秒再试" }
                } else {
                    msg = "未能自动提取 — " + notes.joined(separator: "；")
                    if sawPermission { msg += "。给 DBoard 开「完全磁盘访问」后重试即可读取 Qoder 系浏览器" }
                    if sawEncrypted { msg += "。Chrome 走下方「安装 Chrome 桥」一次装好，登录即自动投递" }
                }
                self.cookieError = msg
            }
        }
    }

    // MARK: - 推进状态

    @Published var startDevelopmentItem: BizPRDItem?
    @Published var startDevelopmentDraft: PRDStartDevelopmentDraft?
    @Published var startDevelopmentLoading = false
    @Published var startDevelopmentError: String?
    @Published private(set) var statusSubmitting: Set<Int> = []
    private var startDevelopmentRequest: UUID?
    private let statusSession: URLSession
    private let statusCookie: () -> String?
    private let statusRefresh: (() -> Void)?

    static func readStatusCookie() -> String? {
        let path = NSString(string: "~/.config/dboard/prd-cookie.txt").expandingTildeInPath
        let cookie = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return cookie?.isEmpty == false ? cookie : nil
    }

    func beginStartDevelopment(_ item: BizPRDItem) {
        guard !statusSubmitting.contains(item.id) else { return }
        startDevelopmentItem = item
        startDevelopmentDraft = nil
        startDevelopmentError = nil
        startDevelopmentLoading = false
        let token = UUID()
        startDevelopmentRequest = token
        guard let cookie = statusCookie(), !cookie.isEmpty else {
            startDevelopmentError = "没有可用登录态，请先更新 Cookie"
            return
        }
        startDevelopmentLoading = true
        var request = URLRequest(url: URL(string: "https://ai.tmallyc.com/prd/api/requirement/detail/\(item.id)")!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        statusSession.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<PRDStartDevelopmentDraft, Error>
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                result = .failure(PRDStartDevelopmentDraft.ReadError.message("登录已过期，请先更新 Cookie"))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(PRDStartDevelopmentDraft.ReadError.message("读取需求失败（HTTP \(http.statusCode)）"))
            } else if let data { result = Result { try PRDStartDevelopmentDraft.decode(data, reqID: item.id) } }
            else { result = .failure(PRDStartDevelopmentDraft.ReadError.message("服务端无响应，请重试")) }
            DispatchQueue.main.async {
                guard let self, self.startDevelopmentRequest == token,
                      self.startDevelopmentItem?.id == item.id else { return }
                self.startDevelopmentLoading = false
                switch result {
                case .success(let draft): self.startDevelopmentDraft = draft
                case .failure(let error): self.startDevelopmentError = error.localizedDescription
                }
            }
        }.resume()
    }

    func cancelStartDevelopment() {
        guard startDevelopmentItem.map({ !statusSubmitting.contains($0.id) }) ?? true else { return }
        startDevelopmentRequest = nil
        startDevelopmentItem = nil
        startDevelopmentDraft = nil
        startDevelopmentError = nil
        startDevelopmentLoading = false
    }

    func pushStatus(reqId: Int, toStatus: String, actionName: String,
                    developmentDraft: PRDStartDevelopmentDraft? = nil) {
        guard !statusSubmitting.contains(reqId) else { return }
        if toStatus == "KFZ", developmentDraft == nil {
            guard let item = prdItems.first(where: { $0.id == reqId }) else {
                flashToast("找不到当前需求，请刷新后重试")
                return
            }
            beginStartDevelopment(item)
            return
        }
        let jsonData: Data
        do {
            jsonData = try JSONEncoder().encode(PRDStatusChange(reqID: reqId, toStatus: toStatus,
                actionName: actionName, development: developmentDraft))
        } catch {
            startDevelopmentError = error.localizedDescription
            flashToast(error.localizedDescription)
            return
        }
        guard let cookie = statusCookie(), !cookie.isEmpty else {
            let message = "没有可用登录态，先在横幅里更新 Cookie"
            if startDevelopmentItem?.id == reqId { startDevelopmentError = message }
            flashToast(message)
            return
        }
        statusSubmitting.insert(reqId)
        startDevelopmentError = nil
        var req = URLRequest(url: URL(string: "https://ai.tmallyc.com/prd/api/requirement/changeStatus")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.httpBody = jsonData
        statusSession.dataTask(with: req) { [weak self] data, response, err in
            var failure = "「\(actionName)」失败: "
            var succeeded = false
            if let err { failure += err.localizedDescription }
            else if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                failure = "登录已过期，请先更新 Cookie"
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure += "HTTP \(http.statusCode)，请重试"
            } else if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                succeeded = obj["success"] as? Bool == true
                if !succeeded { failure += obj["message"] as? String ?? "接口返回异常" }
            } else { failure += "服务端无响应" }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusSubmitting.remove(reqId)
                if succeeded {
                    if self.startDevelopmentItem?.id == reqId { self.cancelStartDevelopment() }
                    self.flashToast("✓ 已\(actionName)")
                    if let refresh = self.statusRefresh { refresh() }
                    else { self.refreshRequirements() }
                } else {
                    if self.startDevelopmentItem?.id == reqId { self.startDevelopmentError = failure }
                    self.flashToast(failure)
                }
            }
        }.resume()
    }

    /// 底部 toast 2.5 秒自动消失(与交付物复用同一通道)
    func flashToast(_ msg: String) {
        deliverableToast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.deliverableToast == msg { self?.deliverableToast = nil }
        }
    }

    // MARK: - 上传交付物

    @Published var deliverableReqId: Int?
    @Published var deliverableReqNo: String = ""
    @Published var deliverableCode: String = ""
    @Published var deliverableContent: String = ""
    @Published var deliverableFile: URL?
    @Published var deliverableProjects: [(app: String, branch: String)] = []
    @Published var devAppQuery: String = ""
    @Published var devAppResults: [(id: Int, name: String)] = []
    @Published var devSelectedApp: (id: Int, name: String)?
    @Published var devBranchQuery: String = ""
    @Published var devBranchResults: [String] = []
    @Published var showDeliverablePanel = false
    @Published var deliverableUploading = false
    @Published var deliverableToast: String?
    @Published var deliverableStatus: [Int: Set<String>] = [:]  // reqId → {"dev","test","solution"}
    @Published var deliverableItems: [Int: [[String: Any]]] = [:] // reqId → flat list of deliverable items
    @Published private(set) var developmentProjectSnapshots: [Int: DevelopmentProjectSnapshot] = [:]
    @Published private(set) var deliverableLoading: Set<Int> = []
    @Published private(set) var deliverableReadErrors: [Int: String] = [:]
    private var deliverableRequests: [Int: UUID] = [:]
    private let projectStore: DevelopmentProjectStore

    func uploadDeliverable(reqId: Int, reqNo: String, code: String) {
        deliverableReqId = reqId
        deliverableReqNo = reqNo
        deliverableCode = code
        deliverableContent = ""
        deliverableFile = nil
        deliverableProjects = []
        devAppQuery = ""
        devAppResults = []
        devSelectedApp = nil
        devBranchQuery = ""
        devBranchResults = []
        showDeliverablePanel = true
    }

    private var appSearchTimer: Timer?
    private var branchSearchTimer: Timer?

    func searchApps() {
        appSearchTimer?.invalidate()
        let q = devAppQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { devAppResults = []; return }
        appSearchTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let cookie = (try? String(contentsOfFile: NSString(string: "~/.config/dboard/prd-cookie.txt").expandingTildeInPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            var req = URLRequest(url: URL(string: "https://ai.tmallyc.com/prd/api/devops/app/list?name=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)")!)
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data = data,
                      let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      resp["success"] as? Bool == true else { return }
                var body = resp["body"]
                if let s = body as? String { body = try? JSONSerialization.jsonObject(with: s.data(using: .utf8)!) }
                let apps = ((body as? [String: Any])?["data"] as? [String: Any])?["apps"] as? [[String: Any]] ?? []
                let results = apps.compactMap { a -> (id: Int, name: String)? in
                    guard let id = a["id"] as? Int, let name = a["name"] as? String else { return nil }
                    return (id, name)
                }
                DispatchQueue.main.async {
                    guard let self, self.devSelectedApp == nil,
                          self.devAppQuery.trimmingCharacters(in: .whitespaces) == q else { return }
                    self.devAppResults = results
                }
            }.resume()
        }
    }

    func searchBranches() {
        branchSearchTimer?.invalidate()
        guard let app = devSelectedApp else { devBranchResults = []; return }
        let searchQuery = devBranchQuery
        devBranchResults = []
        branchSearchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let q = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let cookie = (try? String(contentsOfFile: NSString(string: "~/.config/dboard/prd-cookie.txt").expandingTildeInPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            var req = URLRequest(url: URL(string: "https://ai.tmallyc.com/prd/api/devops/app/branch?id=\(app.id)&name=\(q)")!)
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data = data,
                      let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      resp["success"] as? Bool == true else { return }
                var body = resp["body"]
                if let s = body as? String { body = try? JSONSerialization.jsonObject(with: s.data(using: .utf8)!) }
                let branches = ((body as? [String: Any])?["data"] as? [String: Any])?["branch"] as? [String] ?? []
                DispatchQueue.main.async {
                    guard let self, self.devSelectedApp?.id == app.id,
                          self.devBranchQuery == searchQuery else { return }
                    self.devBranchResults = branches
                }
            }.resume()
        }
    }

    func addDevProject(branch: String) {
        guard let app = devSelectedApp else { return }
        if !deliverableProjects.contains(where: { $0.app == app.name && $0.branch == branch }) {
            deliverableProjects.append((app: app.name, branch: branch))
        }
        devSelectedApp = nil
        devAppQuery = ""
        devBranchQuery = ""
        devAppResults = []
        devBranchResults = []
    }

    func submitDeliverable() {
        guard let reqId = deliverableReqId else { return }
        deliverableUploading = true
        let cookie: String = {
            let p = NSString(string: "~/.config/dboard/prd-cookie.txt").expandingTildeInPath
            return (try? String(contentsOfFile: p, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        }()
        let typeNum: Int = {
            switch deliverableCode {
            case "SJWC", "FASJWC": return 1
            case "KFZ", "KFWC": return 3
            case "CSZ", "CSWC": return 4
            default: return 3
            }
        }()
        let content = deliverableContent
        let branch = deliverableProjects.map { "\($0.app):\($0.branch)" }.joined(separator: ",")
        let fileURL = deliverableFile
        let reqNo = deliverableReqNo

        DispatchQueue.global().async { [weak self] in
            var attachmentIds: [Int] = []
            // 选了附件就必须上传并持久化成功，否则整体不提交，表单与附件保留
            func fail(_ message: String) {
                DispatchQueue.main.async {
                    self?.deliverableUploading = false
                    self?.flashToast(message)
                }
            }
            func accepted(_ response: URLResponse?) -> Bool {
                guard let http = response as? HTTPURLResponse else { return false }
                return (200..<300).contains(http.statusCode)
            }

            if let fileURL = fileURL {
                guard let fileData = try? Data(contentsOf: fileURL) else { fail("无法读取附件，未提交"); return }
                let fileName = fileURL.lastPathComponent
                let boundary = "----DBoard\(UInt32.random(in: 0...UInt32.max))"
                var req1 = URLRequest(url: URL(string: "https://ai.tmallyc.com/prd/api/attachment/uploadTemp")!)
                req1.httpMethod = "POST"
                req1.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                req1.setValue(cookie, forHTTPHeaderField: "Cookie")
                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
                body.append(fileData)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                req1.httpBody = body

                if let (data1, response1) = try? URLSession.shared.syncData(for: req1), accepted(response1),
                   let resp1 = try? JSONSerialization.jsonObject(with: data1) as? [String: Any],
                   resp1["success"] as? Bool == true,
                   let tempData = resp1["data"] as? [String: Any],
                   let ossUrl = tempData["ossUrl"] as? String,
                   let fileSize = tempData["fileSize"] as? Int,
                   let fileType = tempData["fileType"] as? String {
                    let persistBody: [String: Any] = ["reqId": reqId, "reqNo": reqNo, "fileName": fileName, "fileSize": fileSize, "fileType": fileType, "ossUrl": ossUrl]
                    var req2 = URLRequest(url: URL(string: "https://ai.tmallyc.com/prd/api/attachment/persistTemp")!)
                    req2.httpMethod = "POST"
                    req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req2.setValue(cookie, forHTTPHeaderField: "Cookie")
                    req2.httpBody = try? JSONSerialization.data(withJSONObject: persistBody)
                    if let (data2, response2) = try? URLSession.shared.syncData(for: req2), accepted(response2),
                       let resp2 = try? JSONSerialization.jsonObject(with: data2) as? [String: Any],
                       resp2["success"] as? Bool == true,
                       let attData = resp2["data"] as? [String: Any],
                       let attId = attData["id"] as? Int {
                        attachmentIds.append(attId)
                    } else { fail("附件保存失败，交付物未提交；表单已保留，可重试"); return }
                } else { fail("附件上传失败，交付物未提交；表单已保留，可重试"); return }
            }

            // 提交交付物
            let delivBody: [String: Any] = [
                "reqId": reqId,
                "deliverableType": typeNum,
                "deliverableContent": content,
                "attachmentIds": attachmentIds,
                "deliverableAiCreate": 0,
                "deliverableDevProject": branch
            ]
            var req3 = URLRequest(url: URL(string: "https://ai.tmallyc.com/prd/api/requirement/deliverable/uploadWithAttachments")!)
            req3.httpMethod = "POST"
            req3.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req3.setValue(cookie, forHTTPHeaderField: "Cookie")
            req3.httpBody = try? JSONSerialization.data(withJSONObject: delivBody)
            let (data3, response3) = (try? URLSession.shared.syncData(for: req3)) ?? (Data(), URLResponse())
            let ok = accepted(response3)
                && (try? JSONSerialization.jsonObject(with: data3) as? [String: Any])?["success"] as? Bool == true

            DispatchQueue.main.async {
                self?.deliverableUploading = false
                // 失败时保留面板和草稿，便于直接重试
                if ok { self?.showDeliverablePanel = false }
                if ok {
                    self?.deliverableToast = "✅ 交付物上传成功"
                    let tag: String = typeNum == 1 ? "solution" : (typeNum == 3 ? "dev" : "test")
                    self?.deliverableStatus[reqId, default: []].insert(tag)
                    self?.loadDeliverableStatus(reqId: reqId, force: true)
                } else {
                    self?.deliverableToast = "⚠️ 上传失败"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self?.deliverableToast = nil }
            }
        }
    }

    func pickDeliverableFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { deliverableFile = panel.url }
    }

    @discardableResult
    func recordDeliverables(_ response: DevelopmentDeliverables.Response, reqID: Int, fetchedAt: Date = Date()) -> Bool {
        let snapshot = DevelopmentProjectSnapshot(projects: response.projects, fetchedAt: fetchedAt)
        developmentProjectSnapshots[reqID] = snapshot
        deliverableStatus[reqID] = response.tags
        deliverableItems[reqID] = response.items
        let saved = projectStore.save(snapshot, for: reqID)
        deliverableReadErrors[reqID] = saved ? nil : "工程已读取，但本地缓存保存失败；重开后需重新读取"
        return saved
    }

    func loadDeliverableStatus(reqId: Int, force: Bool = false) {
        guard force || !deliverableLoading.contains(reqId) else { return }
        let cookie = (try? String(contentsOfFile: NSString(string: "~/.config/dboard/prd-cookie.txt").expandingTildeInPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard !cookie.isEmpty else {
            deliverableReadErrors[reqId] = "需要登录后读取开发交付"
            authExpired = true
            return
        }
        let requestID = UUID()
        deliverableRequests[reqId] = requestID
        deliverableLoading.insert(reqId)
        deliverableReadErrors[reqId] = nil
        var req = URLRequest(url: URL(string: "https://ai.tmallyc.com/prd/api/requirement/deliverable/list/\(reqId)")!)
        req.timeoutInterval = 20
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        URLSession.shared.dataTask(with: req) { [weak self] data, httpResponse, error in
            let status = (httpResponse as? HTTPURLResponse)?.statusCode
            let response = error == nil && status == 200 ? data.flatMap { try? DevelopmentDeliverables.decode($0) } : nil
            DispatchQueue.main.async {
                guard let self, self.deliverableRequests[reqId] == requestID else { return }
                self.deliverableRequests[reqId] = nil
                self.deliverableLoading.remove(reqId)
                if let response { self.recordDeliverables(response, reqID: reqId) }
                else {
                    let expired = status == 401 || status == 403
                    self.deliverableReadErrors[reqId] = expired ? "登录已过期，请重新登录后读取" : "开发交付读取失败，请重试"
                    if expired { self.authExpired = true }
                }
            }
        }.resume()
    }

    // MARK: - 同步到 AI 表格

    func checkSyncStatus() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let result = self.runSyncScript(args: ["check"])
            guard let data = result.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { return }
            var status: [String: String] = [:]
            var changed = Set<String>()
            for item in items {
                if let name = item["name"] as? String, let synced = item["synced"] as? Bool {
                    status[name] = synced ? "synced" : "unsynced"
                    if (item["changed"] as? Bool) == true { changed.insert(name) }
                }
            }
            DispatchQueue.main.async {
                self.syncStatus = status
                self.syncChanged = changed
            }
        }
    }

    /// mode: sync 只按已确认身份或唯一精确同名写；create / link 只在用户明确选择后使用
    func syncOne(name: String, mode: String = "sync", recordID: String? = nil) {
        syncStatus[name] = "syncing"
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let raw = self.runSyncScript(args: [mode, name] + (recordID.map { [$0] } ?? []))
            let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            let status = json?["status"] as? String ?? ""
            DispatchQueue.main.async {
                if status == "needs-confirm" {
                    self.syncStatus[name] = "unsynced"
                    self.confirmTableRecord(name: name, candidates: json?["candidates"] as? [[String: Any]] ?? [])
                    return
                }
                let ok = ["ok", "updated", "skip"].contains(status)
                self.syncStatus[name] = ok ? "synced" : "error"
                if !ok { self.flashToast("项目表同步失败：\(json?["message"] as? String ?? "请稍后重试")") }
                if ok { self.checkSyncStatus() }
            }
        }
    }

    private func confirmTableRecord(name: String, candidates: [[String: Any]]) {
        let options = candidates.compactMap { c -> (String, String)? in
            guard let id = c["recordId"] as? String, !id.isEmpty else { return nil }
            return (id, c["name"] as? String ?? id)
        }.prefix(2)
        let alert = NSAlert()
        alert.messageText = "项目表里有名称相近的记录"
        alert.informativeText = "「\(name)」没有完全同名的记录。请确认是否就是下面某条；确认后会按需求编号记住，不再按名称猜。"
        for option in options { alert.addButton(withTitle: "关联到「\(option.1)」") }
        alert.addButton(withTitle: "新建记录")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index < options.count { syncOne(name: name, mode: "link", recordID: Array(options)[index].0) }
        else if index == options.count { syncOne(name: name, mode: "create") }
    }

    func syncAll() {
        syncAllRunning = true
        for item in myActive where syncStatus[item.name] != "synced" || syncChanged.contains(item.name) {
            syncStatus[item.name] = "syncing"
        }
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let raw = self.runSyncScript(args: ["sync-all"])
            let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            let results = json?["results"] as? [[String: Any]] ?? []
            let failed = results.filter { !["ok", "updated", "skip"].contains($0["status"] as? String ?? "") }.count
            DispatchQueue.main.async {
                self.syncAllRunning = false
                if json?["status"] as? String != "ok" { self.flashToast("项目表读取失败，未做任何写入") }
                else if failed > 0 { self.flashToast("\(failed) 条未同步：名称相近需单条确认或同步失败") }
                self.checkSyncStatus()
            }
        }
    }

    private func runSyncScript(args: [String]) -> String {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.qoderwork/bin:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        let result = ProcessRunner.run("/bin/bash", arguments: [syncScript] + args, environment: env, timeout: 180)
        return result.outputComplete && !result.timedOut ? String(decoding: result.stdout, as: UTF8.self) : ""
    }
}

// MARK: - 梯队配色

private func tierColor(_ tier: String) -> Color {
    switch tier {
    case "t1": return Color.red
    case "t2": return Color.green
    case "t3m": return Color.accentColor
    case "t3s": return Color.accentColor
    case "gw": return Color.accentColor
    case "adm": return Color.orange
    case "infra": return Color.secondary
    default: return Color.secondary
    }
}

private let hitPrimary = Color.orange
private let hitSecondary = Color.accentColor
// MARK: - 本地 Cookie 桥 (接收 Chrome 扩展投递的登录态, 绕开 App-Bound 加密)

final class CookieBridgeServer {
    static let shared = CookieBridgeServer()
    static let port: UInt16 = 58613
    static let spoolPath = NSString(string: "~/.claude/prd-cookie-spool.txt").expandingTildeInPath
    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }
        _ = CanaryCookieBridge.shared
        guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!) else { return }
        l.newConnectionHandler = { conn in
            guard Self.isLoopback(conn.endpoint) else { conn.cancel(); return }
            conn.start(queue: .global(qos: .utility))
            self.read(conn, buf: Data())
        }
        l.start(queue: .global(qos: .utility))
        listener = l
    }

    private static func isLoopback(_ ep: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = ep else { return false }
        return host == .ipv4(.loopback) || host == .ipv6(.loopback) || host.debugDescription == "localhost"
    }

    private func read(_ conn: NWConnection, buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self else { return }
            var b = buf
            if let d = data { b.append(d) }
            if error != nil || complete { conn.cancel(); return }
            if let req = Self.parse(b) {
                self.handle(conn, req)
            } else if b.count < 131_072 {
                self.read(conn, buf: b)
            } else {
                conn.cancel()
            }
        }
    }

    private static func parse(_ data: Data) -> (method: String, path: String, body: Data, origin: String, authorization: String)? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: data[..<sep.lowerBound], encoding: .utf8) ?? ""
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first?.components(separatedBy: " "), first.count >= 2 else { return ("", "", Data(), "", "") }
        var contentLength = 0
        var origin = ""
        var authorization = ""
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            } else if line.lowercased().hasPrefix("origin:") {
                origin = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("authorization:") {
                authorization = String(line.dropFirst(14)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard contentLength >= 0,
              contentLength <= (first[1] == "/audi-cookie" ? 8192 : 65_536) else {
            return ("", "", Data(), "", "")
        }
        guard first[0] == "POST" else { return (first[0], first[1], Data(), origin, authorization) }
        let bodyLen = data.count - sep.upperBound
        guard bodyLen >= contentLength else { return nil }
        return (first[0], first[1], data[sep.upperBound..<(sep.upperBound + contentLength)], origin, authorization)
    }

    private func handle(_ conn: NWConnection, _ req: (method: String, path: String, body: Data, origin: String, authorization: String)) {
        var status = "200 OK"
        var body = Data("ok".utf8)
        var cors = ""
        if req.path == "/canary-cookie" || req.path.hasPrefix("/canary-cookie/") {
            cors = "Content-Type: application/json\r\n"
            let extensionOrigin = req.origin.range(of: #"^chrome-extension://[a-p]{32}$"#, options: .regularExpression) != nil
            if req.path == "/canary-cookie/pair" {
                NSLog("Canary bridge pairing method=%@ originPresent=%@ extensionOrigin=%@ bodyBytes=%d", req.method, req.origin.isEmpty ? "no" : "yes", extensionOrigin ? "yes" : "no", req.body.count)
            }
            if extensionOrigin {
                cors += "Access-Control-Allow-Origin: \(req.origin)\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nAccess-Control-Allow-Private-Network: true\r\n"
            }
            if req.method == "OPTIONS", ["/canary-cookie", "/canary-cookie/pair"].contains(req.path), extensionOrigin {
                status = "204 No Content"; body = Data()
            } else if req.method == "POST", req.path == "/canary-cookie/pair", req.body.isEmpty {
                let result = CanaryCookieBridge.shared.pair(origin: req.origin) {
                    DispatchQueue.main.sync {
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "允许连接 Chrome 的 Canary 登录态？"
                        alert.informativeText = "仅当你刚点击了 Cookie Bridge 的“连接 Canary”时允许。连接后，该扩展可自动将生产、预发 Canary 登录态同步到本机 DBoard，供本地工具使用。登录态仅保存在内存，不输出或写文件。\n\n扩展：\(req.origin)"
                        alert.addButton(withTitle: "取消")
                        alert.addButton(withTitle: "允许连接")
                        return alert.runModal() == .alertSecondButtonReturn
                    }
                }
                status = result.status; body = result.body
            } else {
                let result = CanaryCookieBridge.shared.response(method: req.method, path: req.path,
                    origin: req.origin, authorization: req.authorization, body: req.body)
                status = result.status; body = result.body
            }
        } else if req.path == "/audi-cookie",
           req.origin.range(of: #"^chrome-extension://[a-p]{32}$"#, options: .regularExpression) != nil {
            AppReleaseWindowController.shared.recordDiagnostic("bridge audi-cookie method=\(req.method) origin=extension")
            cors = "Access-Control-Allow-Origin: \(req.origin)\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\n"
            if req.method == "OPTIONS" {
                status = "204 No Content"; body = Data()
            } else if req.method == "POST",
                      let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                      let name = json["name"] as? String, name == "ac-session-id",
                      let value = json["value"] as? String, value.isEmpty {
                DispatchQueue.main.async { AppReleaseWindowController.shared.clearChromeSession() }
            } else if req.method == "POST",
                      let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                      let name = json["name"] as? String, name == "ac-session-id",
                      let value = json["value"] as? String, !value.isEmpty, value.count <= 4096,
                      let domain = json["domain"] as? String,
                      ["audi.tmallyc.com", ".tmallyc.com", "tmallyc.com"].contains(domain),
                      let path = json["path"] as? String, path == "/" {
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name, .value: value, .domain: domain, .path: path,
                    .secure: "TRUE"
                ]
                if let expiry = json["expirationDate"] as? Double {
                    properties[.expires] = Date(timeIntervalSince1970: expiry)
                }
                if let cookie = HTTPCookie(properties: properties),
                   cookie.expiresDate.map({ $0 > Date() }) ?? true {
                    DispatchQueue.main.async { AppReleaseWindowController.shared.receiveChromeSession(cookie) }
                } else { status = "400 Bad Request" }
            } else { status = "400 Bad Request" }
        } else if req.path == "/cookie",
                  req.origin.range(of: #"^chrome-extension://[a-p]{32}$"#, options: .regularExpression) != nil {
            cors = "Access-Control-Allow-Origin: \(req.origin)\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-DBoard\r\nAccess-Control-Allow-Private-Network: true\r\n"
            if req.method == "OPTIONS" {
                status = "204 No Content"; body = Data()
            } else if req.method == "POST" {
                let text = String(data: req.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.count >= 10, text.count <= 65_536, !text.contains("\r"), !text.contains("\n") {
                    do {
                        try text.write(toFile: Self.spoolPath, atomically: true, encoding: .utf8)
                        DispatchQueue.main.async {
                            BizMapBoardWindowController.shared.receiveBridgedCookie(text)
                        }
                    } catch { status = "500 Internal Server Error"; body = Data("write-fail".utf8) }
                } else { status = "400 Bad Request"; body = Data("bad".utf8) }
            } else { status = "404 Not Found" }
        } else {
            status = "404 Not Found"; body = Data("noop".utf8)
        }
        let resp = "HTTP/1.1 \(status)\r\n\(cors)Cache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)! + body
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }
}

private let prdBlue = Color.accentColor

// MARK: - 项目表记录（list-mine）

struct TableProject: Codable, Identifiable {
    let recordId: String
    let name: String
    let desc: String
    let product: String
    let domain: String
    let tags: String
    let submit: String          // 表内「PRD时间」
    let devStart: String
    let online: String
    var test: String? = nil     // 提测时间；旧缓存没有该字段
    var role: String? = nil     // owner / member
    var requirementId: Int? = nil
    var requirementNo: String? = nil
    var requirementCode: String? = nil
    var requirementStatus: String? = nil
    var id: String { recordId }

    /// 正式状态优先采用需求流当前快照，其次采用项目表读取时的需求查询结果。
    func displayStage(today: String = DemandDates.today(), requirement: BizPRDItem? = nil) -> (label: String, tint: Color) {
        let status = requirement?.status ?? requirementStatus ?? ""
        let code = requirement?.code ?? requirementCode ?? ""
        if !status.isEmpty {
            let tint: Color
            switch code {
            case "CPYSWC", "XQWC": tint = .green
            case "CSZ", "YCS", "CSWC", "CPYSZ": tint = .orange
            case "KFZ", "KFWC": tint = .accentColor
            default: tint = .secondary
            }
            return (status, tint)
        }
        let schedule = stage(today: today)
        if schedule.label == "开发中" || schedule.label == "测试中" { return ("状态待核实", .secondary) }
        if schedule.label == "未排期" { return schedule }
        return ("排期 · " + schedule.label, schedule.tint)
    }

    /// 表内排期推断，不能作为正式需求状态；未来日期算「待…」。
    func stage(today: String = DemandDates.today()) -> (label: String, tint: Color) {
        func reached(_ date: String?) -> Bool? {
            guard let date, !date.isEmpty else { return nil }
            return date <= today
        }
        if let done = reached(online) { return done ? ("已上线", .green) : ("待上线 \(online.suffix(5))", .orange) }
        if let done = reached(test) { return done ? ("测试中", .orange) : ("待提测 \((test ?? "").suffix(5))", .secondary) }
        if let done = reached(devStart) { return done ? ("开发中", .accentColor) : ("待开发 \(devStart.suffix(5))", .secondary) }
        return ("未排期", .secondary)
    }
}

private struct TableProjectsResponse: Codable {
    let status: String
    let items: [TableProject]
    let total: Int
}

private struct TableProjectsCache: Codable { let items: [TableProject] }

private func tableChip(_ text: String, tint: Color) -> some View {
    Text(text).font(.system(size: 9.5, weight: .medium))
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(tint.opacity(0.12)))
        .foregroundStyle(tint)
}

// MARK: - 主视图

struct BizMapBoardView: View {
    @EnvironmentObject var vm: BizMapViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    var popoverMode: Bool = false
    var refreshOnAppear: Bool = true
    @FocusState private var searchFocused: Bool
    @State private var copiedHint: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 chrome(字标+搜索)结成一条带底色的区: 文字不能裸贴在壁纸上
            VStack(spacing: 0) {
                header
                searchBar
            }
            .background(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.78))
            Divider().opacity(0.4)
            if let err = vm.loadError {
                errorState(err)
            } else if vm.perspective == .requirements {
                requirementList
            } else {
                wall
            }
            footer
        }
        // 底层使用与 Skills Board 相同的 同一套 ThemeBackground: 毛玻璃皮肤下是 NSVisualEffectView 原生材质,
        // 不能用裸主题色 opacity —— 半透主题叠透明窗口会成"几乎全透"
        .background(theme.current.background)
        .overlay(alignment: .top) {
            if let hint = copiedHint {
                Text(hint).font(fm.font(10.5))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(theme.current.accentPrimary.opacity(0.92)))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(DBoardUI.spring, value: copiedHint)
        .toolbar {
            if !popoverMode {
                ToolbarItemGroup(placement: .automatic) { WorkspacePinButton(id: "bizmap"); DBoardSettingsButton() }
            }
        }
        .onAppear {
            guard refreshOnAppear else { return }
            vm.load(); vm.checkSyncStatus(); searchFocused = true
            vm.probeAuth()
            for item in vm.myActive { vm.loadDeliverableStatus(reqId: item.id) }
        }
        .onChange(of: vm.perspective) { _, p in
            guard refreshOnAppear else { return }
            if p == .requirements {
                vm.probeAuth()
                for item in vm.myActive { vm.loadDeliverableStatus(reqId: item.id) }
            }
            BizMapBoardWindowController.shared.updateTitle()
        }
        .sheet(item: $vm.startDevelopmentItem, onDismiss: { vm.cancelStartDevelopment() }) { item in
            PRDStartDevelopmentSheet(vm: vm, item: item)
        }
        .sheet(isPresented: $vm.showDeliverablePanel) { deliverableSheet }
        .sheet(isPresented: $vm.showCookieSheet) { cookieSheet }
        .sheet(isPresented: $vm.showTableProjects) { tableProjectsSheet }
        .overlay(alignment: .bottom) {
            if let toast = vm.deliverableToast {
                Text(toast).font(fm.font(12).weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .foregroundStyle(.primary)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(DBoardUI.spring, value: vm.deliverableToast)
            }
        }
    }

    // MARK: Header —— 叠卡式视角切换: 当前字标在前, 待切的缩小压暗垫在右斜下方, 点影子换前台

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            perspectiveStack
            Spacer()
            prdFreshness
            if let g = vm.cache?.generated {
                Text("生成 " + g).font(fm.font(10)).foregroundStyle(theme.current.textMuted)
            }
            if let ge = vm.genError {
                Button(action: {
                    if vm.authExpired { vm.cookieInput = ""; vm.cookieError = nil; vm.showCookieSheet = true }
                }) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
            }
            Button(action: { vm.regenerate() }) {
                if vm.regenerating && vm.refreshProgress == nil { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
            }
            .buttonStyle(.plain).foregroundStyle(theme.current.textSecondary)
            .disabled(vm.regenerating)
            if let prog = vm.refreshProgress {
                HStack(spacing: 4) {
                    ProgressView(value: Double(prog.current), total: Double(prog.total))
                        .frame(width: 60)
                    Text("\(prog.name) (\(prog.current)/\(prog.total))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.current.textMuted)
                        .lineLimit(1)
                }
            }
            if popoverMode {
                TearOffButton(key: "BizMapBoard")
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
        .tearOffHandle("BizMapBoard", enabled: popoverMode)
    }

    /// PRD 快照新鲜度指示器: 旧了就亮橙/红, 点一下拿到刷新指令(粘给 AI 即可)
    @ViewBuilder private var prdFreshness: some View {
        let lvl = vm.prdStaleLevel
        if lvl >= 0 {
            let ageDays = vm.prdAgeDays
            let color: Color = lvl == 2 ? Color.red : (lvl == 1 ? hitPrimary : theme.current.textMuted)
            let label: String = {
                guard let d = ageDays else { return "PRD 快照时间未知" }
                if d <= 0 { return "PRD 今日" }
                return "PRD \(d) 天前"
            }()
            Button(action: {
                let t = vm.copyRefreshPrompt()
                copiedHint = "已复制「\(t)」，粘给 AI 即可"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { copiedHint = nil }
            }) {
                HStack(spacing: 3) {
                    if lvl > 0 {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9))
                    }
                    Text(label).font(fm.font(9.5))
                    if lvl > 0 {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 8.5))
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(Capsule().fill(color.opacity(lvl > 0 ? 0.14 : 0.07)))
                .foregroundStyle(color)
            }
            .buttonStyle(.plain)
        }
    }

    /// 叠卡容器: 两张字标同栈, 谁 active 谁在前台原位, 另一张缩到影子位
    private var perspectiveStack: some View {
        Picker("视角", selection: $vm.perspective) {
            Text("业务地图").tag(BizPerspective.services)
            Text("需求流").tag(BizPerspective.requirements)
        }
        .pickerStyle(.segmented)
        .frame(width: 210)
    }

    // MARK: Search / 路由

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.current.textMuted)
                TextField(vm.perspective == .requirements
                          ? "筛选需求：名称 / 编号 / 工程 / 开发 / 状态 …"
                          : "输入需求关键词做路由：验券 / 领券 / 企微群聊 / 售后退款 / 会员卡 / 下单 …", text: $vm.query)
                    .textFieldStyle(.plain).font(fm.font(12.5))
                    .focused($searchFocused)
                if !vm.query.isEmpty {
                    Button(action: { vm.query = "" }) { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(theme.current.textMuted)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(searchFocused ? theme.current.accentPrimary.opacity(0.6) : theme.current.separator, lineWidth: 1))

            routeHint
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    @ViewBuilder private var routeHint: some View {
        let hits = vm.routeHits
        if vm.perspective == .services, !vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
            if hits.primary.isEmpty && hits.secondary.isEmpty {
                Text("无命中 —— 换个关键词，或该记入路由表（告诉 AI 补）")
                    .font(fm.font(11)).foregroundStyle(theme.current.textMuted)
            } else {
                HStack(spacing: 4) {
                    Text("路由 →").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                    Text("首查 " + hits.primary.sorted().joined(separator: "、"))
                        .font(fm.font(11).weight(.semibold)).foregroundStyle(hitPrimary)
                    if !hits.secondary.isEmpty {
                        Text("次查 " + hits.secondary.sorted().joined(separator: "、"))
                            .font(fm.font(11)).foregroundStyle(hitSecondary)
                    }
                }
            }
        }
    }

    // MARK: 卡片墙

    private var wall: some View {
        ScrollView {
            let hits = vm.routeHits
            let searching = !vm.query.trimmingCharacters(in: .whitespaces).isEmpty
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                ForEach(vm.cache?.groups ?? [], id: \.key) { g in
                    let list = (vm.cache?.services ?? []).filter { $0.tier == g.key }
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 5) {
                                Text(g.label).font(fm.font(11.5).weight(.semibold)).foregroundStyle(theme.current.textSecondary)
                                Text("\(list.count)").font(fm.font(9.5))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(theme.current.separator.opacity(0.5)))
                                    .foregroundStyle(theme.current.textMuted)
                            }
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                                ForEach(list) { svc in
                                    card(svc, hits: hits, searching: searching)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func card(_ svc: BizService, hits: (primary: Set<String>, secondary: Set<String>), searching: Bool) -> some View {
        let isP = hits.primary.contains(svc.name)
        let isS = hits.secondary.contains(svc.name)
        let dimmed = searching && !isP && !isS
        let isSelected = vm.selected?.name == svc.name

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { vm.selected = isSelected ? nil : svc }
            } label: {
            VStack(alignment: .leading, spacing: 10) {
            // 第一层: 标题
            HStack(alignment: .top, spacing: 0) {
                Text(svc.name).font(fm.font(14).weight(.semibold))
                    .foregroundStyle(theme.current.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let g = vm.cache?.generated {
                    Text(g.suffix(11)).font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(theme.current.textMuted)
                }
            }
            // 第二层: 标签行
            HStack(spacing: 6) {
                Text(svc.tier.uppercased()).font(fm.font(9.5).weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(tierColor(svc.tier).opacity(0.12)))
                    .foregroundStyle(tierColor(svc.tier))
                badge(svc.mapLevel, active: svc.mapLevel == "L2")
                if svc.st == "semi" { badge("半退役", tint: Color(hex: "#D97706")) }
                if svc.st == "dead" { badge("停维", tint: theme.current.textMuted) }
                Text("\(svc.c)c").font(fm.font(9.5)).foregroundStyle(theme.current.textMuted)
                Spacer(minLength: 0)
                if !svc.dItems.isEmpty {
                    Text("D×\(svc.dItems.count)").font(fm.font(9).weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(hitPrimary.opacity(0.12))).foregroundStyle(hitPrimary)
                }
                if !svc.prds.isEmpty {
                    Text("P×\(svc.prds.count)").font(fm.font(9).weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(prdBlue.opacity(0.12))).foregroundStyle(prdBlue)
                }
            }
            // 第三层: 描述
            Text(svc.desc).font(fm.font(10.5)).foregroundStyle(theme.current.textSecondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .topLeading)
            // 第四层: 近期变化（如有）
            if let recent = svc.recent, !recent.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9))
                    Text(recent).font(fm.font(9.5)).lineLimit(isSelected ? 3 : 1)
                }
                .foregroundStyle(Color.accentColor)
            }
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel((isSelected ? "收起服务 " : "展开服务 ") + svc.name)
            // 展开详情
            if isSelected {
                Divider().opacity(0.4).padding(.vertical, 4)
                inlineDetail(svc)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(
            isP ? hitPrimary : (isS ? hitSecondary : (isSelected ? theme.current.accentPrimary.opacity(0.7) : theme.current.separator.opacity(0.5))),
            lineWidth: isP || isS || isSelected ? 1.5 : 0.5))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tierColor(svc.tier))
                .frame(width: 4).padding(.vertical, 10)
        }
        .opacity(dimmed ? 0.3 : 1)
        .contentShape(Rectangle())

    }

    private func badge(_ text: String, active: Bool = false, tint: Color? = nil) -> some View {
        let color = tint ?? (active ? theme.current.accentPrimary : theme.current.textMuted)
        return Text(text).font(fm.font(8.5).weight(.semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.4), lineWidth: 0.5))
            .foregroundStyle(color)
    }

    // MARK: 详情面板

    @ViewBuilder private func inlineDetail(_ svc: BizService) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(svc.pkg) · \(svc.c) commits/6mo").font(fm.font(10)).foregroundStyle(theme.current.textMuted)
            if let recent = svc.recent, !recent.isEmpty {
                if let nf = svc.newFacades, nf > 0 {
                    Text("新增 \(nf) 个 Facade").font(fm.font(10))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                        .foregroundStyle(Color.orange)
                }
            }
            if !svc.routing.isEmpty {
                section("路由关键词") { chipFlow(svc.routing, clickable: false) }
            }
            if !svc.related.isEmpty {
                section("关联服务") { chipFlow(svc.related, clickable: true) }
            }
            if !svc.dItems.isEmpty {
                section("D 单 (\(svc.dItems.count))") {
                    ForEach(svc.dItems) { d in
                        HStack(spacing: 4) {
                            Text(d.id).font(fm.font(9.5).weight(.bold)).foregroundStyle(hitPrimary)
                            Text(d.title).font(fm.font(9.5)).foregroundStyle(theme.current.textSecondary).lineLimit(1)
                        }
                    }
                }
            }
            if !svc.prds.isEmpty {
                section("PRD (\(svc.prds.count))") {
                    ForEach(svc.prds) { p in
                        HStack(spacing: 4) {
                            Text(p.no).font(fm.font(9).weight(.bold)).foregroundStyle(prdBlue)
                            Text(p.status).font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                            Text(p.name).font(fm.font(9.5)).foregroundStyle(theme.current.textSecondary).lineLimit(1)
                        }
                    }
                }
            }
            Button(action: { vm.openDoc(svc) }) {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text").font(.system(size: 9))
                    Text(svc.mapLevel == "L2" ? "作战地图" : "服务总览").font(fm.font(10).weight(.medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(prdBlue.opacity(0.08)))
                .foregroundStyle(prdBlue)
            }.buttonStyle(.plain)
        }
    }

    private func detailPane(_ svc: BizService) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(svc.name).font(fm.font(16).weight(.bold)).foregroundStyle(theme.current.textPrimary)
                    badge(svc.mapLevel, active: svc.mapLevel == "L2")
                    Spacer()
                    Button(action: { vm.selected = nil }) { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(theme.current.textMuted)
                }
                Text("\(svc.pkg) · \(svc.c) commits/6mo").font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                if !svc.branch.isEmpty {
                    Text("基线 \(svc.branch)\(svc.div.isEmpty ? "" : "（\(svc.div)）")")
                        .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                }
                section("定位") {
                    Text(svc.desc).font(fm.font(11)).foregroundStyle(theme.current.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let recent = svc.recent, !recent.isEmpty {
                    section("近期变化") {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles").font(.system(size: 10))
                                .foregroundStyle(Color.accentColor)
                            Text(recent).font(fm.font(11)).foregroundStyle(theme.current.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let nf = svc.newFacades, nf > 0 {
                            Text("新增 \(nf) 个 Facade").font(fm.font(10))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.12)))
                                .foregroundStyle(Color.orange)
                        }
                    }
                }
                if !svc.routing.isEmpty {
                    section("需求路由关键词") { chipFlow(svc.routing, clickable: false) }
                }
                if !svc.related.isEmpty {
                    section("强关联服务") { chipFlow(svc.related, clickable: true) }
                }
                if !svc.dItems.isEmpty {
                    section("关联 D 单") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(svc.dItems) { d in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(d.id).font(fm.font(10).weight(.bold)).foregroundStyle(hitPrimary)
                                        Text("#\(d.status)").font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                                    }
                                    Text(d.title).font(fm.font(10.5)).foregroundStyle(theme.current.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.current.separator.opacity(0.3)))
                            }
                        }
                    }
                }
                if !svc.prds.isEmpty {
                    section("关联 PRD 需求 (\(svc.prds.count))") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(svc.prds) { p in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(p.no).font(fm.font(9).weight(.bold)).foregroundStyle(prdBlue)
                                        if let pri = p.pri {
                                            Text(pri).font(fm.font(8.5).weight(.bold))
                                                .foregroundStyle(pri == "P0" ? Color.red : theme.current.textMuted)
                                        }
                                        Text(p.status).font(fm.font(9))
                                            .foregroundStyle(p.code == "SJWC" ? hitPrimary : theme.current.textMuted)
                                        if p.scopes.contains("mine") {
                                            Text("我参与").font(fm.font(8.5))
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Capsule().fill(prdBlue.opacity(0.14)))
                                                .foregroundStyle(prdBlue)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    Text(p.name).font(fm.font(10.5)).foregroundStyle(theme.current.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 8) {
                                        if let dev = p.dev, !dev.isEmpty {
                                            Text("开发 \(dev)").font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                                        }
                                        Button("PRD明细") { vm.openURL(p.url) }
                                            .buttonStyle(.plain).font(fm.font(9).weight(.medium)).foregroundStyle(prdBlue)
                                        if let doc = p.docs.first {
                                            Button("需求文档") { vm.openURL(doc) }
                                                .buttonStyle(.plain).font(fm.font(9).weight(.medium)).foregroundStyle(prdBlue)
                                        }
                                    }
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(prdBlue.opacity(0.06)))
                            }
                        }
                    }
                }
                Button(action: { vm.openDoc(svc) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text").font(.system(size: 10))
                        Text(svc.mapLevel == "L2" ? "打开作战地图" : "打开服务总览").font(fm.font(11).weight(.medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.current.accentPrimary.opacity(0.14)))
                    .foregroundStyle(theme.current.accentPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(fm.font(9.5).weight(.semibold)).foregroundStyle(theme.current.textMuted)
            content()
        }
    }

    /// 简易 chip 流式布局 (够用即可, 不引入 Layout 协议复杂度)
    private func chipFlow(_ items: [String], clickable: Bool) -> some View {
        FlowChips(items: items, clickable: clickable) { name in
            if clickable, let target = vm.service(name) { vm.selected = target }
        }
        .environmentObject(theme).environmentObject(fm)
    }

    // MARK: 需求流 —— 首屏英雄区(我的) + 组内分栏, 告别全量平铺

    private var requirementList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if vm.authExpired {
                    authBanner
                }
                if vm.prdItems.isEmpty {
                    VStack(spacing: 6) {
                        Text(vm.authExpired ? "没有旧数据兜底，需求流暂时为空" : "还没有 PRD 需求快照")
                            .font(fm.font(12)).foregroundStyle(theme.current.textMuted)
                        Text("对 AI 说「刷新PRD」拉取并标注").font(fm.font(10.5)).foregroundStyle(theme.current.textMuted.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity).padding(.top, vm.authExpired ? 24 : 60)
                } else if !vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 搜索时直出全量命中, 不受分栏限制
                    let hits = vm.filteredPRD
                    if hits.isEmpty {
                        Text("没有匹配的需求，请换个筛选词").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        sectionLabel("搜索结果", hits.count, tint: prdBlue)
                        ForEach(hits) { prdRow($0) }
                    }
                } else {
                    // 英雄区: 我正在参与的
                    HStack(spacing: 8) {
                        sectionLabel("我的进行中", vm.myActive.count, tint: prdBlue)
                        Spacer()
                        if vm.syncAllRunning {
                            ProgressView().controlSize(.mini)
                        } else {
                            let pending = vm.myActive.filter { vm.syncStatus[$0.name] != "synced" || vm.syncChanged.contains($0.name) }.count
                            if pending > 0 {
                                Button(action: { vm.syncAll() }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 10))
                                        Text("同步/更新(\(pending))").font(fm.font(9.5).weight(.medium))
                                    }
                                }
                                .buttonStyle(.plain).foregroundStyle(prdBlue)
                            }
                        }
                        Link(destination: URL(string: "https://alidocs.dingtalk.com/i/nodes/YQBnd5ExVEwGvKM7H20q9bEL8yeZqMmz?entrance=data&sheetId=VLDMsZx")!) {
                            HStack(spacing: 3) {
                                Image(systemName: "tablecells").font(.system(size: 10))
                                Text("项目表").font(fm.font(9.5).weight(.medium))
                                Image(systemName: "arrow.up.right").font(.system(size: 7))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(prdBlue.opacity(0.10)))
                            .foregroundStyle(prdBlue)
                        }
                        Button {
                            vm.showTableProjects = true
                            vm.loadTableProjects()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "person.2.fill").font(.system(size: 9))
                                Text(vm.tableProjectsLoaded ? "我参与的(\(vm.tableProjects.count))" : "我参与的")
                                    .font(fm.font(9.5).weight(.medium))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(prdBlue.opacity(0.10)))
                            .foregroundStyle(prdBlue)
                        }
                        .buttonStyle(.plain)
                    }
                    if vm.myActive.isEmpty {
                        Text("暂无我进行中的需求").font(fm.font(10.5)).foregroundStyle(theme.current.textMuted)
                            .padding(.leading, 2)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                            ForEach(vm.myActive) { prdRow($0, hero: true) }
                        }
                    }
                    if !vm.myCompleted.isEmpty {
                        DisclosureGroup("我的已完成（\(vm.myCompleted.count)）") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                                ForEach(vm.myCompleted) { prdRow($0) }
                            }.padding(.top, 8)
                        }
                        .font(fm.font(12)).foregroundStyle(theme.current.textSecondary)
                    }
                    groupTabs.padding(.top, 8)
                    let items = vm.tabItems(vm.reqTab)
                    if items.isEmpty {
                        Text("这一栏是空的")
                            .font(fm.font(10.5)).foregroundStyle(theme.current.textMuted)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                            ForEach(items) { prdRow($0) }
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    /// 登录态失效横幅: 打开登录页(浏览器授权) 或 粘贴新 Cookie(验证通过后自动刷新)
    private var authBanner: some View {
        let red = Color.red
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).foregroundStyle(red)
            VStack(alignment: .leading, spacing: 2) {
                Text("ai.tmallyc.com 登录态已失效").font(fm.font(12.5).weight(.semibold)).foregroundStyle(red)
                Text("在 Chrome 登录 ai.tmallyc.com 后，Cookie Bridge 会自动同步并刷新需求；未安装扩展可点「一键提取」。")
                    .font(fm.font(10.5)).foregroundStyle(theme.current.textSecondary)
            }
            Spacer(minLength: 8)
            Button(action: { vm.extractFromBrowsers() }) {
                Text("一键提取登录态").font(fm.font(10.5).weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(prdBlue))
                    .foregroundStyle(.white)
            }.buttonStyle(.plain)
            Button(action: { vm.cookieInput = ""; vm.cookieError = nil; vm.showCookieSheet = true }) {
                Text("粘贴 Cookie").font(fm.font(10.5).weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(red.opacity(0.14)))
                    .foregroundStyle(red)
            }.buttonStyle(.plain)
            Button(action: { vm.openURL("https://ai.tmallyc.com/prd/index.html") }) {
                Text("浏览器登录").font(fm.font(10)).foregroundStyle(theme.current.accentPrimary)
            }.buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(red.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(red.opacity(0.35), lineWidth: 1))
    }

    private var tableProjectsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells.fill").font(.system(size: 13)).foregroundStyle(prdBlue)
                Text("项目表 · 我参与的项目").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.current.textPrimary)
                if !vm.tableProjectsLoading {
                    Text("\(vm.tableProjects.count)").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(prdBlue.opacity(0.12))).foregroundStyle(prdBlue)
                }
                Spacer()
                Button(action: { vm.loadTableProjects() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(theme.current.textSecondary)
                .disabled(vm.tableProjectsLoading)
                Button(action: { vm.showTableProjects = false }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            Divider()
            if vm.tableProjectsLoading && vm.tableProjects.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在从项目表拉取…").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.tableProjects.isEmpty {
                Text("表里没有以你为开发的项目").font(fm.font(11))
                    .foregroundStyle(theme.current.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(vm.tableProjects) { proj in
                            tableProjCard(proj)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 580, height: 470)
    }

    private func tableProjCard(_ proj: TableProject) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text(proj.name).font(fm.font(12.5).weight(.semibold))
                    .foregroundStyle(theme.current.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                let requirement = vm.tableProjectRequirement(proj)
                let stage = proj.displayStage(requirement: requirement)
                if proj.role == "member" {
                    Text("成员").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(stage.label)
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(stage.tint.opacity(0.12)))
                    .foregroundStyle(stage.tint)
            }
            if !proj.desc.isEmpty {
                Text(proj.desc).font(fm.font(10.5))
                    .foregroundStyle(theme.current.textSecondary)
                    .lineLimit(3)
            }
            HStack(spacing: 5) {
                if !proj.product.isEmpty { tableChip("产品 · \(proj.product)", tint: prdBlue) }
                if !proj.domain.isEmpty { tableChip(proj.domain, tint: Color(hex: "#7c3aed")) }
                if !proj.tags.isEmpty { tableChip(proj.tags, tint: Color(hex: "#0891b2")) }
                Spacer(minLength: 4)
                dateHint("PRD", proj.submit, theme.current.textMuted)
                dateHint("开发", proj.devStart, theme.current.textMuted)
                dateHint("提测", proj.test ?? "", theme.current.textMuted)
                dateHint("上线", proj.online, Color.green)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.gray.opacity(0.12), lineWidth: 0.5))
    }

    private func dateHint(_ label: String, _ date: String, _ tint: Color) -> some View {
        Group {
            if date.isEmpty {
                EmptyView()
            } else {
                Text("\(label) \(date.dropFirst(5))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tint)
            }
        }
    }

    private var cookieSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("更新 PRD 登录 Cookie").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("浏览器登录") { vm.openURL("https://ai.tmallyc.com/prd/index.html") }
                    .buttonStyle(.link).font(.system(size: 11))
                Button(action: { vm.showCookieSheet = false }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Chrome：点「安装 Chrome 桥」装一次扩展，之后在 Chrome 登录即自动投递给 DBoard，不用再管")
                Text("Qoder 系内置浏览器：登录过即可被「从浏览器提取」直接读取；兜底走 DevTools 复制 Cookie 粘贴")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $vm.cookieInput)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            if let e = vm.cookieError {
                Text(e).font(.system(size: 11)).foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if vm.cookieFDAHint && !vm.cookieBusy {
                HStack(spacing: 8) {
                    Button("打开隐私设置") { vm.openPrivacySettings() }
                    Text("在列表中找到并勾选 DBoard，然后回来重启生效").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Button("重启 DBoard") { vm.restartApp() }
                }
                .font(.system(size: 11))
            }
            HStack(spacing: 10) {
                Button("从浏览器提取") { vm.extractFromBrowsers() }
                    .disabled(vm.cookieBusy)
                Button("安装 Chrome 桥") { vm.installCookieBridge() }
                Spacer()
                Button("取消") { vm.showCookieSheet = false }
                if vm.cookieBusy {
                    ProgressView().controlSize(.small)
                }
                Button("保存并刷新") {
                    vm.cookieBusy = true; vm.cookieError = nil
                    vm.saveCookieAndRefresh(vm.cookieInput) { ok, msg in
                        vm.cookieBusy = false
                        if ok { vm.showCookieSheet = false } else { vm.cookieError = msg }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.cookieBusy || vm.cookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func sectionLabel(_ title: String, _ n: Int, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(title).font(fm.font(11.5).weight(.semibold)).foregroundStyle(tint)
            Text("\(n)").font(fm.font(9.5))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(theme.current.separator.opacity(0.5)))
                .foregroundStyle(theme.current.textMuted)
        }
    }

    /// 组内分栏
    private var groupTabs: some View {
        HStack(spacing: 6) {
            Text("组内").font(fm.font(11.5).weight(.semibold)).foregroundStyle(theme.current.textSecondary)
            ForEach(ReqTab.allCases, id: \.self) { t in
                let active = vm.reqTab == t
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { vm.reqTab = t } }) {
                    HStack(spacing: 4) {
                        Text(t.rawValue).font(fm.font(10.5).weight(active ? .bold : .regular))
                        Text("\(vm.tabItems(t).count)").font(fm.font(9))
                            .foregroundStyle(active ? theme.current.accentPrimary : theme.current.textMuted.opacity(0.7))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(Capsule().fill(active ? theme.current.accentPrimary.opacity(0.14) : theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.5)))
                    .overlay(Capsule().stroke(active ? theme.current.accentPrimary.opacity(0.4) : theme.current.separator, lineWidth: 0.5))
                    .foregroundStyle(active ? theme.current.accentPrimary : theme.current.textMuted)
                }
                .buttonStyle(.plain)
            }
            Spacer()

        }
    }

    private func prdRow(_ p: BizPRDItem, hero: Bool = false) -> some View {
        let open = vm.expandedPRD.contains(p.id)
        let stateColor: Color = p.code == "CPYSWC" ? .green : p.code == "SJWC" || p.code == "FASJWC" ? .orange : .accentColor
        let completed = vm.deliverableStatus[p.id] ?? []
        let expected = p.code == "KFZ" || p.code == "KFWC" ? ["solution", "dev"] : p.code == "SJWC" || p.code == "FASJWC" ? ["solution"] : ["solution", "dev", "test"]
        let completedCount = expected.filter { completed.contains($0) }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(p.name).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if hero {
                    let sync = vm.syncStatus[p.name] ?? "unsynced"
                    if sync == "syncing" { ProgressView().controlSize(.small) }
                    else if sync == "synced" && !vm.syncChanged.contains(p.name) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Button { vm.syncOne(name: p.name) } label: {
                            Image(systemName: sync == "error" ? "exclamationmark.arrow.circlepath" : "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(sync == "error" ? Color.orange : Color.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                Text(p.no).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text(p.status).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(stateColor).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(stateColor.opacity(0.08), in: Capsule())
                if let developer = p.dev, !developer.isEmpty {
                    Label(developer, systemImage: "person").font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let priority = p.pri {
                    Text(priority).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(priority == "P0" ? Color.red : Color.secondary)
                }
            }
            HStack(spacing: 8) {
                Button { togglePRD(p.id) } label: {
                    Label(open ? "收起" : "详情", systemImage: open ? "chevron.up" : "chevron.down")
                }
                Button { vm.openURL(p.url) } label: {
                    Label("网页详情", systemImage: "arrow.up.right.square")
                }
                if hero || p.scopes.contains("pending") {
                    if let next = nextStatus(p.code) {
                        Button(next.name) { vm.pushStatus(reqId: p.id, toStatus: next.code, actionName: next.name) }
                            .disabled(vm.statusSubmitting.contains(p.id))
                    }
                    Button("交付物") { vm.uploadDeliverable(reqId: p.id, reqNo: p.no, code: p.code) }
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered).controlSize(.small)
            if hero {
                HStack(spacing: 8) {
                    Label("交付物 \(completedCount)/\(expected.count)", systemImage: "doc.text")
                        .foregroundStyle(completedCount == expected.count ? Color.secondary : Color.orange)
                    Spacer()
                    if let time = p.flow?.first?.t { Text(time).foregroundStyle(.secondary) }
                }.font(.system(size: 11))
            }
            if open { Divider(); prdDetail(p) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.current.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            open ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    private func togglePRD(_ id: Int) {
        withAnimation(DBoardUI.spring) {
            if vm.expandedPRD.contains(id) { vm.expandedPRD.remove(id) }
            else {
                vm.expandedPRD.insert(id)
                if refreshOnAppear { vm.loadDeliverableStatus(reqId: id) }
            }
        }
    }

    private var deliverableSheet: some View {
        let typeName: String = {
            switch vm.deliverableCode {
            case "SJWC", "FASJWC": return "方案交付物"
            case "KFZ", "KFWC": return "开发交付物"
            case "CSZ", "CSWC": return "测试交付物"
            default: return "开发交付物"
            }
        }()
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("上传\(typeName)").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { vm.showDeliverablePanel = false }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }

            if let reqId = vm.deliverableReqId, let items = vm.deliverableItems[reqId], !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已有交付物").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    let order = ["solution", "ui", "dev", "test"]
                    let labels = ["solution": "方案", "ui": "设计", "dev": "开发", "test": "测试"]
                    ForEach(order, id: \.self) { tag in
                        let tagItems = items.filter { ($0["_tag"] as? String) == tag }
                        if !tagItems.isEmpty {
                            ForEach(tagItems.indices, id: \.self) { idx in
                                let it = tagItems[idx]
                                let content = (it["deliverableContent"] as? String ?? "")
                                let author = (it["authorName"] as? String ?? "").components(separatedBy: " - ").last ?? ""
                                HStack(spacing: 5) {
                                    Text(labels[tag] ?? tag).font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.blue.opacity(0.1)))
                                        .foregroundStyle(.blue)
                                    Text(content.isEmpty ? "(无内容)" : String(content.prefix(40)))
                                        .font(.system(size: 10)).foregroundStyle(.primary).lineLimit(1)
                                    Spacer()
                                    Text(author).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
                Divider()
                Text("补充新交付物").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("内容/链接").font(fm.font(10.5)).foregroundStyle(theme.current.textMuted)
                TextField("输入交付物描述或粘贴链接", text: $vm.deliverableContent)
                    .textFieldStyle(.roundedBorder).font(fm.font(11.5))
            }

            if true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("工程与分支").font(fm.font(10.5)).foregroundStyle(theme.current.textMuted)
                    if !vm.deliverableProjects.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(vm.deliverableProjects.indices, id: \.self) { i in
                                    HStack(spacing: 3) {
                                        Text("\(vm.deliverableProjects[i].app):\(vm.deliverableProjects[i].branch)")
                                            .font(fm.font(10))
                                        Button(action: { vm.deliverableProjects.remove(at: i) }) {
                                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                                        }.buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(prdBlue.opacity(0.1)))
                                    .foregroundStyle(prdBlue)
                                }
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("搜索仓库", text: $vm.devAppQuery)
                                .textFieldStyle(.roundedBorder).font(fm.font(10.5))
                                .frame(width: 140)
                                .onChange(of: vm.devAppQuery) { _, value in
                                    guard value != vm.devSelectedApp?.name else { return }
                                    vm.devSelectedApp = nil
                                    vm.searchApps()
                                }
                            if !vm.devAppResults.isEmpty && vm.devSelectedApp == nil {
                                List(vm.devAppResults, id: \.id) { app in
                                    Button {
                                        vm.devSelectedApp = app
                                        vm.devAppQuery = app.name
                                        vm.devAppResults = []
                                        vm.devBranchQuery = ""
                                        vm.searchBranches()
                                    } label: {
                                        Text(app.name).font(fm.font(12))
                                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                                .listStyle(.plain)
                                .frame(width: 140, height: min(CGFloat(vm.devAppResults.count) * 36, 160))
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.current.cardFill).shadow(radius: 4))
                            }
                        }
                        if vm.devSelectedApp != nil {
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("搜索分支", text: $vm.devBranchQuery)
                                    .textFieldStyle(.roundedBorder).font(fm.font(10.5))
                                    .frame(width: 190)
                                    .onChange(of: vm.devBranchQuery) { _ in vm.searchBranches() }
                                if !vm.devBranchResults.isEmpty {
                                    List(vm.devBranchResults, id: \.self) { branch in
                                        Button { vm.addDevProject(branch: branch) } label: {
                                            Text(branch).font(fm.font(11))
                                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                    }
                                    .listStyle(.plain)
                                    .frame(width: 190, height: min(CGFloat(vm.devBranchResults.count) * 36, 180))
                                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.current.cardFill).shadow(radius: 4))
                                }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Text("附件").font(fm.font(10.5)).foregroundStyle(theme.current.textMuted)
                Button(action: { vm.pickDeliverableFile() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "paperclip").font(.system(size: 10))
                        Text(vm.deliverableFile?.lastPathComponent ?? "选择文件").font(fm.font(10.5))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(theme.current.separator.opacity(0.3)))
                    .foregroundStyle(theme.current.textSecondary)
                }.buttonStyle(.plain)
                if vm.deliverableFile != nil {
                    Button(action: { vm.deliverableFile = nil }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                            .foregroundStyle(theme.current.textMuted)
                    }.buttonStyle(.plain)
                }
            }

            Button(action: { vm.submitDeliverable() }) {
                HStack {
                    Spacer()
                    if vm.deliverableUploading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("提交交付物").font(.system(size: 12, weight: .medium))
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.deliverableContent.isEmpty && vm.deliverableFile == nil && vm.deliverableProjects.isEmpty)
        }
        .padding(20)
        .frame(width: 380)
    }

    private func nextStatus(_ code: String) -> (code: String, name: String)? {
        switch code {
        case "SJWC":  return ("KFZ", "开始开发")
        case "KFZ":   return ("KFWC", "开发完成")
        case "KFWC":  return ("CSZ", "开始测试")
        case "CSZ":   return ("CSWC", "测试完成")
        default: return nil
        }
    }

    /// 展开详情: 正文 / 人员 / 流转 / 开发交付声明 / 交付物记录
    @ViewBuilder private func prdDetail(_ p: BizPRDItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5).padding(.vertical, 1)

            if let d = p.desc, !d.isEmpty {
                detailBlock("需求正文", d)
            }
            if let v = p.value, !v.isEmpty {
                detailBlock("业务价值", v)
            }

            // 人与时间轴
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    if let s = p.submitter, !s.isEmpty { metaItem("提出", s) }
                    if let o = p.owner, !o.isEmpty { metaItem("承接", o) }
                    if let pd = p.pending, !pd.isEmpty { metaItem("当前卡在", pd, tint: hitPrimary) }
                }
                HStack(spacing: 10) {
                    if let st = p.submitTime, !st.isEmpty { metaItem("提交", st) }
                    if let ot = p.onlineTime, !ot.isEmpty { metaItem("上线", ot) }
                    if let tg = p.tags, !tg.isEmpty { metaItem("标签", tg, tint: prdBlue) }
                }
                if let dt = p.devTeam, !dt.isEmpty {
                    metaItem("开发团队", dt.joined(separator: " · "))
                }
                if let tt = p.testTeam, !tt.isEmpty {
                    metaItem("测试", tt.joined(separator: " · "))
                }
            }

            if let flow = p.flow, !flow.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("流转记录").font(fm.font(9.5).weight(.semibold)).foregroundStyle(theme.current.textMuted)
                    ForEach(Array(flow.enumerated()), id: \.offset) { _, f in
                        HStack(spacing: 5) {
                            Text(f.t).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.current.textMuted)
                            Text("\(f.from) → \(f.to)").font(fm.font(9.5))
                                .foregroundStyle(theme.current.textSecondary)
                            Text(f.by).font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                        }
                    }
                }
            }

            DevelopmentProjectsView(snapshot: vm.developmentProjectSnapshots[p.id],
                loading: vm.deliverableLoading.contains(p.id), error: vm.deliverableReadErrors[p.id],
                refresh: { vm.loadDeliverableStatus(reqId: p.id, force: true) })

            // 官方交付物: 链接按阶段分组与附件文件
            deliverableSection(p)

            // 实时交付物记录（从 API 拉取）
            if let items = vm.deliverableItems[p.id], !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("交付物记录").font(fm.font(9.5).weight(.semibold)).foregroundStyle(theme.current.textMuted)
                    ForEach(items.indices, id: \.self) { idx in
                        let item = items[idx]
                        let tag = item["_tag"] as? String ?? ""
                        let tagLabel = tag == "dev" ? "开发" : (tag == "test" ? "测试" : (tag == "solution" ? "方案" : "设计"))
                        let content = item["deliverableContent"] as? String ?? ""
                        let author = (item["authorName"] as? String ?? "").components(separatedBy: " - ").last ?? ""
                        let time = String((item["createTime"] as? String ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(tagLabel).font(fm.font(8.5).weight(.medium))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(prdBlue.opacity(0.1)))
                                    .foregroundStyle(prdBlue)
                                Text(author).font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                                Text(time).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(theme.current.textMuted)
                            }
                            if !content.isEmpty {
                                Text(content).font(fm.font(9.5)).foregroundStyle(theme.current.textSecondary)
                                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            if tag == "dev", let proj = item["deliverableDevProject"] as? String, !proj.isEmpty {
                                Text(proj.replacingOccurrences(of: ";", with: "\n")).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.current.textMuted).lineLimit(5)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.current.separator.opacity(0.15)))
                    }
                    Button(action: { vm.uploadDeliverable(reqId: p.id, reqNo: p.no, code: p.code) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "plus.circle").font(.system(size: 9))
                            Text("补充交付物").font(fm.font(9.5))
                        }.foregroundStyle(prdBlue)
                    }.buttonStyle(.plain).padding(.top, 2)
                }
            }


        }
        .padding(.top, 2)
    }

    /// 交付物区块: 来自 PRD 官方 deliverable 接口, 按阶段分组展示
    @ViewBuilder private func deliverableSection(_ p: BizPRDItem) -> some View {
        let docs = p.delivDocs ?? []
        let files = p.files ?? []
        if !docs.isEmpty || !files.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("交付物").font(fm.font(9.5).weight(.semibold)).foregroundStyle(theme.current.textMuted)
                ForEach(files) { f in
                    Button(action: { vm.openURL(f.url) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip").font(.system(size: 8.5))
                            Text(f.name).font(fm.font(9.5)).lineLimit(1)
                        }
                        .foregroundStyle(prdBlue)
                    }
                    .buttonStyle(.plain)
                }
                if !docs.isEmpty {
                    let stage = [1: "方案", 2: "设计", 3: "开发", 4: "测试"]
                    FlowChipsLinks(items: docs.map { d in
                        (label: "\(stage[d.t] ?? "文档")·\(shortHost(d.url))", url: d.url)
                    }) { vm.openURL($0) }
                    .environmentObject(theme).environmentObject(fm)
                }

            }
        }
    }

    private func shortHost(_ url: String) -> String {
        if url.contains("alidocs.dingtalk") { return "钉文档" }
        if url.contains("done.alibaba") { return "D-ONE" }
        if url.contains("devops.aliyun") { return "云效" }
        if url.contains("zlcx-upload") { return "附件" }
        return URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "链接"
    }

    private func detailBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(fm.font(9.5).weight(.semibold)).foregroundStyle(theme.current.textMuted)
            Text(body).font(fm.font(10.5)).foregroundStyle(theme.current.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func metaItem(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(spacing: 3) {
            Text(label).font(fm.font(9)).foregroundStyle(theme.current.textMuted)
            Text(value).font(fm.font(9.5)).foregroundStyle(tint ?? theme.current.textSecondary)
        }
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 20, weight: .light))
                .foregroundStyle(theme.current.textMuted.opacity(0.6))
            Text(msg).font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("重跑生成器") { vm.regenerate() }.font(fm.font(11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(vm.perspective == .requirements ? "工程信息来源：开发交付声明 · 缺失留空" : "服务文档目录 · 业务职责与路由仅供参考")
                .font(fm.font(9)).foregroundStyle(theme.current.textMuted)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(theme.current.chrome.opacity(0.15))
    }
}

// MARK: - chip 流式布局

/// 带链接的 chip 流: 交付物链接按阶段分组展示, 点即打开
private struct FlowChipsLinks: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let items: [(label: String, url: String)]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.url) { it in
                Button(action: { onTap(it.url) }) {
                    Text(it.label).font(fm.font(9)).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(prdBlue.opacity(0.08)))
                        .overlay(Capsule().stroke(prdBlue.opacity(0.35), lineWidth: 0.5))
                        .foregroundStyle(prdBlue)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FlowChips: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let items: [String]
    let clickable: Bool
    let onTap: (String) -> Void

    var body: some View {
        // 固定宽度详情栏内用简单换行网格即可
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { it in
                if clickable {
                    Button { onTap(it) } label: { chip(it) }.buttonStyle(.plain)
                } else { chip(it) }
            }
        }
    }
    private func chip(_ text: String) -> some View {
        Text(text).font(fm.font(11)).lineLimit(1)
            .padding(.horizontal, 8).frame(minHeight: 28)
            .background(Capsule().fill(theme.current.separator.opacity(0.35)))
            .overlay(Capsule().stroke(theme.current.separator, lineWidth: 0.5))
            .foregroundStyle(clickable ? theme.current.accentPrimary : theme.current.textSecondary)
            .contentShape(Rectangle())
    }

}

// MARK: - 窗口控制器 (popover + 撕出, 与 SkillsBoard 同一套模式)

final class BizMapBoardWindowController {
    static let shared = BizMapBoardWindowController()
    private var window: NSWindow?
    private var popover: NSPopover?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private let tearOff = TearOffObserver()
    private var popCloseObserver: Any?
    let vm = BizMapViewModel()
    private var windowInteraction: WorkspaceWindowInteraction?
    private var windowKeyMonitor: Any?

    func receiveBridgedCookie(_ header: String) {
        vm.receiveBridgedCookie(header)
    }

    func receiveAudiSession(_ cookie: HTTPCookie) {
        vm.receiveAudiSession(cookie)
    }

    func togglePopover(relativeTo button: NSStatusBarButton) {
        if let pop = popover, pop.isShown {
            closePopover()
            return
        }
        let screenH = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let popH = min(max(screenH * 0.72, 420), 860)
        let popW: CGFloat = 680    // 卡片墙(2列) + 详情面板 262

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let host = NSHostingController(rootView:
            BizMapBoardView(popoverMode: true)
                .environmentObject(vm)
                .environmentObject(ThemeManager.shared)
                .environmentObject(FontManager.shared)
                .frame(width: popW, height: popH))
        pop.contentSize = NSSize(width: popW, height: popH)
        pop.contentViewController = host
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = pop
        vm.load()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.popover, p.isShown else { return }
            DispatchQueue.main.async { self.closePopover() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 53, let popover = self.popover, popover.isShown,
                  let window = popover.contentViewController?.view.window,
                  e.window === window, window.attachedSheet == nil else { return e }
            if self.vm.selected != nil { self.vm.selected = nil }
            else if !self.vm.expandedPRD.isEmpty { self.vm.expandedPRD = [] }
            else if !self.vm.query.isEmpty { self.vm.query = "" }
            else { self.closePopover() }
            return nil
        }
        popCloseObserver = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: pop, queue: .main) { [weak self] _ in
            self?.teardownMonitors()
        }
        installTearOffObserver()
    }

    private func installTearOffObserver() {
        tearOff.install(key: "BizMapBoard") { [weak self] in
            guard let self = self else { return }
            self.closePopover()
            self.show()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
        teardownMonitors()
    }

    private func teardownMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let o = popCloseObserver { NotificationCenter.default.removeObserver(o); popCloseObserver = nil }
    }

    func updateTitle() {
        window?.title = vm.perspective == .requirements ? "ReqFlow 需求流" : "BizMap 业务地图"
    }

    func showRequirement(no: String? = nil) {
        vm.perspective = .requirements
        vm.query = no ?? ""
        show()
    }

    func showRequirement(link: ReqFlowLink) {
        vm.load()
        if vm.focusRequirement(link) {
            vm.loadDeliverableStatus(reqId: link.id)
            show()
        } else {
            // Terminal or out-of-scope requirements may no longer be in the active snapshot.
            vm.openURL(link.url)
        }
    }

    /// 居中浮窗开关 (⌃E 热键入口): 显示中则收起, 否则弹出并定位到需求视角
    func toggleWindow(requirements: Bool) {
        let target: BizPerspective = requirements ? .requirements : .services
        if let w = window, w.isVisible, vm.perspective == target, w.isKeyWindow {
            w.orderOut(nil)
            return
        }
        vm.perspective = target
        vm.load()
        show()
    }

    func show() {
        if let w = window {
            w.title = vm.perspective == .requirements ? "ReqFlow 需求流" : "BizMap 业务地图"
            centerWindowOnMouseScreen(w)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            vm.load()
            return
        }
        let view = BizMapBoardView()
            .environmentObject(vm)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = vm.perspective == .requirements ? "ReqFlow 需求流" : "BizMap 业务地图"
        win.titleVisibility = .visible
        win.titlebarAppearsTransparent = true
        win.setContentSize(NSSize(width: 980, height: 740))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        // 窗口透明度: 只在 nativeBlur 主题下透出桌面壁纸, 其它主题保持不透明避免顶栏透视
        let _needsTransparent = ThemeManager.shared.current.nativeBlur
        win.isOpaque = !_needsTransparent
        win.backgroundColor = _needsTransparent ? .clear : .windowBackgroundColor
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        win.contentMinSize = NSSize(width: 740, height: 540)
        win.setFrameAutosaveName("DBoardBizMapWindow")
        centerWindowOnMouseScreen(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
        windowInteraction = WorkspaceWindowInteraction(window: win, id: "bizmap", handlesEscape: false)
        windowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isVisible, event.window === window,
                  window.isKeyWindow, event.keyCode == 53, window.attachedSheet == nil else { return event }
            if self.vm.selected != nil { self.vm.selected = nil }
            else if !self.vm.expandedPRD.isEmpty { self.vm.expandedPRD.removeAll() }
            else if !self.vm.query.isEmpty { self.vm.query = "" }
            else { window.orderOut(nil) }
            return nil
        }
    }
}

// MARK: - URLSession 同步封装

extension URLSession {
    func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        var data: Data?, response: URLResponse?, error: Error?
        let sem = DispatchSemaphore(value: 0)
        dataTask(with: request) { d, r, e in
            data = d; response = r; error = e; sem.signal()
        }.resume()
        sem.wait()
        if let e = error { throw e }
        return (data ?? Data(), response ?? URLResponse())
    }
}
