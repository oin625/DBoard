import AppKit
import ObjectiveC

/// One focus order for text, actions and native selectors, independent of Full Keyboard Access.
final class DemandWindowKeyboardNavigation {
    private static var sheetNavigationKey: UInt8 = 0
    private weak var window: NSWindow?
    private var monitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var focusObservers: [NSObjectProtocol] = []
    private struct TabHold {
        let startedAt: TimeInterval
        let backwards: Bool
        var usedForNavigation = false
        var repeated = false
    }
    private var tabHold: TabHold?
    private static let tabTapLimit: TimeInterval = 0.3
    private let onEscape: (() -> Void)?
    private let allowsKindSwitching: Bool

    init(window: NSWindow, allowsKindSwitching: Bool = false, onEscape: (() -> Void)? = nil) {
        self.window = window
        self.onEscape = onEscape
        self.allowsKindSwitching = allowsKindSwitching
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                self.followPointerFocus(event)
                return event
            }
            return self.handleKey(event)
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                self?.tabHold = nil
                if let monitor = self?.monitor { NSEvent.removeMonitor(monitor); self?.monitor = nil }
                if let window = self?.window {
                    objc_setAssociatedObject(window, &Self.sheetNavigationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
            }
        focusObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in self?.tabHold = nil },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in self?.tabHold = nil }
        ]
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        focusObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Editors presented as native sheets get the same navigation without replacing their Escape action.
    static func installForSheet(_ window: NSWindow) {
        guard !(window is DemandWorkspaceWindow),
              objc_getAssociatedObject(window, &sheetNavigationKey) == nil else { return }
        let navigation = DemandWindowKeyboardNavigation(window: window)
        objc_setAssociatedObject(window, &sheetNavigationKey, navigation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyUp {
            guard event.keyCode == 48, let hold = tabHold else { return event }
            tabHold = nil
            guard let window, event.window === window, window.isVisible, window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let root = window.contentView else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return nil }
            // Wait for release to distinguish a tap from a held navigation modifier.
            if !hold.usedForNavigation && !hold.repeated,
               event.timestamp - hold.startedAt <= Self.tabTapLimit {
                _ = moveFocus(backwards: hold.backwards, in: root, window: window)
            }
            return nil
        }
        guard event.type == .keyDown, let window, event.window === window,
              window.isVisible, window.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let root = window.contentView else { return event }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        if event.keyCode == 53, !event.modifierFlags.contains(.shift), let onEscape {
            tabHold = nil
            onEscape()
            return nil
        }
        if event.keyCode == 48 {
            if event.isARepeat {
                tabHold?.repeated = true
            } else {
                tabHold = TabHold(startedAt: event.timestamp, backwards: event.modifierFlags.contains(.shift))
                (window.firstResponder as? DemandKeyboardActionView)?.revealFocusRing()
            }
            return nil
        }
        if tabHold != nil, [UInt16(125), 126].contains(event.keyCode) {
            tabHold?.usedForNavigation = true
            if !event.isARepeat {
                _ = moveFocus(backwards: event.keyCode == 126, in: root, window: window)
            }
            return nil
        }
        guard !event.modifierFlags.contains(.shift) else { return event }
        if allowsKindSwitching, [UInt16(123), 124].contains(event.keyCode),
           !isEditing(window.firstResponder), !(window.firstResponder is NSControl) {
            let kinds = descendants(root).compactMap { $0 as? DemandKeyboardActionView }
                .filter { $0.keyboardIdentifier.hasPrefix("demand-kind-") && isAvailable($0) }
                .sorted { $0.convert($0.bounds, to: root).minX < $1.convert($1.bounds, to: root).minX }
            if kinds.count > 1 {
                let current = kinds.firstIndex { $0.selected } ?? 0
                let index = (current + (event.keyCode == 124 ? 1 : -1) + kinds.count) % kinds.count
                let target = kinds[index]
                focus(target, window: window)
                target.activate()
                // Switching the form may replace SwiftUI nodes. Reacquire its selected control.
                DispatchQueue.main.async { [weak self] in
                    self?.focusControl(identifier: target.keyboardIdentifier)
                }
                return nil
            }
        }
        if [UInt16(36), 76, 49].contains(event.keyCode) {
            if let action = window.firstResponder as? DemandKeyboardActionView {
                action.activate()
                return nil
            }
            if let button = window.firstResponder as? NSButton, button.isEnabled {
                button.performClick(nil)
                return nil
            }
        }
        guard event.keyCode == 125 || event.keyCode == 126 else { return event }
        // Text and native selectors retain their own cursor and selection behavior.
        if isEditing(window.firstResponder) || window.firstResponder is NSControl { return event }
        let scrolls = descendants(root).compactMap { $0 as? NSScrollView }.filter {
            !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty &&
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1
        }
        guard let scroll = scrolls.max(by: {
            $0.visibleRect.width * $0.visibleRect.height < $1.visibleRect.width * $1.visibleRect.height
        }), let document = scroll.documentView else { return event }
        let direction: CGFloat = event.keyCode == 125 ? 1 : -1
        let delta = direction * (document.isFlipped ? 1 : -1) * 64
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y = min(max(document.bounds.minY, origin.y + delta),
                       max(document.bounds.minY, document.bounds.maxY - clip.bounds.height))
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        return nil
    }

    @discardableResult
    func focusControl(identifier: String) -> Bool {
        guard let window, let root = window.contentView,
              let target = descendants(root).compactMap({ $0 as? DemandKeyboardActionView })
                .first(where: { $0.keyboardIdentifier == identifier && isAvailable($0) }) else { return false }
        return focus(target, window: window)
    }

    func focusableControls() -> [NSView] {
        guard let root = window?.contentView else { return [] }
        let all = descendants(root)
        let actions = all.compactMap { $0 as? DemandKeyboardActionView }.filter(isAvailable)
        let controls = all.filter { view in
            guard isAvailable(view) else { return false }
            if let action = view as? DemandKeyboardActionView {
                return !allowsKindSwitching || !action.keyboardIdentifier.hasPrefix("demand-kind-") || action.selected
            }
            if let field = view as? NSTextField { return field.isEditable && field.isEnabled }
            if let text = view as? NSTextView { return text.isEditable && !text.isFieldEditor }
            if let control = view as? NSControl,
               control is NSButton || control is NSDatePicker || control is NSSegmentedControl {
                guard control.isEnabled else { return false }
                // A styled button's native implementation and its overlay are one Tab stop.
                let frame = view.convert(view.bounds, to: root)
                return !actions.contains { action in
                    let other = action.convert(action.bounds, to: root)
                    return other.contains(NSPoint(x: frame.midX, y: frame.midY))
                }
            }
            return false
        }
        return controls.enumerated().map {
            (view: $0.element, path: navigationPath($0.element, in: root), order: $0.offset)
        }.sorted { left, right in
            for (a, b) in zip(left.path, right.path) {
                if a.view === b.view { continue }
                if abs(a.frame.minY - b.frame.minY) > 3 { return a.frame.minY < b.frame.minY }
                if abs(a.frame.minX - b.frame.minX) > 1 { return a.frame.minX < b.frame.minX }
            }
            return left.order < right.order
        }.map(\.view)
    }

    private func moveFocus(backwards: Bool, in root: NSView, window: NSWindow) -> Bool {
        let controls = focusableControls()
        guard !controls.isEmpty else { return false }
        let current = controls.firstIndex { control in
            if let field = control as? NSTextField, let editor = field.currentEditor(),
               editor === window.firstResponder { return true }
            guard let responder = window.firstResponder as? NSView else { return false }
            return responder === control || responder.isDescendant(of: control)
        }
        let start = current.map { ($0 + (backwards ? -1 : 1) + controls.count) % controls.count }
            ?? (backwards ? controls.count - 1 : 0)
        // Some native controls decline first responder when macOS keyboard access is disabled.
        for offset in 0..<controls.count {
            let index = (start + (backwards ? -offset : offset) + controls.count) % controls.count
            if focus(controls[index], window: window) { return true }
        }
        return false
    }

    @discardableResult
    private func focus(_ target: NSView, window: NSWindow) -> Bool {
        guard window.makeFirstResponder(target) else { return false }
        (target as? DemandKeyboardActionView)?.revealFocusRing()
        // Reveal the control through every enclosing scroll view.
        let display = displayView(target)
        var ancestor = display.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                var rect = display.convert(display.bounds, to: document)
                if rect.height > scroll.contentView.bounds.height {
                    if !document.isFlipped { rect.origin.y = rect.maxY - 44 }
                    rect.size.height = 44
                }
                document.scrollToVisible(rect.insetBy(dx: 0, dy: -8))
            }
            ancestor = view.superview
        }
        return true
    }

    private func followPointerFocus(_ event: NSEvent) {
        guard let window, event.window === window, window.isVisible, window.attachedSheet == nil,
              let root = window.contentView else { return }
        let targets = descendants(root).compactMap { $0 as? DemandKeyboardActionView }.filter { target in
            guard isAvailable(target) else { return false }
            let point = target.convert(event.locationInWindow, from: nil)
            return target.visibleRect.contains(point)
        }
        if let target = targets.min(by: {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }) {
            // Keep the pointer event in place; revealing here could move the button before its click.
            window.makeFirstResponder(target)
            target.revealFocusRing()
        }
    }

    private func isEditing(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        if let field = responder as? NSTextField { return field.isEditable }
        return false
    }

    private func isAvailable(_ view: NSView) -> Bool {
        !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0 && view.frame.width > 0 &&
        view.frame.height > 0 && ((view as? DemandKeyboardActionView)?.enabled ?? true)
    }

    private func displayView(_ view: NSView) -> NSView {
        if let scroll = view.enclosingScrollView, scroll.documentView === view { return scroll }
        return view
    }

    /// Group controls by their containing document. Scrolling cannot change the order,
    /// and fixed footer buttons follow all fields in the form, including offscreen fields.
    private func navigationPath(_ view: NSView, in root: NSView) -> [(view: NSView, frame: NSRect)] {
        let display = displayView(view)
        var scopes: [NSView] = []
        var ancestor = display.superview
        while let parent = ancestor {
            if let scroll = parent as? NSScrollView { scopes.append(scroll) }
            ancestor = parent.superview
        }
        scopes.reverse()
        scopes.append(display)
        var container = root
        return scopes.map { scope in
            var rect = scope.convert(scope.bounds, to: container)
            if !container.isFlipped { rect.origin.y = container.bounds.maxY - rect.maxY }
            if let scroll = scope as? NSScrollView, let document = scroll.documentView { container = document }
            return (view: scope, frame: rect)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
