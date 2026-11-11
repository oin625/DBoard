import SwiftUI

enum DemandLayout: String, CaseIterable, Identifiable {
    case list, matrix
    var id: String { rawValue }
    var title: String { self == .list ? "列表" : "四象限" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

/// Positive X points toward urgency; positive Y points toward importance.
/// Placement comes from the user's priority, never from an inferred deadline.
enum DemandMatrix {
    static let rows: [[ItemPriority]] = [[.p1, .p0], [.p3, .p2]]
    static func openItems(_ items: [DItem]) -> [DItem] { items.filter { $0.status != .completed } }
    static func items(_ items: [DItem], in priority: ItemPriority) -> [DItem] {
        items.filter { $0.priority == priority }
    }
}

extension DBoardViewModel {
    @discardableResult
    func moveDemand(_ drag: DemandMatrixDrag, to priority: ItemPriority) -> Bool {
        guard drag.priority != priority else { return false }
        return afterWrite(DItemStore.setPriority(id: drag.id, priority, expectedPriority: drag.priority),
            fail: "需求已变化，未移动；请刷新后重试",
            success: "已移到「" + priority.title + "」")
    }
}

struct DemandLayoutPicker: View {
    @Binding var selection: DemandLayout
    var body: some View {
        HStack(spacing: 3) {
            ForEach(DemandLayout.allCases) { layout in
                Button { selection = layout } label: {
                    Label(layout.title, systemImage: layout.symbol)
                        .dboardFont(size: 11, weight: selection == layout ? .semibold : .medium)
                        .foregroundStyle(selection == layout ? Color.primary : .secondary)
                        .frame(width: layout == .matrix ? 76 : 66, height: 28)
                        .background {
                            if selection == layout {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                            }
                        }.contentShape(Rectangle())
                }.demandButtonStyle(.plain)
                    .accessibilityAddTraits(selection == layout ? .isSelected : [])
            }
        }
        .padding(3).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("需求视角").accessibilityIdentifier("demand-layout-picker")
    }
}

struct DemandMatrixView: View {
    @EnvironmentObject var vm: DBoardViewModel
    let items: [DItem]
    @StateObject private var dragging: DemandMatrixDragSession
    private let onMove: ((DemandMatrixDrag, ItemPriority) -> Bool)?

    init(items: [DItem], dragging: DemandMatrixDragSession = .init(),
         onMove: ((DemandMatrixDrag, ItemPriority) -> Bool)? = nil) {
        self.items = DemandMatrix.openItems(items)
        _dragging = StateObject(wrappedValue: dragging)
        self.onMove = onMove
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Label("重要", systemImage: "arrow.up")
                Spacer(minLength: 4)
                Text(dragging.active == nil ? "拖动卡片调整象限" : "松开即可移动")
                    .dboardFont(size: 10).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text("紧急 →")
            }.dboardFont(size: 11, weight: .medium).foregroundStyle(.secondary)
            VStack(spacing: 16) {
                matrixRow(DemandMatrix.rows[0])
                matrixRow(DemandMatrix.rows[1])
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: DemandMatrixFrameKey.self,
                        value: DemandMatrixFrames(board: proxy.frame(in: .global)))
                }
            }
            .overlay {
                DemandMatrixAxes()
                    .stroke(Color.secondary.opacity(0.42),
                            style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if let drag = dragging.active, let item = items.first(where: { $0.id == drag.id }) {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.id).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Text(item.displayTitle).dboardFont(size: 13, weight: .medium).lineLimit(2)
                    }
                    .padding(10).frame(width: min(220, frame.width - 24), alignment: .leading)
                    .workspaceSurface(radius: 11, highlighted: true)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                    .position(x: min(max(120, dragging.location.x - frame.minX), frame.width - 120),
                              y: min(max(36, dragging.location.y - frame.minY), frame.height - 36))
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
        .onPreferenceChange(DemandMatrixFrameKey.self) { dragging.updateFrames($0) }
        .onDisappear { dragging.cancel() }
        .accessibilityIdentifier("demand-matrix").demandKeyboardID("demand-matrix")
    }

    private func matrixRow(_ priorities: [ItemPriority]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(priorities, id: \.rawValue) { priority in
                DemandQuadrant(priority: priority, items: DemandMatrix.items(items, in: priority),
                    dragging: dragging, onMove: onMove)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The axes run through the gutters, leaving cards and scrolling unobstructed.
private struct DemandMatrixAxes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        let arrow: CGFloat = 4
        path.move(to: CGPoint(x: rect.maxX - arrow, y: rect.midY - arrow))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - arrow, y: rect.midY + arrow))
        path.move(to: CGPoint(x: rect.midX - arrow, y: rect.minY + arrow))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + arrow, y: rect.minY + arrow))
        return path
    }
}

private struct DemandQuadrant: View {
    @EnvironmentObject var vm: DBoardViewModel
    let priority: ItemPriority
    let items: [DItem]
    @ObservedObject var dragging: DemandMatrixDragSession
    let onMove: ((DemandMatrixDrag, ItemPriority) -> Bool)?
    private var isTargeted: Bool { dragging.target == priority }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(priority.title).dboardFont(size: 11, weight: .semibold)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .foregroundStyle(priority.color)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(priority.color.opacity(0.085), in: Capsule())
                Spacer(minLength: 0)
                Text("\(items.count)").dboardFont(size: 11, weight: .medium, design: .rounded)
                    .monospacedDigit().foregroundStyle(.secondary).padding(.trailing, 3)
            }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: isTargeted ? "arrow.down.to.line" : "square.dashed")
                        .dboardFont(size: 20, weight: .light).foregroundStyle(.quaternary)
                    Text(isTargeted ? "移到这里" : "暂无需求")
                        .dboardFont(size: 11).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items, id: \.id) { item in
                            DemandMatrixCard(item: item, dragging: dragging, onMove: onMove)
                                .opacity(dragging.active?.id == item.id ? 0.35 : 1)
                        }
                    }.padding(8)
                }.scrollIndicators(.visible)
            }
        }
        .frame(height: 228)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025))
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(
            isTargeted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.055),
            lineWidth: isTargeted ? 1.5 : 0.5))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: DemandMatrixFrameKey.self,
                    value: DemandMatrixFrames(quadrants: [priority: proxy.frame(in: .global)]))
            }
        }
        .accessibilityLabel(priority.title + "，\(items.count) 项")
        .accessibilityIdentifier("demand-quadrant-" + priority.key).demandKeyboardID("demand-quadrant-" + priority.key)
    }
}

struct DemandMatrixCard: View {
    @EnvironmentObject var vm: DBoardViewModel
    let item: DItem
    var dragging: DemandMatrixDragSession? = nil
    var onMove: ((DemandMatrixDrag, ItemPriority) -> Bool)? = nil
    @State private var hovered = false

    private var interaction: DemandMatrixCardInteraction {
        DemandMatrixCardInteraction(drag: .init(id: item.id, priority: item.priority),
            session: dragging, open: open, move: { drag, destination in
                if let onMove { return onMove(drag, destination) }
                return vm.moveDemand(drag, to: destination)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal").dboardFont(size: 9).foregroundStyle(.tertiary)
                        .opacity(hovered ? 1 : 0.45)
                    Text(item.id).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    DemandKindBadge(item: item)
                    Text(item.status.label).dboardFont(size: 10, weight: .medium)
                        .foregroundStyle(item.status == .inProgress ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }.frame(minHeight: 22).modifier(interaction)
                Button { vm.copyCurrentState(item.id) } label: {
                    Image(systemName: "doc.on.doc").dboardFont(size: 11).frame(width: 24, height: 24)
                }.demandButtonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("复制现状：" + item.id)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).dboardFont(size: 13, weight: .medium)
                    .foregroundStyle(.primary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if !item.project.isEmpty {
                    Text(DemandReminder.singleLine(item.project)).dboardFont(size: 11)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).modifier(interaction)
                .accessibilityIdentifier("matrix-open-" + item.id).demandKeyboardID("matrix-open-" + item.id)
            if !item.reminder.isEmpty || vm.reminderDrafts[item.id] != nil {
                DemandReminderView(item: item)
            }
        }
        .padding(10)
        .workspaceSurface(radius: 11, highlighted: hovered)
        .onHover { hovered = $0 }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: DemandMatrixFrameKey.self,
                    value: DemandMatrixFrames(cards: [item.id: proxy.frame(in: .global)]))
            }
        }
        .contextMenu {
            Button("查看详情", action: open)
            Button("复制现状") { vm.copyCurrentState(item.id) }
            Button("复制代码审查", systemImage: "checkmark.bubble") { vm.copyReviewTask(item.id) }
            Button("编辑需求") { vm.openDemandEditor(.details, item: item) }
        }
        .accessibilityIdentifier("matrix-card-" + item.id).demandKeyboardID("matrix-card-" + item.id)
    }

    private func open() {
        vm.openDemandEditor(.inspect, item: item)
    }
}

struct DemandMatrixDetailSheet: View {
    @EnvironmentObject var vm: DBoardViewModel
    let id: String
    let close: () -> Void
    var isolatedExpansion = false

    var body: some View {
        VStack(spacing: 0) {
            if !isolatedExpansion {
                HStack {
                    Text("需求详情").dboardFont(size: 13, weight: .semibold)
                    Spacer()
                    Button("关闭", action: close).controlSize(.small).keyboardShortcut(.cancelAction)
                }.padding(16)
                Divider()
            }
            ScrollView {
                if let item = vm.items.first(where: { $0.id == id }) {
                    ItemCardView(item: item, isolatedExpansion: isolatedExpansion)
                        .padding(.vertical, isolatedExpansion ? 0 : 12)
                } else if let record = vm.demandArchives.records.first(where: { $0.item.id == id }) {
                    DemandArchiveSection(store: vm.demandArchives, filteredRecords: [record], embedded: true)
                        .onAppear { vm.selectedID = record.id }
                } else {
                    EmptyWorkspaceState(icon: "checkmark.circle", title: "这条需求已完成或移除",
                        detail: "完整记录可在「已完成」中查看。", actionTitle: "查看已完成") {
                            close()
                            vm.showDemands(.completed)
                            if isolatedExpansion { vm.demandWorkspacePresenter?() }
                        }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 800, minHeight: 500, idealHeight: 680)
        .background { DemandCanvasBackground() }
        .onAppear { if !isolatedExpansion { vm.expandedIDs.insert(id) } }
    }
}
