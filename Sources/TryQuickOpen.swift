import SwiftUI
import AppKit
import Combine

final class TryQuickOpenModel: ObservableObject {
    @Published var scope: TryWorkspaceModule = .health {
        didSet {
            horizontalDirection = index(scope) >= index(oldValue) ? 1 : -1
            refresh(restore: true)
        }
    }
    @Published private(set) var entries: [TryEntry] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var verticalDirection = 1
    @Published private(set) var horizontalDirection = 1
    @Published var copyNotice: String?
    private static let scopes: [TryWorkspaceModule] = [.health, .digestion, .idea]
    private var all: [TryEntry] = []
    private var remembered: [TryWorkspaceModule: String] = [:]
    var selected: TryEntry? { entries.first { $0.id == selectedID } }
    var selectedIndex: Int { entries.firstIndex { $0.id == selectedID } ?? 0 }
    func begin(_ entries: [TryEntry]) {
        all = entries; remembered = [:]
        scope = .health
        refresh(restore: true)
    }
    func update(_ entries: [TryEntry]) { all = entries; refresh(restore: false) }
    private func index(_ kind: TryWorkspaceModule) -> Int { Self.scopes.firstIndex(of: kind) ?? 0 }
    func moveScope(_ delta: Int) {
        scope = Self.scopes[min(max(index(scope) + delta, 0), Self.scopes.count - 1)]
    }
    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        verticalDirection = delta >= 0 ? 1 : -1
        selectedID = entries[(selectedIndex + delta % entries.count + entries.count) % entries.count].id
        if let selectedID { remembered[scope] = selectedID }
        copyNotice = nil
    }
    private func refresh(restore: Bool) {
        entries = scope.entryKind.map { TryEntrySearch.results(in: all, kind: $0) } ?? []
        let preferred = restore ? remembered[scope] : selectedID
        selectedID = entries.first { $0.id == preferred }?.id ?? entries.first?.id
        if let selectedID { remembered[scope] = selectedID }
        copyNotice = nil
    }
}


/// Only a current plan and current evidence count toward the quick card's progress.
struct TryLearningQuickSummary {
    let goal: String
    let phase: String
    let current: String
    let next: String
    let stageCount: Int
    let masteredCount: Int
    let stageNumber: Int?

    init(_ entry: TryEntry) {
        let proposal = entry.learningPlanProposal
        let plan = entry.learningPlanCurrent ? entry.learningPlan :
            (entry.learningConfigReady && proposal?.configRevision == entry.learningConfig?.revision ? proposal : nil)
        let compactGoal = plan?.goalSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawGoal = entry.learningConfig?.goal.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        goal = compactGoal.isEmpty ? (rawGoal.isEmpty ? "先确定想学会什么，再让 AI 帮你规划。" : rawGoal) : compactGoal

        let stages = entry.learningPlanCurrent ? entry.learningPlan?.stages ?? [] : []
        stageCount = stages.count
        masteredCount = stages.filter { entry.verifiedLearningStages.contains($0.id) }.count
        let stage = entry.currentLearningStage
        stageNumber = stages.firstIndex { $0.id == stage?.id }.map { $0 + 1 }

        if entry.learningFinishedAt != nil {
            phase = "本轮已结束"
            current = entry.learningGoalReached == true ? "已达到本轮学习目标" : "笔记与成果已留下"
            next = "回看学习总结"
        } else if !entry.learningConfigReady {
            phase = "准备开始"
            current = "还没有确定学习目标"
            next = "补好目标、基础和截止时间"
        } else if !entry.learningPlanCurrent {
            phase = entry.learningPlan == nil ? "等待学习方案" : "学习目标已更新"
            current = entry.learningPlan == nil ? "让 AI 把目标拆成学习阶段" : "原方案需要调整，进度待重新核验"
            next = entry.learningActionTitle
        } else if stageCount > 0 && masteredCount == stageCount {
            phase = "阶段已掌握"
            current = "准备核验本轮学习目标"
            next = entry.learningActionTitle
        } else if let stage {
            phase = "当前阶段"
            current = stage.title
            let later = stages.dropFirst(stageNumber ?? 0).first { !entry.verifiedLearningStages.contains($0.id) }
            next = entry.learningConfig?.overdue == true ? "已到截止时间，先复盘" :
                (later.map { "下一阶段 · " + $0.title } ?? "完成本节后，核验学习目标")
        } else {
            phase = "方案待补充"
            current = "还没有可开始的学习阶段"
            next = "让 AI 补齐学习阶段"
        }
    }
}

struct TryQuickOpenView: View {
    @ObservedObject var model: TryQuickOpenModel
    @ObservedObject var store: TryStore
    let open: (String) -> Void
    let create: (TryKind) -> Void
    var openHealth: () -> Void = {}
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var noticeVisible = false
    @State private var noticeHide: DispatchWorkItem?
    private var motion: Animation? { reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12) }
    var body: some View {
        ZStack {
            ZStack {
                if model.scope == .health {
                    TryHealthQuickCard(store: .shared, monitor: .shared, open: openHealth)
                } else if let entry = model.selected { hero(entry).id(entry.id).transition(verticalTransition) }
                else {
                    VStack(spacing: 18) {
                        Text(model.scope == .digestion ? "还没有学习笔记" : "还没有想法记录").dboardFont(size: 20, weight: .medium)
                        Button(model.scope == .digestion ? "开始学习" : "写下来") { create(model.scope.entryKind ?? .digestion) }
                            .buttonStyle(TryControlStyle()).dboardFont(size: 13).foregroundStyle(theme.current.accentPrimary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.animation(motion, value: model.selectedID)
        }
        .id(model.scope)
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(x: CGFloat(model.horizontalDirection * 45)).combined(with: .opacity),
            removal: .offset(x: CGFloat(model.horizontalDirection * -45)).combined(with: .opacity)))
        .frame(width: 412, height: 410)
        .background { DemandCanvasBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 23))
        .overlay(alignment: .top) {
            Text(model.scope.title).dboardFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary).opacity(noticeVisible ? 0.65 : 0)
                .padding(.top, 7).allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.copyNotice {
                Text(notice).dboardFont(size: 11).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 10).allowsHitTesting(false)
            }
        }
        .animation(motion, value: model.scope)
        .onChange(of: model.scope) { _, _ in
            noticeHide?.cancel(); noticeVisible = true
            let work = DispatchWorkItem { noticeVisible = false }
            noticeHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
        }
        .onDisappear { noticeHide?.cancel() }
        .background(WorkspaceSwipeBridge { model.moveScope($0) })
        .dboardThemeAccent()
    }
    private var verticalTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(y: CGFloat(model.verticalDirection * 40)).combined(with: .opacity),
            removal: .offset(y: CGFloat(model.verticalDirection * -40)).combined(with: .opacity))
    }
    private func hero(_ entry: TryEntry) -> some View {
        Button { open(entry.id) } label: {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text(entry.id).dboardFont(size: 11, design: .monospaced).foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.kind.title).dboardFont(size: 11).foregroundStyle(theme.current.accentSecondary)
                }
                Text(entry.displayTitle).dboardFont(size: 25, weight: .semibold).tracking(-0.5)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if entry.kind == .digestion {
                    learningContent(entry)
                } else {
                    ideaContent(entry)
                }
                Spacer(minLength: 0)
                HStack {
                    Text(entry.kind == .digestion ?
                        "\(entry.learningNotes.count) 篇笔记 · \(entry.learningOutcomes.count) 项成果" :
                        "\(entry.ideaSupplements.count) 条补充").lineLimit(1)
                    Spacer()
                    Text("\(model.selectedIndex + 1) / \(model.entries.count)").monospacedDigit()
                }.dboardFont(size: 11).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(RoundedRectangle(cornerRadius: 23))
        }.buttonStyle(DBoardPlainButtonStyle()).accessibilityIdentifier("try-quick-card-" + entry.id)
    }
    private func learningContent(_ entry: TryEntry) -> some View {
        let summary = TryLearningQuickSummary(entry)
        return VStack(alignment: .leading, spacing: 13) {
            Text(summary.goal).dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
                .lineLimit(3).lineSpacing(3)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(summary.phase).dboardFont(size: 10, weight: .medium)
                    Spacer()
                    if let number = summary.stageNumber, summary.stageCount > 0, entry.learningFinishedAt == nil {
                        Text("\(number) / \(summary.stageCount)").dboardFont(size: 10, design: .monospaced)
                    }
                }.foregroundStyle(theme.current.accentSecondary)
                Text(summary.current).dboardFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.current.textPrimary).lineLimit(2)
                if summary.stageCount > 0 {
                    HStack(spacing: 5) {
                        ForEach(0..<summary.stageCount, id: \.self) { index in
                            Capsule().fill(theme.current.accentPrimary.opacity(index < summary.masteredCount ? 0.8 : 0.13))
                        }
                    }.frame(height: 4).accessibilityHidden(true)
                    Text("已掌握 \(summary.masteredCount) / \(summary.stageCount) 阶段")
                        .dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                }
                Text(entry.hasDueLearningPractice ? "有复习题到期 · 打开详情继续" : summary.next)
                    .dboardFont(size: 11).foregroundStyle(theme.current.accentSecondary).lineLimit(2)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.current.accentPrimary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            if let config = entry.learningConfig, config.valid {
                HStack(spacing: 5) {
                    Text(Date(timeIntervalSince1970: config.deadline), format: .dateTime.month().day())
                    Text("截止")
                    Spacer()
                    Text(entry.learningFinishedAt != nil ? "本轮已结束" :
                        (config.overdue ? "已到期" : (config.daysLeft == 0 ? "今天到期" : "还剩 \(config.daysLeft) 天")))
                        .foregroundStyle(config.overdue && entry.learningFinishedAt == nil ? Color.orange : theme.current.accentSecondary)
                }.dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
            }
        }
    }

    private func ideaContent(_ entry: TryEntry) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if !entry.progress.isEmpty {
                Text(entry.progress).dboardFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.current.accentPrimary).lineLimit(2)
            }
            Text(preview(entry)).dboardFont(size: 13).foregroundStyle(.secondary).lineLimit(6).lineSpacing(3)
            if !entry.nextStep.isEmpty {
                Text(entry.nextStep).dboardFont(size: 12).foregroundStyle(theme.current.accentSecondary).lineLimit(2)
            }
        }
    }

    private func preview(_ entry: TryEntry) -> String {
        let text = entry.kind == .digestion ? entry.learningPreview : entry.body
        return DemandImageMarkdown.references(in: text).reduce(text) { $0.replacingOccurrences(of: $1.markdown, with: "〔图片〕") }
    }
}

private final class TryQuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Independent of the home's selection; opening a card never moves the whole home workspace.
final class TryQuickOpenWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSPanel?
    private(set) var model = TryQuickOpenModel()
    private let store: TryStore
    private let activates: Bool
    private let theme: ThemeManager
    private let copyHandoff: ((String) -> Bool)?
    private let focusReturn = PanelFocusReturn()
    private(set) var details: TryDetailWindowController
    private(set) var capture: TryCaptureWindowController
    private(set) var healthWindow: HealthWindowController
    private var monitor: Any?
    private var subscription: AnyCancellable?
    private var noticeHide: DispatchWorkItem?
    private var closing = false

    init(store: TryStore = .shared, activates: Bool = true, theme: ThemeManager = .shared, copyHandoff: ((String) -> Bool)? = nil) {
        self.store = store; self.activates = activates; self.theme = theme; self.copyHandoff = copyHandoff
        details = TryDetailWindowController(store: store, activates: activates, theme: theme)
        capture = TryCaptureWindowController(store: store, activates: activates, theme: theme)
        healthWindow = HealthWindowController(activates: activates, theme: theme)
    }
    func toggle() { if window?.isVisible == true { close() } else { show() } }
    func show() {
        guard window == nil else { return }
        store.reload()
        model.begin(store.document.entries)
        if activates { focusReturn.capture() }
        let panel = TryQuickPanel(contentRect: NSRect(x: activates ? 0 : -10000, y: 0, width: 452, height: 450),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.title = "次 Try"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = true; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]; panel.delegate = self
        panel.contentView = NSHostingView(rootView: TryQuickOpenView(model: model, store: store,
            open: { [weak self] in self?.open($0) }, create: { [weak self] in self?.create($0) }, openHealth: { [weak self] in self?.openHealth() }).environmentObject(theme))
        window = panel
        subscription = store.$document.receive(on: RunLoop.main).sink { [weak self] in self?.model.update($0.entries) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event)
        }
        if activates {
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                DemandWindowPlacement.center(panel, in: screen.visibleFrame)
            }
            panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } else { panel.orderBack(nil) }
    }
    @discardableResult
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.isVisible == true else { return event }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .command && event.charactersIgnoringModifiers?.lowercased() == "c" {
            let handoff = model.scope == .health ? HealthStore.shared.summary() : model.selectedID.flatMap { store.handoff($0) }
            if let handoff {
                let success: Bool
                if let copyHandoff { success = copyHandoff(handoff) }
                else {
                    NSPasteboard.general.clearContents()
                    success = NSPasteboard.general.setString(handoff, forType: .string)
                }
                model.copyNotice = success ? "已复制，交给 AI 继续" : "复制失败，请重试"
            } else { model.copyNotice = "这里还没有可复制的记录" }
            noticeHide?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.model.copyNotice = nil }
            noticeHide = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
            return nil
        }
        if event.characters == "+", mods.intersection([.command, .control, .option]).isEmpty {
            if model.scope == .health { openHealth() } else { create(model.scope.entryKind ?? .digestion) }
            return nil
        }
        guard mods.isEmpty else { return event }
        switch event.keyCode {
        case 123: model.moveScope(-1); return nil
        case 124: model.moveScope(1); return nil
        case 125: model.move(1); return nil
        case 126: model.move(-1); return nil
        case 36, 76:
            if model.scope == .health { openHealth() } else if let id = model.selectedID { open(id) }
            return nil
        case 53: close(); return nil
        case 48: return nil
        default: return event
        }
    }
    func openHealth() {
        let center = window?.screen?.visibleFrame
        close(restoreFocus: false)
        healthWindow.show(centerIn: center)
    }
    func open(_ id: String) {
        guard store.entry(id) != nil, store.flush() else { model.update(store.document.entries); return }
        let center = window?.screen?.visibleFrame
        close(restoreFocus: false)
        details.show(id, centerIn: center)
    }
    func create(_ kind: TryKind) {
        guard store.flush() else { return }
        let center = window?.screen?.visibleFrame
        close(restoreFocus: false)
        capture.show(kind, centerIn: center)
    }
    func close(restoreFocus: Bool = true) {
        guard let window, !closing else { return }
        closing = true; window.close(); closing = false
        if activates && restoreFocus { focusReturn.restore() } else { focusReturn.discard() }
    }
    func windowDidResignKey(_ notification: Notification) { close(restoreFocus: false) }
    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        subscription = nil; noticeHide?.cancel(); noticeHide = nil; window = nil
    }
}
