import SwiftUI
import Carbon.HIToolbox
import UserNotifications
import Combine
import WebKit

@main
struct DBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panelWindow: NSWindow?
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
    private var skillsStatusItem: NSStatusItem!
    private var isDetached = false   // 面板脱出为独立窗口(不置顶)
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("DBoard: applicationDidFinishLaunching called")

        // 通知中心代理
        UNUserNotificationCenter.current().delegate = self

        // 创建 statusItem 并保持强引用
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSLog("DBoard: statusItem created: \(statusItem != nil)")

        viewModel = DBoardViewModel()

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
            // Skills 看板独立菜单栏入口
            skillsStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let kb = skillsStatusItem.button {
                let kimg = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Skills 看板")
                kimg?.isTemplate = true
                kb.image = kimg
                kb.imagePosition = .imageOnly
                kb.toolTip = "Skills 看板"
                kb.target = self
                kb.action = #selector(openSkillsFromStatusBar)
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
        win.contentViewController = hosting
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

        // 监听 52etf.site 入口点击
        NotificationCenter.default.addObserver(forName: .init("openETF"), object: nil, queue: .main) { [weak self] _ in
            self?.hidePanelWindow()   // 看板是置顶浮动层, 不收起会一直盖在行情窗口上
            self?.showETFWindow()
        }

        // 系统监控入口
        NotificationCenter.default.addObserver(forName: .init("openSkillsBoard"), object: nil, queue: .main) { [weak self] _ in
            self?.hidePanelWindow()
            SkillsBoardWindowController.shared.show()
        }
        NotificationCenter.default.addObserver(forName: .init("openSysMon"), object: nil, queue: .main) { [weak self] _ in
            self?.hidePanelWindow()
            SysMonWindowController.shared.show()
        }

        // 全局快捷键 Ctrl+D
        HotKey.shared.register(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey)) { [weak self] in
            DispatchQueue.main.async { self?.togglePopover() }
        }
    }

    @objc private func openSkillsFromStatusBar() {
        guard let btn = skillsStatusItem?.button else { return }
        SkillsBoardWindowController.shared.togglePopover(relativeTo: btn)
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

    @objc func togglePopover() {
        NSLog("DBoard: togglePopover called")
        guard let win = panelWindow else { return }
        if isDetached {
            // 已脱出: 点图标只做 显示/隐藏, 不改位置
            if win.isVisible && win.isKeyWindow {
                win.orderOut(nil)
            } else {
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            if win.isVisible {
                win.orderOut(nil)
            } else {
                showPopover()
            }
        }
    }

    /// 外部调用: 将面板脱出为独立窗口(降层级 + 显示标题栏)
    func detachPanel() {
        guard let win = panelWindow, !isDetached else { return }
        isDetached = true
        win.level = .normal                          // 不再置顶
        win.titleVisibility = .visible               // 显示标题
        win.titlebarAppearsTransparent = false       // 标题栏不透明(出现红绿灯)
        win.isMovableByWindowBackground = false      // 用标准标题栏拖动
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        NSLog("DBoard: panel detached")
    }

    /// 收回面板: 恢复浮动模式
    private func reattachPanel() {
        guard let win = panelWindow, isDetached else { return }
        isDetached = false
        win.level = .floating
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSLog("DBoard: panel reattached")
    }

    @objc private func hidePanelWindow() {
        reattachPanel()    // 关窗 -> 回到浮动面板模式
        panelWindow?.orderOut(nil)
    }

    private func showPopover() {
        guard let win = panelWindow else { return }
        viewModel.reload()

        // 首次显示时把窗口定位到菜单栏图标下方
        if !win.isVisible, let button = statusItem.button,
           let btnWin = button.window {
            let btnRectOnScreen = btnWin.convertToScreen(button.convert(button.bounds, to: nil))
            let winSize = win.frame.size
            let x = btnRectOnScreen.midX - winSize.width / 2
            let y = btnRectOnScreen.minY - winSize.height - 6
            // 若曾经手动移动过，保留上次位置（frameAutosaveName 处理）
            if win.frameAutosaveName.isEmpty {
                win.setFrameAutosaveName("DBoardMainWindow")
            }
            if !win.setFrameUsingName("DBoardMainWindow") {
                win.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            win.makeFirstResponder(nil)
            if self.focusObserver == nil {
                self.focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { [weak win] _ in
                    win?.makeFirstResponder(nil)
                }
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 即使 app 在前台也显示通知
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // 用户点击通知 → 打开 Tech Scout 窗口
        NSLog("DBoard: didReceive notification response: \(response.notification.request.identifier)")
        if response.notification.request.identifier.hasPrefix("tech-scout") {
            DispatchQueue.main.async { [weak self] in
                self?.techScoutVM.reload()
                self?.techScoutWindow.show()
            }
        } else if response.notification.request.identifier.hasPrefix("reply-inbox") {
            DispatchQueue.main.async { [weak self] in
                self?.replyInboxWindow.show()
            }
        }
        completionHandler()
    }
}
