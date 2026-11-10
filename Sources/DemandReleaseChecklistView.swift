import SwiftUI

struct DemandReleaseDraft {
    var text: String
    let original: DemandReleaseChecklist.Entry?
    var details = ""
    var category: DemandReleaseChecklist.Category? = nil
}

extension DBoardViewModel {
    @discardableResult
    func writeReleaseChecklist(_ id: String, _ update: (inout DemandReleaseChecklist) -> Bool) -> Bool {
        guard DItemStore.updateReleaseChecklist(id: id, update) else {
            showFeedback("上线前事项未保存，输入已保留；记录可能已更新，请重新核对", failed: true)
            return false
        }
        markSelfWrite(); reload()
        return true
    }

    @discardableResult
    func saveReleaseDraft(_ id: String, key: String) -> Bool {
        guard let draft = releaseDrafts[key] else { return true }
        if let original = draft.original, DemandReleaseChecklist.clean(draft.text) == original.text, draft.details.trimmed == original.details, (draft.category ?? original.category) == original.category {
            releaseDrafts[key] = nil
            return true
        }
        guard !draft.text.trimmed.isEmpty else {
            if draft.original == nil && draft.details.trimmed.isEmpty { releaseDrafts[key] = nil; return true }
            showFeedback("事项不能为空；不需要的事项可直接删除", failed: true)
            return false
        }
        guard writeReleaseChecklist(id, { checklist in
            if let original = draft.original { return checklist.edit(original, text: draft.text, details: draft.details, category: draft.category) }
            return checklist.add(draft.text, author: .user, details: draft.details, category: draft.category)
        }) else { return false }
        releaseDrafts[key] = nil
        return true
    }

    func saveReleaseDrafts(_ id: String) -> Bool {
        guard saveReleaseEvidenceDrafts(id) else {
            showFeedback("完成证据未保存，草稿已保留，请先核对后再完成需求", failed: true)
            return false
        }
        for key in releaseDrafts.keys.filter({ $0.hasPrefix(id + ":") }).sorted() {
            if !saveReleaseDraft(id, key: key) { return false }
        }
        return true
    }

    func removeReleaseItem(_ id: String, entry: DemandReleaseChecklist.Entry) {
        guard writeReleaseChecklist(id, { $0.remove(entry) }) else { return }
        releaseDrafts[id + ":" + entry.id] = nil
        offerUndo("恢复上线前事项") { DItemStore.updateReleaseChecklist(id: id) { $0.restore(entry) } }
    }
}

struct DemandReleaseChecklistView: View {
    @EnvironmentObject var vm: DBoardViewModel
    let item: DItem
    var readOnly = false
    @State private var expanded = true
    @State private var collapsedCategories: Set<String> = []
    @State private var addPlacement: DemandReleaseChecklist.Category? = nil
    private var draftKey: String { item.id + ":release-new" }
    private var checklist: DemandReleaseChecklist { item.releaseChecklist }
    private var adding: Bool { !readOnly && vm.releaseDrafts[draftKey] != nil }
    private var categories: [DemandReleaseChecklist.Category] {
        DemandReleaseChecklist.Category.ordered(checklist.items.map(\.category) + [addPlacement].compactMap { $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                if let error = item.releaseChecklistReadError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.orange).padding(.vertical, 6)
                } else {
                    if adding && addPlacement == nil { newItemEditor }
                    ForEach(categories) { category in
                        let entries = checklist.items.filter { $0.category == category }
                        if !entries.isEmpty || (adding && addPlacement == category) {
                            categoryGroup(category, entries: entries)
                        }
                    }
                    if checklist.items.isEmpty && !adding {
                        Text("还没有上线事项").font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            if adding { expanded = true; addPlacement = vm.releaseDrafts[draftKey]?.category }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").font(.system(size: 14))
                    Text("上线前事项").font(.system(size: 13, weight: .semibold))
                    if !checklist.items.isEmpty {
                        Text("\(checklist.completedCount)/\(checklist.items.count)")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(checklist.completedCount == checklist.items.count ? Color.green : Color.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.frame(minHeight: 30).contentShape(Rectangle())
            }.demandButtonStyle(.plain)
                .accessibilityIdentifier("release-section-" + item.id).demandKeyboardID("release-section-" + item.id)
            Spacer(minLength: 6)
            if !readOnly {
                Button { startAdding(in: nil) } label: {
                    Label(adding ? "继续添加" : "添加事项", systemImage: "plus")
                }
                .controlSize(.small).demandButtonStyle(.bordered)
                .disabled(item.releaseChecklistReadError != nil)
                .accessibilityIdentifier("release-add-" + item.id).demandKeyboardID("release-add-" + item.id)
            }
        }
    }

    private func categoryGroup(_ category: DemandReleaseChecklist.Category, entries: [DemandReleaseChecklist.Entry]) -> some View {
        let isOpen = !collapsedCategories.contains(category.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isOpen { collapsedCategories.insert(category.id) }
                        else { collapsedCategories.remove(category.id) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: category.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        Text(category.title).font(.system(size: 12, weight: .semibold))
                        Text(groupCount(entries)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }.frame(minHeight: 30).contentShape(Rectangle())
                }.demandButtonStyle(.plain).accessibilityIdentifier("release-group-" + category.id + "-" + item.id).demandKeyboardID("release-group-" + category.id + "-" + item.id)
                if !readOnly {
                    Button { startAdding(in: category) } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
                    }.demandButtonStyle(ReleaseIconButtonStyle())
                        .accessibilityLabel("添加" + category.title + "事项")
                        .accessibilityIdentifier("release-add-" + category.id + "-" + item.id).demandKeyboardID("release-add-" + category.id + "-" + item.id)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
            if isOpen {
                ForEach(entries) { entry in
                    Divider().padding(.horizontal, 10)
                    DemandReleaseChecklistRow(itemID: item.id, entry: entry, readOnly: readOnly)
                }
                if adding && addPlacement == category {
                    Divider().padding(.horizontal, 10)
                    newItemEditor.padding(8)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    private func groupCount(_ entries: [DemandReleaseChecklist.Entry]) -> String {
        let done = entries.filter(\.done).count
        return done == 0 ? "\(entries.count) 项" : "\(done)/\(entries.count) 已完成"
    }

    private var newItemEditor: some View {
        ReleaseChecklistEditor(draftKey: draftKey, title: "添加上线事项", saveLabel: "添加事项",
            save: { vm.saveReleaseDraft(item.id, key: draftKey) },
            cancel: { vm.releaseDrafts[draftKey] = nil })
    }

    private func startAdding(in category: DemandReleaseChecklist.Category?) {
        if vm.releaseDrafts[draftKey] == nil {
            vm.releaseDrafts[draftKey] = .init(text: "", original: nil, category: category)
        } else if let category {
            vm.releaseDrafts[draftKey]?.category = category
        }
        addPlacement = category
        if let category { collapsedCategories.remove(category.id) }
        expanded = true
    }
}

struct DemandReleaseChecklistRow: View {
    @EnvironmentObject var vm: DBoardViewModel
    let itemID: String
    let entry: DemandReleaseChecklist.Entry
    let readOnly: Bool
    @State private var showingDetails = false
    @State private var showingEvidence = false
    @State private var hovered = false
    private var draftKey: String { itemID + ":" + entry.id }
    private var editing: Bool { !readOnly && vm.releaseDrafts[draftKey] != nil }
    private var hasDetails: Bool { !entry.details.trimmed.isEmpty || entry.text.count > 40 }
    private var detailsText: String {
        [entry.text.count > 40 ? entry.text : "", entry.details].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                checkButton
                Button {
                    if hasDetails { withAnimation(.easeInOut(duration: 0.16)) { showingDetails.toggle() } }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.text).font(.system(size: 13)).strikethrough(entry.done)
                            .foregroundStyle(entry.done ? Color.secondary : Color.primary)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if hasDetails {
                            HStack(spacing: 4) {
                                Text("明细").font(.system(size: 11))
                                Image(systemName: showingDetails ? "chevron.up" : "chevron.down").font(.system(size: 8))
                            }.foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 28).contentShape(Rectangle())
                }.demandButtonStyle(.plain).disabled(!hasDetails)
                    .accessibilityLabel(entry.text + (hasDetails ? "，查看明细" : ""))
                    .accessibilityIdentifier("release-details-" + itemID + "-" + entry.id).demandKeyboardID("release-details-" + itemID + "-" + entry.id)
                if !readOnly || !entry.evidence.trimmed.isEmpty {
                    Button { showingEvidence = true } label: {
                        Label("证据", systemImage: entry.evidence.trimmed.isEmpty ? "photo.badge.plus" : "photo.on.rectangle")
                            .font(.system(size: 11)).frame(minHeight: 28)
                            .foregroundStyle(entry.evidence.trimmed.isEmpty ? Color.secondary : Color.accentColor)
                    }.demandButtonStyle(.plain).disabled(editing)
                        .accessibilityIdentifier("release-evidence-" + itemID + "-" + entry.id).demandKeyboardID("release-evidence-" + itemID + "-" + entry.id)
                        .popover(isPresented: $showingEvidence) {
                            DemandReleaseEvidenceEditor(itemID: itemID, entry: entry, readOnly: readOnly,
                                close: { showingEvidence = false }).environmentObject(vm)
                        }
                }
                if !readOnly {
                    Button { beginEditing() } label: {
                        Image(systemName: "pencil").font(.system(size: 12)).frame(width: 28, height: 28)
                    }.demandButtonStyle(ReleaseIconButtonStyle())
                        .accessibilityLabel("编辑：" + entry.text)
                        .accessibilityIdentifier("release-edit-" + itemID + "-" + entry.id).demandKeyboardID("release-edit-" + itemID + "-" + entry.id)
                }
            }.padding(.horizontal, 8).padding(.vertical, 3)
                .background(hovered && !editing ? Color.primary.opacity(0.035) : Color.clear)
                .onHover { hovered = $0 }
            if editing {
                ReleaseChecklistEditor(draftKey: draftKey, title: "编辑事项", saveLabel: "保存",
                    save: { vm.saveReleaseDraft(itemID, key: draftKey) },
                    cancel: { vm.releaseDrafts[draftKey] = nil },
                    remove: { vm.removeReleaseItem(itemID, entry: entry) })
                    .padding(.horizontal, 8).padding(.bottom, 8)
            } else if showingDetails && hasDetails {
                Text(detailsText).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.4)).frame(width: 2)
                    }
                    .padding(.leading, 42).padding(.trailing, 14).padding(.top, 2).padding(.bottom, 12)
                .accessibilityIdentifier("release-detail-content-" + itemID + "-" + entry.id).demandKeyboardID("release-detail-content-" + itemID + "-" + entry.id)
            }
        }
    }

    private var checkButton: some View {
        Button {
            if !readOnly { vm.writeReleaseChecklist(itemID) { $0.toggle(entry) } }
        } label: {
            Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16)).foregroundStyle(entry.done ? Color.green : Color.secondary)
                .frame(width: 28, height: 28)
        }.demandButtonStyle(.plain).disabled(readOnly || editing)
            .accessibilityLabel((entry.done ? "取消完成：" : "完成：") + entry.text)
            .accessibilityIdentifier("release-check-" + itemID + "-" + entry.id).demandKeyboardID("release-check-" + itemID + "-" + entry.id)
    }

    private func beginEditing() {
        vm.releaseDrafts[draftKey] = vm.releaseDrafts[draftKey] ??
            .init(text: entry.text, original: entry, details: entry.details, category: entry.category)
    }
}

/// Keep drafts in the view model when a card is collapsed or the user switches away.
/// Only Save commits; Cancel discards. Viewing details never starts an editor.
struct ReleaseChecklistEditor: View {
    @EnvironmentObject var vm: DBoardViewModel
    let draftKey: String
    let title: String
    let saveLabel: String
    let save: () -> Bool
    let cancel: () -> Void
    var remove: (() -> Void)? = nil
    @FocusState private var focused: Field?
    @State private var error: String?
    @State private var addingCategory = false
    @State private var categoryName = ""
    @State private var categoryError: String?
    private enum Field { case summary, details, category }
    private var customCategories: [DemandReleaseChecklist.Category] {
        let id = String(draftKey.prefix { $0 != ":" })
        let existing = vm.items.first { $0.id == id }?.releaseChecklist.items.map(\.category) ?? []
        return DemandReleaseChecklist.Category.ordered(existing + [category])
            .filter { !DemandReleaseChecklist.Category.allCases.contains($0) }
    }
    private var category: DemandReleaseChecklist.Category {
        vm.releaseDrafts[draftKey]?.category ?? DemandReleaseChecklist.Category.infer(vm.releaseDrafts[draftKey]?.text ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 24, height: 24)
                }.demandButtonStyle(ReleaseIconButtonStyle())
                    .accessibilityIdentifier("release-cancel-" + draftKey).demandKeyboardID("release-cancel-" + draftKey)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("事项").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("例如：发布 Ultra 服务", text: Binding(
                    get: { vm.releaseDrafts[draftKey]?.text ?? "" },
                    set: { vm.releaseDrafts[draftKey]?.text = DemandReminder.singleLine($0) }))
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($focused, equals: .summary)
                    .padding(8).background(ReleaseFieldBackground(focused: focused == .summary))
                    .onSubmit { focused = .details }
                    .accessibilityIdentifier("release-summary-" + draftKey).demandKeyboardID("release-summary-" + draftKey)
            }
            HStack(spacing: 6) {
                ForEach(DemandReleaseChecklist.Category.allCases) { value in
                    Button { vm.releaseDrafts[draftKey]?.category = value } label: {
                        ReleaseCategoryChoice(category: value, selected: category == value)
                    }.demandButtonStyle(.plain)
                        .accessibilityLabel("分类：" + value.title)
                        .accessibilityAddTraits(category == value ? [.isSelected] : [])
                        .accessibilityIdentifier("release-category-" + value.id + "-" + draftKey).demandKeyboardID("release-category-" + value.id + "-" + draftKey)
                }
            }.accessibilityLabel("常用分类")
            customCategoryControls
            VStack(alignment: .leading, spacing: 5) {
                Text("明细（可选）").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("分支、文件路径、配置参数或执行顺序", text: Binding(
                    get: { vm.releaseDrafts[draftKey]?.details ?? "" },
                    set: { vm.releaseDrafts[draftKey]?.details = $0 }), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(2...7)
                    .focused($focused, equals: .details)
                    .padding(8).background(ReleaseFieldBackground(focused: focused == .details))
                    .accessibilityIdentifier("release-detail-input-" + draftKey).demandKeyboardID("release-detail-input-" + draftKey)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let remove {
                    Button("删除事项", role: .destructive, action: remove)
                        .demandButtonStyle(.plain).font(.system(size: 11)).foregroundStyle(.red).frame(minHeight: 26)
                } else {
                    Text("⌘↩ 保存").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("取消", action: cancel).demandButtonStyle(.bordered).controlSize(.small)
                Button(saveLabel, action: finish).demandButtonStyle(.borderedProminent).controlSize(.small)
                    .disabled(vm.releaseDrafts[draftKey]?.text.trimmed.isEmpty != false)
                    .accessibilityIdentifier("release-save-" + draftKey).demandKeyboardID("release-save-" + draftKey)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
        .onAppear { focused = .summary }
        .onExitCommand(perform: cancel)
        .onKeyPress(.return, phases: .down) { event in
            guard event.modifiers.contains(.command) else { return .ignored }
            finish(); return .handled
        }
        .accessibilityIdentifier("release-editor-" + draftKey).demandKeyboardID("release-editor-" + draftKey)
    }

    private var customCategoryControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !customCategories.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(customCategories) { value in
                        Button { vm.releaseDrafts[draftKey]?.category = value } label: {
                            ReleaseCategoryChoice(category: value, selected: category == value)
                        }.demandButtonStyle(.plain).accessibilityLabel("分类：" + value.title)
                    }
                }
            }
            if addingCategory {
                HStack(spacing: 6) {
                    TextField("例如：数据迁移", text: $categoryName).textFieldStyle(.roundedBorder)
                        .font(.system(size: 12)).focused($focused, equals: .category).onSubmit(useCustomCategory)
                    Button("取消") { addingCategory = false; categoryError = nil }.demandButtonStyle(.plain).font(.system(size: 11))
                    Button("使用", action: useCustomCategory).controlSize(.small).disabled(categoryName.trimmed.isEmpty)
                }.frame(minHeight: 26)
            } else {
                Button {
                    addingCategory = true; categoryName = ""; focused = .category
                } label: {
                    Label("自定义分类", systemImage: "plus").font(.system(size: 11)).frame(minHeight: 24)
                }.demandButtonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("release-custom-category-" + draftKey).demandKeyboardID("release-custom-category-" + draftKey)
            }
            if let categoryError { Text(categoryError).font(.system(size: 11)).foregroundStyle(.orange) }
        }
    }

    private func useCustomCategory() {
        guard let value = DemandReleaseChecklist.Category.named(categoryName) else {
            categoryError = "分类名称需为 1～20 字，不能换行"; return
        }
        vm.releaseDrafts[draftKey]?.category = value
        addingCategory = false; categoryError = nil; focused = .details
    }

    private func finish() {
        guard vm.releaseDrafts[draftKey]?.text.trimmed.isEmpty == false else {
            error = "请填写事项"; return
        }
        if !save() { error = vm.feedback?.message ?? "未保存，输入已保留，请重新核对记录" }
    }
}

private struct ReleaseCategoryChoice: View {
    let category: DemandReleaseChecklist.Category
    let selected: Bool
    private var border: Color { selected ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.6) }
    var body: some View {
        Text(category.title).font(.system(size: 12, weight: selected ? .medium : .regular))
            .frame(maxWidth: .infinity, minHeight: 28)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border, lineWidth: 0.5))
    }
}

private struct ReleaseFieldBackground: View {
    let focused: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                focused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.7), lineWidth: focused ? 1 : 0.5))
    }
}

private struct ReleaseIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.secondary)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }
}

private extension DemandReleaseChecklist.Category {
    var symbol: String {
        switch self {
        case .release: return "shippingbox"
        case .sql: return "cylinder.split.1x2"
        case .configuration: return "slider.horizontal.3"
        case .permission: return "key"
        case .other: return "ellipsis.circle"
        case .custom: return "tag"
        }
    }
}
