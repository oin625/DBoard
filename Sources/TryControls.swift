import SwiftUI

enum TryMotion {
    static func animation(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }
    static func transition(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6))
    }
}

/// Put the hit area inside the label so plain buttons and native menu labels include their padding.
private struct TryControlTarget: ViewModifier {
    var fillWidth = false
    var horizontalPadding: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(Rectangle())
    }
}

extension View {
    func tryControlTarget(fillWidth: Bool = false, horizontalPadding: CGFloat = 10) -> some View {
        modifier(TryControlTarget(fillWidth: fillWidth, horizontalPadding: horizontalPadding))
    }
}

/// Quiet appearance with a generous pointer target; keyboard overlays still use the same action.
struct TryControlStyle: ButtonStyle {
    var fillWidth = false
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tryControlTarget(fillWidth: fillWidth)
            .background(theme.current.accentPrimary.opacity(
                enabled && (hovering || configuration.isPressed) ? 0.07 : 0),
                in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// The native borderless menu discards label padding. Button menus honor the same label geometry as our buttons.
struct TryMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration).menuStyle(.button).buttonStyle(TryControlStyle())
    }
}

/// Every disclosure headline is a full-width control, including the whitespace beside its text.
struct TryDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(TryMotion.animation(reduceMotion)) { configuration.isExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .dboardFont(size: 9, weight: .semibold)
                        .foregroundStyle(.secondary).frame(width: 10)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                }
            }
            .demandButtonStyle(TryControlStyle(fillWidth: true))
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded {
                configuration.content.demandKeyboardID("").transition(TryMotion.transition(reduceMotion))
            }
        }
    }
}
