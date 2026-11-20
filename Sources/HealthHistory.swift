import SwiftUI

struct HealthHistoryDay: Identifiable {
    let id: String
    let date: Date
    let reference: Date
    let records: HealthDay
    let events: [HealthTimelineEvent]
    var waterML: Int { records.water.reduce(0) { $0 + $1.ml } }
    var completedExercise: [HealthExercise] { records.exercise.filter { $0.isCompleted(at: reference) } }
    var pendingExercise: [HealthExercise] { records.exercise.filter { !$0.isCompleted(at: reference) } }
    var exerciseMinutes: Int { completedExercise.reduce(0) { $0 + $1.minutes } }
    func events(for category: HealthTimelineEvent.Category) -> [HealthTimelineEvent] {
        events.filter { $0.category == category }
    }
}

struct HealthWaterRecord {
    let date: Date
    let ml: Int
}

enum HealthHistory {
    static func days(in document: HealthDocument, at now: Date, calendar: Calendar = .current) -> [HealthHistoryDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<30).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .compactMap { day(in: document, on: $0, at: now, calendar: calendar) }
    }

    static func allDays(in document: HealthDocument, at now: Date, calendar: Calendar = .current) -> [HealthHistoryDay] {
        let today = calendar.startOfDay(for: now)
        var dates = Set(document.days.keys.compactMap { HealthCalendar.date($0, calendar: calendar) })
        for item in document.days.values.flatMap(\.breaks) {
            dates.insert(calendar.startOfDay(for: Date(timeIntervalSince1970: item.startedAt)))
            if let end = item.endedAt {
                dates.insert(calendar.startOfDay(for: Date(timeIntervalSince1970: end)))
            }
        }
        return dates.filter { $0 <= today }.sorted(by: >)
            .compactMap { day(in: document, on: $0, at: now, calendar: calendar) }
    }

    static func waterRecord(in document: HealthDocument, at now: Date, calendar: Calendar = .current) -> HealthWaterRecord? {
        let today = calendar.startOfDay(for: now)
        return document.days.compactMap { key, records -> HealthWaterRecord? in
            guard let date = HealthCalendar.date(key, calendar: calendar), date <= today else { return nil }
            let total = records.water.reduce(0) { $0 + $1.ml }
            return total > 0 ? HealthWaterRecord(date: date, ml: total) : nil
        }.sorted {
            $0.ml == $1.ml ? $0.date < $1.date : $0.ml > $1.ml
        }.first
    }

    static func day(in document: HealthDocument, on date: Date, at now: Date, calendar: Calendar = .current) -> HealthHistoryDay? {
        let key = HealthCalendar.key(date, calendar: calendar)
        let events = HealthTimeline.events(in: document, on: date, asOf: now, calendar: calendar)
            .sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        guard document.days[key] != nil || !events.isEmpty else { return nil }
        return HealthHistoryDay(id: key, date: date, reference: now, records: document.days[key] ?? HealthDay(), events: events)
    }
}

struct HealthAllHistoryView: View {
    let value: HealthDocument
    let now: Date
    @ObservedObject var store: HealthStore
    let editExercise: (HealthExercise) -> Void
    let back: () -> Void
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        let days = HealthHistory.allDays(in: value, at: now)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Button(action: back) { Label("返回健康", systemImage: "chevron.left") }
                    .demandButtonStyle(TryControlStyle()).demandKeyboardID("health-history-back")
                Spacer()
                Text("\(days.count) 天记录").dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
            }
            Text("全部历史记录").dboardFont(size: 26, weight: .semibold)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(days) { day in
                        HealthHistoryDayView(day: day, store: store, editExercise: editExercise, showsYear: true)
                    }
                    if days.isEmpty {
                        Text("暂无历史记录").dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(26).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
    }
}

struct HealthHistoryDayView: View {
    let day: HealthHistoryDay
    @ObservedObject var store: HealthStore
    let editExercise: (HealthExercise) -> Void
    var showsYear = false
    var initiallyExpanded = false
    @State private var expanded = false
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            details.padding(.horizontal, 18).padding(.bottom, 14)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                Text(day.date, format: showsYear ? .dateTime.year().month().day().weekday() : .dateTime.month().day().weekday())
                    .dboardFont(size: 13, weight: .medium)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { overview }
                    VStack(alignment: .leading, spacing: 5) { overview }
                }.dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                    .lineLimit(1)
            }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
        }
        .demandKeyboardID("health-history-day-" + day.id)
        .padding(.horizontal, 6).workspaceSurface(radius: 12)
        .onAppear { if initiallyExpanded { expanded = true } }
    }

    @ViewBuilder private var overview: some View {
        Text("办公 " + HealthDuration.text(day.records.deskSeconds))
        Text("喝水 \(day.waterML) ml")
        Text("运动 \(day.completedExercise.count) 次")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("办公", summary: "离座 \(day.records.breakCount(at: day.reference)) 次")
                Text("累计 \(HealthDuration.text(day.records.deskSeconds)) · 最长连续 \(HealthDuration.text(day.records.longestDeskSeconds))")
                    .dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                ForEach(day.events(for: .desk)) { event in logRow(event) }
            }.demandKeyboardID("health-history-desk-" + day.id)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("喝水", summary: "\(day.records.water.count) 次 · \(day.waterML) ml")
                ForEach(day.events(for: .water)) { event in logRow(event) }
            }.demandKeyboardID("health-history-water-" + day.id)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("运动", summary: exerciseSummary)
                ForEach(day.records.exercise.sorted { $0.at < $1.at }) { item in
                    exerciseRow(item)
                }
            }.demandKeyboardID("health-history-exercise-" + day.id)
        }.padding(.top, 14)
    }

    private var exerciseSummary: String {
        var text = "\(day.completedExercise.count) 次"
        if day.exerciseMinutes > 0 { text += " · " + HealthDuration.text(Double(day.exerciseMinutes * 60)) }
        if !day.pendingExercise.isEmpty { text += " · 待完成 \(day.pendingExercise.count) 项" }
        return text
    }

    private func sectionHeader(_ title: String, summary: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).dboardFont(size: 12, weight: .semibold)
            Spacer(minLength: 8)
            Text(summary).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
        }
    }

    private func logRow(_ event: HealthTimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Date(timeIntervalSince1970: event.at), format: .dateTime.hour().minute())
                .dboardFont(size: 11, design: .monospaced)
                .foregroundStyle(theme.current.textSecondary).frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).dboardFont(size: 12, weight: .medium)
                if let detail = event.detail {
                    Text(detail).dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if case .undoWater(let id) = event.action {
                Button("撤销") { _ = store.removeWater(id) }
                    .demandButtonStyle(TryControlStyle())
                    .demandKeyboardID("health-history-water-undo-" + id)
            }
        }.padding(.vertical, 5)
    }

    private func exerciseRow(_ item: HealthExercise) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).dboardFont(size: 12, weight: .medium)
                Text(item.timeRange(relativeTo: day.reference)).dboardFont(size: 11)
                    .foregroundStyle(theme.current.textSecondary)
                Text(item.status(at: day.reference)).dboardFont(size: 10)
                    .foregroundStyle(item.isCompleted(at: day.reference) ? theme.current.textSecondary : theme.current.accentPrimary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.endsAt != nil {
                Button("修改") { editExercise(item) }
                    .demandButtonStyle(TryControlStyle()).demandKeyboardID("health-history-exercise-edit-" + item.id)
            }
            Button(item.isCompleted(at: day.reference) ? "删除" : "取消") { _ = store.removeExercise(item.id) }
                .demandButtonStyle(TryControlStyle()).demandKeyboardID("health-history-exercise-delete-" + item.id)
        }.padding(.vertical, 5)
    }
}
