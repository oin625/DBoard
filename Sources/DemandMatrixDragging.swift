import SwiftUI
import AppKit

struct DemandMatrixDrag: Equatable {
    let id: String
    let priority: ItemPriority
}

struct DemandMatrixFrames: Equatable {
    var quadrants: [ItemPriority: CGRect] = [:]
    var cards: [String: CGRect] = [:]
    var board: CGRect = .zero
}

struct DemandMatrixFrameKey: PreferenceKey {
    static var defaultValue = DemandMatrixFrames()
    static func reduce(value: inout DemandMatrixFrames, nextValue: () -> DemandMatrixFrames) {
        let next = nextValue()
        value.quadrants.merge(next.quadrants) { _, new in new }
        value.cards.merge(next.cards) { _, new in new }
        if !next.board.isEmpty { value.board = next.board }
    }
}

/// This board only changes classification within one window. Avoid native pasteboard drag sessions:
/// nested scroll views and controls must not decide whether an occupied quadrant accepts the move.
final class DemandMatrixDragSession: ObservableObject {
    @Published private(set) var active: DemandMatrixDrag?
    @Published private(set) var location: CGPoint = .zero
    @Published private(set) var target: ItemPriority?
    private(set) var frames = DemandMatrixFrames()

    func updateFrames(_ value: DemandMatrixFrames) {
        frames = value
        if active != nil { updateTarget(at: location) }
    }

    func update(_ drag: DemandMatrixDrag, at point: CGPoint) {
        guard active == nil || active?.id == drag.id else { return }
        active = drag
        location = point
        updateTarget(at: point)
    }

    func finish(at point: CGPoint) -> (DemandMatrixDrag, ItemPriority)? {
        defer { cancel() }
        guard let drag = active, let destination = quadrant(at: point), destination != drag.priority else { return nil }
        return (drag, destination)
    }

    func cancel() {
        active = nil
        target = nil
    }

    private func quadrant(at point: CGPoint) -> ItemPriority? {
        DemandMatrix.rows.flatMap { $0 }.first { frames.quadrants[$0]?.contains(point) == true }
    }

    private func updateTarget(at point: CGPoint) {
        let next = quadrant(at: point).flatMap { $0 == active?.priority ? nil : $0 }
        if target != next { target = next }
    }
}

struct DemandMatrixCardInteraction: ViewModifier {
    let drag: DemandMatrixDrag
    let session: DemandMatrixDragSession?
    let open: () -> Void
    let move: (DemandMatrixDrag, ItemPriority) -> Bool

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                GeometryReader { proxy in
                    DemandMatrixPointerRegion(drag: drag, session: session, open: open, move: move,
                        globalFrame: proxy.frame(in: .global)).accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
    }
}

private struct DemandMatrixPointerRegion: NSViewRepresentable {
    let drag: DemandMatrixDrag
    let session: DemandMatrixDragSession?
    let open: () -> Void
    let move: (DemandMatrixDrag, ItemPriority) -> Bool
    let globalFrame: CGRect

    func makeNSView(context: Context) -> DemandMatrixPointerView {
        let view = DemandMatrixPointerView()
        configure(view)
        return view
    }

    func updateNSView(_ view: DemandMatrixPointerView, context: Context) { configure(view) }

    private func configure(_ view: DemandMatrixPointerView) {
        view.drag = drag
        view.session = session
        view.open = open
        view.move = move
        view.globalFrame = globalFrame
    }
}

/// Capture the mouse in the card's non-control regions. This also works on the first mouse down
/// in an inactive window, and keeps copying and reminder text selection outside the drag surface.
final class DemandMatrixPointerView: NSView {
    var drag: DemandMatrixDrag?
    weak var session: DemandMatrixDragSession?
    var open: () -> Void = {}
    var move: (DemandMatrixDrag, ItemPriority) -> Bool = { _, _ in false }
    private var pressedDrag: DemandMatrixDrag?
    private var start: CGPoint?
    private var moved = false
    var globalFrame: CGRect = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    private func point(_ event: NSEvent) -> CGPoint {
        // SwiftUI's global origin includes window chrome; AppKit content coordinates do not.
        // Anchor to this exact surface, which also accounts for nested scroll views and popovers.
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: globalFrame.minX + local.x - bounds.minX,
                       y: globalFrame.minY + local.y - bounds.minY)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        start = point(event)
        pressedDrag = drag
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let pressedDrag else { return }
        let location = point(event)
        guard moved || hypot(location.x - start.x, location.y - start.y) >= 6 else { return }
        moved = true
        session?.update(pressedDrag, at: location)
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; pressedDrag = nil; moved = false }
        guard start != nil else { return }
        if moved {
            let location = point(event)
            guard let content = window?.contentView,
                  content.bounds.contains(content.convert(event.locationInWindow, from: nil)) else {
                session?.cancel(); return
            }
            if let (source, destination) = session?.finish(at: location) { _ = move(source, destination) }
        } else { open() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { session?.cancel(); start = nil; pressedDrag = nil; moved = false }
        else if event.keyCode == 36 || event.keyCode == 49 { open() }
        else { super.keyDown(with: event) }
    }
}
