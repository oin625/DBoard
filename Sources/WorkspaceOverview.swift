import SwiftUI
import AppKit

struct WorkspaceOverview: View {
    @EnvironmentObject var vm: DBoardViewModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                metric("紧急", vm.urgentCount, symbol: "bolt.fill", color: vm.urgentCount > 0 ? .red : .secondary) {
                    vm.showDemands(.urgent)
                }
                Divider().frame(height: 28)
                metric("进行中", vm.inProgressCount, symbol: "circle.lefthalf.filled", color: .accentColor) {
                    vm.showDemands(.inProgress)
                }
                Divider().frame(height: 28)
                metric("今日零碎", vm.totalCount - vm.doneCount, symbol: "checklist", color: .secondary) {
                    vm.workspacePage = .todos
                }
            }
            .padding(.vertical, 6)
            .workspaceSurface()
            .padding(.horizontal, 20)
            TodaySection(compactWhenEmpty: true)
            CockpitSection()
            OverviewDemandSection()
        }
        .padding(.top, 18).padding(.bottom, 20)
    }

    private func metric(_ title: String, _ value: Int, symbol: String, color: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).dboardFont(size: 14, weight: .medium)
                    .foregroundStyle(color).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(max(value, 0))").dboardFont(size: 21, weight: .semibold, design: .rounded)
                        .monospacedDigit().foregroundStyle(.primary)
                    Text(title).dboardFont(size: 11).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(DBoardPlainButtonStyle()).accessibilityLabel("\(title)，\(value) 项")
    }
}

struct OverviewDemandSection: View {
    @EnvironmentObject var vm: DBoardViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                NewItemRow(embedded: true)
                Button { vm.showDemands() } label: {
                    HStack(spacing: 4) {
                        Text("查看全部")
                        Image(systemName: "arrow.up.right").dboardFont(size: 10, weight: .semibold)
                    }
                }.demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("overview-all-demands")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 20).padding(.bottom, 12)
            DemandMatrixView(items: vm.items)
        }
    }
}
