import SwiftUI

// MARK: - Theme Definition
struct DBoardTheme: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let icon: String

    let background: Color
    let orbA: Color
    let orbB: Color
    let orbC: Color

    let cardFill: Color
    let cardFillOpacity: Double

    let accentPrimary: Color
    let accentSecondary: Color

    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textMuted: Color
    let chrome: Color
    let separator: Color

    // 新增: 皮肤系统(背景图 + 毛玻璃 + 氛围)
    let backgroundImage: String?      // bundle 图片名, nil=纯色
    let backgroundBlur: CGFloat       // 背景图模糊度 0~20
    let cardMaterial: Bool            // true=系统毛玻璃 Material
    let overlayOpacity: Double        // 遮罩层透明度(暗化/亮化)
    let overlayColor: Color           // 遮罩颜色(暗皮肤用黑, 亮皮肤用白)
    let glowEnabled: Bool             // 是否开启 orb 光球
    let nativeBlur: Bool              // true=用 NSVisualEffectView 透出桌面壁纸(原生毛玻璃)

    var accentGradient: LinearGradient {
        LinearGradient(colors: [accentPrimary, accentSecondary], startPoint: .leading, endPoint: .trailing)
    }

    static func == (lhs: DBoardTheme, rhs: DBoardTheme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Presets
extension DBoardTheme {
    // 跟随系统(默认): 全部取 AppKit 语义色, 深浅色自动切换, 强调色跟随系统设置。
    // 对齐 DESIGN.md —— 不写死色值、不用背景图/光球, 层级靠字重与间距。
    static let system = DBoardTheme(
        id: "system", name: "跟随系统", icon: "circle.lefthalf.filled",
        background: Color(nsColor: .windowBackgroundColor),
        orbA: .clear, orbB: .clear, orbC: .clear,
        cardFill: Color(nsColor: .controlBackgroundColor), cardFillOpacity: 1.0,
        accentPrimary: .accentColor, accentSecondary: .accentColor,
        textPrimary: Color(nsColor: .labelColor),
        textSecondary: Color(nsColor: .secondaryLabelColor),
        textTertiary: Color(nsColor: .secondaryLabelColor),
        textMuted: Color(nsColor: .tertiaryLabelColor),
        chrome: Color(nsColor: .tertiaryLabelColor),
        separator: Color(nsColor: .separatorColor),
        backgroundImage: nil, backgroundBlur: 0, cardMaterial: false,
        overlayOpacity: 0, overlayColor: .clear, glowEnabled: false, nativeBlur: false
    )

    static let glass = DBoardTheme(
        id: "glass", name: "毛玻璃", icon: "rectangle.on.rectangle",
        background: Color(nsColor: .windowBackgroundColor),
        orbA: .clear, orbB: .clear, orbC: .clear,
        cardFill: Color(nsColor: .controlBackgroundColor), cardFillOpacity: 0.95,
        accentPrimary: .accentColor, accentSecondary: .accentColor,
        textPrimary: .primary, textSecondary: .secondary, textTertiary: .secondary,
        textMuted: Color(nsColor: .tertiaryLabelColor), chrome: Color(nsColor: .tertiaryLabelColor),
        separator: Color(nsColor: .separatorColor),
        backgroundImage: nil, backgroundBlur: 0, cardMaterial: true,
        overlayOpacity: 0, overlayColor: .clear, glowEnabled: false, nativeBlur: true
    )

    static let minimal = DBoardTheme(
        id: "minimal", name: "极简", icon: "circle.hexagongrid",
        background: Color(nsColor: .windowBackgroundColor),
        orbA: .clear, orbB: .clear, orbC: .clear,
        cardFill: Color(nsColor: .controlBackgroundColor), cardFillOpacity: 1,
        accentPrimary: .accentColor, accentSecondary: .accentColor,
        textPrimary: .primary, textSecondary: .secondary, textTertiary: .secondary,
        textMuted: Color(nsColor: .tertiaryLabelColor), chrome: Color(nsColor: .tertiaryLabelColor),
        separator: Color(nsColor: .separatorColor),
        backgroundImage: nil, backgroundBlur: 0, cardMaterial: false,
        overlayOpacity: 0, overlayColor: .clear, glowEnabled: false, nativeBlur: false
    )

    static let all: [DBoardTheme] = [.system, .glass, .minimal]
}

// MARK: - Theme Manager
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var current: DBoardTheme {
        didSet {
            UserDefaults.standard.set(current.id, forKey: "dboard_theme_id")
            // 通知窗口层: 从毛玻璃主题切到不透明主题时要同步 isOpaque / backgroundColor
            NotificationCenter.default.post(name: .init("DBoardThemeChanged"), object: nil)
        }
    }

    private init() {
        // 默认落到 minimal 紫: 新皮肤上线时旧用户第一次启动会看到, 老用户手动切走后
        // savedID 会覆盖回原选择。
        // 2026-10 UI 改版: 一次性迁移到「跟随系统」, 之后尊重手动选择
        let d = UserDefaults.standard
        if !d.bool(forKey: "dboard_ui_v2") {
            d.set("system", forKey: "dboard_theme_id")
            d.set("system", forKey: "dboard_font_id")
            d.set(true, forKey: "dboard_ui_v2")
        }
        let savedID = d.string(forKey: "dboard_theme_id") ?? "system"
        self.current = DBoardTheme.all.first { $0.id == savedID } ?? .system
    }

    func cycle() {
        guard let idx = DBoardTheme.all.firstIndex(where: { $0.id == current.id }) else { return }
        let next = (idx + 1) % DBoardTheme.all.count
        withAnimation(DBoardUI.spring) { current = DBoardTheme.all[next] }
    }
}
