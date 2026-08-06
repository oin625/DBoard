import SwiftUI
import AppKit

// MARK: - 撕出手势公共件
// 源自 Skills Board 的交互: popover 顶部往下拖 => 撕成独立窗口。
// 这里抽成修饰器, 让所有菜单栏弹窗共用同一套手感(阈值/提示文案/动效一致)。

extension Notification.Name {
    static func tearOff(_ key: String) -> Notification.Name { .init("tearOff\(key)") }
}

/// 撕出手势 + 拖拽反馈。挂在弹窗顶部 chrome 上(header 那一条)。
/// - key: 面板标识, 与窗口控制器监听的通知名一致
/// - enabled: 仅 popover 模式给手势; 已是独立窗口时不挂
struct TearOffGesture: ViewModifier {
    let key: String
    let enabled: Bool
    @EnvironmentObject var theme: ThemeManager
    @State private var progress: CGFloat = 0

    private let threshold: CGFloat = 32   // 小于此位移多半是误触/手抖

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // 只认向下(dy>0): 向上拖没有语义, 避免与内容滚动抢手势
            .gesture(enabled
                ? DragGesture(minimumDistance: 12)
                    .onChanged { g in
                        progress = max(0, min(1, g.translation.height / threshold))
                    }
                    .onEnded { g in
                        if g.translation.height > threshold {
                            NotificationCenter.default.post(name: .tearOff(key), object: nil)
                        }
                        progress = 0
                    }
                : nil)
            .overlay(alignment: .bottom) {
                if progress > 0.05 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.left.and.arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(progress >= 1 ? "松手变为独立窗口" : "继续下拉…")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(theme.current.accentPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(theme.current.accentPrimary.opacity(0.12)))
                    .opacity(Double(progress))
                }
            }
    }
}

extension View {
    /// popover 顶部下拉撕出为独立窗口
    func tearOffHandle(_ key: String, enabled: Bool = true) -> some View {
        modifier(TearOffGesture(key: key, enabled: enabled))
    }
}

/// 统一的撕出按钮
struct TearOffButton: View {
    let key: String
    @EnvironmentObject var theme: ThemeManager
    var body: some View {
        Button(action: { NotificationCenter.default.post(name: .tearOff(key), object: nil) }) {
            Image(systemName: "rectangle.expand.diagonal").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.current.textSecondary)
        .help("撕出为独立窗口（也可下拉顶部）")
    }
}

// MARK: - 窗口控制器侧的监听公共件

/// 各 WindowController 复用: 注册一次撕出监听, 收到就关 popover 开窗口
final class TearOffObserver {
    private var token: Any?
    /// - onTear: 通常是 { closePopover(); show() }
    func install(key: String, onTear: @escaping () -> Void) {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: .tearOff(key), object: nil, queue: .main) { _ in onTear() }
    }
    deinit {
        if let t = token { NotificationCenter.default.removeObserver(t) }
    }
}
