import SwiftUI

enum DemandFilter: String, CaseIterable, Identifiable {
    case all = "全部", urgent = "紧急", inProgress = "进行中", pending = "待开始", suspended = "挂起", completed = "已完成", incidents = "线上排查"
    var id: String { rawValue }
    func includes(_ item: DItem) -> Bool {
        switch self {
        case .incidents: return item.isIncident
        case .all: return true
        case .urgent: return item.isUrgent
        case .inProgress: return item.status == .inProgress
        case .pending: return item.status == .pending
        case .suspended: return item.status == .suspended
        case .completed: return item.status == .completed
        }
    }
}

extension DBoardViewModel {
    var filteredItems: [DItem] {
        let matches = items.filter { demandFilter.includes($0) && DemandSearch.matches($0, query: demandQuery) }
        if viewMode == .priority { return matches.sorted { $0.priority < $1.priority } }
        var projects: [String] = []
        for item in matches where !projects.contains(item.project) { projects.append(item.project) }
        return projects.flatMap { project in matches.filter { $0.project == project } }
    }

    var filteredArchiveRecords: [ArchivedDemand] {
        DemandArchiveCatalog.visible(demandArchives.records, active: items, filter: demandFilter, query: demandQuery)
    }

    var filteredDemandCount: Int { filteredItems.count + filteredArchiveRecords.count }
    var knownDemandCount: Int { Set(items.map(\.id) + demandArchives.records.map { $0.item.id }).count }

    func showDemands(_ filter: DemandFilter = .all) {
        if [.all, .completed, .incidents].contains(filter) { demandArchives.reloadLocal() }
        demandFilter = filter; demandQuery = ""; workspacePage = .demands
    }
}

struct DemandFilterBar: View {
    @EnvironmentObject var vm: DBoardViewModel
    @ObservedObject var store: DemandArchiveStore
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").dboardFont(size: 12).foregroundStyle(.secondary)
                TextField("搜索需求、项目或进度", text: $vm.demandQuery)
                    .dboardFont(size: 12).textFieldStyle(.plain).accessibilityLabel("搜索本地需求")
                if !vm.demandQuery.isEmpty {
                    Button { vm.demandQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            Picker("需求筛选", selection: $vm.demandFilter) {
                ForEach(DemandFilter.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 104).controlSize(.regular)
            if vm.demandFilter != .all {
                Button { vm.demandFilter = .all; vm.demandQuery = "" } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle").dboardFont(size: 14)
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除筛选")
            }
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }
}

struct DemandContextView: View {
    @EnvironmentObject var vm: DBoardViewModel
    let item: DItem
    @State private var expanded = false
    var body: some View {
        if let link = item.reqFlow {
            // 正式编号、状态和打开入口已在卡片头部展示，这里只补充来源时间与工程声明
            VStack(alignment: .leading, spacing: expanded ? 12 : 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .dboardFont(size: 10, weight: .semibold).foregroundStyle(.secondary)
                        Text("需求上下文").dboardFont(size: 13, weight: .semibold)
                        Spacer()
                        if expanded, let date = vm.reqFlow.cache?.prdGenerated {
                            Text("ReqFlow 快照 \(date)").dboardFont(size: 11).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收起需求上下文" : "展开需求上下文")
                .accessibilityIdentifier("demand-context-" + item.id)
                if expanded {
                    if !vm.reqFlow.prdItems.contains(where: { $0.id == link.id }) {
                        Text("当前快照没有该正式需求，个人状态不会被覆盖")
                            .dboardFont(size: 11).foregroundStyle(.secondary)
                    }
                    DevelopmentProjectsView(snapshot: vm.reqFlow.developmentProjectSnapshots[link.id],
                        loading: vm.reqFlow.deliverableLoading.contains(link.id),
                        error: vm.reqFlow.deliverableReadErrors[link.id],
                        refresh: { vm.reqFlow.loadDeliverableStatus(reqId: link.id, force: true) })
                    DemandDeliveryAction(item: item, coordinator: vm.deliveryCoordinator, refresh: { reqID in
                        vm.reload()
                        if vm.deliveryCoordinator.states[item.id]?.failed != true { vm.scheduleSync() }
                        vm.reqFlow.loadDeliverableStatus(reqId: reqID, force: true)
                    })
                    Text("仅展示开发交付的工程声明；工程不等于发布应用")
                        .dboardFont(size: 11).foregroundStyle(.secondary)
                }
            }
            .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
