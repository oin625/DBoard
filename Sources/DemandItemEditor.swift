import SwiftUI
import AppKit

struct DemandCardEditor: Identifiable {
    enum Kind: String { case details, prompt, changes, chats }
    let kind: Kind
    let item: DItem
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

    init(draft: DItemDraft, original: DItem? = nil, close: @escaping () -> Void) {
        self.original = original
        self.close = close
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { original == nil }
    private var changed: Bool { original.map { DItemDraft(from: $0) != draft } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(isNew ? "新增需求" : "编辑需求", systemImage: isNew ? "plus.square" : "pencil")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(draft.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            ScrollView {
                DItemEditForm(draft: draft, isNew: isNew, onSave: { _ in save() }, onCancel: requestClose,
                    onDraftChange: { value in
                        draft = value
                        if isNew { vm.updateNewItemDraft(value) }
                    }, showsActions: false)
                    .padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = saveError ?? (isNew ? vm.newItemDraftError : nil) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if isNew {
                    Text("草稿自动保存，关闭后可继续编辑").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isNew ? "关闭" : "取消", action: requestClose).keyboardShortcut(.cancelAction)
                Button(isNew ? "创建需求" : "保存修改", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.validationError != nil)
                    .accessibilityIdentifier("demand-editor-save")
            }
        }
        .padding(20).frame(minWidth: 520, idealWidth: 640, maxWidth: 800, minHeight: 520, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("放弃未保存的修改？", isPresented: $confirmingDiscard) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改", role: .destructive, action: close)
        } message: { Text("已保存的需求保留，本次尚未保存的修改会被清除。") }
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
            if vm.saveItem(draft, original: original) { close() }
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
                .sheet(item: $vm.demandEditor) { request in
                    switch request.kind {
                    case .prompt:
                        DemandPromptEditor(item: request.item, draftStore: vm.promptDraftStore, cancel: { vm.demandEditor = nil })
                            .environmentObject(vm)
                    case .changes:
                        DemandChangesEditor(item: request.item, draftStore: vm.changeDraftStore, cancel: { vm.demandEditor = nil })
                            .environmentObject(vm)
                    case .details:
                        DemandItemEditor(draft: DItemDraft(from: request.item), original: request.item, close: { vm.demandEditor = nil })
                            .environmentObject(vm).environmentObject(theme)
                    case .chats:
                        DemandChatAssociationEditor(item: request.item, close: { vm.demandEditor = nil })
                            .environmentObject(vm)
                    }
                }
                .sheet(isPresented: $vm.newItemFormOpen) {
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
