import SwiftUI

/// Shared surfaces for the home and demand workspace; colors follow macOS appearance.
struct WorkspaceSurface: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.demandFloatingCanvas) private var floatingCanvas
    var radius: CGFloat = 14
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background {
                if floatingCanvas {
                    Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.45 : 0.48)
                } else {
                    Color.clear.themeCardBackground()
                        .overlay { if colorScheme == .dark { Color.white.opacity(0.035) } }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.4) : theme.current.separator.opacity(0.25),
                                  lineWidth: highlighted ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.035), radius: 5, x: 0, y: 2)
    }
}

extension View {
    func workspaceSurface(radius: CGFloat = 14, highlighted: Bool = false) -> some View {
        modifier(WorkspaceSurface(radius: radius, highlighted: highlighted))
    }
}

struct WorkspaceActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).frame(minHeight: 30)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.1 : 0.045))
            }
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Keep short actions on one row when possible, wrap them without truncating labels.
struct WorkspaceFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + arrangement.points[index].x,
                                   y: bounds.minY + arrangement.points[index].y),
                       proposal: ProposedViewSize(view.sizeThatFits(.unspecified)))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), points)
    }
}
