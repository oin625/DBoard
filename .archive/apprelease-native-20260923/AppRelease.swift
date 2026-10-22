import SwiftUI
import Combine

// MARK: - 应用发布台数据层
// 网关调用与定时调度逻辑对齐 audi /app-release (route.js + scheduler.js)，
// 直连运维平台网关，token 仅存 UserDefaults。⌃Q 呼出。

struct AppRelError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static func msg(_ m: String) -> AppRelError { AppRelError(message: m) }
}

// MARK: 字典宽松取值工具

func arRaw(_ d: [String: Any], _ keys: [String]) -> Any? {
    for k in keys {
        if let v = d[k], !(v is NSNull) { return v }
    }
    return nil
}

func arStr(_ d: [String: Any], _ keys: [String]) -> String? {
    guard let v = arRaw(d, keys) else { return nil }
    switch v {
    case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    case let n as NSNumber: return n.stringValue
    default: return String(describing: v)
    }
}

func arInt(_ d: [String: Any], _ keys: [String]) -> Int? {
    guard let v = arRaw(d, keys) else { return nil }
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
    return nil
}

func arDict(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }

func arDictList(_ v: Any?) -> [[String: Any]] {
    (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
}

/// 对齐前端 pickList：数组本体或 apps/list/goods/records 字段
func arPickList(_ data: Any?) -> [[String: Any]] {
    if let arr = data as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
    let d = arDict(data)
    for key in ["apps", "list", "goods", "records", "results"] {
        if let arr = d[key] as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
    }
    return []
}

private let arDateFormats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss.SSS"]

/// DateFormatter 初始化昂贵且非线程安全：按线程缓存复用
private func arCachedFormatter(_ fmt: String) -> DateFormatter {
    let dict = Thread.current.threadDictionary
    if let df = dict[fmt] as? DateFormatter { return df }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = fmt
    dict[fmt] = df
    return df
}

/// 宽松日期解析：字符串 / epoch 秒 / epoch 毫秒
func arParseDate(_ v: Any?) -> Date? {
    if let n = v as? NSNumber {
        let d = n.doubleValue
        if d > 1e12 { return Date(timeIntervalSince1970: d / 1000) }
        if d > 1e8 { return Date(timeIntervalSince1970: d) }
        return nil
    }
    guard let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    var normalized = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasSuffix("Z") { normalized.removeLast() }
    for fmt in arDateFormats {
        if let date = arCachedFormatter(fmt).date(from: fmt.hasSuffix("SSS") ? String(normalized.prefix(19)) : normalized) { return date }
    }
    if let iso = ISO8601DateFormatter().date(from: normalized + "Z") { return iso }
    return nil
}

func arFormatDate(_ v: Any?) -> String {
    if let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty, arParseDate(s) == nil { return s }
    guard let date = arParseDate(v) else { return "—" }
    return arCachedFormatter("MM-dd HH:mm").string(from: date)
}

func arFormatFull(_ v: Date) -> String {
    arCachedFormatter("MM-dd HH:mm").string(from: v)
}

/// token 尾号脱敏展示
func arMaskToken(_ token: String) -> String {
    let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count <= 8 { return "****" }
    return "****" + String(t.suffix(4))
}

/// 数字 ID 转 JSON number（网关 forms 里 goods_id/app_id 均为 uint64，字符串会被拒）
func arNumID(_ s: String) -> Any {
    let t = s.trimmingCharacters(in: .whitespaces)
    if let i = Int64(t) { return NSNumber(value: i) }
    return s
}

// MARK: 网关调用

final class AppRelAPI {
    static let gateway = "https://pre-i0-nczgateway.tmallyc-inc.com/gateway/i0"

    enum OP {
        case apps, goods, appDetail, envList, reset, verify, prodVerified, publish, publishHistory, state, branches, createGood
        var path: String {
            switch self {
            case .apps: return "/devopsapplication/api/app/list"
            case .goods: return "/devopsapplication/api/app/goods/list"
            case .appDetail: return "/devopsapplication/api/app/detail"
            case .envList: return "/deliveryapplication/v2/api/app/env/list"
            case .reset: return "/devopsapplication/api/goods/reset"
            case .verify: return "/deliveryapplication/api/deploysvc/goods/pre/verified"
            case .prodVerified: return "/deliveryapplication/api/deploysvc/goods/prod/verified"
            case .publish: return "/deliveryapplication/api/deploysvc/goods/publish"
        case .publishHistory: return "/deliveryapplication/api/deploysvc/goods/publish/history"
            case .state: return "/deliveryapplication/api/app/running/state"
            case .branches: return "/devopsapplication/api/app/branch"
            case .createGood: return "/devopsapplication/api/app/goods/create"
            }
        }
        var isWrite: Bool {
            switch self {
            case .reset, .verify, .prodVerified, .publish, .createGood: return true
            default: return false
            }
        }
    }

    static let shared = AppRelAPI()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 同步调用（必须在后台线程）：返回响应 data 字段；网关错误以 AppRelError 抛出
    func call(_ op: OP, token: String, params: [String: Any] = [:], payload: [String: Any] = [:]) throws -> Any {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppRelError.msg("请先填写运维平台 token") }
        guard var comps = URLComponents(string: Self.gateway + op.path) else { throw AppRelError.msg("网关地址无效") }
        if !op.isWrite {
            let items = params.compactMap { (k, v) -> URLQueryItem? in
                if v is NSNull { return nil }
                let s = v is String ? (v as? String ?? "") : String(describing: v)
                guard !s.isEmpty else { return nil }
                return URLQueryItem(name: k, value: s)
            }
            if !items.isEmpty { comps.queryItems = items }
        }
        guard let url = comps.url else { throw AppRelError.msg("网关地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = op.isWrite ? "POST" : "GET"
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        req.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "token")
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if op.isWrite {
            req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "content-type")
            req.httpBody = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        }
        let sem = DispatchSemaphore(value: 0)
        var outData: Data?
        var outResp: URLResponse?
        var outErr: Error?
        let task = session.dataTask(with: req) { d, r, e in
            outData = d; outResp = r; outErr = e; sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 31) == .timedOut {
            task.cancel()
            throw AppRelError.msg("运维平台请求超时（30 秒）")
        }
        if let e = outErr { throw AppRelError.msg("运维平台请求失败：\(e.localizedDescription)") }
        guard let http = outResp as? HTTPURLResponse else { throw AppRelError.msg("运维平台无响应") }
        let data = outData ?? Data()
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AppRelError.msg("运维平台返回了非 JSON 响应（HTTP \(http.statusCode)）")
        }
        let msg = arStr(json, ["msg", "message", "error"])
        if !(200...299).contains(http.statusCode) { throw AppRelError.msg(msg ?? "运维平台请求失败（HTTP \(http.statusCode)）") }
        if let code = arInt(json, ["code"]), code != 200 { throw AppRelError.msg(msg ?? "运维平台操作失败") }
        return json["data"] ?? json
    }
}

// MARK: 实体解析

struct ReleaseApp: Identifiable {
    let id: String
    let name: String
    let level: String
    let desc: String
    let employeeName: String

    static func parse(_ d: [String: Any]) -> ReleaseApp? {
        guard let id = arStr(d, ["id", "app_id"]) else { return nil }
        return ReleaseApp(
            id: id,
            name: arStr(d, ["name", "app_name"]) ?? "未命名应用",
            level: arStr(d, ["level"]) ?? "应用",
            desc: arStr(d, ["description"]) ?? "暂无说明",
            employeeName: arStr(d, ["employee_name"]) ?? ""
        )
    }
}

struct StoredApp: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let employeeName: String
    var app: ReleaseApp { ReleaseApp(id: id, name: name, level: "应用", desc: "", employeeName: employeeName) }
}

struct ReleaseGood: Identifiable {
    let id: String
    let name: String
    let status: String
    let branch: String
    let logURL: String
    let created: String
    let updated: String
    let creator: String
    let waitingVerification: Bool
    let awaitingProduction: Bool
    let awaitingProdVerify: Bool
    let prodVerifying: Bool

    static func parse(_ d: [String: Any]) -> ReleaseGood? {
        guard let id = arStr(d, ["id", "goods_id"]) else { return nil }
        let status = arStr(d, ["status_desc", "status_name", "status", "state"]) ?? "未知状态"
        let logRaw = arStr(d, ["log", "log_url", "logUrl"]) ?? ""
        return ReleaseGood(
            id: id,
            name: arStr(d, ["tag", "name", "goods_name", "version"]) ?? "制品 #\(id)",
            status: status,
            branch: arStr(d, ["git", "branch", "git_branch", "branch_name", "source_branch", "gitBranch"]) ?? "—",
            logURL: logRaw.hasPrefix("http") ? logRaw : "",
            created: arFormatDate(arRaw(d, ["create_time", "created_at"])),
            updated: arFormatDate(arRaw(d, ["update_time", "updated_at"])),
            creator: arStr(d, ["creator", "create_user", "creator_name", "employee_name"]) ?? "",
            waitingVerification: ReleaseGood.isWaitingVerification(status),
            awaitingProduction: status.contains("允许生产环境发布") || status.contains("预发验证通过") || status.contains("可发布生产"),
            awaitingProdVerify: status.contains("生产环境待验证"),
            prodVerifying: status.contains("生产环境验证中")
        )
    }

    static func isWaitingVerification(_ status: String) -> Bool {
        let s = status.lowercased()
        if s.contains("预发待验证") { return true }
        for p in ["pre.*(pending|wait|to_be).*verif", "pending.*pre.*verif"] where s.range(of: p, options: .regularExpression) != nil { return true }
        return false
    }
}

enum GoodsProductionAction {
    case publish, verifyAndPublish, deployed, building
}

extension ReleaseGood {
    /// 「部署线上」按钮的接口链路：允许生产环境发布→直接发布；预发待验证/生产环境待验证→先补预发验证再发布
    var productionAction: GoodsProductionAction {
        if awaitingProduction { return .publish }
        if waitingVerification || awaitingProdVerify { return .verifyAndPublish }
        if status.contains("生产环境运行中") || status.contains("已完成发布") || status.contains("release版本") { return .deployed }
        return .building
    }
}

/// 平台返回的 `工号-姓名(花名)`，界面只留姓名部分
func arStripJobPrefix(_ value: String) -> String {
    let s = value.trimmingCharacters(in: .whitespaces)
    return s.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
}

struct ReleaseRecord: Identifiable {
    let id: String
    let time: String
    let branch: String
    let operatorName: String
    let goodsID: String
    let status: String
    let succeeded: Bool

    static func parse(_ d: [String: Any]) -> ReleaseRecord {
        let status = arStr(d, ["status", "status_desc", "message"]) ?? "—"
        return ReleaseRecord(
            id: arStr(d, ["id"]) ?? UUID().uuidString,
            time: arFormatDate(arRaw(d, ["create_time", "created_at"])),
            branch: arStr(d, ["branch"]) ?? "—",
            operatorName: arStripJobPrefix(arStr(d, ["employee_name"]) ?? "—"),
            goodsID: arStr(d, ["goods_id", "id"]) ?? "—",
            status: status,
            succeeded: status.contains("成功"))
    }
}

// MARK: 操作人身份（登录态 `工号-姓名`）

enum AppRelIdentity {
    private static var cache: [String: (name: String, at: Date)] = [:]
    private static let cacheLock = NSLock()

    /// 该接口只在应用直连域名可用：走网关 /gateway/i0/devopsapplication/api/user/ 会 404
    static func operatorName(token: String) throws -> String {
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppRelError.msg("请先填写运维平台 token") }
        cacheLock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 300 {
            cacheLock.unlock()
            return hit.name
        }
        cacheLock.unlock()
        guard let url = URL(string: "https://pre-i0-devopsapplication.tmallyc-inc.com/api/user/") else {
            throw AppRelError.msg("用户信息接口地址无效")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        req.setValue(key, forHTTPHeaderField: "token")
        let sem = DispatchSemaphore(value: 0)
        var outData: Data?
        var outErr: Error?
        let task = URLSession.shared.dataTask(with: req) { d, _, e in outData = d; outErr = e; sem.signal() }
        task.resume()
        if sem.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            throw AppRelError.msg("获取操作人超时")
        }
        if let e = outErr { throw AppRelError.msg("获取操作人失败：\(e.localizedDescription)") }
        let json = (try? JSONSerialization.jsonObject(with: outData ?? Data())) as? [String: Any]
        let data = arDict(json?["data"])
        guard let job = arStr(data, ["job_number"]), !job.isEmpty,
              let real = arStr(data, ["real_name"]), !real.isEmpty else {
            throw AppRelError.msg("运维平台用户信息接口未返回工号与姓名，无法确定发布操作人，已阻止发布")
        }
        let name = "\(job)-\(real)"
        cacheLock.lock()
        if cache.count > 50 { cache.removeAll() }
        cache[key] = (name, Date())
        cacheLock.unlock()
        return name
    }
}

// MARK: 发布流程（验证 → 线上，含状态机落库延迟重试）

enum AppRelFlow {
    static func verifyPayload(appID: String, goodsID: String) -> [String: Any] {
        ["id": arNumID(appID), "goods_id": arNumID(goodsID), "feature_list": "验证通过"]
    }

    static func normalizedPublishPayload(token: String, _ payload: [String: Any]) throws -> [String: Any] {
        var p = payload
        for key in ["app_id", "new_goods_id", "old_goods_id"] {
            if let s = arStr(payload, [key]) { p[key] = arNumID(s) }
        }
        // employee_name 的语义是「操作人」= 运维平台登录态的 工号-姓名，与应用 owner 无关，强制覆盖
        p["employee_name"] = try AppRelIdentity.operatorName(token: token)
        return p
    }

    static func verify(_ token: String, appID: String, goodsID: String) throws {
        _ = try AppRelAPI.shared.call(.verify, token: token, payload: verifyPayload(appID: appID, goodsID: goodsID))
    }

    static func verifyProduction(token: String, appID: String, goodsID: String) throws {
        _ = try AppRelAPI.shared.call(.prodVerified, token: token, payload: verifyPayload(appID: appID, goodsID: goodsID))
    }

    /// publish 带重试：verify 通过后平台状态机落库有 1~2 秒延迟，首枪常被"预发环境完成验证通过后才能发布上线"挡回
    static func publishWithRetry(token: String, appID: String, goodsID: String, payload: [String: Any], attempts: Int = 5) throws {
        let pub = try normalizedPublishPayload(token: token, payload)
        var last: Error = AppRelError.msg("发布线上失败")
        for attempt in 0..<attempts {
            do {
                _ = try AppRelAPI.shared.call(.publish, token: token, payload: pub)
                return
            } catch {
                last = error
                let m = error.localizedDescription
                if m.contains("正在发布") { throw error }
                // 仅"预发未完成验证"这一类落库延迟错误才重试；其余错误（如 412 权限）立即抛出，
                // 且绝不再补调预发验证，防止把"生产环境待验证"的制品错误打回"允许生产环境发布"
                guard m.contains("预发"), m.contains("验证") else { throw error }
                Thread.sleep(forTimeInterval: 2)
                if attempt == 2 {
                    try? verify(token, appID: appID, goodsID: goodsID)
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
        throw last
    }

    static func verifyThenPublish(token: String, appID: String, goodsID: String, payload: [String: Any]) throws {
        try verify(token, appID: appID, goodsID: goodsID)
        try publishWithRetry(token: token, appID: appID, goodsID: goodsID, payload: payload)
    }
}

struct ReleasePod: Identifiable {
    var id: String { name.isEmpty ? UUID().uuidString : name }
    let name: String
    let state: String
    let podIP: String
    let hostIP: String
    let branch: String
    let goodsID: String
    let restarts: String
    let startTime: String
    let image: String
    let webShell: String

    static func parse(_ d: [String: Any]) -> ReleasePod {
        let labels = arDict(d["labels"])
        return ReleasePod(
            name: arStr(d, ["pod_name", "name", "podName"]) ?? "未命名 Pod",
            state: arStr(d, ["state", "container_state", "containerState"]) ?? "未知状态",
            podIP: arStr(d, ["pod_ip", "podIp"]) ?? "—",
            hostIP: arStr(d, ["host_ip", "hostIp"]) ?? "—",
            branch: arStr(labels, ["branch"]) ?? "—",
            goodsID: arStr(labels, ["goods_id", "goodsId"]) ?? "—",
            restarts: arStr(d, ["restart_count", "container_restart_count", "restartCount"]) ?? "—",
            startTime: arFormatDate(arRaw(d, ["start_time", "startTime"])),
            image: arStr(d, ["image"]) ?? "—",
            webShell: { let s = arStr(d, ["web_shell_url", "webShellUrl"]) ?? ""; return s.hasPrefix("http") ? s : "" }()
        )
    }
}

struct ReleaseEnvState {
    let title: String
    let summary: String
    let detail: String
    let pods: [ReleasePod]
    var hasPods: Bool { !pods.isEmpty }

    static func parse(_ data: Any, appName: String) -> ReleaseEnvState {
        let d = arDict(data)
        let pods = arDictList(d["pods"]).map(ReleasePod.parse)
        let label = pods.isEmpty ? (arStr(d, ["status_desc", "status_name", "status", "state", "message"]) ?? "状态已获取") : ""
        var detail = "等待应用状态接口返回部署信息"
        if let goodsName = arStr(d, ["goods_name", "goods_id"]) { detail = "当前制品：\(goodsName)" }
        else if arRaw(d, ["update_time", "updated_at"]) != nil { detail = "更新时间：\(arFormatDate(arRaw(d, ["update_time", "updated_at"])))" }
        else if !pods.isEmpty { detail = "已连接部署状态接口" }
        return ReleaseEnvState(
            title: arStr(d, ["app_name", "appName"]) ?? appName,
            summary: pods.isEmpty ? label : "运行中 Pod：\(pods.count)",
            detail: detail,
            pods: pods
        )
    }

    static let empty = ReleaseEnvState(title: "—", summary: "暂无部署记录", detail: "等待应用状态接口返回部署信息", pods: [])
}

// MARK: 定时任务调度

struct ScheduleTask: Identifiable {
    let id: String
    let at: Date
    let appName: String
    let goodsID: String
    let branch: String
    let replicas: Int
    let type: String
    let status: String
    let error: String

    var statusLabel: String {
        switch status {
        case "scheduled": return "待执行"
        case "running": return "执行中"
        case "completed": return "已完成"
        default: return "失败"
        }
    }
}

final class AppReleaseScheduler {
    static let shared = AppReleaseScheduler()
    private let maxDelay: TimeInterval = 7 * 24 * 3600
    private let waitTimeout: TimeInterval = 15 * 60

    private final class Box {
        let id: String
        let token: String
        let at: Date
        let payload: [String: Any]
        let type: String
        let branch: String
        var status = "scheduled"
        var error = ""
        var timer: Timer?
        let force: Bool
        init(id: String, token: String, at: Date, payload: [String: Any], type: String, force: Bool = false, branch: String = "") {
            self.id = id; self.token = token; self.at = at; self.payload = payload; self.type = type; self.force = force; self.branch = branch
        }
        var snapshot: ScheduleTask {
            ScheduleTask(id: id, at: at,
                         appName: arStr(payload, ["app_name"]) ?? "",
                         goodsID: arStr(payload, ["new_goods_id"]) ?? "",
                         branch: branch,
                         replicas: arInt(payload, ["new_replicas"]) ?? 0,
                         type: type, status: status, error: error)
        }
    }

    private var boxes: [String: Box] = [:]
    private let lock = NSLock()

    func addSchedule(token: String, at: Date, payload: [String: Any], branch: String = "") throws -> ScheduleTask {
        let delay = at.timeIntervalSinceNow
        guard delay > 0 else { throw AppRelError.msg("定时发布时间必须晚于当前时间") }
        guard delay <= maxDelay else { throw AppRelError.msg("本地定时任务最多支持提前 7 天创建") }
        let box = Box(id: UUID().uuidString, token: token, at: at, payload: payload, type: "scheduled-redeploy-publish", branch: branch)
        lock.lock(); boxes[box.id] = box; lock.unlock()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.run(box) }
        box.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return box.snapshot
    }

    func addRedeployPublish(token: String, payload: [String: Any], branch: String = "") -> ScheduleTask {
        let box = Box(id: UUID().uuidString, token: token, at: Date(), payload: payload, type: "redeploy-publish", force: true, branch: branch)
        box.status = "running"
        lock.lock(); boxes[box.id] = box; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.execute(box) }
        return box.snapshot
    }

    func snapshot(token: String) -> [ScheduleTask] {
        lock.lock(); defer { lock.unlock() }
        return boxes.values
            .filter { $0.token == token }
            .map { $0.snapshot }
            .sorted { $0.at < $1.at }
    }

    func cancel(id: String, token: String) throws {
        lock.lock()
        guard let box = boxes[id], box.token == token else { lock.unlock(); throw AppRelError.msg("未找到该定时任务") }
        guard box.status == "scheduled" else { box.error = ""; lock.unlock(); throw AppRelError.msg("该任务已开始或已结束，不能删除") }
        box.timer?.invalidate()
        box.timer = nil
        boxes.removeValue(forKey: id)
        lock.unlock()
    }

    private func run(_ box: Box) {
        box.status = "running"
        box.error = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.execute(box) }
    }

    private func execute(_ box: Box) {
        do {
            let goodsID = arStr(box.payload, ["new_goods_id"]) ?? ""
            let appID = arStr(box.payload, ["app_id"]) ?? ""
            guard !goodsID.isEmpty, !appID.isEmpty else { throw AppRelError.msg("定时任务缺少制品或应用 ID") }
            let pub = try AppRelFlow.normalizedPublishPayload(token: box.token, box.payload)

            let current = try fetchGood(token: box.token, appID: appID, goodsID: goodsID)
            if box.force == false, let good = current {
                switch good.productionAction {
                case .publish:
                    try AppRelFlow.publishWithRetry(token: box.token, appID: appID, goodsID: goodsID, payload: pub)
                    box.status = "completed"
                    return
                case .verifyAndPublish:
                    try AppRelFlow.verify(box.token, appID: appID, goodsID: goodsID)
                    try AppRelFlow.publishWithRetry(token: box.token, appID: appID, goodsID: goodsID, payload: pub)
                    box.status = "completed"
                    return
                case .deployed:
                    box.error = "制品已处于生产流程（\(good.status)），无需重复发布"
                    box.status = "completed"
                    return
                case .building:
                    break
                }
            }
            // 制作中的制品自带的就是我们要等的预发构建，再发 reset 会被判"当前制品状态不允许重制"：跳过
            if current?.productionAction != .building {
                _ = try AppRelAPI.shared.call(.reset, token: box.token, payload: ["goods_id": arNumID(goodsID), "tag": "pre-i0"])
            }
            let deadline = Date().addingTimeInterval(waitTimeout)
            while true {
                if let g = try fetchGood(token: box.token, appID: appID, goodsID: goodsID), g.waitingVerification { break }
                if Date() > deadline { throw AppRelError.msg("等待预发部署完成超时（15 分钟），任务中止") }
                Thread.sleep(forTimeInterval: 3)
            }
            try AppRelFlow.verifyThenPublish(token: box.token, appID: appID, goodsID: goodsID, payload: pub)
            box.status = "completed"
        } catch {
            box.status = "failed"
            box.error = error.localizedDescription
        }
    }

    private func fetchGood(token: String, appID: String, goodsID: String) throws -> ReleaseGood? {
        let data = try AppRelAPI.shared.call(.goods, token: token,
                                             params: ["id": appID, "current_page": "1", "page_size": "50"])
        return arPickList(data).first(where: { arStr($0, ["id", "goods_id"]) == goodsID }).flatMap { ReleaseGood.parse($0) }
    }
}
