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

    var accentGradient: LinearGradient {
        LinearGradient(colors: [accentPrimary, accentSecondary], startPoint: .leading, endPoint: .trailing)
    }

    static func == (lhs: DBoardTheme, rhs: DBoardTheme) -> Bool { lhs.id == rhs.id }
}

// MARK: - Presets
extension DBoardTheme {
    static let colorful = DBoardTheme(
        id: "colorful", name: "炫彩", icon: "paintpalette",
        background: Color(hex: "#f8f9ff"),
        orbA: Color(hex: "#c084fc"), orbB: Color(hex: "#60a5fa"), orbC: Color(hex: "#fb923c"),
        cardFill: .white, cardFillOpacity: 0.7,
        accentPrimary: Color(hex: "#6366f1"), accentSecondary: Color(hex: "#ec4899"),
        textPrimary: Color(hex: "#1e293b"), textSecondary: Color(hex: "#334155"),
        textTertiary: Color(hex: "#64748b"), textMuted: Color(hex: "#94a3b8"),
        chrome: Color(hex: "#cbd5e1"), separator: Color(hex: "#e2e8f0")
    )

    static let ocean = DBoardTheme(
        id: "ocean", name: "海洋", icon: "drop",
        background: Color(hex: "#f0f9ff"),
        orbA: Color(hex: "#06b6d4"), orbB: Color(hex: "#3b82f6"), orbC: Color(hex: "#8b5cf6"),
        cardFill: .white, cardFillOpacity: 0.65,
        accentPrimary: Color(hex: "#0891b2"), accentSecondary: Color(hex: "#2563eb"),
        textPrimary: Color(hex: "#0c4a6e"), textSecondary: Color(hex: "#155e75"),
        textTertiary: Color(hex: "#0e7490"), textMuted: Color(hex: "#67e8f9"),
        chrome: Color(hex: "#a5f3fc"), separator: Color(hex: "#cffafe")
    )

    static let sunset = DBoardTheme(
        id: "sunset", name: "日落", icon: "sun.horizon",
        background: Color(hex: "#fffbf5"),
        orbA: Color(hex: "#f97316"), orbB: Color(hex: "#ef4444"), orbC: Color(hex: "#eab308"),
        cardFill: .white, cardFillOpacity: 0.7,
        accentPrimary: Color(hex: "#ea580c"), accentSecondary: Color(hex: "#dc2626"),
        textPrimary: Color(hex: "#292524"), textSecondary: Color(hex: "#44403c"),
        textTertiary: Color(hex: "#78716c"), textMuted: Color(hex: "#a8a29e"),
        chrome: Color(hex: "#d6d3d1"), separator: Color(hex: "#e7e5e4")
    )

    static let forest = DBoardTheme(
        id: "forest", name: "森林", icon: "leaf",
        background: Color(hex: "#f0fdf4"),
        orbA: Color(hex: "#22c55e"), orbB: Color(hex: "#10b981"), orbC: Color(hex: "#84cc16"),
        cardFill: .white, cardFillOpacity: 0.68,
        accentPrimary: Color(hex: "#16a34a"), accentSecondary: Color(hex: "#059669"),
        textPrimary: Color(hex: "#14532d"), textSecondary: Color(hex: "#166534"),
        textTertiary: Color(hex: "#15803d"), textMuted: Color(hex: "#86efac"),
        chrome: Color(hex: "#bbf7d0"), separator: Color(hex: "#dcfce7")
    )

    // 手绘风主题
    static let kraft = DBoardTheme(
        id: "kraft", name: "牛皮纸", icon: "doc.plaintext",
        background: Color(hex: "#f5e6d3"),
        orbA: Color(hex: "#d4a574"), orbB: Color(hex: "#c4956a"), orbC: Color(hex: "#e8c9a0"),
        cardFill: Color(hex: "#fdf6ee"), cardFillOpacity: 0.85,
        accentPrimary: Color(hex: "#8b5e3c"), accentSecondary: Color(hex: "#c4734f"),
        textPrimary: Color(hex: "#3d2b1f"), textSecondary: Color(hex: "#5c4033"),
        textTertiary: Color(hex: "#8b6f47"), textMuted: Color(hex: "#b89b7a"),
        chrome: Color(hex: "#d4b896"), separator: Color(hex: "#e8d5b7")
    )

    static let chalkboard = DBoardTheme(
        id: "chalkboard", name: "黑板", icon: "pencil.and.ruler",
        background: Color(hex: "#2d4a3e"),
        orbA: Color(hex: "#4a7c6a"), orbB: Color(hex: "#3d6b5a"), orbC: Color(hex: "#5a8f7a"),
        cardFill: Color(hex: "#3a5f50"), cardFillOpacity: 0.85,
        accentPrimary: Color(hex: "#f0e68c"), accentSecondary: Color(hex: "#ffa07a"),
        textPrimary: Color(hex: "#f5f5e8"), textSecondary: Color(hex: "#dcdcc8"),
        textTertiary: Color(hex: "#b8b8a0"), textMuted: Color(hex: "#8a8a72"),
        chrome: Color(hex: "#6b7a5a"), separator: Color(hex: "#4f6b5a")
    )

    static let watercolor = DBoardTheme(
        id: "watercolor", name: "水彩", icon: "drop.halffull",
        background: Color(hex: "#fef7fb"),
        orbA: Color(hex: "#f9a8d4"), orbB: Color(hex: "#c4b5fd"), orbC: Color(hex: "#93c5fd"),
        cardFill: .white, cardFillOpacity: 0.75,
        accentPrimary: Color(hex: "#e879a8"), accentSecondary: Color(hex: "#a78bfa"),
        textPrimary: Color(hex: "#4a2040"), textSecondary: Color(hex: "#6b3a5c"),
        textTertiary: Color(hex: "#9b6b8a"), textMuted: Color(hex: "#d4a5c0"),
        chrome: Color(hex: "#e8c5d8"), separator: Color(hex: "#f5dce8")
    )

    static let all: [DBoardTheme] = [.colorful, .ocean, .sunset, .forest, .kraft, .chalkboard, .watercolor]
}

// MARK: - Theme Manager
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var current: DBoardTheme {
        didSet { UserDefaults.standard.set(current.id, forKey: "dboard_theme_id") }
    }

    private init() {
        let savedID = UserDefaults.standard.string(forKey: "dboard_theme_id") ?? "colorful"
        self.current = DBoardTheme.all.first { $0.id == savedID } ?? .colorful
    }

    func cycle() {
        guard let idx = DBoardTheme.all.firstIndex(where: { $0.id == current.id }) else { return }
        let next = (idx + 1) % DBoardTheme.all.count
        withAnimation(.easeInOut(duration: 0.4)) { current = DBoardTheme.all[next] }
    }
}
