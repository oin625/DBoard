import SwiftUI
import Cocoa

// MARK: - 结果列表 (全宽表格行: 左元信息列 + 消息全文铺行内可钻取, 悬停出动作)

struct LogResultsListView: View {
    @ObservedObject var vm: LogSearchViewModel
    let toast: (String) -> Void

    var body: some View {
        if vm.rows.isEmpty {
            if vm.loading { searchingView } else { emptyView }
        } else if visibleEntries.isEmpty {
            ContentUnavailableCompat(
                icon: "eye.slash",
                title: "本页 \(vm.rows.count) 条都被本地过滤藏掉了",
                note: "取消「只看 ERROR」(⌘E) 或恢复隐藏的应用"
            )
        } else {
            VStack(spacing: 0) {
                // 表头移出滚动区: pinnedViews + .bar 毛玻璃表头在滚动时每帧重算模糊, 是卡顿主因
                tableHeader
                // List 桥接真正的 NSTableView, 有内建行复用/虚拟化——这是滚动卡顿的
                // 主因: ScrollView+LazyVStack 里每行的 NSScrollView/NSTextView 没有
                // 这层复用, 50 行同屏时滚动开销明显高于原生表格。
                List {
                    ForEach(visibleEntries) { e in
                        LogResultRow(vm: vm, entry: e, toast: toast)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 重查期间旧结果留在原位压暗(不清空列表, 见 ViewModel.perform),
            // 新数据到达再恢复亮度——观感是"刷新", 不是"塌掉重建"
            .opacity(vm.loading ? 0.45 : 1)
            .overlay(alignment: .top) {
                if vm.loading {
                    ProgressView().progressViewStyle(.linear)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: vm.loading)
        }
    }

    /// errOnly/muted 都是本地过滤
    private var visibleEntries: [LogEntry] {
        vm.rows.filter {
            !vm.mutedApps.contains($0.app) && (!vm.errOnly || $0.levelKind == .err)
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Text("时间·级别·应用").frame(width: 88, alignment: .leading)
            Text("消息").frame(maxWidth: .infinity, alignment: .center)
            Text(" ").frame(width: 96)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.primary.opacity(0.045))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private var searchingView: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("查询中…").font(.callout).foregroundStyle(Color.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 空态三件套(DESIGN.md): 图标 + 一句话 + 主操作
    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.6))
            Text("输入关键词或选择应用")
                .font(.callout).foregroundStyle(Color.secondary)
            if !vm.recentHistory.isEmpty {
                Button("重跑上次查询") { vm.applyHistory(vm.recentHistory[0]) }
                    .controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 单行 (元信息列 + 全文直接铺开, 不折叠不截断)

struct LogResultRow: View {
    @ObservedObject var vm: LogSearchViewModel
    let entry: LogEntry
    let toast: (String) -> Void
    @EnvironmentObject var theme: ThemeManager
    @State private var hovering = false

    var body: some View {
        let timeParts = Self.rowTimeParts(entry.timestamp)
        let flat = entry.flatText      // 解析时预计算, body 零字符串分配
        let huge = entry.isHuge
        return HStack(alignment: .top, spacing: 8) {
            // 左侧元信息列: 日期/时刻/级别/应用 四行堆叠, 右侧整幅留给消息全文
            VStack(alignment: .leading, spacing: 2) {
                Text(timeParts.0)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                Text(timeParts.1)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                Text(entry.levelLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(entry.levelColor)
                if entry.app != "unknown", !entry.app.isEmpty {
                    Text(entry.app)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 88, alignment: .leading)
            .padding(.top, 2)
            .contentShape(Rectangle())
            // 双击元信息列 = 弹窗看全文(普通行无需展开, 不响应)
            .onTapGesture(count: 2) {
                if huge { openFullText() }
            }

            // 行内一律纯 SwiftUI Text 渲染(零 AppKit 桥接开销, 这是流畅度的核心取舍):
            // huge 行同样只显示前 3 行纯文本预览, "展开全文"改弹窗——原地展开时 AppKit
            // 要同步排版全文、List 要重排该行之后所有行位置, 两者叠加就是"点展开很卡"
            // 的确切成因; 弹窗后列表行高永远固定, 卡顿从架构上消失。
            // 代价(已与用户确认接受): 鼠标划词直接点的钻取挪进右键菜单/弹窗内点击。
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.plainPreview(huge ? Self.foldedPreview(flat, keywords: vm.activeKeywords) : flat,
                                       keywords: vm.activeKeywords))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(theme.current.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(huge ? 3 : nil)
                    .fixedSize(horizontal: false, vertical: !huge)
                if huge {
                    Button(action: openFullText) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 8, weight: .bold))
                            Text("查看全文 · \(flat.count) 字")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
                .opacity(hovering ? 1 : 0.45)
                .animation(.easeInOut(duration: 0.15), value: hovering)
                .padding(.top, 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("复制整行") { copyText(entry.detail, "消息已复制") }
            if let tr = entry.traceId {
                Button("复制 traceId") { copyText(tr, "traceId 已复制: \(tr.prefix(8))…") }
            }
            // 普通行没有鼠标划词直接点的钻取入口(流畅度换来的取舍), 右键给等价能力
            if !huge {
                let hits = LogWordTokenizer.drillRanges(in: flat, excluded: entry.jsonBlocks.map(\.nsRange))
                    .map(\.value)
                if !hits.isEmpty {
                    Menu("钻取词…") {
                        ForEach(Array(Set(hits)).sorted().prefix(20), id: \.self) { w in
                            Button(w) { vm.drill(w) }
                        }
                    }
                }
                if !entry.jsonBlocks.isEmpty {
                    Menu("查看 JSON…") {
                        ForEach(entry.jsonBlocks) { block in
                            Button("块 · \(block.raw.prefix(30))…") {
                                LogJSONViewerState.shared.onAttachFilter = { [weak vm] f, v in
                                    vm?.attachFilter(field: f, value: v)
                                }
                                LogJSONViewerWindow.shared.show(block: block)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("查看前后 5 分钟") { vm.searchAround(entry) }
            Button("在新窗口查看前后 5 分钟") {
                LogSearchWindowController.openContextWindow(for: entry, from: vm)
            }
            Divider()
            Button("仅看应用 \(entry.app)") { vm.appDrill(entry.app) }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button { copyText(entry.detail, "消息已复制") } label: {
                Text("复制")
                    .padding(4).contentShape(Rectangle())
            }
            if let tr = entry.traceId {
                Button { copyText(tr, "traceId 已复制: \(tr.prefix(8))…") } label: {
                    Text("trace")
                        .padding(4).contentShape(Rectangle())
                }
            }
            Menu {
                Button("查看前后 5 分钟") { vm.searchAround(entry) }
                Button("在新窗口查看前后 5 分钟") {
                    LogSearchWindowController.openContextWindow(for: entry, from: vm)
                }
                Divider()
                Button("仅看应用 \(entry.app)") { vm.appDrill(entry.app) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(5).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.subheadline)
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
        .frame(width: 96, alignment: .trailing)
    }

    private func copyText(_ t: String, _ hint: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        toast(hint)
    }

    /// huge 行"查看全文"改弹窗(不再原地展开变高, 见类型上方长注释)
    private func openFullText() {
        LogFullTextViewerWindow.shared.show(
            entry: entry, keywords: vm.activeKeywords,
            onDrill: { [weak vm] w in vm?.drill(w) },
            onAttachFilter: { [weak vm] f, v in vm?.attachFilter(field: f, value: v) }
        )
    }

    /// huge 行折叠预览: 围绕关键词首次命中位置截一个 400 字窗口, 而不是死板截头部——
    /// 否则命中词落在异常栈/大JSON中段时, 折叠预览永远看不到高亮在哪, 等于白搭。
    /// 用原生 NSString.range(of:) 一次性找最早命中, 比逐词跑正则轻得多, 且只在
    /// huge 行(少数)触发, 不影响普通行。
    static func foldedPreview(_ text: String, keywords: [String]) -> String {
        let cap = 400
        guard text.count > cap else { return text }
        let ns = text as NSString
        var earliest = Int.max
        for kw in keywords where !kw.isEmpty {
            let r = ns.range(of: kw, options: .caseInsensitive)
            if r.location != NSNotFound { earliest = min(earliest, r.location) }
        }
        guard earliest != Int.max, earliest > cap - 80 else {
            // 无命中 或 命中本就在自然头部范围内: 直接截头部, 不用围绕
            let idx = text.index(text.startIndex, offsetBy: min(cap, text.count))
            return String(text[text.startIndex..<idx])
        }
        let start = max(0, earliest - 80)
        let end = min(ns.length, start + cap)
        let prefix = start > 0 ? "…" : ""
        let suffix = end < ns.length ? "…" : ""
        return prefix + ns.substring(with: NSRange(location: start, length: end - start)) + suffix
    }

    static func rowTimeParts(_ t: String) -> (String, String) {
        let s = t.replacingOccurrences(of: "T", with: " ")
        guard s.count >= 19 else { return (s, "") }
        return (String(s.prefix(10)), String(s.suffix(8)))
    }

    /// 普通行的纯 SwiftUI 渲染路径: 只做关键词高亮(AttributedString, 值类型/零 AppKit),
    /// 不做词钻取扫描/JSON 富文本着色——那些留给右键菜单和 huge 行的重组件。
    static func plainPreview(_ text: String, keywords: [String]) -> AttributedString {
        var attr = AttributedString(text)
        for kw in keywords where !kw.isEmpty {
            var searchRange = attr.startIndex..<attr.endIndex
            while let r = attr[searchRange].range(of: kw, options: [.caseInsensitive]) {
                attr[r].backgroundColor = Color.yellow.opacity(0.38)
                guard r.upperBound < attr.endIndex else { break }
                searchRange = r.upperBound..<attr.endIndex
            }
        }
        return attr
    }
}

// MARK: - 底部翻页条

struct LogPagerBar: View {
    @ObservedObject var vm: LogSearchViewModel

    var body: some View {
        HStack(spacing: 6) {
            pageIcon("chevron.left.2", help: "首页",
                     enabled: !vm.loading && vm.page > 1) { vm.runQuery(1) }
            pageText("上一页", enabled: !vm.loading && vm.page > 1) { vm.runQuery(vm.page - 1) }
            Text(vm.total > 0
                 ? "第 \(vm.page) / \(vm.totalPages) 页 (共 \(Self.grouped(vm.total)) 条)"
                 : "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 4)
            pageText("下一页", enabled: !vm.loading && vm.page < vm.totalPages) {
                vm.runQuery(vm.page + 1)
            }
            pageIcon("chevron.right.2", help: "末页",
                     enabled: !vm.loading && vm.page < vm.totalPages) { vm.runQuery(vm.totalPages) }
            Spacer()
            if !vm.mutedApps.isEmpty {
                let n = vm.rows.filter { vm.mutedApps.contains($0.app) }.count
                if n > 0 { Text("暂隐 \(n)").font(.caption).foregroundStyle(Color.secondary) }
            }
            if vm.errOnly {
                let e = vm.rows.filter { $0.levelKind == .err }.count
                Text("ERROR \(e)/\(vm.rows.count)").font(.caption).foregroundStyle(Color.red)
            }
            Text("每页").font(.callout).foregroundStyle(Color.secondary)
            Picker("", selection: $vm.pageSize) {
                ForEach(LogSearchViewModel.allowedPageSizes, id: \.self) { s in
                    Text("\(s)").tag(s)
                }
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }

    private func pageText(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.6))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(enabled ? 0.06 : 0.03)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func pageIcon(_ symbol: String, help: String, enabled: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.6))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(enabled ? 0.06 : 0.03)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
