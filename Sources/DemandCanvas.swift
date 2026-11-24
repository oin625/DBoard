import SwiftUI
import AppKit

/// The same renderer powers live windows and appearance previews.
struct ThemeCanvasBackground: View {
    let palette: DBoardTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if palette.nativeBlur {
                NativeBlurView()
                palette.background.opacity(colorScheme == .dark ? 0.50 : 0.42)
            } else {
                palette.background
            }
            MeshGradient(width: 3, height: 3,
                points: [.init(0, 0), .init(0.5, 0), .init(1, 0),
                         .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                         .init(0, 1), .init(0.5, 1), .init(1, 1)],
                colors: palette.meshColors)
                .opacity(palette.meshOpacity(for: colorScheme))
            if palette == .nova {
                // Broad facets add depth without a timer, particles, or effects over the text.
                AngularGradient(
                    stops: [.init(color: .clear, location: 0),
                            .init(color: palette.orbA.opacity(0.22), location: 0.18),
                            .init(color: .clear, location: 0.31),
                            .init(color: palette.orbB.opacity(0.20), location: 0.49),
                            .init(color: .clear, location: 0.64),
                            .init(color: palette.orbC.opacity(0.13), location: 0.82),
                            .init(color: .clear, location: 1)],
                    center: .topTrailing, startAngle: .degrees(0), endAngle: .degrees(360))
            } else if palette == .aurora {
                GeometryReader { geometry in
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [palette.orbA.opacity(0.33), .clear],
                                                 center: .center, startRadius: 0,
                                                 endRadius: geometry.size.width * 0.50))
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .scaleEffect(x: 1.8, y: 0.65)
                            .rotationEffect(.degrees(-28))
                            .position(x: geometry.size.width * 0.28, y: geometry.size.height * 0.15)
                        Circle()
                            .fill(RadialGradient(colors: [palette.orbB.opacity(0.23), .clear],
                                                 center: .center, startRadius: 0,
                                                 endRadius: geometry.size.width * 0.50))
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .scaleEffect(x: 1.7, y: 0.60)
                            .rotationEffect(.degrees(-28))
                            .position(x: geometry.size.width * 0.95, y: geometry.size.height * 0.85)
                    }
                }
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }
}

struct DemandCanvasBackground: View {
    @EnvironmentObject private var theme: ThemeManager
    var body: some View { ThemeCanvasBackground(palette: theme.current) }
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
    @EnvironmentObject private var theme: ThemeManager
    func body(content: Content) -> some View {
        content
            .environment(\.demandFloatingCanvas, true)
            .buttonStyle(DemandKeyboardPrimitiveButtonStyle(base: DefaultButtonStyle()))
            .disclosureGroupStyle(DemandKeyboardDisclosureStyle())
            .toggleStyle(DemandKeyboardToggleStyle())
            .background { DemandCanvasBackground() }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(theme.current.accentPrimary.opacity(0.4), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                DemandWindowDragArea()
                    .frame(height: 18).padding(.horizontal, 24).padding(.top, 3)
            }
            .dboardFont(size: 13)
            .dboardThemeAccent()
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
