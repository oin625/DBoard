import SwiftUI

enum DemandFilter: String, CaseIterable, Identifiable {
    case all = "全部", urgent = "紧急", inProgress = "进行中", pending = "待开始", suspended = "挂起", completed = "已完成"
    var id: String { rawValue }
    func includes(_ item: DItem) -> Bool {
        switch self {
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
        let terms = demandQuery.trimmed.lowercased().split(whereSeparator: \.isWhitespace)
        let matches = items.filter { item in
            let text = ([item.id, item.project, item.displayTitle, item.title, item.branch ?? "", item.reqFlow?.no ?? ""]
                + item.milestones.map { $0.fullContent }).joined(separator: " ").lowercased()
            return demandFilter.includes(item) && terms.allSatisfy { text.contains($0) }
        }
        if viewMode == .priority { return matches.sorted { $0.priority < $1.priority } }
        var projects: [String] = []
        for item in matches where !projects.contains(item.project) { projects.append(item.project) }
        return projects.flatMap { project in matches.filter { $0.project == project } }
    }

    func showDemands(_ filter: DemandFilter = .all) {
        demandFilter = filter; demandQuery = ""; workspacePage = .demands
    }
}

struct DemandFilterBar: View {
    @EnvironmentObject var vm: DBoardViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("搜索编号、名称、项目、分支和进度", text: $vm.demandQuery)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("搜索本地需求")
                Picker("需求筛选", selection: $vm.demandFilter) {
                    ForEach(DemandFilter.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(maxWidth: 130)
            }
            HStack {
                Text("\(vm.demandFilter.rawValue) · \(vm.filteredItems.count) / \(vm.items.count) 项")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if vm.demandFilter != .all || !vm.demandQuery.isEmpty {
                    Button("清除筛选") { vm.demandFilter = .all; vm.demandQuery = "" }
                        .font(.system(size: 11)).buttonStyle(.plain)
                }
            }
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
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
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Text("需求上下文").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if expanded, let date = vm.reqFlow.cache?.prdGenerated {
                            Text("ReqFlow 快照 \(date)").font(.system(size: 11)).foregroundStyle(.secondary)
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
                            .font(.system(size: 11)).foregroundStyle(.secondary)
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
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
