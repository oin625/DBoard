import AppKit
import Combine

/// 工作窗口只通过关闭或 Esc 收起；置顶是独立、可记忆的选择。
final class WorkspaceWindowInteraction {
    private weak var window: NSWindow?
    private let id: String
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var subscription: AnyCancellable?
    private let onHide: (() -> Void)?
    private let handlesEscape: Bool

    init(window: NSWindow, id: String, handlesEscape: Bool = true, onHide: (() -> Void)? = nil) {
        self.window = window
        self.id = id
        self.handlesEscape = handlesEscape
        self.onHide = onHide
        window.hidesOnDeactivate = false
        window.toolbarStyle = .unified
        subscription = WorkspacePreferences.shared.$pinnedWindows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyPin() }
        applyPin()
        if handlesEscape {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isVisible,
                      event.window === window, window.isKeyWindow, event.keyCode == 53,
                      window.attachedSheet == nil else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
                window.orderOut(nil)
                self.onHide?()
                return nil
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.onHide?() }
    }

    private func applyPin() {
        guard let window else { return }
        let pinned = WorkspacePreferences.shared.pinnedWindows.contains(id)
        window.level = pinned ? .floating : .normal
        window.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenPrimary]
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}

/// 浮层收起时只恢复焦点，不把窗口切换造成的外部点击吞掉。
final class PanelFocusReturn {
    private var previous: NSRunningApplication?
    func capture() {
        let app = NSWorkspace.shared.frontmostApplication
        if app?.bundleIdentifier != Bundle.main.bundleIdentifier { previous = app }
    }
    func discard() { previous = nil }
    func restore() {
        guard NSApp.isActive, let previous, !previous.isTerminated,
              previous.bundleIdentifier != Bundle.main.bundleIdentifier else { self.previous = nil; return }
        previous.activate()
        self.previous = nil
    }
}
