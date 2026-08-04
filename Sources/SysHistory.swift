import Foundation
import Darwin
import AppKit

// MARK: - 卡顿历史: 常驻采样(每分钟落点) + 亮红灯抓归因快照, 供事后追查
// 设计动机: 最卡的时候人在救火不会开面板, 等腾出手机器已缓过来 —— 必须把"卡的那一刻"存下来

/// 进程变化量: 卡顿瞬间相对基线涨了多少
struct ProcDelta: Codable, Identifiable {
    let name: String
    let memBeforeMB: Double
    let memNowMB: Double
    let cpuBefore: Double
    let cpuNow: Double
    var id: String { name }

    var memDeltaMB: Double { memNowMB - memBeforeMB }
    /// 人话描述: 只说涨的那部分
    var text: String {
        var parts: [String] = []
        if memDeltaMB >= 150 {
            parts.append(String(format: "内存 +%.1fG (%.1f→%.1fG)",
                                memDeltaMB / 1024, memBeforeMB / 1024, memNowMB / 1024))
        } else if memDeltaMB >= 30 {
            parts.append(String(format: "内存 +%.0fM", memDeltaMB))
        }
        if cpuNow - cpuBefore >= 25 {
            parts.append(String(format: "CPU %.0f%%→%.0f%%", cpuBefore, cpuNow))
        } else if cpuNow >= 80 {
            parts.append(String(format: "CPU %.0f%%", cpuNow))
        }
        return parts.isEmpty ? "" : name + " " + parts.joined(separator: " · ")
    }
}

/// 进程基线快照(内存态, 不落盘)
private struct ProcSnap {
    let at: TimeInterval
    var byName: [String: (mem: Double, cpu: Double)]
}

/// 一分钟一个采样点
struct SysPoint: Codable {
    let t: TimeInterval      // 时间戳
    let lv: Int              // 0=流畅 1=略卡 2=很卡
    let rate: Double         // 换页 页/秒
    let lpc: Double          // 负载/核
    let freePct: Double      // 可回收内存%
    let swapGB: Double       // 交换区占用
}

/// 一次卡顿事件(连续亮灯合并为一段)
struct LagEvent: Codable, Identifiable {
    let start: TimeInterval
    var end: TimeInterval
    var peakLv: Int          // 该段最高等级
    var peakRate: Double
    var peakLpc: Double
    var minFreePct: Double
    var culprits: String     // 兼容旧数据(快照式归因), 新数据用 deltas
    var hitCount: Int = 1    // 该段内亮灯采样次数
    var deltas: [ProcDelta] = []   // A: 相对60秒前基线, 涨得最多的进程
    var frontApp: String = ""      // B: 卡顿时前台应用
    var frontTitle: String = ""    // B: 前台窗口标题(有权限才有)
    var id: TimeInterval { start }

    /// 显示用时长: 不足1分钟显示秒
    var durationText: String {
        let d = end - start
        if d < 60 { return "\(max(Int(d), 5))秒" }
        return "\(Int(d / 60))分钟"
    }
    var durationMin: Int { max(1, Int((end - start) / 60)) }
}

final class SysHistoryStore {
    static let shared = SysHistoryStore()

    private let pointsPath = NSHomeDirectory() + "/.dboard-sysmon-points.json"
    private let eventsPath = NSHomeDirectory() + "/.dboard-sysmon-events.json"
    private let openPath = NSHomeDirectory() + "/.dboard-sysmon-open.json"

    private let keepDays: TimeInterval = 7 * 86400
    private let queue = DispatchQueue(label: "dboard.syshistory")

    private var points: [SysPoint] = []
    private var events: [LagEvent] = []
    private var lastPointAt: TimeInterval = 0
    private var openEvent: LagEvent? = nil       // 正在进行中的卡顿段
    private var lastCulpritAt: TimeInterval = 0  // 归因抓取节流

    private init() { load() }

    // MARK: 写入

    /// 由菜单栏 5 秒定时器调用; 内部按分钟节流落点
    /// 事件合并: 亮灯后 GAP 秒内再次亮灯视为同一段(避免零散单点被门槛滤掉)
    func record(level: Int, rate: Double, lpc: Double, freePct: Double, swapGB: Double) {
        let now = Date().timeIntervalSince1970
        queue.async { [weak self] in
            guard let self = self else { return }

            // 常驻维护基线(20秒一帧) —— 必须在判级前跑, 卡顿时才有对比样本
            self.maintainBaseline(now: now)

            if level > 0 {
                if var ev = self.openEvent, now - ev.end <= Self.mergeGap {
                    // 延续(含跨越短暂回绿的合并)
                    ev.end = now
                    ev.peakLv = max(ev.peakLv, level)
                    ev.peakRate = max(ev.peakRate, rate)
                    ev.peakLpc = max(ev.peakLpc, lpc)
                    ev.minFreePct = min(ev.minFreePct, freePct)
                    ev.hitCount += 1
                    // 升级到"很卡"时重算一次归因(此时变化更明显)
                    if ev.deltas.isEmpty || (level >= 2 && ev.peakLv < 2) {
                        let d = self.computeDeltas(now: now)
                        if !d.isEmpty { ev.deltas = d }
                        if ev.frontApp.isEmpty {
                            let ctx = Self.frontContext()
                            ev.frontApp = ctx.app
                            ev.frontTitle = ctx.title
                        }
                    }
                    self.openEvent = ev
                    self.saveOpen()
                } else {
                    // 旧段已超出合并窗口 -> 先落库, 再开新段
                    if let old = self.openEvent { self.closeEvent(old, at: now) }
                    var ev = LagEvent(start: now, end: now, peakLv: level,
                                      peakRate: rate, peakLpc: lpc, minFreePct: freePct,
                                      culprits: "")
                    ev.hitCount = 1
                    ev.deltas = self.computeDeltas(now: now)
                    let ctx = Self.frontContext()
                    ev.frontApp = ctx.app
                    ev.frontTitle = ctx.title
                    self.openEvent = ev
                    self.saveOpen()
                }
            } else if let ev = self.openEvent, now - ev.end > Self.mergeGap {
                // 回绿且超过合并窗口才真正结束该段
                self.closeEvent(ev, at: now)
                self.openEvent = nil
                self.saveOpen()
            }

            // 按分钟落点
            guard now - self.lastPointAt >= 60 else { return }
            self.lastPointAt = now
            self.points.append(SysPoint(t: now, lv: level, rate: rate,
                                        lpc: lpc, freePct: freePct, swapGB: swapGB))
            self.points = self.points.filter { now - $0.t < self.keepDays }
            self.savePoints()
        }
    }

    /// 合并窗口: 3 分钟内的相邻亮灯算同一次卡顿
    private static let mergeGap: TimeInterval = 180

    /// 落库一段卡顿(不再用时长门槛, 零散单点也算 —— 否则与趋势带矛盾)
    private func closeEvent(_ ev: LagEvent, at now: TimeInterval) {
        events.append(ev)
        events = events.filter { now - $0.start < keepDays }
        saveEvents()
    }

    // MARK: 归因采集(A: 变化量 / B: 前台上下文)

    /// 滑动基线环: 每 20 秒存一帧进程快照, 保留最近 5 帧(约100秒)
    /// 卡顿时取 ~60 秒前那帧做对比 —— "什么变了"比"什么在那儿"有用
    private var snapRing: [ProcSnap] = []
    private var lastSnapAt: TimeInterval = 0

    /// 由 record 每轮调用, 内部 20 秒节流
    private func maintainBaseline(now: TimeInterval) {
        guard now - lastSnapAt >= 20 else { return }
        lastSnapAt = now
        snapRing.append(ProcSnap(at: now, byName: Self.procMap()))
        if snapRing.count > 5 { snapRing.removeFirst() }
    }

    /// 取最接近 60 秒前的基线帧
    private func baseline(before now: TimeInterval) -> ProcSnap? {
        let target = now - 60
        return snapRing.min { abs($0.at - target) < abs($1.at - target) }
    }

    /// 计算变化量: 涨得最多的 3 个进程(内存>=30M 或 CPU 涨>=25% 才算)
    private func computeDeltas(now: TimeInterval) -> [ProcDelta] {
        guard let base = baseline(before: now) else { return [] }
        let cur = Self.procMap()
        var out: [ProcDelta] = []
        for (name, c) in cur {
            let b = base.byName[name] ?? (mem: 0, cpu: 0)
            let dMem = c.mem - b.mem
            let dCPU = c.cpu - b.cpu
            // 新出现的进程(基线里没有)按全量算涨幅
            let isNew = base.byName[name] == nil
            guard dMem >= 30 || dCPU >= 25 || (isNew && c.mem >= 200) || c.cpu >= 80 else { continue }
            out.append(ProcDelta(name: Self.pretty(name),
                                 memBeforeMB: b.mem, memNowMB: c.mem,
                                 cpuBefore: b.cpu, cpuNow: c.cpu))
        }
        // 按"内存涨幅 + CPU涨幅权重"排序
        return out.sorted { a, b in
            (a.memDeltaMB + (a.cpuNow - a.cpuBefore) * 20)
                > (b.memDeltaMB + (b.cpuNow - b.cpuBefore) * 20)
        }.prefix(3).map { $0 }
    }

    /// ps 一次, 按进程名聚合(同名多进程合并, 如 Chrome 的多个 Helper)
    private static func procMap() -> [String: (mem: Double, cpu: Double)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["axo", "rss,pcpu,comm"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [:] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        var m: [String: (mem: Double, cpu: Double)] = [:]
        for line in out.components(separatedBy: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let rss = Double(parts[0]), let cpu = Double(parts[1]) else { continue }
            let name = String(parts[2])
            let memMB = rss / 1024
            // 只跟踪 >=50MB 的进程, 小进程噪音大且不影响体感
            guard memMB >= 50 || cpu >= 10 else { continue }
            let cur = m[name] ?? (mem: 0, cpu: 0)
            m[name] = (mem: cur.mem + memMB, cpu: cur.cpu + cpu)
        }
        return m
    }

    /// 路径转可读名
    private static func pretty(_ path: String) -> String {
        var n = (path as NSString).lastPathComponent
        // "Qoder Helper (Renderer)" 这类保留, 去掉 .app 之类后缀
        if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
        return n.isEmpty ? path : n
    }

    /// B: 前台应用与窗口标题(窗口标题需辅助功能权限, 拿不到就只留应用名)
    private static func frontContext() -> (app: String, title: String) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        var title = ""
        let script = """
        tell application "System Events"
            try
                tell (first application process whose frontmost is true)
                    return name of front window
                end tell
            on error
                return ""
            end try
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        if (try? proc.run()) != nil {
            // 卡顿时系统可能很慢, 给 1.5 秒上限避免拖累采样
            let deadline = Date().addingTimeInterval(1.5)
            while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if proc.isRunning { proc.terminate() }
            else {
                title = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (app, title)
    }

    // MARK: 读取

    /// 最近 N 分钟的等级序列(用于趋势带), 缺失分钟为 -1
    func recentLevels(minutes: Int) -> [Int] {
        queue.sync {
            let now = Date().timeIntervalSince1970
            let from = now - Double(minutes) * 60
            var buckets = [Int](repeating: -1, count: minutes)
            for p in points where p.t >= from {
                let idx = Int((p.t - from) / 60)
                if idx >= 0 && idx < minutes { buckets[idx] = max(buckets[idx], p.lv) }
            }
            return buckets
        }
    }

    /// 最近的卡顿事件(新的在前), 含正在进行中的
    func recentEvents(limit: Int = 8) -> [LagEvent] {
        queue.sync {
            var all = events
            if let ev = openEvent { all.append(ev) }
            return all.sorted { $0.start > $1.start }.prefix(limit).map { $0 }
        }
    }

    /// 交换区趋势: 最近N小时采样值
    func swapTrend(hours: Int = 6) -> [Double] {
        queue.sync {
            let from = Date().timeIntervalSince1970 - Double(hours) * 3600
            return points.filter { $0.t >= from }.map { $0.swapGB }
        }
    }

    /// 今日统计: 卡顿次数与总时长
    func todayStats() -> (events: Int, lagMinutes: Int) {
        queue.sync {
            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: Date()).timeIntervalSince1970
            var all = events
            if let ev = openEvent { all.append(ev) }
            let todays = all.filter { $0.start >= dayStart }
            let mins = todays.reduce(0) { $0 + $1.durationMin }
            return (todays.count, mins)
        }
    }

    /// 开机时长(秒)
    static func uptime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    func clearAll() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.points = []
            self.events = []
            self.openEvent = nil
            self.savePoints()
            self.saveEvents()
            try? FileManager.default.removeItem(atPath: self.openPath)
        }
    }

    // MARK: 持久化

    private func load() {
        let now = Date().timeIntervalSince1970
        if FileManager.default.fileExists(atPath: pointsPath),
           let d = try? Data(contentsOf: URL(fileURLWithPath: pointsPath)),
           let arr = try? JSONDecoder().decode([SysPoint].self, from: d) {
            points = arr.filter { now - $0.t < keepDays }
            lastPointAt = points.last?.t ?? 0
        }
        if FileManager.default.fileExists(atPath: eventsPath),
           let d = try? Data(contentsOf: URL(fileURLWithPath: eventsPath)),
           let arr = try? JSONDecoder().decode([LagEvent].self, from: d) {
            events = arr.filter { now - $0.start < keepDays }
        }
        // 恢复进行中的段(D板重启不丢)
        if FileManager.default.fileExists(atPath: openPath),
           let d = try? Data(contentsOf: URL(fileURLWithPath: openPath)),
           let ev = try? JSONDecoder().decode(LagEvent.self, from: d) {
            if now - ev.end <= Self.mergeGap { openEvent = ev }
            else { events.append(ev); saveEvents(); try? FileManager.default.removeItem(atPath: openPath) }
        }
    }

    private func savePoints() {
        guard let d = try? JSONEncoder().encode(points) else { return }
        try? d.write(to: URL(fileURLWithPath: pointsPath), options: .atomic)
    }

    private func saveOpen() {
        if let ev = openEvent, let d = try? JSONEncoder().encode(ev) {
            try? d.write(to: URL(fileURLWithPath: openPath), options: .atomic)
        } else {
            try? FileManager.default.removeItem(atPath: openPath)
        }
    }

    private func saveEvents() {
        guard let d = try? JSONEncoder().encode(events) else { return }
        try? d.write(to: URL(fileURLWithPath: eventsPath), options: .atomic)
    }
}
