import SwiftUI

// MARK: - 字体预设
struct DBoardFont: Identifiable, Equatable {
    let id: String
    let name: String       // 菜单显示名
    let fontName: String   // 实际字体名（PostScript / family）
    let sizeScale: CGFloat // 字号缩放（不同字体视觉大小不同，做补偿）

    static func == (lhs: DBoardFont, rhs: DBoardFont) -> Bool { lhs.id == rhs.id }
}

extension DBoardFont {
    static let muyao   = DBoardFont(id: "muyao",   name: "沐瑶手写", fontName: "Muyao-Softbrush", sizeScale: 1.0)
    static let yuanti  = DBoardFont(id: "yuanti",  name: "圆体",     fontName: "Yuanti SC",       sizeScale: 0.92)
    static let xingkai = DBoardFont(id: "xingkai", name: "行楷",     fontName: "Xingkai SC",      sizeScale: 1.05)
    static let baoli   = DBoardFont(id: "baoli",   name: "报隶",     fontName: "Baoli SC",        sizeScale: 0.95)
    static let hannotate = DBoardFont(id: "hannotate", name: "手札体", fontName: "Hannotate SC",  sizeScale: 1.0)
    static let kaiti   = DBoardFont(id: "kaiti",   name: "楷体",     fontName: "Kaiti SC",        sizeScale: 0.95)
    static let pingfang = DBoardFont(id: "pingfang", name: "苹方(标准)", fontName: "PingFang SC", sizeScale: 0.9)

    static let all: [DBoardFont] = [.muyao, .yuanti, .xingkai, .baoli, .hannotate, .kaiti, .pingfang]
}

// MARK: - 字体管理器
final class FontManager: ObservableObject {
    static let shared = FontManager()

    @Published var current: DBoardFont {
        didSet { UserDefaults.standard.set(current.id, forKey: "dboard_font_id") }
    }

    private init() {
        let savedID = UserDefaults.standard.string(forKey: "dboard_font_id") ?? "muyao"
        self.current = DBoardFont.all.first { $0.id == savedID } ?? .muyao
    }

    /// 按当前字体返回 Font，传入基准字号
    func font(_ size: CGFloat) -> Font {
        .custom(current.fontName, size: size * current.sizeScale)
    }
}
