import SwiftUI
import AppKit
import Combine

enum DemandQuickOpenScope: String, CaseIterable {
    case development = "需求", incident = "排查", all = "完整列表"
    func includes(_ item: DItem) -> Bool {
        switch self {
        case .all: return true
        case .development: return !item.isIncident
        case .incident: return item.isIncident
        }
    }
}

/// Remember actual detail visits, independently of AI feedback and demand status.
final class DemandQuickOpenRecents {
    static let shared = DemandQuickOpenRecents()
    private let defaults: UserDefaults
    private let key = "dboard.quickopen.recentIDs"
    var ids: [String] { defaults.stringArray(forKey: key) ?? [] }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func record(_ id: String) {
        defaults.set(Array(([id] + ids.filter { $0 != id }).prefix(64)), forKey: key)
    }
}

struct DemandQuickOpenEntry: Identifiable {
    let item: DItem
    let archive: ArchivedDemand?
    var id: String { item.id }
}

enum DemandQuickOpenCatalog {
    static func entries(items: [DItem], archives: [ArchivedDemand], scope: DemandQuickOpenScope,
                        includesCompleted: Bool, recentIDs: [String] = []) -> [DemandQuickOpenEntry] {
        let currentIDs = Set(items.map(\.id))
        var seen = Set<String>()
        let candidates = items.map { DemandQuickOpenEntry(item: $0, archive: nil) }
            + archives.filter { !currentIDs.contains($0.item.id) }
                .map { DemandQuickOpenEntry(item: $0.item, archive: $0) }
        let recency = Dictionary(recentIDs.enumerated().map { ($0.element, $0.offset) },
                                 uniquingKeysWith: min)
        return candidates.enumerated().filter { _, entry in
            seen.insert(entry.id).inserted && scope.includes(entry.item)
                && (includesCompleted || entry.item.status != .completed)
        }.map { offset, entry in
            (entry: entry, offset: offset, recent: recency[entry.id] ?? Int.max, activity: latestActivity(entry.item))
        }.sorted { lhs, rhs in
            if (lhs.entry.item.status == .completed) != (rhs.entry.item.status == .completed) {
                return lhs.entry.item.status != .completed
            }
            if lhs.recent != rhs.recent { return lhs.recent < rhs.recent }
            let left = rank(lhs.entry.item.status), right = rank(rhs.entry.item.status)
            if left != right { return left < right }
            if lhs.activity != rhs.activity { return lhs.activity > rhs.activity }
            if lhs.entry.item.priority != rhs.entry.item.priority {
                return lhs.entry.item.priority < rhs.entry.item.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.entry)
    }

    private static func rank(_ status: ItemStatus) -> Int {
        switch status {
        case .inProgress: return 0
        case .pending: return 1
        case .suspended: return 2
        case .completed: return 3
        }
    }

    private static func latestActivity(_ item: DItem) -> Date {
        let parser = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var dates = [item.execution?.updatedAt, item.handoff?.updated_at].compactMap { text -> Date? in
            guard let text else { return nil }
            return parser.date(from: text) ?? fractional.date(from: text)
        }
        let now = Date()
        for text in item.milestones.map(\.date) + [item.startDate ?? ""] {
            if var date = DemandDates.period(start: text, deadline: nil, on: now)?.start {
                if text.contains("."), date > now.addingTimeInterval(86400) {
                    date = Calendar.current.date(byAdding: .year, value: -1, to: date) ?? date
                }
                dates.append(date)
            }
        }
        return dates.max() ?? .distantPast
    }
}

final class DemandQuickOpenModel: ObservableObject {
    @Published var scope: DemandQuickOpenScope = .development {
        didSet {
            clearCopyNotice()
            horizontalDirection = index(of: scope) >= index(of: oldValue) ? 1 : -1
            refresh(restoreSelection: true)
        }
    }
    @Published var includesCompleted = false { didSet { refresh(restoreSelection: true) } }
    @Published private(set) var entries: [DemandQuickOpenEntry] = []
    @Published var selectedID: String? {
        didSet {
            if oldValue != selectedID { clearCopyNotice() }
            if let selectedID { remembered[scope] = selectedID }
        }
    }
    @Published private(set) var verticalDirection = 1
    @Published private(set) var horizontalDirection = 1
    @Published private(set) var copyNotice: String?
    private var copyNoticeHide: DispatchWorkItem?
    private var remembered: [DemandQuickOpenScope: String] = [:]
    private var items: [DItem] = []
    private var archives: [ArchivedDemand] = []
    private var recentIDs: [String] = []

    var selected: DemandQuickOpenEntry? { entries.first { $0.id == selectedID } }
    var selectedIndex: Int { entries.firstIndex { $0.id == selectedID } ?? 0 }

    func begin(items: [DItem], archives: [ArchivedDemand], recentIDs: [String]) {
        scope = .development
        update(items: items, archives: archives, recentIDs: recentIDs)
        selectedID = entries.first?.id
    }

    func update(items: [DItem], archives: [ArchivedDemand], recentIDs: [String]? = nil) {
        self.items = items
        self.archives = archives
        if let recentIDs { self.recentIDs = recentIDs }
        refresh(restoreSelection: false)
    }

    deinit { copyNoticeHide?.cancel() }

    private func clearCopyNotice() {
        copyNoticeHide?.cancel()
        copyNoticeHide = nil
        copyNotice = nil
    }

    func showCopyResult(_ succeeded: Bool) {
        copyNoticeHide?.cancel()
        copyNotice = succeeded ? "现状已复制" : "复制失败，请刷新后重试"
        let work = DispatchWorkItem { [weak self] in
            self?.copyNotice = nil
            self?.copyNoticeHide = nil
        }
        copyNoticeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { selectedID = nil; return }
        verticalDirection = delta >= 0 ? 1 : -1
        selectedID = entries[(selectedIndex + delta % entries.count + entries.count) % entries.count].id
    }

    func moveScope(_ delta: Int) {
        let pages = DemandQuickOpenScope.allCases
        scope = pages[min(max(index(of: scope) + delta, 0), pages.count - 1)]
    }

    private func index(of scope: DemandQuickOpenScope) -> Int { DemandQuickOpenScope.allCases.firstIndex(of: scope) ?? 0 }

    private func refresh(restoreSelection: Bool) {
        entries = DemandQuickOpenCatalog.entries(items: items, archives: archives, scope: scope,
                                                 includesCompleted: scope == .all && includesCompleted, recentIDs: recentIDs)
        let preferred = restoreSelection ? remembered[scope] : selectedID
        selectedID = entries.first { $0.id == preferred }?.id ?? entries.first?.id
    }
}

struct DemandQuickOpenView: View {
    @ObservedObject var model: DemandQuickOpenModel
    let open: (DemandQuickOpenEntry) -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var gridSelection
    @State private var appeared = false
    @State private var scopeNoticeVisible = false
    @State private var scopeNoticeHide: DispatchWorkItem?

    private var motion: Animation? { reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12) }
    private var verticalTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(y: CGFloat(model.verticalDirection * 40)).combined(with: .opacity),
            removal: .offset(y: CGFloat(model.verticalDirection * -40)).combined(with: .opacity))
    }

    var body: some View {
        ZStack {
            if model.scope == .all { fullGrid }
            else { deck }
        }
        .id(model.scope)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(x: CGFloat(model.horizontalDirection * 45)).combined(with: .opacity),
            removal: .offset(x: CGFloat(model.horizontalDirection * -45)).combined(with: .opacity)))
        .frame(width: 412, height: 330)
        .background { DemandCanvasBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 23))
        .overlay(alignment: .top) {
            Text(model.scope.rawValue).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary).opacity(scopeNoticeVisible ? 0.65 : 0)
                .padding(.top, 7).allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.25), value: scopeNoticeVisible)
                .accessibilityHidden(!scopeNoticeVisible)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.copyNotice {
                Text(notice).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.1), radius: 14, y: 7)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .animation(motion, value: appeared)
        .animation(motion, value: model.scope)
        .padding(20)
        .onAppear { appeared = true }
        .onChange(of: model.scope) { old, new in
            guard old != new else { return }
            scopeNoticeHide?.cancel()
            scopeNoticeVisible = true
            let work = DispatchWorkItem { scopeNoticeVisible = false; scopeNoticeHide = nil }
            scopeNoticeHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95, execute: work)
        }
        .onDisappear { scopeNoticeHide?.cancel(); scopeNoticeHide = nil }
        .accessibilityAction(named: Text("关闭")) { close() }
        .accessibilityAction(named: Text("上一个视图")) { model.moveScope(-1) }
        .accessibilityAction(named: Text("下一个视图")) { model.moveScope(1) }
    }

    private var deck: some View {
        ZStack {
            if let entry = model.selected {
                hero(entry).id(entry.id).transition(verticalTransition)
            } else {
                emptyState
            }
        }.animation(motion, value: model.selectedID)
    }

    private func hero(_ entry: DemandQuickOpenEntry) -> some View {
        let accent: Color = entry.item.isIncident ? .orange : .blue
        return Button { open(entry) } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(entry.id).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.item.status.label).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accent).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(accent.opacity(0.075), in: Capsule())
                }
                Text(entry.item.displayTitle).font(.system(size: 25, weight: .semibold))
                    .tracking(-0.5).foregroundStyle(.primary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(2)
                if !entry.item.reminder.trimmed.isEmpty {
                    Text(entry.item.reminder).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(accent).lineLimit(2).layoutPriority(1)
                } else if let stage = entry.item.execution?.stage {
                    Text(stage.label).font(.system(size: 12)).foregroundStyle(accent).lineLimit(2)
                }
                if let latest = entry.item.milestones.last, !latest.summary.trimmed.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Text("最近进展").fontWeight(.medium)
                            Text(latest.date)
                        }.font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(latest.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(4).lineSpacing(3)
                    }.padding(.top, 2)
                } else if let description = description(for: entry.item) {
                    Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(4).lineSpacing(3)
                }
                Spacer(minLength: 8)
                HStack {
                    Text(entry.item.project.isEmpty ? entry.item.kind.rawValue : entry.item.project)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("\(model.selectedIndex + 1) / \(model.entries.count)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 23))
                .contentShape(RoundedRectangle(cornerRadius: 23))
        }.buttonStyle(.plain).accessibilityIdentifier("quick-open-card-" + entry.id)
            .accessibilityLabel(entry.id + " " + entry.item.displayTitle + "，回车打开详情")
    }

    private func description(for item: DItem) -> String? {
        let candidates = [item.title, DemandPromptSections(stored: item.prompt).intent]
        return candidates.map { $0.trimmed }.first {
            !$0.isEmpty && $0 != "（待补充）" && $0 != item.displayTitle && $0 != item.reminder.trimmed
        }
    }

    private var fullGrid: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(model.entries.count) 项").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button { model.includesCompleted.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.includesCompleted ? "checkmark.circle.fill" : "circle")
                        Text("含已完成")
                    }.foregroundStyle(model.includesCompleted ? Color.accentColor : .secondary)
                }.buttonStyle(.plain).accessibilityIdentifier("quick-open-completed")
            }.font(.system(size: 10)).padding(.horizontal, 3).padding(.vertical, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 9),
                        GridItem(.flexible(), spacing: 9)
                    ], alignment: .leading, spacing: 9) {
                        ForEach(model.entries) { entry in gridCard(entry) }
                    }.padding(.horizontal, 1).padding(.vertical, 2)
                }.scrollIndicators(.hidden)
                    .overlay { if model.entries.isEmpty { emptyState } }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { withAnimation(motion) { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onAppear {
                        if let id = model.selectedID { proxy.scrollTo(id, anchor: .center) }
                    }
            }
        }.padding(16)
    }

    private func gridCard(_ entry: DemandQuickOpenEntry) -> some View {
        let chosen = model.selectedID == entry.id
        let accent: Color = entry.item.isIncident ? .orange : .blue
        return Button { open(entry) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(entry.id).font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(entry.item.status.label).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(accent).lineLimit(1)
                }
                Text(entry.item.displayTitle)
                    .font(.system(size: 13, weight: chosen ? .semibold : .medium))
                    .foregroundStyle(.primary).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                if !entry.item.reminder.trimmed.isEmpty {
                    Text(entry.item.reminder).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accent).lineLimit(1)
                } else if let latest = entry.item.milestones.last, !latest.summary.trimmed.isEmpty {
                    Text(latest.summary).font(.system(size: 10))
                        .foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(entry.item.project.isEmpty ? entry.item.kind.rawValue : entry.item.project)
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }.padding(12).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(chosen ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
                    if chosen {
                        RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.9), lineWidth: 1.25)
                            .matchedGeometryEffect(id: "grid-selection", in: gridSelection)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).id(entry.id)
            .accessibilityIdentifier("quick-open-card-" + entry.id)
            .accessibilityLabel(entry.id + " " + entry.item.displayTitle + "，回车打开详情")
            .accessibilityAddTraits(chosen ? .isSelected : [])
            .animation(motion, value: model.selectedID)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("这里还没有任务").font(.system(size: 16, weight: .medium))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class DemandQuickOpenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DemandQuickOpenWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSPanel?
    private(set) var model = DemandQuickOpenModel()
    private weak var viewModel: DBoardViewModel?
    private var keyMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    private let focusReturn = PanelFocusReturn()
    private let activates: Bool
    private let recents: DemandQuickOpenRecents
    private let copyCurrentState: ((String) -> Bool)?
    private var closing = false

    init(activates: Bool = true, recents: DemandQuickOpenRecents = .shared,
         copyCurrentState: ((String) -> Bool)? = nil) {
        self.activates = activates
        self.recents = recents
        self.copyCurrentState = copyCurrentState
    }

    func toggle(_ vm: DBoardViewModel) {
        if window?.isVisible == true { close() }
        else { show(vm) }
    }

    func show(_ vm: DBoardViewModel) {
        if let window {
            if activates { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            return
        }
        viewModel = vm
        vm.demandArchives.reloadLocal()
        model = DemandQuickOpenModel()
        model.begin(items: vm.items, archives: vm.demandArchives.records, recentIDs: recents.ids)
        if activates { focusReturn.capture() }
        let panel = DemandQuickOpenPanel(contentRect: NSRect(x: activates ? 0 : -10000, y: 0, width: 452, height: 370),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "D板 · 快速打开"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: DemandQuickOpenView(model: model,
            open: { [weak self] in self?.open($0) }, close: { [weak self] in self?.close() }))
        window = panel
        vm.$items.receive(on: RunLoop.main).sink { [weak self, weak vm] items in
            guard let self, let vm else { return }
            self.model.update(items: items, archives: vm.demandArchives.records, recentIDs: self.recents.ids)
        }.store(in: &subscriptions)
        vm.demandArchives.$records.receive(on: RunLoop.main).sink { [weak self, weak vm] archives in
            guard let self, let vm else { return }
            self.model.update(items: vm.items, archives: archives, recentIDs: self.recents.ids)
        }.store(in: &subscriptions)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.isVisible == true else { return event }
            return self.handleKey(event)
        }
        if activates {
            let pointer = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
                let frame = screen.visibleFrame
                DemandWindowPlacement.center(panel, in: frame)
            }
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else { panel.orderBack(nil) }
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.isVisible == true else { return event }
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c",
           model.scope != .all, let entry = model.selected, let vm = viewModel {
            let copied = copyCurrentState?(entry.id) ?? vm.copyCurrentState(entry.id)
            model.showCopyResult(copied)
            return nil
        }
        if event.characters == "+", event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let vm = viewModel {
            let centerIn = window?.screen?.visibleFrame
            let kind: DemandKind? = model.scope == .incident ? .incident :
                model.scope == .development ? .development : nil
            close(restoreFocus: false)
            vm.beginNewItemDraft(kind: kind, centerIn: centerIn)
            return nil
        }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
        switch event.keyCode {
        case 123: model.moveScope(-1); return nil
        case 124: model.moveScope(1); return nil
        case 125: model.move(1); return nil
        case 126: model.move(-1); return nil
        case 36, 76:
            if let entry = model.selected { open(entry) }
            return nil
        case 53: close(); return nil
        default: return event
        }
    }

    func open(_ entry: DemandQuickOpenEntry) {
        guard let vm = viewModel else { return }
        // Resolve the latest data again, so a removed task cannot be opened from an old search result.
        let current = vm.items.first { $0.id == entry.id }
            ?? vm.demandArchives.records.first { $0.item.id == entry.id }?.item
        guard let current else {
            model.update(items: vm.items, archives: vm.demandArchives.records)
            return
        }
        let centerIn = window?.screen?.visibleFrame
        close(restoreFocus: false)
        vm.openDemandEditor(.inspect, item: current, centerIn: centerIn)
    }

    func close(restoreFocus: Bool = true) {
        guard let window, !closing else { return }
        closing = true
        window.close()
        closing = false
        if restoreFocus && activates { focusReturn.restore() }
        else { focusReturn.discard() }
    }

    func windowDidResignKey(_ notification: Notification) {
        close(restoreFocus: false)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        subscriptions.removeAll()
        window = nil
    }
}
