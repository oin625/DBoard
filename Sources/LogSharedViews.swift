import SwiftUI
import Cocoa

// MARK: - 共享视图组件 (被列表行复用: 全文文本视图 + 空态占位)

/// 空态三件套(图标+一句话+说明)
struct ContentUnavailableCompat: View {
    let icon: String
    let title: String
    var note: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.6))
            Text(title).font(.callout).foregroundStyle(Color.secondary)
            if let note {
                Text(note).font(.caption).foregroundStyle(Color.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - 全文文本视图 (词可钻取 + JSON 芯片 + 关键词高亮, 高度自适应)

struct LogMessageTextView: NSViewRepresentable {
    let text: String
    let blocks: [LogJSONBlock]
    let keywords: [String]
    let textColor: NSColor
    let accentColor: NSColor
    /// 折叠时的最大可视行数(nil=全文); 列表行不传 = 永远全展开
    var visibleLineLimit: Int? = nil
    /// 行 hover 时=true: 所有可钻取词加淡点状下划线, 明确"这些词可钻"
    var hoverAffordance = false
    /// true = 撑满 SwiftUI 给的整块区域并自身负责滚动(详情弹窗)。此时排版完全交给
    /// AppKit(widthTracksTextView), 窗口拉大 → NSTextView 变宽 → 立刻重排充满,
    /// 不会像"按提案宽度测量一次"那样把容器宽度钉死在旧尺寸上、右侧留一大片空白。
    /// false = 高度自适应内容, 供 List 行内折叠排版(行高必须固定, 见 LogResultsListView)
    var fillsViewport = false
    let onDrill: (String) -> Void
    let onOpenJSON: (LogJSONBlock) -> Void
    /// 双击空白/非词区域回调(巨型行=展开/收起; 普通行由调用方决定不响应)
    var onBlankDouble: (() -> Void)? = nil

    private static let lineHeight: CGFloat = 17
    /// 钻取提示下划线色: 深绿(用户指定方向, 浅蓝点线看不清)
    static let drillColor = NSColor(srgbRed: 0.05, green: 0.52, blue: 0.25, alpha: 1.0)

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrill: onDrill, onOpenJSON: onOpenJSON)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 必须保留 NSScrollView 外壳: 直接返回裸 NSTextView 会让 SwiftUI 合成出全黑窗口
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // fillsViewport 模式弹窗自己不出 scroller 位, 覆盖滚动条即可;
        // 列表行内滚动必须禁掉(折叠窗口由 bounds.origin 定位)
        scroll.hasVerticalScroller = fillsViewport
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = fillsViewport ? .automatic : .none
        scroll.scrollerStyle = .overlay

        let textView = HoverWordTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 16))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.importsGraphics = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainerInset = fillsViewport ? NSSize(width: 12, height: 10)
                                                   : NSSize(width: 0, height: 2)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true      // 高度由 sizeThatFits 定, 跟随滚动视图伸缩
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer {
            // 两种模式的关键分叉: 弹窗让容器宽度恒等于文本视图宽度(AppKit 自动重排),
            // 列表行则由 sizeThatFits 逐次显式下发 containerSize
            container.widthTracksTextView = fillsViewport
            container.heightTracksTextView = false
            container.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
            container.lineBreakMode = .byWordWrapping
        }
        // 抑制 NSTextView 默认右键菜单(查找/字体等对只读日志毫无意义)
        textView.menu = NSMenu()
        textView.delegate = context.coordinator
        textView.onBlankDouble = onBlankDouble
        scroll.documentView = textView
        context.coordinator.attach(textView)
        context.coordinator.fillsViewport = fillsViewport
        context.coordinator.render(text: text, blocks: blocks, terms: keywords,
                                   textColor: textColor, accentColor: accentColor,
                                   affordance: hoverAffordance)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onDrill = onDrill
        context.coordinator.onOpenJSON = onOpenJSON
        (scroll.documentView as? HoverWordTextView)?.onBlankDouble = onBlankDouble
        context.coordinator.fillsViewport = fillsViewport
        context.coordinator.render(text: text, blocks: blocks, terms: keywords,
                                   textColor: textColor, accentColor: accentColor,
                                   affordance: hoverAffordance)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? {
        if fillsViewport {
            // 贪心吃满提案尺寸: 排版/滚动全在 AppKit 内部完成, SwiftUI 不再参与测高
            return CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
        }
        let width = max(proposal.width ?? 300, 60)
        let height = context.coordinator.measuredHeight(
            width: width, lineLimit: visibleLineLimit,
            focusRange: context.coordinator.firstHitRange)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onDrill: (String) -> Void
        var onOpenJSON: (LogJSONBlock) -> Void
        /// 弹窗模式: 排版交给 AppKit(widthTracksTextView), 禁止 measuredHeight 插手容器尺寸
        var fillsViewport = false
        private weak var textView: NSTextView?
        private var blocks: [LogJSONBlock] = []
        private struct Snap: Equatable {
            let text: String
            let terms: [String]
            let fg: String
            let accent: String
            let affordance: Bool
        }
        private var snapshot: Snap?
        /// 本次 render 里关键词的首个命中区间(供折叠窗口定位使用); 无命中或无关键词则 nil
        private(set) var firstHitRange: NSRange?
        /// 测量缓存: 同一内容+同一宽度只排版一次; render 换内容时作废
        private struct Measure { var width: CGFloat; var lineLimit: Int?; var focusKey: String; var height: CGFloat }
        private var measure: Measure?

        init(onDrill: @escaping (String) -> Void,
             onOpenJSON: @escaping (LogJSONBlock) -> Void) {
            self.onDrill = onDrill
            self.onOpenJSON = onOpenJSON
        }

        func attach(_ textView: NSTextView) {
            self.textView = textView
            (textView as? HoverWordTextView).map(LogHoverHub.register)
        }

        /// 行高测量: 同宽度/同折叠档位只排版一次(滚动时 SwiftUI 会反复询问尺寸)。
        /// 折叠态额外物理锁死 textView.frame 高度——只改 containerSize 不够,
        /// isVerticallyResizable=true 会让 NSTextView 自己撑到全文高度, NSScrollView
        /// 一旦发现 documentView 比可视区高就继续响应滚轮, 这就是"折叠了但还能拖动看全文"的真凶。
        ///
        /// focusRange 非空时: 折叠窗口对齐到该字符范围所在行, 而不是永远从头 3 行——
        /// 保证巨型行(异常栈/大JSON)在关键词命中位置很靠后时, 折叠预览也能露出命中词。
        func measuredHeight(width: CGFloat, lineLimit: Int?, focusRange: NSRange?) -> CGFloat {
            guard !fillsViewport else { return 0 }   // 弹窗模式不参与排版
            let focusKey = focusRange.map { "\($0.location)-\($0.length)" } ?? "-"
            if let m = measure, m.width == width, m.lineLimit == lineLimit,
               m.focusKey == focusKey { return m.height }
            guard let textView, let container = textView.textContainer,
                  let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage, storage.length > 0 else {
                return 18
            }
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            let full = layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(for: container), in: container)
            let needed = ceil(full.maxY) + 4
            let h: CGFloat
            if let limit = lineLimit {
                h = min(needed, CGFloat(limit) * LogMessageTextView.lineHeight + 6)
                textView.isVerticallyResizable = false   // 关掉自动撑高, 折叠高度才是真的
                textView.frame.size = NSSize(width: width, height: h)
                positionFold(textView: textView, container: container, layoutManager: layoutManager,
                            windowHeight: h, focusRange: focusRange)
            } else {
                h = needed
                textView.isVerticallyResizable = true
                textView.frame.size = NSSize(width: width, height: h)
            }
            container.containerSize = NSSize(width: width, height: h)
            measure = Measure(width: width, lineLimit: lineLimit, focusKey: focusKey, height: h)
            return h
        }

        /// 把折叠窗口的可视区滚动到 focusRange 所在行(命中的关键词/异常栈起点),
        /// 而不总是死板显示开头 3 行——NSTextView 高度已锁定为折叠高度, 这里只挪它的
        /// bounds.origin(相当于给这块"取景框"挪位置), 不影响 frame/不触发重新排版。
        private func positionFold(textView: NSTextView, container: NSTextContainer,
                                  layoutManager: NSLayoutManager, windowHeight: CGFloat,
                                  focusRange: NSRange?) {
            guard let focusRange, focusRange.length > 0,
                  let storage = textView.textStorage,
                  NSMaxRange(focusRange) <= storage.length else {
                textView.bounds.origin = .zero
                return
            }
            let glyphs = layoutManager.glyphRange(forCharacterRange: focusRange, actualCharacterRange: nil)
            let focusRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let full = layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(for: container), in: container)
            // 命中词已经在折叠窗口天然可见范围内: 不挪, 保持从头显示的直觉
            if focusRect.maxY <= windowHeight { textView.bounds.origin = .zero; return }
            // 否则让命中行落在折叠窗口的上 1/3 处, 前后都留出上下文
            var y = focusRect.minY - windowHeight * 0.3
            y = max(0, min(y, max(0, full.maxY - windowHeight)))
            textView.bounds.origin = NSPoint(x: 0, y: y)
        }

        func render(text: String, blocks: [LogJSONBlock], terms: [String],
                    textColor: NSColor, accentColor: NSColor, affordance: Bool) {
            let snap = Snap(text: text, terms: terms, fg: textColor.description,
                            accent: accentColor.description, affordance: affordance)
            guard snap != snapshot, let textView else { return }
            snapshot = snap
            measure = nil
            self.blocks = blocks

            let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let attr = NSMutableAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: textColor])
            let length = attr.length

            // JSON 芯片: 整段原文内联展示, 点击弹格式化窗口。
            // 固定 systemBlue 语义(结构块), 与关键词命中的黄色荧光笔区分开
            for block in blocks where NSMaxRange(block.nsRange) <= length {
                attr.addAttributes([
                    .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.12),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor.systemBlue.withAlphaComponent(0.7),
                    .link: URL(string: "dboard-json://\(block.id.uuidString)")!,
                    .cursor: NSCursor.pointingHand,
                    .toolTip: "JSON · 点击查看格式化内容",
                ], range: block.nsRange)
            }
            // 可钻取词: 手型光标 + tooltip, 不加下划线(满屏下划线噪音)
            let excluded = blocks.map(\.nsRange)
            for hit in LogWordTokenizer.drillRanges(in: text, excluded: excluded)
            where NSMaxRange(hit.range) <= length {
                let encoded = hit.value.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics) ?? hit.value
                guard let url = URL(string: "dboard-attach://word/\(encoded)") else { continue }
                var wordAttrs: [NSAttributedString.Key: Any] = [
                    .link: url,
                    .cursor: NSCursor.pointingHand,
                    .toolTip: "点击钻取: \(hit.value)",
                ]
                if affordance {
                    wordAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    wordAttrs[.underlineColor] = LogMessageTextView.drillColor
                }
                attr.addAttributes(wordAttrs, range: hit.range)
            }
            // 关键词命中高亮: systemYellow 荧光笔底(不划线), 与 JSON 的蓝色结构块
            // 和钻取 hover 的绿色下划线在色相/形态上都拉开距离。
            // 顺带记录全文最早命中位置, 折叠窗口按它定位, 而不是死板显示开头 3 行。
            firstHitRange = nil
            for term in terms where !term.isEmpty {
                var search = NSRange(location: 0, length: length)
                while search.length > 0 {
                    let r = attr.mutableString.range(
                        of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                    guard r.location != NSNotFound else { break }
                    attr.addAttribute(.backgroundColor,
                                      value: NSColor.systemYellow.withAlphaComponent(0.38),
                                      range: r)
                    if firstHitRange == nil || r.location < firstHitRange!.location {
                        firstHitRange = r
                    }
                    let next = r.location + r.length
                    search = NSRange(location: next, length: max(0, length - next))
                }
            }
            textView.linkTextAttributes = [
                .foregroundColor: textColor,
                .cursor: NSCursor.pointingHand,
            ]
            textView.textStorage?.setAttributedString(attr)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            switch url.scheme {
            case "dboard-json":
                guard let id = UUID(uuidString: url.host ?? ""),
                      let block = blocks.first(where: { $0.id == id }) else { return false }
                onOpenJSON(block)
                return true
            case "dboard-attach":
                let raw = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
                let value = raw.removingPercentEncoding ?? raw
                guard !value.isEmpty, url.host == "word" else { return false }
                // 选中文字时不钻取(避免与选词复制冲突)
                if textView.selectedRange().length > 0 { return false }
                onDrill(value)
                return true
            default:
                return false
            }
        }
    }
}

/// hover 到可钻取词上时: 深绿粗实线下划线 + 淡绿底, 精准标记"即将钻取的是这个词"。
/// 事件路径(双保险): ① 本视图 tracking area 的 mouseMoved; ② 窗口 mouseMoved/全局监视器
/// 广播(NSEvent 带全局坐标)→ applyHover(screenPoint:)。nonactivating 面板里
/// app 非激活时只有路径②可靠, 由 LogSearchWindowController 统一转发。
final class HoverWordTextView: NSTextView {
    private var hoveredRange: NSRange?
    private var hoveredOriginalColor: Any?

    /// 双击落在非词/空白处 → 回调外层(巨型行展开/收起快捷手势)
    var onBlankDouble: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2, let storage = textStorage, let window {
            // characterIndex(for:) 要求屏幕坐标系(见 applyHover 同款注释)
            let screenP = window.convertPoint(toScreen: event.locationInWindow)
            let idx = characterIndex(for: screenP)
            var r = NSRange(location: 0, length: 0)
            let link = idx < storage.length
                ? storage.attribute(.link, at: idx, effectiveRange: &r) : nil
            if link == nil { onBlankDouble?() }
        }
        super.mouseUp(with: event)
    }

    /// 覆盖层高亮条: 属性重绘在 SwiftUI 缓存下不可靠, 改用真实子视图画线(必显示)
    private lazy var hoverBar: NSView = {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = LogMessageTextView.drillColor.cgColor
        v.layer?.cornerRadius = 1.2
        v.isHidden = true
        return v
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 浮动面板默认不收 mouseMoved, 不打开这个 tracking 回调会哑
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        // 注意: 配 .inVisibleRect 时 rect 必须给 bounds(与可见区求交), 给 .zero 会缩成空区域
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        applyHover(screenPoint: NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    /// screen 坐标 → 本视图命中词高亮; 返回 true 表示鼠标落在本视图内(由本视图处理)
    ///
    /// 坐标系陷阱: characterIndex(for:) 是 NSTextInputClient 协议方法, 文档写明
    /// 参数须是"屏幕坐标"(非 flipped); 传视图局部坐标会查到错误字符, 表现为"从不命中"。
    @discardableResult
    func applyHover(screenPoint: NSPoint) -> Bool {
        guard let window, let storage = textStorage else { return false }
        let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard bounds.contains(local) else { return false }
        let idx = characterIndex(for: screenPoint)   // 必须传屏幕坐标, 不是 local
        guard idx < storage.length else { clearHover(); return true }
        var effective = NSRange(location: 0, length: 0)
        let link = storage.attribute(.link, at: idx, effectiveRange: &effective)
        if (link as? URL)?.scheme == "dboard-attach" {
            if hoveredRange == effective {   // 同一个词: 只需跟着滚动重摆高亮条
                placeHoverBar(for: effective)
                return true
            }
            clearHover()
            hoveredRange = effective
            hoveredOriginalColor = storage.attribute(.foregroundColor,
                                                     at: effective.location, effectiveRange: nil)
            storage.beginEditing()
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.thick.rawValue,
                .underlineColor: LogMessageTextView.drillColor,
                .foregroundColor: LogMessageTextView.drillColor,
            ], range: effective)
            storage.endEditing()
            displayIfNeeded()
            placeHoverBar(for: effective)
        } else {
            clearHover()
        }
        return true
    }

    /// 把绿色高亮条摆到命中词的正下方(视图坐标系)
    private func placeHoverBar(for charRange: NSRange) {
        guard let lm = layoutManager, let cont = textContainer else { return }
        if hoverBar.superview !== self {
            addSubview(hoverBar, positioned: .above, relativeTo: nil)
        }
        let glyphs = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: cont)
        let origin = textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        hoverBar.frame = NSRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 2.4)
        hoverBar.isHidden = false
    }

    func clearHover() {
        hoverBar.isHidden = true
        guard let r = hoveredRange,
              let storage = textStorage,
              r.location + r.length <= storage.length else { hoveredRange = nil; return }
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: r)
        storage.removeAttribute(.underlineColor, range: r)
        if let original = hoveredOriginalColor {
            storage.addAttribute(.foregroundColor, value: original, range: r)
        }
        storage.endEditing()
        displayIfNeeded()
        hoveredRange = nil
        hoveredOriginalColor = nil
    }
}

/// 钻取 hover 广播枢纽: nonactivating 面板在 app 非激活时收不到 mouseMoved/tracking 事件,
/// 由 LogSearchWindowController 的全局 mouseMoved 监视器把鼠标全局位置广播给
/// 所有在册文本视图, 谁包含鼠标谁负责高亮/清除。
enum LogHoverHub {
    private struct Weak { weak var view: HoverWordTextView? }
    private static var views: [Weak] = []

    static func register(_ view: HoverWordTextView) {
        if views.contains(where: { $0.view === view }) { return }
        views.append(Weak(view: view))
        if views.count > 80 { views.removeAll { $0.view == nil } }
    }

    static var liveCount: Int { views.filter { $0.view != nil }.count }

    static var lastBroadcast = Date.distantPast

    private static var lastPoint: NSPoint?
    private static var lastConsumed = false

    @discardableResult
    static func broadcast(screenPoint: NSPoint) -> Bool {
        // 鼠标没动: 直接跳过整轮遍历(轮询 120ms, 静止时零开销)
        if screenPoint == lastPoint { return lastConsumed }
        lastPoint = screenPoint
        lastBroadcast = Date()
        var alive: [HoverWordTextView] = []
        alive.reserveCapacity(views.count)
        for w in views { if let v = w.view { alive.append(v) } }
        views = alive.map { Weak(view: $0) }
        var consumed = false
        for v in alive where v.applyHover(screenPoint: screenPoint) {
            consumed = true
        }
        if !consumed {   // 鼠标不在任何文本上: 清掉所有残留高亮
            alive.forEach { $0.clearHover() }
        }
        lastConsumed = consumed
        return consumed
    }
}
