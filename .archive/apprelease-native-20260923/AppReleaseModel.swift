import SwiftUI
import Combine

// MARK: - 应用发布台状态层（对齐 AppReleaseClient.jsx 的行为）

final class AppReleaseModel: ObservableObject {
    private enum Keys {
        static let token = "dboard.ar.token"
        static let appTabs = "dboard.ar.appTabs"
        static let selectedApp = "dboard.ar.selectedApp"
    }

    @Published var tokenInput = ""
    @Published var tokenEditorCollapsed = true
    @Published var pinned = false
    @Published var savedToken: String? {
        didSet { reschedulePolling() }
    }
    @Published var query = ""
    @Published var apps: [ReleaseApp] = []
    @Published var showAppDropdown = false
    @Published var appTabs: [StoredApp] = []
    @Published var selectedApp: ReleaseApp?
    @Published var goods: [ReleaseGood] = []
    @Published var replicas = 2
    @Published var envStates: [String: ReleaseEnvState] = [:]
    @Published var records: [String: [ReleaseRecord]] = AppReleaseModel.emptyRecords()

    static func emptyRecords() -> [String: [ReleaseRecord]] { ["pre": [], "prod": []] }
    @Published var loading = false
    @Published var addingApp = false
    @Published var busyAction: String?
    @Published var notice: (kind: String, text: String)?

    @Published var schedules: [ScheduleTask] = []

    @Published var showScheduleModal = false
    @Published var scheduleGoodID = ""
    @Published var scheduleDate = Date().addingTimeInterval(600)

    @Published var showCreateModal = false
    @Published var createMode = CreateMode.pre
    @Published var branchQuery = ""
    @Published var branchSuggestions: [String] = []
    @Published var branchLoading = false
    @Published var branchSearched = false
    @Published var creatingGood = false

    @Published var showTokenGuide = false

    let expandedEnvs: Set<String> = ["pre", "prod"]


    enum CreateMode: String, CaseIterable, Identifiable {
        case pre = "部署预发"
        case redeploy = "重制并部署线上"
        case schedule = "定时部署线上"
        var id: String { rawValue }
    }

    private var appSearchWork: DispatchWorkItem?
    private var branchSearchWork: DispatchWorkItem?
    private var branchRequestID = 0
    private var pollTimer: Timer?
    private var hasRestored = false
    private var lastFinishedTaskIDs: Set<String> = []
    private let defaults = UserDefaults.standard

    init() {
        let token = defaults.string(forKey: Keys.token) ?? ""
        if !token.isEmpty {
            tokenInput = token
            savedToken = token
        }
        if let data = defaults.data(forKey: Keys.appTabs),
           let tabs = try? JSONDecoder().decode([StoredApp].self, from: data) {
            appTabs = tabs.filter { !$0.id.isEmpty }
        }
        if let data = defaults.data(forKey: Keys.selectedApp),
           let saved = try? JSONDecoder().decode(StoredApp.self, from: data) {
            if !appTabs.contains(where: { $0.id == saved.id }) {
                appTabs.insert(saved, at: 0)
            }
            selectedApp = saved.app
        }
    }

    // MARK: token

    func saveToken() {
        let value = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return noticeMsg("error", "请输入运维平台 token") }
        defaults.set(value, forKey: Keys.token)
        savedToken = value
        tokenEditorCollapsed = true
        noticeMsg("success", "token 已保存到本机。")
        loadSelectedAppIfNeeded()
    }

    func clearToken() {
        defaults.removeObject(forKey: Keys.token)
        tokenInput = ""
        savedToken = nil
        selectedApp = nil
        appTabs = []
        defaults.removeObject(forKey: Keys.appTabs)
        defaults.removeObject(forKey: Keys.selectedApp)
        goods = []
        envStates = [:]
        schedules = []
        noticeMsg("info", "本地 token 已清除。")
    }

    private func reschedulePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard savedToken != nil else { return }
        refreshSchedules()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refreshSchedules() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func refreshSchedules() {
        guard let token = savedToken else { return }
        schedules = AppReleaseScheduler.shared.snapshot(token: token)
    }

    // MARK: 应用搜索与选择

    func updateQuery(_ value: String) {
        query = value
        appSearchWork?.cancel()
        showAppDropdown = !value.trimmingCharacters(in: .whitespaces).isEmpty
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            apps = []
            return
        }
        guard savedToken != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.searchApps(keyword: value) }
        appSearchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func searchApps(keyword: String? = nil, silent: Bool = false) {
        guard let token = savedToken else {
            if !silent { noticeMsg("error", "请先填写并保存运维平台 token") }
            return
        }
        let kw = (keyword ?? query).trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else {
            if !silent { noticeMsg("error", "请输入应用名称") }
            return
        }
        if !silent {
            loading = true
            notice = nil
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try AppRelAPI.shared.call(.apps, token: token, params: ["name": kw])
                let list = arPickList(data).compactMap(ReleaseApp.parse)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !silent {
                        self.apps = list
                        self.showAppDropdown = true
                        if list.isEmpty { self.noticeMsg("info", "未找到匹配的应用，请检查名称或权限。") }
                    }
                    if !self.loading { self.refreshSchedules() } else { self.loading = false }
                }
            } catch {
                if !silent {
                    DispatchQueue.main.async {
                        self?.loading = false
                        self?.noticeMsg("error", error.localizedDescription)
                    }
                }
            }
            if !silent { DispatchQueue.main.async { self?.loading = false } }
        }
    }

    /// 按名称添加应用：唯一/精确匹配则直接选中并加载制品、清空输入框；多个匹配则弹下拉供选择
    func addAppByName() {
        guard let token = savedToken else { noticeMsg("error", "请先填写并保存运维平台 token"); return }
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { noticeMsg("error", "请输入应用名称"); return }
        addingApp = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<[ReleaseApp], Error>
            do {
                let data = try AppRelAPI.shared.call(.apps, token: token, params: ["name": kw])
                outcome = .success(arPickList(data).compactMap(ReleaseApp.parse))
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.addingApp = false
                switch outcome {
                case .failure(let error):
                    self.noticeMsg("error", error.localizedDescription)
                case .success(let list):
                    if list.isEmpty {
                        self.noticeMsg("info", "未找到应用「\(kw)」，请检查名称或权限。")
                        return
                    }
                    let target = list.first { $0.name.caseInsensitiveCompare(kw) == .orderedSame }
                        ?? (list.count == 1 ? list[0] : nil)
                    if let app = target {
                        self.query = ""
                        self.chooseApp(app)
                    } else {
                        self.apps = list
                        self.showAppDropdown = true
                        self.noticeMsg("info", "匹配到 \(list.count) 个应用，请在下拉中选择。")
                    }
                }
            }
        }
    }

    func chooseApp(_ app: ReleaseApp) {
        showAppDropdown = false
        query = ""
        apps = []
        records = Self.emptyRecords()
        selectedApp = app
        let stored = StoredApp(id: app.id, name: app.name, employeeName: app.employeeName)
        appTabs.removeAll { $0.id == app.id }
        appTabs.insert(stored, at: 0)
        if appTabs.count > 8 { appTabs = Array(appTabs.prefix(8)) }
        persistTabs()
        defaults.set(try? JSONEncoder().encode(stored), forKey: Keys.selectedApp)
        goods = []
        envStates = [:]
        notice = nil
        loadApp(app: app, errorPrefix: "加载应用信息失败：")
    }

    func removeAppTab(_ appID: String) {
        appTabs.removeAll { $0.id == appID }
        persistTabs()
        if selectedApp?.id != appID { return }
        if let next = appTabs.first {
            chooseApp(next.app)
            return
        }
        selectedApp = nil
        goods = []
        envStates = [:]
        defaults.removeObject(forKey: Keys.selectedApp)
    }

    private func persistTabs() {
        if let data = try? JSONEncoder().encode(appTabs) { defaults.set(data, forKey: Keys.appTabs) }
    }

    func loadSelectedAppIfNeeded() {
        guard !hasRestored, let token = savedToken, let app = selectedApp else { return }
        hasRestored = true
        if !token.isEmpty { loadApp(app: app, errorPrefix: "恢复已确认应用失败：") }
    }

    func refreshSelectedApp() {
        guard let app = selectedApp else { return }
        loadApp(app: app, errorPrefix: "刷新失败：")
    }

    /// 发起部署动作后自动刷新：立即一次，12 秒后再补一次（平台侧状态变化有延迟）
    func autoRefreshAfterDeploy() {
        refreshSelectedApp()
        let appID = selectedApp?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.selectedApp?.id == appID else { return }
            self.refreshSelectedApp()
        }
    }

    private func loadApp(app: ReleaseApp, errorPrefix: String) {
        guard let token = savedToken else { return }
        loading = true
        let appID = app.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [String: Any] = [:]
            var failure: Error?
            let lock = NSLock()
            let group = DispatchGroup()
            let tasks: [(String, AppRelAPI.OP, [String: Any])] = [
                ("goods", .goods, ["id": appID, "current_page": "1", "page_size": "50"]),
                ("detail", .appDetail, ["id": appID]),
                ("pre", .state, ["app_id": appID, "env_tag": "pre-i0"]),
                ("prod", .state, ["app_id": appID, "env_tag": "prod-i0"]),
                ("envs", .envList, ["app_id": appID]),
                ("hist-pre", .publishHistory, ["app_id": appID, "env_tag": "pre-i0", "page": "1", "pageSize": "10"]),
                ("hist-prod", .publishHistory, ["app_id": appID, "env_tag": "prod-i0", "page": "1", "pageSize": "10"]),
            ]
            for (key, op, params) in tasks {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    do {
                        let data = try AppRelAPI.shared.call(op, token: token, params: params)
                        lock.lock(); results[key] = data; lock.unlock()
                    } catch {
                        // 发布记录属于附属信息，拿不到不阻断主流程
                        if key.hasPrefix("hist-") { return }
                        lock.lock()
                        if failure == nil { failure = error }
                        lock.unlock()
                    }
                }
            }
            group.wait()
            if let failure {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading = false
                    self.noticeMsg("error", "\(errorPrefix)\(failure.localizedDescription)")
                }
                return
            }
            let parsedGoods = arPickList(results["goods"]).compactMap(ReleaseGood.parse)
            let nReplicas = Self.productionReplicas(envs: arDictList(results["envs"]), detail: arDict(results["detail"]))
            let pre = ReleaseEnvState.parse(results["pre"], appName: app.name)
            let prod = ReleaseEnvState.parse(results["prod"], appName: app.name)
            DispatchQueue.main.async {
                guard let self else { return }
                self.goods = parsedGoods
                self.replicas = nReplicas
                self.envStates = ["pre": pre, "prod": prod]
                self.records = [
                    "pre": Array(arPickList(results["hist-pre"]).prefix(3)).map(ReleaseRecord.parse),
                    "prod": Array(arPickList(results["hist-prod"]).prefix(3)).map(ReleaseRecord.parse),
                ]
                self.loading = false
            }
        }
    }

    static func productionReplicas(envs: [[String: Any]], detail: [String: Any]) -> Int {
        if let prod = envs.first(where: { (arStr($0, ["env"]) ?? "").lowercased() == "prod" }),
           let n = arInt(prod, ["replicas"]), n > 0 { return n }
        return findReplicas(detail)
    }

    static func findReplicas(_ detail: [String: Any]) -> Int {
        for v in [detail["new_replicas"], detail["replicas"], detail["replica_count"]] {
            if let n = v as? NSNumber, n.intValue > 0 { return n.intValue }
            if let s = v as? String, let i = Int(s), i > 0 { return i }
        }
        for sub in ["app", "detail"] {
            let d = arDict(detail[sub])
            if let v = arInt(d, ["new_replicas", "replicas"]), v > 0 { return v }
        }
        return 2
    }

    // MARK: 制品操作

    func productionPayload(good: ReleaseGood) -> [String: Any] {
        guard let app = selectedApp else { return [:] }
        return [
            "deploy_mode": 0,
            "env_tag": "prod-i0",
            "new_replicas": replicas,
            "old_goods_id": arNumID(good.id),
            "old_replicas": 0,
            "update_in_place": false,
            "new_goods_id": arNumID(good.id),
            "employee_name": Self.publisherName(fallback: app.employeeName),
            "app_id": arNumID(app.id),
            "app_name": app.name,
        ]
    }

    /// publish 接口按"工号-姓名"比对 owner/backup 名单；优先取 tmyc-deploy skill 的 .env EMPLOYEE_NAME
    static func publisherName(fallback: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let envURL = home.appendingPathComponent(".claude/skills/tmyc-deploy/.env")
        if let text = try? String(contentsOf: envURL, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("EMPLOYEE_NAME=") {
                let v = line.dropFirst("EMPLOYEE_NAME=".count).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return String(v) }
            }
        }
        return fallback
    }

    func deployPre(_ good: ReleaseGood) {
        guard let token = savedToken, selectedApp != nil else { return }
        busyAction = "pre-\(good.id)"
        notice = nil
        let id = good.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                _ = try AppRelAPI.shared.call(.reset, token: token, payload: ["goods_id": arNumID(id), "tag": "pre-i0"])
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyAction = nil
                    self.noticeMsg("success", "已发起制品 \(id) 的预发部署。")
                    self.autoRefreshAfterDeploy()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.busyAction = nil
                    self?.noticeMsg("error", error.localizedDescription)
                }
            }
        }
    }

    func verifyThenPublish(_ good: ReleaseGood) {
        guard let token = savedToken, let app = selectedApp else { return }
        let id = good.id
        busyAction = "prod-\(id)"
        noticeMsg("info", "正在确认制品 \(id) 的预发验证，并发起线上部署…")
        let payload = productionPayload(good: good)
        let appID = app.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try AppRelFlow.verifyThenPublish(token: token, appID: appID, goodsID: id, payload: payload)
                DispatchQueue.main.async {
                    self?.busyAction = nil
                    self?.noticeMsg("success", "制品 \(id) 已通过预发验证并发起线上部署。")
                    self?.autoRefreshAfterDeploy()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.busyAction = nil
                    self?.noticeMsg("error", error.localizedDescription)
                    self?.refreshSelectedApp()
                }
            }
        }
    }

    /// 制品已是"生产环境待验证"状态：确认生产验证通过，结束发布流程
    /// 「部署线上」统一入口：按制品状态分发链路（允许生产环境发布→直接发布；预发/生产待验证→先补预发验证再发布）
    func deployProduction(_ good: ReleaseGood) {
        switch good.productionAction {
        case .publish:
            publishOnly(good)
        case .verifyAndPublish:
            verifyThenPublish(good)
        case .deployed:
            noticeMsg("error", "制品 \(good.id) 已处于生产流程（\(good.status)），无需重复部署线上")
        case .building:
            noticeMsg("error", "制品 \(good.id) 正在制作中（\(good.status)），等待制品完成后再部署线上")
        }
    }

    func verifyProduction(_ good: ReleaseGood) {
        guard let token = savedToken, let app = selectedApp else { return }
        let id = good.id
        busyAction = "vp-\(id)"
        let appID = app.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try AppRelFlow.verifyProduction(token: token, appID: appID, goodsID: id)
                DispatchQueue.main.async {
                    self?.busyAction = nil
                    self?.noticeMsg("success", "制品 \(id) 已提交线上验证，进入「生产环境验证中」，验证完成后即定格为 release 版本。")
                    self?.autoRefreshAfterDeploy()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.busyAction = nil
                    self?.noticeMsg("error", error.localizedDescription)
                    self?.refreshSelectedApp()
                }
            }
        }
    }

    /// 制品已是"允许生产环境发布"状态：跳过验证直接发布上线
    func publishOnly(_ good: ReleaseGood) {
        guard let token = savedToken, let app = selectedApp else { return }
        let id = good.id
        busyAction = "pub-\(id)"
        let payload = productionPayload(good: good)
        let appID = app.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try AppRelFlow.publishWithRetry(token: token, appID: appID, goodsID: id, payload: payload)
                DispatchQueue.main.async {
                    self?.busyAction = nil
                    self?.noticeMsg("success", "已发起制品 \(id) 的线上部署。")
                    self?.autoRefreshAfterDeploy()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.busyAction = nil
                    self?.noticeMsg("error", error.localizedDescription)
                    self?.refreshSelectedApp()
                }
            }
        }
    }

    func redeployThenPublish(_ good: ReleaseGood) {
        guard let token = savedToken else { return }
        let id = good.id
        busyAction = "rebuild-\(id)"
        noticeMsg("info", "制品 \(id) 正在重新部署预发，待预发验证后将自动部署线上…")
        let task = AppReleaseScheduler.shared.addRedeployPublish(token: token, payload: productionPayload(good: good), branch: good.branch)
        schedules.insert(task, at: 0)
        busyAction = nil
    }

    func scheduleProduction(_ goodID: String, at: Date) {
        guard let token = savedToken, let good = goods.first(where: { $0.id == goodID }) else { return }
        do {
            let task = try AppReleaseScheduler.shared.addSchedule(token: token, at: at, payload: productionPayload(good: good), branch: good.branch)
            schedules = (schedules + [task]).sorted { $0.at < $1.at }
            noticeMsg("success", "已添加 \(arFormatFull(task.at)) 的线上部署任务。")
            showScheduleModal = false
        } catch {
            noticeMsg("error", error.localizedDescription)
        }
    }

    func cancelSchedule(_ task: ScheduleTask) {
        guard let token = savedToken else { return }
        do {
            try AppReleaseScheduler.shared.cancel(id: task.id, token: token)
            schedules.removeAll { $0.id == task.id }
            noticeMsg("info", "已删除定时任务。")
        } catch {
            noticeMsg("error", error.localizedDescription)
        }
    }

    func openScheduleModal(goodID: String = "") {
        scheduleGoodID = goodID.isEmpty ? (scheduleGoodID.isEmpty ? (goods.first?.id ?? "") : scheduleGoodID) : goodID
        if scheduleDate <= Date() { scheduleDate = Date().addingTimeInterval(600) }
        showScheduleModal = true
    }

    // MARK: 新建制品

    func openCreateModal() {
        guard selectedApp != nil else { return noticeMsg("error", "请先选择应用") }
        guard savedToken != nil else { return noticeMsg("error", "请先填写并保存运维平台 token") }
        branchQuery = ""
        branchSuggestions = []
        branchSearched = false
        createMode = .pre
        if scheduleDate <= Date() { scheduleDate = Date().addingTimeInterval(600) }
        showCreateModal = true
    }

    func updateBranchQuery(_ value: String) {
        branchQuery = value
        branchRequestID += 1
        branchSearchWork?.cancel()
        branchSuggestions = []
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            branchSearched = false
            branchLoading = false
            return
        }
        branchSearched = true
        let id = branchRequestID
        let work = DispatchWorkItem { [weak self] in self?.searchBranches(keyword: value, requestID: id) }
        branchSearchWork = work
        branchLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func searchBranches(keyword: String, requestID: Int) {
        guard let token = savedToken, let app = selectedApp else { return }
        let name = keyword.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try AppRelAPI.shared.call(.branches, token: token, params: ["id": app.id, "name": name])
                let list = arDict(data)["branch"] as? [Any] ?? arDictList(data).compactMap { arStr($0, ["name", "branch"]) }
                let branches = list.compactMap { v -> String? in
                    if let s = v as? String { return s }
                    if let d = v as? [String: Any] { return arStr(d, ["name", "branch"]) }
                    return nil
                }
                DispatchQueue.main.async {
                    guard let self, self.branchRequestID == requestID else { return }
                    self.branchSuggestions = branches
                    self.branchLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.branchRequestID == requestID else { return }
                    self.branchLoading = false
                    self.noticeMsg("error", "查询 Git 分支失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func createGood() {
        guard let token = savedToken, let app = selectedApp else { return }
        let branch = branchQuery.trimmingCharacters(in: .whitespaces)
        guard !branch.isEmpty else { return noticeMsg("error", "请输入或选择 Git 分支") }
        creatingGood = true
        let mode = createMode
        let when = scheduleDate
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let created = try AppRelAPI.shared.call(.createGood, token: token,
                                                        payload: ["id": app.id, "branch": branch, "publish_type": 1, "tag": "pre-i0"])
                let createdData = arDict(created)
                let createdGoods = arDictList(createdData["goods"]) + [createdData]
                let createdID = arStr(createdData, ["id", "goods_id"]) ?? arStr(createdGoods.first ?? [:], ["id", "goods_id"])
                let listData = try AppRelAPI.shared.call(.goods, token: token,
                                                         params: ["id": app.id, "current_page": "1", "page_size": "50"])
                let list = arPickList(listData).compactMap(ReleaseGood.parse)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.goods = list
                    let good = list.first(where: { $0.id == createdID }) ?? list.first(where: { $0.branch == branch })
                    switch mode {
                    case .pre:
                        self.showCreateModal = false
                        self.creatingGood = false
                        self.noticeMsg("success", "已创建 \(branch) 分支的预发制品。")
                    case .redeploy:
                        self.showCreateModal = false
                        self.creatingGood = false
                        guard let good else {
                            self.noticeMsg("error", "制品已创建，但暂未获取到制品 ID，请稍后在列表中执行重制并部署线上")
                            return
                        }
                        self.redeployThenPublish(good)
                    case .schedule:
                        self.showCreateModal = false
                        self.creatingGood = false
                        guard let good else {
                            self.noticeMsg("error", "制品已创建，但暂未获取到制品 ID，请稍后在列表中定时部署")
                            return
                        }
                        self.scheduleProduction(good.id, at: when)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.creatingGood = false
                    self?.noticeMsg("error", "创建制品失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: 工具

    @Published var goodsExpanded = false
    var displayGoods: [ReleaseGood] { Array(goods.prefix(goodsExpanded ? 10 : 5)) }
    var pendingProdVerify: [ReleaseGood] { goods.filter { $0.awaitingProdVerify || $0.prodVerifying } }

    func noticeMsg(_ kind: String, _ text: String) {
        notice = (kind, text)
    }

    func closeTopModal() -> Bool {
        if showTokenGuide { showTokenGuide = false; return true }
        if showScheduleModal { showScheduleModal = false; return true }
        if showCreateModal, !creatingGood { showCreateModal = false; return true }
        return false
    }
}
