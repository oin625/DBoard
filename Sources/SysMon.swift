import SwiftUI
import AppKit
import Darwin

// MARK: - 系统监控: CPU/内存/磁盘/温度 + Top进程(Qoder系高亮), 3秒采样, 关窗停表

struct ProcRow: Identifiable {
    let pid: Int
    let name: String
    let cpu: Double
    let mem: Double
    var id: Int { pid }
    var isQoder: Bool { name.lowercased().contains("qoder") }
}

/// 卡顿等级: 只有真正影响体感的信号才升级
enum LagLevel {
    case smooth, mild, severe
    var label: String { self == .smooth ? "流畅" : (self == .mild ? "略卡" : "很卡") }
    var dot: String { self == .smooth ? "🟢" : (self == .mild ? "🟡" : "🔴") }
    var color: Color {
        switch self {
        case .smooth: return Color(hex: "#5aa86c")
        case .mild:   return Color(hex: "#e8a04c")
        case .severe: return Color(hex: "#d94f4f")
        }
    }
}

final class SysMonViewModel: ObservableObject {
    // 三个真信号
    @Published var swapRate: Double = 0           // 页/秒, >0 = 正在换页
    @Published var loadPerCore: Double = 0        // 负载/核数, >1 = CPU 排队
    @Published var memFreePct: Double = 100       // 空闲内存百分比
    @Published var level: LagLevel = .smooth
    @Published var reason: String = ""            // 触发升级的信号说明

    @Published var memUsedGB: Double = 0
    @Published var memTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1073741824
    @Published var swapUsedGB: Double = 0
    @Published var diskFreeGB: Double = 0
    @Published var diskTotalGB: Double = 0
    @Published var thermal: String = "正常"
    @Published var lastUpdate: Date? = nil

    // 归因(按需展开才采集)
    @Published var procs: [ProcRow] = []
    @Published var families: [(String, Double, Int)] = []
    @Published var detailLoading = false
    @Published var detailLoaded = false

    @Published var aiDiag = ""
    @Published var aiDiagLoading = false

    // 历史(每次采样刷新, 数据来自常驻落盘)
    @Published var trend: [Int] = []
    @Published var lagEvents: [LagEvent] = []
    @Published var todayEvents = 0
    @Published var todayLagMin = 0
    @Published var uptimeText = ""
    @Published var swapTrendText = ""

    private var timer: Timer?
    private var prevSwap: (ins: UInt64, outs: UInt64, at: Date)? = nil

    func start() {
        sample()
        timer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    /// 读常驻历史(菜单栏定时器负责写, 这里只读)
    func refreshHistory() {
        let h = SysHistoryStore.shared
        trend = h.recentLevels(minutes: 60)
        lagEvents = h.recentEvents(limit: 5)
        let st = h.todayStats()
        todayEvents = st.events
        todayLagMin = st.lagMinutes
        let up = SysHistoryStore.uptime()
        if up > 0 {
            let d = Int(up) / 86400, hh = (Int(up) % 86400) / 3600
            uptimeText = d > 0 ? "已开机 \(d)天\(hh)小时" : "已开机 \(hh)小时"
        }
        let sw = h.swapTrend(hours: 6)
        if sw.count >= 4 {
            let first = sw.prefix(sw.count / 3).reduce(0, +) / Double(max(sw.count / 3, 1))
            let last = sw.suffix(sw.count / 3).reduce(0, +) / Double(max(sw.count / 3, 1))
            let delta = last - first
            if delta > 0.5 { swapTrendText = String(format: "交换区6小时内涨了 %.1fG, 建议重启释放", delta) }
            else if delta < -0.5 { swapTrendText = String(format: "交换区在回落 (%.1fG)", delta) }
            else { swapTrendText = "交换区水位稳定" }
        }
    }

    func resample() { sample() }

    /// 结束进程(SIGTERM), 仅本用户进程有权限
    func terminate(pid: Int) {
        kill(pid_t(pid), SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.resample() }
    }

    /// AI 诊断: 只在亮灯时可用, 围绕触发的信号提问(不许自由发挥)
    func runAIDiag() {
        guard !aiDiagLoading, level != .smooth else { return }
        aiDiagLoading = true
        aiDiag = ""
        let sig = reason
        let lvlText = level.label
        let snap = String(format: "内存 %.1f/%.0fG(可回收%.0f%%), 交换区占用 %.1fG, 换页 %.0f页/秒, 负载 %.2f/核, 温度%@",
                          memUsedGB, memTotalGB, memFreePct, swapUsedGB, swapRate, loadPerCore, thermal)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rows = Self.sampleTopCPU().prefix(8)
                .map { String(format: "%@ cpu%.0f%% mem%.0fM", $0.name, $0.cpu, $0.mem) }.joined(separator: "; ")
            let fam = Self.familyRows().prefix(8)
                .map { String(format: "%@ %.1fG(%d进程)", $0.0, $0.1, $0.2) }.joined(separator: "; ")
            let prompt = "你是macOS性能专家。当前判定为「\(lvlText)」, 触发信号: \(sig)。\n"
                + "只围绕这个信号解释和处置, 不要罗列无关指标, 不要说\"一切正常\"。输出纯文本(无markdown), 3行以内:\n"
                + "第1行: 这个信号是什么原因造成的(优先看按应用聚合, 多进程应用在单进程榜会隐身)\n"
                + "第2行: 具体关闭/重启哪个应用能缓解(CloudShell/AliEntSafe/alilang 是公司安全软件, 严禁建议关闭; mds/WindowServer 不要动)\n"
                + "第3行: 一句话行动建议\n"
                + "数据: " + snap + "\n按应用聚合内存: " + fam + "\n瞬时CPU榜: " + rows
            let out = DBoardAIProvider.shared.text(prompt, timeout: 90)
                ?? "诊断失败（Qoder CLI 未登录或不可用），未消耗 Codex 额度"
            DispatchQueue.main.async {
                self?.aiDiag = out
                self?.aiDiagLoading = false
            }
        }
    }

    /// 轻量采样(纯 syscall, 无子进程): 三信号 + 判级
    private func sample() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let (used, swapGB, freePct, ins, outs) = Self.sampleVM()
            let (dFree, dTotal) = Self.sampleDisk()

            // 换页速率: 两次采样差分
            var rate = 0.0
            let now = Date()
            if let p = self.prevSwap {
                let dt = now.timeIntervalSince(p.at)
                if dt > 0.5 {
                    let d = (ins &- p.ins) + (outs &- p.outs)
                    rate = Double(d) / dt
                }
            }
            let newPrev = (ins: ins, outs: outs, at: now)

            var la = [Double](repeating: 0, count: 3)
            getloadavg(&la, 3)
            let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
            let lpc = cores > 0 ? la[0] / cores : 0

            let therm: String
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: therm = "正常"
            case .fair: therm = "略热"
            case .serious: therm = "偏热·已降频"
            case .critical: therm = "过热!"
            @unknown default: therm = "-"
            }

            // 判级: 只有真信号才升级
            var lvl = LagLevel.smooth
            var reasons: [String] = []
            if rate > 200 { lvl = .severe; reasons.append(String(format: "正在换页 %.0f页/秒", rate)) }
            else if rate > 20 { lvl = .mild; reasons.append(String(format: "轻微换页 %.0f页/秒", rate)) }
            if lpc > 2.0 { lvl = .severe; reasons.append(String(format: "CPU严重排队 %.1f/核", lpc)) }
            else if lpc > 1.0 { if lvl == .smooth { lvl = .mild }; reasons.append(String(format: "CPU排队 %.1f/核", lpc)) }
            if freePct < 8 { lvl = .severe; reasons.append(String(format: "内存仅剩%.0f%%", freePct)) }
            else if freePct < 15 { if lvl == .smooth { lvl = .mild }; reasons.append(String(format: "内存剩%.0f%%", freePct)) }
            if therm.contains("降频") || therm.contains("过热") {
                if lvl == .smooth { lvl = .mild }
                reasons.append("温度\(therm)")
            }
            let why = reasons.isEmpty
                ? String(format: "负载 %.1f/核 · 零换页 · 内存余 %.0f%%", lpc, freePct)
                : reasons.joined(separator: " · ")

            DispatchQueue.main.async {
                self.prevSwap = newPrev
                self.swapRate = rate
                self.loadPerCore = lpc
                self.memFreePct = freePct
                self.memUsedGB = used
                self.swapUsedGB = swapGB
                self.diskFreeGB = dFree
                self.diskTotalGB = dTotal
                self.thermal = therm
                self.level = lvl
                self.reason = why
                self.lastUpdate = Date()
                self.refreshHistory()
            }
        }
    }

    /// 按需归因: 只在展开/亮灯时调用(含 top 子进程, 约2秒)
    func loadDetail() {
        guard !detailLoading else { return }
        detailLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rows = Self.sampleTopCPU()
            let fams = Self.familyRows()
            DispatchQueue.main.async {
                self?.procs = rows
                self?.families = fams
                self?.detailLoading = false
                self?.detailLoaded = true
            }
        }
    }

    /// top -l 2 取第二次采样 = 真瞬时 CPU(ps 的 pcpu 是生命周期平均值, 不可用)
    static func sampleTopCPU() -> [ProcRow] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        proc.arguments = ["-l", "2", "-n", "10", "-o", "cpu", "-stats", "pid,cpu,mem,command"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        // 取第二段(第二次 Processes: 之后)
        let blocks = out.components(separatedBy: "Processes:")
        guard blocks.count >= 3 else { return [] }
        var rows: [ProcRow] = []
        var started = false
        for line in blocks[2].components(separatedBy: "\n") {
            if line.contains("PID") && line.contains("%CPU") { started = true; continue }
            guard started else { continue }
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4, let pid = Int(parts[0]), let cpu = Double(parts[1]) else { continue }
            // MEM 形如 475M+ / 1267M- / 52M, 转 MB
            let memStr = String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            var memMB = 0.0
            if memStr.hasSuffix("G"), let v = Double(memStr.dropLast()) { memMB = v * 1024 }
            else if memStr.hasSuffix("M"), let v = Double(memStr.dropLast()) { memMB = v }
            else if memStr.hasSuffix("K"), let v = Double(memStr.dropLast()) { memMB = v / 1024 }
            let name = String(parts[3]).trimmingCharacters(in: .whitespaces)
            rows.append(ProcRow(pid: pid, name: name, cpu: cpu, mem: memMB))
            if rows.count >= 10 { break }
        }
        return rows
    }

    /// 应用家族聚合(结构化版, 供视图直接展示)
    static func familyRows() -> [(String, Double, Int)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["axo", "rss,comm"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        var g: [String: (Double, Int)] = [:]
        for line in out.components(separatedBy: "\n").dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let rss = Double(parts[0]) else { continue }
            let low = String(parts[1]).lowercased()
            let fam: String
            if low.contains("redhat.java") { fam = "Qoder-JavaLS" }
            else if low.contains("qoder.app") { fam = "Qoder IDE" }
            else if low.contains(".qoder") || low.contains("qodercli") || low.contains("qoderwork") { fam = "Qoder周边" }
            else if low.contains("google chrome") { fam = "Chrome" }
            else if low.contains("dingtalk") { fam = "钉钉" }
            else if low.contains("alientsafe") || low.contains("cloudshell") || low.contains("alilang") { fam = "公司安全软件" }
            else if low.hasPrefix("/system") || low.hasPrefix("/usr/libexec") || low.hasPrefix("/usr/sbin") { fam = "macOS系统" }
            else { continue }
            let cur = g[fam] ?? (0, 0)
            g[fam] = (cur.0 + rss, cur.1 + 1)
        }
        return g.sorted { $0.value.0 > $1.value.0 }.map { ($0.key, $0.value.0 / 1048576, $0.value.1) }
    }

    /// 一次 syscall 取内存+交换+换页计数
    private static func sampleVM() -> (used: Double, swapGB: Double, freePct: Double, ins: UInt64, outs: UInt64) {
        var vmstat = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmstat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var usedGB = 0.0, freePct = 100.0
        var ins: UInt64 = 0, outs: UInt64 = 0
        if kr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = (Double(vmstat.active_count) + Double(vmstat.wire_count)
                        + Double(vmstat.compressor_page_count)) * page
            usedGB = used / 1073741824
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            // 可回收 = free + inactive + purgeable
            let avail = (Double(vmstat.free_count) + Double(vmstat.inactive_count)
                         + Double(vmstat.purgeable_count)) * page
            if total > 0 { freePct = avail / total * 100 }
            ins = UInt64(vmstat.swapins)
            outs = UInt64(vmstat.swapouts)
        }
        var swap = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.size
        var swapGB = 0.0
        if sysctlbyname("vm.swapusage", &swap, &sz, nil, 0) == 0 {
            swapGB = Double(swap.xsu_used) / 1073741824
        }
        return (usedGB, swapGB, freePct, ins, outs)
    }

    private static func sampleDisk() -> (Double, Double) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? Double,
              let total = attrs[.systemSize] as? Double else { return (0, 0) }
        return (free / 1073741824, total / 1073741824)
    }

}

// MARK: - 视图

struct SysMonView: View {
    var compactHeader: Bool = false   // popover 模式: 无红绿灯, 头部不留位
    var popoverMode: Bool = false     // popover: 高度自适应内容, 不撑 minHeight
    @State private var confirmKillPid: Int? = nil
    @State private var showDetail = false
    @State private var confirmClear = false

    /// 防呆: 系统关键进程与公司安全软件不允许结束
    private static let protected: Set<String> = [
        "WindowServer", "securityd", "launchd", "kernel_task", "loginwindow",
        "Finder", "Dock", "CloudShell", "AliEntSafe", "alilang", "EasyMonitor", "DBoard",
    ]
    private static func killable(_ name: String) -> Bool {
        let n = name.lowercased()
        return !protected.contains { n.contains($0.lowercased()) } && !n.hasPrefix("mds")
    }
    @EnvironmentObject var vm: SysMonViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    statusLight
                    trendSection
                    eventsSection
                    if vm.level != .smooth || showDetail {
                        detailSection
                    } else {
                        Button(action: { showDetail = true; vm.loadDetail() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.down.circle").font(.system(size: 11))
                                Text("仍想看详细占用")
                            }
                            .font(fm.font(12))
                            .foregroundStyle(theme.current.textTertiary)
                        }
                        .buttonStyle(SmoothButtonStyle())
                        .padding(.top, 2)
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: popoverMode ? 0 : 560, minHeight: popoverMode ? 0 : 420)
        .focusEffectDisabled()
        .background(ThemeBackground().environmentObject(theme).environmentObject(ThemeManager.shared))
        .onChange(of: vm.level) { _, new in
            // 亮灯时自动拉归因数据
            if new != .smooth && !vm.detailLoaded { vm.loadDetail() }
        }
    }

    /// 核心: 一个状态灯 + 一行依据
    private var statusLight: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(vm.level.color).frame(width: 14, height: 14)
                    .shadow(color: vm.level.color.opacity(0.5), radius: 4)
                Text(vm.level.label)
                    .font(fm.font(30))
                    .foregroundStyle(vm.level.color)
                Spacer()
                if vm.level == .smooth {
                    Text("无需处理")
                        .font(fm.font(12))
                        .foregroundStyle(theme.current.textMuted)
                }
            }
            HStack {
                Text(vm.reason)
                    .font(fm.font(13))
                    .foregroundStyle(theme.current.textSecondary)
                Spacer()
            }
            // 辅助信息行: 内存/交换/磁盘, 只作参考不作判定
            HStack(spacing: 14) {
                metric("内存", String(format: "%.1f/%.0fG", vm.memUsedGB, vm.memTotalGB))
                metric("交换区", vm.swapUsedGB > 0.05 ? String(format: "%.1fG", vm.swapUsedGB) : "0")
                metric("磁盘剩余", String(format: "%.0fG", vm.diskFreeGB))
                metric("温度", vm.thermal)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(vm.level == .smooth
                  ? AnyShapeStyle(theme.current.cardFill.opacity(theme.current.cardFillOpacity))
                  : AnyShapeStyle(vm.level.color.opacity(0.08))))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(vm.level == .smooth ? Color.clear : vm.level.color.opacity(0.3), lineWidth: 1))
    }

    /// 最近1小时趋势带: 每格1分钟, 让"刚才卡过"可见
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("最近 1 小时").font(fm.font(12)).foregroundStyle(theme.current.textTertiary)
                Spacer()
                if vm.todayEvents > 0 {
                    Text("今日卡顿 \(vm.todayEvents) 次 · 共 \(vm.todayLagMin) 分钟")
                        .font(fm.font(11))
                        .foregroundStyle(Color(hex: "#c8863c"))
                } else {
                    Text("今日无卡顿").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                }
            }
            GeometryReader { g in
                let n = max(vm.trend.count, 1)
                let gap: CGFloat = 1
                let w = max((g.size.width - CGFloat(n - 1) * gap) / CGFloat(n), 1)
                HStack(spacing: gap) {
                    ForEach(Array(vm.trend.enumerated()), id: \.offset) { _, lv in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Self.trendColor(lv))
                            .frame(width: w)
                    }
                }
            }
            .frame(height: 18)
            HStack {
                Text("60分钟前").font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                Spacer()
                if !vm.uptimeText.isEmpty {
                    Text(vm.uptimeText).font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                }
                if !vm.swapTrendText.isEmpty {
                    Text("· " + vm.swapTrendText)
                        .font(fm.font(9))
                        .foregroundStyle(vm.swapTrendText.contains("建议重启")
                                         ? Color(hex: "#c8863c") : theme.current.textMuted)
                }
                Spacer()
                Text("现在").font(fm.font(9)).foregroundStyle(theme.current.textMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
    }

    private static func trendColor(_ lv: Int) -> Color {
        switch lv {
        case 0: return Color(hex: "#5aa86c").opacity(0.55)
        case 1: return Color(hex: "#e8a04c")
        case 2: return Color(hex: "#d94f4f")
        default: return Color.gray.opacity(0.13)   // -1 无数据
        }
    }

    /// 卡顿事件: 把"卡的那一刻"的归因证据留下来, 事后可查
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("卡顿记录").font(fm.font(12)).foregroundStyle(theme.current.textTertiary)
                Spacer()
                if !vm.lagEvents.isEmpty {
                    Button(action: {
                        if confirmClear {
                            SysHistoryStore.shared.clearAll()
                            vm.refreshHistory()
                            confirmClear = false
                        } else {
                            confirmClear = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { confirmClear = false }
                        }
                    }) {
                        Text(confirmClear ? "确认清空?" : "清空")
                            .font(fm.font(10))
                            .foregroundStyle(confirmClear ? .white : theme.current.textMuted)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(confirmClear
                                ? Color(hex: "#ff6b6b") : theme.current.textTertiary.opacity(0.1)))
                    }
                    .buttonStyle(SmoothButtonStyle())
                }
            }
            if vm.lagEvents.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal").font(.system(size: 12))
                    Text("7天内没有卡顿记录 —— 卡的时候会自动记下当时谁在吃资源")
                        .font(fm.font(11))
                }
                .foregroundStyle(theme.current.textMuted)
                .padding(.vertical, 6)
            } else {
                ForEach(vm.lagEvents) { ev in eventRow(ev) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
    }

    private func eventRow(_ ev: LagEvent) -> some View {
        let c = ev.peakLv >= 2 ? Color(hex: "#d94f4f") : Color(hex: "#e8a04c")
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        let sf = DateFormatter(); sf.dateFormat = "HH:mm"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(c).frame(width: 7, height: 7)
                Text(f.string(from: Date(timeIntervalSince1970: ev.start))
                     + "–" + sf.string(from: Date(timeIntervalSince1970: ev.end)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.current.textSecondary)
                Text(ev.peakLv >= 2 ? "很卡" : "略卡")
                    .font(fm.font(11)).foregroundStyle(c)
                Text(ev.durationText)
                    .font(fm.font(11)).foregroundStyle(theme.current.textTertiary)
                if ev.hitCount > 1 {
                    Text("\(ev.hitCount)次")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.current.textMuted)
                }
                Spacer()
                Text(String(format: "换页%.0f/秒 · 负载%.1f/核 · 内存余%.0f%%",
                            ev.peakRate, ev.peakLpc, ev.minFreePct))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.current.textMuted)
            }
            // B: 当时在干什么 —— 比进程名更能唤起记忆
            if !ev.frontApp.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow").font(.system(size: 9))
                    Text(ev.frontTitle.isEmpty
                         ? "当时在 " + ev.frontApp
                         : "当时在 " + ev.frontApp + " — " + ev.frontTitle)
                        .font(fm.font(11))
                        .lineLimit(1)
                }
                .foregroundStyle(theme.current.textSecondary)
                .padding(.leading, 14)
            }
            // A: 什么变了 —— 相对60秒前基线涨得最多的进程
            if !ev.deltas.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ev.deltas) { d in
                        if !d.text.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                                Text(d.text)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color(hex: "#c8863c"))
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.leading, 14)
            } else if !ev.culprits.isEmpty {
                // 兼容旧数据
                Text("当时占用: " + ev.culprits)
                    .font(fm.font(11))
                    .foregroundStyle(theme.current.textMuted)
                    .lineLimit(2)
                    .padding(.leading, 14)
            } else if ev.frontApp.isEmpty {
                Text("未抓到变化(卡顿太短或刚启动无基线)")
                    .font(fm.font(10))
                    .foregroundStyle(theme.current.textMuted)
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(c.opacity(0.06)))
    }

    private func metric(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(fm.font(10)).foregroundStyle(theme.current.textMuted)
            Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.current.textSecondary)
        }
    }

    /// 归因区: 按应用聚合 + 瞬时CPU榜 + AI诊断
    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("占用归因").font(fm.font(13)).foregroundStyle(theme.current.textTertiary)
                if vm.detailLoading {
                    ProgressView().controlSize(.mini)
                    Text("采样中(约2秒)…").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                }
                Spacer()
                Button(action: { vm.loadDetail() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                        .foregroundStyle(theme.current.textSecondary)
                        .padding(5)
                        .background(Circle().fill(theme.current.textTertiary.opacity(0.1)))
                }
                .buttonStyle(SmoothButtonStyle())
                .disabled(vm.detailLoading)
                aiDiagButton
            }
            if !vm.aiDiag.isEmpty {
                Text(vm.aiDiag)
                    .font(fm.font(12))
                    .foregroundStyle(theme.current.textPrimary.opacity(0.85))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(theme.current.accentPrimary.opacity(0.06)))
            }
            if !vm.families.isEmpty {
                Text("按应用聚合内存").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                ForEach(vm.families.prefix(6), id: \.0) { f in
                    HStack(spacing: 8) {
                        Text(f.0).font(fm.font(13)).foregroundStyle(theme.current.textPrimary)
                        Text("\(f.2)进程").font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.current.textMuted)
                        Spacer()
                        miniBar(value: min(f.1 / max(vm.memTotalGB, 1), 1), width: 90)
                        Text(String(format: "%.1fG", f.1))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(f.1 > 4 ? Color(hex: "#d94f4f") : theme.current.textSecondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(theme.current.textTertiary.opacity(0.04)))
                }
            }
            if !vm.procs.isEmpty {
                Text("瞬时 CPU 占用").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                    .padding(.top, 4)
                ForEach(vm.procs) { p in procRow(p) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
    }

    private var aiDiagButton: some View {
        Button(action: { vm.runAIDiag() }) {
            HStack(spacing: 3) {
                if vm.aiDiagLoading {
                    ProgressView().controlSize(.mini)
                    Text("诊断中…")
                } else {
                    Image(systemName: "stethoscope").font(.system(size: 10, weight: .bold))
                    Text("AI 诊断")
                }
            }
            .font(fm.font(11))
            .foregroundStyle(vm.level == .smooth ? theme.current.textMuted : theme.current.accentPrimary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(vm.level == .smooth
                ? theme.current.textTertiary.opacity(0.08)
                : theme.current.accentPrimary.opacity(0.1)))
        }
        .buttonStyle(SmoothButtonStyle())
        .disabled(vm.aiDiagLoading || vm.level == .smooth)
        .help(vm.level == .smooth ? "当前流畅, 无需诊断" : "围绕告警信号给出处置建议")
    }

    private func procRow(_ p: ProcRow) -> some View {
        HStack(spacing: 8) {
            Text(p.name)
                .font(fm.font(13))
                .foregroundStyle(p.isQoder ? theme.current.accentPrimary : theme.current.textPrimary)
                .lineLimit(1)
            Text("\(p.pid)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.current.textMuted)
            Spacer()
            miniBar(value: min(p.cpu / 100, 1), width: 70)
            Text(String(format: "%3.0f%%", p.cpu))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(p.cpu > 80 ? Color(hex: "#d94f4f") : theme.current.textSecondary)
                .frame(width: 40, alignment: .trailing)
            Text(String(format: "%.0fM", p.mem))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.current.textTertiary)
                .frame(width: 52, alignment: .trailing)
            if Self.killable(p.name) {
                Button(action: {
                    if confirmKillPid == p.pid {
                        vm.terminate(pid: p.pid)
                        confirmKillPid = nil
                    } else {
                        confirmKillPid = p.pid
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            if confirmKillPid == p.pid { confirmKillPid = nil }
                        }
                    }
                }) {
                    Text(confirmKillPid == p.pid ? "确认结束?" : "结束")
                        .font(fm.font(10))
                        .foregroundStyle(confirmKillPid == p.pid ? .white : Color(hex: "#ff6b6b"))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(confirmKillPid == p.pid
                            ? Color(hex: "#ff6b6b") : Color(hex: "#ff6b6b").opacity(0.1)))
                }
                .buttonStyle(SmoothButtonStyle())
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.current.textMuted)
                    .frame(width: 46)
                    .help("系统/公司安全进程, 不可结束")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(p.isQoder ? theme.current.accentPrimary.opacity(0.08)
                            : theme.current.textTertiary.opacity(0.04)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("系统监控")
                .font(fm.font(18))
                .foregroundStyle(theme.current.accentGradient)
            Spacer()
            if let d = vm.lastUpdate {
                Text(d, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.current.textTertiary)
            }
        }
        .padding(.leading, compactHeader ? 16 : 84)
        .padding(.trailing, 16)
        .padding(.top, compactHeader ? 12 : 6)
        .padding(.bottom, 8)
        .tearOffHandle("SysMon", enabled: popoverMode)
    }

    private func gaugeCard(title: String, value: Double, main: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(fm.font(12)).foregroundStyle(theme.current.textTertiary)
            Text(main).font(fm.font(19)).foregroundStyle(theme.current.textPrimary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.current.textTertiary.opacity(0.12))
                    Capsule()
                        .fill(value > 0.85 ? Color(hex: "#d94f4f") : (value > 0.6 ? Color(hex: "#e8a04c") : Color(hex: "#5aa86c")))
                        .frame(width: max(g.size.width * min(value, 1), 4))
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: value)
                }
            }
            .frame(height: 7)
            if !sub.isEmpty {
                Text(sub).font(fm.font(10)).foregroundStyle(theme.current.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
    }

    private func miniBar(value: Double, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(theme.current.textTertiary.opacity(0.1))
            Capsule()
                .fill(value > 0.8 ? Color(hex: "#d94f4f") : theme.current.accentPrimary.opacity(0.7))
                .frame(width: max(width * min(value, 1), 2))
        }
        .frame(width: width, height: 5)
    }
}

// MARK: - 窗口

final class SysMonWindowController {
    static let shared = SysMonWindowController()
    private var window: NSWindow?
    private var popover: NSPopover?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private let tearOff = TearOffObserver()
    private let vm = SysMonViewModel()

    /// 菜单栏入口: 图标正下方展开, 点外部自动收起
    /// 高度自适应内容(不写死), 宽度 560 —— 720 太宽且内容撑不满会留大片空白
    func togglePopover(relativeTo button: NSStatusBarButton) {
        if let pop = popover, pop.isShown {
            closePopover()
            return
        }
        vm.start()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        // 高度上限 = 屏幕可用高度的 72%, 内容超出由内部 ScrollView 滚动
        // (不能用 sizingOptions=.preferredContentSize: 展开归因后 popover 会长到屏幕外,
        //  ScrollView 永远拿不到"超出可视区"状态 -> 完全滚不动)
        let screenH = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let popH = min(max(screenH * 0.72, 420), 860)
        let host = NSHostingController(rootView:
            SysMonView(compactHeader: true, popoverMode: true)
                .environmentObject(vm)
                .environmentObject(ThemeManager.shared)
                .environmentObject(FontManager.shared)
                .frame(width: 560, height: popH))
        pop.contentSize = NSSize(width: 560, height: popH)
        pop.contentViewController = host
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = pop

        // .transient 在 ScrollView 抢焦点后可能失效 —— 显式监听全局点击兜底
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.popover, p.isShown else { return }
            DispatchQueue.main.async { self.closePopover() }
        }
        // Esc 也收起
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, let p = self?.popover, p.isShown {
                self?.closePopover()
                return nil
            }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: pop, queue: .main) { [weak self] _ in
            self?.teardownMonitors()
            self?.vm.pause()   // 收起即停采样
        }
        // 顶部下拉撕出为独立窗口(与 Skills/BizMap 同一套手感)
        tearOff.install(key: "SysMon") { [weak self] in
            guard let self = self else { return }
            self.closePopover()
            self.show()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
        teardownMonitors()
        vm.pause()
    }

    private func teardownMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    func show() {
        vm.start()
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SysMonView()
            .environmentObject(vm)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "系统监控"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.isReleasedWhenClosed = false
        // 原生毛玻璃需要窗口透明才能透出桌面壁纸
        win.isOpaque = false
        win.backgroundColor = .clear
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        // 缩放范围: 下限跟随内容最小值, 上限放开到屏幕
        win.contentMinSize = NSSize(width: 560, height: 380)
        win.contentMaxSize = NSSize(width: 2400, height: 2000)
        win.setContentSize(NSSize(width: 760, height: 680))
        // 记忆上次的尺寸与位置(autosave 由 AppKit 持久化到 defaults)
        win.setFrameAutosaveName("DBoardSysMonWindow")
        if win.frame.width < 400 || win.frame.height < 300 {
            win.setContentSize(NSSize(width: 760, height: 680))
            win.center()
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            self?.vm.pause()   // 关窗停止采样
        }
    }
}
