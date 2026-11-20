import SwiftUI

enum DemandSearch {
    static func matches(_ item: DItem, query: String) -> Bool {
        let terms = query.trimmed.lowercased().split(whereSeparator: \.isWhitespace)
        let text = ([item.id, item.project, item.displayTitle, item.title, item.branch ?? "", item.reqFlow?.no ?? "", item.kind.rawValue]
            + item.milestones.map { $0.fullContent }).joined(separator: " ").lowercased()
        return terms.allSatisfy { text.contains($0) }
    }
}

enum DemandArchiveCatalog {
    static func visible(_ records: [ArchivedDemand], active: [DItem], filter: DemandFilter, query: String) -> [ArchivedDemand] {
        guard [.all, .completed, .incidents].contains(filter) else { return [] }
        let current = Set(active.map(\.id))
        var seen = Set<String>()
        return records.filter { record in
            // Current data wins over historical snapshots after restoring a completed demand.
            guard !current.contains(record.item.id), seen.insert(record.id).inserted else { return false }
            return filter.includes(record.item) && DemandSearch.matches(record.item, query: query)
        }
    }
}


struct CompletedDemandEntry: Identifiable {
    let item: DItem
    let archive: ArchivedDemand?
    var id: String { item.id }
    var selectionID: String { archive?.id ?? item.id }
    var completionStamp: String? { item.incidentClosure?.closed_at ?? archive?.completedDate }
    var completionDay: String? { completionStamp.map { String($0.prefix(10)) } }
}

enum DemandCompletedCatalog {
    static func entries(current: [DItem], archived: [ArchivedDemand]) -> [CompletedDemandEntry] {
        let currentIDs = Set(current.map(\.id))
        var seen = Set<String>()
        let currentEntries = current.filter { $0.status == .completed && seen.insert($0.id).inserted }
            .map { CompletedDemandEntry(item: $0, archive: nil) }
        let archiveEntries = archived.filter {
            $0.item.status == .completed && !currentIDs.contains($0.item.id) && seen.insert($0.id).inserted
        }.map { CompletedDemandEntry(item: $0.item, archive: $0) }
        return (currentEntries + archiveEntries).enumerated().sorted { left, right in
            let lhs = left.element.completionStamp ?? "", rhs = right.element.completionStamp ?? ""
            return lhs == rhs ? left.offset < right.offset : lhs > rhs
        }.map(\.element)
    }
}

struct DemandListView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @ObservedObject var store: DemandArchiveStore
    @State private var inProgressExpanded = true

    var body: some View {
        let open = vm.visibleOpenDemands
        let completed = vm.filteredItems.filter { $0.status == .completed }
        let archives = vm.filteredArchiveRecords
        let isDefault = vm.isDefaultDemandList
        let count = vm.filteredDemandCount
        let showCompleted = !completed.isEmpty || !archives.isEmpty || (isDefault && count > 0)

        DemandFilterBar(store: store)
        NewItemRow(embedded: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 20).padding(.bottom, 10)
        HStack {
            if isDefault && count > 0 {
                Button { inProgressExpanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Label("进行中", systemImage: "circle.lefthalf.filled").dboardFont(size: 15, weight: .semibold)
                        Text("\(open.count)").dboardFont(size: 12).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: inProgressExpanded ? "chevron.down" : "chevron.right")
                            .dboardFont(size: 10).foregroundStyle(.secondary)
                    }.frame(minHeight: 28).contentShape(Rectangle())
                }.demandButtonStyle(.plain).disabled(open.isEmpty)
                    .accessibilityLabel("\(inProgressExpanded ? "收起" : "展开")进行中，\(open.count)项")
                    .accessibilityIdentifier("in-progress-section-toggle").demandKeyboardID("in-progress-section-toggle")
            } else {
                Text("\(vm.demandFilter.rawValue) · \(count) 项")
                    .dboardFont(size: 11).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("排查经验", systemImage: "books.vertical") { vm.showingKnowledge = true }
                .dboardFont(size: 11).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
        .onChange(of: isDefault) { _, isDefault in
            if isDefault { inProgressExpanded = true }
        }
        .onChange(of: vm.selectedID) { _, id in
            if isDefault && open.contains(where: { $0.id == id }) { inProgressExpanded = true }
        }
        if count == 0 {
            EmptyWorkspaceState(icon: "magnifyingglass",
                title: vm.knownDemandCount == 0 ? "还没有需求" : "没有符合筛选的需求",
                detail: vm.knownDemandCount == 0 ? "点上方「新增需求」开始记录。" : "已完成的需求也可在这里搜索，可清除筛选后查看。",
                actionTitle: vm.knownDemandCount == 0 ? nil : "查看全部", action: { vm.showDemands() })
        } else {
            if !isDefault || inProgressExpanded {
                VStack(spacing: 10) {
                    ForEach(open, id: \.id) { item in
                        ItemCardView(item: item, appearDelay: 0).id(item.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            if showCompleted {
                DemandArchiveSection(store: store, filteredRecords: archives,
                                     currentItems: completed, embedded: true, collapsible: vm.demandFilter != .completed)
            }
        }
        if !showCompleted, let error = store.error, [.all, .completed].contains(vm.demandFilter) {
            Label(error, systemImage: "exclamationmark.triangle")
                .dboardFont(size: 11).foregroundStyle(.orange).padding(.horizontal, 20)
        }
    }
}
