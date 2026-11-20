import SwiftUI
import AppKit

/// Captured by native editor bindings so autosave can change the record ID without recreating the editor.
final class TryNotebookPage: ObservableObject, Identifiable {
    let id = UUID()
    @Published var noteID: String?
    @Published var stageID: String?
    let generation: Int
    init(noteID: String?, generation: Int, stageID: String?) {
        self.noteID = noteID; self.generation = generation; self.stageID = stageID
    }
}

struct TryLearningNotebook: View {
    @ObservedObject var store: TryStore
    let entryID: String
    var initialNoteID: String? = nil
    var initiallyShowsOverview = false
    var suggestedTitle: String? = nil
    let close: () -> Void
    let copyAction: (String) -> Void
    let notify: (String) -> Void
    @State private var page: TryNotebookPage?
    @State private var showingOverview = false
    @AppStorage("tryNotebookShowsDirectory") private var showsDirectory = true
    @State private var directoryDragOffset: CGFloat = 0
    @State private var organization: TryLearningOrganization?
    @State private var editing = true
    @State private var focusRequest = 0
    @State private var deleteConfirmation = false
    @State private var outcomeEditing = false
    @State private var outcomeText = ""
    @State private var outcomeNoteID: String?
    @State private var outcomeReference = ""
    @StateObject private var controller = TryNoteController()
    @EnvironmentObject private var theme: ThemeManager
    private var item: TryEntry? { store.entry(entryID) }
    private var note: TryLearningNote? { item?.learningNotes.first { $0.id == page?.noteID } }

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        controller.end()
                        if store.flush() { close() }
                    } label: { Label("学习", systemImage: "chevron.left") }
                        .demandButtonStyle(TryControlStyle()).demandKeyboardID("try-notebook-back")
                    Text(item.id).dboardFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundStyle(theme.current.accentPrimary)
                    Text(item.displayTitle).dboardFont(size: 13, weight: .medium).lineLimit(1)
                    Spacer(minLength: 8)
                    Button { newPage() } label: { Label("新一篇", systemImage: "plus") }
                        .demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("try-new-note")
                }.padding(.horizontal, 22).padding(.vertical, 12)
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if showsDirectory {
                            let width = min(230, max(160, geometry.size.width * 0.25))
                            HStack(spacing: 0) {
                                directory(item).frame(width: max(0, width + directoryDragOffset)).clipped()
                                TryNotebookDivider(tint: theme.current.textSecondary.opacity(0.13),
                                    changed: { directoryDragOffset = min(0, max(-width, $0)) },
                                    ended: { offset in
                                        if offset <= -55 { setDirectoryVisible(false) }
                                        else { withAnimation(.easeOut(duration: 0.18)) { directoryDragOffset = 0 } }
                                    }, clicked: { setDirectoryVisible(false) })
                                    .frame(width: 12).frame(maxHeight: .infinity)
                            }.transition(.move(edge: .leading).combined(with: .opacity))
                        } else {
                            collapsedDirectoryHandle
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        if showingOverview {
                            TryNotebookOverview(item: item, open: showNote, create: { newPage() })
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let page {
                            TryNotebookSheet(store: store, entryID: entryID, page: page, editing: $editing,
                                controller: controller, focusRequest: focusRequest,
                                delete: { deleteConfirmation = true },
                                outcome: { text in
                                    outcomeText = text; outcomeNoteID = page.noteID; outcomeReference = ""; outcomeEditing = true
                                },
                                copyAction: {
                                    controller.end()
                                    if store.flush() { copyAction($0) }
                                }, openNote: showNote)
                                .id(page.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else { Color.clear }
                    }
                }
            }
            .onAppear {
                if let initialNoteID { showNote(initialNoteID) }
                else if initiallyShowsOverview { showOverview() }
                else { newPage(fresh: suggestedTitle != nil, suggestedTitle: suggestedTitle) }
            }
            .onDisappear { controller.end(); _ = store.flush() }
            .alert("删除这篇笔记？", isPresented: $deleteConfirmation) {
                Button("删除", role: .destructive) {
                    controller.end()
                    if let note, store.removeLearningNote(entryID, noteID: note.id) { showOverview() }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("可从学习页面的「已删除笔记」恢复，学习成果会保留。") }
            .popover(item: $organization) { draft in
                TryLearningOrganizationView(store: store, entryID: entryID, draftID: draft.id,
                    close: { organization = nil })
            }
            .popover(isPresented: $outcomeEditing) {
                TryLearningOutcomeEditor(text: $outcomeText, noteID: $outcomeNoteID, reference: $outcomeReference,
                    notes: item.learningNotes, save: {
                        if store.saveLearningOutcome(entryID, text: outcomeText, noteID: outcomeNoteID, reference: outcomeReference) {
                            outcomeEditing = false; notify("成果已记录")
                        }
                    }, close: { outcomeEditing = false }).environmentObject(theme)
            }
        }
    }
    private func setDirectoryVisible(_ visible: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            showsDirectory = visible
            directoryDragOffset = 0
        }
    }
    private var collapsedDirectoryHandle: some View {
        Button { setDirectoryVisible(true) } label: {
            VStack(spacing: 0) {
                Image(systemName: "chevron.right").dboardFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.current.textSecondary).frame(width: 28, height: 36)
                Spacer(minLength: 0)
            }.frame(width: 28).frame(maxHeight: .infinity)
                .background(theme.current.textSecondary.opacity(0.035))
                .contentShape(Rectangle())
        }.demandButtonStyle(.plain).accessibilityLabel("展开笔记目录")
            .demandKeyboardID("try-notebook-toggle-directory")
    }
    private func directory(_ item: TryEntry) -> some View {
        let catalog = TryNotebookCatalog(item)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Button(action: showOverview) {
                        HStack {
                            Text("全部笔记").dboardFont(size: 13, weight: .medium)
                            Spacer(minLength: 4)
                            Text("\(catalog.notes.count)").dboardFont(size: 11)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.current.accentPrimary.opacity(showingOverview ? 0.10 : 0),
                                        in: RoundedRectangle(cornerRadius: 10))
                    }.demandButtonStyle(.plain).demandKeyboardID("try-notebook-all")
                    Button { setDirectoryVisible(false) } label: {
                        Image(systemName: "chevron.left").dboardFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.current.textSecondary)
                            .frame(width: 28, height: 32).contentShape(Rectangle())
                    }.demandButtonStyle(.plain).accessibilityLabel("收起笔记目录")
                        .demandKeyboardID("try-notebook-toggle-directory")
                }
                if !showingOverview, page?.noteID == nil {
                    Text("正在写 · 新一篇").dboardFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.current.accentPrimary).padding(12)
                }
                ForEach(catalog.notes.reversed()) { note in directoryRow(note) }
                if !(item.learningOrganizations ?? []).isEmpty {
                    Menu("整理记录与待采纳稿") {
                        ForEach(item.learningOrganizations ?? []) { draft in
                            Button((draft.adoptedNoteID == nil ? "待采纳 · " : "") + draft.title) { organization = draft }
                        }
                    }.demandMenuStyle(TryMenuStyle()).dboardFont(size: 11).padding(.top, 14)
                }
            }.padding(12)
        }.background(theme.current.textSecondary.opacity(0.035))
    }
    private func directoryRow(_ note: TryLearningNote) -> some View {
        Button { showNote(note.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(note.id).dboardFont(size: 9, design: .monospaced).foregroundStyle(theme.current.textSecondary)
                Text(note.displayTitle).dboardFont(size: 12, weight: !showingOverview && page?.noteID == note.id ? .medium : .regular)
                    .foregroundStyle(theme.current.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .background(theme.current.accentPrimary.opacity(!showingOverview && page?.noteID == note.id ? 0.10 : 0),
                            in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.demandButtonStyle(.plain).demandKeyboardID("try-select-note-" + note.id)
    }
    private func showOverview() {
        controller.end()
        if store.flush() { showingOverview = true }
    }
    private func newPage(fresh: Bool = true, suggestedTitle: String? = nil) {
        controller.end()
        guard let next = store.beginNotebookPage(entryID, fresh: fresh, suggestedTitle: suggestedTitle) else { return }
        page = next; showingOverview = false
        editing = true; focusRequest += 1
    }
    private func showNote(_ noteID: String) {
        controller.end()
        guard store.flush(), let note = item?.learningNotes.first(where: { $0.id == noteID }) else { return }
        if !(item?.learningDraft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            guard store.saveLearningNote(entryID) != nil else { return }
        }
        page = TryNotebookPage(noteID: noteID, generation: store.learningGeneration(entryID), stageID: note.learningStageID)
        showingOverview = false; editing = false
        store.selectLearningNote(entryID, noteID: noteID)
    }
}

private struct TryNotebookOverview: View {
    let item: TryEntry
    let open: (String) -> Void
    let create: () -> Void
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("全部笔记").dboardFont(size: 25, weight: .semibold)
                let catalog = TryNotebookCatalog(item)
                if catalog.notes.isEmpty {
                    Button("写第一篇", action: create).demandButtonStyle(WorkspaceActionStyle(prominent: true))
                } else {
                    cards(catalog.notes)
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func cards(_ notes: [TryLearningNote]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
            ForEach(notes) { note in
                Button { open(note.id) } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(note.id).dboardFont(size: 10, design: .monospaced)
                            .foregroundStyle(theme.current.textSecondary)
                        Text(note.displayTitle).dboardFont(size: 15, weight: .medium).lineLimit(2).multilineTextAlignment(.leading)
                        Text(TryNoteMarkup.plainLabel(TryNotebookPresentation(note).body))
                            .dboardFont(size: 11).foregroundStyle(theme.current.textSecondary).lineLimit(2)
                    }.padding(18).frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
                        .workspaceSurface(radius: 13).contentShape(Rectangle())
                }.demandButtonStyle(.plain).demandKeyboardID("try-note-overview-" + note.id)
            }
        }
    }
}

private struct TryNotebookSheet: View {
    @ObservedObject var store: TryStore
    let entryID: String
    @ObservedObject var page: TryNotebookPage
    @Binding var editing: Bool
    let controller: TryNoteController
    let focusRequest: Int
    let delete: () -> Void
    let outcome: (String) -> Void
    let copyAction: (String) -> Void
    let openNote: (String) -> Void
    @State private var provenance = false
    @State private var metadataPresented = false
    @State private var linkedUnit: TryLearningUnit?
    @EnvironmentObject private var theme: ThemeManager
    private var item: TryEntry? { store.entry(entryID) }
    private var note: TryLearningNote? { item?.learningNotes.first { $0.id == page.noteID } }
    private var displayedTitle: String {
        if let note {
            return !note.title.isEmpty || TryNotebookPresentation.hasBodyTitle(note) ? note.displayTitle : ""
        }
        return item?.learningDraft.title ?? ""
    }
    private var bodyText: Binding<String> {
        Binding(get: {
            if let noteID = page.noteID { return store.entry(entryID)?.learningNotes.first { $0.id == noteID }?.body ?? "" }
            return store.entry(entryID)?.learningDraft.body ?? ""
        }, set: { store.writeNotebookPage(entryID, page: page, body: $0) })
    }
    var body: some View {
        if let item {
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(Date(timeIntervalSince1970: note?.createdAt ?? Date().timeIntervalSince1970),
                            format: .dateTime.year().month().day()).dboardFont(size: 13, weight: .medium)
                        if let note { Text(note.id).dboardFont(size: 10, design: .monospaced).foregroundStyle(theme.current.textSecondary) }
                        Spacer()
                        if !editing {
                            Button("编辑") { editing = true; controller.focus() }
                                .demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("try-note-edit")
                        } else if page.noteID != nil {
                            Button("阅读") { controller.end(); editing = false }
                                .demandButtonStyle(TryControlStyle()).demandKeyboardID("try-note-edit-done")
                        }
                        if page.noteID != nil {
                            Menu { Button("删除笔记", role: .destructive, action: delete) } label: { Image(systemName: "ellipsis") }
                                .demandMenuStyle(TryMenuStyle()).menuIndicator(.hidden).accessibilityLabel("笔记操作")
                        }
                    }
                    if !displayedTitle.isEmpty, !editing || note.map({ TryNotebookPresentation.hasBodyTitle($0) }) != true {
                        Text(displayedTitle).dboardFont(size: 24, weight: .semibold)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    TryNoteEditor(text: bodyText, editing: $editing, bookmark: note?.bookmark ?? item.learningDraft.bookmark,
                        minimumHeight: max(80, geometry.size.height - (displayedTitle.isEmpty ? 212 : 248)),
                        maximumHeight: max(80, geometry.size.height - (displayedTitle.isEmpty ? 212 : 248)),
                        autofocus: true, allowsClickToEdit: editing, allowsReadingToEdit: true,
                        richFormatting: true, readingPresentation: note.map { TryNotebookPresentation($0).body }, controller: controller,
                        onBookmark: { store.rememberLearningNote(entryID, noteID: page.noteID, bookmark: $0, generation: page.generation) },
                        onEnd: { _ = store.flush() })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .overlay(alignment: .topLeading) {
                            if bodyText.wrappedValue.isEmpty {
                                Text("写下理解、疑问或练习，直接粘贴图片也可以…")
                                    .dboardFont(size: 15).foregroundStyle(theme.current.textSecondary)
                                    .padding(.top, 8).allowsHitTesting(false)
                            }
                        }
                    HStack(spacing: 6) {
                        if editing {
                            Button { controller.format(.bold) } label: { Image(systemName: "bold") }
                                .demandButtonStyle(TryControlStyle()).accessibilityLabel("加粗")
                                .demandKeyboardID("try-note-bold")
                            Button { controller.format(.italic) } label: { Image(systemName: "italic") }
                                .demandButtonStyle(TryControlStyle()).accessibilityLabel("斜体")
                                .demandKeyboardID("try-note-italic")
                            Button { controller.format(.bullet) } label: { Image(systemName: "list.bullet") }
                                .demandButtonStyle(TryControlStyle()).accessibilityLabel("项目列表")
                                .demandKeyboardID("try-note-list")
                            Button { controller.images() } label: { Image(systemName: "photo") }
                                .demandButtonStyle(TryControlStyle()).accessibilityLabel("贴入图片")
                            Menu {
                                Button("加粗 ⌘B") { controller.format(.bold) }
                                Button("斜体 ⌘I") { controller.format(.italic) }
                                Divider()
                                Button("小标题") { controller.format(.heading) }
                                Button("项目列表") { controller.format(.bullet) }
                                Button("编号列表") { controller.format(.numbered) }
                                Button("引用") { controller.format(.quote) }
                                Button("行内代码") { controller.format(.code) }
                                Button("代码块") { controller.format(.codeBlock) }
                            } label: { Image(systemName: "textformat") }
                                .demandMenuStyle(TryMenuStyle()).menuIndicator(.hidden).accessibilityLabel("笔记格式")
                        }
                        if store.error != nil {
                            Text("尚未保存").dboardFont(size: 10).foregroundStyle(Color.orange)
                        }
                        Spacer(minLength: 4)
                        if page.noteID != nil {
                            Button("记为成果") {
                                let selection = controller.editor?.selectedRange() ?? NSRange(location: 0, length: 0)
                                outcome(selection.length > 0 ? (controller.editor!.string as NSString).substring(with: selection) : "")
                            }.demandButtonStyle(TryControlStyle()).dboardFont(size: 11).demandKeyboardID("try-note-to-outcome")
                        }
                    }
                    HStack(spacing: 8) {
                        if let note {
                            Text(note.origin == "ai_organized" ? "AI整理 · 已采纳" :
                                 note.origin == "ai_supplement" ? "AI补充 · 已采纳" : "我的原文")
                                .dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                            Button("关联信息") { metadataPresented = true }
                                .demandButtonStyle(TryControlStyle()).dboardFont(size: 11)
                            if !(note.sourceNotes ?? []).isEmpty || !TryNotebookPresentation(note).annotations.isEmpty {
                                Button("来源与说明") { provenance = true }
                                    .demandButtonStyle(TryControlStyle()).dboardFont(size: 11)
                            }
                        }
                        Spacer()
                        Button { copyAction(item.learningAction) } label: { Label("交给 AI", systemImage: "sparkles") }
                            .demandButtonStyle(TryControlStyle()).dboardFont(size: 11).demandKeyboardID("try-notebook-ai")
                    }
                    if let error = controller.error {
                        Text(error).dboardFont(size: 12).foregroundStyle(.orange)
                    }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .popover(isPresented: $metadataPresented) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("关联信息").dboardFont(size: 18, weight: .semibold)
                    Menu {
                        Button("不关联阶段") { assignStage(nil) }
                        ForEach(item.learningPlan?.stages ?? []) { stage in
                            Button(stage.title) { assignStage(stage.id) }
                        }
                    } label: {
                        Text(page.stageID.flatMap { stageID in item.learningPlan?.stages.first { $0.id == stageID }?.title ?? stageID } ?? "关联学习阶段")
                    }.demandMenuStyle(TryMenuStyle())
                    if let note {
                        Menu("知识主题") {
                            ForEach(item.learningTopics ?? []) { topic in
                                Button(((note.topicIDs ?? []).contains(topic.id) ? "✓ " : "") + topic.title) {
                                    var topics = note.topicIDs ?? []
                                    if topics.contains(topic.id) { topics.removeAll { $0 == topic.id } } else { topics.append(topic.id) }
                                    store.editLearningNote(entryID, noteID: note.id, field: "topicIDs",
                                        value: topics.joined(separator: ","), generation: page.generation)
                                }
                            }
                        }.demandMenuStyle(TryMenuStyle())
                        ForEach((item.learningUnits ?? []).filter { (note.unitIDs ?? []).contains($0.id) }) { unit in
                            Button(unit.title) { metadataPresented = false; linkedUnit = unit }
                                .demandButtonStyle(TryControlStyle())
                        }
                    }
                }.padding(24).frame(width: 350).environmentObject(theme)
            }
            .popover(isPresented: $provenance) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array((note.map { TryNotebookPresentation($0).annotations } ?? []).enumerated()), id: \.offset) { _, annotation in
                            TryStudyMarkdown(text: annotation)
                        }
                        ForEach(note?.sourceNotes ?? []) { source in
                            Text(source.id + " · " + source.title).font(.system(size: 15, weight: .semibold))
                            Text(Date(timeIntervalSince1970: source.updatedAt), style: .date).font(.system(size: 11))
                            TryStudyMarkdown(text: source.body)
                            Button("打开原始笔记 " + source.id) { provenance = false; openNote(source.id) }
                                .demandButtonStyle(TryControlStyle())
                        }
                    }.padding(24)
                }.frame(width: 560, height: 500)
            }
            .popover(item: $linkedUnit) { unit in
                ScrollView {
                    TryLearningUnitView(unit: unit, topics: [], notes: [], openNote: { _ in }).padding(24)
                }.frame(width: 620, height: 550)
            }
            .onChange(of: focusRequest) { _, _ in if editing { controller.focus() } }
        }
    }
    private func assignStage(_ stageID: String?) {
        page.stageID = stageID
        store.editLearningNote(entryID, noteID: page.noteID, field: "learningStageID", value: stageID ?? "", generation: page.generation)
    }
}
