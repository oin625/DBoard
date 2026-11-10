import SwiftUI
import AppKit

struct DemandCardEditor: Identifiable {
    enum Kind: String { case inspect, details, prompt, changes, chats, technicalPlan, delivery }
    let kind: Kind
    let item: DItem
    var deliveryPlan: DemandDeliveryPlan? = nil
    var id: String { item.id + ":" + kind.rawValue }
}

/// A stable sheet keeps the underlying demand card and scroll position intact.
struct DemandItemEditor: View {
    @EnvironmentObject private var vm: DBoardViewModel
    let original: DItem?
    let close: () -> Void
    @State private var draft: DItemDraft
    @State private var confirmingDiscard = false
    @State private var saveError: String?
    @State private var pendingDismissal: (() -> Void)?

    init(draft: DItemDraft, original: DItem? = nil, close: @escaping () -> Void) {
        self.original = original
        self.close = close
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { original == nil }
    private var changed: Bool { original.map { DItemDraft(from: $0) != draft } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: isNew ? "plus" : "pencil")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNew ? (draft.isIncident ? "新增线上排查" : "新增需求") : (draft.isIncident ? "编辑排查" : "编辑需求"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(isNew ? "先记下要做什么，其他信息可以稍后补充。" : "更新需求信息和关联资料。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(draft.id).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.45), in: Capsule())
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
            ScrollView {
                DItemEditForm(draft: draft, isNew: isNew, onSave: { _ in save() }, onCancel: requestClose,
                    onDraftChange: { value in
                        let previousID = draft.id
                        draft = value
                        if isNew { vm.updateNewItemDraft(value, previousID: previousID) }
                    }, showsActions: false)
                    .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = saveError ?? (isNew ? vm.newItemDraftError : nil) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                if isNew {
                    Label("草稿自动保存", systemImage: "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isNew ? "关闭" : "取消", action: requestClose)
                    .demandButtonStyle(WorkspaceActionStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("demand-editor-close").demandKeyboardID("demand-editor-close")
                Button(isNew ? (draft.isIncident ? "创建排查" : "创建需求") : "保存修改", action: save)
                    .demandButtonStyle(WorkspaceActionStyle(prominent: true)).keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.validationError != nil)
                    .accessibilityIdentifier("demand-editor-save").demandKeyboardID("demand-editor-save")
            }
            .padding(.horizontal, 24).padding(.vertical, 16).background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(minWidth: 540, idealWidth: 660, maxWidth: 900, minHeight: 560, idealHeight: 740)
        .background { DemandCanvasBackground() }
        .alert("放弃未保存的修改？", isPresented: $confirmingDiscard) {
            Button("继续编辑", role: .cancel) { pendingDismissal = nil }
            Button("放弃修改", role: .destructive) {
                let finish = pendingDismissal ?? close
                pendingDismissal = nil
                vm.demandEditorDismissal = nil
                finish()
            }
        } message: { Text("已保存的需求保留，本次尚未保存的修改会被清除。") }
        .onAppear { updateDismissal() }
        .onChange(of: draft) { _, _ in updateDismissal() }
        .onDisappear { if !isNew && vm.demandEditorInWindow { vm.demandEditorDismissal = nil } }
    }

    private func updateDismissal() {
        guard vm.demandEditorInWindow, !isNew else { return }
        vm.demandEditorDismissal = changed ? { finish in
            pendingDismissal = finish
            confirmingDiscard = true
        } : nil
    }

    private func requestClose() {
        if isNew { vm.updateNewItemDraft(draft); close() }
        else if changed { confirmingDiscard = true }
        else { close() }
    }

    private func save() {
        if isNew {
            vm.updateNewItemDraft(draft)
            if vm.createItem(draft) { vm.finishNewItemDraft(); close() }
            else { saveError = "创建失败，草稿已保留；请检查输入后重试。" }
        } else if let original {
            guard changed else { close(); return }
            if vm.saveItem(draft, original: original) {
                vm.demandEditorDismissal = nil
                close()
            }
            else { saveError = "保存失败，输入仍保留；需求可能已被其他操作更新，请核对后重试。" }
        }
    }
}

struct DemandChatAssociationEditor: View {
    @EnvironmentObject private var vm: DBoardViewModel
    let item: DItem
    let close: () -> Void
    @State private var error: String?

    var body: some View {
        DemandChatPicker(links: item.chatLinks ?? DemandChatLinks(), feedbackError: error, confirm: { links in
            guard links.optional != item.chatLinks else { close(); return }
            var draft = DItemDraft(from: item)
            draft.chatLinks = links.optional
            if vm.saveItem(draft, original: item) { close() }
            else { error = "关联未保存，选择仍保留；群聊信息可能已变化，请核对后重试。" }
        }, cancel: close)
        .onAppear { vm.editingFormCount += 1 }
        .onDisappear { vm.editingFormCount = max(0, vm.editingFormCount - 1) }
    }
}

private struct DemandEditorPresentation: ViewModifier {
    @EnvironmentObject private var vm: DBoardViewModel
    @EnvironmentObject private var theme: ThemeManager
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .sheet(item: Binding(
                    get: { vm.demandEditorInWindow ? nil : vm.demandEditor },
                    set: { if !vm.demandEditorInWindow { vm.demandEditor = $0 } }
                )) { request in
                    DemandEditorContent(request: request, close: { vm.demandEditor = nil })
                        .environmentObject(vm).environmentObject(theme).environmentObject(FontManager.shared)
                }
                .sheet(isPresented: $vm.showingKnowledge) {
                    DemandKnowledgeView(close: { vm.showingKnowledge = false }).environmentObject(vm)
                }
                .sheet(isPresented: Binding(
                    get: { vm.newItemFormOpen && !vm.newItemFormInWindow },
                    set: { if !vm.newItemFormInWindow { vm.newItemFormOpen = $0 } }
                )) {
                    if let draft = vm.newItemDraft {
                        DemandItemEditor(draft: draft, close: { vm.newItemFormOpen = false })
                            .environmentObject(vm).environmentObject(theme)
                    }
                }
        } else { content }
    }
}

extension View {
    func demandEditorPresentation(enabled: Bool = true) -> some View {
        modifier(DemandEditorPresentation(enabled: enabled))
    }
}
