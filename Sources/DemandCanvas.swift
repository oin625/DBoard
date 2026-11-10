import SwiftUI
import AppKit

/// Shared by the quick-open card and demand pages so all use the same tint and mesh.
struct DemandCanvasBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            MeshGradient(width: 3, height: 3,
                points: [.init(0, 0), .init(0.5, 0), .init(1, 0),
                         .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                         .init(0, 1), .init(0.5, 1), .init(1, 1)],
                colors: [.blue, .indigo, .blue, .clear, .blue, .indigo, .clear, .clear, .blue])
                .opacity(colorScheme == .dark ? 0.22 : 0.13)
        }
        .allowsHitTesting(false)
    }
}

private struct DemandFloatingCanvasKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var demandFloatingCanvas: Bool {
        get { self[DemandFloatingCanvasKey.self] }
        set { self[DemandFloatingCanvasKey.self] = newValue }
    }
}

private struct DemandFloatingCanvas: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.demandFloatingCanvas, true)
            .buttonStyle(DemandKeyboardPrimitiveButtonStyle(base: DefaultButtonStyle()))
            .disclosureGroupStyle(DemandKeyboardDisclosureStyle())
            .toggleStyle(DemandKeyboardToggleStyle())
            .background { DemandCanvasBackground() }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.blue.opacity(0.4), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                DemandWindowDragArea()
                    .frame(height: 18).padding(.horizontal, 24).padding(.top, 3)
            }
    }
}

extension View {
    func demandFloatingCanvas() -> some View {
        modifier(DemandFloatingCanvas())
    }
}

/// A transparent drag target over the existing top padding; it occupies no extra layout space.
private struct DemandWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DemandWindowDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class DemandWindowDragView: NSView {
    private var start: (origin: NSPoint, pointer: NSPoint)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window, window.attachedSheet == nil else { return }
        start = (window.frame.origin, window.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let window else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: start.origin.x + pointer.x - start.pointer.x,
                                      y: start.origin.y + pointer.y - start.pointer.y))
    }

    override func mouseUp(with event: NSEvent) { start = nil }
}
