import SwiftUI
import Carbon.HIToolbox
import UserNotifications
import Combine

@main
struct DBoardApp: App {
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--dboard-delivery-cli") {
            DemandDeliveryCommand.run(Array(CommandLine.arguments[index...]))
        }
    }
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { DBoardSettingsView() }
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

    private var mainWindowInteraction: WorkspaceWindowInteraction?
    private let demandDetailWindow = DemandDetailWindowController()
    private let newDemandWindow = NewDemandWindowController()
    private let demandQuickOpenWindow = DemandQuickOpenWindowController()
    private let mainFocusReturn = PanelFocusReturn()
    private var debugTriggerTimer: Timer?

    private var isDetached = false   // 面板脱出为独立窗口(不置顶)
    private let panelTearOff = TearOffObserver()
    private var cancellables = Set<AnyCancellable>()

    func applicationWillTerminate(_ notification: Notification) {
        LocalAudiServer.shared.stop()
    }

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
        viewModel.demandWindowPresenter = { [weak self] vm in
            guard let self else { return }
            self.closeMainPopover(restoreFocus: false)
            self.demandDetailWindow.show(vm)
        }
        viewModel.demandWorkspacePresenter = { [weak self] in self?.detachPanel() }
        viewModel.newDemandWindowPresenter = { [weak self] vm in
            guard let self else { return }
            self.closeMainPopover(restoreFocus: false)
            self.newDemandWindow.show(vm)
        }

        if let button = statusItem.button {
            NSLog("DBoard: statusItem button exists")
            updateStatusIcon(button: button, urgent: viewModel.urgentCount)
            button.action = #selector(togglePopover)
            button.target = self
            NSLog("DBoard: button configured")
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

        let rootView = DBoardRootView().environmentObject(viewModel).environmentObject(ThemeManager.shared).dboardFont(size: 13).environmentObject(FontManager.shared)
        let hosting = NSHostingController(rootView: rootView)

        // 创建可拖拽/可缩放的浮动窗口
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "D板"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.isMovableByWindowBackground = false
        win.level = .normal
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        // Glass needs a transparent backing; opaque skins also tint the titlebar.
        let needsTransparent = ThemeManager.shared.current.nativeBlur
        win.isOpaque = !needsTransparent
        win.backgroundColor = needsTransparent ? .clear : NSColor(ThemeManager.shared.current.background)
        win.contentViewController = hosting

        // Update backing without recreating the hosting view or losing editor state.
        NotificationCenter.default.addObserver(forName: .dboardThemeChanged,
                                                object: ThemeManager.shared, queue: .main) { [weak win] _ in
            guard let w = win else { return }
            let needTrans = ThemeManager.shared.current.nativeBlur
            w.isOpaque = !needTrans
            w.backgroundColor = needTrans ? .clear : NSColor(ThemeManager.shared.current.background)
        }
        win.minSize = NSSize(width: 760, height: 560)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 关闭时改为隐藏而不是销毁
        win.standardWindowButton(.closeButton)?.target = self
        win.standardWindowButton(.closeButton)?.action = #selector(hidePanelWindow)
        panelWindow = win
        mainWindowInteraction = WorkspaceWindowInteraction(window: win, id: "dboard", handlesEscape: false)
        win.setFrameAutosaveName("DBoardWorkspaceWindow")

        // 窗口关闭/变 key 时的焦点处理
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            if let o = self?.focusObserver { NotificationCenter.default.removeObserver(o); self?.focusObserver = nil }
        }

        // Editing uses the persistent workspace; transient popovers must not own sheets.
        NotificationCenter.default.addObserver(forName: .init("DBoardEditorWillOpen"),
            object: nil, queue: .main) { [weak self] _ in
            guard let self, self.mainPopover?.isShown == true else { return }
            self.detachPanel()
        }

        // Tech Scout 初始化
        techScoutVM = TechScoutViewModel()
        techScoutWindow = TechScoutWindowController(viewModel: techScoutVM)

        // 监听 D板窗口内的 Tech Scout 入口点击
        NotificationCenter.default.addObserver(forName: .init("openTechScout"), object: nil, queue: .main) { [weak self] _ in
            self?.closeMainPopover(restoreFocus: false)
            self?.techScoutVM.reload()
            self?.techScoutWindow.show()
        }

        // 钉钉待回复 初始化
        replyInboxVM = ReplyInboxViewModel.shared
        replyInboxWindow = ReplyInboxWindowController(viewModel: replyInboxVM)

        // 监听待回复入口点击
        NotificationCenter.default.addObserver(forName: .init("openReplyInbox"), object: nil, queue: .main) { [weak self] _ in
            self?.closeMainPopover(restoreFocus: false)
            self?.replyInboxWindow.show()
        }

        // 监听应用发布台入口(命令面板等)，WKWebView 内嵌 audi 线上版
        NotificationCenter.default.addObserver(forName: .init("openAppRelease"), object: nil, queue: .main) { [weak self] _ in
            self?.closeMainPopover(restoreFocus: false)
            AppReleaseWindowController.shared.show()
        }

        // Skills 看板入口
        NotificationCenter.default.addObserver(forName: .init("openSkillsBoard"), object: nil, queue: .main) { [weak self] _ in
            self?.closeMainPopover(restoreFocus: false)
            SkillsBoardWindowController.shared.show()
        }

        NotificationCenter.default.addObserver(forName: .init("DBoardModuleWillOpen"), object: nil, queue: .main) { [weak self] _ in
            self?.closeMainPopover(restoreFocus: false)
        }

        var shortcutActions: [String: () -> Void] = [
            "clipboard": { UsageStats.hit("clipboard"); WorkspacePreferences.shared.remember("clipboard"); ClipboardBoardWindowController.shared.show() },
            "reqflow": { UsageStats.hit("reqflow"); WorkspacePreferences.shared.remember("reqflow"); BizMapBoardWindowController.shared.toggleWindow(requirements: true) },
            "logs": { UsageStats.hit("logs"); WorkspacePreferences.shared.remember("logs"); AppReleaseWindowController.shared.toggleLogs() },
            "apprelease": { UsageStats.hit("apprelease"); WorkspacePreferences.shared.remember("apprelease"); AppReleaseWindowController.shared.toggle() },
            "audihome": { UsageStats.hit("audihome"); WorkspacePreferences.shared.remember("audihome"); AppReleaseWindowController.shared.toggleHome() },
        ].mapValues { [weak self] action in
            return { self?.closeMainPopover(restoreFocus: false); action() }
        }
        // Home must toggle before any popover close; other module shortcuts retain their behavior.
        shortcutActions["dboard"] = { [weak self] in self?.toggleHome() }
        shortcutActions["quickopen"] = { [weak self] in self?.toggleQuickOpen() }
        GlobalShortcutManager.shared.configure(actions: shortcutActions)
        // 快捷键状态与配置变化由管理器统一处理，默认保留原有组合。

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
            case "apprelease": AppReleaseWindowController.shared.show()
            case "panel": self?.detachPanel()
            case "home": self?.toggleHome()
            case "quickopen": self?.toggleQuickOpen()
            case "settings":
                self?.detachPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .init("openDBoardSettings"), object: nil)
                }
            case "uireport":
                let report = NSApp.windows.map { "id=\($0.windowNumber) title=\($0.title) visible=\($0.isVisible) frame=\($0.frame) toolbar=\($0.toolbar != nil)" }.joined(separator: "\n")
                try? report.write(toFile: "/tmp/dboard-ui-window-report.txt", atomically: true, encoding: .utf8)
            case let cmd where c.hasPrefix("expand="):
                self?.viewModel.expandedIDs.insert(String(cmd.dropFirst("expand=".count)))
                self?.detachPanel()
            case "report":
                let w = ClipboardBoardWindowController.shared.debugWindowInfo()
                try? w.write(toFile: "/tmp/dboard-debug-report.txt", atomically: true, encoding: .utf8)
            case "hkreport":
                let r = GlobalShortcutManager.shared.report
                try? r.write(toFile: "/tmp/dboard-debug-report.txt", atomically: true, encoding: .utf8)
            default: break
            }
        }

        // 剪切板后台监控(D012): changeCount 轮询, 纯本地
        ClipboardMonitor.shared.start()
    }





    private func updateStatusIcon(button: NSStatusBarButton, urgent: Int) {
        if button.image == nil, let image = NSImage(systemSymbolName: "list.bullet.rectangle.fill", accessibilityDescription: "D板") {
            button.image = image
            button.image?.isTemplate = true
        }
        button.attributedTitle = NSAttributedString(string: "")
    }

    // MARK: - 主面板交互 (popover 模式)

    func toggleQuickOpen() {
        closeMainPopover(restoreFocus: false)
        demandQuickOpenWindow.toggle(viewModel)
    }

    func toggleHome() {
        UsageStats.hit("dboard")
        guard let window = panelWindow else { return }
        let focused = window.isKeyWindow || window.attachedSheet?.isKeyWindow == true
        if isDetached && window.isVisible && focused &&
            (viewModel.workspacePage == .overview || window.attachedSheet != nil) {
            window.orderOut(nil)
            return
        }
        if viewModel.editingFormCount == 0 { viewModel.workspacePage = .overview }
        // A transient menu popover closes on external focus; hotkeys use the persistent workspace.
        detachPanel()
    }

    @objc func togglePopover() {
        UsageStats.hit("dboard")
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
        mainFocusReturn.capture()
        viewModel.workspacePage = .overview
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
            .dboardFont(size: 13).environmentObject(FontManager.shared)
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
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: pop, queue: .main) { [weak self, weak pop] _ in
            guard let self else { return }
            self.teardownMainMonitors()
            if self.mainPopover === pop {
                self.mainPopover = nil
                self.mainFocusReturn.discard()
            }
        }
    }

    func closeMainPopover(restoreFocus: Bool = true) {
        guard let popover = mainPopover else { return }
        mainPopover = nil
        popover.performClose(nil)
        teardownMainMonitors()
        if restoreFocus { mainFocusReturn.restore() }
        else { mainFocusReturn.discard() }
    }

    private func teardownMainMonitors() {
        if let m = mainClickMonitor { NSEvent.removeMonitor(m); mainClickMonitor = nil }
        if let m = mainKeyMonitor { NSEvent.removeMonitor(m); mainKeyMonitor = nil }
    }

    /// 脱出: 关掉 popover, 用独立窗口打开
    func detachPanel() {
        closeMainPopover(restoreFocus: false)
        isDetached = true
        guard let win = panelWindow else { return }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("DBoard: panel detached to window")
    }

    @objc func hidePanelWindow() {
        if isDetached {
            isDetached = false
            panelWindow?.orderOut(nil)
            NSLog("DBoard: panel reattached (closed window)")
        } else {
            panelWindow?.orderOut(nil)
        }
    }
}
