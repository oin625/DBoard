import SwiftUI
import AppKit

struct SkillsBoardView: View {
    @EnvironmentObject var vm: SkillsViewModel
    @EnvironmentObject var theme: ThemeManager
    var refreshOnAppear = true
    var popoverMode = false
    var initialSelection: String? = nil
    @State private var selectedID: String?
    @State private var boardTab: BoardTab = .skills
    @StateObject private var envVM = AgentEnvViewModel()
    @State private var environmentLoaded = false
    @State private var showNewCategory = false
    @State private var newCategoryName = ""
    @State private var renameCategory: String?
    @State private var renameText = ""

    enum BoardTab: String, CaseIterable {
        case skills = "技能库", mcp = "MCP", hooks = "Hooks", agents = "Agents", memory = "Context"
    }

    private var selected: SkillItem? { vm.items.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if boardTab == .skills {
                HStack(alignment: .top, spacing: 0) {
                    if !popoverMode { sidebar.frame(width: 180) }
                    if popoverMode, let selected {
                        SkillLibraryDetail(item: selected, close: { selectedID = nil }).id(selected.id)
                    } else {
                        library
                        if let selected {
                            SkillLibraryDetail(item: selected, close: { selectedID = nil })
                                .id(selected.id).frame(width: 350)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            } else {
                environmentPage.padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.current.cardFill)
            }
        }
        .frame(minWidth: popoverMode ? 0 : 760, minHeight: popoverMode ? 0 : 540)
        .background { DemandCanvasBackground() }
        .dboardThemeAccent()
        .focusEffectDisabled()
        .overlay(alignment: .top) {
            if !popoverMode {
                SkillHeaderDragArea().frame(height: 16)
                    .padding(.horizontal, 24).padding(.top, 2)
            }
        }
        .overlay(alignment: .bottom) {
            if !vm.actionMsg.isEmpty {
                Text(vm.actionMsg).dboardFont(size: 12)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .foregroundStyle(theme.current.textPrimary)
                    .background(theme.current.cardFill, in: Capsule())
                    .shadow(color: theme.current.shadow.opacity(0.12), radius: 10, y: 3)
                    .padding(16).allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task(id: vm.actionMsg) {
            let message = vm.actionMsg
            guard !message.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            if vm.actionMsg == message { withAnimation { vm.actionMsg = "" } }
        }
        .onAppear {
            selectedID = initialSelection
            guard refreshOnAppear else { return }
            vm.loadOverrides()
            vm.refreshIfNeeded()
        }
        .onChange(of: boardTab) { _, tab in
            if tab != .skills && !environmentLoaded && refreshOnAppear {
                environmentLoaded = true
                envVM.scan()
            }
        }
        .onExitCommand {
            if selectedID != nil { withAnimation { selectedID = nil } }
            else if !vm.search.isEmpty { vm.search = "" }
            else if !popoverMode { NSApp.keyWindow?.performClose(nil) }
        }
        .alert("新建分类", isPresented: $showNewCategory) {
            TextField("分类名称", text: $newCategoryName)
            Button("创建") { vm.addCategory(newCategoryName); newCategoryName = "" }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名分类", isPresented: Binding(
            get: { renameCategory != nil }, set: { if !$0 { renameCategory = nil } })) {
            TextField("分类名称", text: $renameText)
            Button("保存") {
                if let renameCategory { vm.renameCategory(renameCategory, to: renameText) }
                renameCategory = nil
            }
            Button("取消", role: .cancel) { renameCategory = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { boardTab = .skills }
            } label: {
                Text("Skills").dboardFont(size: 22, weight: .semibold)
                    .foregroundStyle(theme.current.textPrimary)
                    .padding(.vertical, 6)
            }.buttonStyle(DBoardPlainButtonStyle())
            if boardTab != .skills {
                Text("/  " + boardTab.rawValue).dboardFont(size: 14)
                    .foregroundStyle(theme.current.textSecondary)
            }
            Spacer()
            Menu {
                ForEach(BoardTab.allCases.filter { $0 != .skills }, id: \.self) { tab in
                    Button(tab.rawValue) { withAnimation { boardTab = tab } }
                }
            } label: {
                Label("环境", systemImage: "slider.horizontal.3").dboardFont(size: 12)
            }.menuStyle(.borderlessButton).fixedSize()
            Button {
                if boardTab == .skills { vm.scan() } else { envVM.scan() }
            } label: {
                HStack(spacing: 5) {
                    if vm.loading || envVM.loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text("刷新")
                }.dboardFont(size: 12).padding(.horizontal, 10).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }.buttonStyle(DBoardPlainButtonStyle()).disabled(vm.loading || envVM.loading)
            if popoverMode {
                TearOffButton(key: "SkillsBoard")
            } else {
                Group {
                    WorkspacePinButton(id: "skills")
                    DBoardSettingsButton()
                    Button { NSApp.keyWindow?.performClose(nil) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭 Skills 面板")
                }
                .buttonStyle(SkillWindowControlStyle())
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .tearOffHandle("SkillsBoard", enabled: popoverMode)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                sideButton("全部技能", icon: "square.grid.2x2",
                    count: vm.currentItems.count,
                    selected: !vm.showAssetLibrary && !vm.favoritesOnly && vm.categoryFilter == "全部") {
                        vm.switchScope(assetLibrary: false); selectedID = nil
                    }
                sideButton("常用", icon: "star", count: vm.currentItems.filter { vm.favorites.contains($0.id) }.count,
                    selected: vm.favoritesOnly) {
                        vm.switchScope(assetLibrary: false); vm.favoritesOnly = true; selectedID = nil
                    }
                sideButton("本地留存", icon: "archivebox", count: vm.assetItems.count,
                    selected: vm.showAssetLibrary) {
                        vm.switchScope(assetLibrary: true); selectedID = nil
                    }
                HStack {
                    Text("分类").dboardFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.current.textSecondary)
                    Spacer()
                    Button { newCategoryName = ""; showNewCategory = true } label: {
                        Image(systemName: "plus").frame(width: 30, height: 30).contentShape(Rectangle())
                    }.buttonStyle(DBoardPlainButtonStyle()).accessibilityLabel("新建分类")
                }.padding(.top, 20).padding(.horizontal, 10)
                ForEach(vm.categories.filter { $0.0 != "全部" }, id: \.0) { category in
                    sideButton(category.0, icon: nil, count: category.1,
                        selected: vm.categoryFilter == category.0) {
                            vm.categoryFilter = category.0; vm.assetLimit = 40; selectedID = nil
                        }
                        .contextMenu {
                            Button("重命名分类") { renameCategory = category.0; renameText = category.0 }
                            Button("移除分类") { vm.deleteCategory(category.0); vm.categoryFilter = "全部" }
                        }
                }
                ForEach(vm.customCategories.filter { !vm.categories.map(\.0).contains($0) }, id: \.self) { category in
                    sideButton(category, icon: nil, count: 0, selected: vm.categoryFilter == category) {
                        vm.categoryFilter = category
                    }.contextMenu {
                        Button("重命名分类") { renameCategory = category; renameText = category }
                        Button("移除分类") { vm.deleteCategory(category); vm.categoryFilter = "全部" }
                    }
                }
            }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 20)
        }
    }

    private func sideButton(_ title: String, icon: String?, count: Int, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { action() }
        } label: {
            HStack(spacing: 9) {
                if let icon { Image(systemName: icon).frame(width: 17) }
                Text(title).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(count)").dboardFont(size: 11).monospacedDigit()
                    .foregroundStyle(theme.current.textSecondary)
            }.dboardFont(size: 12, weight: selected ? .semibold : .regular)
                .foregroundStyle(selected ? theme.current.accentPrimary : theme.current.textPrimary)
                .padding(.horizontal, 11).frame(height: 38)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10).fill(theme.current.cardFill)
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.current.accentPrimary.opacity(0.3), lineWidth: 1) }
                    }
                }.contentShape(Rectangle())
        }.buttonStyle(DBoardPlainButtonStyle())
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            filters
            HStack {
                Text(vm.favoritesOnly ? "常用技能" : (vm.categoryFilter != "全部" ? vm.categoryFilter : (vm.showAssetLibrary ? "本地留存" : "全部技能")))
                    .dboardFont(size: 14, weight: .semibold)
                Text("\(vm.matchedItems.count)").dboardFont(size: 12)
                    .foregroundStyle(theme.current.textSecondary)
                Spacer()
            }.foregroundStyle(theme.current.textPrimary)
            ScrollView {
                if vm.filtered.isEmpty {
                    VStack(spacing: 10) {
                        if vm.loading { ProgressView(); Text("正在读取本地技能") }
                        else {
                            Image(systemName: vm.favoritesOnly ? "star" : "square.grid.2x2").dboardFont(size: 28)
                            Text(vm.favoritesOnly ? "把常用技能点亮星标，放在这里" : (vm.items.isEmpty ? "没有找到本地技能" : "没有符合筛选的技能"))
                                .dboardFont(size: 12)
                            if !vm.search.isEmpty || vm.categoryFilter != "全部" || vm.sourceFilter != "全部来源" {
                                Button("清除筛选") { vm.clearFilters() }
                            }
                        }
                    }.foregroundStyle(theme.current.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        ForEach(vm.filtered) { card($0) }
                    }.padding(.bottom, 12)
                    if vm.canLoadMore {
                        Button("显示更多（\(vm.filtered.count) / \(vm.matchedItems.count)）") { vm.loadMoreAssets() }
                            .dboardFont(size: 12).padding(12)
                    }
                }
            }
        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filters: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.current.textSecondary)
                TextField("查找技能、用途", text: $vm.search).textFieldStyle(.plain).dboardFont(size: 13)
                if !vm.search.isEmpty {
                    Button { vm.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 26, height: 26)
                    }.buttonStyle(DBoardPlainButtonStyle()).foregroundStyle(theme.current.textSecondary)
                }
            }.padding(.horizontal, 12).frame(height: 40)
                .background(theme.current.cardFill, in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(theme.current.separator.opacity(0.5), lineWidth: 1) }
            HStack(spacing: 12) {
                Menu {
                    ForEach(vm.sourceOptions, id: \.self) { source in
                        Button(source) { vm.sourceFilter = source; vm.assetLimit = 40 }
                    }
                } label: {
                    Label(vm.sourceFilter, systemImage: "line.3.horizontal.decrease")
                        .dboardFont(size: 11)
                }.menuStyle(.borderlessButton).fixedSize()
                if popoverMode {
                    Menu {
                        Button("全部技能") { vm.switchScope(assetLibrary: false) }
                        Button("常用") { vm.switchScope(assetLibrary: false); vm.favoritesOnly = true }
                        Button("本地留存") { vm.switchScope(assetLibrary: true) }
                        Divider()
                        ForEach(vm.categories, id: \.0) { category in
                            Button(category.0) { vm.categoryFilter = category.0 }
                        }
                    } label: { Text("分类").dboardFont(size: 11) }.menuStyle(.borderlessButton)
                }
                Spacer()
            }
        }
    }

    private func card(_ item: SkillItem) -> some View {
        let isSelected = selectedID == item.id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selectedID = isSelected ? nil : item.id }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.displayName).dboardFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.current.textPrimary).lineLimit(1)
                    .truncationMode(.middle).padding(.trailing, 28)
                Text(vm.note(for: item).isEmpty ? (item.desc.isEmpty ? "暂无用途说明" : item.desc) : vm.note(for: item))
                    .dboardFont(size: 12).lineSpacing(3)
                    .foregroundStyle(theme.current.textSecondary).lineLimit(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(spacing: 5) {
                    Text(item.sourceLabels.prefix(2).joined(separator: " · ")).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(item.category).lineLimit(1)
                }.dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).frame(height: 145)
                .background(theme.current.cardFill, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isSelected ? theme.current.accentPrimary : theme.current.separator.opacity(0.65),
                                      lineWidth: isSelected ? 1.5 : 1)
                }
                .shadow(color: theme.current.shadow.opacity(isSelected ? 0.09 : 0.035), radius: 7, y: 2)
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(DBoardPlainButtonStyle())
            .overlay(alignment: .topTrailing) {
                Button { vm.toggleFavorite(item) } label: {
                    Image(systemName: vm.favorites.contains(item.id) ? "star.fill" : "star")
                        .dboardFont(size: 12)
                        .foregroundStyle(vm.favorites.contains(item.id) ? theme.current.accentPrimary : theme.current.textSecondary)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }.buttonStyle(DBoardPlainButtonStyle()).padding(5)
                    .accessibilityLabel(vm.favorites.contains(item.id) ? "取消常用" : "设为常用")
            }
            .contextMenu {
                Button(vm.favorites.contains(item.id) ? "取消常用" : "设为常用") { vm.toggleFavorite(item) }
                Button("复制调用") { vm.copyInvocation(item) }
                Button("打开 SKILL.md") { vm.openSkillMD(item) }
                Button("在 Finder 中查看") { vm.revealInFinder(item) }
                Menu("移入分类") {
                    ForEach(vm.assignableCategories, id: \.self) { category in
                        Button(category) { vm.assign(item, to: category) }
                    }
                }
            }
    }

    @ViewBuilder private var environmentPage: some View {
        switch boardTab {
        case .skills: EmptyView()
        case .mcp: McpBoardView(env: envVM)
        case .hooks: HooksBoardView(env: envVM)
        case .agents: AgentsBoardView(env: envVM)
        case .memory: MemoryBoardView(env: envVM)
        }
    }
}

private struct SkillHeaderDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DemandWindowDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct SkillWindowControlStyle: ButtonStyle {
    @EnvironmentObject private var theme: ThemeManager
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.dboardFont(size: 12)
            .foregroundStyle(theme.current.textSecondary)
            .dboardClickTarget()
            .background(theme.current.accentPrimary.opacity(configuration.isPressed ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}

struct SkillLibraryDetail: View {
    let item: SkillItem
    let close: () -> Void
    @EnvironmentObject private var vm: SkillsViewModel
    @EnvironmentObject private var theme: ThemeManager
    @State private var selectedPath = ""
    @State private var document = ""
    @State private var documentError = ""
    @State private var reading = false
    @State private var editingNote = false
    @State private var noteDraft = ""
    @State private var showDocument = false
    @State private var showFullDescription = false
    @State private var confirmArchive = false
    private var path: String { selectedPath.isEmpty ? item.path : selectedPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayName).dboardFont(size: 17, weight: .semibold).textSelection(.enabled)
                    if item.name != item.dir && !item.name.isEmpty {
                        Text(item.dir).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                    }
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(DBoardPlainButtonStyle()).accessibilityLabel("收起技能详情")
            }.padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 8) {
                        Button { vm.copyInvocation(item, path: path) } label: {
                            Label("复制调用", systemImage: "doc.on.doc").dboardFont(size: 12)
                                .frame(maxWidth: .infinity).frame(height: 36)
                        }.buttonStyle(.borderedProminent)
                        Button { vm.toggleFavorite(item) } label: {
                            Image(systemName: vm.favorites.contains(item.id) ? "star.fill" : "star")
                                .frame(width: 34, height: 34)
                        }.buttonStyle(.bordered).accessibilityLabel("切换常用")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        caption("用途")
                        Text(item.desc.isEmpty ? "SKILL.md 暂无用途说明" : item.desc)
                            .dboardFont(size: 12).lineSpacing(4).textSelection(.enabled)
                            .lineLimit(showFullDescription ? nil : 6)
                        if item.desc.count > 200 {
                            Button(showFullDescription ? "收起" : "完整用途") { withAnimation { showFullDescription.toggle() } }
                                .buttonStyle(DBoardPlainButtonStyle()).dboardFont(size: 11).foregroundStyle(theme.current.accentPrimary)
                        }
                    }
                    noteSection
                    HStack {
                        caption("分类")
                        Spacer()
                        Menu {
                            ForEach(vm.assignableCategories, id: \.self) { category in
                                Button(category) { vm.assign(item, to: category) }
                            }
                            Divider()
                            Button("恢复默认分类") { vm.resetCategory(item) }
                        } label: { Text(item.category).dboardFont(size: 12) }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                    fileSection
                    if !item.problems.isEmpty {
                        Text(item.problems.joined(separator: "\n")).dboardFont(size: 12).foregroundStyle(.orange)
                    }
                    if !documentError.isEmpty {
                        Text(documentError).dboardFont(size: 12).foregroundStyle(.red).textSelection(.enabled)
                    }
                    DisclosureGroup(isExpanded: $showDocument) {
                        if reading { ProgressView().padding(12) }
                        else {
                            SkillDocumentText(text: document)
                                .padding(.top, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } label: {
                        Text("SKILL.md 正文").dboardFont(size: 12, weight: .medium)
                    }
                    if !item.readOnly && item.enabled {
                        Button("归档此技能", role: .destructive) { confirmArchive = true }
                            .buttonStyle(.bordered)
                    } else if !item.readOnly && item.origin == "已归档" {
                        Button("恢复到 Claude 本地目录") { vm.enable(item) }
                            .buttonStyle(.bordered)
                    }
                }.padding(.horizontal, 18).padding(.bottom, 22)
            }
        }
        .foregroundStyle(theme.current.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.current.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.current.separator.opacity(0.6), lineWidth: 1) }
        .padding(.trailing, 14).padding(.top, 10).padding(.bottom, 14)
        .task(id: path) {
            reading = true; document = ""; documentError = ""
            let location = path + "/SKILL.md"
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try String(contentsOfFile: location, encoding: .utf8) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let text): document = text
            case .failure(let error): documentError = "无法读取 SKILL.md：\(error.localizedDescription)"
            }
            reading = false
        }
        .confirmationDialog("归档 \(item.displayName)？", isPresented: $confirmArchive) {
            Button("归档", role: .destructive) { vm.disable(item) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(item.riskyToDisable ? "此技能被其他流程引用，归档可能影响调用。文件会移至本地归档目录。" : "文件会移至本地归档目录。")
        }
    }

    private func caption(_ title: String) -> some View {
        Text(title).dboardFont(size: 11, weight: .medium).foregroundStyle(theme.current.textSecondary)
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption("我的用途备注")
                Spacer()
                if !editingNote {
                    Button(vm.note(for: item).isEmpty ? "添加" : "编辑") {
                        noteDraft = vm.note(for: item)
                        withAnimation(.easeInOut(duration: 0.18)) { editingNote = true }
                    }.buttonStyle(DBoardPlainButtonStyle()).dboardFont(size: 11).foregroundStyle(theme.current.accentPrimary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
            }
            if editingNote {
                TextField("用自己的话写一句用途", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5).dboardFont(size: 12)
                HStack {
                    Button("取消") { withAnimation { editingNote = false } }.buttonStyle(.bordered)
                    Spacer()
                    Button("保存") { vm.setNote(noteDraft, for: item); withAnimation { editingNote = false } }
                        .buttonStyle(.borderedProminent)
                }.controlSize(.small)
            } else if !vm.note(for: item).isEmpty {
                Text(vm.note(for: item)).dboardFont(size: 12).lineSpacing(3).textSelection(.enabled)
            }
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("文件位置")
            if item.availableInstallations.count > 1 {
                Picker("查看来源", selection: Binding(get: { path }, set: { selectedPath = $0 })) {
                    ForEach(item.availableInstallations) { installation in
                        Text(installation.source + " · " + installation.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .tag(installation.path)
                    }
                }.labelsHidden().dboardFont(size: 11)
            }
            Text((path + "/SKILL.md").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("打开文件") { NSWorkspace.shared.open(URL(fileURLWithPath: path + "/SKILL.md")) }
                    .buttonStyle(.bordered)
                Button("Finder") { NSWorkspace.shared.selectFile(path + "/SKILL.md", inFileViewerRootedAtPath: path) }
                    .buttonStyle(.bordered)
                Button("复制路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path + "/SKILL.md", forType: .string)
                    vm.actionMsg = "已复制文件路径"
                }.buttonStyle(.bordered)
            }.dboardFont(size: 11).controlSize(.small)
        }
    }
}

private struct SkillDocumentText: View {
    let text: String
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .dboardFont(size: 12).lineSpacing(5).textSelection(.enabled)
            .foregroundStyle(theme.current.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
