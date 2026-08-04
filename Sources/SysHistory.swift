import Foundation
import Darwin

// MARK: - 卡顿历史: 常驻采样(每分钟落点) + 亮红灯抓归因快照, 供事后追查
// 设计动机: 最卡的时候人在救火不会开面板, 等腾出手机器已缓过来 —— 必须把"卡的那一刻"存下来

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
    var culprits: String     // 亮灯瞬间抓的归因快照(按应用聚合)
    var hitCount: Int = 1    // 该段内亮灯采样次数
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

            if level > 0 {
                if var ev = self.openEvent, now - ev.end <= Self.mergeGap {
                    // 延续(含跨越短暂回绿的合并)
                    ev.end = now
                    ev.peakLv = max(ev.peakLv, level)
                    ev.peakRate = max(ev.peakRate, rate)
                    ev.peakLpc = max(ev.peakLpc, lpc)
                    ev.minFreePct = min(ev.minFreePct, freePct)
                    ev.hitCount += 1
                    if ev.culprits.isEmpty || (level >= 2 && now - self.lastCulpritAt > 120) {
                        ev.culprits = Self.snapshotCulprits()
                        self.lastCulpritAt = now
                    }
                    self.openEvent = ev
                    self.saveOpen()
                } else {
                    // 旧段已超出合并窗口 -> 先落库, 再开新段
                    if let old = self.openEvent { self.closeEvent(old, at: now) }
                    var ev = LagEvent(start: now, end: now, peakLv: level,
                                      peakRate: rate, peakLpc: lpc, minFreePct: freePct,
                                      culprits: Self.snapshotCulprits())
                    ev.hitCount = 1
                    self.lastCulpritAt = now
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
        var closed = ev
        if closed.culprits.isEmpty { closed.culprits = "(未抓到归因)" }
        events.append(closed)
        events = events.filter { now - $0.start < keepDays }
        saveEvents()
    }

    /// 亮红灯瞬间的归因快照: 按应用聚合内存
    private static func snapshotCulprits() -> String {
        let fams = SysMonViewModel.familyRows().prefix(4)
            .map { String(format: "%@ %.1fG(%d进程)", $0.0, $0.1, $0.2) }
            .joined(separator: " · ")
        return fams.isEmpty ? "(采集失败)" : fams
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
