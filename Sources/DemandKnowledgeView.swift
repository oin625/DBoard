import SwiftUI

struct DemandKnowledgeView: View {
    @EnvironmentObject var vm: DBoardViewModel
    let close: () -> Void
    var cacheURL: URL? = nil
    @State private var entries: [DemandKnowledge.Entry] = []
    @State private var error: String?
    @State private var query = ""
    @State private var includeInactive = false
    @State private var expanded: Set<String> = []
    @State private var editing: DemandKnowledge.Entry?

    private var visible: [DemandKnowledge.Entry] {
        let terms = query.trimmed.lowercased().split(whereSeparator: \.isWhitespace)
        return entries.filter { entry in
            let body = ([entry.title, entry.mechanism, entry.procedure, entry.finding, entry.boundaries]
                        + entry.symptoms + entry.scopes).joined(separator: " ").lowercased()
            return (includeInactive || entry.active) && terms.allSatisfy { body.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("排查经验", systemImage: "books.vertical").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("刷新", action: reload).controlSize(.small)
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            TextField("搜索现象、机制、服务或查法", text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Text("\(visible.count) 条经验").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("显示停用", isOn: $includeInactive).toggleStyle(DemandKeyboardToggleStyle()).font(.system(size: 11))
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            ScrollView {
                if visible.isEmpty {
                    Text(error == nil ? "暂无匹配经验。线上排查时由 AI 提炼并维护，你可以在这里查看和修正。" : "读取失败，未按空库覆盖。")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 40)
                }
                let groups = Dictionary(grouping: visible, by: { $0.mechanism.isEmpty ? "原因未定" : $0.mechanism })
                ForEach(groups.keys.sorted(), id: \.self) { mechanism in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(mechanism).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(groups[mechanism] ?? []) { entry in row(entry) }
                    }.padding(.bottom, 12)
                }
            }
        }.padding(20).frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 680)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear(perform: reload)
            .onReceive(vm.objectWillChange) { _ in reload() }
            .sheet(item: $editing) { entry in
                DemandKnowledgeEditor(entry: entry, cacheURL: cacheURL) { editing = nil; reload() }.environmentObject(vm)
            }
    }

    private func reload() {
        do {
            let text: String?
            if let cacheURL { text = try String(contentsOf: cacheURL, encoding: .utf8) }
            else { text = CacheFile.read() }
            guard let text else { throw DemandKnowledge.ReadError.invalid }
            entries = try DemandKnowledge.read(text.components(separatedBy: "\n")).entries
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func row(_ entry: DemandKnowledge.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if !expanded.insert(entry.id).inserted { expanded.remove(entry.id) }
                } label: {
                    HStack {
                        Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                        Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
                }.demandButtonStyle(.plain)
                Button("编辑") { editing = entry }.controlSize(.small)
                Button(entry.active ? "停用" : "启用") {
                    var value = entry; value.active.toggle()
                    if vm.afterWrite(DItemStore.saveKnowledge(value, expected: entry.revision, at: cacheURL),
                                     fail: "经验已变化，请刷新后重试", success: value.active ? "经验已启用" : "经验已停用") { reload() }
                }.controlSize(.small)
            }
            HStack {
                Text(entry.active ? (entry.confidence == "confirmed" ? "根因已确认" : "查法可复用 · 原因待确认") : "已停用")
                    .font(.system(size: 11)).foregroundStyle(entry.active && entry.confidence == "confirmed" ? .green : .secondary)
                if entry.updated_by == "user" { Text("你已修正").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if !entry.scopes.isEmpty { Text(entry.scopes.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary) }
            if expanded.contains(entry.id) {
                detail("适用现象", entry.symptoms.joined(separator: "\n"))
                detail("排查路径", entry.procedure)
                if !entry.finding.isEmpty { detail("已知结论", entry.finding) }
                detail("适用边界", entry.boundaries)
                detail("证据入口", entry.evidence.joined(separator: "\n"))
                HStack {
                    ForEach(entry.sources, id: \.id) { source in
                        Button("查看 " + source.id) { close(); vm.focusItem(source.id) }.font(.system(size: 12))
                    }
                }
            }
        }.padding(12).background(.quaternary.opacity(entry.active ? 0.4 : 0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DemandKnowledgeEditor: View {
    @EnvironmentObject var vm: DBoardViewModel
    let close: () -> Void
    let cacheURL: URL?
    @State private var draft: DemandKnowledgeDraft
    @State private var error: String?

    init(entry: DemandKnowledge.Entry, cacheURL: URL? = nil, close: @escaping () -> Void) {
        self.close = close
        self.cacheURL = cacheURL
        _draft = State(initialValue: DemandKnowledgeDraft.load(entry.id) ?? .init(value: entry, expected: entry.revision))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修正排查经验").font(.system(size: 16, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("名称", $draft.value.title)
                    field("主要机制（未确定可留空）", $draft.value.mechanism)
                    Picker("确定程度", selection: $draft.value.confidence) {
                        Text("根因已确认").tag("confirmed")
                        Text("查法可复用，原因待确认").tag("method")
                    }
                    lines("适用现象（每行一种）", $draft.value.symptoms)
                    lines("服务与适用范围（每行一项）", $draft.value.scopes)
                    field("排查路径：查哪里，不同结果怎样继续", $draft.value.procedure, minimum: 4)
                    field("已知结论", $draft.value.finding, minimum: 2)
                    field("适用边界与尚未确认的部分", $draft.value.boundaries, minimum: 2)
                    lines("证据入口（每行一项）", $draft.value.evidence)
                }.padding(.trailing, 3)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Text("草稿保留；保存后 AI 会保护你的修正。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
                Button("保存") {
                    if vm.afterWrite(DItemStore.saveKnowledge(draft.value, expected: draft.expected, at: cacheURL),
                                     fail: "保存失败：经验可能已变化，草稿保留。", success: "经验已修正") {
                        DemandKnowledgeDraft.clear(draft.value.id); close()
                    } else { error = "请核对最新经验后再保存，当前草稿保留。" }
                }.demandButtonStyle(.borderedProminent).disabled(!draft.value.cleaned.isValid)
            }
        }.padding(20).frame(width: 620, height: 650)
            .onChange(of: draft.value) { _, _ in draft.save() }
    }

    private func field(_ title: String, _ text: Binding<String>, minimum: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(title, text: text, axis: .vertical).lineLimit(minimum...12).textFieldStyle(.roundedBorder)
        }
    }
    private func lines(_ title: String, _ values: Binding<[String]>) -> some View {
        field(title, Binding(get: { values.wrappedValue.joined(separator: "\n") },
                             set: { values.wrappedValue = $0.components(separatedBy: "\n") }), minimum: 2)
    }
}

struct IncidentExperienceView: View {
    let item: DItem
    var body: some View {
        if item.isIncident {
            if let review = item.incidentExperienceReview {
                Text("经验判断：\(review.decision == "skip" ? "暂不沉淀" : review.decision == "create" ? "已新增经验" : "已更新经验") · \(review.reason)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("AI 排查后会判断是否沉淀经验；没有有效结论时只记录进展。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
