import SwiftUI

// MARK: - Theme Definition
struct DBoardTheme: Identifiable, Equatable {
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
}

// MARK: - Presets
extension DBoardTheme {
    // 牛皮纸: 手绘暖色(保留, 无背景图)
    static let kraft = DBoardTheme(
        id: "kraft", name: "牛皮纸", icon: "doc.plaintext",
        background: Color(hex: "#f5e6d3"),
        orbA: Color(hex: "#d4a574"), orbB: Color(hex: "#c4956a"), orbC: Color(hex: "#e8c9a0"),
        cardFill: Color(hex: "#fdf6ee"), cardFillOpacity: 0.85,
        accentPrimary: Color(hex: "#8b5e3c"), accentSecondary: Color(hex: "#c4734f"),
        textPrimary: Color(hex: "#3d2b1f"), textSecondary: Color(hex: "#5c4033"),
        textTertiary: Color(hex: "#8b6f47"), textMuted: Color(hex: "#b89b7a"),
        chrome: Color(hex: "#d4b896"), separator: Color(hex: "#e8d5b7"),
        backgroundImage: nil, backgroundBlur: 0, cardMaterial: false,
        overlayOpacity: 0, overlayColor: .clear, glowEnabled: true, nativeBlur: false
    )

    // 赛博朋克: 霓虹城市夜景 + 暗色毛玻璃
    static let cyberpunk = DBoardTheme(
        id: "cyberpunk", name: "赛博朋克", icon: "bolt.horizontal.circle",
        background: Color(hex: "#0a0a1a"),
        orbA: Color(hex: "#ff006e"), orbB: Color(hex: "#00f5d4"), orbC: Color(hex: "#8338ec"),
        cardFill: Color(hex: "#1a1a2e"), cardFillOpacity: 0.65,
        accentPrimary: Color(hex: "#00f5d4"), accentSecondary: Color(hex: "#ff006e"),
        textPrimary: Color(hex: "#eaf2f8"), textSecondary: Color(hex: "#b0c4de"),
        textTertiary: Color(hex: "#6c8ebf"), textMuted: Color(hex: "#3d5a80"),
        chrome: Color(hex: "#2a2a4a"), separator: Color(hex: "#1f1f3a"),
        backgroundImage: "bg-cyberpunk", backgroundBlur: 3, cardMaterial: true,
        overlayOpacity: 0.55, overlayColor: .black, glowEnabled: false, nativeBlur: false
    )

    // QQ经典: 蓝天白云 + 亮色毛玻璃(致敬2005-2010)
    static let qqClassic = DBoardTheme(
        id: "qqClassic", name: "QQ经典", icon: "bubble.left.fill",
        background: Color(hex: "#e8f4fd"),
        orbA: Color(hex: "#1e1e1e"), orbB: Color(hex: "#ffffff"), orbC: Color(hex: "#fe6d2e"),
        cardFill: .white, cardFillOpacity: 0.78,
        accentPrimary: Color(hex: "#12b7f5"), accentSecondary: Color(hex: "#fe6d2e"),
        textPrimary: Color(hex: "#1a2b42"), textSecondary: Color(hex: "#2d4a6f"),
        textTertiary: Color(hex: "#5a7a9a"), textMuted: Color(hex: "#7a8fa6"),
        chrome: Color(hex: "#b8d4e8"), separator: Color(hex: "#d4eaf7"),
        backgroundImage: "bg-qqsky", backgroundBlur: 2, cardMaterial: true,
        overlayOpacity: 0.25, overlayColor: .white, glowEnabled: false, nativeBlur: false
    )

    // 星空: 紫粉星云 + 暗色毛玻璃 + 淡光球
    static let starfield = DBoardTheme(
        id: "starfield", name: "星空", icon: "sparkles",
        background: Color(hex: "#0f0a1e"),
        orbA: Color(hex: "#7c3aed"), orbB: Color(hex: "#ec4899"), orbC: Color(hex: "#6366f1"),
        cardFill: Color(hex: "#1e1040"), cardFillOpacity: 0.6,
        accentPrimary: Color(hex: "#a78bfa"), accentSecondary: Color(hex: "#f472b6"),
        textPrimary: Color(hex: "#f5f3ff"), textSecondary: Color(hex: "#ddd6fe"),
        textTertiary: Color(hex: "#a78bfa"), textMuted: Color(hex: "#6d5aab"),
        chrome: Color(hex: "#2e1f5e"), separator: Color(hex: "#1e1040"),
        backgroundImage: "bg-starfield", backgroundBlur: 1, cardMaterial: true,
        overlayOpacity: 0.5, overlayColor: .black, glowEnabled: true, nativeBlur: false
    )

    // 毛玻璃: 抽象光斑 + 系统 Material + 彩色光球
    static let glass = DBoardTheme(
        id: "glass", name: "毛玻璃", icon: "rectangle.on.rectangle",
        background: .clear,
        orbA: .clear, orbB: .clear, orbC: .clear,
        // 卡片 0.9: 毛玻璃的"透"体现在窗口背景层, 卡片本身必须够厚才能保证文字可读
        cardFill: .white, cardFillOpacity: 0.9,
        accentPrimary: Color(hex: "#0058b0"), accentSecondary: Color(hex: "#0058b0"),
        // vibrancy: 半透明层上的文字禁用浅灰, 全部收紧到高对比区间
        textPrimary: Color(hex: "#0a0a0c"), textSecondary: Color(hex: "#2b2b30"),
        textTertiary: Color(hex: "#4a4a52"), textMuted: Color(hex: "#63636d"),
        chrome: Color(hex: "#b8b8c0"), separator: Color(hex: "#d0d0d8"),
        backgroundImage: nil, backgroundBlur: 0, cardMaterial: true,
        overlayOpacity: 0, overlayColor: .clear, glowEnabled: false, nativeBlur: true
    )

    // 极简紫 (minimal): 参考 Linear/Proxyman 的专业工具审美——
    // 纯灰阶 + 单一紫色强调, 无背景图/无 orb/无毛玻璃, 全靠留白和字重建立层次。
    // 用来对冲另外 5 套皮肤过度装饰、把工具搞得像海报的问题。
    static let minimal = DBoardTheme(
        id: "minimal", name: "极简紫", icon: "circle.hexagongrid",
        background: Color(hex: "#FAFAFB"),
        orbA: .clear, orbB: .clear, orbC: .clear,
        cardFill: .white, cardFillOpacity: 1.0,
        accentPrimary: Color(hex: "#5E6AD7"),      // Linear 紫
        accentSecondary: Color(hex: "#8B93E8"),    // 强调色的浅色变体, 需要渐变时用
        textPrimary: Color(hex: "#0F172A"),        // 近黑, 保证正文对比度
        textSecondary: Color(hex: "#334155"),
        textTertiary: Color(hex: "#64748B"),
        textMuted: Color(hex: "#94A3B8"),
        chrome: Color(hex: "#94A3B8"),      // slate-400: 加深, 保证在浅底上可辨识
        separator: Color(hex: "#CBD5E1"),   // slate-300: 从 E2E8F0 加深, 边框不再发虚
        backgroundImage: nil, backgroundBlur: 0, cardMaterial: false,
        overlayOpacity: 0, overlayColor: .clear, glowEnabled: false, nativeBlur: false
    )

    static let all: [DBoardTheme] = [.minimal, .kraft, .cyberpunk, .qqClassic, .starfield, .glass]
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
        let savedID = UserDefaults.standard.string(forKey: "dboard_theme_id") ?? "minimal"
        self.current = DBoardTheme.all.first { $0.id == savedID } ?? .minimal
    }

    func cycle() {
        guard let idx = DBoardTheme.all.firstIndex(where: { $0.id == current.id }) else { return }
        let next = (idx + 1) % DBoardTheme.all.count
        withAnimation(.easeInOut(duration: 0.4)) { current = DBoardTheme.all[next] }
    }
}
