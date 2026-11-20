import SwiftUI
import Charts

private enum HealthDashboardChart { case water, desk, exercise }

// Receive plot clicks directly in the floating window, while wheel events keep scrolling.
private struct HealthDashboardChartTapTarget: NSViewRepresentable {
    let action: (CGPoint) -> Void
    func makeNSView(context: Context) -> HealthDashboardChartTapView { HealthDashboardChartTapView() }
    func updateNSView(_ view: HealthDashboardChartTapView, context: Context) { view.action = action }
}

final class HealthDashboardChartTapView: NSView {
    var action: ((CGPoint) -> Void)?
    private var press: CGPoint?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        press = convert(event.locationInWindow, from: nil)
    }
    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let press, bounds.contains(point), hypot(point.x - press.x, point.y - press.y) <= 5 else { return }
        action?(point)
    }
}

struct HealthDashboardView: View {
    let value: HealthDocument
    let now: Date
    @ObservedObject var store: HealthStore
    let editExercise: (HealthExercise) -> Void
    let back: () -> Void
    @State private var perspective: HealthDashboardPerspective
    @State private var anchor: Date
    @State private var selectedDay: Date?
    @EnvironmentObject private var theme: ThemeManager

    init(value: HealthDocument, now: Date, store: HealthStore,
         editExercise: @escaping (HealthExercise) -> Void, back: @escaping () -> Void,
         initialPerspective: HealthDashboardPerspective = .week) {
        self.value = value; self.now = now; self.store = store
        self.editExercise = editExercise; self.back = back
        _perspective = State(initialValue: initialPerspective)
        _anchor = State(initialValue: now)
    }

    var body: some View {
        let period = HealthStatisticsPeriod(perspective: perspective, anchor: anchor, now: now)
        let statistics = HealthStatistics(document: value, period: period)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button {
                    if selectedDay != nil { selectedDay = nil } else { back() }
                } label: {
                    Label(selectedDay == nil ? "返回健康" : "返回看板", systemImage: "chevron.left")
                }.demandButtonStyle(TryControlStyle()).demandKeyboardID("health-dashboard-back")
                Spacer()
                Text(selectedDay == nil ? "健康历史看板" : "当日明细")
                    .dboardFont(size: 16, weight: .semibold)
            }
            if let date = selectedDay {
                Text(date, format: .dateTime.year().month().day().weekday())
                    .dboardFont(size: 22, weight: .semibold)
                ScrollView {
                    if let day = HealthHistory.day(in: value, on: date, at: now) {
                        HealthHistoryDayView(day: day, store: store, editExercise: editExercise,
                            showsYear: true, initiallyExpanded: true).padding(.vertical, 4)
                    } else {
                        Text("这一天没有记录").dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                    }
                }.id(HealthCalendar.key(date))
            } else {
                periodControls(period)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(period.title).dboardFont(size: 22, weight: .semibold)
                            .accessibilityIdentifier("health-dashboard-period-title")
                        Text(coverage(statistics)).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                        water(statistics)
                        desk(statistics)
                        exercise(statistics)
                        if perspective == .day {
                            Button("查看当天明细") { selectedDay = period.start }
                                .demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("health-dashboard-open-day")
                        } else {
                            dailyDetails(statistics)
                        }
                        Text("日均按对应项目有记录的天数计算；空白日期表示无记录。")
                            .dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                    }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(26).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
    }

    private func periodControls(_ period: HealthStatisticsPeriod) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(HealthDashboardPerspective.allCases) { item in
                    Button(item.title) { perspective = item }
                        .demandButtonStyle(WorkspaceActionStyle(prominent: perspective == item))
                        .demandKeyboardID("health-dashboard-" + item.rawValue)
                        .accessibilityAddTraits(perspective == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { dateControls(period) }
                VStack(alignment: .leading, spacing: 8) { dateControls(period) }
            }
        }
    }

    @ViewBuilder private func dateControls(_ period: HealthStatisticsPeriod) -> some View {
        HStack(spacing: 8) {
            Button { anchor = period.shifted(-1) } label: { Image(systemName: "chevron.left") }
                .demandButtonStyle(TryControlStyle()).accessibilityLabel("上一个周期")
                .demandKeyboardID("health-dashboard-previous")
            Button { anchor = period.shifted(1) } label: { Image(systemName: "chevron.right") }
                .demandButtonStyle(TryControlStyle()).accessibilityLabel("下一个周期")
                .disabled(!period.canMoveForward).demandKeyboardID("health-dashboard-next")
            Button(perspective.currentTitle) { anchor = now }
                .demandButtonStyle(TryControlStyle()).demandKeyboardID("health-dashboard-current")
        }
        DatePicker("选择日期", selection: $anchor, in: ...now, displayedComponents: .date)
            .labelsHidden().datePickerStyle(.compact).accessibilityLabel("选择统计日期")
    }

    private func coverage(_ statistics: HealthStatistics) -> String {
        let period = statistics.period
        let scope = period.includesToday ? "截至今天" : "完整周期"
        return "\(scope) · 有记录 \(statistics.recordDayCount) 天 / \(statistics.days.count) 天"
    }

    private func headline(_ value: String, unit: String, label: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).dboardFont(size: 32, weight: .semibold, design: .rounded)
                    .accessibilityIdentifier(id)
                Text(unit).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
            }
            Text(label).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).dboardFont(size: 16, weight: .medium)
            Text(title).dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
        }
    }
    private func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func water(_ statistics: HealthStatistics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("喝水", systemImage: "drop.fill").dboardFont(size: 14, weight: .medium)
                .foregroundStyle(theme.current.accentPrimary)
            HStack(alignment: .top, spacing: 30) {
                headline(statistics.waterDayCount == 0 ? "—" : statistics.waterML.formatted(),
                    unit: "ml", label: "总量", id: "health-dashboard-water-total")
                if perspective != .day {
                    metric("日均 · 有喝水记录 \(statistics.waterDayCount) 天",
                        statistics.waterDailyAverage.map { decimal($0) + " ml" } ?? "—")
                        .accessibilityIdentifier("health-dashboard-water-average")
                }
                Spacer(minLength: 0)
            }
            if statistics.waterDayCount == 0 {
                Text("暂无喝水记录").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
            }
            if perspective != .day { chart(statistics, kind: .water) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).workspaceSurface(radius: 17)
    }

    private func desk(_ statistics: HealthStatistics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("办公", systemImage: "figure.seated.side").dboardFont(size: 14, weight: .medium)
                .foregroundStyle(theme.current.accentPrimary)
            headline(statistics.deskDayCount == 0 ? "—" : HealthDuration.text(statistics.deskSeconds),
                unit: "", label: "累计办公", id: "health-dashboard-desk-total")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) { deskMetrics(statistics) }
                VStack(alignment: .leading, spacing: 12) { deskMetrics(statistics) }
            }
            if perspective != .day {
                Text("柱：累计办公 · 线：最长连续办公")
                    .dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                chart(statistics, kind: .desk)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).workspaceSurface(radius: 17)
    }
    @ViewBuilder private func deskMetrics(_ statistics: HealthStatistics) -> some View {
        if perspective != .day {
            metric("日均 · 有办公记录 \(statistics.deskDayCount) 天",
                statistics.deskDailyAverage.map { HealthDuration.text($0) } ?? "—")
        }
        metric("最长连续办公", statistics.longestDeskSeconds.map { HealthDuration.text($0) } ?? "—")
        if perspective == .day { metric("离座", "\(statistics.breakCount) 次") }
    }

    private func exercise(_ statistics: HealthStatistics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("运动", systemImage: "figure.run").dboardFont(size: 14, weight: .medium)
                .foregroundStyle(theme.current.accentPrimary)
            HStack(alignment: .top, spacing: 28) {
                headline(statistics.exerciseCount.formatted(), unit: "次",
                    label: "已计入的运动", id: "health-dashboard-exercise-count")
                metric("总时长", HealthDuration.text(Double(statistics.exerciseMinutes * 60)))
                metric("平均每次", statistics.exerciseAverageMinutes.map { decimal($0) + " 分钟" } ?? "—")
            }
            if statistics.inferredExerciseCount > 0 {
                Text("\(statistics.inferredExerciseCount) 次按已结束的运动安排计入")
                    .dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
            }
            if perspective != .day { chart(statistics, kind: .exercise) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).workspaceSurface(radius: 17)
    }

    private func chart(_ statistics: HealthStatistics, kind: HealthDashboardChart) -> some View {
        Chart(statistics.days) { day in
            if kind == .water {
                if let amount = day.waterML {
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value("喝水量", amount))
                        .foregroundStyle(theme.current.accentPrimary)
                }
            } else if kind == .desk {
                if let seconds = day.deskSeconds {
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value("累计办公", seconds / 60))
                        .foregroundStyle(theme.current.accentPrimary.opacity(0.6))
                }
                if let seconds = day.longestDeskSeconds {
                    LineMark(x: .value("日期", day.date, unit: .day), y: .value("最长连续办公", seconds / 60),
                        series: .value("连续记录", day.deskSeries))
                        .foregroundStyle(theme.current.accentSecondary)
                    PointMark(x: .value("日期", day.date, unit: .day), y: .value("最长连续办公", seconds / 60))
                        .foregroundStyle(theme.current.accentSecondary)
                }
            } else if !day.exercises.isEmpty {
                BarMark(x: .value("日期", day.date, unit: .day), y: .value("运动时长", day.exerciseMinutes))
                    .foregroundStyle(theme.current.accentPrimary)
            }
        }
        .chartXScale(domain: statistics.period.start...statistics.period.chartEnd)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: perspective == .month ? 5 : 1)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day(), centered: true)
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartYAxisLabel(kind == .water ? "ml" : "分钟")
        .frame(height: 150)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                HealthDashboardChartTapTarget { point in
                    guard let plot = proxy.plotFrame, geometry[plot].contains(point),
                          let date = proxy.value(atX: point.x - geometry[plot].minX, as: Date.self),
                          statistics.days.contains(where: { statistics.period.calendar.isDate($0.date, inSameDayAs: date) })
                    else { return }
                    selectedDay = statistics.period.calendar.startOfDay(for: date)
                }
            }
        }
        .accessibilityLabel(kind == .water ? "每日喝水总量，单位毫升" :
            (kind == .desk ? "每日累计和最长连续办公，单位分钟" : "每日已计入运动时长，单位分钟"))
    }

    private func dailyDetails(_ statistics: HealthStatistics) -> some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(statistics.days.reversed()) { day in
                    Button { selectedDay = day.date } label: {
                        HStack {
                            Text(day.date, format: .dateTime.month().day().weekday())
                            Spacer()
                            Text(day.hasRecord ? "查看明细" : "无记录")
                                .foregroundStyle(theme.current.textSecondary)
                        }.dboardFont(size: 12)
                    }.demandButtonStyle(TryControlStyle(fillWidth: true))
                        .demandKeyboardID("health-dashboard-open-" + day.id)
                }
            }.padding(.top, 10)
        } label: { Text("每日明细").dboardFont(size: 13, weight: .medium) }
            .demandKeyboardID("health-dashboard-days").padding(18).workspaceSurface(radius: 14)
    }
}
