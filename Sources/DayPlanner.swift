import SwiftUI

private struct PlanBlock: Codable, Identifiable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var reminderAt: Date
    var didRemind = false
    var completed = false
    var requirementID: Int? = nil
    var requirementNo: String? = nil
}

private enum PlanDay {
    static func endOfDay(_ day: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))!
    }
}

private final class DayPlanStore: ObservableObject {
    static let shared = DayPlanStore()
    @Published private(set) var blocks: [PlanBlock] = []
    @Published private(set) var now = Date()
    @Published private(set) var requirements: [BizPRDItem] = []
    @Published private(set) var reqSnapshotAt: Date?
    @Published private(set) var reqLoadError: String?

    private let storageKey = "dboard_day_plan_v1"
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var reminderWindow: NSWindow?

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([PlanBlock].self, from: data) {
            blocks = saved.filter { $0.start >= Calendar.current.date(byAdding: .day, value: -30, to: Date())! }
        }
        let tick = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkDue() }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkDue() }
        DispatchQueue.main.async { [weak self] in self?.checkDue() }
    }

    var today: [PlanBlock] {
        blocks.filter { Calendar.current.isDateInToday($0.start) }
            .sorted { $0.start < $1.start }
    }

    func reloadRequirements() {
        let path = NSString(string: "~/.claude/bizmap-cache.json").expandingTildeInPath
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let snapshot = try JSONDecoder().decode(BizMapCache.self, from: data)
            requirements = (snapshot.prdItemsAll ?? [])
                .filter { $0.scopes.contains("mine") && ["KFZ", "CSZ"].contains($0.code) }
                .sorted(by: BizMapViewModel.prdSort)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            reqSnapshotAt = snapshot.prdGenerated.flatMap { formatter.date(from: $0) }
            reqLoadError = nil
        } catch {
            requirements = []
            reqSnapshotAt = nil
            reqLoadError = "ReqFlow 缓存不可用"
        }
    }

    func save(title: String, start: Date, end: Date, editing id: UUID?,
              requirementID: Int?, requirementNo: String?) -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "写下要做的事情" }
        let calendar = Calendar.current
        guard let start = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)),
              let end = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end)) else {
            return "时间无效，请重新选择"
        }
        guard calendar.isDateInToday(start), calendar.isDateInToday(end), end > start else {
            return "请选择今天的时间，结束时间要晚于开始时间"
        }
        guard !blocks.contains(where: { $0.id != id && calendar.isDateInToday($0.start) && start < $0.end && end > $0.start }) else {
            return "时间与已有安排重叠，请调整后再保存"
        }
        if let id, let index = blocks.firstIndex(where: { $0.id == id }) {
            blocks[index].title = name
            blocks[index].requirementID = requirementID
            blocks[index].requirementNo = requirementNo
            blocks[index].start = start
            if blocks[index].end != end {
                blocks[index].end = end
                blocks[index].reminderAt = end
                blocks[index].didRemind = end <= Date()
            }
        } else {
            blocks.append(PlanBlock(title: name, start: start, end: end, reminderAt: end,
                                    didRemind: end <= Date(), requirementID: requirementID, requirementNo: requirementNo))
        }
        persist()
        checkDue()
        return nil
    }

    func setCompleted(_ id: UUID, _ completed: Bool) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].completed = completed
        persist()
    }

    func delete(_ id: UUID) {
        blocks.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(blocks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func checkDue() {
        now = Date()
        guard reminderWindow == nil else { return }
        guard let block = today.first(where: { !$0.completed && !$0.didRemind && $0.reminderAt <= now }) else { return }
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        blocks[index].didRemind = true
        persist()
        showReminder(for: block)
    }

    func previewReminder() {
        guard reminderWindow == nil else { return }
        let end = Date()
        let preview = PlanBlock(title: "这一段时间结束了", start: end.addingTimeInterval(-60),
                                end: end, reminderAt: end)
        showReminder(for: preview, isPreview: true)
    }

    private func showReminder(for block: PlanBlock, isPreview: Bool = false) {
        let content = PlanReminderView(title: block.title, time: block.end, isPreview: isPreview) { [weak self] action in
            guard let self else { return }
            self.reminderWindow?.orderOut(nil)
            self.reminderWindow = nil
            if !isPreview, let index = self.blocks.firstIndex(where: { $0.id == block.id }) {
                switch action {
                case .complete:
                    self.blocks[index].completed = true
                case .snooze:
                    let minutes = UserDefaults.standard.integer(forKey: "plan.snoozeMinutes")
                    self.blocks[index].reminderAt = Date().addingTimeInterval(Double(minutes > 0 ? minutes : 10) * 60)
                    self.blocks[index].didRemind = false
                case .dismiss:
                    break
                }
                self.persist()
            }
            self.checkDue()
        }
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 256),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.level = .floating
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(rootView: content)
        win.setContentSize(NSSize(width: 420, height: 256))
        let frame = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
        win.setFrameOrigin(NSPoint(x: frame.midX - win.frame.width / 2,
                                   y: frame.midY - win.frame.height / 2))
        reminderWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }
}

private enum PlanReminderAction { case complete, snooze, dismiss }

private struct PlanReminderView: View {
    @AppStorage("plan.snoozeMinutes") private var snoozeMinutes = 10
    let title: String
    let time: Date
    let isPreview: Bool
    let onAction: (PlanReminderAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 36, weight: .light, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Text(isPreview ? "预览 · 不修改安排" : "这一段结束了")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 18)
            Rectangle().fill(Color.accentColor).frame(height: 2)
                .padding(.bottom, 20)
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .lineLimit(2)
            Text("接下来怎么安排？")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Spacer(minLength: 16)
            HStack(spacing: 14) {
                Button("知道了") { onAction(.dismiss) }
                Spacer()
                Button("\(snoozeMinutes) 分钟后提醒") { onAction(.snooze) }
                Button("标记完成") { onAction(.complete) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 420, height: 256)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private enum PlanDragPart { case move, start, end }

private struct DayPlanView: View {
    @ObservedObject var store: DayPlanStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("plan.defaultMinutes") private var defaultMinutes = 45
    @FocusState private var titleFocused: Bool
    @State private var editingID: UUID?
    @State private var editorAnchor: Date?
    @State private var editorScrollRequest = 0
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftStart = Date()
    @State private var draftEnd = Date().addingTimeInterval(45 * 60)
    @State private var draftRequirementID: Int?
    @State private var draftRequirementNo: String?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var showFullDay = false
    @State private var showInbox = false
    @State private var dragging: (id: UUID, part: PlanDragPart, minutes: Int)?
    @State private var dragError: String?

    private var dayEnd: Date { PlanDay.endOfDay(store.now).addingTimeInterval(-60) }
    private var workEnd: Date { Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: store.now)! }
    private var displayEnd: Date {
        if showFullDay { return dayEnd }
        let lastPlan = store.today.map(\.end).max() ?? store.now
        let draft = editing ? draftEnd : store.now
        return min(dayEnd, max(store.now.addingTimeInterval(2 * 3600), lastPlan.addingTimeInterval(30 * 60), draft))
    }
    private var timelineNow: Date {
        editing && editingID == nil ? min(store.now, editorAnchor ?? store.now) : store.now
    }
    private var visibleBlocks: [PlanBlock] {
        store.today.filter { $0.end > timelineNow }
    }
    private var pastBlocks: [PlanBlock] {
        store.today.filter { $0.end <= timelineNow }
    }
    private var pendingRequirements: [BizPRDItem] {
        let scheduled = Set(store.today.compactMap(\.requirementID))
        return store.requirements.filter { !scheduled.contains($0.id) }
    }
    private var upcoming: [PlanBlock] { store.today.filter { !$0.completed && $0.end > store.now } }
    private var current: PlanBlock? { upcoming.first { $0.start <= store.now } }
    private var next: PlanBlock? { current ?? upcoming.first }
    private var totalMinutes: Int {
        store.today.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
    }
    private var finishedMinutes: Int {
        store.today.filter(\.completed).reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
    }
    private var dayStart: Date { Calendar.current.startOfDay(for: store.now) }
    private var dayDuration: TimeInterval { PlanDay.endOfDay(store.now).timeIntervalSince(dayStart) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 224)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            timeline
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 680, minHeight: 520)
        .confirmationDialog("删除这段安排？", isPresented: $confirmDelete) {
            Button("删除安排", role: .destructive) {
                if let editingID { store.delete(editingID) }
                editing = false
            }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.now.formatted(.dateTime.month().day().weekday(.wide)))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(store.now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 32, weight: .light, design: .rounded))
                .monospacedDigit()
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.vertical, 20)
            if let next {
                Text(current == nil ? "下一段 · \(next.start.formatted(date: .omitted, time: .shortened))" : "正在进行")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(next.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .padding(.top, 8)
                Text(current == nil ? "\(next.start.formatted(date: .omitted, time: .shortened)) – \(next.end.formatted(date: .omitted, time: .shortened))" : "到 \(next.end.formatted(date: .omitted, time: .shortened)) 结束")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                Text("下一段时间，留给什么？")
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("从右侧选一段空档，开始安排。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            Spacer(minLength: 20)
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.bottom, 20)
            Text("今日负荷")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("已规划")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor))
                    ForEach(store.today) { block in
                        let x = CGFloat(block.start.timeIntervalSince(dayStart) / dayDuration) * geo.size.width
                        let width = CGFloat(block.end.timeIntervalSince(block.start) / dayDuration) * geo.size.width
                        Capsule()
                            .fill(block.completed ? Color.secondary : Color.accentColor)
                            .frame(width: max(2, width))
                            .offset(x: x)
                    }
                    Rectangle().fill(Color.primary)
                        .frame(width: 2, height: 13)
                        .offset(x: CGFloat(store.now.timeIntervalSince(dayStart) / dayDuration) * geo.size.width)
                }
                .frame(height: 8)
            }
            .frame(height: 13)
            .padding(.top, 16)
            .accessibilityLabel("全天日程分布，当前时间有刻度；已规划 \(totalMinutes / 60) 小时 \(totalMinutes % 60) 分")
            HStack {
                Text("00:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("24:00")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            HStack {
                Text("已完成 \(finishedMinutes / 60) 小时 \(finishedMinutes % 60) 分")
                Spacer()
                Text("\(store.today.filter(\.completed).count) / \(store.today.count) 段")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 20)
            GeometryReader { geo in
                Capsule().fill(Color(nsColor: .separatorColor))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(finishedMinutes) / CGFloat(max(1, totalMinutes)))
                    }
            }
            .frame(height: 4)
            .padding(.top, 8)
            Button("预览结束提醒") { store.previewReminder() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 24)
        }
        .padding(20)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今天的时间")
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(store.today.count) 段安排 · 点击空档即可添加")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let dragError {
                        Text(dragError).font(.system(size: 11)).foregroundStyle(.red)
                    }
                    if let error = store.reqLoadError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    } else if let date = store.reqSnapshotAt {
                        Text("ReqFlow 快照 · \(date.formatted(.dateTime.month().day().hour().minute())) · \(store.requirements.count) 条进行中")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("规划设置")
                .accessibilityLabel("规划设置")
                Button { addNew() } label: {
                    Label("安排时间", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if !pendingRequirements.isEmpty { inbox }
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                    if !pastBlocks.isEmpty {
                        Text("此前安排")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                        ForEach(pastBlocks) { block in
                            timelineRow(block)
                            if editing && editingID == block.id { inlineEditor.padding(.bottom, 16).id("planEditor") }
                            if block.start < workEnd && block.end >= workEnd { workEndRow }
                        }
                    }
                    if visibleBlocks.isEmpty {
                        emptyTimeline
                    } else {
                        ForEach(Array(visibleBlocks.enumerated()), id: \.element.id) { index, block in
                            let previous = index == 0 ? timelineNow : max(timelineNow, visibleBlocks[index - 1].end)
                            if block.start.timeIntervalSince(previous) >= 5 * 60 {
                                gap(from: previous, to: block.start)
                            }
                            timelineRow(block)
                            if editing && editingID == block.id { inlineEditor.padding(.bottom, 16).id("planEditor") }
                            if block.start < workEnd && block.end >= workEnd { workEndRow }
                        }
                        futureSlots(after: max(timelineNow, visibleBlocks.last!.end))
                    }
                    if displayEnd >= dayEnd {
                        endRow
                    } else {
                        Button("展开今天剩余时间") { showFullDay = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 16)
                            .padding(.leading, 100)
                    }
                }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                .onChange(of: editorScrollRequest) {
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.25)) {
                            proxy.scrollTo("planEditor", anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { showInbox.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showInbox ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Label("待安排需求 · \(pendingRequirements.count)", systemImage: "tray")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showInbox ? "收起待安排需求" : "展开待安排需求，\(pendingRequirements.count) 条")
                Spacer()
                Button("ReqFlow ↗") { BizMapBoardWindowController.shared.showRequirement() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
            if showInbox {
                ScrollView {
                    requirementRows(limit: 5)
                }
                .frame(maxHeight: 180)
                if let date = store.reqSnapshotAt {
                    Text("快照 \(date.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func requirementRows(limit: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(pendingRequirements.prefix(limit))) { req in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(req.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .help(req.name)
                        Text("\(req.no) · \(req.status)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button("安排") { addNew(requirement: req) }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            if pendingRequirements.count > 5 {
                Button("在 ReqFlow 查看更多") { BizMapBoardWindowController.shared.showRequirement() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 8)
            }
        }
    }

    private var emptyTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("从现在，往后安排。")
                    .font(.system(size: 17, weight: .medium))
                Spacer()
                Text("或者先留出")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 12)
            HStack(spacing: 8) {
                ForEach([25, 50, 90].filter { Double($0 * 60) <= dayEnd.timeIntervalSince(store.now) }, id: \.self) { minutes in
                    Button("\(minutes) 分钟") { addNew(minutes: minutes) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.bottom, 10)
            if let requirement = pendingRequirements.first {
                Button("从 ReqFlow 需求开始 →") { addNew(requirement: requirement) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 22)
            } else {
                Spacer().frame(height: 18)
            }
            HStack(spacing: 20) {
                Text(timelineNow.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 68, alignment: .leading)
                Circle().fill(Color.accentColor).frame(width: 9, height: 9)
                Text(timelineNow < store.now ? "选定时段" : "现在")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.bottom, 8)
            futureSlots(after: timelineNow)
        }
    }

    private var endRow: some View {
        HStack(spacing: 20) {
            Text("23:59")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 68, alignment: .leading)
            Circle().fill(Color.secondary).frame(width: 9, height: 9)
            Text("今天结束")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var workEndRow: some View {
        HStack(spacing: 20) {
            Text("18:00")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 68, alignment: .leading)
            Circle().fill(Color.secondary).frame(width: 9, height: 9)
            Text("工作时间结束 · 仍可安排")
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 12)
    }

    @ViewBuilder private func futureSlots(after anchor: Date) -> some View {
        if displayEnd.timeIntervalSince(anchor) >= 5 * 60 {
            gap(from: anchor, to: displayEnd)
        }
    }

    private func timelineRow(_ block: PlanBlock) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    Text(previewTimes(for: block).start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    dragHandle(block, part: .start)
                }
                HStack(spacing: 2) {
                    Text(previewTimes(for: block).end.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    dragHandle(block, part: .end)
                }
            }
            .frame(width: 68, alignment: .leading)
            VStack(spacing: 0) {
                Circle()
                    .fill(block.completed ? Color.secondary : block.start <= store.now && block.end > store.now ? Color.accentColor : Color(nsColor: .separatorColor))
                    .frame(width: 9, height: 9)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            }
            .frame(width: 9)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Button { edit(block) } label: {
                        Text(block.title)
                            .font(.system(size: 15, weight: .medium))
                            .strikethrough(block.completed)
                            .foregroundStyle(block.completed ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("编辑这段安排")
                    dragHandle(block, part: .move)
                    Button { store.setCompleted(block.id, !block.completed) } label: {
                        Image(systemName: block.completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(block.completed ? Color.accentColor : Color.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(block.completed ? "标记未完成" : "标记完成")
                }
                if let no = block.requirementNo {
                    Button("ReqFlow · \(no) ↗") {
                        BizMapBoardWindowController.shared.showRequirement(no: no)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                }
                if !block.completed && block.start <= store.now && block.end > store.now {
                    Text("进行中  ·  \(max(0, Int(block.end.timeIntervalSince(store.now) / 60))) 分钟后结束")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(block.completed ? "已完成" : block.end <= store.now ? "已过时间 · 点击可调整" : "结束时提醒")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 22)
        .padding(.horizontal, 12)
        .background {
            if !block.completed && block.start <= store.now && block.end > store.now {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.07))
            }
        }
    }

    private func previewTimes(for block: PlanBlock) -> (start: Date, end: Date) {
        guard let dragging, dragging.id == block.id else { return (block.start, block.end) }
        let offset = TimeInterval(dragging.minutes * 60)
        switch dragging.part {
        case .move: return (block.start.addingTimeInterval(offset), block.end.addingTimeInterval(offset))
        case .start: return (block.start.addingTimeInterval(offset), block.end)
        case .end: return (block.start, block.end.addingTimeInterval(offset))
        }
    }

    private func dragHandle(_ block: PlanBlock, part: PlanDragPart) -> some View {
        Image(systemName: part == .move ? "line.3.horizontal" : part == .start ? "arrow.up" : "arrow.down")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .help(part == .move ? "上下拖动以移动安排" : part == .start ? "上下拖动以调整开始时间" : "上下拖动以调整结束时间")
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { value in
                    dragging = (block.id, part, Int((value.translation.height / 30).rounded()) * 5)
                }
                .onEnded { value in
                    let minutes = Int((value.translation.height / 30).rounded()) * 5
                    dragging = nil
                    guard minutes != 0 else { return }
                    let offset = TimeInterval(minutes * 60)
                    let start = part == .move || part == .start ? block.start.addingTimeInterval(offset) : block.start
                    let end = part == .move || part == .end ? block.end.addingTimeInterval(offset) : block.end
                    guard Calendar.current.isDateInToday(start), end <= dayEnd, end > start else {
                        dragError = "调整后的时间需要留在今天，结束时间要晚于开始时间"
                        return
                    }
                    dragError = store.save(title: block.title, start: start, end: end, editing: block.id,
                                           requirementID: block.requirementID, requirementNo: block.requirementNo)
                    if dragError == nil && editing && editingID == block.id {
                        draftStart = start
                        draftEnd = end
                    }
                })
    }

    @ViewBuilder private func gap(from start: Date, to end: Date) -> some View {
        if start < workEnd && end >= workEnd {
            if workEnd.timeIntervalSince(start) >= 5 * 60 { gapPart(from: start, to: workEnd) }
            workEndRow
            if end.timeIntervalSince(workEnd) >= 5 * 60 { gapPart(from: workEnd, to: end) }
        } else {
            gapPart(from: start, to: end)
        }
    }

    private func gapPart(from start: Date, to end: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                addNew(start: start, end: min(end, start.addingTimeInterval(Double(defaultMinutes * 60))))
            } label: {
                HStack(spacing: 20) {
                    Text(start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 68, alignment: .leading)
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 58)
                        .frame(width: 9)
                    Label("空档 \(max(0, Int(end.timeIntervalSince(start) / 60))) 分钟 · 点击安排", systemImage: "plus.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击填入空闲时间")
            if editing && editingID == nil && (editorAnchor ?? dayEnd) >= start && (editorAnchor ?? dayEnd) < end {
                inlineEditor.padding(.bottom, 16).id("planEditor")
            }
        }
    }

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(editingID == nil ? "新的一段" : "编辑这一段")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { editing = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消编辑")
            }
            TextField("这段时间，做什么？", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($titleFocused)
                .onSubmit(saveDraft)
                .padding(.vertical, 6)
            HStack(spacing: 8) {
                Menu {
                    Button("不关联需求") {
                        draftRequirementID = nil
                        draftRequirementNo = nil
                    }
                    ForEach(store.requirements) { req in
                        Button("\(req.no) · \(req.name)") {
                            if draftTitle.isEmpty || draftRequirementID != nil { draftTitle = req.name }
                            draftRequirementID = req.id
                            draftRequirementNo = req.no
                        }
                    }
                    if store.requirements.isEmpty {
                        Button(store.reqLoadError ?? "暂无进行中的需求") { }
                            .disabled(true)
                    }
                    Divider()
                    Button("重新读取 ReqFlow 缓存") { store.reloadRequirements() }
                } label: {
                    Label(draftRequirementNo ?? "关联 ReqFlow 需求", systemImage: "link")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                Spacer()
                if let date = store.reqSnapshotAt {
                    Text("快照 \(date.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            HStack(spacing: 12) {
                Text("从").foregroundStyle(.secondary)
                DatePicker("开始", selection: $draftStart, displayedComponents: .hourAndMinute).labelsHidden()
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Text("到").foregroundStyle(.secondary)
                DatePicker("结束", selection: $draftEnd, displayedComponents: .hourAndMinute).labelsHidden()
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                if editingID != nil {
                    Button("删除", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.plain)
                }
                Spacer()
                Text("结束时提醒")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("保存���排", action: saveDraft)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func saveDraft() {
        error = store.save(title: draftTitle, start: draftStart, end: draftEnd, editing: editingID,
                           requirementID: draftRequirementID, requirementNo: draftRequirementNo)
        if error == nil { editing = false }
    }

    private func addNew(minutes: Int? = nil, requirement: BizPRDItem? = nil) {
        let duration = minutes ?? defaultMinutes
        let rounded = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 300) * 300)
        var start = rounded
        for block in store.today where start < block.end && start.addingTimeInterval(TimeInterval(duration * 60)) > block.start {
            start = block.end
        }
        guard start.addingTimeInterval(5 * 60) <= dayEnd else {
            dragError = "今天剩余时间不足 5 分钟，请调整已有安排"
            return
        }
        addNew(start: start, end: min(dayEnd, start.addingTimeInterval(TimeInterval(duration * 60))))
        if let requirement {
            draftTitle = requirement.name
            draftRequirementID = requirement.id
            draftRequirementNo = requirement.no
            showInbox = false
        }
    }

    private func addNew(start: Date, end: Date) {
        editingID = nil
        editorAnchor = start
        dragError = nil
        draftTitle = ""
        draftRequirementID = nil
        draftRequirementNo = nil
        draftStart = start
        draftEnd = end
        error = nil
        editing = true
        titleFocused = true
        editorScrollRequest += 1
    }

    private func edit(_ block: PlanBlock) {
        editingID = block.id
        editorAnchor = nil
        dragError = nil
        draftTitle = block.title
        draftRequirementID = block.requirementID
        draftRequirementNo = block.requirementNo
        draftStart = block.start
        draftEnd = block.end
        error = nil
        editing = true
        titleFocused = true
        editorScrollRequest += 1
    }
}

struct DayPlanSettingsView: View {
    @AppStorage("plan.defaultMinutes") private var defaultMinutes = 45
    @AppStorage("plan.snoozeMinutes") private var snoozeMinutes = 10

    var body: some View {
        TabView {
            Form {
                Picker("默认安排时长", selection: $defaultMinutes) {
                    ForEach([25, 45, 50, 60, 90], id: \.self) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                Picker("提醒延后时间", selection: $snoozeMinutes) {
                    ForEach([5, 10, 15, 30], id: \.self) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                Text("今日规划可安排今天的任意时段；结束时提醒。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .tabItem { Label("今日规划", systemImage: "calendar.badge.clock") }
        }
        .frame(width: 420, height: 200)
    }
}

final class DayPlanWindowController {
    static let shared = DayPlanWindowController()
    private let store = DayPlanStore.shared
    private var window: NSWindow?

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        show()
    }

    private func show() {
        store.checkDue()
        store.reloadRequirements()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "今日规划"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 520)
        window.contentViewController = NSHostingController(rootView: DayPlanView(store: store))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
