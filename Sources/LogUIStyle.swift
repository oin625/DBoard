import SwiftUI
import Cocoa

// MARK: - 日志面板共享 UI 原语 (DESIGN.md: 系统字体 / 材质定层级 / spring 微动效)

/// 排版: 一律系统字体。ui() 保留原调用点写法但映射到 SF Pro;
/// 技术数据用系统等宽, 合规。
enum LogTypography {
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func code(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// 动效常量与 reduce-motion 闸门 (DESIGN.md motion_rules)
enum LogMotion {
    /// spring(response 0.2-0.35) —— pika ContentView 同款参数
    static func springUI() -> Animation {
        .spring(response: 0.25, dampingFraction: 0.8)
    }
    static func springUI(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : springUI()
    }
}

extension View {
    /// 层级材质: macOS 26 用 Liquid Glass, 15 回退 regularMaterial。
    /// 工具栏/浮层条统一走这里, 禁止再手画"实色卡片+描边+阴影"。
    @ViewBuilder
    func logGlass(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius,
                                                                    style: .continuous))
        }
    }
}

/// pika 式悬停/按压反馈按钮样式: hover 淡入底色, 按下变暗, 尊重减弱动效
struct HoverButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Body_: View {
        let configuration: Configuration
        let selected: Bool
        let reduceMotion: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08)
                                       : selected ? Color.accentColor.opacity(0.14)
                                       : Color.clear)
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { h in
                    if reduceMotion { hovering = h }
                    else { withAnimation(.easeInOut(duration: 0.15)) { hovering = h } }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15),
                           value: configuration.isPressed)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        Body_(configuration: configuration, selected: selected,
              reduceMotion: reduceMotion)
    }
}
