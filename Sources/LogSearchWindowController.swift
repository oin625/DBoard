import SwiftUI
import Cocoa

// MARK: - Window Controller (Ctrl+L 面板 / Ctrl+⇧L 剪贴板 / 上下文独立窗口)

final class LogSearchWindowController: NSObject, NSWindowDelegate {
    static let shared = LogSearchWindowController(isPrimary: true)
    private static var contextWindows: [UUID: LogSearchWindowController] = [:]

    private let controllerID = UUID()
    private let isPrimary: Bool
    private var window: NSWindow?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var hoverMonitor: Any?
    private var hoverTimer: Timer?
    private var lastFrontmost: NSRunningApplication?
    let vm = LogSearchViewModel()

    private init(isPrimary: Bool = false) {
        self.isPrimary = isPrimary
        super.init()
    }

    static func openContextWindow(for entry: LogEntry, from source: LogSearchViewModel) {
        let controller = LogSearchWindowController()
        controller.vm.env = source.env
        contextWindows[controller.controllerID] = controller
        controller.show()
        controller.vm.searchAround(entry)
    }

    func toggle() {
        if let w = window, w.isVisible { hide() } else { show() }
    }

    /// Ctrl+Shift+L: 取剪切板首行文本作为短语 tag 直接查
    func searchWithClipboard() {
        show()
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        let text = raw.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else { return }
        vm.searchClipboardText(text)
    }

    /// 调试通道: /tmp/dboard-debug-trigger 写 logsearchq=关键词 → 开面板直接搜
    func debugSearch(_ q: String) {
        show()
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        vm.debugSearch(text)
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { lastFrontmost = front }
        if let w = window {
            centerOnMouseScreen(w)
            w.makeKeyAndOrderFront(nil)
            installMonitors()
            return
        }
        let rootView = LogSearchRootView(vm: vm)
            .environmentObject(ThemeManager.shared)
        let host = NSHostingController(rootView: rootView)
        let win = LogSearchPanel(contentViewController: host)
        win.title = "日志快搜"
        win.titleVisibility = .visible
        win.titlebarAppearsTransparent = true
        win.toolbarStyle = .unified
        win.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        win.isFloatingPanel = true
        win.level = .floating
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        let _needsTransparent = ThemeManager.shared.current.nativeBlur
        win.isOpaque = !_needsTransparent
        win.backgroundColor = _needsTransparent ? .clear : .windowBackgroundColor
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = true
        win.delegate = self
        win.contentMinSize = NSSize(width: 780, height: 500)
        win.setFrame(NSRect(x: 0, y: 0, width: 1120, height: 720), display: false)
        centerOnMouseScreen(win)
        if !isPrimary { cascadeContextWindow(win) }
        win.makeKeyAndOrderFront(nil)
        window = win
        installMonitors()
    }

    func hide() {
        if !isPrimary {
            window?.close()
            return
        }
        teardownMonitors()
        window?.orderOut(nil)
        restoreFocus()
    }

    private func installMonitors() {
        teardownMonitors()
        // 钻取词 hover: 全局监视器在非激活面板/无输入监视权限时可能收不到事件,
        // 直接轮询鼠标全局坐标(NSEvent.mouseLocation 无需权限), 稳定可靠
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            LogHoverHub.broadcast(screenPoint: NSEvent.mouseLocation)
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, let w = self.window, w.isVisible else { return }
            LogHoverHub.broadcast(screenPoint: NSEvent.mouseLocation)
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let w = self.window, w.isVisible else { return }
            if self.isPrimary, !w.frame.contains(NSEvent.mouseLocation), !self.vm.isPinned {
                DispatchQueue.main.async { self.hide() }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = self.window, w.isVisible, w.isKeyWindow, e.window === w, w.attachedSheet == nil else { return e }
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch e.keyCode {
            case 53:  // Esc: 先清输入框里的半截关键词, 再清应用, 最后关窗
                if !self.vm.kwInput.isEmpty { self.vm.kwInput = ""; return nil }
                if !self.vm.appName.isEmpty { self.vm.appName = ""; return nil }
                self.hide()
                return nil
            default:
                // 非输入状态回车 = 查询; 焦点在文本输入(NSTextField 系/行内文本)时放行,
                // 避免与字段自身 onSubmit 叠加成双重查询。⌘Return 交给工具栏按钮的 keyboardShortcut。
                if (e.keyCode == 36 || e.keyCode == 76), flags.isEmpty {
                    let fr = w.firstResponder
                    let editing = fr is NSTextView
                        || fr is NSTextField
                        || String(describing: type(of: fr)).contains("TextFieldCell")
                    if !editing {
                        self.vm.runQuery(1)
                        return nil
                    }
                }
                return e
            }
        }
    }

    private func teardownMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = hoverMonitor { NSEvent.removeMonitor(m); hoverMonitor = nil }
        hoverTimer?.invalidate(); hoverTimer = nil
    }

    private func restoreFocus() {
        if NSApp.isActive, let app = lastFrontmost, !app.isTerminated,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate()
        }
        lastFrontmost = nil
    }

    private func centerOnMouseScreen(_ win: NSWindow) {
        // 全局快捷键可能在 DBoard 仍处于活跃状态时触发, 此时 NSScreen.main 可能还是上次的屏幕。
        // 优先跟随鼠标所在屏幕, 避免面板留在之前的桌面。
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
        let scr = mouseScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = scr?.visibleFrame else { return }
        var fr = win.frame
        // 窗口比目标屏还宽/高时夹紧, 避免负偏移
        fr.size.width = min(fr.size.width, f.width)
        fr.size.height = min(fr.size.height, f.height)
        fr.origin.x = f.minX + (f.width - fr.width) / 2
        fr.origin.y = f.minY + (f.height - fr.height) * 0.6
        // 兜底: 若算出的位置不与任何"正常坐标"屏幕(visibleFrame.minX >= -100,
        // 排除负坐标幽灵/断连屏)相交, 强制回到主屏
        let realScreens = NSScreen.screens.filter { $0.visibleFrame.minX >= -100 }
        if !realScreens.contains(where: { $0.visibleFrame.intersects(fr) }),
           let mainFrame = (realScreens.first ?? NSScreen.main)?.visibleFrame {
            fr.origin.x = mainFrame.minX + (mainFrame.width - fr.width) / 2
            fr.origin.y = mainFrame.minY + (mainFrame.height - fr.height) * 0.6
        }
        win.setFrame(fr, display: false)
    }

    private func cascadeContextWindow(_ win: NSWindow) {
        let index = max(0, Self.contextWindows.count - 1) % 6
        let offset = CGFloat(index) * 24
        var frame = win.frame
        frame.origin.x += offset
        frame.origin.y -= offset
        win.setFrame(frame, display: false)
    }

    func windowWillClose(_ notification: Notification) {
        teardownMonitors()
        guard !isPrimary else { return }
        Self.contextWindows.removeValue(forKey: controllerID)
    }
}
