import SwiftUI
import Cocoa

/// 原生毛玻璃: NSVisualEffectView 透出桌面壁纸
struct NativeBlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

// MARK: - 通用皮肤背景(背景图 + 遮罩 + 毛玻璃 + orb 光球)
struct ThemeBackground: View {
    @EnvironmentObject var theme: ThemeManager
    var body: some View {
        if theme.current.nativeBlur {
            // 原生毛玻璃: 直接透出桌面壁纸, 不加任何自己的颜色
            NativeBlurView()
                .ignoresSafeArea()
        } else {
            // 用 Color 铺底(保证自身不撑大布局), 所有装饰层用 overlay 叠加
            theme.current.background
                .overlay(backgroundImageLayer)
                .overlay(overlayLayer)
                .overlay(orbLayer)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var backgroundImageLayer: some View {
        if let imgName = theme.current.backgroundImage,
           let nsImg = Self.loadImage(imgName) {
            GeometryReader { geo in
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: theme.current.backgroundBlur)
            }
        }
    }

    @ViewBuilder
    private var overlayLayer: some View {
        if theme.current.overlayOpacity > 0 {
            theme.current.overlayColor
                .opacity(theme.current.overlayOpacity)
        }
    }

    @ViewBuilder
    private var orbLayer: some View {
        if theme.current.glowEnabled {
            GeometryReader { g in
                Circle()
                    .fill(theme.current.orbA.opacity(0.25))
                    .frame(width: g.size.width * 0.6)
                    .blur(radius: 60)
                    .offset(x: -g.size.width * 0.2, y: -g.size.height * 0.1)
                Circle()
                    .fill(theme.current.orbB.opacity(0.2))
                    .frame(width: g.size.width * 0.5)
                    .blur(radius: 50)
                    .offset(x: g.size.width * 0.3, y: g.size.height * 0.4)
                Circle()
                    .fill(theme.current.orbC.opacity(0.15))
                    .frame(width: g.size.width * 0.4)
                    .blur(radius: 40)
                    .offset(x: g.size.width * 0.1, y: g.size.height * 0.7)
            }
            .allowsHitTesting(false)
        }
    }

    /// 从 App bundle Resources/ 加载图片
    private static func loadImage(_ name: String) -> NSImage? {
        // 先试 bundle named
        if let img = NSImage(named: name) { return img }
        // 再试 bundle path (Resources/ 目录)
        let bundle = Bundle.main
        for ext in ["png", "jpg", "jpeg"] {
            if let path = bundle.path(forResource: name, ofType: ext) {
                return NSImage(contentsOfFile: path)
            }
        }
        // 最后试绝对路径(开发时)
        let devPath = bundle.bundlePath + "/Contents/Resources/" + name
        for ext in ["", ".png", ".jpg"] {
            let p = devPath + ext
            if let img = NSImage(contentsOfFile: p) { return img }
        }
        return nil
    }
}

/// 卡片背景修饰器: 根据主题决定用纯色还是毛玻璃
struct ThemeCardBackground: ViewModifier {
    @EnvironmentObject var theme: ThemeManager
    func body(content: Content) -> some View {
        if theme.current.cardMaterial {
            content
                .background(.ultraThinMaterial)
                .background(theme.current.cardFill.opacity(0.25))
        } else {
            content
                .background(theme.current.cardFill.opacity(theme.current.cardFillOpacity))
        }
    }
}

extension View {
    func themeCardBackground() -> some View {
        self.modifier(ThemeCardBackground())
    }
}

// MARK: - Color 扩展
extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b)
    }
}

// MARK: - 毛玻璃背景
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - ViewModel
final class DBoardViewModel: ObservableObject {
    @Published var items: [DItem] = []
    @Published var todaySec: TodoSection? = nil
    @Published var prevSecs: [TodoSection] = []
    @Published var syncTime: String? = nil
    /// 昨天（最近一个历史块），兼容旧引用
    var prevSec: TodoSection? { prevSecs.first }
    @Published var viewMode: ViewMode = .priority
    @Published var syncText: String = ""
    @Published var syncKind: SyncKind = .idle
    @Published var expandedIDs: Set<String> = []
    @Published var paletteOpen = false
    @Published var paletteQuery = ""
    @Published var paletteSel = 0
    @Published var selectedID: String? = nil

    enum SyncKind { case idle, pending, syncing, done, fail }

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var lastSelfWrite: Date = .distantPast
    private var syncDebounce: DispatchWorkItem?
    private let syncDelay: TimeInterval = 30

    init() {
        reload()
        startWatching()
    }

    @Published var newTodoText = ""

    var urgentCount: Int { items.filter { $0.isUrgent }.count }
    var inProgressCount: Int { items.filter { $0.status == .inProgress }.count }
    var todayTodos: [TodoItem] { todaySec?.items ?? [] }
    var doneCount: Int { todayTodos.filter { $0.isCompleted }.count }
    var totalCount: Int { todayTodos.count }
    var allDone: Bool { totalCount > 0 && doneCount == totalCount }

    func reload() {
        let r = CacheParser.parse()
        items = r.items
        syncTime = r.syncTime

        // 把历史未完成项顺延显示在今日零碎顶部
        var carriedOver: [TodoItem] = []
        for sec in r.prevSecs {
            for item in sec.items where !item.isCompleted {
                var carried = item
                carried.text = "[\(sec.shortDate)顺延] " + carried.text
                carried.isCarriedOver = true
                carriedOver.append(carried)
            }
        }

        if let today = r.todaySec {
            let merged = carriedOver + today.items
            todaySec = TodoSection(dateLabel: today.dateLabel, items: merged, isToday: true)
        } else if !carriedOver.isEmpty {
            let todayStr: String = {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
            }()
            todaySec = TodoSection(dateLabel: todayStr, items: carriedOver, isToday: true)
        } else {
            todaySec = r.todaySec
        }

        // 保留所有历史块用于展示（不过滤）
        prevSecs = r.prevSecs
        updateSyncDisplay()
    }

    func updateSyncDisplay() {
        if let t = syncTime, let time = t.split(separator: "T").last {
            let parts = time.split(separator: ":")
            if parts.count >= 2 { syncText = "最近同步 \(parts[0]):\(parts[1])"; syncKind = .idle; return }
        }
        syncText = "未同步"; syncKind = .idle
    }

    func toggleExpanded(_ id: String) {
        var s = expandedIDs
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        expandedIDs = s
    }
    func expandAll() { expandedIDs = Set(items.map { $0.id }) }
    func collapseAll() { expandedIDs = [] }
    func setViewMode(_ m: ViewMode) { viewMode = m }
    func markSelfWrite() { lastSelfWrite = Date() }

    func toggleTodo(_ idx: Int) {
        guard let sec = todaySec, idx < sec.items.count else { return }
        let item = sec.items[idx]
        lastSelfWrite = Date()

        if item.isCarriedOver {
            // 顺延项：按原始文本在文件中匹配（去掉"[X月X日顺延] "前缀）
            var originalText = item.text
            if let r = originalText.range(of: "^\\[.*?顺延\\]\\s*", options: .regularExpression) {
                originalText = String(originalText[r.upperBound...])
            }
            _ = FileMutator.toggleTodoByText(originalText)
        } else {
            // 今日项：计算真实 index（排除 carriedOver 项）
            let realIdx = sec.items.prefix(idx).filter { !$0.isCarriedOver }.count
            _ = FileMutator.toggleTodo(index: realIdx)
        }

        var arr = sec.items
        arr[idx].isCompleted.toggle()
        todaySec = TodoSection(dateLabel: sec.dateLabel, items: arr, isToday: sec.isToday)
        scheduleSync()
    }

    func addTodo(_ text: String) {
        guard !text.isEmpty else { return }
        lastSelfWrite = Date()
        _ = FileMutator.addTodo(text: text)
        if var sec = todaySec {
            sec = TodoSection(dateLabel: sec.dateLabel, items: sec.items + [TodoItem(text: text, isCompleted: false, linkedDItem: nil, note: nil)], isToday: sec.isToday)
            todaySec = sec
        } else {
            let todayStr = Self.todayStr()
            todaySec = TodoSection(dateLabel: todayStr, items: [TodoItem(text: text, isCompleted: false, linkedDItem: nil, note: nil)], isToday: true)
        }
        scheduleSync()
    }

    func editTodo(_ idx: Int, newText: String) {
        guard let sec = todaySec, idx < sec.items.count, !newText.isEmpty else { return }
        lastSelfWrite = Date()
        _ = FileMutator.editTodo(index: idx, newText: newText)
        var arr = sec.items
        arr[idx].text = newText
        todaySec = TodoSection(dateLabel: sec.dateLabel, items: arr, isToday: sec.isToday)
        scheduleSync()
    }

    func deleteTodo(_ idx: Int) {
        guard let sec = todaySec, idx < sec.items.count else { return }
        let item = sec.items[idx]
        lastSelfWrite = Date()

        if item.isCarriedOver {
            // 顺延项：按原始文本在历史块中删除（去掉"[X月X日顺延] "前缀）
            var originalText = item.text
            if let r = originalText.range(of: "^\\[.*?顺延\\]\\s*", options: .regularExpression) {
                originalText = String(originalText[r.upperBound...])
            }
            _ = FileMutator.deleteTodoByText(originalText)
        } else {
            // 今日项：计算真实 index（排除 carriedOver 项）
            let realIdx = sec.items.prefix(idx).filter { !$0.isCarriedOver }.count
            _ = FileMutator.deleteTodo(index: realIdx)
        }

        var arr = sec.items
        arr.remove(at: idx)
        todaySec = TodoSection(dateLabel: sec.dateLabel, items: arr, isToday: sec.isToday)
        scheduleSync()
    }

    func addNote(_ idx: Int, note: String) {
        guard let sec = todaySec, idx < sec.items.count else { return }
        lastSelfWrite = Date()
        _ = FileMutator.addNote(index: idx, note: note)
        var arr = sec.items
        arr[idx].note = note.isEmpty ? nil : note
        todaySec = TodoSection(dateLabel: sec.dateLabel, items: arr, isToday: sec.isToday)
        scheduleSync()
    }

    private static func todayStr() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    // MARK: 命令面板
    struct PaletteEntry: Identifiable {
        let id = UUID()
        let label: String
        let sub: String
        let icon: String
        let action: () -> Void
    }
    var paletteEntries: [PaletteEntry] {
        var es: [PaletteEntry] = []
        let q = paletteQuery.lowercased()
        let acts: [(String, String, () -> Void)] = [
            ("切换视图", "command", { self.setViewMode(self.viewMode == .priority ? .project : .priority); self.paletteOpen = false }),
            ("展开全部需求", "arrow.up.left.and.arrow.down.right", { self.expandAll(); self.paletteOpen = false }),
            ("折叠全部需求", "arrow.down.right.and.arrow.up.left", { self.collapseAll(); self.paletteOpen = false }),
            ("同步钉钉", "bolt", { self.doSyncNow(); self.paletteOpen = false }),
            ("刷新", "arrow.clockwise", { self.reload(); self.paletteOpen = false }),
            ("模块使用统计(近14天)", "chart.bar", {
                self.paletteOpen = false
                let names = Dictionary(uniqueKeysWithValues: DBoardModule.all.map { ($0.id, $0.title) })
                let rows = UsageStats.summary().map { "\(names[$0.0] ?? $0.0)：\($0.1) 次" }
                let alert = NSAlert()
                alert.messageText = "模块使用统计（近 14 天）"
                alert.informativeText = rows.isEmpty ? "还没有记录" : rows.joined(separator: "\n")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }),
        ]
        // 一键运维: 写生产的动作仍走 Runner 的二次确认
        for op in OpsAction.all where q.isEmpty || op.title.lowercased().contains(q) || "cookie 抖音 douyin 运维".contains(q) {
            es.append(PaletteEntry(label: op.title, sub: "运维", icon: op.icon, action: {
                self.paletteOpen = false
                DispatchQueue.main.async { OpsRunner.shared.requestRun(op) }
            }))
        }
        for m in DBoardModule.all where q.isEmpty || m.title.lowercased().contains(q) || m.id.contains(q) {
            es.append(PaletteEntry(label: m.title, sub: m.shortcut.isEmpty ? "模块" : m.shortcut, icon: m.icon, action: {
                self.paletteOpen = false
                m.launch()
            }))
        }
        for a in acts {
            if q.isEmpty || a.0.lowercased().contains(q) {
                es.append(PaletteEntry(label: a.0, sub: "动作", icon: a.1, action: a.2))
            }
        }
        for it in items {
            if q.isEmpty || it.displayTitle.lowercased().contains(q) || it.id.lowercased().contains(q) {
                let id = it.id
                es.append(PaletteEntry(label: it.displayTitle, sub: id, icon: "doc.text", action: { self.expandedIDs.insert(id); self.paletteOpen = false }))
            }
        }
        return es
    }
    func paletteMove(_ d: Int) {
        let n = paletteEntries.count
        guard n > 0 else { return }
        paletteSel = (paletteSel + d + n) % n
    }
    func paletteRun() {
        guard paletteEntries.indices.contains(paletteSel) else { return }
        paletteEntries[paletteSel].action()
    }

    // MARK: 键盘选中导航
    func moveSel(_ d: Int) {
        let ids = items.map { $0.id }
        guard !ids.isEmpty else { return }
        let cur = selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        selectedID = ids[(cur + d + ids.count) % ids.count]
    }
    func activateSel() { if let id = selectedID { toggleExpanded(id) } }

    func cycleStatus(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let order: [ItemStatus] = [.pending, .inProgress, .completed, .suspended]
        let cur = order.firstIndex(of: item.status) ?? 0
        let next = order[(cur + 1) % order.count]
        lastSelfWrite = Date()
        _ = FileMutator.setStatus(id: id, newStatusRaw: next.rawValue)
        var arr = items
        if let i = arr.firstIndex(where: { $0.id == id }) { arr[i].status = next }
        items = arr
        scheduleSync()
    }

    func cycleToStatus(_ id: String, target: ItemStatus) {
        lastSelfWrite = Date()
        _ = FileMutator.setStatus(id: id, newStatusRaw: target.rawValue)
        var arr = items
        if let i = arr.firstIndex(where: { $0.id == id }) { arr[i].status = target }
        items = arr
        scheduleSync()
    }

    private func startWatching() {
        let path = CacheFile.path
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        fileMonitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: [.write, .rename, .delete], queue: .main)
        fileMonitor?.setEventHandler { [weak self] in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.lastSelfWrite) < 0.6 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.reload() }
        }
        fileMonitor?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 { close(fd); self?.fileDescriptor = -1 }
        }
        fileMonitor?.resume()
    }

    func scheduleSync() {
        syncDebounce?.cancel()
        syncText = "⏳ \(Int(syncDelay))s 后同步"; syncKind = .pending
        let work = DispatchWorkItem { [weak self] in self?.doSync() }
        syncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + syncDelay, execute: work)
    }
    func doSyncNow() { syncDebounce?.cancel(); syncDebounce = nil; doSync() }

    private func doSync() {
        syncText = "正在同步钉钉…"; syncKind = .syncing
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = [CacheFile.syncScript]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            var ok = false
            do { try task.run(); task.waitUntilExit(); ok = (task.terminationStatus == 0) } catch { ok = false }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.syncText = ok ? "✅ 已同步钉钉" : "⚠ 同步失败"
                self.syncKind = ok ? .done : .fail
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.reload() }
            }
        }
    }

    deinit {
        fileMonitor?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }
}

// MARK: - 根视图
struct DBoardRootView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @State private var monitor: Any?
    var popoverMode: Bool = false   // popover 模式才挂下拉撕出手势

    var body: some View {
        ZStack {
            // 皮肤背景(背景图 + 遮罩 + orb 光球)
            ThemeBackground()
                .environmentObject(theme)

            VStack(spacing: 0) {
                HeaderView(popoverMode: popoverMode)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        CockpitSection()
                        NewItemRow()
                        NeedsSection()
                        PrevSection()
                        TodaySection()
                    }
                    .padding(.bottom, 12)
                }
                FooterView()
            }
            if vm.paletteOpen {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { vm.paletteOpen = false }
                    CommandPalette().environmentObject(vm).padding(.top, 50)
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 380, idealWidth: 420, maxWidth: .infinity, minHeight: 480, idealHeight: 640, maxHeight: .infinity)
        .focusEffectDisabled()
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak vm] event in
                return Self.handleKey(event, vm: vm)
            }
        }
        .onDisappear {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }
    }

    static func handleKey(_ event: NSEvent, vm: DBoardViewModel?) -> NSEvent? {
        guard let vm = vm else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let c = (event.charactersIgnoringModifiers ?? "").lowercased()
        // ⌘K
        if mods.contains(.command) && c == "k" { vm.paletteOpen.toggle(); vm.paletteQuery = ""; vm.paletteSel = 0; return nil }
        if vm.paletteOpen {
            switch event.keyCode {
            case 53: vm.paletteOpen = false; return nil      // esc
            case 125: vm.paletteMove(1); return nil          // ↓
            case 126: vm.paletteMove(-1); return nil         // ↑
            case 36: vm.paletteRun(); return nil             // enter
            default: return event
            }
        }
        let typing = event.window?.firstResponder is NSTextView
        if typing { return event }
        if c == "j" { vm.moveSel(1); return nil }
        if c == "k" { vm.moveSel(-1); return nil }
        if event.keyCode == 36 { vm.activateSel(); return nil }   // enter
        if event.keyCode == 53 {  // esc
            if vm.selectedID != nil {
                vm.selectedID = nil
            } else {
                // 没有选中项，关闭窗口
                event.window?.orderOut(nil)
            }
            return nil
        }
        return event
    }
}

// MARK: - 命令面板
struct CommandPalette: View {
    @EnvironmentObject var vm: DBoardViewModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索需求或动作…", text: $vm.paletteQuery)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
            }
            .padding(13)
            .overlay(Divider(), alignment: .bottom)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(vm.paletteEntries.enumerated()), id: \.element.id) { i, e in
                        PaletteRow(entry: e, selected: i == vm.paletteSel)
                    }
                }
                .padding(5)
            }
        }
        .frame(width: 320, height: 360)
        .focusEffectDisabled()
        .background(RoundedRectangle(cornerRadius: 13).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        .onAppear { focused = true }
        .onChange(of: vm.paletteQuery) { _ in vm.paletteSel = 0 }
    }
}

struct PaletteRow: View {
    @EnvironmentObject var fm: FontManager
    let entry: DBoardViewModel.PaletteEntry
    let selected: Bool
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: entry.icon).font(fm.font(14))
                .foregroundStyle(selected ? Color.blue : Color.gray.opacity(0.6)).frame(width: 14)
            Text(entry.label).font(fm.font(16))
                .foregroundStyle(selected ? Color.blue : Color.primary)
            Spacer()
            Text(entry.sub).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.gray.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? Color.blue.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { entry.action() }
    }
}

// MARK: - Header
struct HeaderView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var showHandle = false
    var popoverMode: Bool = false

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"; return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("D板").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.current.textPrimary)
                Text(Self.dateFmt.string(from: Date())).font(.system(size: 11))
                    .foregroundStyle(theme.current.textTertiary)
            }
            .help("下拉或双击可脱出为独立窗口")
            Spacer()
            if vm.urgentCount > 0 {
                Text("\(vm.urgentCount) 紧急").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .contentTransition(.numericText())
            }
            if vm.inProgressCount > 0 {
                Text("\(vm.inProgressCount) 进行中").font(.system(size: 11))
                    .foregroundStyle(theme.current.textTertiary)
                    .contentTransition(.numericText())
            }
            HeaderIconButton(icon: "magnifyingglass", help: "命令面板 ⌘K") {
                vm.paletteQuery = ""; vm.paletteSel = 0; vm.paletteOpen = true
            }
            // 入口收敛: 所有模块收进一个菜单, 不再在头部平铺一排图标
            Menu {
                ForEach(DBoardModule.all) { m in
                    Button { m.launch() } label: {
                        Label(m.shortcut.isEmpty ? m.title : "\(m.title)  \(m.shortcut)", systemImage: m.icon)
                    }
                }
            } label: {
                Image(systemName: "square.grid.2x2").font(.system(size: 13))
                    .foregroundStyle(theme.current.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("全部模块")
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
        .contentShape(Rectangle())
        .onHover { showHandle = $0 }
        // 下拉撕出(与 Skills/BizMap/SysMon 同一套手感); 双击脱出作为旧入口保留
        .tearOffHandle("DBoardPanel", enabled: popoverMode)
        .onTapGesture(count: 2) {
            // 双击标题区 -> 脱出为独立窗口
            if let app = NSApp.delegate as? AppDelegate {
                app.detachPanel()
            }
        }
    }
}

// 头部图标按钮: hover 高亮放大 + 按压回弹
struct HeaderIconButton: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(hovered ? theme.current.textPrimary : theme.current.textTertiary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.current.textPrimary.opacity(hovered ? 0.07 : 0)))
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.9, hoverScale: 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
        .help(help)
    }
}

// MARK: - 需求分组
struct NeedsSection: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager

    var groups: [(String, Color, [DItem])] {
        if vm.viewMode == .project {
            var order: [String] = []
            var g: [String: [DItem]] = [:]
            for it in vm.items {
                if g[it.project] == nil { order.append(it.project) }
                g[it.project, default: []].append(it)
            }
            return order.map { ($0, Color(hex: projColor($0)), g[$0]!) }
        } else {
            return ItemPriority.allCases.compactMap { p in
                let arr = vm.items.filter { $0.priority == p }
                return arr.isEmpty ? nil : (p.title, p.color, arr)
            }
        }
    }

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.element.0) { gi, grp in
            HStack(spacing: 6) {
                Circle().fill(grp.1).frame(width: 6, height: 6)
                Text(grp.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.current.textSecondary)
                Spacer()
                Text("\(grp.2.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.current.textMuted)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            VStack(spacing: 6) {
                ForEach(Array(grp.2.enumerated()), id: \.element.id) { i, item in
                    ItemCardView(item: item, appearDelay: Double(i) * 0.04 + Double(gi) * 0.02)
                }
            }
            .padding(.horizontal, 4)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: vm.items.count)
    }
}

// MARK: - 需求卡片
struct ItemCardView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let item: DItem
    var appearDelay: Double = 0
    @State private var hovered = false
    @State private var appeared = false
    var expanded: Bool { vm.expandedIDs.contains(item.id) }
    var pcolor: Color { item.priority.color }
    var projC: Color { Color(hex: projColor(item.project)) }
    var showDesc: Bool { !item.title.isEmpty && item.title != "（待补充）" && item.title != item.displayTitle }
    var hasBranch: Bool { (item.branch?.isEmpty == false && item.branch != "待定") }
    var hasCycle: Bool { item.startDate != nil }
    var hasProgress: Bool { !item.milestones.isEmpty }
    var hasDetail: Bool { showDesc || hasBranch || hasCycle || hasProgress }

    @State private var editing = false
    @State private var progressBuf = ""

    var body: some View {
        cardContent
        .contextMenu { contextMenuContent }
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovered)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: expanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: editing)
        .onHover { hovered = $0 }
        .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(appearDelay)) { appeared = true }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                DItemEditForm(draft: DItemDraft(from: item), onSave: { d in
                    vm.saveItem(d, original: item); editing = false
                }, onCancel: { editing = false })
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    cardHeader
                    cardMeta
                }
                .contentShape(Rectangle())
                .onTapGesture { vm.toggleExpanded(item.id) }
                if expanded {
                    cardDetails
                    progressInput
                    actionBar
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .cardStyle(theme.current)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .fill(!editing && (vm.selectedID == item.id || hovered) ? theme.current.textPrimary.opacity(0.035) : Color.clear)
                .allowsHitTesting(false)
        )
        .padding(.horizontal, 16)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var progressInput: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle").font(.system(size: 12)).foregroundStyle(theme.current.textMuted)
            TextField("追加今日进度，回车保存", text: $progressBuf)
                .textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit {
                    vm.appendProgress(item.id, progressBuf); progressBuf = ""
                }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.current.textPrimary.opacity(0.05)))
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            actionBtn("编辑", "pencil") { editing = true }
            Menu {
                ForEach(ItemPriority.allCases, id: \.self) { p in
                    Button { if p != item.priority { vm.setPriority(item.id, p) } } label: {
                        Label(p.title, systemImage: p == item.priority ? "checkmark" : "circle")
                    }
                }
            } label: {
                Label("优先级", systemImage: "flag").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(theme.current.textTertiary)
            actionBtn("完成并归档", "archivebox") { vm.archiveItem(item) }
            Spacer()
            actionBtn("删除", "trash", tint: .red) { vm.deleteItem(item) }
        }
        .padding(.top, 2)
    }

    private func actionBtn(_ t: String, _ icon: String, tint: Color? = nil, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Label(t, systemImage: icon).font(.system(size: 12))
                .foregroundStyle(tint ?? theme.current.textTertiary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardHeader: some View {
        HStack(spacing: 8) {
            Circle().fill(pcolor).frame(width: 6, height: 6)
            Text(item.displayTitle)
                .font(fm.font(15, weight: .medium))
                .lineLimit(expanded ? nil : 2)
                .foregroundStyle(theme.current.textPrimary)
            Spacer()
            if let dl = item.daysRemaining {
                if item.isUrgent {
                    Text("\(dl)天")
                        .font(fm.font(13))
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.1)))
                } else {
                    Text("\(dl)天").font(fm.font(13)).foregroundStyle(theme.current.textTertiary)
                }
            }
            Image(systemName: "chevron.right").font(fm.font(13))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(theme.current.chrome)
        }
    }

    @ViewBuilder
    private var cardMeta: some View {
        HStack(spacing: 6) {
            Text(item.id).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.current.textTertiary)
            Text("·").font(fm.font(13)).foregroundStyle(theme.current.separator)
            Text(item.project).font(fm.font(13)).foregroundStyle(theme.current.textTertiary)
            Text("·").font(fm.font(13)).foregroundStyle(theme.current.separator)
            StatusPill(status: item.status) { vm.cycleStatus(item.id) }
            Spacer()
        }
    }

    @ViewBuilder
    private var cardDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            if hasDetail {
                if showDesc {
                    HStack(alignment: .top, spacing: 6) {
                        Text("描述").font(fm.font(14)).foregroundStyle(theme.current.textMuted).frame(width: 30, alignment: .leading)
                        Text(item.title).font(fm.font(14)).foregroundStyle(theme.current.textSecondary)
                    }
                }
                if hasBranch, let b = item.branch {
                    HStack(spacing: 6) {
                        Text("分支").font(fm.font(14)).foregroundStyle(theme.current.textMuted).frame(width: 30, alignment: .leading)
                        Text(b).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.current.accentPrimary)
                    }
                }
                if let sd = item.startDate {
                    HStack(spacing: 6) {
                        Text("周期").font(fm.font(14)).foregroundStyle(theme.current.textMuted).frame(width: 30, alignment: .leading)
                        Text("\(sd)\(item.deadline.map { " → \($0)" } ?? "")").font(fm.font(14)).foregroundStyle(theme.current.textSecondary)
                    }
                }
                if hasProgress {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(item.milestones.enumerated()), id: \.offset) { _, ms in
                            HStack(spacing: 5) {
                                Circle().fill(theme.current.accentPrimary).frame(width: 5, height: 5)
                                Text(ms.date).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.current.textMuted)
                                Text(ms.content).font(fm.font(14)).foregroundStyle(theme.current.textSecondary)
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
            } else {
                Text("暂无详情，点「编辑」补充").font(fm.font(14)).foregroundStyle(theme.current.textMuted)
            }
        }
        .padding(.top, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button { vm.toggleExpanded(item.id) } label: {
            Label(expanded ? "折叠" : "展开详情", systemImage: expanded ? "chevron.up" : "chevron.down")
        }
        Button { if !expanded { vm.toggleExpanded(item.id) }; editing = true } label: {
            Label("编辑", systemImage: "pencil")
        }
        Divider()
        if let b = item.branch, !b.isEmpty, b != "待定" {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(b, forType: .string)
            } label: {
                Label("复制分支名", systemImage: "doc.on.doc")
            }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.id, forType: .string)
        } label: {
            Label("复制编号 \(item.id)", systemImage: "number")
        }
        Divider()
        Menu("切换状态") {
            ForEach([ItemStatus.pending, .inProgress, .completed, .suspended], id: \.rawValue) { s in
                Button {
                    if item.status != s { vm.cycleToStatus(item.id, target: s) }
                } label: {
                    HStack {
                        Text(s.label)
                        if item.status == s { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        Menu("调整优先级") {
            ForEach(ItemPriority.allCases, id: \.self) { p in
                Button { if p != item.priority { vm.setPriority(item.id, p) } } label: {
                    HStack { Text(p.title); if item.priority == p { Image(systemName: "checkmark") } }
                }
            }
        }
        Divider()
        Button { vm.archiveItem(item) } label: { Label("完成并归档", systemImage: "archivebox") }
        Button(role: .destructive) { vm.deleteItem(item) } label: { Label("删除", systemImage: "trash") }
    }
}

// MARK: - 状态药丸
struct StatusPill: View {
    @EnvironmentObject var fm: FontManager
    let status: ItemStatus
    let onTap: () -> Void
    @State private var pop = false
    @State private var hovered = false
    var fg: Color {
        switch status {
        case .pending: return Color.secondary
        case .inProgress: return Color.blue
        case .completed: return Color.green
        case .suspended: return Color.orange
        }
    }
    var body: some View {
        Text(status.label).font(fm.font(13))
            .foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [fg.opacity(0.15), fg.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .scaleEffect(pop ? 1.15 : (hovered ? 1.08 : 1))
            .id(status)
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .onTapGesture {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { pop = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pop = false }
                }
                onTap()
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: hovered)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: status)
    }
}

// MARK: - 昨日归档
struct PrevSection: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var expanded = false
    @State private var showHistory = false
    var body: some View {
        if let prev = vm.prevSec {
            // 昨天：保持原有逻辑
            if prev.allCompleted {
                Button { expanded.toggle() } label: {
                    HStack {
                        Text("\(prev.shortDate) 已完成").font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                        Spacer()
                        Text("\(prev.doneCount)/\(prev.totalCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.current.chrome)
                        Image(systemName: "chevron.right").font(.system(size: 9)).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(theme.current.chrome)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                if expanded {
                    ForEach(Array(prev.items.filter { $0.isCompleted }.enumerated()), id: \.offset) { _, td in
                        TodoRow(idx: -1, todo: td, readOnly: true)
                    }
                }
            } else {
                let done = prev.items.filter { $0.isCompleted }
                if !done.isEmpty {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text("\(prev.shortDate) 已完成 \(done.count) 项").font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 9)).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(theme.current.chrome)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if expanded {
                        ForEach(Array(done.enumerated()), id: \.offset) { _, td in
                            TodoRow(idx: -1, todo: td, readOnly: true)
                        }
                    }
                }
            }

            // 更早历史下拉框
            if vm.prevSecs.count > 1 {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showHistory.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(fm.font(13)).foregroundStyle(theme.current.chrome)
                        Text("更早历史 · \(vm.prevSecs.count - 1) 天").font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9)).rotationEffect(.degrees(showHistory ? 90 : 0)).foregroundStyle(theme.current.chrome)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                if showHistory {
                    ForEach(Array(vm.prevSecs.dropFirst()), id: \.dateLabel) { sec in
                        HistoryBlockView(sec: sec)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

// MARK: - 历史日期块
struct HistoryBlockView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let sec: TodoSection
    @State private var expanded = false
    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
            HStack {
                Text(sec.shortDate).font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                Spacer()
                Text("\(sec.doneCount) 项已完成").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.current.chrome)
                Image(systemName: "chevron.right").font(.system(size: 9)).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(theme.current.chrome)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        if expanded {
            ForEach(Array(sec.items.filter { $0.isCompleted }.enumerated()), id: \.offset) { _, td in
                TodoRow(idx: -1, todo: td, readOnly: true)
            }
        }
    }
}

// MARK: - 今日零碎
struct TodaySection: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("今日零碎").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.current.textSecondary)
                Spacer()
                Text("\(vm.doneCount)/\(vm.totalCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.current.textMuted)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)

            // 醒目的添加行
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.current.accentPrimary)
                TextField("添加今日零碎…", text: $vm.newTodoText)
                    .font(fm.font(15))
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.current.textPrimary)
                    .onSubmit {
                        let text = vm.newTodoText.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        vm.newTodoText = ""
                        vm.addTodo(text)
                    }
                if !vm.newTodoText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("回车添加").font(fm.font(12)).foregroundStyle(theme.current.textMuted)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.current.textPrimary.opacity(0.05)))
            .padding(.horizontal, 16).padding(.vertical, 4)

            if vm.todayTodos.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(theme.current.textMuted)
                    Text("今天还没有零碎事项，上面一行直接输入").font(.system(size: 12)).foregroundStyle(theme.current.textTertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            }

            ForEach(Array(vm.todayTodos.enumerated()), id: \.offset) { idx, td in
                TodoRow(idx: idx, todo: td, readOnly: false)
                    .id("today-\(idx)")
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: vm.allDone)
    }
}

// MARK: - 零碎行
struct TodoRow: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let idx: Int
    let todo: TodoItem
    let readOnly: Bool
    @State private var pop = false
    @State private var checkBounce = false
    @State private var hovered = false
    @State private var editingText = false
    @State private var editingNote = false
    @State private var textBuf = ""
    @State private var noteBuf = ""
    @FocusState private var textFocused: Bool
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    if !readOnly {
                        vm.toggleTodo(idx)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { checkBounce = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { checkBounce = false }
                        }
                    }
                } label: {
                    ZStack {
                        Circle().stroke(todo.isCompleted ? Color.green : (hovered ? theme.current.accentPrimary : theme.current.textMuted), lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        if todo.isCompleted {
                            Circle().fill(Color.green.opacity(0.3)).frame(width: 18, height: 18)
                                .scaleEffect(pop ? 1.7 : 1).opacity(pop ? 0 : 0.6)
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .contentShape(Circle())
                    .background(todo.isCompleted ? Color.green : .clear, in: Circle())
                    .scaleEffect(todo.isCompleted && pop ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                .disabled(readOnly)
                .onChange(of: todo.isCompleted) { done in
                    if done {
                        pop = false
                        withAnimation(.easeOut(duration: 0.5)) { pop = true }
                    }
                }

                if editingText && !readOnly {
                    TextField(todo.text, text: $textBuf, onCommit: {
                        if !textBuf.isEmpty { vm.editTodo(idx, newText: textBuf) }
                        editingText = false
                    })
                    .font(fm.font(15))
                    .focused($textFocused)
                    .textFieldStyle(.plain)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.4)))
                } else {
                    Text(todo.text).font(fm.font(15))
                        .strikethrough(todo.isCompleted, color: theme.current.chrome)
                        .foregroundStyle(todo.isCompleted ? theme.current.textMuted : theme.current.textPrimary)
                        .animation(.easeInOut(duration: 0.35), value: todo.isCompleted)
                        .onTapGesture(count: 2) {
                            if !readOnly { textBuf = todo.text; editingText = true; textFocused = true }
                        }
                }

                Spacer()
                if !readOnly && hovered && !editingText {
                    HStack(spacing: 1) {
                        IconBtn("pencil") { textBuf = todo.text; editingText = true; textFocused = true }
                        IconBtn("message") { noteBuf = todo.note ?? ""; editingNote = true; noteFocused = true }
                        IconBtn("xmark", color: .red) { vm.deleteTodo(idx) }
                    }
                    .transition(.opacity)
                }
            }

            if editingNote && !readOnly {
                TextField("备注…", text: $noteBuf, axis: .vertical)
                    .font(fm.font(14))
                    .focused($noteFocused)
                    .textFieldStyle(.plain)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 5).stroke(Color.blue.opacity(0.4)))
                    .onSubmit {
                        vm.addNote(idx, note: noteBuf); editingNote = false
                    }
            } else if let note = todo.note {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "message").font(.system(size: 9)).foregroundStyle(theme.current.chrome)
                    Text(note).font(fm.font(14)).foregroundStyle(theme.current.textTertiary)
                }.padding(.leading, 28)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
        .scaleEffect(checkBounce ? 1.02 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(hovered && !readOnly ? theme.current.textPrimary.opacity(0.04) : .clear).padding(.horizontal, 12)
        )
        .contextMenu {
            if !readOnly {
                Button {
                    textBuf = todo.text; editingText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { textFocused = true }
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button {
                    noteBuf = todo.note ?? ""; editingNote = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { noteFocused = true }
                } label: {
                    Label(todo.note != nil ? "编辑备注" : "添加备注", systemImage: "message")
                }
                Divider()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(todo.text, forType: .string)
                } label: {
                    Label("复制内容", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive) { vm.deleteTodo(idx) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .onHover { hovered = $0 }
    }
}

struct IconBtn: View {
    @EnvironmentObject var fm: FontManager
    let icon: String
    var color: Color = .secondary
    let action: () -> Void
    init(_ icon: String, color: Color = .secondary, action: @escaping () -> Void) {
        self.icon = icon; self.color = color; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(fm.font(14)).foregroundStyle(color)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

struct FooterView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    var body: some View {
        HStack(spacing: 6) {
            // 引擎心跳: 值守/资讯/同步 三个 daemon 的死活 + 同步动作反馈
            EngineStrip()
            Spacer()
            FooterButton(vm.viewMode == .project ? "按项目" : "按优先级") { vm.setViewMode(vm.viewMode == .project ? .priority : .project) }
            FooterButton(vm.expandedIDs.isEmpty ? "展开" : "折叠") {
                if vm.expandedIDs.isEmpty { vm.expandAll() } else { vm.collapseAll() }
            }
            Button { vm.paletteOpen.toggle() } label: {
                Text("⌘K").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.current.textTertiary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.current.textPrimary.opacity(0.06)))
            }.buttonStyle(SmoothButtonStyle(scale: 0.88))
            FooterButtonIcon("arrow.clockwise") { vm.reload() }
            FooterButtonIcon("bolt") { vm.doSyncNow() }
            Menu {
                Section("主题") {
                    ForEach(DBoardTheme.all) { t in
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) { ThemeManager.shared.current = t }
                        } label: {
                            Label(t.name, systemImage: theme.current.id == t.id ? "checkmark" : t.icon)
                        }
                    }
                }
                Section("字体") {
                    ForEach(DBoardFont.all) { f in
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) { FontManager.shared.current = f }
                        } label: {
                            Label(f.name, systemImage: fm.current.id == f.id ? "checkmark" : "textformat")
                        }
                    }
                }
            } label: {
                Image(systemName: "paintbrush").font(.system(size: 12)).foregroundStyle(theme.current.textMuted)
                    .padding(3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("外观")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .overlay(alignment: .top) {
            Color.black.opacity(0.06).frame(height: 1)
        }
    }
}

struct FooterButton: View {
    @EnvironmentObject var fm: FontManager
    @EnvironmentObject var theme: ThemeManager
    let title: String
    let action: () -> Void
    @State private var hovered = false
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11)).foregroundStyle(hovered ? theme.current.accentPrimary : theme.current.textMuted)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? theme.current.accentPrimary.opacity(0.12) : Color.clear))
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.9))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
    }
}

struct FooterButtonIcon: View {
    @EnvironmentObject var fm: FontManager
    @EnvironmentObject var theme: ThemeManager
    let icon: String
    let action: () -> Void
    @State private var hovered = false
    init(_ icon: String, action: @escaping () -> Void) { self.icon = icon; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(hovered ? theme.current.accentPrimary : theme.current.textMuted)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? theme.current.accentPrimary.opacity(0.12) : Color.clear))
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.9))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
    }
}
