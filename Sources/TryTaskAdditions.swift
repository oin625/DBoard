import SwiftUI
import AppKit

struct TryTaskAdditionsView: View {
    @ObservedObject var store: TryStore
    let id: String
    @Binding var composing: Bool
    let presentationRequest: Int
    let revealComposer: (@escaping () -> Void) -> Void
    let didSave: (String) -> Void
    let notify: (String) -> Void
    @State private var historyExpanded = false
    @State private var withdrawing: TryAddition?
    @EnvironmentObject private var theme: ThemeManager

    static func composerAnchor(_ taskID: String) -> String { taskID + "-addition-composer" }
    static func rowAnchor(_ taskID: String, _ additionID: String) -> String { taskID + "-addition-row-" + additionID }

    private var additions: [TryAddition] { store.entry(id)?.additions ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("追加内容").dboardFont(size: 12, weight: .medium)
                if additions.contains(where: \.pending) {
                    Text(String(additions.filter(\.pending).count) + " 项待处理")
                        .dboardFont(size: 11).foregroundStyle(theme.current.accentPrimary)
                }
                Spacer()
                if !composing && store.entry(id)?.kind == .task {
                    Button(store.additionDraft(id).isEmpty ? "再追加" : "继续草稿") { composing = true }
                        .demandButtonStyle(TryControlStyle()).dboardFont(size: 11)
                }
            }
            if composing {
                TryAdditionComposer(store: store, id: id,
                    presentationRequest: presentationRequest, reveal: revealComposer,
                    close: { composing = false }, saved: { additionID, copied in
                        composing = false
                        didSave(additionID)
                        notify(copied ? "已保存并复制，交给 AI 继续" : "已保存追加内容")
                    })
                    .id(Self.composerAnchor(id))
            } else if !store.additionDraft(id).isEmpty {
                Button("继续未保存的追加草稿") { composing = true }
                    .demandButtonStyle(TryControlStyle(fillWidth: true)).foregroundStyle(theme.current.accentPrimary)
            }
            ForEach(additions.filter(\.pending).reversed()) { addition in
                row(addition)
            }
            let processed = additions.filter { !$0.pending }
            if !processed.isEmpty {
                DisclosureGroup(isExpanded: $historyExpanded) {
                    ForEach(processed.reversed()) { addition in row(addition) }
                        .padding(.top, 8)
                } label: {
                    Text("已处理与已撤回 · " + String(processed.count)).dboardFont(size: 12).foregroundStyle(.secondary)
                }.demandKeyboardID("try-addition-history")
            }
        }
        .padding(18).workspaceSurface(radius: 16)
        .alert("撤回这次追加？", isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } })) {
            Button("撤回", role: .destructive) {
                if let addition = withdrawing { _ = store.withdrawAddition(id, additionID: addition.id) }
                withdrawing = nil
            }
            Button("取消", role: .cancel) { withdrawing = nil }
        } message: { Text("保留记录，AI 将不再把它当作待处理内容。") }
    }

    private func row(_ addition: TryAddition) -> some View {
        HStack(alignment: .top, spacing: 4) {
            DisclosureGroup {
                DemandSpellContentView(text: addition.body).padding(.top, 8)
                if let summary = addition.completionSummary, addition.completedAt != nil {
                    Text(summary).dboardFont(size: 12).foregroundStyle(.secondary).padding(.top, 8)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(addition.preview).dboardFont(size: 13).lineLimit(2)
                    Text(addition.withdrawnAt != nil ? "已撤回" : (addition.pending ? "待处理" : "已处理"))
                        .dboardFont(size: 10).foregroundStyle(addition.pending ? theme.current.accentPrimary : theme.current.textSecondary)
                }
            }.demandKeyboardID("try-addition-" + addition.id)
            if addition.withdrawnAt == nil {
                Menu {
                    Button("编辑这次追加") {
                        if store.prepareAddition(id, editing: addition.id) { composing = true }
                    }
                    Button(addition.pending ? "确认已处理" : "恢复待处理") {
                        _ = store.markAddition(id, additionID: addition.id, completed: addition.pending)
                    }
                    Button("撤回追加", role: .destructive) { withdrawing = addition }
                } label: { Image(systemName: "ellipsis") }
                    .demandMenuStyle(TryMenuStyle()).menuIndicator(.hidden)
                    .accessibilityLabel("操作这次追加").demandKeyboardID("try-addition-menu-" + addition.id)
            }
        }
        .id(Self.rowAnchor(id, addition.id))
    }
}

struct TryAdditionComposer: View {
    @ObservedObject var store: TryStore
    let id: String
    let presentationRequest: Int
    let reveal: (@escaping () -> Void) -> Void
    let close: () -> Void
    let saved: (String, Bool) -> Void
    @State private var presented = false
    @State private var editing = true
    @State private var clearConfirmation = false
    @StateObject private var controller = TryNoteController()
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        let generation = store.additionGeneration(id)
        let draft = store.additionDraft(id)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.editingID == nil ? "这次新增或调整什么" : "编辑这次追加")
                    .dboardFont(size: 13, weight: .medium)
                Spacer()
                Button {
                    controller.end()
                    if store.flush() { close() }
                } label: { Image(systemName: "xmark") }
                    .demandButtonStyle(TryControlStyle()).accessibilityLabel("关闭并保留追加草稿")
                    .demandKeyboardID("try-addition-close")
            }
            TryNoteEditor(text: Binding(get: { store.additionDraft(id).body }, set: {
                store.editAdditionDraft(id, body: $0, generation: generation)
            }), editing: $editing, bookmark: draft.bookmark, minimumHeight: 120, maximumHeight: 360,
                autofocus: false, controller: controller,
                onBookmark: { store.rememberAddition(id, bookmark: $0, generation: generation) },
                onEnd: { _ = store.flush() })
                .id(id + "-addition-" + String(generation))
                .overlay(alignment: .topLeading) {
                    if draft.body.isEmpty {
                        Text("写新增功能、调整或遇到的问题，也可以直接贴图…")
                            .dboardFont(size: 14).foregroundStyle(.secondary)
                            .padding(.top, 8).allowsHitTesting(false)
                    }
                }
            HStack {
                Button { editing = true; controller.images() } label: { Image(systemName: "photo") }
                    .demandButtonStyle(TryControlStyle()).accessibilityLabel("添加图片")
                Spacer()
                if !draft.isEmpty {
                    Button("清空草稿") { clearConfirmation = true }
                        .demandButtonStyle(TryControlStyle()).dboardFont(size: 11).foregroundStyle(.secondary)
                }
            }
            if store.entry(id)?.status != .active {
                Text("保存后将恢复任务继续处理，已有成果保留。").dboardFont(size: 11).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(saveTitle) { save(copy: false) }
                    .demandButtonStyle(WorkspaceActionStyle()).disabled(draft.isEmpty)
                    .demandKeyboardID("try-addition-save")
                Button("保存并复制") { save(copy: true) }
                    .demandButtonStyle(WorkspaceActionStyle(prominent: true)).disabled(draft.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command).demandKeyboardID("try-addition-save-copy")
            }
            if let error = controller.error ?? store.error {
                Text(error).dboardFont(size: 12).foregroundStyle(.orange)
            }
        }
        .padding(16).workspaceSurface(radius: 12)
        .alert("清空未保存的追加草稿？", isPresented: $clearConfirmation) {
            Button("清空", role: .destructive) {
                controller.end()
                if store.clearAdditionDraft(id) { close() }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            presented = true
            reveal { if presented { controller.focus() } }
        }
        .onChange(of: presentationRequest) { _, _ in
            reveal { if presented { controller.focus() } }
        }
        .onDisappear { presented = false; controller.end(); _ = store.flush() }
    }

    private var saveTitle: String {
        if store.entry(id)?.status != .active { return "保存并继续任务" }
        return store.additionDraft(id).editingID == nil ? "保存追加" : "保存修改"
    }
    private func save(copy: Bool) {
        controller.end()
        guard let additionID = store.submitAddition(id) else { return }
        var copied = false
        if copy, let command = store.handoff(id) {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(command, forType: .string)
        }
        saved(additionID, copied)
    }
}
