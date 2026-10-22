import SwiftUI
import Cocoa

// 本文件从 LogSearch.swift 拆出: JSON 弹窗查看器 + 通用浮动面板。
// 2026-09-20 日志搜索按 audi logs-hist 重构时, 这些属于"值得保留的既有资产", 原样迁移。

// MARK: - 浮动面板基类(可成为 key 但不抢 main)

final class LogSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - JSON 弹窗查看（语法着色, 格式化铺满, 全量复制）

final class LogJSONViewerWindow: NSObject, NSWindowDelegate {
    static let shared = LogJSONViewerWindow()
    private var window: NSWindow?
    private var keyMonitor: Any?

    /// 原文里点哪个 JSON 块就弹哪个, 不再把所有块一起铺出来。
    func show(block: LogJSONBlock) {
        let rootView = LogJSONViewerView(block: block)
            .environmentObject(ThemeManager.shared)
        if let w = window {
            w.contentViewController = NSHostingController(rootView: rootView)
            w.makeKeyAndOrderFront(nil)
            installMonitors()
            return
        }
        let win = LogSearchPanel(contentViewController: NSHostingController(rootView: rootView))
        win.title = "JSON"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.styleMask = [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        win.isFloatingPanel = true
        win.level = .floating
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        // 窗口透明度: 只在 nativeBlur 主题下透出桌面壁纸, 其它主题保持不透明避免顶栏透视
        let _needsTransparent = ThemeManager.shared.current.nativeBlur
        win.isOpaque = !_needsTransparent
        win.backgroundColor = _needsTransparent ? .clear : .windowBackgroundColor
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = true
        win.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(button)?.isHidden = true
        }
        win.contentMinSize = NSSize(width: 400, height: 280)
        win.setFrame(NSRect(x: 0, y: 0, width: 580, height: 520), display: false)
        if !win.setFrameUsingName("dboard_logjson_frame") {
            centerOnMouseScreen(win)
        }
        _ = win.setFrameAutosaveName("dboard_logjson_frame")
        win.makeKeyAndOrderFront(nil)
        window = win
        installMonitors()
    }

    func windowWillClose(_ notification: Notification) {
        teardownMonitors()
        window = nil
    }

    /// Esc/✕ 关自己, 不依赖 keyWindow 判定(其他浮动面板可能抢 key, 会关错窗口)
    func close() {
        window?.close()
    }

    // ⌘F 切搜索条, Esc 先收搜索条再关窗 —— onExitCommand 在非激活面板里不稳, 用 monitor 兜底
    private func installMonitors() {
        teardownMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = self.window, w.isKeyWindow else { return e }
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, e.keyCode == 3 {  // F
                NotificationCenter.default.post(name: .logJSONToggleFind, object: nil)
                return nil
            }
            if e.keyCode == 53 {  // Esc
                NotificationCenter.default.post(name: .logJSONEscape, object: nil)
                return nil
            }
            return e
        }
    }

    private func teardownMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func centerOnMouseScreen(_ win: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let f = scr?.visibleFrame else { return }
        var fr = win.frame
        fr.origin.x = f.minX + (f.width - fr.width) / 2
        fr.origin.y = f.minY + (f.height - fr.height) / 2
        win.setFrame(fr, display: false)
    }
}

private struct LogJSONViewerView: View {
    let block: LogJSONBlock
    @EnvironmentObject var theme: ThemeManager
    @State private var copied = false
    @State private var valueCopied = false
    @State private var showFind = false
    @State private var findText = ""
    @State private var findIndex = 0
    @State private var findCount = 0
    @FocusState private var findFocus: Bool

    private var cardOp: Double { theme.current.cardFillOpacity }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showFind { findBar }
            Divider().opacity(0.4)
            LogJSONTextView(
                text: block.formatted,
                findText: $findText,
                findIndex: $findIndex,
                findCount: $findCount,
                textColor: NSColor(theme.current.textPrimary),
                accentColor: NSColor(theme.current.accentPrimary)
            )
        }
        .frame(minWidth: 400, minHeight: 280)
        .ignoresSafeArea(.all, edges: .top)
        .background(
            theme.current.cardMaterial
                ? AnyView(Color.clear.background(.regularMaterial))
                : AnyView(theme.current.background)
        )
        .onReceive(NotificationCenter.default.publisher(for: .logJSONToggleFind)) { _ in
            toggleFind()
        }
        .onReceive(NotificationCenter.default.publisher(for: .logJSONEscape)) { _ in
            if showFind { showFind = false; findText = "" } else { LogJSONViewerWindow.shared.close() }
        }
        .onAppear {
            LogJSONViewerState.shared.onValueCopied = {
                valueCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { valueCopied = false }
            }
        }
        .onDisappear {
            LogJSONViewerState.shared.onValueCopied = nil
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("JSON")
                .font(LogTypography.ui(12, weight: .medium))
                .foregroundStyle(theme.current.textTertiary)
            if valueCopied {
                Text("已复制")
                    .font(LogTypography.ui(11, weight: .medium))
                    .foregroundStyle(theme.current.accentPrimary)
                    .transition(.opacity)
            }
            Spacer()
            ViewerIconButton(systemName: "magnifyingglass", help: "搜索 (⌘F)") { toggleFind() }
            Button {
                copyToPasteboard(block.formatted)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    LogJSONViewerWindow.shared.close()
                }
            } label: {
                Text(copied ? "已复制" : "复制")
                    .font(LogTypography.ui(11.5, weight: .medium))
                    .foregroundStyle(copied ? theme.current.accentPrimary : theme.current.textSecondary)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.current.separator.opacity(0.15))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(copied)
            .help("复制后自动关闭")
            ViewerIconButton(systemName: "xmark", help: "关闭 (Esc)", danger: true) {
                LogJSONViewerWindow.shared.close()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(theme.current.cardFill.opacity(cardOp * 0.38))
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            TextField("搜索关键字", text: $findText)
                .textFieldStyle(.plain)
                .font(LogTypography.ui(12))
                .foregroundStyle(theme.current.textPrimary)
                .focused($findFocus)
                .onSubmit { findNext(forward: true) }
                .padding(.horizontal, 8).frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.current.separator.opacity(0.12))
                )
            // 清空已输入的搜索词(保留搜索条)
            if !findText.isEmpty {
                ViewerIconButton(systemName: "xmark.circle.fill", help: "清空关键字") {
                    findText = ""
                }
            }
            if findCount > 0 {
                Text("\(findIndex + 1)/\(findCount)")
                    .font(LogTypography.ui(11))
                    .foregroundStyle(theme.current.textTertiary)
                    .monospacedDigit()
            } else if !findText.isEmpty {
                Text("无")
                    .font(LogTypography.ui(11))
                    .foregroundStyle(theme.current.textMuted)
            }
            ViewerIconButton(systemName: "chevron.up", help: "上一处·循环",
                             disabled: findCount == 0) {
                findNext(forward: false)
            }
            ViewerIconButton(systemName: "chevron.down", help: "下一处 (Enter)·循环",
                             disabled: findCount == 0) {
                findNext(forward: true)
            }
            // 收起搜索条: 不依赖 Esc 的唯一出口
            ViewerIconButton(systemName: "xmark", help: "收起搜索条", danger: true) {
                withAnimation(.easeOut(duration: 0.12)) {
                    showFind = false
                    findText = ""
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(theme.current.cardFill.opacity(cardOp * 0.5))
    }

    private func toggleFind() {
        showFind.toggle()
        if showFind {
            findText = ""
            findCount = 0
            findIndex = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { findFocus = true }
        }
    }

    private func findNext(forward: Bool) {
        NotificationCenter.default.post(name: .logJSONFindNext, object: NSNumber(value: forward))
    }

    private func copyToPasteboard(_ t: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }
}

extension Notification.Name {
    static let logJSONFindNext = Notification.Name("logJSONFindNext")
    static let logJSONToggleFind = Notification.Name("logJSONToggleFind")
    static let logJSONEscape = Notification.Name("logJSONEscape")
}

// MARK: - JSON 正文视图（NSTextView: 语法着色, 可选可复制, ⌘F 查找高亮跳转）

private struct LogJSONTextView: NSViewRepresentable {
    let text: String
    @Binding var findText: String
    @Binding var findIndex: Int
    @Binding var findCount: Int
    let textColor: NSColor
    let accentColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // 工厂创建保证 textSystem/clipView 布局正确
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.importsGraphics = false
        textView.usesInspectorBar = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator
        context.coordinator.attach(textView: textView, scroll: scroll, text: text,
                                   textColor: textColor, accentColor: accentColor,
                                   findText: $findText, findIndex: $findIndex,
                                   findCount: $findCount)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(findText: findText, textColor: textColor,
                                   accentColor: accentColor, bindings:
            (findText: $findText, findIndex: $findIndex, findCount: $findCount))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private weak var textView: NSTextView?
        private weak var scroll: NSScrollView?
        private var text: String = ""
        private var textColor: NSColor = .textColor
        private var accentColor: NSColor = .systemBlue
        private var findTextBinding: Binding<String>?
        private var findIndexBinding: Binding<Int>?
        private var findCountBinding: Binding<Int>?
        private var matches: [NSRange] = []
        private var currentMatch = -1
        private var lastQuery = "\0"

        func attach(textView: NSTextView, scroll: NSScrollView, text: String,
                    textColor: NSColor, accentColor: NSColor,
                    findText: Binding<String>, findIndex: Binding<Int>,
                    findCount: Binding<Int>) {
            self.textView = textView
            self.scroll = scroll
            self.text = text
            self.textColor = textColor
            self.accentColor = accentColor
            self.findTextBinding = findText
            self.findIndexBinding = findIndex
            self.findCountBinding = findCount
            render()
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleFindNext(_:)),
                name: .logJSONFindNext, object: nil)
        }

        func update(findText: String, textColor: NSColor, accentColor: NSColor,
                    bindings: (findText: Binding<String>, findIndex: Binding<Int>,
                               findCount: Binding<Int>)) {
            self.findTextBinding = bindings.findText
            self.findIndexBinding = bindings.findIndex
            self.findCountBinding = bindings.findCount
            let colorChanged = (textColor.description != self.textColor.description
                                 || accentColor.description != self.accentColor.description)
            self.textColor = textColor
            self.accentColor = accentColor
            // 搜索词变化: 重新扫描命中并高亮, 不重渲染正文
            if findText != lastQuery {
                lastQuery = findText
                rescanMatches()
            }
            if colorChanged { render() }
        }

        private var valueRanges: [(text: String, range: NSRange, attachField: String?)] = []
        private static let valueRegex = try! NSRegularExpression(
            pattern: ##""((?:[^"\\]|\\.)*)"\s*:\s*("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)"##)

        private func render() {
            guard let textView else { return }
            let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let attr = NSMutableAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: textColor])
            LogJSONSyntax.colorizeInto(
                attr, key: accentColor, string: NSColor(srgbRed: 0.18, green: 0.45, blue: 0.33, alpha: 1),
                number: NSColor(srgbRed: 0.69, green: 0.35, blue: 0.16, alpha: 1),
                boolean: NSColor(srgbRed: 0.49, green: 0.36, blue: 0.75, alpha: 1),
                null: .systemGray)
            // value 加 .link: 单击即选中整个 value 并复制; linkTextAttributes 给下划线视觉。
            // key 命中 traceId/spanId 的记录 attachField, 支持双击附加为 AND 条件。
            valueRanges.removeAll()
            let ns = attr.mutableString
            let whole = NSRange(location: 0, length: attr.length)
            let attachableKeys = Set(LogSearchViewModel.attachedFilterFields)
            for m in Coordinator.valueRegex.matches(in: ns as String, range: whole) {
                let keyRange = m.range(at: 1)
                let rawRange = m.range(at: 2)
                let key = ns.substring(with: keyRange)
                let raw = ns.substring(with: rawRange)
                let isString = raw.hasPrefix("\"")
                let contentRange = isString
                    ? NSRange(location: rawRange.location + 1, length: rawRange.length - 2)
                    : rawRange
                let text = isString ? String(raw.dropFirst().dropLast()) : raw
                let attachField = attachableKeys.contains(key) ? key : nil
                valueRanges.append((text: text, range: contentRange, attachField: attachField))
                attr.addAttribute(.link,
                                  value: URL(string: "dboard-copy://\(valueRanges.count - 1)")!,
                                  range: contentRange)
                if attachField != nil {
                    attr.addAttributes([
                        .backgroundColor: accentColor.withAlphaComponent(0.12),
                        .toolTip: "点击加入 AND 条件"
                    ], range: contentRange)
                }
            }
            textView.linkTextAttributes = [
                .font: font,
                .foregroundColor: accentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: accentColor.withAlphaComponent(0.4)
            ]
            textView.textStorage?.setAttributedString(attr)
        }

        private func rescanMatches() {
            guard let textView else { return }
            let q = findTextBinding?.wrappedValue ?? ""
            matches.removeAll()
            currentMatch = -1
            guard !q.isEmpty else {
                applyFindHighlight(clear: true)
                findIndexBinding?.wrappedValue = 0
                findCountBinding?.wrappedValue = 0
                return
            }
            let ns = text as NSString
            var range = NSRange(location: 0, length: ns.length)
            while range.length > 0 {
                let r = ns.range(of: q, options: [.caseInsensitive, .diacriticInsensitive],
                                 range: range)
                guard r.location != NSNotFound else { break }
                matches.append(r)
                range = NSRange(location: r.location + r.length,
                                length: ns.length - (r.location + r.length))
            }
            findCountBinding?.wrappedValue = matches.count
            if matches.isEmpty {
                findIndexBinding?.wrappedValue = 0
                applyFindHighlight(clear: true)
                return
            }
            // 从当前选区往下找首个, 没有则从开头
            let cursor = NSMaxRange(textView.selectedRange())
            currentMatch = matches.firstIndex(where: { $0.location >= cursor }) ?? 0
            findIndexBinding?.wrappedValue = currentMatch
            applyFindHighlight()
            scroll(to: matches[currentMatch])
        }

        private func applyFindHighlight(clear: Bool = false) {
            guard let storage = textView?.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.backgroundColor, range: whole)
            if clear { return }
            let dim = NSColor(srgbRed: 1.0, green: 0.88, blue: 0.51, alpha: 0.55)
            let cur = NSColor(srgbRed: 1.0, green: 0.59, blue: 0.0, alpha: 0.9)
            for (i, r) in matches.enumerated() {
                storage.addAttribute(.backgroundColor,
                                      value: i == currentMatch ? cur : dim, range: r)
            }
        }

        private func scroll(to range: NSRange) {
            // 不设选区: 选区在 NSTextView 非 key 状态下会变系统灰白, 盖掉查找高亮。
            // 当前命中靠更深的橙色 background 标记, 滚动到可见即可。
            textView?.scrollRangeToVisible(range)
        }

        @objc func handleFindNext(_ n: Notification) {
            let forward = (n.object as? NSNumber)?.boolValue ?? true
            guard !matches.isEmpty else { return }
            if forward {
                currentMatch = (currentMatch + 1) % matches.count
            } else {
                currentMatch = currentMatch <= 0 ? matches.count - 1 : currentMatch - 1
            }
            findIndexBinding?.wrappedValue = currentMatch
            applyFindHighlight()
            scroll(to: matches[currentMatch])
        }

        // MARK: - 单击 value 复制

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "dboard-copy",
                  let idx = Int(url.host ?? ""), idx < valueRanges.count
            else { return false }
            let value = valueRanges[idx]
            // traceId/spanId 值单击直接附加为 AND 条件, 不再复制到剪贴板。
            if let field = value.attachField {
                LogJSONViewerState.shared.onAttachFilter?(field, value.text)
                return true
            }
            textView.setSelectedRange(value.range)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value.text, forType: .string)
            LogJSONViewerState.shared.onValueCopied?()
            return true
        }
    }
}

// JSON 弹窗图标按钮: 28×28 完整热区 + hover 底色反馈(danger 悬停变红)
// —— 旧版 22×18 的 plain 小图标经常点不中, 交互被吐槽过
private struct ViewerIconButton: View {
    let systemName: String
    let help: String
    var font: CGFloat = 12
    var danger = false
    var disabled = false
    let action: () -> Void
    @EnvironmentObject var theme: ThemeManager
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: font, weight: .semibold))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.5)
                                   : hovering
                    ? (danger ? Color.red : Color.accentColor)
                    : Color.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering && !disabled
                              ? Color.primary.opacity(0.08) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

final class LogJSONViewerState {
    static let shared = LogJSONViewerState()
    var onValueCopied: (() -> Void)?
    /// (field, value) → 把 traceId/spanId 双击命中的值附加到查询里。
    var onAttachFilter: ((String, String) -> Void)?
}

// JSON 语法着色: key → 字符串 → 布尔 → null → 数字 的交替正则一次扫描;
// 字符串整体先被吃掉, 内部数字/关键字不会被误染。
private enum LogJSONSyntax {
    private static let regex = try! NSRegularExpression(
        pattern: ##"("(?:[^"\\]|\\.)*"\s*:)|("(?:[^"\\]|\\.)*")|\b(true|false)\b|\b(null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)"##
    )

    /// 直接对已有 NSMutableAttributedString 上色(就地, 不重建), 避免大文本二次拼接。
    /// 超大文本直接放弃着色, 保证窗口秒开。
    static func colorizeInto(_ attr: NSMutableAttributedString,
                             key: NSColor, string: NSColor, number: NSColor,
                             boolean: NSColor, null: NSColor) {
        guard attr.length <= 200_000 else { return }
        let ns = attr.mutableString
        let whole = NSRange(location: 0, length: attr.length)
        for match in regex.matches(in: ns as String, range: whole) {
            let color: NSColor
            if match.range(at: 1).location != NSNotFound {
                color = key
            } else if match.range(at: 2).location != NSNotFound {
                color = string
            } else if match.range(at: 3).location != NSNotFound {
                color = boolean
            } else if match.range(at: 4).location != NSNotFound {
                color = null
            } else {
                color = number
            }
            attr.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

// MARK: - 全文查看弹窗(huge 行"展开全文"改弹窗, 不再原地变高)
//
// 原地展开会让 List 重新排布该行之后所有行位置, 且 AppKit 对几千字全文的同步排版
// 本身有开销, 两者叠加是"点展开卡"的确切成因。改弹窗后列表行高永远固定为折叠 3 行,
// List 不会因任何行的展开状态发生重排——卡顿从架构上消失，全文里的词钻取/JSON芯片
// (LogMessageTextView, 与行内共用同一套渲染)照常可用。

final class LogFullTextViewerWindow: NSObject, NSWindowDelegate {
    static let shared = LogFullTextViewerWindow()
    private var window: NSWindow?
    private var keyMonitor: Any?

    func show(entry: LogEntry, keywords: [String],
             onDrill: @escaping (String) -> Void,
             onAttachFilter: @escaping (String, String) -> Void) {
        let rootView = LogFullTextViewerView(entry: entry, keywords: keywords,
                                             onDrill: onDrill, onAttachFilter: onAttachFilter)
            .environmentObject(ThemeManager.shared)
        if let w = window {
            w.contentViewController = NSHostingController(rootView: rootView)
            w.makeKeyAndOrderFront(nil)
            installMonitors()
            return
        }
        let win = LogSearchPanel(contentViewController: NSHostingController(rootView: rootView))
        win.title = "日志详情"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.styleMask = [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        win.isFloatingPanel = true
        win.level = .floating
        win.hidesOnDeactivate = false
        win.isReleasedWhenClosed = false
        let needsTransparent = ThemeManager.shared.current.nativeBlur
        win.isOpaque = !needsTransparent
        win.backgroundColor = needsTransparent ? .clear : .windowBackgroundColor
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = true
        win.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(button)?.isHidden = true
        }
        win.contentMinSize = NSSize(width: 460, height: 320)
        win.setFrame(NSRect(x: 0, y: 0, width: 720, height: 560), display: false)
        if !win.setFrameUsingName("dboard_logfulltext_frame") {
            centerOnMouseScreen(win)
        }
        _ = win.setFrameAutosaveName("dboard_logfulltext_frame")
        win.makeKeyAndOrderFront(nil)
        window = win
        installMonitors()
    }

    func windowWillClose(_ notification: Notification) {
        teardownMonitors()
        window = nil
    }

    func close() { window?.close() }

    private func installMonitors() {
        teardownMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = self.window, w.isKeyWindow else { return e }
            if e.keyCode == 53 { self.close(); return nil }   // Esc
            return e
        }
    }

    private func teardownMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func centerOnMouseScreen(_ win: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let f = scr?.visibleFrame else { return }
        var fr = win.frame
        fr.origin.x = f.minX + (f.width - fr.width) / 2
        fr.origin.y = f.minY + (f.height - fr.height) / 2
        win.setFrame(fr, display: false)
    }
}

private struct LogFullTextViewerView: View {
    let entry: LogEntry
    let keywords: [String]
    let onDrill: (String) -> Void
    let onAttachFilter: (String, String) -> Void
    @EnvironmentObject var theme: ThemeManager
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            // 不再套 SwiftUI ScrollView: 那层会按"一次性测量出的内容尺寸"排版内部
            // NSScrollView, 窗口拉大时文本容器宽度留在旧值 → 文字挤在左边、右侧一大片空白。
            // fillsViewport 模式下由 NSTextView 自己跟随视口宽度重排, 窗口多宽就铺多宽。
            LogMessageTextView(
                text: entry.flatText,
                blocks: entry.jsonBlocks,
                keywords: keywords,
                textColor: NSColor(theme.current.textPrimary),
                accentColor: NSColor(theme.current.accentPrimary),
                fillsViewport: true,
                onDrill: { w in
                    onDrill(w)
                    LogFullTextViewerWindow.shared.close()
                },
                onOpenJSON: { block in
                    LogJSONViewerState.shared.onAttachFilter = onAttachFilter
                    LogJSONViewerWindow.shared.show(block: block)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 460, minHeight: 320)
        .ignoresSafeArea(.all, edges: .top)
        .background(
            theme.current.cardMaterial
                ? AnyView(Color.clear.background(.regularMaterial))
                : AnyView(theme.current.background)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(entry.levelLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(entry.levelColor)
            Text(entry.app)
                .font(.callout)
                .foregroundStyle(Color.secondary)
            Text(entry.timestamp)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.secondary)
            Spacer()
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.detail, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Text(copied ? "已复制" : "复制全文")
                    .font(.callout)
                    .foregroundStyle(copied ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            Button {
                LogFullTextViewerWindow.shared.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}
