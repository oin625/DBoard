import SwiftUI
import AppKit

/// Built-in skins share layout and semantic colors; only the visual palette changes.
struct DBoardTheme: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let icon: String
    let summary: String
    let background: Color
    let orbA: Color
    let orbB: Color
    let orbC: Color
    let cardFill: Color
    let cardFillOpacity: Double
    let accentPrimary: Color
    let accentSecondary: Color
    let controlAccent: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textMuted: Color
    let chrome: Color
    let separator: Color
    let cardMaterial: Bool
    let nativeBlur: Bool
    let meshOpacityLight: Double
    let meshOpacityDark: Double
    let floatingCardOpacityLight: Double
    let floatingCardOpacityDark: Double
    let shadow: Color

    var accentGradient: LinearGradient {
        LinearGradient(colors: [accentPrimary, accentSecondary], startPoint: .leading, endPoint: .trailing)
    }
    var meshColors: [Color] {
        [orbA, orbB, orbA, .clear, orbC, orbB, .clear, .clear, orbA]
    }
    func meshOpacity(for scheme: ColorScheme) -> Double {
        scheme == .dark ? meshOpacityDark : meshOpacityLight
    }
    func floatingCardOpacity(for scheme: ColorScheme) -> Double {
        scheme == .dark ? floatingCardOpacityDark : floatingCardOpacityLight
    }

    static func == (lhs: DBoardTheme, rhs: DBoardTheme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension DBoardTheme {
    /// Keep the existing blue/indigo mesh as the default.
    static let indigo = make(
        id: "indigo", name: "蓝靛", icon: "water.waves", summary: "熟悉的蓝靛渐变",
        background: Color(nsColor: .controlBackgroundColor),
        orbs: [.blue, .indigo, .blue], card: Color(nsColor: .controlBackgroundColor),
        accent: Color(nsColor: .systemBlue), secondary: .indigo,
        mesh: (0.13, 0.22), floatingCard: (0.48, 0.45))

    static let sand = make(
        id: "sand", name: "暖砂", icon: "sun.haze", summary: "温暖、柔和的纸面",
        background: adaptive("sand-background", light: 0xEEE8DE, dark: 0x24211E),
        orbs: [Color(hex: "BD9665"), Color(hex: "D0B095"), Color(hex: "C8A178")],
        card: adaptive("sand-card", light: 0xFFFCF6, dark: 0x35302A),
        accent: adaptive("sand-accent", light: 0x95552F, dark: 0xDEB58D),
        secondary: adaptive("sand-secondary", light: 0x9B7646, dark: 0xD4B383),
        mesh: (0.16, 0.16), floatingCard: (0.58, 0.55),
        buttonAccent: adaptive("sand-button", light: 0x95552F, dark: 0x9B5D36))

    static let graphite = make(
        id: "graphite", name: "石墨", icon: "circle.righthalf.filled", summary: "克制的灰阶与冷色",
        background: adaptive("graphite-background", light: 0xECEEF1, dark: 0x1B1E24),
        orbs: [Color(hex: "8591A6"), Color(hex: "606D86"), Color(hex: "9CA4B5")],
        card: adaptive("graphite-card", light: 0xF9FAFC, dark: 0x2C313B),
        accent: adaptive("graphite-accent", light: 0x485C78, dark: 0xAABBD2),
        secondary: adaptive("graphite-secondary", light: 0x65758D, dark: 0x99ADC8),
        mesh: (0.08, 0.12), floatingCard: (0.65, 0.58),
        buttonAccent: adaptive("graphite-button", light: 0x485C78, dark: 0x526D94))

    static let glass = make(
        id: "glass", name: "透青", icon: "rectangle.on.rectangle", summary: "清透的青色毛玻璃",
        background: adaptive("glass-background", light: 0xECF7F6, dark: 0x172B30),
        orbs: [Color(hex: "53BAAF"), Color(hex: "7AABD7"), Color(hex: "8ACFC4")],
        card: adaptive("glass-card", light: 0xF4FFFC, dark: 0x28454A),
        accent: adaptive("glass-accent", light: 0x087B7F, dark: 0x74D2CD),
        secondary: adaptive("glass-secondary", light: 0x426F9B, dark: 0x94BDE0),
        mesh: (0.13, 0.18), floatingCard: (0.30, 0.30), glass: true,
        buttonAccent: adaptive("glass-button", light: 0x087B7F, dark: 0x087B7F))

    static let all: [DBoardTheme] = [.indigo, .sand, .graphite, .glass]
    static let defaultTheme = indigo

    static func resolve(savedID: String?) -> DBoardTheme {
        switch savedID {
        case "system": return .indigo
        case "minimal": return .graphite
        default: return all.first { $0.id == savedID } ?? defaultTheme
        }
    }

    private static func make(id: String, name: String, icon: String, summary: String,
                             background: Color, orbs: [Color], card: Color, accent: Color,
                             secondary: Color, mesh: (Double, Double),
                             floatingCard: (Double, Double), glass: Bool = false,
                             buttonAccent: Color? = nil) -> DBoardTheme {
        DBoardTheme(id: id, name: name, icon: icon, summary: summary, background: background,
            orbA: orbs[0], orbB: orbs[1], orbC: orbs[2], cardFill: card,
            cardFillOpacity: glass ? 0.30 : 1,
            accentPrimary: accent, accentSecondary: secondary, controlAccent: buttonAccent ?? accent,
            textPrimary: Color(nsColor: .labelColor),
            textSecondary: Color(nsColor: .secondaryLabelColor),
            textTertiary: Color(nsColor: .secondaryLabelColor),
            textMuted: Color(nsColor: .tertiaryLabelColor),
            chrome: Color(nsColor: .tertiaryLabelColor),
            separator: Color(nsColor: .separatorColor),
            cardMaterial: glass, nativeBlur: glass,
            meshOpacityLight: mesh.0, meshOpacityDark: mesh.1,
            floatingCardOpacityLight: floatingCard.0, floatingCardOpacityDark: floatingCard.1,
            shadow: adaptive(id + "-shadow", light: 0x172333, dark: 0x000000))
    }

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        func rgb(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                    green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let lightColor = rgb(light), darkColor = rgb(dark)
        return Color(nsColor: NSColor(name: NSColor.Name("dboard." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

extension Notification.Name {
    static let dboardThemeChanged = Notification.Name("DBoardThemeChanged")
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    private let defaults: UserDefaults
    @Published var current: DBoardTheme {
        didSet {
            guard oldValue.id != current.id else { return }
            defaults.set(current.id, forKey: "dboard_theme_id")
            NotificationCenter.default.post(name: .dboardThemeChanged, object: self)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Retain the legacy font migration without overwriting an explicit font/skin choice.
        if !defaults.bool(forKey: "dboard_ui_v2") {
            if defaults.string(forKey: "dboard_font_id") == nil {
                defaults.set("system", forKey: "dboard_font_id")
            }
            defaults.set(true, forKey: "dboard_ui_v2")
        }
        current = DBoardTheme.resolve(savedID: defaults.string(forKey: "dboard_theme_id"))
        defaults.set(current.id, forKey: "dboard_theme_id")
    }

    func restoreDefault() { current = .defaultTheme }

    func cycle() {
        guard let idx = DBoardTheme.all.firstIndex(where: { $0.id == current.id }) else { return }
        withAnimation(DBoardUI.spring) { current = DBoardTheme.all[(idx + 1) % DBoardTheme.all.count] }
    }
}

/// AppKit keyboard overlays use the same skin accent as SwiftUI controls.
private struct DBoardFocusColorKey: EnvironmentKey {
    static let defaultValue = NSColor.systemBlue
}

extension EnvironmentValues {
    var dboardFocusColor: NSColor {
        get { self[DBoardFocusColorKey.self] }
        set { self[DBoardFocusColorKey.self] = newValue }
    }
}

private struct DBoardThemeAccent: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    func body(content: Content) -> some View {
        content
            .tint(theme.current.accentPrimary)
            .accentColor(theme.current.accentPrimary)
            .environment(\.dboardFocusColor, NSColor(theme.current.accentPrimary))
    }
}

extension View {
    func dboardThemeAccent() -> some View { modifier(DBoardThemeAccent()) }
}
