import SwiftUI
import AppKit

// MARK: - 字体预设
struct DBoardFont: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let fontName: String
    let sizeScale: CGFloat

    static func == (lhs: DBoardFont, rhs: DBoardFont) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Respect the view's size and weight. Technical text keeps its monospaced design.
    func swiftUIFont(_ size: CGFloat, weight: Font.Weight = .regular,
                     design: Font.Design = .default) -> Font {
        if id == "system" || design == .monospaced {
            return .system(size: size, weight: weight, design: design)
        }
        return .custom(fontName, size: size * sizeScale).weight(weight)
    }

    func appKitFont(_ size: CGFloat) -> NSFont {
        if id == "system" { return .systemFont(ofSize: size) }
        return NSFont(name: fontName, size: size * sizeScale) ?? .systemFont(ofSize: size)
    }
}

extension DBoardFont {
    static let muyao = DBoardFont(id: "muyao", name: "沐瑶手写", fontName: "Muyao-Softbrush", sizeScale: 1.0)
    static let yuanti = DBoardFont(id: "yuanti", name: "圆体", fontName: "Yuanti SC", sizeScale: 0.92)
    static let xingkai = DBoardFont(id: "xingkai", name: "行楷", fontName: "Xingkai SC", sizeScale: 1.05)
    static let baoli = DBoardFont(id: "baoli", name: "报隶", fontName: "Baoli SC", sizeScale: 0.95)
    static let hannotate = DBoardFont(id: "hannotate", name: "手札体", fontName: "Hannotate SC", sizeScale: 1.0)
    static let kaiti = DBoardFont(id: "kaiti", name: "楷体", fontName: "Kaiti SC", sizeScale: 0.95)
    static let pingfang = DBoardFont(id: "pingfang", name: "苹方(标准)", fontName: "PingFang SC", sizeScale: 0.9)
    static let system = DBoardFont(id: "system", name: "系统字体", fontName: "", sizeScale: 1.0)
    static let all: [DBoardFont] = [.system, .pingfang, .yuanti, .hannotate, .kaiti, .muyao, .xingkai, .baoli]
}

final class FontManager: ObservableObject {
    static let shared = FontManager()
    private let defaults: UserDefaults

    @Published var current: DBoardFont {
        didSet { defaults.set(current.id, forKey: "dboard_font_id") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Preserve the existing migration and let tests use isolated preferences.
        if defaults === UserDefaults.standard { _ = ThemeManager.shared }
        else { _ = ThemeManager(defaults: defaults) }
        let savedID = defaults.string(forKey: "dboard_font_id") ?? "system"
        current = DBoardFont.all.first { $0.id == savedID } ?? .system
    }

    /// Older compact panels retain their established system-font sizing.
    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        current.swiftUIFont(current.id == "system" ? max(11, min(size, 15)) : size, weight: weight)
    }
}

/// Optional scope for previews/tests; ordinary views follow the shared preference immediately.
private struct DBoardFontOverrideKey: EnvironmentKey {
    static let defaultValue: DBoardFont? = nil
}
extension EnvironmentValues {
    var dboardFontOverride: DBoardFont? {
        get { self[DBoardFontOverrideKey.self] }
        set { self[DBoardFontOverrideKey.self] = newValue }
    }
}

private struct DBoardFontStyle: ViewModifier {
    @ObservedObject private var manager = FontManager.shared
    @Environment(\.dboardFontOverride) private var override
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font((override ?? manager.current).swiftUIFont(size, weight: weight, design: design))
    }
}

extension View {
    /// Use for interface text instead of a fixed system font.
    func dboardFont(size: CGFloat, weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(DBoardFontStyle(size: size, weight: weight, design: design))
    }
}

/// Styling only: leave text, image attachments, undo and selection intact.
enum DBoardEditorFont {
    static func apply(_ font: NSFont, to editor: NSTextView) {
        guard !editor.hasMarkedText() else { return }
        if editor.font != font { editor.font = font }
        editor.typingAttributes[.font] = font
        guard let storage = editor.textStorage, storage.length > 0 else { return }
        var needsUpdate = false
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if (value as? NSFont) != font { needsUpdate = true; stop.pointee = true }
        }
        if needsUpdate {
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }
    }
}
