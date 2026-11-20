import SwiftUI
import AppKit
import Combine

/// Space changes have their own publisher: they do not invalidate every work demand card.
final class WorkspaceSpaces: ObservableObject {
    @Published private(set) var selection: DBoardSpace = .main
    var binding: Binding<DBoardSpace> { Binding(get: { self.selection }, set: { self.select($0) }) }
    func select(_ value: DBoardSpace) {
        guard selection != value else { return }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            if editor.hasMarkedText() { editor.unmarkText() }
            editor.didChangeText()
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
        NotificationCenter.default.post(name: .init("DBoardFlushPersonalDrafts"), object: nil)
        selection = value
    }
    func move(_ delta: Int) { select(delta > 0 ? .personal : .main) }
}

/// Keep both pages mounted. Switching only moves the viewport, preserving editor and native view identity.
struct WorkspaceSpacePager<Main: View, Personal: View>: View {
    @ObservedObject var spaces: WorkspaceSpaces
    let main: Main
    let personal: Personal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(spaces: WorkspaceSpaces, @ViewBuilder main: () -> Main, @ViewBuilder personal: () -> Personal) {
        self.spaces = spaces; self.main = main(); self.personal = personal()
    }
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSpacePicker(selection: spaces.binding)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    main.frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(spaces.selection == .main).accessibilityHidden(spaces.selection != .main)
                    personal.frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(spaces.selection == .personal).accessibilityHidden(spaces.selection != .personal)
                }
                .frame(width: geometry.size.width * 2, height: geometry.size.height, alignment: .leading)
                .offset(x: spaces.selection == .main ? 0 : -geometry.size.width)
                .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1), value: spaces.selection)
            }.clipped()
        }
        .background(WorkspaceSwipeBridge { spaces.move($0) })
    }
}

struct WorkspaceSwipeTracker {
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var fired = false
    private var vertical = false
    mutating func reset() { x = 0; y = 0; fired = false; vertical = false }
    mutating func update(dx: CGFloat, dy: CGFloat) -> Int? {
        guard !fired && !vertical else { return nil }
        x += dx; y += dy
        if abs(y) > 18 && abs(y) > abs(x) * 1.3 { vertical = true; return nil }
        guard abs(x) >= 55 && abs(x) > abs(y) * 1.5 else { return nil }
        fired = true
        return x < 0 ? 1 : -1
    }
}

struct WorkspaceSwipeBridge: NSViewRepresentable {
    let move: (Int) -> Void
    func makeNSView(context: Context) -> WorkspaceSwipeView { WorkspaceSwipeView() }
    func updateNSView(_ view: WorkspaceSwipeView, context: Context) { view.move = move }
    static func dismantleNSView(_ view: WorkspaceSwipeView, coordinator: ()) { view.stop() }
}
final class WorkspaceSwipeView: NSView {
    var move: ((Int) -> Void)?
    private var monitor: Any?
    private var tracker = WorkspaceSwipeTracker()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            guard let self, event.window === self.window, event.window?.attachedSheet == nil else { return event }
            if event.type == .swipe, abs(event.deltaX) > abs(event.deltaY) {
                self.move?(event.deltaX < 0 ? 1 : -1)
                return nil
            }
            guard event.type == .scrollWheel, event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty, !event.phase.isEmpty else { return event }
            if event.phase.contains(.began) { self.tracker.reset() }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { self.tracker.reset(); return event }
            if let direction = self.tracker.update(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY) {
                self.move?(direction)
                return nil
            }
            return event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        tracker.reset()
    }
    deinit { stop() }
}
