import SwiftUI

struct TryLearningHome: View {
    let entries: [TryEntry]
    let searching: Bool
    let open: (String) -> Void
    let notebook: (String) -> Void
    let create: () -> Void
    @State private var completedExpanded = false
    @State private var shelvedExpanded = false
    @EnvironmentObject private var theme: ThemeManager
    private var active: [TryEntry] { entries.filter { $0.learningFinishedAt == nil && $0.status == .active } }
    private var completed: [TryEntry] { entries.filter { $0.learningFinishedAt != nil || $0.status == .done } }
    private var shelved: [TryEntry] { entries.filter { $0.learningFinishedAt == nil && $0.status == .shelved } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text(searching ? "没有找到相关主题" : "从一个想弄懂的问题开始")
                        .dboardFont(size: 21, weight: .medium)
                    if !searching {
                        Button("开启学习", action: create).demandButtonStyle(WorkspaceActionStyle(prominent: true))
                    }
                }.padding(28).frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
                    .workspaceSurface(radius: 18)
            }
            ForEach(active) { item in
                TryLearningHomeCard(entry: item, open: { open(item.id) }, notebook: { notebook(item.id) })
            }
            if !shelved.isEmpty {
                DisclosureGroup("先搁置 · \(shelved.count)", isExpanded: $shelvedExpanded) {
                    ForEach(shelved) { item in
                        compact(item).padding(.top, 8)
                    }
                }.demandKeyboardID("try-learning-shelved")
            }
            if !completed.isEmpty {
                DisclosureGroup("回看 · \(completed.count)", isExpanded: $completedExpanded) {
                    ForEach(completed) { item in
                        compact(item).padding(.top, 8)
                    }
                }.demandKeyboardID("try-learning-completed")
            }
        }
    }
    private func compact(_ item: TryEntry) -> some View {
        HStack(spacing: 12) {
            Button { open(item.id) } label: {
                HStack(spacing: 12) {
                    Text(item.id).dboardFont(size: 11, design: .monospaced).foregroundStyle(theme.current.textSecondary)
                    Text(item.displayTitle).dboardFont(size: 15, weight: .medium).lineLimit(2)
                    Spacer()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.demandButtonStyle(TryControlStyle(fillWidth: true))
            Button("笔记本") { notebook(item.id) }.demandButtonStyle(TryControlStyle())
        }.padding(12).workspaceSurface(radius: 13)
    }
}

struct TryLearningHomeCard: View {
    let entry: TryEntry
    let open: () -> Void
    let notebook: () -> Void
    @EnvironmentObject private var theme: ThemeManager
    private var summary: TryLearningQuickSummary { TryLearningQuickSummary(entry) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(entry.id).dboardFont(size: 11, weight: .medium, design: .monospaced)
                    .foregroundStyle(theme.current.accentPrimary)
                Spacer()
                Text(entry.learningConfig?.overdue == true ? "到期复盘" : "进行中")
                    .dboardFont(size: 11, weight: .medium)
                    .foregroundStyle(entry.learningConfig?.overdue == true ? .orange : theme.current.accentPrimary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Button(action: open) {
                    Text(entry.displayTitle).dboardFont(size: 24, weight: .semibold)
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }.demandButtonStyle(.plain).demandKeyboardID("try-learning-home-open-" + entry.id)
                Text(summary.goal).dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
                    .lineLimit(2).lineSpacing(4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.current).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                Text(entry.learningFinishedAt == nil && entry.learningAction == "lesson"
                     ? entry.currentLearningUnit?.title ?? entry.currentLearningStage?.summary ?? summary.next
                     : summary.next)
                    .dboardFont(size: 16, weight: .medium).lineLimit(3).lineSpacing(4)
                if !entry.progress.isEmpty {
                    Text(entry.progress).dboardFont(size: 12).foregroundStyle(theme.current.accentPrimary).lineLimit(2)
                }
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.current.accentPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            if summary.stageCount > 0 {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        ForEach(0..<summary.stageCount, id: \.self) { index in
                            Capsule().fill(theme.current.accentPrimary.opacity(index < summary.masteredCount ? 0.9 : 0.12))
                                .frame(width: 22, height: 4)
                        }
                    }
                    Text("\(summary.masteredCount) / \(summary.stageCount) 阶段已核验")
                        .dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    actions
                    Spacer()
                    schedule
                }
                VStack(alignment: .leading, spacing: 12) { actions; schedule }
            }
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading).workspaceSurface(radius: 18)
    }
    private var actions: some View {
        HStack(spacing: 10) {
            Button(entry.learningAction == "lesson" ? "继续学习" : entry.learningActionTitle, action: open)
                .demandButtonStyle(WorkspaceActionStyle(prominent: true))
                .demandKeyboardID("try-learning-home-continue-" + entry.id)
            Button("笔记本", action: notebook).demandButtonStyle(TryControlStyle())
                .demandKeyboardID("try-learning-home-notes-" + entry.id)
        }
    }
    private var schedule: some View {
        HStack(spacing: 8) {
            if let config = entry.learningConfig {
                Text(config.deadlineDate, format: .dateTime.month().day())
                Text("截止 · 每天\(config.minutesPerDay)分钟")
            }
        }.dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
    }
}

private extension TryLearningConfig {
    var deadlineDate: Date { Date(timeIntervalSince1970: deadline) }
}
