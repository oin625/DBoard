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
            guard !current.contains(record.item.id), seen.insert(record.item.id).inserted else { return false }
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
            $0.item.status == .completed && !currentIDs.contains($0.item.id) && seen.insert($0.item.id).inserted
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
    @ObservedObject var preferences: WorkspacePreferences = .shared
    var body: some View {
        DemandFilterBar(store: store)
        HStack(spacing: 8) {
            DemandLayoutPicker(selection: $preferences.demandLayout)
            Spacer(minLength: 8)
            NewItemRow(embedded: true)
        }.padding(.horizontal, 20).padding(.bottom, 10)
        HStack {
            Text("\(vm.demandFilter.rawValue) · \(vm.filteredDemandCount) 项")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button("排查经验", systemImage: "books.vertical") { vm.showingKnowledge = true }
                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.bottom, 8)
        if vm.filteredDemandCount == 0 {
            EmptyWorkspaceState(icon: "magnifyingglass",
                title: vm.knownDemandCount == 0 ? "还没有需求" : "没有符合筛选的需求",
                detail: vm.knownDemandCount == 0 ? "点上方「新增需求」开始记录。" : "已完成的需求也可在这里搜索，可清除筛选后查看。",
                actionTitle: vm.knownDemandCount == 0 ? nil : "查看全部", action: { vm.showDemands() })
        } else {
            let open = DemandMatrix.openItems(vm.filteredItems)
            if !open.isEmpty {
                if preferences.demandLayout == .matrix { DemandMatrixView(items: open) }
                else { NeedsSection(items: open) }
            }
            let completed = vm.filteredItems.filter { $0.status == .completed }
            if !completed.isEmpty || !vm.filteredArchiveRecords.isEmpty {
                DemandArchiveSection(store: store, filteredRecords: vm.filteredArchiveRecords,
                                     currentItems: completed, embedded: true, collapsible: vm.demandFilter != .completed)
            }
        }
        if vm.filteredArchiveRecords.isEmpty, let error = store.error, [.all, .completed].contains(vm.demandFilter) {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 20)
        }
    }
}
