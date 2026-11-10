import SwiftUI
import Cocoa
import Combine

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
    @Published var editingFormCount = 0
    @Published var newItemDraft: DItemDraft?
    @Published var newItemFormOpen = false
    @Published var newItemFormInWindow = false
    var newDemandWindowPresenter: ((DBoardViewModel) -> Void)?
    @Published var demandEditor: DemandCardEditor?
    @Published var demandEditorInWindow = false
    var demandWindowPresenter: ((DBoardViewModel) -> Void)?
    var demandWindowCenterRect: NSRect?
    var newDemandWindowCenterRect: NSRect?
    var demandWorkspacePresenter: (() -> Void)?
    var demandEditorDismissal: ((@escaping () -> Void) -> Void)?
    @Published var newItemDraftError: String?
    let newItemDraftStore: NewDemandDraftStore?
    let promptDraftStore: DemandPromptDraftStore
    let changeDraftStore: DemandChangeDraftStore
    lazy var deliveryCoordinator = DemandDeliveryCoordinator()
    @Published var feedback: WorkspaceFeedback?
    private var feedbackDismiss: DispatchWorkItem?
    @Published var workspacePage: WorkspacePage? = .overview
    @Published var demandFilter: DemandFilter = .all
    @Published var demandQuery = ""
    @Published var showingKnowledge = false
    @Published var archivingIDs: Set<String> = []
    @Published var reminderDrafts: [String: DemandReminderDraft] = [:]
    var reminderSaveWork: [String: DispatchWorkItem] = [:]
    @Published var handoffDrafts: [String: DemandHandoffDraft] = DemandHandoffDraft.load() {
        didSet { DemandHandoffDraft.persist(handoffDrafts) }
    }
    var handoffSaveWork: [String: DispatchWorkItem] = [:]
    @Published var releaseDrafts: [String: DemandReleaseDraft] = [:]
    @Published var releaseEvidenceDrafts: [String: DemandReleaseEvidenceDraft] = [:]
    @Published var releaseEvidenceErrors: [String: String] = [:]
    lazy var archiveJournal = ArchiveJournal()
    lazy var demandArchives: DemandArchiveStore = {
        let store: DemandArchiveStore
        if let configuredArchiveStore { store = configuredArchiveStore }
        else if allowsRemoteOperations { store = DemandArchiveStore() }
        else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardEmptyArchive-" + UUID().uuidString)
            store = DemandArchiveStore(cache: directory.appendingPathComponent("cache.md"),
                journalURL: directory.appendingPathComponent("journal.json"), allowsRemote: false)
        }
        archiveObservation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return store
    }()
    var codeReviewRequest = UUID()
    var codeReviewWork: DispatchWorkItem?
    let completionRequest: ((DItem) -> Void)?
    private let configuredArchiveStore: DemandArchiveStore?
    private var archiveObservation: AnyCancellable?
    var attentionItems: [DItem] { items.filter { $0.isUrgent || $0.status == .inProgress }.sorted { $0.priority < $1.priority } }

    enum SyncKind { case idle, pending, syncing, done, fail }

    private var fileObserver: FileRefreshObserver?
    private var syncRunning = false
    private var syncQueued = false
    private let allowsRemoteOperations: Bool
    private var lastSelfWrite: Date = .distantPast
    private var syncDebounce: DispatchWorkItem?
    private let syncDelay: TimeInterval = 30
    let reqFlow: BizMapViewModel
    private var reqFlowObservation: AnyCancellable?
    private var calendarObservations: [AnyCancellable] = []

    init(loadCache: Bool = true, reqFlow: BizMapViewModel? = nil,
         newItemDraftStore: NewDemandDraftStore? = nil,
         promptDraftStore: DemandPromptDraftStore? = nil,
         changeDraftStore: DemandChangeDraftStore? = nil,
         archiveStore: DemandArchiveStore? = nil,
         completionRequest: ((DItem) -> Void)? = nil) {
        self.completionRequest = completionRequest
        self.configuredArchiveStore = archiveStore
        self.allowsRemoteOperations = loadCache
        self.newItemDraftStore = newItemDraftStore ?? (loadCache ? NewDemandDraftStore() : nil)
        self.promptDraftStore = promptDraftStore ?? DemandPromptDraftStore(url: loadCache ? DemandPromptDraftStore.defaultURL : nil)
        self.changeDraftStore = changeDraftStore ?? DemandChangeDraftStore(url: loadCache ? DemandChangeDraftStore.defaultURL : nil)
        self.newItemDraft = self.newItemDraftStore?.draft
        self.newItemDraftError = self.newItemDraftStore?.error
        self.reqFlow = reqFlow ?? (loadCache
            ? BizMapBoardWindowController.shared.vm : BizMapViewModel(loadBackgroundData: false))
        reqFlowObservation = self.reqFlow.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if loadCache { reload(); startWatching(); observeCalendarChanges() }
    }

    func openDemandEditor(_ kind: DemandCardEditor.Kind, item: DItem, deliveryPlan: DemandDeliveryPlan? = nil, centerIn: NSRect? = nil) {
        if demandEditorInWindow, let dismissal = demandEditorDismissal,
           demandEditor?.id != item.id + ":" + kind.rawValue {
            dismissal { [weak self] in
                self?.demandEditorDismissal = nil
                self?.openDemandEditor(kind, item: item, deliveryPlan: deliveryPlan, centerIn: centerIn)
            }
            return
        }
        if allowsRemoteOperations && kind == .inspect { DemandQuickOpenRecents.shared.record(item.id) }
        if let presenter = demandWindowPresenter, kind == .inspect || demandEditorInWindow {
            demandWindowCenterRect = centerIn
            demandEditorInWindow = true
            demandEditor = DemandCardEditor(kind: kind, item: item, deliveryPlan: deliveryPlan)
            presenter(self)
            return
        }
        demandEditorInWindow = false
        NotificationCenter.default.post(name: .init("DBoardEditorWillOpen"), object: nil)
        demandEditor = DemandCardEditor(kind: kind, item: item, deliveryPlan: deliveryPlan)
    }

    func focusItem(_ id: String) {
        if items.contains(where: { $0.id == id }) {
            showDemands()
            selectedID = id
            expandedIDs.insert(id)
        } else {
            demandArchives.reloadLocal()
            guard let record = demandArchives.records.first(where: { $0.item.id == id }) else {
                showFeedback("未找到这条需求，请刷新需求或归档记录", failed: true); return
            }
            focusArchive(record)
        }
    }

    func focusArchive(_ record: ArchivedDemand) {
        if items.contains(where: { $0.id == record.item.id }) {
            workspacePage = .history
        } else {
            showDemands(.completed)
            demandQuery = record.item.id
        }
        selectedID = record.id
    }

    func showFeedback(_ message: String, failed: Bool = false) {
        feedbackDismiss?.cancel()
        let value = WorkspaceFeedback(message: message, failed: failed)
        feedback = value
        let work = DispatchWorkItem { [weak self] in
            if self?.feedback?.id == value.id { self?.feedback = nil }
        }
        feedbackDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 8 : 3), execute: work)
    }

    @Published var newTodoText = ""

    var urgentCount: Int { items.filter { $0.isUrgent }.count }
    var inProgressCount: Int { items.filter { $0.status == .inProgress }.count }
    var todayTodos: [TodoItem] { todaySec?.items ?? [] }
    var doneCount: Int { todayTodos.filter { $0.isCompleted }.count }
    var totalCount: Int { todayTodos.count }
    var allDone: Bool { totalCount > 0 && doneCount == totalCount }

    func reload() {
        reqFlow.load()
        // 读取、按周期改状态、写回在同一把锁内，避免覆盖同步脚本刚写入的内容
        let outcome: (content: String, started: Bool, failed: Bool) = CacheFile.withLock { () -> (content: String, started: Bool, failed: Bool) in
            let source = CacheFile.read() ?? ""
            let update = DemandCycle.reconcile(source)
            guard !update.startedIDs.isEmpty else { return (source, false, false) }
            return CacheFile.write(update.content) ? (update.content, true, false) : (source, false, true)
        } ?? (CacheFile.read() ?? "", false, false)
        let content = outcome.content
        if outcome.started { markSelfWrite(); scheduleSync() }
        if outcome.failed { showFeedback("周期已开始，但自动更新状态失败，请检查本地数据文件", failed: true) }
        let r = CacheParser.parse(content: content)
        items = r.items
        refreshCodeReviews()
        syncTime = r.syncTime

        // 把历史未完成项顺延显示在今日零碎顶部
        var carriedOver: [TodoItem] = []
        for sec in r.prevSecs {
            for item in sec.items where !item.isCompleted {
                var carried = item
                guard sec.dateLabel < DemandDates.today() else { continue }
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
        updateSyncDisplay(content: content)
    }

    func updateSyncDisplay(content: String? = nil) {
        if syncKind == .syncing || syncKind == .pending { return }
        if syncKind == .fail {
            // CLI 或后台同步成功后，仅凭与当前正文一致的凭证清除旧失败状态。
            guard syncText == "同步失败，改动保留在本机",
                  let content, ContentRevision.matchesSyncReceipt(content) else { return }
            if feedback?.failed == true && feedback?.message == "同步失败，改动保留在本机" {
                feedbackDismiss?.cancel()
                feedback = nil
            }
        }
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

    func toggleTodo(_ item: TodoItem) {
        afterWrite(TodoStore.change(item, .toggle).ok, fail: "事项已变化或存在重复，请刷新后核对原日期",
            success: item.isCompleted ? "已恢复为未完成" : "事项已完成")
    }

    @discardableResult
    func addTodo(_ text: String) -> Bool {
        afterWrite(TodoStore.add(text), fail: "添加失败，请使用单行文字并检查本地数据", success: "事项已添加")
    }

    @discardableResult
    func editTodo(_ item: TodoItem, newText: String) -> Bool {
        afterWrite(TodoStore.change(item, .edit(newText)).ok,
            fail: "保存失败：事项可能已变化，请刷新核对；输入仍保留")
    }

    func deleteTodo(_ item: TodoItem) {
        let result = TodoStore.change(item, .delete)
        guard afterWrite(result.ok, fail: "删除失败，请刷新核对原日期", success: "事项已删除，可撤销") else { return }
        if let removal = result.removal { offerUndo("恢复删除的事项") { TodoStore.restore(removal) } }
    }

    @discardableResult
    func addNote(_ item: TodoItem, note: String) -> Bool {
        afterWrite(TodoStore.change(item, .note(note)).ok,
            fail: "备注未保存，请使用单行文字或刷新核对；输入仍保留")
    }

    @Published var undoTitle: String?
    private var undoAction: (() -> Bool)?
    func offerUndo(_ title: String, action: @escaping () -> Bool) { undoTitle = title; undoAction = action }
    func undoLastDeletion() {
        guard let action = undoAction else { return }
        if afterWrite(action(), fail: "恢复失败：原编号或记录已存在，请核对后重试", success: "已恢复删除的记录") {
            undoTitle = nil; undoAction = nil
        }
    }

    private static func todayStr() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    // MARK: 命令面板
    struct PaletteEntry: Identifiable {
        let id: String
        let label: String
        let sub: String
        let icon: String
        let action: () -> Void
    }
    var paletteEntries: [PaletteEntry] {
        var es: [PaletteEntry] = []
        let q = paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let acts: [(String, String, () -> Void)] = [
            ("切换视图", "command", { self.setViewMode(self.viewMode == .priority ? .project : .priority); self.paletteOpen = false }),
            ("展开全部需求", "arrow.up.left.and.arrow.down.right", { self.expandAll(); self.paletteOpen = false }),
            ("折叠全部需求", "arrow.down.right.and.arrow.up.left", { self.collapseAll(); self.paletteOpen = false }),
            ("同步钉钉", "bolt", { self.doSyncNow(); self.paletteOpen = false }),
            ("设置", "gearshape", { self.paletteOpen = false; NotificationCenter.default.post(name: .init("openDBoardSettings"), object: nil) }),
            ("刷新", "arrow.clockwise", { self.reload(); self.paletteOpen = false }),
            (FeatureFlags.shared.replyEnabled ? "关闭钉钉值守" : "开启钉钉值守", "bubble.left.and.bubble.right", {
                FeatureFlags.shared.setReplyEnabled(!FeatureFlags.shared.replyEnabled); self.paletteOpen = false
            }),
            ("使用记录", "chart.bar", {
                self.paletteOpen = false
                WorkspacePreferences.shared.settingsPage = .usage
                NotificationCenter.default.post(name: .init("openDBoardSettings"), object: nil)
            }),
        ]
        // 一键运维: 写生产的动作仍走 Runner 的二次确认
        for op in OpsAction.all where q.isEmpty || op.title.lowercased().contains(q) || "cookie 抖音 douyin 运维".contains(q) {
            es.append(PaletteEntry(id: "ops:" + op.id, label: op.title, sub: "运维", icon: op.icon, action: {
                self.paletteOpen = false
                DispatchQueue.main.async { OpsRunner.shared.requestRun(op) }
            }))
        }
        let prefs = WorkspacePreferences.shared
        let preferred = prefs.favorites + prefs.recentModules.filter { !prefs.favorites.contains($0) }
        let modules = DBoardModule.visible.sorted {
            (preferred.firstIndex(of: $0.id) ?? 999) < (preferred.firstIndex(of: $1.id) ?? 999)
        }
        for m in modules where q.isEmpty || q.split(separator: " ").allSatisfy({ m.searchText.contains($0) }) {
            es.append(PaletteEntry(id: "module:" + m.id, label: m.title, sub: (prefs.favorites.contains(m.id) ? "常用" : prefs.recentModules.contains(m.id) ? "最近" : "模块") + (m.shortcut.isEmpty ? "" : " · " + m.shortcut), icon: m.icon, action: {
                self.paletteOpen = false
                m.launch()
            }))
        }
        for a in acts {
            if q.isEmpty || a.0.lowercased().contains(q) {
                es.append(PaletteEntry(id: "action:" + a.0, label: a.0, sub: "动作", icon: a.1, action: a.2))
            }
        }
        for it in items where !q.isEmpty {
            if it.displayTitle.lowercased().contains(q) || it.id.lowercased().contains(q) {
                let id = it.id
                es.append(PaletteEntry(id: "demand:" + id, label: it.displayTitle, sub: id, icon: "doc.text", action: { self.focusItem(id); self.paletteOpen = false }))
            }
        }
        if !q.isEmpty {
            let activeIDs = Set(items.map(\.id))
            for record in demandArchives.records where !activeIDs.contains(record.item.id) &&
                DemandSearch.matches(record.item, query: q) {
                es.append(PaletteEntry(id: "archive:" + record.id, label: record.item.displayTitle,
                    sub: record.item.id + " · 已完成", icon: "archivebox", action: {
                        self.focusArchive(record); self.paletteOpen = false
                    }))
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
        let ids = filteredItems.map { $0.id }
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
        cycleToStatus(id, target: next)
    }

    func cycleToStatus(_ id: String, target: ItemStatus) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if target == .completed { completeItem(item); return }
        guard item.status != target else { return }
        if target == .pending, DemandCycle.hasStarted(start: item.startDate, deadline: item.deadline) {
            showFeedback("开始日期已到；要恢复待开始，请在编辑里调整开始日期", failed: true)
            return
        }
        markSelfWrite()
        afterWrite(FileMutator.setStatus(id: id, newStatusRaw: target.rawValue),
                   fail: "状态更新失败", success: "已改为「\(target.label)」")
    }

    private func observeCalendarChanges() {
        let dayChanged = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
        let timeZoneChanged = NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
        let clockChanged = NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
        let woke = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
        let active = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
        dayChanged.merge(with: timeZoneChanged, clockChanged, woke, active)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &calendarObservations)
    }

    private func startWatching() {
        fileObserver = FileRefreshObserver(url: URL(fileURLWithPath: CacheFile.path)) { [weak self] in self?.reload() }
    }

    func scheduleSync() {
        syncDebounce?.cancel()
        if let content = CacheFile.read(), DemandOverview.matchesReceipt(content) {
            if !syncRunning { syncText = "概况已同步，其他资料保存在本机"; syncKind = .idle }
            return
        }
        if syncRunning { syncQueued = true; return }
        syncText = "\(Int(syncDelay))s 后同步"; syncKind = .pending
        guard allowsRemoteOperations else { return }
        let work = DispatchWorkItem { [weak self] in self?.doSync() }
        syncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + syncDelay, execute: work)
    }
    func doSyncNow() { syncDebounce?.cancel(); syncDebounce = nil; doSync(force: true) }

    private func doSync(force: Bool = false) {
        guard allowsRemoteOperations else { return }
        if syncRunning { syncQueued = true; return }
        syncRunning = true; syncQueued = false
        let source = CacheFile.read() ?? ""
        let revision = (try? DemandOverview.hash(source)) ?? ContentRevision.hash(source)
        syncText = "正在同步钉钉…"; syncKind = .syncing
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProcessRunner.run("/bin/bash", arguments: [CacheFile.syncScript] + (force ? ["--force"] : []), timeout: 105)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.syncRunning = false
                let current = CacheFile.read() ?? ""
                let changed = revision != ((try? DemandOverview.hash(current)) ?? ContentRevision.hash(current))
                let again = self.syncQueued || result.exitCode == 75 || (result.businessSucceeded && changed)
                self.syncQueued = false
                self.syncText = result.businessSucceeded ? "已同步钉钉" : "同步失败，改动保留在本机"
                self.syncKind = result.businessSucceeded ? .done : .fail
                if again { self.scheduleSync() }
                self.reload()
            }
        }
    }

    deinit {
        feedbackDismiss?.cancel()
        syncDebounce?.cancel()
        reminderSaveWork.values.forEach { $0.cancel() }
        fileObserver = nil
    }
}

// MARK: - 根视图
struct DBoardRootView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var prefs = WorkspacePreferences.shared
    @ObservedObject private var flags = FeatureFlags.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var monitor: Any?
    @State private var windowNumber: Int?
    var popoverMode: Bool = false

    var body: some View {
        ZStack {
            if popoverMode {
                VStack(spacing: 0) {
                    HeaderView(popoverMode: true)
                    if vm.workspacePage != .overview {
                        HStack {
                            Button { vm.workspacePage = .overview } label: { Label("概览", systemImage: "chevron.left") }
                            Spacer()
                            Text((vm.workspacePage ?? .overview).title).font(.system(size: 13, weight: .semibold))
                        }
                        .demandButtonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 12)
                    }
                    workspaceContent
                    FooterView()
                }
            } else {
                NavigationSplitView {
                    List(selection: $vm.workspacePage) {
                        Section("工作台") {
                            ForEach(WorkspacePage.allCases) { page in
                                NavigationLink(value: page) { Label(page.title, systemImage: page.icon) }
                            }
                        }
                        Section("常用入口") {
                            ForEach(prefs.favorites.compactMap { id in DBoardModule.visible.first { $0.id == id } }) { module in
                                Button { module.launch() } label: { Label(module.title, systemImage: module.icon) }
                                    .demandButtonStyle(.plain)
                            }
                        }
                        Section {
                            Button { openSettings() } label: { Label("设置", systemImage: "gearshape") }
                                .demandButtonStyle(.plain)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background { DemandCanvasBackground() }
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
                } detail: {
                    VStack(spacing: 0) {
                        workspaceContent
                        FooterView()
                    }
                    .frame(minWidth: 480)
                    .background { DemandCanvasBackground() }
                    .navigationTitle((vm.workspacePage ?? .overview).title)
                    .toolbar {
                        ToolbarItemGroup(placement: .automatic) {
                            if vm.workspacePage == .demands {
                                Picker("排序", selection: $vm.viewMode) {
                                    Text("按优先级").tag(ViewMode.priority)
                                    Text("按项目").tag(ViewMode.project)
                                }.pickerStyle(.menu)
                            }
                            Button { vm.paletteQuery = ""; vm.paletteSel = 0; vm.paletteOpen = true } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            DBoardModuleMenu()
                            WorkspacePinButton(id: "dboard")
                            DBoardSettingsButton()
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
            if vm.paletteOpen {
                Color.black.opacity(0.2).ignoresSafeArea().onTapGesture { vm.paletteOpen = false }
                CommandPalette().environmentObject(vm)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let title = vm.undoTitle {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                        Text("已删除，可从本机恢复").font(.system(size: 12))
                        Button(title) { vm.undoLastDeletion() }.controlSize(.small)
                        Button { vm.undoTitle = nil } label: { Image(systemName: "xmark") }
                            .demandButtonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if let feedback = vm.feedback {
                    WorkspaceFeedbackView(feedback: feedback) { vm.feedback = nil }
                }
            }
            .padding(16).padding(.bottom, 36)
            .transition(.opacity)
        }
        .background { DemandCanvasBackground() }
        .frame(minWidth: popoverMode ? 420 : 760, minHeight: popoverMode ? 480 : 560)
        .background(WindowNumberReader { windowNumber = $0 })
        .animation(reduceMotion ? nil : DBoardUI.spring, value: vm.paletteOpen)
        .demandEditorPresentation(enabled: !popoverMode)
        .onReceive(NotificationCenter.default.publisher(for: .init("openDBoardSettings"))) { _ in openSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.refreshCodeReviews()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { event in
            if (event.object as? NSWindow)?.windowNumber == windowNumber { vm.refreshCodeReviews() }
        }
        .onAppear {
            vm.refreshCodeReviews()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak vm] event in
                guard event.window?.windowNumber == windowNumber else { return event }
                return Self.handleKey(event, vm: vm) {
                    guard let app = NSApp.delegate as? AppDelegate else { return }
                    if popoverMode { app.closeMainPopover() } else { app.hidePanelWindow() }
                }
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }

    private var workspaceContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    switch vm.workspacePage ?? .overview {
                    case .overview:
                        WorkspaceOverview()
                    case .demands:
                        DemandListView(store: vm.demandArchives)
                    case .todos:
                        TodaySection()
                    case .history:
                        DemandArchiveSection(store: vm.demandArchives)
                        if !vm.prevSecs.isEmpty {
                            Divider().padding(16)
                            Text("零碎历史").font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                            ForEach(vm.prevSecs, id: \.dateLabel) { HistoryBlockView(sec: $0) }
                        }
                    }
                }.padding(.bottom, 16)
            }
            .id(vm.workspacePage ?? .overview)
            .onChange(of: vm.selectedID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    static func handleKey(_ event: NSEvent, vm: DBoardViewModel?, dismiss: (() -> Void)? = nil) -> NSEvent? {
        guard let vm, event.window?.attachedSheet == nil else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let c = (event.charactersIgnoringModifiers ?? "").lowercased()
        if mods.contains(.command) && c == "k" {
            vm.paletteOpen.toggle(); vm.paletteQuery = ""; vm.paletteSel = 0; return nil
        }
        if vm.paletteOpen {
            switch event.keyCode {
            case 53: vm.paletteOpen = false; return nil
            case 125: vm.paletteMove(1); return nil
            case 126: vm.paletteMove(-1); return nil
            case 36: vm.paletteRun(); return nil
            default: return event
            }
        }
        if event.keyCode == 53 && vm.editingFormCount > 0 { return event }
        if event.window?.firstResponder is NSTextView { return event }
        if mods.isEmpty && (c == "j" || c == "k") {
            vm.workspacePage = .demands; vm.moveSel(c == "j" ? 1 : -1); return nil
        }
        if mods.isEmpty && event.keyCode == 36 { vm.activateSel(); return nil }
        if event.keyCode == 53 {
            if vm.selectedID != nil { vm.selectedID = nil }
            else if let dismiss { dismiss() }
            else { event.window?.orderOut(nil) }
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
                TextField("搜索需求、模块或动作…", text: $vm.paletteQuery)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(vm.paletteEntries.enumerated()), id: \.element.id) { index, entry in
                            PaletteRow(entry: entry, selected: index == vm.paletteSel).id(index)
                        }
                        if vm.paletteEntries.isEmpty {
                            EmptyWorkspaceState(icon: "magnifyingglass", title: "没有匹配项",
                                detail: "试试需求编号、服务、日志、发布或技能。",
                                actionTitle: "清空搜索", action: { vm.paletteQuery = "" })
                        }
                    }.padding(8)
                }
                .onChange(of: vm.paletteSel) { _, index in proxy.scrollTo(index, anchor: .center) }
            }
            Divider()
            Text("↑↓ 选择 · Enter 打开 · Esc 收起")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 400, height: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
        .onAppear { focused = true }
        .onChange(of: vm.paletteQuery) { _, _ in vm.paletteSel = 0 }
    }
}

struct PaletteRow: View {
    @EnvironmentObject var fm: FontManager
    let entry: DBoardViewModel.PaletteEntry
    let selected: Bool
    var body: some View {
        Button(action: entry.action) {
        HStack(spacing: 9) {
            Image(systemName: entry.icon).font(fm.font(14))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary).frame(width: 14)
            Text(entry.label).font(.system(size: 13))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
            Spacer()
            Text(entry.sub).font(.system(size: 11))
                .foregroundStyle(Color.gray.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        }
        .demandButtonStyle(.plain)
        .accessibilityLabel(entry.label + "，" + entry.sub)
    }
}

// MARK: - Header
struct HeaderView: View {
    @ObservedObject private var flags = FeatureFlags.shared
    @ObservedObject private var shortcuts = ShortcutPreferences.shared
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var showHandle = false
    var popoverMode: Bool = false

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE"; return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("D板").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.current.textPrimary)
                Text(Self.dateFmt.string(from: Date())).font(.system(size: 10))
                    .foregroundStyle(theme.current.textTertiary)
            }
            Spacer()
            if vm.workspacePage != .overview && vm.urgentCount > 0 {
                Text("\(vm.urgentCount) 紧急").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .contentTransition(.numericText())
            }
            if vm.workspacePage != .overview && vm.inProgressCount > 0 {
                Text("\(vm.inProgressCount) 进行中").font(.system(size: 11))
                    .foregroundStyle(theme.current.textTertiary)
                    .contentTransition(.numericText())
            }
            HeaderIconButton(icon: "magnifyingglass", help: "命令面板 ⌘K") {
                vm.paletteQuery = ""; vm.paletteSel = 0; vm.paletteOpen = true
            }
            // 入口收敛: 所有模块收进一个���单, 不再在头部平铺一排图标
            DBoardModuleMenu()
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
        .contentShape(Rectangle())
        .onHover { showHandle = $0 }
        // 下拉撕出(与 Skills/BizMap 同一套手感); 双击脱出作为旧入口保留
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
        .demandButtonStyle(SmoothButtonStyle(scale: 0.9, hoverScale: 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
        .accessibilityLabel(help)
    }
}

// MARK: - 需求分组
struct NeedsSection: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    var focused = false
    var items: [DItem]? = nil
    private var displayedItems: [DItem] { items ?? (focused ? Array(vm.attentionItems.prefix(6)) : vm.filteredItems) }

    var groups: [(String, Color, [DItem])] {
        if vm.viewMode == .project {
            var order: [String] = []
            var g: [String: [DItem]] = [:]
            for it in displayedItems {
                if g[it.project] == nil { order.append(it.project) }
                g[it.project, default: []].append(it)
            }
            return order.map { ($0, Color.secondary, g[$0]!) }
        } else {
            return ItemPriority.allCases.compactMap { p in
                let arr = displayedItems.filter { $0.priority == p }
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
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            VStack(spacing: 10) {
                ForEach(Array(grp.2.enumerated()), id: \.element.id) { i, item in
                    ItemCardView(item: item, appearDelay: 0).id(item.id)
                }
            }
            .padding(.horizontal, 4)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: vm.items.count)
    }
}

/// Display the most recently appended record first; dates can repeat within the same day.
struct DemandProgressHistoryView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let milestones: [Milestone]
    @Binding var expanded: Bool

    private var visibleRecords: [Milestone] {
        expanded ? Array(milestones.reversed()) : Array(milestones.suffix(1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(visibleRecords.enumerated()), id: \.offset) { _, record in
                DemandProgressRow(record: record).id(record.date + record.fullContent)
            }
            if milestones.count > 1 {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.up" : "ellipsis")
                            .font(.system(size: 11, weight: .semibold)).frame(width: 16)
                        Text(expanded ? "收起历史记录" : "查看全部记录（\(milestones.count) 条）")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(theme.current.textTertiary)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .demandButtonStyle(.plain)
            }
        }
    }
}

// MARK: - 需求卡片
struct ItemCardView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let item: DItem
    var appearDelay: Double = 0
    var isolatedExpansion = false
    @State private var detailExpanded = true
    @State private var hovered = false
    var expanded: Bool { isolatedExpansion ? detailExpanded : vm.expandedIDs.contains(item.id) }
    var pcolor: Color { item.priority.color }
    var projC: Color { .secondary }
    var showDesc: Bool { !item.title.isEmpty && item.title != "（待补充）" && item.title != item.displayTitle }
    var hasBranch: Bool { (item.branch?.isEmpty == false && item.branch != "待定") }
    var hasCycle: Bool { item.startDate != nil }
    var hasProgress: Bool { !item.milestones.isEmpty }
    var hasDetail: Bool { showDesc || hasBranch || hasCycle || hasProgress || !item.changes.isEmpty || item.changeReadError != nil }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingAllProgress = false

    var body: some View {
        cardContent
        .contextMenu { contextMenuContent }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: expanded)
        .onHover { hovered = $0 }
        .onChange(of: expanded) { _, open in if !open { showingAllProgress = false } }
    }

    @ViewBuilder
    private var cardContent: some View {
        if isolatedExpansion {
            cardBody.padding(24)
        } else {
            cardBody
                .padding(.horizontal, 14).padding(.vertical, 13)
                .workspaceSurface(highlighted: vm.selectedID == item.id || hovered)
                .padding(.horizontal, 16)
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if isolatedExpansion { detailExpanded.toggle() }
                        else { vm.toggleExpanded(item.id) }
                    } label: {
                        cardHeader
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .demandButtonStyle(.plain).accessibilityLabel("\(expanded ? "收起" : "展开") \(item.id) \(item.displayTitle)")
                    cardMeta
                    DemandReminderView(item: item)
                    if let version = item.version {
                        Label("\(version.label) · 基于 \(version.parentID)「\(version.parentTitle)」", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let link = item.reqFlow {
                        ReqFlowLinkedRequirementView(link: link, flow: vm.reqFlow) {
                            BizMapBoardWindowController.shared.showRequirement(link: link)
                        }
                    }
                }
                if vm.archivingIDs.contains(item.id) {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("归档处理中…").font(.system(size: 11)) }
                }
                if expanded {
                    DemandContextView(item: item)
                    cardDetails
                    IncidentResultView(item: item)
                    IncidentExperienceView(item: item)
                    DemandHandoffView(item: item)
                    DemandReleaseChecklistView(item: item)
                    DemandWorktreesSection(item: item)
                    if !item.isIncident || item.execution != nil { DemandDebuggingView(item: item) }
                    actionBar
                }
        }
        .contentShape(Rectangle())
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            actionBtn(item.isIncident ? "编辑排查" : "编辑需求", "pencil") { vm.openDemandEditor(.details, item: item) }
            actionBtn("追加变更", "wand.and.stars") { vm.openDemandEditor(.changes, item: item) }
            if item.isIncident && item.status == .completed {
                actionBtn("恢复排查", "arrow.uturn.backward") { vm.reopenIncident(item) }
            } else {
                actionBtn(vm.archivingIDs.contains(item.id) ? "正在完成…" : (item.isIncident ? "完结排查" : "完成"),
                          "checkmark.circle") { vm.completeItem(item) }
                    .disabled(vm.archivingIDs.contains(item.id))
            }
            Spacer()
            Menu {
                Menu("调整优先级") {
                    ForEach(ItemPriority.allCases, id: \.self) { p in
                        Button { if p != item.priority { vm.setPriority(item.id, p) } } label: {
                            Label(p.title, systemImage: p == item.priority ? "checkmark" : "circle")
                        }
                    }
                }
                Divider()
                Button("删除需求", systemImage: "trash", role: .destructive) { vm.deleteItem(item) }
            } label: { Label("更多", systemImage: "ellipsis").font(.system(size: 12)) }
            .demandMenuStyle(.borderlessButton).fixedSize()
        }.padding(.top, 4)
    }

    private func actionBtn(_ t: String, _ icon: String, tint: Color? = nil, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Label(t, systemImage: icon).font(.system(size: 12))
                .padding(.horizontal, 6).frame(minHeight: 30).contentShape(Rectangle())
                .foregroundStyle(tint ?? theme.current.textTertiary)
        }
        .demandButtonStyle(.plain)
    }

    @ViewBuilder
    private var cardHeader: some View {
        HStack(spacing: 8) {
            Circle().fill(pcolor).frame(width: 6, height: 6)
            Text(item.displayTitle)
                .font(fm.font(14, weight: .semibold))
                .lineLimit(expanded ? nil : 2)
                .foregroundStyle(theme.current.textPrimary)
            Spacer()
            if let label = item.deadlineLabel {
                Text(label).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(item.isUrgent ? Color.red : Color.secondary)
                    .fixedSize()
            }
            Image(systemName: "chevron.right").font(fm.font(13))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(theme.current.chrome)
        }
    }

    @ViewBuilder
    private var cardMeta: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                DemandKindBadge(item: item)
                Text(item.id).font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary).fixedSize()
                if !item.project.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(DemandReminder.singleLine(item.project)).font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                StatusPill(status: item.status, onTap: {}, onSelect: { vm.cycleToStatus(item.id, target: $0) })
                    .fixedSize()
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Button { vm.copyCurrentState(item.id) } label: {
                    Label("复制现状", systemImage: "doc.on.doc").fixedSize()
                }
                .demandButtonStyle(WorkspaceActionStyle())
                .accessibilityLabel("复制现状").accessibilityIdentifier("demand-copy-" + item.id)
                Button { vm.copyReviewTask(item.id) } label: {
                    Image(systemName: "checkmark.bubble").font(.system(size: 12)).frame(width: 28, height: 28)
                }
                .demandButtonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("复制代码审查").accessibilityIdentifier("demand-review-copy-" + item.id)
                Button { vm.openDemandEditor(.prompt, item: item) } label: {
                    Image(systemName: "wand.and.stars").font(.system(size: 12)).frame(width: 28, height: 28)
                }
                .demandButtonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("编辑咒言").accessibilityIdentifier("demand-prompt-" + item.id)
            }
        }
    }

    @ViewBuilder
    private var cardDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { vm.openDemandEditor(.chats, item: item) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(item.chatLinks?.summary ?? "关联群聊").lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                    Text(item.chatLinks == nil ? "添加" : "管理").font(.system(size: 11))
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .demandButtonStyle(.plain).accessibilityIdentifier("demand-chats-" + item.id).demandKeyboardID("demand-chats-" + item.id)
            if let error = item.chatReadError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
            }
            if !item.changes.isEmpty {
                HStack {
                    Label("追加变更 " + String(item.changes.count) + " 条", systemImage: "wand.and.stars")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("查看变更") { vm.openDemandEditor(.changes, item: item) }.font(.system(size: 12)).demandButtonStyle(.plain)
                }
            }
            if let error = item.changeReadError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
            if hasDetail {
                if showDesc {
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.isIncident ? "现象" : "描述").font(fm.font(14)).foregroundStyle(theme.current.textMuted).frame(width: 30, alignment: .leading)
                        if item.isIncident { DemandSpellContentView(text: item.title) }
                        else { Text(item.title).font(fm.font(14)).foregroundStyle(theme.current.textSecondary) }
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
                    DemandProgressHistoryView(milestones: item.milestones, expanded: $showingAllProgress)
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
        Button("复制现状", systemImage: "doc.text") { vm.copyCurrentState(item.id) }
        Button("复制代码审查", systemImage: "checkmark.bubble") { vm.copyReviewTask(item.id) }
        Button("追加变更咒言", systemImage: "wand.and.stars") { vm.openDemandEditor(.changes, item: item) }
        Button("编辑咒言", systemImage: "wand.and.stars") { vm.openDemandEditor(.prompt, item: item) }
        Divider()
        Button { vm.toggleExpanded(item.id) } label: {
            Label(expanded ? "折叠" : "展开详情", systemImage: expanded ? "chevron.up" : "chevron.down")
        }
        Button { if !expanded { vm.toggleExpanded(item.id) }; vm.openDemandEditor(.details, item: item) } label: {
            Label("编辑", systemImage: "pencil")
        }
        if let link = item.reqFlow {
            Button { BizMapBoardWindowController.shared.showRequirement(link: link) } label: {
                Label("打开关联需求 \(link.no)", systemImage: "arrow.up.right.square")
            }
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
        Button("完成", systemImage: "checkmark.circle") { vm.completeItem(item) }
        Button(role: .destructive) { vm.deleteItem(item) } label: { Label("删除", systemImage: "trash") }
    }
}

// MARK: - 状态药丸
struct StatusPill: View {
    let status: ItemStatus
    let onTap: () -> Void
    var onSelect: ((ItemStatus) -> Void)? = nil
    var fg: Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return .accentColor
        case .completed: return .green
        case .suspended: return .orange
        }
    }
    var body: some View {
        Menu {
            ForEach([ItemStatus.pending, .inProgress, .completed, .suspended], id: \.rawValue) { target in
                Button {
                    if let onSelect { onSelect(target) }
                } label: {
                    if target == status { Label(target.label, systemImage: "checkmark") }
                    else { Text(target.label) }
                }
            }
        } label: {
            Text(status.label).font(.system(size: 11))
                .foregroundStyle(fg).padding(.horizontal, 8).padding(.vertical, 4)
                .background(fg.opacity(0.08), in: Capsule())
        }
        .demandMenuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
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
            // 昨天：保持����有逻辑
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
                }.demandButtonStyle(.plain)
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
                    }.demandButtonStyle(.plain)
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
                }.demandButtonStyle(.plain)
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
        }.demandButtonStyle(.plain)
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
    var compactWhenEmpty = false
    @State private var adding = false
    @FocusState private var addFocused: Bool
    private var compact: Bool { compactWhenEmpty && vm.todayTodos.isEmpty && !adding }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("今日零碎")
                    .font(.system(size: compact ? 12 : 13, weight: compact ? .regular : .semibold))
                    .foregroundStyle(compact ? theme.current.textTertiary : theme.current.textSecondary)
                if vm.todayTodos.isEmpty && !adding && !compact {
                    Text("还没有添加").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if vm.todayTodos.isEmpty && !adding {
                    addButton
                } else {
                    Text("\(vm.doneCount)/\(vm.totalCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.current.textMuted)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, compact ? 0 : 16).padding(.bottom, compact ? 0 : 6)

            if adding {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(theme.current.accentPrimary)
                    TextField("添加今日零碎…", text: $vm.newTodoText)
                        .font(fm.font(15)).textFieldStyle(.plain)
                        .foregroundStyle(theme.current.textPrimary)
                        .focused($addFocused)
                        .accessibilityLabel("添加今日零碎")
                        .onAppear { addFocused = true }
                        .onSubmit {
                            let text = vm.newTodoText.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { return }
                            if vm.addTodo(text) { vm.newTodoText = "" }
                        }
                    if !vm.newTodoText.trimmed.isEmpty {
                        Text("回车添加").font(fm.font(12)).foregroundStyle(theme.current.textMuted)
                    }
                    Button("取消", action: closeInput).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.current.textPrimary.opacity(0.05)))
                .padding(.horizontal, 16).padding(.vertical, 4)
                .onExitCommand(perform: closeInput)
            } else if !vm.todayTodos.isEmpty {
                HStack {
                    addButton
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }

            ForEach(Array(vm.todayTodos.enumerated()), id: \.element.id) { idx, td in
                TodoRow(idx: idx, todo: td, readOnly: false).id(td.id)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: vm.allDone)
        .onDisappear(perform: closeInput)
    }

    private var addButton: some View {
        Button {
            adding = true
        } label: {
            Label(vm.newTodoText.isEmpty ? "添加" : "继续添加", systemImage: "plus")
                .font(.system(size: 12))
        }
        .demandButtonStyle(.plain).foregroundStyle(Color.accentColor)
        .accessibilityLabel("添加今日零碎")
    }

    private func closeInput() {
        addFocused = false
        adding = false
    }
}

// MARK: - 零碎行
struct TodoRow: View {
    @EnvironmentObject var vm: DBoardViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let idx: Int
    let todo: TodoItem
    let readOnly: Bool
    @State private var editingText = false
    @State private var editingNote = false
    @State private var textBuf = ""
    @State private var noteBuf = ""
    @State private var registeredEditing = false
    @FocusState private var textFocused: Bool
    @FocusState private var noteFocused: Bool
    private var isEditing: Bool { editingText || editingNote }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { vm.toggleTodo(todo) } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(todo.isCompleted ? Color.green : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .demandButtonStyle(.plain).disabled(readOnly || isEditing)
            .accessibilityLabel(todo.isCompleted ? "恢复事项为未完成" : "完成事项")
            VStack(alignment: .leading, spacing: 8) {
                if todo.isCarriedOver, let origin = todo.origin {
                    Label("\(origin.date) 顺延，修改会写回原日期", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if editingText {
                    TextField("事项内容", text: $textBuf).textFieldStyle(.roundedBorder)
                        .focused($textFocused).onSubmit(saveText)
                    editActions(save: saveText)
                } else {
                    Text(todo.text).font(.system(size: 13))
                        .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                        .strikethrough(todo.isCompleted).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2) { if !readOnly { beginText() } }
                }
                if editingNote {
                    TextField("备注", text: $noteBuf).textFieldStyle(.roundedBorder)
                        .focused($noteFocused).onSubmit(saveNote)
                    editActions(save: saveNote)
                } else if let note = todo.note {
                    Label(note, systemImage: "message").font(.system(size: 12)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let link = todo.linkedDItem {
                    Button {
                        if vm.items.contains(where: { $0.id == link }) { vm.focusItem(link) }
                        else { vm.showFeedback("关联需求不在当前本地看板中，请核对历史记录", failed: true) }
                    } label: { Label("关联 \(link)", systemImage: "link") }
                    .font(.system(size: 11)).demandButtonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                if let time = todo.completedAt {
                    Text("完成于 \(time)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !readOnly {
                Menu { actions } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .demandMenuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(isEditing).accessibilityLabel("事项操作")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .contextMenu { if !readOnly { actions } }
        .animation(reduceMotion ? nil : DBoardUI.spring, value: todo.isCompleted)
        .onExitCommand { if isEditing { editingText = false; editingNote = false } }
        // 保存旧记录会换行身份，视图可能在状态回落前消失；只按本行登记过的次数归还
        .onChange(of: isEditing) { _, editing in
            guard editing != registeredEditing else { return }
            registeredEditing = editing
            vm.editingFormCount = max(0, vm.editingFormCount + (editing ? 1 : -1))
        }
        .onDisappear {
            if registeredEditing { registeredEditing = false; vm.editingFormCount = max(0, vm.editingFormCount - 1) }
        }
    }

    private func beginText() { textBuf = todo.text; editingText = true; textFocused = true }
    private func saveText() { if vm.editTodo(todo, newText: textBuf) { editingText = false } }
    private func saveNote() { if vm.addNote(todo, note: noteBuf) { editingNote = false } }
    private func editActions(save: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button("保存", action: save)
            Button("取消") { editingText = false; editingNote = false }
        }.controlSize(.small)
    }
    @ViewBuilder private var actions: some View {
        Button("编辑", systemImage: "pencil", action: beginText)
        Button(todo.note == nil ? "添加备注" : "编辑备注", systemImage: "message") {
            noteBuf = todo.note ?? ""; editingNote = true; noteFocused = true
        }
        Button("复制内容", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(todo.text, forType: .string)
        }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive) { vm.deleteTodo(todo) }
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
        .demandButtonStyle(.plain)
    }
}

struct FooterView: View {
    @ObservedObject private var cookieReminder = DouyinCookieReminderStore.shared
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        HStack(spacing: 12) {
            EngineStrip()
            LocalAudiServiceMenu()
            Spacer(minLength: 4)
            Text(vm.syncText.isEmpty ? "本地看板" : vm.syncText)
                .font(.system(size: 11)).foregroundStyle(vm.syncKind == .fail ? Color.orange : Color.secondary)
                .lineLimit(1)
            Menu {
                Button("刷新看板") { vm.reload() }
                Button("立即同步钉钉") { vm.doSyncNow() }
                Button(vm.expandedIDs.isEmpty ? "展开全部需求" : "折叠全部需求") {
                    if vm.expandedIDs.isEmpty { vm.expandAll() } else { vm.collapseAll() }
                }
                Divider()
                ForEach(OpsAction.all) { op in
                    Button(op.title + (op.id == OpsAction.douyinCookie.id
                        ? cookieReminder.expiry.map { "（" + $0.summary + "）" } ?? "" : "")) {
                        OpsRunner.shared.requestRun(op)
                    }
                }
                Divider()
                Button("设置…") { openSettings() }
            } label: { Image(systemName: "ellipsis.circle") }
            .demandMenuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
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
        .demandButtonStyle(SmoothButtonStyle(scale: 0.9))
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
        .demandButtonStyle(SmoothButtonStyle(scale: 0.9))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
    }
}
