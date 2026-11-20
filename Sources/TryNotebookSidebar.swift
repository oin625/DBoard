import SwiftUI
import AppKit

/// A generous native hit area prevents the floating window from consuming sidebar drags.
struct TryNotebookDivider: NSViewRepresentable {
    let tint: Color
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    let clicked: () -> Void

    func makeNSView(context: Context) -> TryNotebookDividerView {
        let view = TryNotebookDividerView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: TryNotebookDividerView, context: Context) {
        view.tint = NSColor(tint)
        view.changed = changed
        view.ended = ended
        view.clicked = clicked
    }
}

final class TryNotebookDividerView: NSView {
    var tint = NSColor.separatorColor { didSet { needsDisplay = true } }
    var changed: ((CGFloat) -> Void)?
    var ended: ((CGFloat) -> Void)?
    var clicked: (() -> Void)?
    private var start: NSPoint?
    private var dragged = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = event.locationInWindow
        if abs(point.x - start.x) > 4 || abs(point.y - start.y) > 4 { dragged = true }
        if dragged { changed?(point.x - start.x) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let offset = event.locationInWindow.x - start.x
        self.start = nil
        if dragged { ended?(offset) }
        else { clicked?() }
    }
}
