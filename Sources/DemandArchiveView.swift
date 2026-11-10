import SwiftUI
import AppKit

struct DemandArchiveSection: View {
    @EnvironmentObject var vm: DBoardViewModel
    @ObservedObject var store: DemandArchiveStore
    var filteredRecords: [ArchivedDemand]? = nil
    var currentItems: [DItem] = []
    var embedded = false
    var collapsible = false
    @State private var sectionExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var historyExpanded: Set<String> = []
    @State private var reviewExpanded: Set<String> = []
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var selection: VersionSelection?
    @State private var restoring: ArchivedDemand?

    private struct VersionSelection: Identifiable {
        let record: ArchivedDemand
        let draft: DItemDraft
        var id: String { record.id }
    }

    private var visible: [ArchivedDemand] {
        if let filteredRecords { return filteredRecords }
        return store.records.filter { DemandSearch.matches($0.item, query: query) }
    }

    private var completedEntries: [CompletedDemandEntry] {
        DemandCompletedCatalog.entries(current: currentItems.filter { DemandSearch.matches($0, query: query) }, archived: visible)
    }

    private func successor(_ record: ArchivedDemand) -> DItem? {
        vm.items.first { $0.version?.sourceRevision == record.id } ??
            store.records.first { $0.item.version?.sourceRevision == record.id }?.item
    }

    private func openSuccessor(_ item: DItem) {
        if vm.items.contains(where: { $0.id == item.id }) { vm.focusItem(item.id) }
        else {
            if embedded, let archived = store.records.first(where: { $0.item.id == item.id }) { vm.focusArchive(archived) }
            else {
                query = item.id
                if let archived = store.records.first(where: { $0.item.id == item.id }) { expanded.insert(archived.id) }
            }
        }
    }

    private func begin(_ record: ArchivedDemand) {
        if let next = successor(record) { openSuccessor(next); return }
        do { selection = VersionSelection(record: record, draft: try record.newDraft(id: DItemStore.nextID(reserving: store.records.map { $0.item.id }, kind: record.item.kind))) }
        catch { vm.flash(error.localizedDescription) }
    }

    private func restore(_ record: ArchivedDemand) {
        guard store.records.contains(where: { $0.id == record.id }) else {
            vm.flash("归档记录已变化，请重新打开"); return
        }
        if vm.afterWrite(DItemStore.reopenArchive(record), fail: "恢复失败：原编号或需求流关联已被占用，或归档数据无法读取",
                         success: "已恢复继续处理 " + record.item.id) {
            vm.focusItem(record.item.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if collapsible {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { sectionExpanded.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Label("已完成", systemImage: "checkmark.circle").font(.system(size: 15, weight: .semibold))
                            Text("\(completedEntries.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                            Image(systemName: sectionExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 28).contentShape(Rectangle())
                    }.demandButtonStyle(.plain)
                        .accessibilityLabel("\(sectionExpanded ? "收起" : "展开")已完成，\(completedEntries.count)项")
                        .accessibilityIdentifier("completed-section-toggle").demandKeyboardID("completed-section-toggle")
                } else {
                    Label("已完成", systemImage: "checkmark.circle").font(.system(size: 15, weight: .semibold))
                    Text("\(completedEntries.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.loading)
                if let node = DItemStore.archiveNodeID {
                    Button("打开已完成文档") {
                        if let url = URL(string: "https://alidocs.dingtalk.com/i/nodes/" + node) { NSWorkspace.shared.open(url) }
                    }.font(.system(size: 12))
                }
            }
            if !embedded {
                Text("开启新版本会保留旧版，自动带入背景；需要继续处理时可恢复原编号。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("搜索已完成需求编号 / 名称 / 项目", text: $query).textFieldStyle(.roundedBorder)
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            if !embedded, let date = store.readAt {
                Text("历史读取：\(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !collapsible || sectionExpanded {
                if completedEntries.isEmpty {
                    Text(store.loading ? "正在读取已完成需求…" : (query.isEmpty ? "暂无可读取的已完成需求" : "没有匹配的已完成需求"))
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(completedEntries) { entry in row(entry).id(entry.selectionID) }
                }
            }
        }
        .padding(16)
        .onAppear {
            store.reloadLocal()
            if !embedded { store.refresh() }
            revealSelection()
        }
        .onChange(of: vm.selectedID) { _, _ in revealSelection() }
        .onChange(of: collapsible) { _, canCollapse in
            if canCollapse { sectionExpanded = false }
        }
        .sheet(item: $selection) { selection in
            NewDemandVersionForm(record: selection.record, draft: selection.draft, cancel: { self.selection = nil },
                create: { draft in
                    guard store.records.contains(where: { $0.id == selection.record.id }),
                          successor(selection.record) == nil else {
                        vm.flash("该归档已有后续版本或记录已变化，请重新打开"); return false
                    }
                    guard vm.createItem(draft) else { return false }
                    self.selection = nil
                    return true
                }).environmentObject(vm)
        }
        .alert("恢复原需求继续处理？", isPresented: Binding(
            get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("取消", role: .cancel) { restoring = nil }
            Button("恢复继续处理") { if let record = restoring { restore(record) }; restoring = nil }
        } message: {
            Text("恢复原编号、咒言和进度为进行中，周期从今天重新开始。已完成的快照保留作历史记录。")
        }
    }

    private func revealSelection() {
        guard let id = vm.selectedID, let entry = completedEntries.first(where: { $0.selectionID == id }) else { return }
        sectionExpanded = true
        if entry.archive != nil { expanded.insert(id) }
        else { vm.expandedIDs.insert(entry.item.id) }
    }

    private func row(_ entry: CompletedDemandEntry) -> some View {
        let item = entry.item
        let record = entry.archive
        let active = vm.items.first { $0.id == item.id }
        let next = record.flatMap { successor($0) }
        let isExpanded = record == nil ? vm.expandedIDs.contains(item.id) : expanded.contains(entry.selectionID)
        let cacheURL: URL? = record == nil ? nil : store.cacheURL
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if record == nil { vm.toggleExpanded(item.id) }
                else if isExpanded { expanded.remove(entry.selectionID) }
                else { expanded.insert(entry.selectionID) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    Text(item.displayTitle).font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                    Text("已完成").font(.system(size: 11)).foregroundStyle(.green)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(minHeight: 26).contentShape(Rectangle())
            }.demandButtonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "收起" : "展开") \(item.id) \(item.displayTitle)")
                .accessibilityIdentifier("completed-toggle-" + item.id).demandKeyboardID("completed-toggle-" + item.id)
            HStack(spacing: 8) {
                Text(item.kind.rawValue).font(.system(size: 11))
                    .foregroundStyle(item.isIncident ? Color.orange : .secondary)
                if !item.project.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(item.project).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let day = entry.completionDay {
                    Text(day).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !item.reminder.isEmpty {
                Text(item.reminder).font(.system(size: 12)).foregroundStyle(DemandReminder.color)
                    .lineLimit(1).textSelection(.enabled)
            }
            if item.isIncident, let closure = item.incidentClosure, !isExpanded {
                Text(closure.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            WorkspaceFlowLayout {
                completedActions(item: item, record: record, active: active, next: next, cacheURL: cacheURL)
            }.demandButtonStyle(WorkspaceActionStyle())
            if let record, let review = store.reviewNotes.last(where: { $0.itemID == item.id && $0.sourceRevision == record.id }) {
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        if reviewExpanded.contains(review.id) { reviewExpanded.remove(review.id) }
                        else { reviewExpanded.insert(review.id) }
                    } label: {
                        Label(review.summary, systemImage: reviewExpanded.contains(review.id) ? "chevron.down" : "checkmark.bubble")
                            .font(.system(size: 12)).multilineTextAlignment(.leading)
                    }.demandButtonStyle(.plain).foregroundStyle(.secondary)
                    if reviewExpanded.contains(review.id) {
                        Text(review.details).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
            }
            if isExpanded {
                if record == nil { DemandContextView(item: item) }
                if let error = item.changeReadError ?? item.versionReadError ?? item.chatReadError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                }
                IncidentResultView(item: item)
                if !item.title.isEmpty && item.title != "（待补充）" && item.title != item.displayTitle {
                    if item.isIncident { DemandSpellContentView(text: item.title) }
                    else { Text(item.title).font(.system(size: 13)).textSelection(.enabled) }
                }
                if let branch = item.branch, !branch.isEmpty {
                    Text("完成时分支：" + branch).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let record {
                    ForEach(Array(DemandVersion.archiveNotes(record.block).enumerated()), id: \.offset) { _, note in
                        Text(note).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let chats = item.chatLinks {
                    Label(chats.summary, systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                let spell = DemandPromptSections(stored: item.prompt).assembled
                if !spell.isEmpty {
                    DisclosureGroup("原咒言") { DemandSpellContentView(text: spell) }
                }
                if !item.changes.isEmpty {
                    DisclosureGroup("追加变更 \(item.changes.count) 条") {
                        ForEach(item.changes) { change in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(change.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                DemandSpellContentView(text: change.intent)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                if record == nil {
                    IncidentExperienceView(item: item)
                    DemandHandoffView(item: item)
                    if !item.isIncident || item.execution != nil { DemandDebuggingView(item: item) }
                } else if let page = item.execution?.debugPage {
                    Text("调试页：audi · " + page).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !item.releaseChecklist.items.isEmpty || item.releaseChecklistReadError != nil {
                    DemandReleaseChecklistView(item: item, readOnly: true)
                }
                DemandWorktreesSection(item: item, cacheURL: cacheURL ?? URL(fileURLWithPath: CacheFile.path))
                DemandProgressHistoryView(milestones: item.milestones, expanded: Binding(
                    get: { historyExpanded.contains(entry.selectionID) },
                    set: { if $0 { historyExpanded.insert(entry.selectionID) } else { historyExpanded.remove(entry.selectionID) } }))
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
        .accessibilityIdentifier("completed-card-" + item.id).demandKeyboardID("completed-card-" + item.id)
    }

    @ViewBuilder
    private func completedActions(item: DItem, record: ArchivedDemand?, active: DItem?,
                                  next: DItem?, cacheURL: URL?) -> some View {
        Button("复制现状", systemImage: "doc.on.doc") { vm.copyCurrentState(item.id, at: cacheURL) }
            .font(.system(size: 12)).accessibilityIdentifier("completed-copy-" + item.id)
        Button("代码审查", systemImage: "checkmark.bubble") { vm.copyReviewTask(item.id, at: cacheURL) }
            .font(.system(size: 12))
            .accessibilityIdentifier("archive-review-copy-" + item.id).demandKeyboardID("archive-review-copy-" + item.id)
        if record == nil, let active {
            if active.isIncident {
                Button("恢复排查") { vm.reopenIncident(active) }.font(.system(size: 12))
                    .accessibilityIdentifier("completed-reopen-" + item.id).demandKeyboardID("completed-reopen-" + item.id)
            } else {
                Button("恢复继续处理") { vm.cycleToStatus(active.id, target: .inProgress) }
                    .font(.system(size: 12)).accessibilityIdentifier("completed-reopen-" + item.id)
            }
            Button(item.isIncident ? "编辑排查" : "编辑需求") { vm.openDemandEditor(.details, item: active) }
                .font(.system(size: 12))
        } else if let active {
            Button((active.status == .completed ? "已完成 · 打开 " : "正在处理 · 打开 ") + active.id) { vm.focusItem(active.id) }
                .font(.system(size: 12))
        } else if let record {
            if let next {
                Button("已开启 " + next.id) { openSuccessor(next) }.font(.system(size: 12))
            } else {
                Button("开启 " + String((item.version?.number ?? 1) + 1) + ".0") { begin(record) }
                    .font(.system(size: 12)).disabled(item.changeReadError != nil || item.versionReadError != nil)
            }
            Button("恢复继续处理") { restoring = record }.font(.system(size: 12))
                .disabled(item.changeReadError != nil || item.versionReadError != nil)
                .accessibilityIdentifier("completed-reopen-" + item.id).demandKeyboardID("completed-reopen-" + item.id)
        }
    }

}

struct NewDemandVersionForm: View {
    @EnvironmentObject var vm: DBoardViewModel
    let record: ArchivedDemand
    @State var draft: DItemDraft
    let cancel: () -> Void
    let create: (DItemDraft) -> Bool
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("开启 " + (draft.version?.label ?? "新版本"), systemImage: "arrow.triangle.branch")
                .font(.system(size: 16, weight: .semibold))
            Text("基于 " + record.item.id + "「" + record.item.displayTitle + "」，使用新编号 " + draft.id)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("新版本名称", text: $draft.name).textFieldStyle(.roundedBorder)
            Text("上一版咒言、仓库、分支和进度已作为背景保存。只写本次改动；代码入口和资料可直接修改。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView { DemandPromptFields(sections: $draft.promptSections) }
            HStack {
                Spacer()
                Button("取消", action: requestClose).keyboardShortcut(.cancelAction)
                Button("创建新版本") { _ = create(draft) }
                    .disabled(draft.name.trimmed.isEmpty || draft.promptSections.intent.trimmed.isEmpty || draft.validationError != nil)
                    .demandButtonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 640, maxWidth: 800, minHeight: 480, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(changed)
        .onExitCommand(perform: requestClose)
        .alert("放弃未保存的新版本？", isPresented: $confirmingDiscard) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改", role: .destructive, action: cancel)
        }
        .onAppear { vm.editingFormCount += 1 }
        .onDisappear { vm.editingFormCount = max(0, vm.editingFormCount - 1) }
    }

    private var changed: Bool {
        guard let initial = try? record.newDraft(id: draft.id) else { return true }
        return draft.name != initial.name || draft.prompt != initial.prompt
    }

    private func requestClose() {
        if changed { confirmingDiscard = true } else { cancel() }
    }
}
