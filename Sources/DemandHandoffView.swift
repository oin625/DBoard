import SwiftUI

struct DemandHandoffDraft: Codable {
    var text: String
    let expected: String
    private static let key = "dboard.handoffNoteDrafts.v1"
    static func load(defaults: UserDefaults = .standard) -> [String: Self] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Self].self, from: data)) ?? [:]
    }
    static func persist(_ drafts: [String: Self], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(drafts) { defaults.set(data, forKey: key) }
    }
}

extension DBoardViewModel {
    func editHandoffNotes(_ item: DItem, text: String) {
        var draft = handoffDrafts[item.id] ?? DemandHandoffDraft(text: item.handoffNotes, expected: item.handoffNotes)
        draft.text = text
        handoffDrafts[item.id] = draft
        handoffSaveWork[item.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.saveHandoffNotes(item.id) }
        handoffSaveWork[item.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    @discardableResult
    func saveHandoffNotes(_ id: String) -> Bool {
        handoffSaveWork.removeValue(forKey: id)?.cancel()
        guard let draft = handoffDrafts[id] else { return true }
        guard draft.text.trimmed != draft.expected else { handoffDrafts[id] = nil; return true }
        guard DItemStore.saveHandoffNotes(id: id, text: draft.text, expected: draft.expected) else {
            showFeedback("交接补充未保存，草稿已保留；请核对是否有并发修改", failed: true)
            return false
        }
        handoffDrafts[id] = nil
        markSelfWrite(); reload()
        return true
    }
}

struct DemandHandoffView: View {
    @EnvironmentObject var vm: DBoardViewModel
    let item: DItem
    @State private var expanded = false
    @State private var editing = false
    private var notes: String { vm.handoffDrafts[item.id]?.text ?? item.handoffNotes }

    init(item: DItem, initiallyExpanded: Bool = false) {
        self.item = item
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "text.alignleft")
                        Text("交接摘要").font(.system(size: 13, weight: .semibold))
                        if let summary = item.handoff {
                            Text("覆盖\(summary.covered_count)条").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(minHeight: 28).contentShape(Rectangle())
                }.demandButtonStyle(.plain).accessibilityIdentifier("handoff-section-" + item.id).demandKeyboardID("handoff-section-" + item.id)
                Spacer()
                if expanded && item.status != .completed {
                    Button(editing ? "完成" : "补充或纠正") {
                        if editing { if vm.saveHandoffNotes(item.id) { editing = false } }
                        else { editing = true }
                    }.controlSize(.small)
                }
            }
            if expanded {
                if let error = item.handoffReadError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                } else if let summary = item.handoff {
                    section("已完成", summary.sections.completed)
                    section("待做与阻塞", summary.sections.pending)
                    section("关键决定", summary.sections.decisions)
                    section("验证与追溯", summary.sections.verification)
                    if let resources = summary.resources, !resources.isEmpty {
                        ForEach(Array(resources.enumerated()), id: \.offset) { _, resource in
                            section(resource.topic, resource.when_to_read + "\n" + resource.source)
                        }
                    }
                    if !summary.references.isEmpty { section("其他资料入口", summary.references.joined(separator: "\n")) }
                    Text("最近判断：\(summary.last_decision.decision == "compact" ? "已整体整理" : "暂不整体整理") · \(summary.last_decision.reason)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("更新：\(summary.updated_at) · 最新变更和代码核验优先")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("尚无摘要，AI 接手读取历史后会整理；完整记录仍保留。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if editing {
                    Text("仅补充或纠正交接事实；新增业务要求请使用追加变更。自动保存。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { notes }, set: { vm.editHandoffNotes(item, text: $0) }))
                        .font(.system(size: 12)).scrollContentBackground(.hidden)
                        .frame(minHeight: 70, maxHeight: 140).padding(6)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel(item.id + " 交接补充")
                } else if !notes.isEmpty { section("你的补充或纠正", notes) }
            }
        }.padding(.vertical, 6)
            .onAppear { if vm.handoffDrafts[item.id] != nil { expanded = true; editing = true } }
            .onDisappear { _ = vm.saveHandoffNotes(item.id) }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(text.isEmpty ? "未记录" : text).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
