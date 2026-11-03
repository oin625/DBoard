import SwiftUI
import AppKit

struct DemandArchiveSection: View {
    @EnvironmentObject var vm: DBoardViewModel
    @ObservedObject var store: DemandArchiveStore
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
        let query = query.trimmed.lowercased()
        return store.records.filter {
            query.isEmpty || [$0.item.id, $0.item.displayTitle, $0.item.project].contains { $0.lowercased().contains(query) }
        }
    }

    private func successor(_ record: ArchivedDemand) -> DItem? {
        vm.items.first { $0.version?.sourceRevision == record.id } ??
            store.records.first { $0.item.version?.sourceRevision == record.id }?.item
    }

    private func openSuccessor(_ item: DItem) {
        if vm.items.contains(where: { $0.id == item.id }) { vm.focusItem(item.id) }
        else {
            query = item.id
            if let archived = store.records.first(where: { $0.item.id == item.id }) { expanded.insert(archived.id) }
        }
    }

    private func begin(_ record: ArchivedDemand) {
        if let next = successor(record) { openSuccessor(next); return }
        do { selection = VersionSelection(record: record, draft: try record.newDraft(id: DItemStore.nextID(reserving: store.records.map { $0.item.id }))) }
        catch { vm.flash(error.localizedDescription) }
    }

    private func restore(_ record: ArchivedDemand) {
        guard store.records.contains(where: { $0.id == record.id }) else {
            vm.flash("归档记录已变化，请重新打开"); return
        }
        if vm.afterWrite(DItemStore.reopenArchive(record), fail: "恢复失败：原编号或需求流关联已被占用，或归档数据无法读取",
                         success: "已撤销归档，恢复 " + record.item.id) {
            vm.focusItem(record.item.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("归档需求", systemImage: "archivebox").font(.system(size: 15, weight: .semibold))
                Text("\(store.records.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新钉钉归档").disabled(store.loading)
                if let node = DItemStore.archiveNodeID {
                    Button("打开归档文档") {
                        if let url = URL(string: "https://alidocs.dingtalk.com/i/nodes/" + node) { NSWorkspace.shared.open(url) }
                    }.font(.system(size: 12))
                }
            }
            Text("开启新版本会保留旧版，自动带入背景；误归档可恢复原编号。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("搜索归档需求编号 / 名称 / 项目", text: $query).textFieldStyle(.roundedBorder)
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            if let date = store.readAt {
                Text("归档读取：\(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if visible.isEmpty {
                Text(store.loading ? "正在读取归档需求…" : (query.isEmpty ? "暂无可读取的归档需求" : "没有匹配的归档需求"))
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(visible) { record in row(record) }
            }
        }
        .padding(16)
        .onAppear { store.reloadLocal(); store.refresh() }
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
        .alert("撤销归档，恢复原需求？", isPresented: Binding(
            get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("取消", role: .cancel) { restoring = nil }
            Button("恢复继续处理") { if let record = restoring { restore(record) }; restoring = nil }
        } message: {
            Text("恢复原编号、咒言和进度为进行中，周期从今天重新开始。归档快照保留作历史记录。")
        }
    }

    private func row(_ record: ArchivedDemand) -> some View {
        let item = record.item
        let active = vm.items.first { $0.id == item.id }
        let next = successor(record)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    Text(item.displayTitle).font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                    Image(systemName: expanded.contains(record.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                Text(item.project.isEmpty ? "已归档" : item.project).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let active {
                    Button("已恢复 · 打开 " + active.id) { vm.focusItem(active.id) }.font(.system(size: 12))
                } else {
                    if let next {
                        Button("已开启 " + next.id) { openSuccessor(next) }.font(.system(size: 12))
                    } else {
                        Button("开启 " + String((item.version?.number ?? 1) + 1) + ".0") { begin(record) }
                            .font(.system(size: 12))
                            .disabled(item.changeReadError != nil || item.versionReadError != nil)
                    }
                    Button("撤销归档") { restoring = record }.font(.system(size: 12))
                        .disabled(item.changeReadError != nil || item.versionReadError != nil)
                }
            }
            if expanded.contains(record.id) {
                if let date = record.completedDate { Text("归档完成：" + date).font(.system(size: 11)).foregroundStyle(.secondary) }
                if let error = item.changeReadError ?? item.versionReadError ?? item.chatReadError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                }
                if !item.title.isEmpty && item.title != "（待补充）" {
                    Text(item.title).font(.system(size: 13)).textSelection(.enabled)
                }
                if let branch = item.branch, !branch.isEmpty {
                    Text("归档时分支：" + branch).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(Array(DemandVersion.archiveNotes(record.block).enumerated()), id: \.offset) { _, note in
                    Text(note).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let chats = item.chatLinks {
                    Label(chats.summary, systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                let spell = DemandPromptSections(stored: item.prompt).assembled
                if !spell.isEmpty {
                    DisclosureGroup("原咒言") { DemandSpellContentView(text: spell) }
                }
                ForEach(Array(item.milestones.enumerated()), id: \.offset) { _, milestone in
                    DemandProgressRow(record: milestone)
                }
            }
        }
        .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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
                    .buttonStyle(.borderedProminent)
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
