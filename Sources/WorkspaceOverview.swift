import SwiftUI
import AppKit

struct WorkspaceOverview: View {
    @EnvironmentObject var vm: DBoardViewModel
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                metric("紧急", vm.urgentCount, color: vm.urgentCount > 0 ? .red : .secondary) {
                    vm.showDemands(.urgent)
                }
                metric("进行中", vm.inProgressCount, color: .primary) { vm.showDemands(.inProgress) }
                metric("今日零碎", vm.totalCount - vm.doneCount, color: .primary) { vm.workspacePage = .todos }
            }
            .padding(.horizontal, 20)
            TodaySection(compactWhenEmpty: true)
            CockpitSection()
            VStack(spacing: 0) {
                HStack {
                    Text("需要关注的需求").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("查看全部") { vm.showDemands() }.controlSize(.small)
                }
                .padding(.horizontal, 20)
                NewItemRow()
                if vm.attentionItems.isEmpty {
                    EmptyWorkspaceState(icon: "checkmark.circle", title: "当前没有紧急或进行中的需求",
                        detail: "所有需求仍可在「需求」中查看。")
                } else {
                    NeedsSection(focused: true)
                }
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private func metric(_ title: String, _ value: Int, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(max(value, 0))").font(.system(size: 24, weight: .semibold))
                    .monospacedDigit().foregroundStyle(color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(value) 项")
    }
}
