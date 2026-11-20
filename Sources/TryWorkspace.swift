import SwiftUI
import AppKit

struct WorkspaceSpacePicker: View {
    @Binding var selection: DBoardSpace
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        HStack(spacing: 3) {
            ForEach(DBoardSpace.allCases, id: \.rawValue) { space in
                Button {
                    selection = space
                } label: {
                    Text(space.title).dboardFont(size: 12, weight: selection == space ? .semibold : .regular)
                        .foregroundStyle(selection == space ? theme.current.accentPrimary : theme.current.textSecondary)
                        .padding(.horizontal, 18).padding(.vertical, 8).frame(minHeight: 36)
                        .contentShape(Rectangle())
                        .background {
                            if selection == space {
                                RoundedRectangle(cornerRadius: 10).fill(theme.current.accentPrimary.opacity(0.11))
                            }
                        }
                }.demandButtonStyle(.plain)
                    .demandKeyboardID("space-" + space.rawValue)
                    .demandKeyboardSelected(selection == space)
                    .accessibilityAddTraits(selection == space ? .isSelected : [])
            }
        }
        .padding(3).background(theme.current.cardFill.opacity(0.38), in: RoundedRectangle(cornerRadius: 13))
        .padding(.top, 10).padding(.bottom, 6)
        .environment(\.demandFloatingCanvas, false)
    }
}

enum TryEntrySearch {
    static func results(in entries: [TryEntry], kind: TryKind, query: String = "", finishedIdeas: Bool = false) -> [TryEntry] {
        entries.filter { item in
            guard item.deletedAt == nil, !item.isEmpty, item.kind == kind else { return false }
            if kind == .idea, (item.status == .done) != finishedIdeas { return false }
            return query.isEmpty || ([item.displayTitle, item.body, item.progress, item.learningSources ?? ""] +
                item.learningNotes.map(\.body) + item.learningOutcomes.map(\.text))
                .joined(separator: " ").localizedCaseInsensitiveContains(query)
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
}

struct TryWorkspaceView: View {
    @ObservedObject var store: TryStore
    var keyboardEnabled = false
    @State private var module: TryWorkspaceModule = .digestion
    private var kind: TryKind { module.entryKind ?? .digestion }
    @State private var query = ""
    @State private var finishedIdeasVisible = false
    @State private var learningSearchVisible = false
    @State private var openNotebookFirst = false
    @State private var trashVisible = false
    @State private var toast: String?
    @State private var writer: TryCaptureWindowController?
    @EnvironmentObject private var theme: ThemeManager

    private var entries: [TryEntry] {
        TryEntrySearch.results(in: store.document.entries, kind: kind, query: query, finishedIdeas: finishedIdeasVisible)
    }
    var body: some View {
        VStack(spacing: 0) {
            if trashVisible {
                TryTrashView(store: store) { trashVisible = false }
            } else if let entry = store.selected, entry.kind != .task {
                TryJournalDetail(store: store, id: entry.id, initiallyBrowsingNotebook: openNotebookFirst, back: { openNotebookFirst = false; store.selectedID = nil },
                    open: { store.selectedID = $0 }, notify: { toast = $0 }).id(entry.id)
            } else {
                VStack(spacing: 0) {
                    moduleHeader
                    if module == .health { TryHealthView(store: .shared, monitor: .shared) }
                    else { home }
                }
            }
            if let error = store.error {
                HStack {
                    Text(error).dboardFont(size: 12).foregroundStyle(.orange)
                    Spacer()
                    Button("重试保存") { _ = store.flush(); store.reload() }.demandButtonStyle(TryControlStyle())
                }.padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).dboardFont(size: 12).padding(12)
                    .background(.regularMaterial, in: Capsule()).padding(16)
            }
        }
        .onChange(of: toast) { _, value in
            guard let value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if toast == value { toast = nil } }
        }
        .onAppear { store.reload() }
        .onDisappear { _ = store.flush() }
        .dboardDrawingLinks()
        .dboardFont(size: 13).dboardThemeAccent()
        .environment(\.demandFloatingCanvas, false)
        .disclosureGroupStyle(TryDisclosureStyle())
    }
    private var moduleHeader: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                ForEach([TryWorkspaceModule.health, .digestion, .idea]) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { module = item; query = ""; finishedIdeasVisible = false }
                    } label: {
                        Text(item.title).dboardFont(size: 22, weight: module == item ? .semibold : .regular)
                            .foregroundStyle(module == item ? theme.current.textPrimary : theme.current.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                            .background {
                                if module == item { RoundedRectangle(cornerRadius: 12).fill(theme.current.accentPrimary.opacity(0.09)) }
                            }
                    }.demandButtonStyle(.plain)
                }
            }
            Spacer()
            if module == .digestion {
                Button { learningSearchVisible.toggle() } label: { Image(systemName: "magnifyingglass") }
                    .demandButtonStyle(TryControlStyle()).accessibilityLabel("搜索学习主题")
            }
            if module != .health {
            Button { capture() } label: {
                Label(kind == .digestion ? "开启学习" : "记个想法", systemImage: "plus")
            }.demandButtonStyle(WorkspaceActionStyle(prominent: true))
            }
            Menu {
                if module == .idea {
                    Button(finishedIdeasVisible ? "查看当前想法" : "查看已告一段落的想法") {
                        finishedIdeasVisible.toggle(); query = ""
                    }
                }
                Button("回收站") { trashVisible = true }
            } label: { Image(systemName: "ellipsis") }
                .demandMenuStyle(TryMenuStyle()).menuIndicator(.hidden).accessibilityLabel("更多")
        }
        .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 6)
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if kind != .digestion {
                    Text(finishedIdeasVisible ? "已告一段落的想法，可回看或继续。" : "念头、观察、问题，先记下来。")
                        .dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
                }
                if (kind == .digestion && learningSearchVisible) || (kind != .digestion && (!entries.isEmpty || !query.isEmpty)) {
                    TextField(kind == .digestion ? "搜索主题、笔记或成果" : "找一下想法", text: $query)
                        .textFieldStyle(.plain).dboardFont(size: 13).padding(12).workspaceSurface(radius: 12)
                        .accessibilityLabel("搜索个人记录")
                }
                if kind == .digestion {
                    TryLearningHome(entries: entries, searching: !query.isEmpty,
                        open: { openNotebookFirst = false; store.selectedID = $0 },
                        notebook: { openNotebookFirst = true; store.selectedID = $0 }, create: capture)
                } else if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(query.isEmpty ? (finishedIdeasVisible ? "还没有告一段落的想法" : "这里留给你的下一个念头") : "没有找到相关记录")
                            .dboardFont(size: 18, weight: .medium)
                        Text(query.isEmpty ? (finishedIdeasVisible ? "想法结束后会保留在这里，可随时回看或继续。" : "文字、链接、图片都可以直接放进来，未写完的内容会保留。") : "换个关键词试试。")
                            .dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
                        if query.isEmpty, !finishedIdeasVisible {
                            Button("写下来") { capture() }
                                .demandButtonStyle(WorkspaceActionStyle())
                        }
                    }.padding(28).frame(maxWidth: .infinity, minHeight: 190, alignment: .leading).workspaceSurface(radius: 18)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 265), spacing: 18)], spacing: 18) {
                        ForEach(entries) { entry in
                            TryLearningCard(entry: entry, remove: {
                                if store.trash(entry.id) { toast = "已移到回收站" }
                            }) {
                                guard store.flush() else { return }
                                store.selectedID = entry.id
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private func capture() {
        if writer == nil { writer = TryCaptureWindowController(store: store) }
        writer?.show(kind)
    }
}

struct TryEntryCard: View {
    let entry: TryEntry
    var project: TryProject?
    var remove: (() -> Void)? = nil
    let open: () -> Void
    @State private var hovered = false
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        ZStack(alignment: .topTrailing) {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(entry.kind.title).dboardFont(size: 11, weight: .medium).foregroundStyle(theme.current.accentSecondary)
                    Spacer()
                    if entry.status != .active {
                        Text(entry.statusTitle).dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                    }
                }.padding(.trailing, remove == nil ? 0 : 28)
                if !entry.pendingAdditions.isEmpty {
                    Text(String(entry.pendingAdditions.count) + " 项追加待处理")
                        .dboardFont(size: 11, weight: .medium).foregroundStyle(theme.current.accentPrimary)
                }
                Text(entry.displayTitle).dboardFont(size: 17, weight: .semibold).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.progress.isEmpty ? preview : entry.progress)
                    .dboardFont(size: 12).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                if !entry.nextStep.isEmpty {
                    Text(entry.nextStep).dboardFont(size: 11).foregroundStyle(theme.current.accentPrimary).lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack {
                    if let project { Text(project.name).lineLimit(1) }
                    Spacer()
                    Text(Date(timeIntervalSince1970: entry.updatedAt), style: .relative)
                }.dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 175, alignment: .topLeading)
            .workspaceSurface(radius: 14, highlighted: hovered)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }.demandButtonStyle(.plain).accessibilityLabel(entry.kind.title + "，" + entry.displayTitle)
        .contextMenu {
            if let remove { Button("移到回收站", role: .destructive, action: remove) }
        }
        if let remove {
            Button(action: remove) { Image(systemName: "trash").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary) }
                .demandButtonStyle(TryControlStyle()).padding(6).demandKeyboardID("try-trash-" + entry.id).accessibilityLabel("移到回收站")
        }
        }
        .onHover { hovered = $0 }
    }
    private var preview: String {
        let body = DemandImageMarkdown.references(in: entry.body).reduce(entry.body) { $0.replacingOccurrences(of: $1.markdown, with: "〔图片〕") }
        guard !body.isEmpty else { return "" }
        if entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        }
        return body
    }
}

struct TryEntryDetail: View {
    @ObservedObject var store: TryStore
    let id: String
    var initiallyEditing = false
    var openProject: (String) -> Void
    var notify: (String) -> Void
    var select: ((String?) -> Void)? = nil
    var compose: ((TryKind, String?, String?) -> Void)? = nil
    @State private var editing = false
    @State private var referencesExpanded = false
    @State private var historyExpanded = false
    @State private var summaryExpanded = false
    @State private var aiExpanded = false
    @State private var nextStepVisible = false
    @State private var addingContent = false
    @State private var additionPresentationRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var adoptConfirmation = false
    @State private var linkedWriter: TryCaptureWindowController?
    @StateObject private var controller = TryNoteController()
    @FocusState private var nextStepFocused: Bool
    @EnvironmentObject private var theme: ThemeManager

    private var entry: TryEntry? { store.entry(id) }
    private func choose(_ id: String?) {
        if let select { select(id) } else { store.selectedID = id }
    }
    private func text(_ field: String) -> Binding<String> {
        Binding(get: {
            guard let entry else { return "" }
            switch field { case "title": return entry.title; case "progress": return entry.progress; case "nextStep": return entry.nextStep; default: return entry.body }
        }, set: { store.edit(id, field: field, value: $0) })
    }
    var body: some View {
        if let entry, entry.kind != .task {
            TryJournalDetail(store: store, id: id, back: { choose(nil) },
                open: { choose($0) }, notify: notify)
        } else if let entry {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    toolbar(entry)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            TextField(entry.displayTitle, text: text("title"), axis: .vertical)
                                .textFieldStyle(.plain).dboardFont(size: 27, weight: .semibold)
                                .accessibilityLabel("标题")
                            writingSection(entry)
                            if addingContent || !store.additionDraft(id).isEmpty || !(entry.additions ?? []).isEmpty {
                                TryTaskAdditionsView(store: store, id: id, composing: $addingContent,
                                    presentationRequest: additionPresentationRequest,
                                    revealComposer: { focus in
                                        revealAddition(TryTaskAdditionsView.composerAnchor(id), proxy: proxy, focus: focus)
                                    },
                                    didSave: { additionID in
                                        revealAddition(TryTaskAdditionsView.rowAnchor(id, additionID), proxy: proxy)
                                    }, notify: notify)
                            }
                            if entry.kind != .idea || !entry.progress.isEmpty || !entry.nextStep.isEmpty {
                                progressSection(entry)
                            } else {
                                resultSection(entry)
                            }
                            referenceSection(entry)
                            statusActions(entry)
                        }
                        .padding(.horizontal, 30).padding(.vertical, 18)
                        .frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }
            }
            .disclosureGroupStyle(TryDisclosureStyle())
            .onAppear { editing = true }
            .onDisappear { controller.end(); _ = store.flush() }
            .alert("将 AI 整理结果追加到正文？", isPresented: $adoptConfirmation) {
                Button("追加") { controller.end(); _ = store.adopt(id) }
                Button("取消", role: .cancel) {}
            } message: { Text("保留你原来写的内容，在末尾追加这一份结果。") }
        }
    }

    private func revealAddition(_ anchor: String, proxy: ScrollViewProxy, focus: (() -> Void)? = nil) {
        // Let the inserted editor (or saved row) finish layout before locating it.
        DispatchQueue.main.async {
            guard store.entry(id) != nil, focus == nil || addingContent else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                proxy.scrollTo(anchor, anchor: .top)
            }
            if let focus {
                DispatchQueue.main.async {
                    guard addingContent else { return }
                    focus()
                }
            }
        }
    }

    private func toolbar(_ entry: TryEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                controller.end()
                if store.flush() { choose(nil) }
            } label: { Image(systemName: "chevron.left") }
                .demandButtonStyle(TryControlStyle()).accessibilityLabel("返回次 Try")
            Text(entry.kind.title).dboardFont(size: 12).foregroundStyle(theme.current.accentSecondary)
            Spacer()
            if entry.kind == .task {
                Button {
                    controller.end()
                    addingContent = true
                    additionPresentationRequest += 1
                } label: { Label("追加内容", systemImage: "plus") }
                    .demandButtonStyle(TryControlStyle()).dboardFont(size: 12)
                    .demandKeyboardID("try-add-content")
            }
            Button {
                controller.end()
                guard let handoff = store.handoff(id) else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(handoff, forType: .string)
                notify("已复制，交给 AI " + entry.kind.aiAction)
            } label: { Label(entry.kind.aiAction, systemImage: "sparkles") }
                .demandButtonStyle(WorkspaceActionStyle())
            Button {
                controller.end()
                if store.trash(id) { notify("已移到回收站，可恢复"); choose(nil) }
            } label: { Image(systemName: "trash") }
                .demandButtonStyle(TryControlStyle()).accessibilityLabel("移到回收站")
            options(entry)
        }.padding(.horizontal, 26).padding(.vertical, 12)
    }

    private func writingSection(_ entry: TryEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if entry.kind == .task { sectionTitle("要做什么") }
            TryNoteEditor(text: text("body"), editing: $editing,
                bookmark: store.bookmarks[id], minimumHeight: 150, maximumHeight: 560, autofocus: false, controller: controller,
                onBookmark: { store.remember(id, bookmark: $0) }, onEnd: { _ = store.flush() })
                .overlay(alignment: .topLeading) {
                    if entry.body.isEmpty {
                        Text(entry.kind.placeholder).dboardFont(size: 16).foregroundStyle(theme.current.textSecondary)
                            .padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Button { editing = true; controller.images() } label: { Image(systemName: "photo") }
                    .demandButtonStyle(TryControlStyle()).accessibilityLabel("添加图片")
                Menu {
                    Button("小标题") { controller.insert("\n## ") }
                    Button("列表") { controller.insert("\n- ") }
                    if entry.kind == .digestion {
                        Button("我的理解 / 还有疑问") { controller.insert("\n\n## 我的理解\n\n## 还有疑问\n") }
                    }
                } label: { Image(systemName: "textformat") }
                    .demandMenuStyle(TryMenuStyle()).menuIndicator(.hidden).accessibilityLabel("插入段落")
                Spacer()
            }.foregroundStyle(.secondary)
            if let error = controller.error { Text(error).dboardFont(size: 12).foregroundStyle(.orange) }
        }
        .padding(22)
        .workspaceSurface(radius: 16)
    }

    private func progressSection(_ entry: TryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle(entry.kind == .digestion ? "消化到哪了" : "当前进展")
                Spacer()
                if entry.nextStep.isEmpty && !nextStepVisible {
                    Button {
                        nextStepVisible = true
                        nextStepFocused = true
                    } label: { Label("下一步", systemImage: "plus") }
                        .demandButtonStyle(TryControlStyle()).dboardFont(size: 11).foregroundStyle(.secondary)
                        .accessibilityLabel("添加下一步").demandKeyboardID("try-add-next-step")
                }
            }
            TextField("写一句现在的情况…", text: text("progress"), axis: .vertical)
                .textFieldStyle(.plain).dboardFont(size: 14).lineLimit(1...4)
                .accessibilityLabel("当前进展")
            if !entry.nextStep.isEmpty || nextStepVisible {
                VStack(alignment: .leading, spacing: 6) {
                    Text("下一步").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                    TextField(entry.kind == .digestion ? "下次想弄明白什么？" : "下一件要做的事，可不填", text: text("nextStep"), axis: .vertical)
                        .textFieldStyle(.plain).dboardFont(size: 13).lineLimit(1...4)
                        .focused($nextStepFocused).accessibilityLabel("下一步")
                }
            }
            resultSection(entry)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface(radius: 16)
    }

    @ViewBuilder
    private func resultSection(_ entry: TryEntry) -> some View {
        if !entry.aiResult.isEmpty {
            DisclosureGroup(isExpanded: $aiExpanded) {
                DemandSpellContentView(text: entry.aiResult).padding(.top, 10)
                Button("采纳到正文") { adoptConfirmation = true }
                    .demandButtonStyle(WorkspaceActionStyle()).padding(.top, 10)
                    .demandKeyboardID("try-adopt-result")
            } label: {
                Text(entry.pendingAdditions.isEmpty ? "AI 最新结果" : "AI 结果 · 仍有追加待处理").dboardFont(size: 12).foregroundStyle(.secondary)
            }.demandKeyboardID("try-result")
        }
    }

    private func referenceSection(_ entry: TryEntry) -> some View {
        DisclosureGroup(isExpanded: $referencesExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                metadata(entry)
                let related = entry.relatedIDs.compactMap { store.entry($0) }
                if !related.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("相关记录").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                        ForEach(related) { related in
                            Button(related.kind.title + " · " + related.displayTitle) {
                                controller.end()
                                if store.flush() { choose(related.id) }
                            }.demandButtonStyle(TryControlStyle(fillWidth: true)).dboardFont(size: 12)
                                .foregroundStyle(theme.current.accentPrimary)
                        }
                    }
                }
                if !entry.aiSummary.isEmpty {
                    DisclosureGroup(isExpanded: $summaryExpanded) {
                        DemandSpellContentView(text: entry.aiSummary).padding(.top, 10)
                    } label: {
                        Text("AI 交接摘要").dboardFont(size: 12).foregroundStyle(.secondary)
                    }.demandKeyboardID("try-summary")
                }
                if !entry.reports.isEmpty {
                    DisclosureGroup(isExpanded: $historyExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(entry.reports.reversed()) { report in
                                if report.details.isEmpty {
                                    Text(report.summary).dboardFont(size: 12)
                                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10)
                                } else {
                                    DisclosureGroup {
                                        DemandSpellContentView(text: report.details).padding(.top, 8)
                                    } label: {
                                        Text(report.summary).dboardFont(size: 12)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }.padding(.top, 10)
                    } label: {
                        Text("反馈记录 · " + String(entry.reports.count)).dboardFont(size: 12).foregroundStyle(.secondary)
                    }.demandKeyboardID("try-history")
                }
            }.padding(.top, 12)
        } label: {
            HStack {
                Text("资料与记录").dboardFont(size: 12, weight: .medium)
                Spacer()
                if let project = store.document.projects.first(where: { $0.id == entry.projectID }) {
                    Text(project.name).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary).lineLimit(1)
                }
            }.foregroundStyle(.secondary)
        }
        .padding(12).workspaceSurface(radius: 14)
        .demandKeyboardID("try-references")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).dboardFont(size: 12, weight: .medium).foregroundStyle(theme.current.textPrimary)
    }

    private func statusActions(_ entry: TryEntry) -> some View {
        HStack(spacing: 12) {
            if entry.status == .active {
                Button(entry.kind.doneTitle) {
                    controller.end()
                    if store.status(id, .done) { notify(entry.kind == .task ? "已确认完成" : "已留存，随时可以继续") }
                }.demandButtonStyle(WorkspaceActionStyle())
                Button("先搁置") { controller.end(); _ = store.status(id, .shelved) }
                    .demandButtonStyle(TryControlStyle()).dboardFont(size: 12).foregroundStyle(.secondary)
            } else {
                Text(entry.statusTitle).dboardFont(size: 12).foregroundStyle(.secondary)
                Button("继续") { _ = store.status(id, .active) }.demandButtonStyle(WorkspaceActionStyle())
            }
            Spacer()
        }.padding(.top, 2)
    }

    private func metadata(_ entry: TryEntry) -> some View {
        HStack(spacing: 12) {
            Menu {
                Button("不归属项目") { _ = store.setProject(id, projectID: nil) }
                ForEach(store.document.projects) { project in
                    Button(project.name) { _ = store.setProject(id, projectID: project.id) }
                }
                Divider()
                Button("新建项目") {
                    controller.end()
                    if let projectID = store.project(name: "新项目") {
                        _ = store.setProject(id, projectID: projectID); openProject(projectID)
                    }
                }
            } label: {
                Text(store.document.projects.first(where: { $0.id == entry.projectID })?.name ?? "未归属项目").lineLimit(1)
            }.demandMenuStyle(TryMenuStyle()).dboardFont(size: 11)
            if let projectID = entry.projectID {
                Button("共用资料") { controller.end(); openProject(projectID) }
                    .demandButtonStyle(TryControlStyle()).dboardFont(size: 11)
            }
            if let conversion = entry.conversions.last {
                Text("由" + conversion.from.title + "转来").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
            }
            Spacer()
        }.foregroundStyle(.secondary)
    }

    private func options(_ entry: TryEntry) -> some View {
        Menu {
            ForEach(TryKind.allCases.filter { $0 != entry.kind }) { kind in
                Button("转为" + kind.title) { controller.end(); _ = store.convert(id, to: kind) }
                Button("关联新" + kind.title) {
                    controller.end()
                    if let compose { compose(kind, entry.projectID, id) }
                    else {
                        if linkedWriter == nil { linkedWriter = TryCaptureWindowController(store: store) }
                        linkedWriter?.show(kind, projectID: entry.projectID, relatedID: id)
                    }
                }
            }
        } label: { Image(systemName: "ellipsis") }
            .demandMenuStyle(TryMenuStyle()).menuIndicator(.hidden).accessibilityLabel("转换或关联记录")
    }
}

struct TryProjectEditor: View {
    @ObservedObject var store: TryStore
    let project: TryProject
    let back: () -> Void
    @EnvironmentObject private var theme: ThemeManager
    @State private var editing = false
    @StateObject private var controller = TryNoteController()
    private var current: TryProject { store.document.projects.first { $0.id == project.id } ?? project }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { controller.end(); if store.flush() { back() } } label: { Label("返回", systemImage: "chevron.left") }
                    .demandButtonStyle(TryControlStyle())
                Spacer()
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TextField("项目名称", text: Binding(get: { current.name }, set: { store.editProject(project.id, field: "name", value: $0) }))
                        .textFieldStyle(.plain).dboardFont(size: 26, weight: .semibold)
                    Text("项目共用资料").dboardFont(size: 13, weight: .medium)
                    Text("仓库、代码入口、设计约定或学习资料，写一次，关联的记录都能给 AI 使用。")
                        .dboardFont(size: 12).foregroundStyle(.secondary)
                    TryNoteEditor(text: Binding(get: { current.context }, set: { store.editProject(project.id, field: "context", value: $0) }),
                        editing: $editing, bookmark: store.bookmarks[project.id], controller: controller,
                        onBookmark: { store.remember(project.id, bookmark: $0) }, onEnd: { _ = store.flush() })
                        .padding(20).workspaceSurface(radius: 16)
                    HStack {
                        Button("添加图片") { editing = true; controller.images() }.demandButtonStyle(TryControlStyle())
                        Spacer()
                        Button(editing ? "写好了" : "编辑资料") { if editing { controller.end() } else { editing = true; controller.focus() } }
                            .demandButtonStyle(TryControlStyle())
                    }.dboardFont(size: 12)
                    if let error = controller.error { Text(error).dboardFont(size: 12).foregroundStyle(.orange) }
                }.padding(30).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
            }
        }.onDisappear { controller.end(); _ = store.flush() }
    }
}
