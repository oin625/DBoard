import SwiftUI
import Carbon.HIToolbox
import UserNotifications
import Combine
import WebKit

@main
struct DBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { DayPlanSettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panelWindow: NSWindow?          // detach 后用的独立窗口
    private var mainPopover: NSPopover?         // 默认 popover 下拉
    private var mainClickMonitor: Any?
    private var mainKeyMonitor: Any?
    private var viewModel: DBoardViewModel!
    private var focusObserver: NSObjectProtocol?
    private var techScoutVM: TechScoutViewModel!
    private var techScoutWindow: TechScoutWindowController!
    private var replyInboxVM: ReplyInboxViewModel!
    private var replyInboxWindow: ReplyInboxWindowController!
    private var etfWindow: NSWindow?
    private var etfWebView: WKWebView?
    private var sysStatusItem: NSStatusItem!
    private var sysMonTimer: Timer?
    private var prevSysSwap: (ins: UInt64, outs: UInt64, at: Date)?
    private var bizMapStatusItem: NSStatusItem!
    private var benchSkillsVM: SkillsViewModel?   // ⏱ 临时基准用，定位后可删

    private var clipHotKey: HotKey?
    private var logHotKey: HotKey?
    private var logClipHotKey: HotKey?
    private var codexHotKey: HotKey?
    private var reqFlowHotKey: HotKey?
    private var dayPlanHotKey: HotKey?
    private var appReleaseHotKey: HotKey?
    private var audiHomeHotKey: HotKey?
    private var debugTriggerTimer: Timer?

    private var isDetached = false   // 面板脱出为独立窗口(不置顶)
    private let panelTearOff = TearOffObserver()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("DBoard: applicationDidFinishLaunching called")

        // 通知中心代理
        UNUserNotificationCenter.current().delegate = self

        // Chrome cookie 桥接本地监听 (App 启动即监听, 不等面板打开)
        CookieBridgeServer.shared.start()

        // 预热 ReqFlow 数据层: 触发单例 init → 读项目表缓存 + 后台静默刷新
        _ = BizMapBoardWindowController.shared

        // 创建 statusItem 并保持强引用
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSLog("DBoard: statusItem created: \(statusItem != nil)")

        viewModel = DBoardViewModel()
        _ = DayPlanWindowController.shared

        // ⏱ 临时基准：启动后自动跑一次 Skills 扫描，把分阶段耗时写到
        // /tmp/dboard_scan_timing.txt，用于定位"开面板很慢"的根因。定位后删除。
        benchSkillsVM = SkillsViewModel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.benchSkillsVM?.scan()
        }

        if let button = statusItem.button {
            NSLog("DBoard: statusItem button exists")
            updateStatusIcon(button: button, urgent: viewModel.urgentCount)
            button.action = #selector(togglePopover)
            button.target = self
            NSLog("DBoard: button configured")
            // 系统监控独立菜单栏入口: 图标+实时CPU%, 点击直开监控窗口
            sysStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let sb = sysStatusItem.button {
                let img = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "系统监控")
                img?.isTemplate = true   // 模板图像: 自动随菜单栏明暗反色
                sb.image = img
                sb.imagePosition = .imageLeft
                sb.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                sb.target = self
                sb.action = #selector(openSysMonFromStatusBar)
            }
            // BizMap 业务地图独立菜单栏入口: 接需求时搜关键词→路由到服务→直达作战地图
            bizMapStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let mb = bizMapStatusItem.button {
                let mimg = NSImage(systemSymbolName: "map", accessibilityDescription: "BizMap 业务地图")
                mimg?.isTemplate = true
                mb.image = mimg
                mb.imagePosition = .imageOnly
                mb.toolTip = "BizMap 业务地图"
                mb.target = self
                mb.action = #selector(openBizMapFromStatusBar)
            }

            let smt = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.updateSysStatusTitle() }
            RunLoop.main.add(smt, forMode: .common)
            sysMonTimer = smt
            updateSysStatusTitle()
        } else {
            NSLog("DBoard: ERROR - statusItem button is nil")
        }

        // 订阅需求变化，更新菜单栏图标 badge
        viewModel.$items.sink { [weak self] items in
            let urgent = items.filter { $0.isUrgent }.count
            DispatchQueue.main.async {
                guard let self = self, let button = self.statusItem.button else { return }
                self.updateStatusIcon(button: button, urgent: urgent)
            }
        }.store(in: &cancellables)

        let rootView = DBoardRootView().environmentObject(viewModel).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
        let hosting = NSHostingController(rootView: rootView)

        // 创建可拖拽/可缩放的浮动窗口
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "我的需求看板"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        // 窗口透明度: 只在原生毛玻璃 (nativeBlur) 主题下才需要 clear 背景透出桌面壁纸
        // 其它主题 (minimal / kraft / kraft-lite) 保持不透明, 否则 fullSizeContentView 下
        // 顶部标题栏区域会因窗口 backing 透明而看穿桌面
        let needsTransparent = ThemeManager.shared.current.nativeBlur
        win.isOpaque = !needsTransparent
        win.backgroundColor = needsTransparent ? .clear : NSColor(named: "WindowBg") ?? .windowBackgroundColor
        win.contentViewController = hosting

        // 主题切换时同步窗口透明度: 从毛玻璃切到 minimal, 或反过来
        NotificationCenter.default.addObserver(forName: .init("DBoardThemeChanged"),
                                                object: nil, queue: .main) { [weak win] _ in
            guard let w = win else { return }
            let needTrans = ThemeManager.shared.current.nativeBlur
            w.isOpaque = !needTrans
            w.backgroundColor = needTrans ? .clear : .windowBackgroundColor
        }
        win.minSize = NSSize(width: 380, height: 480)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 关闭时改为隐藏而不是销毁
        win.standardWindowButton(.closeButton)?.target = self
        win.standardWindowButton(.closeButton)?.action = #selector(hidePanelWindow)
        panelWindow = win

        // 窗口关闭/变 key 时的焦点处理
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            if let o = self?.focusObserver { NotificationCenter.default.removeObserver(o); self?.focusObserver = nil }
        }

        // Tech Scout 初始化
        techScoutVM = TechScoutViewModel()
        techScoutWindow = TechScoutWindowController(viewModel: techScoutVM)

        // 监听 D板窗口内的 Tech Scout 入口点击
        NotificationCenter.default.addObserver(forName: .init("openTechScout"), object: nil, queue: .main) { [weak self] _ in
            self?.hidePanelWindow()
            self?.techScoutVM.reload()
            self?.techScoutWindow.show()
        }

        // 钉钉待回复 初始化
        replyInboxVM = ReplyInboxViewModel()
        replyInboxWindow = ReplyInboxWindowController(viewModel: replyInboxVM)

        // 监听待回复入口点击
        NotificationCenter.default.addObserver(forName: .init("openReplyInbox"), object: nil, queue: .main) { [weak self] _ in
            self?.hidePanelWindow()
            self?.replyInboxWindow.show()
        }

        // 监听应用发布台入口(命令面板等)，WKWebView 内嵌 audi 线上版
        NotificationCenter.default.addObserver(forName: .init("openAppRelease"), object: nil, queue: .main) { [weak self] _ in
            self?.hidePanelWindow()
            AppReleaseWindowController.shared.show()
        }

        // 监听 52etf.site 入口点击
        NotificationCenter.default.addObserver(forName: .init("openETF"), object: nil, queue: .main) { [weak self] _ in
            self?.hidePanelWindow()   // 看板是置顶浮动层, 不收起会一直盖在行情窗口上
            self?.showETFWindow()
        }

        // 系统监控入口
        NotificationCenter.default.addObserver(forName: .init("openSkillsBoard"), object: nil, queue: .main) { [weak self] _ in
            self?.closeMainPopover()
            self?.hidePanelWindow()
            SkillsBoardWindowController.shared.show()
        }
        NotificationCenter.default.addObserver(forName: .init("openSysMon"), object: nil, queue: .main) { [weak self] _ in
            self?.hidePanelWindow()
            SysMonWindowController.shared.show()
        }

        // 全局快捷键 ⌥V: 剪切板历史(D012)
        clipHotKey = HotKey()
        clipHotKey?.register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey)) { [weak self] in
            DispatchQueue.main.async {
                // 剪切板不留菜单栏图标, ⌥V 直接弹窗口
                _ = self
                NSLog("DBoard: clip hotkey fired")
                ClipboardBoardWindowController.shared.show()
            }
        }

        // 全局快捷键 ⌥C: Codex 供应商切换面板(csw 可视化)
        codexHotKey = HotKey()
        codexHotKey?.register(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey)) {
            DispatchQueue.main.async { CodexSwitchWindowController.shared.toggle() }
        }

        // 全局快捷键 ⌃E: 居中浮窗弹 ReqFlow(需求视角), 不贴菜单栏图标
        reqFlowHotKey = HotKey()
        reqFlowHotKey?.register(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(controlKey)) {
            DispatchQueue.main.async {
                BizMapBoardWindowController.shared.toggleWindow(requirements: true)
            }
        }


        // 全局快捷键 Ctrl+O: 今日规划，不占用独立菜单栏入口
        dayPlanHotKey = HotKey()
        dayPlanHotKey?.register(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey)) {
            DispatchQueue.main.async { DayPlanWindowController.shared.toggle() }
        }

        // 全局快捷键 Ctrl+L: Audi 内嵌日志页
        logHotKey = HotKey()
        logHotKey?.register(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey)) {
            DispatchQueue.main.async { AppReleaseWindowController.shared.toggleLogs() }
        }

        // 全局快捷键 ⌃Q: 应用发布台(WKWebView 内嵌 audi 线上版)
        appReleaseHotKey = HotKey()
        appReleaseHotKey?.register(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey)) {
            DispatchQueue.main.async { AppReleaseWindowController.shared.toggle() }
        }

        // 全局快捷键 Ctrl+W: Audi 首页
        audiHomeHotKey = HotKey()
        audiHomeHotKey?.register(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey)) {
            DispatchQueue.main.async { AppReleaseWindowController.shared.toggleHome() }
        }

        // 全局快捷键 Ctrl+Shift+L: 取剪切板文本直接搜日志
        logClipHotKey = HotKey()
        logClipHotKey?.register(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | shiftKey)) {
            DispatchQueue.main.async { LogSearchWindowController.shared.searchWithClipboard() }
        }

        // 调试触发: echo optv|mbpanel > /tmp/dboard-debug-trigger → 等价于按 ⌥V / 点菜单栏管家图标
        debugTriggerTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            let path = "/tmp/dboard-debug-trigger"
            guard FileManager.default.fileExists(atPath: path),
                  let cmd = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(atPath: path)
            let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("DBoard: debug trigger cmd=\(c)")
            switch c {
            case "optv": ClipboardBoardWindowController.shared.show()
            case "ctrlr": BizMapBoardWindowController.shared.toggleWindow(requirements: true)
            case "logsearch": LogSearchWindowController.shared.show()
            case "codex": CodexSwitchWindowController.shared.toggle()
            case "apprelease": AppReleaseWindowController.shared.show()
            case "dayplan": DayPlanWindowController.shared.toggle()
            case let cmd where c.hasPrefix("logsearchq="):
                LogSearchWindowController.shared.debugSearch(String(cmd.dropFirst("logsearchq=".count)))

            case "report":
                let w = ClipboardBoardWindowController.shared.debugWindowInfo()
                try? w.write(toFile: "/tmp/dboard-debug-report.txt", atomically: true, encoding: .utf8)
            case "hkreport":
                let r = "clip(⌥V)=\(self?.clipHotKey?.isRegistered ?? false) log(Ctrl+L)=\(self?.logHotKey?.isRegistered ?? false) logClip(Ctrl+⇧L)=\(self?.logClipHotKey?.isRegistered ?? false) codex(⌥C)=\(self?.codexHotKey?.isRegistered ?? false) reqflow(⌃E)=\(self?.reqFlowHotKey?.isRegistered ?? false) dayPlan(⌃O)=\(self?.dayPlanHotKey?.isRegistered ?? false) audiHome(Ctrl+W)=\(self?.audiHomeHotKey?.isRegistered ?? false)"
                try? r.write(toFile: "/tmp/dboard-debug-report.txt", atomically: true, encoding: .utf8)
            default: break
            }
        }

        // 剪切板后台监控(D012): changeCount 轮询, 纯本地
        ClipboardMonitor.shared.start()
    }

    @objc private func openBizMapFromStatusBar() {
        guard let btn = bizMapStatusItem?.button else { return }
        BizMapBoardWindowController.shared.togglePopover(relativeTo: btn)
    }




    @objc private func openSysMonFromStatusBar() {
        guard let btn = sysStatusItem?.button else { return }
        SysMonWindowController.shared.togglePopover(relativeTo: btn)
    }

    /// 菜单栏实时CPU%(host_statistics 差分, 5秒一次, 开销可忽略)
    /// 菜单栏: 与面板同口径的卡顿灯(负载/核 + 换页速率), 不显示会误导的 CPU%
    private func updateSysStatusTitle() {
        guard let sb = sysStatusItem?.button else { return }

        // 换页速率差分
        var vmstat = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var rate = 0.0
        let kr = withUnsafeMutablePointer(to: &vmstat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let ins = UInt64(vmstat.swapins), outs = UInt64(vmstat.swapouts)
            let now = Date()
            if let p = prevSysSwap {
                let dt = now.timeIntervalSince(p.at)
                if dt > 0.5 { rate = Double((ins &- p.ins) + (outs &- p.outs)) / dt }
            }
            prevSysSwap = (ins: ins, outs: outs, at: now)
        }

        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let lpc = cores > 0 ? la[0] / cores : 0

        // 内存空闲率与交换区(供历史留存)
        var freePct = 100.0
        if kr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            let avail = (Double(vmstat.free_count) + Double(vmstat.inactive_count)
                         + Double(vmstat.purgeable_count)) * page
            if total > 0 { freePct = avail / total * 100 }
        }
        var sw = xsw_usage()
        var swSz = MemoryLayout<xsw_usage>.size
        var swapGB = 0.0
        if sysctlbyname("vm.swapusage", &sw, &swSz, nil, 0) == 0 {
            swapGB = Double(sw.xsu_used) / 1073741824
        }

        // 与 SysMonViewModel 判级一致
        let therm = ProcessInfo.processInfo.thermalState
        let hot = therm == .serious || therm == .critical
        let severe = rate > 200 || lpc > 2.0 || freePct < 8
        let mild = rate > 20 || lpc > 1.0 || freePct < 15 || hot

        // 常驻落历史(面板关着也记) —— 卡的那一刻必须留下证据
        SysHistoryStore.shared.record(level: severe ? 2 : (mild ? 1 : 0),
                                      rate: rate, lpc: lpc, freePct: freePct, swapGB: swapGB)

        // severe/mild 仅用于 tooltip 和历史采样, 不再影响图标颜色

        // 图标始终白色(模板图像 + 不设 tint), 不变色
        sb.attributedTitle = NSAttributedString(string: "")
        sb.toolTip = severe || mild
            ? String(format: "卡顿: 负载 %.1f/核, 换页 %.0f页/秒", lpc, rate)
            : String(format: "流畅: 负载 %.1f/核", lpc)
    }

    private func showETFWindow() {
        // 自绘大盘云图(东方财富公开行情), 不依赖安全网关
        MarketMapWindowController.shared.show()
    }

    private func updateStatusIcon(button: NSStatusBarButton, urgent: Int) {
        if button.image == nil, let image = NSImage(systemSymbolName: "list.bullet.rectangle.fill", accessibilityDescription: "D板") {
            button.image = image
            button.image?.isTemplate = true
        }
        button.attributedTitle = NSAttributedString(string: "")
    }

    // MARK: - 主面板交互 (popover 模式, 跟系统监控/Skills 同一套)

    @objc func togglePopover() {
        NSLog("DBoard: togglePopover called")
        if isDetached {
            // 已脱出为独立窗口
            guard let win = panelWindow else { return }
            if win.isVisible && win.isKeyWindow { win.orderOut(nil) }
            else { win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            return
        }
        // popover 模式
        if let pop = mainPopover, pop.isShown {
            closeMainPopover()
            return
        }
        guard let btn = statusItem.button else { return }
        viewModel.reload()

        let screenH = (btn.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let popH = min(max(screenH * 0.78, 480), 900)
        let popW: CGFloat = 520

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let rootView = DBoardRootView(popoverMode: true)
            .environmentObject(viewModel)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: rootView.frame(width: popW, height: popH))
        pop.contentSize = NSSize(width: popW, height: popH)
        pop.contentViewController = host
        pop.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        mainPopover = pop

        // 顶部下拉撕出为独立窗口(与其他面板同一套手感)
        panelTearOff.install(key: "DBoardPanel") { [weak self] in
            self?.detachPanel()
        }

        // 点外部收起(兜底 .transient 失效)
        mainClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.mainPopover, p.isShown else { return }
            DispatchQueue.main.async { self.closeMainPopover() }
        }
        mainKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, let p = self?.mainPopover, p.isShown {
                self?.closeMainPopover()
                return nil
            }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: pop, queue: .main) { [weak self] _ in
            self?.teardownMainMonitors()
        }
    }

    private func closeMainPopover() {
        mainPopover?.performClose(nil)
        mainPopover = nil
        teardownMainMonitors()
    }

    private func teardownMainMonitors() {
        if let m = mainClickMonitor { NSEvent.removeMonitor(m); mainClickMonitor = nil }
        if let m = mainKeyMonitor { NSEvent.removeMonitor(m); mainKeyMonitor = nil }
    }

    /// 脱出: 关掉 popover, 用独立窗口打开
    func detachPanel() {
        closeMainPopover()
        isDetached = true
        guard let win = panelWindow else { return }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("DBoard: panel detached to window")
    }

    @objc private func hidePanelWindow() {
        if isDetached {
            isDetached = false
            panelWindow?.orderOut(nil)
            NSLog("DBoard: panel reattached (closed window)")
        } else {
            panelWindow?.orderOut(nil)
        }
    }
}
