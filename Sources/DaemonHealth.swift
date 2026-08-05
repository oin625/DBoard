import SwiftUI

// MARK: - 引擎心跳(daemon 健康探测)
// 看板的数据全靠后台 daemon 喂, daemon 挂了看板只会"安静地过期"。
// 这里把三个引擎的死活摆到 Footer 上: 值守 reply-daemon / 资讯 tech-scout / 钉钉同步。

enum EngineState: Int, Comparable {
    case ok = 0, unknown = 1, warn = 2, dead = 3
    static func < (a: EngineState, b: EngineState) -> Bool { a.rawValue < b.rawValue }
}

struct EngineStatus: Identifiable {
    let id: String
    let name: String
    let icon: String
    var state: EngineState = .unknown
    var detail: String = "探测中…"   // 判定依据(给人看的白话)
    var problem: String? = nil       // 异常时的一句话概括(上 Footer)
    var hint: String? = nil          // 修复建议
}

final class EngineHealthModel: ObservableObject {
    @Published var engines: [EngineStatus] = [
        EngineStatus(id: "reply", name: "值守 reply-daemon", icon: "bubble.left.and.bubble.right"),
        EngineStatus(id: "scout", name: "资讯 tech-scout", icon: "antenna.radiowaves.left.and.right"),
        EngineStatus(id: "sync", name: "钉钉同步", icon: "arrow.triangle.2.circlepath"),
    ]
    @Published var lastCheck: Date? = nil

    private var timer: Timer?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// 最严重的引擎(全 ok 时为 nil)
    var worst: EngineStatus? {
        engines.filter { $0.state != .ok }.max { $0.state < $1.state }
    }

    init() {
        refresh()
        // 60 秒巡检一次, 成本极低(一次 launchctl + 两次本地文件读取)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    deinit { timer?.invalidate() }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = [self.checkReplyDaemon(), self.checkTechScout(), self.checkSync()]
            DispatchQueue.main.async {
                self.engines = result
                self.lastCheck = Date()
            }
        }
    }

    // MARK: 值守 reply-daemon — launchd pid 是唯一真相, 日志 mtime 只作参考
    private func checkReplyDaemon() -> EngineStatus {
        var e = EngineStatus(id: "reply", name: "值守 reply-daemon", icon: "bubble.left.and.bubble.right")
        let logStr = fileDate(home + "/.dws/logs/reply-daemon.log").map { "最后活动 " + Self.rel($0) } ?? "无日志"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["list", "com.zz.dws-reply-daemon"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            e.state = .unknown
            e.detail = "launchctl 调用失败 · \(logStr)"
            return e
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()

        if p.terminationStatus != 0 {
            e.state = .dead
            e.problem = "值守未加载"
            e.detail = "launchd 里查无此服务 · \(logStr)"
            e.hint = "launchctl load ~/Library/LaunchAgents/com.zz.dws-reply-daemon.plist"
        } else if out.contains("\"PID\"") {
            e.state = .ok
            e.detail = "进程存活 · \(logStr)"
        } else {
            e.state = .dead
            e.problem = "值守进程退出"
            e.detail = "launchd 已加载但进程没在跑 · \(logStr)"
            e.hint = "launchctl kickstart -k gui/\(getuid())/com.zz.dws-reply-daemon"
        }
        return e
    }

    // MARK: 资讯 tech-scout — 每天 10/14 点各推一轮, 靠 pending.json 的 timestamp 判活
    private func checkTechScout() -> EngineStatus {
        var e = EngineStatus(id: "scout", name: "资讯 tech-scout", icon: "antenna.radiowaves.left.and.right")
        let path = home + "/.claude/tech-scout-pending.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["timestamp"] as? Double else {
            e.state = .unknown
            e.detail = "读不到 tech-scout-pending.json"
            e.hint = "对 agent 说「手动拉一轮资讯」"
            return e
        }
        let date = Date(timeIntervalSince1970: ts)
        let ageH = Date().timeIntervalSince(date) / 3600
        e.detail = "上次推送 " + Self.rel(date)
        if ageH < 26 {
            e.state = .ok
        } else if ageH < 50 {
            e.state = .warn
            e.problem = "资讯错过一轮推送"
            e.hint = "对 agent 说「手动拉一轮资讯」排查定时任务"
        } else {
            e.state = .dead
            e.problem = "资讯断供 \(Int(ageH / 24)) 天"
            e.hint = "对 agent 说「资讯怎么没更新」排查 tech-scout"
        }
        return e
    }

    // MARK: 钉钉同步 — cache 头部 <!-- synced: ISO --> 是上次同步成功的凭证
    private func checkSync() -> EngineStatus {
        var e = EngineStatus(id: "sync", name: "钉钉同步", icon: "arrow.triangle.2.circlepath")
        let path = home + "/.claude/demand-center-cache.md"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let firstLine = content.split(separator: "\n", maxSplits: 1).first,
              let range = firstLine.range(of: #"synced: ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8})"#, options: .regularExpression) else {
            e.state = .unknown
            e.detail = "cache 头部没有 synced 时间戳"
            e.hint = "点 ⚡ 跑一次同步"
            return e
        }
        let iso = String(firstLine[range].dropFirst("synced: ".count))
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = fmt.date(from: iso) else {
            e.state = .unknown
            e.detail = "synced 时间戳解析失败: \(iso)"
            return e
        }
        let ageH = Date().timeIntervalSince(date) / 3600
        e.detail = "上次同步 " + Self.rel(date)
        if ageH < 24 {
            e.state = .ok
        } else if ageH < 72 {
            e.state = .warn
            e.problem = "同步 \(Int(ageH / 24)) 天没跑"
            e.hint = "点 ⚡ 立即同步, 或对 agent 说「同步D板」"
        } else {
            e.state = .dead
            e.problem = "同步 \(Int(ageH / 24)) 天没跑"
            e.hint = "点 ⚡ 立即同步, 或对 agent 说「同步D板」"
        }
        return e
    }

    // MARK: 工具
    private func fileDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func rel(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }
}

// MARK: - Footer 心跳条
struct EngineStrip: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @StateObject private var health = EngineHealthModel()
    @State private var showDetail = false
    @State private var syncPulse = false

    /// 同步动作进行中时, 同步点让位给动作状态(沿用原来的脉冲反馈)
    private var syncActionColor: Color? {
        switch vm.syncKind {
        case .idle: return nil
        case .pending: return theme.current.accentSecondary
        case .syncing: return theme.current.accentPrimary
        case .done: return Color(hex: "#34c759")
        case .fail: return .orange
        }
    }

    private func stateColor(_ s: EngineState) -> Color {
        switch s {
        case .ok: return Color(hex: "#34c759")
        case .warn: return .orange
        case .dead: return Color(hex: "#d94f4f")
        case .unknown: return theme.current.textMuted
        }
    }

    private var summaryText: String {
        if vm.syncKind != .idle { return vm.syncText }        // 同步动作反馈优先
        if let w = health.worst, let p = w.problem { return p }
        if let w = health.worst, w.state == .unknown { return "引擎状态未知" }
        return vm.syncText.isEmpty ? "引擎正常" : vm.syncText  // 全绿时保留"最近同步"信息
    }

    private var summaryColor: Color {
        if let c = syncActionColor { return c }
        if let w = health.worst { return stateColor(w.state) }
        return theme.current.textMuted
    }

    var body: some View {
        Button { showDetail.toggle(); health.refresh() } label: {
            HStack(spacing: 5) {
                ForEach(health.engines) { e in
                    Circle()
                        .fill(e.id == "sync" ? (syncActionColor ?? stateColor(e.state)) : stateColor(e.state))
                        .frame(width: 5, height: 5)
                        .scaleEffect(e.id == "sync" && syncPulse ? 1.5 : 1.0)
                        .opacity(e.id == "sync" && syncPulse ? 0.6 : 1.0)
                }
                Text(summaryText).font(.system(size: 9)).foregroundStyle(summaryColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("引擎心跳: 值守 / 资讯 / 同步")
        .onChange(of: vm.syncKind) { kind in
            if kind == .syncing {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { syncPulse = true }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { syncPulse = false }
            }
        }
        .popover(isPresented: $showDetail, arrowEdge: .top) {
            EngineDetailPanel(health: health, stateColor: stateColor)
        }
    }
}

// MARK: - 心跳详情弹层
struct EngineDetailPanel: View {
    @ObservedObject var health: EngineHealthModel
    let stateColor: (EngineState) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("引擎心跳").font(.system(size: 11, weight: .bold))
                Spacer()
                if let t = health.lastCheck {
                    Text("巡检于 " + EngineHealthModel.rel(t)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Button { health.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("立即重测")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            ForEach(health.engines) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: e.icon).font(.system(size: 10)).frame(width: 13)
                            .foregroundStyle(.secondary)
                        Text(e.name).font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Circle().fill(stateColor(e.state)).frame(width: 6, height: 6)
                    }
                    Text(e.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.leading, 19)
                    if let hint = e.hint {
                        Text(hint)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(stateColor(e.state))
                            .padding(.leading, 19)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                if e.id != health.engines.last?.id { Divider().padding(.leading, 12) }
            }
            Divider()
            Text("每 60 秒自动巡检 · 点状态点可随时重测")
                .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(width: 260)
    }
}
