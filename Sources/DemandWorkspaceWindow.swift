import AppKit

/// The content is the window; AppKit adds no title bar, frame or shadow around it.
final class DemandWorkspaceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        guard delegate?.windowShouldClose?(self) != false else { return }
        close()
    }

    func setContent(_ controller: NSViewController) {
        contentViewController = controller
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 20
        contentView?.layer?.masksToBounds = true
    }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
    }
}

/// Keep the window centered through hosting layout, then release placement on user interaction.
final class DemandWindowCentering {
    private weak var window: NSWindow?
    private var anchor: NSRect?
    private var resizeObserver: NSObjectProtocol?
    private var interactionMonitor: Any?

    init(window: NSWindow) {
        self.window = window
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.adjust() }
        }
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            if let self, event.window === self.window { self.anchor = nil }
            return event
        }
    }

    func center(in visibleFrame: NSRect?) {
        anchor = visibleFrame
        guard let visibleFrame, let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        DemandWindowPlacement.center(window, in: visibleFrame)
        DispatchQueue.main.async { [weak self] in self?.adjust() }
    }

    private func adjust() {
        guard let window, let anchor else { return }
        let frame = DemandWindowPlacement.centeredFrame(window.frame, in: anchor)
        if abs(window.frame.midX - frame.midX) > 0.5 || abs(window.frame.midY - frame.midY) > 0.5 {
            window.setFrame(frame, display: true)
        }
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor) }
    }
}
