import SwiftUI
import AppKit

/// Local to the visible study page; text editors retain their normal plus input.
struct TryLearningNoteShortcut: NSViewRepresentable {
    let enabled: Bool
    let action: () -> Void
    func makeNSView(context: Context) -> TryLearningNoteShortcutView { TryLearningNoteShortcutView() }
    func updateNSView(_ view: TryLearningNoteShortcutView, context: Context) {
        view.enabled = enabled; view.action = action
    }
    static func dismantleNSView(_ view: TryLearningNoteShortcutView, coordinator: ()) { view.stop() }
}

final class TryLearningNoteShortcutView: NSView {
    var enabled = false
    var action: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }
    @discardableResult
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard enabled, !isHiddenOrHasHiddenAncestor, event.type == .keyDown, !event.isARepeat,
              let window, event.window === window, window.isVisible, window.attachedSheet == nil,
              event.characters == "+",
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        if let text = window.firstResponder as? NSTextView, text.isEditable || text.hasMarkedText() { return event }
        if let field = window.firstResponder as? NSTextField, field.isEditable { return event }
        action?()
        return nil
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    deinit { stop() }
}

/// Uses the existing Tab / held-Tab / arrow navigation without changing Main's window behavior.
struct TryKeyboardBridge: NSViewRepresentable {
    var onEscape: () -> Void
    var endsEditingOnEscape = true
    func makeNSView(context: Context) -> TryKeyboardHostView { TryKeyboardHostView() }
    func updateNSView(_ view: TryKeyboardHostView, context: Context) {
        view.onEscape = onEscape; view.endsEditingOnEscape = endsEditingOnEscape
    }
    static func dismantleNSView(_ view: TryKeyboardHostView, coordinator: ()) { view.navigation = nil }
}
final class TryKeyboardHostView: NSView {
    var onEscape: (() -> Void)?
    var endsEditingOnEscape = true
    var navigation: DemandWindowKeyboardNavigation?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        navigation = nil
        guard let window else { return }
        navigation = DemandWindowKeyboardNavigation(window: window, onEscape: { [weak self] in
            guard let self, let window = self.window else { return }
            if self.endsEditingOnEscape, let editor = window.firstResponder as? TryNoteTextView, editor.isEditable {
                editor.didChangeText()
                window.makeFirstResponder(nil)
                editor.isEditable = false
                editor.endWriting?()
                return
            }
            // Commit the native field editor before leaving a title/progress field.
            window.makeFirstResponder(nil)
            self.onEscape?()
        })
    }
}
