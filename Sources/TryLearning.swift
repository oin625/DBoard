import SwiftUI
import AppKit

struct TryLearningCard: View {
    let entry: TryEntry
    let remove: () -> Void
    let open: () -> Void
    @State private var hovered = false
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(entry.id).dboardFont(size: 11, weight: .medium, design: .monospaced).foregroundStyle(theme.current.accentPrimary)
                    Text(entry.kind.title).dboardFont(size: 11).foregroundStyle(theme.current.accentSecondary)
                    if entry.kind == .idea, entry.status != .active {
                        Text(entry.statusTitle).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                    }
                    Spacer()
                    Text(Date(timeIntervalSince1970: entry.updatedAt), style: .relative).dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                }
                Text(entry.displayTitle).dboardFont(size: 20, weight: .semibold).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if entry.kind == .digestion, entry.learningConfigReady {
                    Text(entry.learningFinishedAt != nil ? "本轮已结束" :
                        (entry.learningConfig?.overdue == true ? "已到期，待复盘" :
                        (entry.learningPlanCurrent ? "当前 · " + (entry.currentLearningStage?.title ?? "目标验收") :
                        (entry.learningPlanProposal == nil ? "待制定学习方案" : "安排需调整"))))
                        .dboardFont(size: 13, weight: .medium).foregroundStyle(theme.current.accentPrimary).lineLimit(2)
                }
                if entry.kind == .digestion, !entry.progress.isEmpty {
                    Text(entry.progress).dboardFont(size: 13, weight: .medium).foregroundStyle(theme.current.accentPrimary).lineLimit(2)
                }
                if entry.hasDueLearningPractice {
                    Text("有复习题到期").dboardFont(size: 12, weight: .medium).foregroundStyle(theme.current.accentPrimary)
                }
                Text(plain(entry.kind == .digestion ? (entry.learningConfigReady ? entry.learningGoalLabel : entry.learningPreview) : entry.body))
                    .dboardFont(size: 13).foregroundStyle(theme.current.textSecondary).lineLimit(entry.kind == .idea ? 5 : 3).lineSpacing(4)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                if entry.kind == .digestion {
                    HStack(spacing: 12) {
                        if let config = entry.learningConfig {
                            Text(entry.learningFinishedAt != nil ? "本轮已结束" : (config.overdue ? "到期复盘" : "还有 \(config.daysLeft) 天"))
                                .foregroundStyle(config.overdue ? .orange : theme.current.accentPrimary)
                        }
                        Text("\(entry.learningNotes.count) 篇笔记")
                        if !entry.learningOutcomes.isEmpty { Text("\(entry.learningOutcomes.count) 项成果") }
                    }.dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                }
            }.padding(23).frame(maxWidth: .infinity, minHeight: 205, alignment: .topLeading)
                .workspaceSurface(radius: 18, highlighted: hovered).contentShape(RoundedRectangle(cornerRadius: 18))
        }.demandButtonStyle(.plain).onHover { hovered = $0 }.accessibilityIdentifier("try-learning-card-" + entry.id)
            .contextMenu { Button("移到回收站", role: .destructive, action: remove) }
    }
    private func plain(_ text: String) -> String {
        DemandImageMarkdown.references(in: text).reduce(text) { $0.replacingOccurrences(of: $1.markdown, with: "〔图片〕") }
    }
}

struct TryJournalDetail: View {
    @ObservedObject var store: TryStore
    let id: String
    var initiallyBrowsingNotebook = false
    let back: () -> Void
    let open: (String) -> Void
    let notify: (String) -> Void
    @State private var learningSection = "学习"
    @State private var notebookPresented = false
    @State private var notebookInitialNoteID: String?
    @State private var notebookInitiallyShowsOverview = false
    @State private var notebookSuggestedTitle: String?
    @State private var titleEditing = false
    @State private var goalEditing = false
    @State private var progressEditing = false
    @State private var progressDraft = ""
    @State private var nextDraft = ""
    @State private var outcomeEditing = false
    @State private var outcomeID: String?
    @State private var outcomeText = ""
    @State private var outcomeNoteID: String?
    @State private var outcomeReference = ""
    @State private var allOutcomes = false
    @State private var sourcesExpanded = false
    @State private var sourcesEditing = false
    @State private var aiExpanded = false
    @StateObject private var controller = TryNoteController()
    @FocusState private var progressFocused: Bool
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var item: TryEntry? { store.entry(id) }
    private var isStudy: Bool { item?.kind == .digestion }
    private func binding(_ field: String) -> Binding<String> {
        Binding(get: {
            guard let item else { return "" }
            switch field { case "title": return item.title; case "learningSources": return item.learningSources ?? ""; default: return item.body }
        }, set: { store.edit(id, field: field, value: $0) })
    }
    var body: some View {
        ZStack {
            if notebookPresented {
                TryLearningNotebook(store: store, entryID: id, initialNoteID: notebookInitialNoteID, initiallyShowsOverview: notebookInitiallyShowsOverview, suggestedTitle: notebookSuggestedTitle,
                    close: { notebookPresented = false }, copyAction: copyLearningAction, notify: notify)
                    .transition(TryMotion.transition(reduceMotion))
            } else if let item {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        toolbar(item)
                        GeometryReader { geometry in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 24) {
                                    if isStudy {
                                        Text(item.displayTitle).dboardFont(size: 28, weight: .semibold)
                                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                        if learningSection == "复习" {
                                            TryLearningEvidenceView(store: store, id: id,
                                                copyAction: copyLearningAction, openNote: showNote)
                                        } else {
                                        TryLearningJourneyPanel(store: store, id: id,
                                            editGoal: { controller.end(); goalEditing = true },
                                            writeNote: { writeStageNote() },
                                            copyAction: { copyLearningAction($0) }, openNote: showNote)
                                        }
                                        if learningSection == "复习" { overview(item) }
                                        if item.currentLearningStage == nil, let explanation = item.standaloneLearningExplanation {
                                            DisclosureGroup {
                                                TryLearningStudySheet(text: TryLearningReading.text(explanation)).padding(.top, 10)
                                                Button("写下当前理解") { writeStageNote() }
                                                    .demandButtonStyle(TryControlStyle())
                                            } label: { Text("学习讲解").dboardFont(size: 13, weight: .medium) }
                                        }
                                        references(item)
                                    } else {
                                        TryIdeaJournal(store: store, id: id, controller: controller, notify: notify,
                                            revealEditor: { anchor, focus in
                                                DispatchQueue.main.async {
                                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                                        proxy.scrollTo(anchor, anchor: .top)
                                                    }
                                                    DispatchQueue.main.async { focus() }
                                                }
                                            })
                                        if !item.relatedIDs.isEmpty { references(item) }
                                    }
                                    aiSection(item)
                                }.padding(28).frame(maxWidth: 1160, alignment: .leading).frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .transition(TryMotion.transition(reduceMotion))
                .onDisappear { controller.end(); _ = store.flush() }
                .popover(isPresented: $outcomeEditing) {
                    TryLearningOutcomeEditor(text: $outcomeText, noteID: $outcomeNoteID, reference: $outcomeReference,
                        notes: item.learningNotes, save: {
                            if store.saveLearningOutcome(id, outcomeID: outcomeID, text: outcomeText, noteID: outcomeNoteID, reference: outcomeReference) {
                                outcomeEditing = false; notify("成果已记录")
                            }
                        }, close: { outcomeEditing = false }).environmentObject(theme)
                }
                .popover(isPresented: $goalEditing) {
                    TryLearningGoalEditor(store: store, id: id, close: { goalEditing = false },
                        saved: { copyLearningAction("plan") }).environmentObject(theme)
                }
                .popover(isPresented: $sourcesEditing) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("补充资料").dboardFont(size: 20, weight: .semibold)
                        TextEditor(text: binding("learningSources")).dboardFont(size: 13)
                            .frame(height: 230).accessibilityLabel("学习资料")
                        HStack {
                            Spacer()
                            Button("收好") { if store.flush() { sourcesEditing = false } }
                                .demandButtonStyle(WorkspaceActionStyle(prominent: true))
                        }
                    }.padding(24).frame(width: 460).onDisappear { _ = store.flush() }
                }
            }
        }.animation(TryMotion.animation(reduceMotion), value: notebookPresented)
            .background(TryLearningNoteShortcut(
                enabled: isStudy && learningSection == "学习" && !notebookPresented &&
                    !titleEditing && !goalEditing && !sourcesEditing && !outcomeEditing,
                action: writeStageNote))
            .onAppear { if initiallyBrowsingNotebook { showNotebookOverview() } }
            .popover(isPresented: $titleEditing) {
                TextField("学习主题", text: binding("title"), axis: .vertical)
                    .textFieldStyle(.plain).dboardFont(size: 20).padding(24).frame(width: 400)
                    .onDisappear { _ = store.flush() }
            }
    }
    private func toolbar(_ item: TryEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                controller.end()
                if store.flush() { back() }
            } label: { Image(systemName: "chevron.left") }
                .demandButtonStyle(TryControlStyle()).accessibilityLabel("返回")
            Button {
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(item.id, forType: .string) { notify("已复制编号 " + item.id) }
            } label: {
                Text(item.id).dboardFont(size: 12, weight: .medium, design: .monospaced).foregroundStyle(theme.current.accentPrimary)
            }.demandButtonStyle(TryControlStyle()).accessibilityLabel("复制编号 " + item.id)
            Text(item.kind.title).dboardFont(size: 12).foregroundStyle(theme.current.accentSecondary)
            Spacer()
            if isStudy {
                if learningSection == "复习" {
                    Button("继续学习") { learningSection = "学习" }.demandButtonStyle(TryControlStyle())
                }
                Button("笔记本", action: showNotebookOverview)
                    .demandButtonStyle(TryControlStyle()).demandKeyboardID("try-open-knowledge")
                Button { writeStageNote() } label: { Label("写笔记", systemImage: "square.and.pencil") }
                    .demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("try-open-notebook")
            } else {
                Button("围绕这个学习") {
                    controller.end()
                    if let next = store.beginLearning(from: id) { open(next) }
                }.demandButtonStyle(TryControlStyle()).demandKeyboardID("try-idea-learn")
            }
            if !isStudy {
                Button {
                    controller.end()
                    guard let text = store.handoff(id) else { return }
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(text, forType: .string) { notify("已复制，交给 AI " + item.kind.aiAction) }
                } label: { Label(item.kind.aiAction, systemImage: "sparkles") }
                    .demandButtonStyle(WorkspaceActionStyle(prominent: true)).demandKeyboardID("try-learning-copy")
            }
            Menu {
                if isStudy {
                    Button("复习与成果") { learningSection = "复习" }
                    Button("编辑主题名称") { titleEditing = true }
                    Button("编辑资料") { sourcesEditing = true }
                }
                let deleted = (item.notes ?? []).filter { $0.deletedAt != nil }
                if isStudy, !deleted.isEmpty {
                    Menu("已删除笔记") {
                        ForEach(deleted) { deletedNote in
                            Button("恢复 " + deletedNote.displayTitle) { _ = store.removeLearningNote(id, noteID: deletedNote.id, restore: true) }
                        }
                    }
                }
                Button("移到回收站", role: .destructive) {
                    controller.end()
                    if store.trash(id) { back() }
                }
            } label: { Image(systemName: "ellipsis") }
                .demandMenuStyle(TryMenuStyle()).menuIndicator(.hidden).accessibilityLabel("更多")
        }.padding(.horizontal, 25).padding(.vertical, 12)
    }
    private func overview(_ item: TryEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("学到哪里").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                    if !progressEditing {
                        Button {
                            progressDraft = item.progress; nextDraft = item.nextStep
                            progressEditing = true; progressFocused = true
                        } label: {
                            HStack(spacing: 8) {
                                Text(item.progress.isEmpty ? "记一句当前进度" : item.progress)
                                    .dboardFont(size: 15, weight: .medium).foregroundStyle(theme.current.accentPrimary).multilineTextAlignment(.leading)
                                Image(systemName: "pencil").dboardFont(size: 10)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                        }.demandButtonStyle(.plain).demandKeyboardID("try-learning-progress")
                        if !item.nextStep.isEmpty { Text("接着看 · " + item.nextStep).dboardFont(size: 12).foregroundStyle(theme.current.textSecondary) }
                    }
                }
                Spacer()
                Text("\(item.learningNotes.count) 篇笔记").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
            }
            if progressEditing {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("当前学到哪了", text: $progressDraft, axis: .vertical)
                        .textFieldStyle(.plain).dboardFont(size: 15).focused($progressFocused).accessibilityLabel("学习进度")
                    TextField("下一步想看什么，可不填", text: $nextDraft, axis: .vertical)
                        .textFieldStyle(.plain).dboardFont(size: 13).accessibilityLabel("接着学习")
                    HStack {
                        Spacer()
                        Button("取消") { progressEditing = false }.demandButtonStyle(TryControlStyle())
                        Button("保存") {
                            store.edit(id, field: "progress", value: progressDraft); store.edit(id, field: "nextStep", value: nextDraft)
                            if store.flush() { progressEditing = false }
                        }.demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("try-learning-progress-save")
                    }
                }.transition(TryMotion.transition(reduceMotion))
            }
            if item.learningSuggestionCurrent, let suggestion = item.learningSuggestion {
                VStack(alignment: .leading, spacing: 10) {
                    Text("待采纳的建议").dboardFont(size: 11, weight: .medium).foregroundStyle(theme.current.accentSecondary)
                    if let progress = suggestion.progress { Text(progress).dboardFont(size: 13) }
                    if let next = suggestion.nextStep { Text("下一步 · " + next).dboardFont(size: 12).foregroundStyle(theme.current.textSecondary) }
                    ForEach(suggestion.outcomes) { outcome in Text(outcome.text).dboardFont(size: 13) }
                    HStack {
                        Button("忽略") { _ = store.update(id) { $0.learningSuggestion = nil } }.demandButtonStyle(TryControlStyle())
                        Spacer()
                        Button("采纳") { _ = store.acceptLearningSuggestion(id) }
                            .demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("try-learning-suggestion-accept")
                    }
                }.padding(14).workspaceSurface(radius: 12)
            }
            Divider().opacity(0.35)
            HStack {
                Text("学会了什么").dboardFont(size: 12, weight: .medium)
                Spacer()
                Button("记录成果") { editOutcome(nil) }.demandButtonStyle(TryControlStyle()).dboardFont(size: 11)
                    .demandKeyboardID("try-learning-outcome-add")
            }
            if item.learningOutcomes.isEmpty {
                Text("把真正弄懂的知识、完成的练习留在这里。").dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
            } else {
                ForEach(allOutcomes ? item.learningOutcomes : Array(item.learningOutcomes.prefix(3))) { outcome in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark").dboardFont(size: 11).foregroundStyle(theme.current.accentPrimary).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(outcome.text).dboardFont(size: 14).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                if let linked = item.learningNotes.first(where: { $0.id == outcome.noteID }) {
                                    Button { showNote(linked.id) } label: { Label(linked.displayTitle, systemImage: "arrow.up.right").lineLimit(1) }
                                        .demandButtonStyle(TryControlStyle()).dboardFont(size: 11).foregroundStyle(theme.current.accentSecondary)
                                        .demandKeyboardID("try-outcome-note-" + outcome.id)
                                } else if outcome.noteID != nil {
                                    Text("关联笔记已删除，可恢复").dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                                }
                                if let url = URL(string: outcome.reference), ["http", "https"].contains(url.scheme ?? "") {
                                    Link("查看成果", destination: url).dboardFont(size: 11)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Menu {
                            Button("编辑") { editOutcome(outcome) }
                            Button("删除成果", role: .destructive) { _ = store.removeLearningOutcome(id, outcomeID: outcome.id) }
                        } label: { Image(systemName: "ellipsis") }
                            .demandMenuStyle(TryMenuStyle()).menuIndicator(.hidden).accessibilityLabel("编辑学习成果")
                    }
                }
                if item.learningOutcomes.count > 3 {
                    Button(allOutcomes ? "收起成果" : "查看全部 \(item.learningOutcomes.count) 项成果") { allOutcomes.toggle() }
                        .demandButtonStyle(TryControlStyle()).dboardFont(size: 11)
                }
            }
        }.padding(21).workspaceSurface(radius: 17)
            .animation(TryMotion.animation(reduceMotion), value: progressEditing)
            .animation(TryMotion.animation(reduceMotion), value: allOutcomes)
    }
    @ViewBuilder private func references(_ item: TryEntry) -> some View {
        let related = item.relatedIDs.compactMap { store.entry($0) }.filter { $0.kind != .task }
        let resources = item.learningResources
        let notes = item.learningSourceNotes
        if !related.isEmpty || (isStudy && (!resources.isEmpty || !notes.isEmpty)) {
            DisclosureGroup(isExpanded: $sourcesExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if isStudy {
                        TryLearningResourceCards(resources: resources)
                        if !notes.isEmpty { Text(notes).dboardFont(size: 13).textSelection(.enabled) }
                    }
                    ForEach(related) { related in
                        Button(related.kind.title + " · " + related.displayTitle) {
                            controller.end()
                            if store.flush() { open(related.id) }
                        }.demandButtonStyle(TryControlStyle()).dboardFont(size: 12)
                    }
                    if isStudy {
                        Button("编辑资料") { sourcesEditing = true }
                            .demandButtonStyle(TryControlStyle()).demandKeyboardID("try-learning-sources-edit")
                    }
                }.padding(.top, 12)
            } label: {
                Text(isStudy ? "资料" : "相关学习笔记").dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            }.demandKeyboardID("try-learning-sources")
        }
    }
    @ViewBuilder private func aiSection(_ item: TryEntry) -> some View {
        if !isStudy, !item.aiResult.isEmpty {
            DisclosureGroup(isExpanded: $aiExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    DemandSpellContentView(text: item.aiResult)
                    Button("收入想法") {
                        controller.end()
                        _ = store.adopt(id)
                    }.demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("try-learning-adopt")
                }.padding(.top, 14)
            } label: { Text("AI 解释与建议").dboardFont(size: 12, weight: .medium).foregroundStyle(theme.current.accentSecondary) }
                .demandKeyboardID("try-learning-ai")
        }
    }
    private func showNotebookOverview() {
        controller.end()
        guard store.flush() else { return }
        notebookSuggestedTitle = nil
        notebookInitialNoteID = nil; notebookInitiallyShowsOverview = true; notebookPresented = true
    }
    private func writeStageNote() {
        controller.end()
        guard store.flush() else { return }
        guard let item else { return }
        notebookSuggestedTitle = item.currentLearningNoteTitle
        notebookInitialNoteID = nil; notebookInitiallyShowsOverview = false; notebookPresented = true
    }
    private func copyLearningAction(_ action: String) {
        controller.end()
        guard store.flush() else { return }
        guard store.entry(id)?.learningConfigReady == true else { goalEditing = true; return }
        if action == "check", let item = store.entry(id), !item.learningDraft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = store.saveLearningNote(id)
        }
        guard let text = store.learningHandoff(id, action: action) else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            notify(action == "plan" ? "方案指令已复制，粘贴给 AI；合适的方案会自动开始试学" : "已复制本阶段指令，粘贴给 AI 继续")
        }
    }

    private func showNote(_ noteID: String) {
        controller.end()
        guard store.flush() else { return }
        notebookInitialNoteID = noteID; notebookInitiallyShowsOverview = false; notebookPresented = true
    }
    private func editOutcome(_ outcome: TryLearningOutcome?) {
        outcomeID = outcome?.id; outcomeText = outcome?.text ?? ""; outcomeNoteID = outcome?.noteID
        outcomeReference = outcome?.reference ?? ""; outcomeEditing = true
    }

}

struct TryLearningOutcomeEditor: View {
    @Binding var text: String
    @Binding var noteID: String?
    @Binding var reference: String
    let notes: [TryLearningNote]
    let save: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("记录学习成果").dboardFont(size: 17, weight: .semibold)
            TextField("理解了什么，或能做什么？", text: $text, axis: .vertical)
                .textFieldStyle(.plain).dboardFont(size: 15).lineLimit(2...6).focused($focused).accessibilityLabel("学习成果")
            Picker("关联笔记", selection: $noteID) {
                Text("不关联").tag(String?.none)
                ForEach(notes) { note in Text(note.displayTitle).tag(Optional(note.id)) }
            }.dboardFont(size: 12)
            TextField("成果或练习链接，可不填", text: $reference).textFieldStyle(.plain).dboardFont(size: 12).accessibilityLabel("成果链接")
            HStack {
                Spacer()
                Button("取消", action: close).demandButtonStyle(TryControlStyle())
                Button("保存", action: save).demandButtonStyle(WorkspaceActionStyle(prominent: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command).demandKeyboardID("try-learning-outcome-save")
            }
        }.padding(24).frame(width: 380).dboardThemeAccent().onAppear { focused = true }
    }
}
