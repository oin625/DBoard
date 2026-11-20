import SwiftUI
import AppKit

struct TryHealthView: View {
    @ObservedObject var store: HealthStore
    @ObservedObject var monitor: HealthDeskMonitor
    var close: (() -> Void)? = nil
    @State private var settingsPresented = false
    @State private var settingsDraft = HealthSettings()
    @State private var exerciseDraft: HealthExerciseDraft?
    @State private var cupDrinking = false
    @State private var todayHistoryExpanded = true
    @State private var allHistoryPresented = false
    @State private var dashboardPresented = false
    @State private var notice: String?
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let reference = max(context.date, Date())
            let value = store.snapshot(at: reference)
            if dashboardPresented {
                HealthDashboardView(value: value, now: reference, store: store,
                    editExercise: { presentExercise($0) }, back: { dashboardPresented = false })
            } else if allHistoryPresented {
                HealthAllHistoryView(value: value, now: reference, store: store,
                    editExercise: { presentExercise($0) }, back: { allHistoryPresented = false })
            } else {
                content(value, at: reference)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice { Text(notice).dboardFont(size: 12).padding(12).background(.regularMaterial, in: Capsule()).padding(16) }
        }
        .onChange(of: notice) { _, value in
            guard let value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if notice == value { notice = nil } }
        }
        .popover(isPresented: $settingsPresented) { settingsForm }
        .popover(item: $exerciseDraft) { draft in
            HealthExerciseScheduleForm(store: store, draft: draft) {
                exerciseDraft = nil
            } onSaved: {
                exerciseDraft = nil; notice = "运动安排已保存"
            }
        }
        .disclosureGroupStyle(TryDisclosureStyle())
        .dboardThemeAccent()
    }
    private func content(_ value: HealthDocument, at now: Date) -> some View {
        let today = value.days[HealthCalendar.key(now)] ?? HealthDay()
        let events = HealthTimeline.events(in: value, on: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    if let close {
                        Button(action: close) { Image(systemName: "chevron.left") }
                            .demandButtonStyle(TryControlStyle()).accessibilityLabel("返回")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("健康").dboardFont(size: 26, weight: .semibold)
                        Text(now, format: .dateTime.month().day().weekday())
                            .dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
                    }
                    Spacer()
                    Button { dashboardPresented = true } label: {
                        Label("历史看板", systemImage: "chart.bar.xaxis")
                    }.demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("health-dashboard")
                    Button {
                        settingsDraft = store.document.settings; settingsPresented = true
                    } label: { Label("目标与习惯", systemImage: "slider.horizontal.3") }
                        .demandButtonStyle(TryControlStyle()).demandKeyboardID("health-settings")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                    desk(value, today, at: now)
                    water(value, today, at: now)
                    exercise(value, at: now)
                }
                let plans = store.pendingExercise(at: now)
                if !plans.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("运动安排").dboardFont(size: 14, weight: .medium)
                        ForEach(plans) { item in
                            exerciseRow(item, at: now)
                            if item.id != plans.last?.id { Divider() }
                        }
                    }.padding(18).workspaceSurface()
                }
                if let error = store.error ?? monitor.notice {
                    Text(error).dboardFont(size: 12).foregroundStyle(.orange)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !events.isEmpty {
                    DisclosureGroup(isExpanded: $todayHistoryExpanded) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(events) { item in
                                HStack(alignment: .top, spacing: 11) {
                                    Text(Date(timeIntervalSince1970: item.at), format: .dateTime.hour().minute())
                                        .dboardFont(size: 10, design: .monospaced)
                                        .foregroundStyle(theme.current.textSecondary)
                                        .frame(width: 38, alignment: .leading)
                                    Image(systemName: item.icon)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(theme.current.accentPrimary)
                                        .frame(width: 25, height: 25)
                                        .background(theme.current.accentPrimary.opacity(0.09), in: Circle())
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).dboardFont(size: 12, weight: .medium)
                                        if let detail = item.detail {
                                            Text(detail).dboardFont(size: 10)
                                                .foregroundStyle(theme.current.textSecondary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    switch item.action {
                                    case .none:
                                        EmptyView()
                                    case .undoWater(let id):
                                        Button("撤销") { _ = store.removeWater(id) }
                                            .demandButtonStyle(TryControlStyle())
                                            .demandKeyboardID("health-water-undo-" + id)
                                    case .deleteExercise(let id):
                                        HStack(spacing: 8) {
                                            if let record = today.exercise.first(where: { $0.id == id }), record.endsAt != nil {
                                                Button("修改") { presentExercise(record) }
                                                    .demandButtonStyle(TryControlStyle())
                                                    .demandKeyboardID("health-exercise-edit-" + id)
                                            }
                                            Button("删除") { _ = store.removeExercise(id) }
                                                .demandButtonStyle(TryControlStyle())
                                                .demandKeyboardID("health-exercise-delete-" + id)
                                        }
                                    }
                                }
                                .padding(.vertical, 8)
                                if item.id != events.last?.id {
                                    Divider().padding(.leading, 74)
                                }
                            }
                        }.padding(.top, 8)
                    } label: { Text("今天的记录").dboardFont(size: 14, weight: .medium) }
                        .demandKeyboardID("health-today-history").padding(18).workspaceSurface()
                }
                recentHistory(value, at: now)
                Button { allHistoryPresented = true } label: {
                    Label("查看全部历史记录", systemImage: "clock.arrow.circlepath")
                }.demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("health-all-history")
                Button("复制记录，交给 AI 帮我安排") {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(store.summary(), forType: .string) { notice = "健康记录已复制" }
                }.demandButtonStyle(TryControlStyle()).demandKeyboardID("health-copy")
            }.padding(26).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func recentHistory(_ value: HealthDocument, at now: Date) -> some View {
        let days = HealthHistory.days(in: value, at: now)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(days) { day in
                    HealthHistoryDayView(day: day, store: store, editExercise: { presentExercise($0) })
                }
                if days.isEmpty {
                    Text("最近三十天暂无记录").dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
                }
            }.padding(.top, 12)
        } label: { Text("最近三十天").dboardFont(size: 14, weight: .medium) }
            .demandKeyboardID("health-month-history").padding(18).workspaceSurface()
    }

    private func desk(_ value: HealthDocument, _ today: HealthDay, at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("连续办公", systemImage: "figure.seated.side").dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                let minutes = max(0, Int(value.continuousSeconds / 60))
                if minutes >= 60 {
                    Text("\(minutes / 60)").dboardFont(size: 36, weight: .semibold, design: .rounded)
                    Text("小时").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                }
                Text("\(minutes >= 60 ? minutes % 60 : minutes)")
                    .dboardFont(size: minutes >= 60 ? 36 : 40, weight: .semibold, design: .rounded)
                Text("分钟").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("连续办公 " + HealthDuration.text(value.continuousSeconds))
            Text("累计 " + HealthDuration.text(today.deskSeconds))
                .dboardFont(size: 12, weight: .medium).foregroundStyle(theme.current.textPrimary)
            if let status = deskStatus(value) {
                Text(status).dboardFont(size: 12).foregroundStyle(
                    value.mode == .desk ? theme.current.accentPrimary : theme.current.textSecondary)
            }
            Text("今天已离座 \(today.breakCount(at: now)) 次").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
            Button { _ = monitor.requestAwayLock() } label: {
                Label(monitor.pendingLock ? "正在锁屏…" : "离座锁屏", systemImage: "lock")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.demandButtonStyle(WorkspaceActionStyle(prominent: true)).disabled(monitor.pendingLock || value.mode == .away)
                .demandKeyboardID("health-away-lock")
            HStack {
                Text(ShortcutPreferences.shared.binding(for: "awaylock")?.title ?? "快捷键已关闭")
                    .dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                Spacer()
                Button(value.mode == .paused ? "开始办公" : "暂停计时") {
                    if value.mode == .paused { _ = store.resume() } else { _ = store.pause() }
                }.demandButtonStyle(TryControlStyle()).dboardFont(size: 11).demandKeyboardID("health-desk-toggle")
            }
        }.padding(20).frame(maxWidth: .infinity, minHeight: 255, alignment: .topLeading).workspaceSurface(radius: 17)
    }
    private func water(_ value: HealthDocument, _ today: HealthDay, at now: Date) -> some View {
        let total = today.water.map(\.ml).reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            Label("今天喝水", systemImage: "drop").dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(total)").dboardFont(size: 40, weight: .semibold, design: .rounded)
                            .lineLimit(1).minimumScaleFactor(0.4)
                        Text("ml").dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
                            .fixedSize()
                    }
                    Text(value.isCupFilled ? "杯子已接满" : "现在是空杯")
                        .dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                }
                Spacer(minLength: 4)
                HealthCupView(filled: value.isCupFilled, drinking: cupDrinking)
                    .frame(width: 68, height: 76)
            }
            if value.settings.waterGoalML > 0 {
                ProgressView(value: Double(min(total, value.settings.waterGoalML)), total: Double(value.settings.waterGoalML))
                Text(total >= value.settings.waterGoalML ? "今天的目标已完成" : "目标 \(value.settings.waterGoalML) ml")
                    .dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let record = HealthHistory.waterRecord(in: value, at: now) {
                    Text("历史单日最高 \(record.ml) ml").dboardFont(size: 11, weight: .medium)
                    Text(record.date, format: .dateTime.year().month().day())
                        .dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                } else {
                    Text("历史单日最高：暂无记录").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("health-water-record")
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        if store.fillCup() { notice = "水接满了" }
                    }
                } label: {
                    Label("接水", systemImage: "waterbottle")
                        .frame(maxWidth: .infinity)
                }
                .demandButtonStyle(WorkspaceActionStyle())
                .disabled(value.isCupFilled || cupDrinking)
                .demandKeyboardID("health-water-fill")
                Button {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        cupDrinking = true
                        if store.drinkCup() { notice = "喝水 \(value.settings.cupML) ml" }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        withAnimation(.spring(response: 0.35)) { cupDrinking = false }
                    }
                } label: {
                    Label("喝水", systemImage: "drop.fill")
                        .frame(maxWidth: .infinity)
                }
                .demandButtonStyle(WorkspaceActionStyle(prominent: true))
                .disabled(!value.isCupFilled || cupDrinking)
                .demandKeyboardID("health-water-drink")
            }
            HStack {
                Text("\(today.water.count) 次 · 每杯 \(value.settings.cupML) ml")
                    .dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                Spacer()
                if let last = today.water.last {
                    Button("撤销上一杯") { _ = store.removeWater(last.id) }
                        .demandButtonStyle(TryControlStyle()).dboardFont(size: 11).demandKeyboardID("health-water-undo-last")
                }
            }
        }.padding(20).frame(maxWidth: .infinity, minHeight: 255, alignment: .topLeading).workspaceSurface(radius: 17)
    }
    private func exercise(_ value: HealthDocument, at now: Date) -> some View {
        let count = store.weekExerciseCount(at: now)
        return VStack(alignment: .leading, spacing: 14) {
            Label("本周运动", systemImage: "figure.walk").dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(count)").dboardFont(size: 40, weight: .semibold, design: .rounded)
                Text(value.settings.weeklyExerciseGoal > 0 ? "/ \(value.settings.weeklyExerciseGoal) 次" : "次")
                    .dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            }
            Text(value.settings.weeklyExerciseGoal > 0 && count >= value.settings.weeklyExerciseGoal ?
                "本周目标已完成" : "提前安排，结束后自动计为完成")
                .dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            Spacer(minLength: 0)
            Button { presentExercise() } label: {
                Label("安排运动", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
            }.demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("health-exercise-add")
        }.padding(20).frame(maxWidth: .infinity, minHeight: 255, alignment: .topLeading).workspaceSurface(radius: 17)
    }

    private func exerciseRow(_ item: HealthExercise, at now: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).dboardFont(size: 13, weight: .medium)
                Text(item.timeRange(relativeTo: now)).dboardFont(size: 12)
                    .foregroundStyle(theme.current.textSecondary)
                Text(item.status(at: now)).dboardFont(size: 10)
                    .foregroundStyle(item.isCompleted(at: now) ? theme.current.textSecondary : theme.current.accentPrimary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.endsAt != nil {
                Button("修改") { presentExercise(item) }
                    .demandButtonStyle(TryControlStyle()).demandKeyboardID("health-exercise-edit-" + item.id)
            }
            Button(item.isCompleted(at: now) ? "删除" : "取消") {
                withAnimation(.easeInOut(duration: 0.2)) { _ = store.removeExercise(item.id) }
            }.demandButtonStyle(TryControlStyle()).demandKeyboardID("health-exercise-delete-" + item.id)
        }.padding(.vertical, 4)
    }

    private func presentExercise(_ item: HealthExercise? = nil) {
        let nextHalfHour = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 1800) + 1) * 1800)
        let start = item.map { Date(timeIntervalSince1970: $0.at) } ?? nextHalfHour
        exerciseDraft = HealthExerciseDraft(editingID: item?.id, title: item?.title ?? "",
            startsAt: start, endsAt: item?.endsAt.map { Date(timeIntervalSince1970: $0) } ?? start.addingTimeInterval(3600))
    }

    private func deskStatus(_ value: HealthDocument) -> String? {
        switch value.mode {
        case .away: return "已离座，解锁后开始新的一段"
        case .locked: return "锁屏暂停，保留这段时长"
        case .paused: return "计时已暂停"
        case .desk: return value.continuousSeconds >= Double(value.settings.deskReminderMinutes * 60) ? "可以起身活动一下了" : nil
        }
    }
    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("目标与习惯").dboardFont(size: 20, weight: .semibold)
            Stepper("杯子容量 \(settingsDraft.cupML) ml", value: $settingsDraft.cupML, in: 50...2000, step: 50)
            Stepper(settingsDraft.waterGoalML == 0 ? "每日喝水目标 · 暂不设置" : "每日喝水目标 \(settingsDraft.waterGoalML) ml",
                value: $settingsDraft.waterGoalML, in: 0...5000, step: 250)
            Stepper(settingsDraft.weeklyExerciseGoal == 0 ? "每周运动目标 · 暂不设置" : "每周运动 \(settingsDraft.weeklyExerciseGoal) 次",
                value: $settingsDraft.weeklyExerciseGoal, in: 0...14)
            Stepper("连续办公 \(HealthDuration.text(Double(settingsDraft.deskReminderMinutes * 60)))后提示", value: $settingsDraft.deskReminderMinutes, in: 10...180, step: 5)
            Text("喝水和运动目标由你决定；0 表示暂不设目标。").dboardFont(size: 11).foregroundStyle(.secondary)
            HStack {
                Button("取消") { settingsPresented = false }.demandButtonStyle(TryControlStyle())
                Spacer()
                Button("保存") { if store.settings(settingsDraft) { settingsPresented = false } }
                    .demandButtonStyle(WorkspaceActionStyle(prominent: true))
            }
        }.padding(24).frame(width: 390).dboardFont(size: 13)
    }

}

private struct HealthExerciseDraft: Identifiable {
    let id = UUID()
    var editingID: String?
    var title: String
    var startsAt: Date
    var endsAt: Date
}

private struct HealthExerciseScheduleForm: View {
    @ObservedObject var store: HealthStore
    @State var draft: HealthExerciseDraft
    let onClose: () -> Void
    let onSaved: () -> Void
    @State private var error: String?
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.editingID == nil ? "安排运动" : "修改运动安排").dboardFont(size: 20, weight: .semibold)
            TextField("例如羽毛球、散步、力量训练", text: $draft.title)
                .textFieldStyle(.roundedBorder).accessibilityLabel("运动内容")
                .demandKeyboardID("health-exercise-title")
            DatePicker("开始", selection: $draft.startsAt, displayedComponents: [.date, .hourAndMinute])
                .demandKeyboardID("health-exercise-start")
                .onChange(of: draft.startsAt) { old, new in
                    draft.endsAt = new.addingTimeInterval(max(60, draft.endsAt.timeIntervalSince(old)))
                }
            DatePicker("结束", selection: $draft.endsAt, displayedComponents: [.date, .hourAndMinute])
                .demandKeyboardID("health-exercise-end")
            Text(draft.endsAt > draft.startsAt ?
                HealthDuration.text(draft.endsAt.timeIntervalSince(draft.startsAt)) : "结束时间需晚于开始时间")
                .dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            Text("结束后自动计为完成；计划有变动可修改或取消。")
                .dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
            if let error = error ?? store.error {
                Text(error).dboardFont(size: 12).foregroundStyle(.orange)
            }
            HStack {
                Button("取消") { onClose() }.demandButtonStyle(TryControlStyle())
                    .demandKeyboardID("health-exercise-dismiss")
                Spacer()
                Button("保存安排") {
                    if store.scheduleExercise(id: draft.editingID, title: draft.title,
                        startsAt: draft.startsAt, endsAt: draft.endsAt) {
                        onSaved()
                    } else {
                        error = store.error ?? "请填写运动内容，时间范围应在 1 分钟到 24 小时之间。"
                    }
                }.demandButtonStyle(WorkspaceActionStyle(prominent: true))
                    .demandKeyboardID("health-exercise-save").keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        draft.endsAt.timeIntervalSince(draft.startsAt) < 60 ||
                        draft.endsAt.timeIntervalSince(draft.startsAt) > 86400)
            }
        }.padding(24).frame(width: 420).dboardFont(size: 13)
    }
}

private struct HealthCupView: View {
    let filled: Bool
    let drinking: Bool
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.current.cardFill.opacity(0.5))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.current.accentSecondary.opacity(0.72),
                            theme.current.accentPrimary.opacity(0.9)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: filled ? 59 : 3)
                .padding(5)
                .opacity(filled ? 1 : 0.28)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.current.textSecondary.opacity(0.5), lineWidth: 2)
            if filled {
                Circle()
                    .fill(.white.opacity(0.48))
                    .frame(width: 5, height: 5)
                    .offset(x: 17, y: -51)
            }
        }
        .rotationEffect(.degrees(drinking ? -15 : 0), anchor: .bottomTrailing)
        .scaleEffect(drinking ? 0.94 : 1)
        .shadow(color: theme.current.accentPrimary.opacity(filled ? 0.2 : 0), radius: 8, y: 4)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: filled)
        .animation(.easeInOut(duration: 0.42), value: drinking)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(filled ? "杯子已接满" : "空杯")
    }
}

struct TryHealthQuickCard: View {
    @ObservedObject var store: HealthStore
    @ObservedObject var monitor: HealthDeskMonitor
    let open: () -> Void
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let value = store.snapshot(at: context.date)
            let day = value.days[HealthCalendar.key(context.date)] ?? HealthDay()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("今天").dboardFont(size: 11).foregroundStyle(.secondary)
                    Spacer()
                    Text("健康").dboardFont(size: 11).foregroundStyle(theme.current.accentSecondary)
                }
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("给工作留点活动时间").dboardFont(size: 23, weight: .semibold)
                        Text(value.mode == .desk ? "连续办公 \(HealthDuration.text(value.continuousSeconds))" :
                            (value.mode == .away ? "已离座，回来解锁即可" : "计时暂停，保留这段时长"))
                            .dboardFont(size: 15).foregroundStyle(theme.current.accentPrimary)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 14) {
                    Text("累计 \(HealthDuration.text(day.deskSeconds))")
                    Text("今天喝水 \(day.water.map(\.ml).reduce(0, +)) ml")
                    Text("今天离座 \(day.breakCount(at: context.date)) 次")
                    Text("本周运动 \(store.weekExerciseCount(at: context.date)) 次")
                    if let next = store.pendingExercise(at: context.date).first {
                        Text("\(next.title) · \(next.timeRange(relativeTo: context.date))")
                            .foregroundStyle(theme.current.accentPrimary)
                    }
                }.dboardFont(size: 14).foregroundStyle(theme.current.textSecondary)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(store.document.isCupFilled ? "已接满" : "接水") {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { _ = store.fillCup() }
                    }
                    .buttonStyle(TryControlStyle())
                    .disabled(store.document.isCupFilled)
                    Button("喝水") {
                        withAnimation(.easeInOut(duration: 0.45)) { _ = store.drinkCup() }
                    }
                    .buttonStyle(TryControlStyle())
                    .disabled(!store.document.isCupFilled)
                    Spacer()
                    Button("离座锁屏") { _ = monitor.requestAwayLock() }
                        .buttonStyle(WorkspaceActionStyle(prominent: true)).disabled(monitor.pendingLock)
                }
                Text("回车打开 · \(ShortcutPreferences.shared.binding(for: "awaylock")?.title ?? "快捷键已关闭") 离座锁屏")
                    .dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

final class HealthWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let store: HealthStore
    private let monitor: HealthDeskMonitor
    private let activates: Bool
    private let theme: ThemeManager
    private var centering: DemandWindowCentering?
    private var keyboard: DemandWindowKeyboardNavigation?
    init(store: HealthStore = .shared, monitor: HealthDeskMonitor = .shared, activates: Bool = true, theme: ThemeManager = .shared) {
        self.store = store; self.monitor = monitor; self.activates = activates; self.theme = theme
    }
    func show(centerIn: NSRect? = nil) {
        if window == nil {
            let value = DemandWorkspaceWindow(contentRect: NSRect(x: activates ? 0 : -10000, y: 0, width: 820, height: 740))
            value.title = "次 Try · 健康"; value.minSize = NSSize(width: 520, height: 560); value.delegate = self
            let host = NSHostingController(rootView: TryHealthView(store: store, monitor: monitor, close: { [weak self] in self?.close() })
                .demandFloatingCanvas().environmentObject(theme).environmentObject(FontManager.shared))
            host.sizingOptions = []
            value.setContent(host)
            value.setContentSize(NSSize(width: 820, height: 740))
            window = value
            centering = DemandWindowCentering(window: value)
            keyboard = DemandWindowKeyboardNavigation(window: value, onEscape: { [weak self] in self?.close() })
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        centering?.center(in: centerIn ?? (activates ? screen?.visibleFrame : nil))
        if activates { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { window?.orderBack(nil) }
    }
    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) { window = nil; keyboard = nil; centering = nil }
}
