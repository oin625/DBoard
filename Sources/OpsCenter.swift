import SwiftUI
import AppKit
import UserNotifications

// MARK: - 一键运维(OpsCenter)
// 把"翻文档找脚本 → 开终端 → 跑命令 → 盯输出"压成面板上的一个按钮。
// 每个动作就是一条本机命令; Runner 负责二次确认、流式日志、步骤进度、完成通知、结果留存。

struct OpsAction: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let executable: String
    let arguments: [String]
    let workingDir: String
    /// 非空 = 执行前弹二次确认(写生产的动作必须有)
    let confirm: String?
    /// 脚本输出里 "[k/n] 文案" 形式的步骤行, 用于进度显示
    let totalSteps: Int?
    let timeout: TimeInterval

    static let douyinCookie = OpsAction(
        id: "douyin-cookie",
        title: "刷新抖音评价 Cookie",
        detail: "自动登录抖音来客，写入生产 Redis",
        icon: "arrow.triangle.2.circlepath.circle",
        executable: "/usr/bin/python3",
        arguments: ["-u", "douyin-auto-cookie.py", "--env", "prod"],
        workingDir: NSHomeDirectory() + "/Documents/one/projects/各种评价",
        confirm: "将自动登录抖音来客并覆盖【生产】Redis 的 douyin:cookie。\n过程中会弹出 Chromium 窗口，约 20 秒；如遇验证码请在窗口内手动完成。",
        totalSteps: 7,
        timeout: 180
    )

    static let all: [OpsAction] = [.douyinCookie]
}

final class OpsRunner: ObservableObject {
    static let shared = OpsRunner()

    enum Phase: String { case idle, running, success, failed }

    struct RunState {
        var phase: Phase = .idle
        var step: Int = 0
        var stepText: String = ""
        var log: [String] = []
        var startedAt: Date? = nil
        var endedAt: Date? = nil
        var message: String = ""
    }

    @Published private(set) var states: [String: RunState] = [:]
    private var processes: [String: Process] = [:]

    private init() {
        // 恢复上次结果(只留摘要, 不留日志)
        for a in OpsAction.all {
            guard let d = UserDefaults.standard.dictionary(forKey: "ops.last.\(a.id)"),
                  let ts = d["at"] as? Double, let raw = d["phase"] as? String,
                  let phase = Phase(rawValue: raw) else { continue }
            var s = RunState()
            s.phase = phase
            s.endedAt = Date(timeIntervalSince1970: ts)
            s.message = d["msg"] as? String ?? ""
            states[a.id] = s
        }
    }

    func state(_ a: OpsAction) -> RunState { states[a.id] ?? RunState() }
    var anyRunning: Bool { states.values.contains { $0.phase == .running } }

    /// 入口: 带确认的执行
    func requestRun(_ a: OpsAction) {
        guard state(a).phase != .running else { return }
        UsageStats.hit("ops:\(a.id)")
        if let text = a.confirm {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = a.title
            alert.informativeText = text
            alert.alertStyle = .warning
            alert.addButton(withTitle: "执行")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        run(a)
    }

    func cancel(_ a: OpsAction) {
        processes[a.id]?.terminate()
    }

    private func run(_ a: OpsAction) {
        guard FileManager.default.fileExists(atPath: a.workingDir) else {
            finish(a, ok: false, message: "找不到脚本目录 \(a.workingDir)")
            return
        }
        var s = RunState()
        s.phase = .running
        s.startedAt = Date()
        s.stepText = "启动中…"
        states[a.id] = s

        let p = Process()
        p.executableURL = URL(fileURLWithPath: a.executable)
        p.arguments = a.arguments
        p.currentDirectoryURL = URL(fileURLWithPath: a.workingDir)
        var env = ProcessInfo.processInfo.environment
        // launchd 拉起的 App 没有登录 shell 的 PATH
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                DispatchQueue.main.async { self?.ingest(a, line: line) }
            }
        }

        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.processes[a.id] = nil
                let last = self.state(a).log.last { $0.hasPrefix("✅") || $0.hasPrefix("❌") } ?? ""
                let msg: String
                if proc.terminationReason == .uncaughtSignal {
                    msg = "已中止"
                } else if ok {
                    msg = last.isEmpty ? "完成" : last
                } else {
                    msg = last.isEmpty ? "退出码 \(proc.terminationStatus)" : last
                }
                self.finish(a, ok: ok, message: msg)
            }
        }

        do {
            try p.run()
            processes[a.id] = p
        } catch {
            finish(a, ok: false, message: "启动失败: \(error.localizedDescription)")
            return
        }

        // 超时保护: 卡在验证码/网络时不让进程永远挂着
        DispatchQueue.main.asyncAfter(deadline: .now() + a.timeout) { [weak self, weak p] in
            guard let self, let p, p.isRunning else { return }
            self.ingest(a, line: "❌ 超时 \(Int(a.timeout))s，已中止")
            p.terminate()
        }
    }

    private func ingest(_ a: OpsAction, line: String) {
        var s = state(a)
        s.log.append(line)
        if s.log.count > 200 { s.log.removeFirst(s.log.count - 200) }
        // "[3/7] 切换到「邮箱登录」..."
        if let r = line.range(of: #"^\[(\d+)/(\d+)\]\s*"#, options: .regularExpression) {
            let head = line[r].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            s.step = Int(head.split(separator: "/").first ?? "") ?? s.step
            s.stepText = String(line[r.upperBound...]).replacingOccurrences(of: "...", with: "")
        } else if line.contains("正在更新 Cookie") {
            s.stepText = "写入生产 Redis"
        }
        states[a.id] = s
    }

    private func finish(_ a: OpsAction, ok: Bool, message: String) {
        var s = state(a)
        s.phase = ok ? .success : .failed
        s.endedAt = Date()
        s.message = message
        states[a.id] = s
        UserDefaults.standard.set(["at": Date().timeIntervalSince1970, "phase": s.phase.rawValue, "msg": message],
                                  forKey: "ops.last.\(a.id)")
        let content = UNMutableNotificationContent()
        content.title = (ok ? "已完成：" : "失败：") + a.title
        content.body = message
        content.sound = ok ? nil : .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "ops-\(a.id)-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }
}

// MARK: - 动作行(首屏/详情共用)
struct OpsActionRow: View {
    @ObservedObject var runner = OpsRunner.shared
    @EnvironmentObject var theme: ThemeManager
    let action: OpsAction
    @State private var showLog = false

    private var st: OpsRunner.RunState { runner.state(action) }

    private var subtitle: String {
        switch st.phase {
        case .running:
            let step = action.totalSteps.map { st.step > 0 ? "\(st.step)/\($0) · " : "" } ?? ""
            return step + st.stepText
        case .success, .failed:
            let when = st.endedAt.map { "上次 " + Self.fmt.string(from: $0) } ?? ""
            return [when, st.message].filter { !$0.isEmpty }.joined(separator: " · ")
        case .idle:
            return action.detail
        }
    }

    private var tint: Color {
        switch st.phase {
        case .running: return theme.current.accentPrimary
        case .success: return .green
        case .failed: return .red
        case .idle: return theme.current.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: st.phase == .failed ? "exclamationmark.triangle.fill" : action.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.current.textPrimary)
                    Text(subtitle).font(.system(size: 11))
                        .foregroundStyle(st.phase == .failed ? Color.red : theme.current.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if !st.log.isEmpty {
                    Button { showLog.toggle() } label: {
                        Image(systemName: "text.alignleft").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.current.textTertiary)
                    .help("查看输出")
                }
                if st.phase == .running {
                    ProgressView().controlSize(.small)
                    Button("中止") { runner.cancel(action) }.controlSize(.small)
                } else {
                    Button(st.phase == .failed ? "重试" : "执行") { runner.requestRun(action) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
            if st.phase == .running, let total = action.totalSteps {
                ProgressView(value: Double(st.step), total: Double(total))
                    .progressViewStyle(.linear)
                    .tint(theme.current.accentPrimary)
            }
            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(st.log.enumerated()), id: \.offset) { i, l in
                                Text(l).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(theme.current.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.current.textPrimary.opacity(0.04)))
                    .onChange(of: st.log.count) { n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showLog)
    }

    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M-d HH:mm"; return f
    }()
}

// MARK: - 模块目录(入口收敛: 头部菜单 / ⌘K 共用一份)
struct DBoardModule: Identifiable {
    let id: String
    let title: String
    let icon: String
    let shortcut: String
    let open: () -> Void

    func launch() {
        UsageStats.hit(id)
        open()
    }

    private static func post(_ name: String) { NotificationCenter.default.post(name: .init(name), object: nil) }

    static let all: [DBoardModule] = [
        DBoardModule(id: "dayplan", title: "今日规划", icon: "calendar.day.timeline.left", shortcut: "⌃O") { DayPlanWindowController.shared.toggle() },
        DBoardModule(id: "reply", title: "钉钉待回复", icon: "bubble.left.and.bubble.right", shortcut: "") { post("openReplyInbox") },
        DBoardModule(id: "reqflow", title: "ReqFlow 需求流", icon: "point.3.connected.trianglepath.dotted", shortcut: "⌃E") { BizMapBoardWindowController.shared.toggleWindow(requirements: true) },
        DBoardModule(id: "bizmap", title: "BizMap 业务地图", icon: "map", shortcut: "") { BizMapBoardWindowController.shared.toggleWindow(requirements: false) },
        DBoardModule(id: "logs", title: "Audi 日志", icon: "doc.text.magnifyingglass", shortcut: "⌃L") { AppReleaseWindowController.shared.toggleLogs() },
        DBoardModule(id: "logsearch", title: "日志快搜", icon: "magnifyingglass", shortcut: "⌃⇧L") { LogSearchWindowController.shared.show() },
        DBoardModule(id: "apprelease", title: "应用发布台", icon: "paperplane", shortcut: "⌃Q") { AppReleaseWindowController.shared.toggle() },
        DBoardModule(id: "audihome", title: "Audi 首页", icon: "house", shortcut: "⌃W") { AppReleaseWindowController.shared.toggleHome() },
        DBoardModule(id: "clipboard", title: "剪切板历史", icon: "doc.on.clipboard", shortcut: "⌥V") { ClipboardBoardWindowController.shared.show() },
        DBoardModule(id: "codex", title: "Codex 供应商切换", icon: "arrow.left.arrow.right", shortcut: "⌥C") { CodexSwitchWindowController.shared.toggle() },
        DBoardModule(id: "skills", title: "Skills 看板", icon: "wand.and.stars", shortcut: "") { post("openSkillsBoard") },
        DBoardModule(id: "techscout", title: "科技资讯", icon: "antenna.radiowaves.left.and.right", shortcut: "") { post("openTechScout") },
        DBoardModule(id: "sysmon", title: "系统监控", icon: "gauge.with.needle", shortcut: "") { post("openSysMon") },
        DBoardModule(id: "market", title: "A股行情", icon: "chart.line.uptrend.xyaxis", shortcut: "") { post("openETF") },
    ]
}

// MARK: - 模块使用统计(纯本地, 用来决定哪些模块该冻结/下线)
enum UsageStats {
    private static let path = NSHomeDirectory() + "/Library/Application Support/DBoard/usage.json"
    private static let queue = DispatchQueue(label: "dboard.usage")

    /// 结构: { "模块id": { "yyyy-MM-dd": 次数 } }
    static func hit(_ id: String) {
        queue.async {
            var db = load()
            let day = dayFmt.string(from: Date())
            db[id, default: [:]][day, default: 0] += 1
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: db, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }

    /// 近 N 天各模块打开次数, 降序
    static func summary(days: Int = 14) -> [(String, Int)] {
        let db = queue.sync { load() }
        let cutoff = dayFmt.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        return db.map { (id, perDay) in (id, perDay.filter { $0.key >= cutoff }.values.reduce(0, +)) }
            .sorted { $0.1 > $1.1 }
    }

    private static func load() -> [String: [String: Int]] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]] else { return [:] }
        return obj
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}
