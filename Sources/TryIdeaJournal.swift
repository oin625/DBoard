import SwiftUI
import AppKit

/// Each thought owns its reading content and its editing action.
struct TryIdeaJournal: View {
    @ObservedObject var store: TryStore
    let id: String
    @ObservedObject var controller: TryNoteController
    let notify: (String) -> Void
    let revealEditor: (String, @escaping () -> Void) -> Void
    @State private var editingOriginal = false
    @State private var composing = false
    @State private var expandedSupplements: Set<String> = []
    @State private var clearingDraft = false
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var item: TryEntry? { store.entry(id) }
    private func original(_ field: String) -> Binding<String> {
        Binding(get: { field == "title" ? item?.title ?? "" : item?.body ?? "" },
            set: { store.edit(id, field: field, value: $0) })
    }
    private var originalAnchor: String { id + "-idea-original-editor" }
    private var supplementAnchor: String { id + "-idea-supplement-editor" }
    private var editingSupplementID: String? { composing ? store.additionDraft(id).editingID : nil }

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 20) {
                if editingOriginal {
                    TextField("想法标题，可后补", text: original("title"), axis: .vertical)
                        .textFieldStyle(.plain).dboardFont(size: 28, weight: .semibold)
                        .accessibilityLabel("想法标题")
                } else {
                    Text(item.displayTitle).dboardFont(size: 28, weight: .semibold)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(supplementActionTitle, action: startNewSupplement)
                        .demandButtonStyle(WorkspaceActionStyle(prominent: true))
                        .demandKeyboardID("try-idea-add-supplement")
                    Spacer()
                    statusActions(item)
                }
                if composing, editingSupplementID == nil {
                    supplementWriter.padding(24).workspaceSurface(radius: 17)
                        .transition(TryMotion.transition(reduceMotion))
                }
                originalBlock(item)
                if !item.ideaSupplements.isEmpty {
                    Text("后续补充 · " + String(item.ideaSupplements.count))
                        .dboardFont(size: 12, weight: .medium).foregroundStyle(theme.current.textSecondary)
                    ForEach(item.ideaSupplements.reversed()) { supplement in
                        supplementBlock(supplement)
                    }
                }
                if let error = controller.error { Text(error).dboardFont(size: 12).foregroundStyle(.orange) }
            }
            .animation(TryMotion.animation(reduceMotion), value: composing)
            .animation(TryMotion.animation(reduceMotion), value: editingOriginal)
            .animation(TryMotion.animation(reduceMotion), value: editingSupplementID)
            .onDisappear { controller.end(); _ = store.flush() }
            .alert("清空未保存的补充草稿？", isPresented: $clearingDraft) {
                Button("清空", role: .destructive) {
                    controller.end()
                    if store.clearAdditionDraft(id) { composing = false }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func statusActions(_ item: TryEntry) -> some View {
        if item.status == .active {
            Button(item.kind.doneTitle) { changeStatus(.done) }
                .demandButtonStyle(TryControlStyle())
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.current.textSecondary.opacity(0.45), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .demandKeyboardID("try-idea-finish")
        } else {
            Text(item.statusTitle).dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            Button("继续这个想法") { changeStatus(.active) }
                .demandButtonStyle(TryControlStyle())
                .demandKeyboardID("try-idea-resume")
        }
    }

    private func changeStatus(_ status: TryStatus) {
        controller.end()
        guard store.status(id, status) else { return }
        editingOriginal = false; composing = false
        notify(status == .done ? "该想法已告一段落" : "已继续这个想法")
    }

    private func originalBlock(_ item: TryEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最初的想法").dboardFont(size: 11, weight: .medium)
                .foregroundStyle(theme.current.textSecondary)
            if editingOriginal {
                TryNoteEditor(text: original("body"), editing: $editingOriginal,
                    bookmark: store.bookmarks[id], minimumHeight: 180, maximumHeight: 540,
                    autofocus: false, allowsClickToEdit: true, controller: controller,
                    onBookmark: { store.remember(id, bookmark: $0) }, onEnd: { _ = store.flush() })
                    .id(originalAnchor)
                    .onAppear {
                        revealEditor(originalAnchor) { if editingOriginal { controller.focus() } }
                    }
                writingTools.transition(.opacity)
            } else if item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("还没写正文，可以点下方编辑或继续补充。").dboardFont(size: 14)
                    .foregroundStyle(theme.current.textSecondary)
            } else {
                DemandSpellContentView(text: item.body, fontSize: 15).lineSpacing(5).transition(.opacity)
            }
            HStack {
                Spacer()
                Button(action: {
                    if editingOriginal { finishWriting() }
                    else {
                        controller.end()
                        guard store.flush() else { return }
                        composing = false; editingOriginal = true
                    }
                }) {
                    Label(editingOriginal ? "写好了" : "编辑", systemImage: editingOriginal ? "checkmark" : "pencil")
                }.demandButtonStyle(TryControlStyle()).dboardFont(size: 12)
                    .accessibilityLabel(editingOriginal ? "完成最初想法的编辑" : "编辑最初的想法")
                    .demandKeyboardID("try-idea-edit-original")
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).workspaceSurface(radius: 17)
    }

    private func supplementBlock(_ supplement: TryAddition) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if editingSupplementID == supplement.id {
                supplementWriter.transition(TryMotion.transition(reduceMotion))
            } else {
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedSupplements.contains(supplement.id) },
                    set: { if $0 { expandedSupplements.insert(supplement.id) } else { expandedSupplements.remove(supplement.id) } })) {
                    DemandSpellContentView(text: supplement.body, fontSize: 15)
                        .lineSpacing(5).padding(.top, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !expandedSupplements.contains(supplement.id) {
                            Text(supplement.preview).dboardFont(size: 14).lineLimit(2)
                        }
                        Text(Date(timeIntervalSince1970: supplement.createdAt), style: .date)
                            .dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                    }
                }.demandKeyboardID("try-idea-supplement-" + supplement.id)
                HStack {
                    Spacer()
                    Button { startEditingSupplement(supplement.id) } label: {
                        Label(store.additionDraft(id).editingID == supplement.id ? "继续编辑" : "编辑", systemImage: "pencil")
                    }.demandButtonStyle(TryControlStyle()).dboardFont(size: 12)
                        .accessibilityLabel("编辑这次补充")
                        .demandKeyboardID("try-idea-edit-supplement-" + supplement.id)
                }
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).workspaceSurface(radius: 17)
    }

    private var supplementActionTitle: String {
        let draft = store.additionDraft(id)
        return draft.editingID == nil && !draft.isEmpty ? "继续补充草稿" : "补充想法"
    }

    private var supplementWriter: some View {
        let generation = store.additionGeneration(id)
        let draft = store.additionDraft(id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.editingID == nil ? "补充这个想法" : "编辑这次补充")
                    .dboardFont(size: 14, weight: .medium)
                Spacer()
                Button { finishWriting() } label: { Image(systemName: "xmark") }
                    .demandButtonStyle(TryControlStyle()).accessibilityLabel("关闭并保留补充草稿")
                    .demandKeyboardID("try-idea-supplement-close")
            }
            TryNoteEditor(text: Binding(get: { store.additionDraft(id).body },
                set: { store.editAdditionDraft(id, body: $0, generation: generation) }),
                editing: $composing, bookmark: draft.bookmark, minimumHeight: 160, maximumHeight: 380,
                autofocus: false, allowsClickToEdit: true, controller: controller,
                onBookmark: { store.rememberAddition(id, bookmark: $0, generation: generation) },
                onEnd: { _ = store.flush() })
                .id(supplementAnchor)
                .onAppear {
                    revealEditor(supplementAnchor) { if composing { controller.focus() } }
                }
                .overlay(alignment: .topLeading) {
                    if draft.body.isEmpty {
                        Text("刚想到的补充、新的角度，或者贴一张图…")
                            .dboardFont(size: 15).foregroundStyle(theme.current.textSecondary)
                            .padding(.top, 8).allowsHitTesting(false)
                    }
                }
            writingTools
            HStack(spacing: 12) {
                if !draft.isEmpty {
                    Button("清空草稿") { clearingDraft = true }
                        .demandButtonStyle(TryControlStyle()).foregroundStyle(theme.current.textSecondary)
                }
                Spacer()
                Button("稍后再写") { finishWriting() }.demandButtonStyle(TryControlStyle())
                    .demandKeyboardID("try-idea-supplement-later")
                Button(draft.editingID == nil ? "收好补充" : "保存修改") {
                    controller.end()
                    guard let savedID = store.submitAddition(id) else { composing = true; return }
                    composing = false; expandedSupplements.insert(savedID)
                    notify(draft.editingID == nil ? "补充已收好，原文保留" : "这条补充已更新")
                }.demandButtonStyle(WorkspaceActionStyle(prominent: true)).disabled(draft.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command).demandKeyboardID("try-idea-supplement-save")
            }
        }
    }

    private var writingTools: some View {
        HStack {
            Button { controller.images() } label: { Label("添加图片", systemImage: "photo") }
                .demandButtonStyle(TryControlStyle()).dboardFont(size: 11).accessibilityLabel("添加图片")
            Spacer()
        }
    }

    private func startNewSupplement() {
        if composing, editingSupplementID == nil { controller.focus(); return }
        controller.end()
        guard store.flush() else { return }
        if store.additionDraft(id).editingID != nil {
            guard let savedID = store.submitAddition(id) else { composing = true; return }
            expandedSupplements.insert(savedID)
        }
        editingOriginal = false; composing = true
    }

    private func startEditingSupplement(_ supplementID: String) {
        controller.end()
        guard store.flush() else { return }
        if let previousID = store.additionDraft(id).editingID, previousID != supplementID {
            guard let savedID = store.submitAddition(id) else { composing = true; return }
            expandedSupplements.insert(savedID)
        }
        if store.prepareAddition(id, editing: supplementID) {
            editingOriginal = false; composing = true
        }
    }

    private func finishWriting() {
        controller.end()
        if store.flush() { editingOriginal = false; composing = false }
    }
}
