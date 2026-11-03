import SwiftUI

struct DemandProgressRow: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let record: Milestone
    @State private var detailsExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(theme.current.accentPrimary).frame(width: 5, height: 5).padding(.top, 6)
            Text(record.date).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.current.textMuted).fixedSize().padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 8) {
                    Text(record.summary).font(fm.font(14)).foregroundStyle(theme.current.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !record.detailText.isEmpty {
                        Button { detailsExpanded.toggle() } label: {
                            HStack(spacing: 3) {
                                Text(detailsExpanded ? "收起" : "明细")
                                Image(systemName: detailsExpanded ? "chevron.up" : "chevron.down")
                            }.font(.system(size: 11)).foregroundStyle(theme.current.textTertiary)
                        }
                        .buttonStyle(.plain).fixedSize().padding(.top, 2)
                        .accessibilityLabel((detailsExpanded ? "收起明细：" : "展开明细：") + record.summary)
                    }
                }
                if detailsExpanded {
                    Text(record.detailText).font(fm.font(13)).foregroundStyle(theme.current.textSecondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(theme.current.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}
