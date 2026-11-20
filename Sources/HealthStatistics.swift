import Foundation

enum HealthDashboardPerspective: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String {
        switch self { case .day: return "日视角"; case .week: return "周视角"; case .month: return "月视角" }
    }
    var currentTitle: String {
        switch self { case .day: return "今天"; case .week: return "本周"; case .month: return "本月" }
    }
    var component: Calendar.Component {
        switch self { case .day: return .day; case .week: return .weekOfYear; case .month: return .month }
    }
}

struct HealthStatisticsPeriod {
    let perspective: HealthDashboardPerspective
    let start: Date
    let end: Date
    let reference: Date
    let calendar: Calendar

    init(perspective: HealthDashboardPerspective, anchor: Date, now: Date, calendar: Calendar = .current) {
        var calendar = calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        self.calendar = calendar
        self.perspective = perspective
        self.reference = now
        let interval = calendar.dateInterval(of: perspective.component, for: anchor)!
        start = interval.start
        end = interval.end
    }
    var includesToday: Bool { start <= reference && reference < end }
    var canMoveForward: Bool { end <= reference }
    var lastDay: Date { calendar.startOfDay(for: end.addingTimeInterval(-1)) }
    var chartEnd: Date {
        min(end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference))!)
    }
    var dates: [Date] {
        var result: [Date] = []
        var date = start
        while date < end && date <= reference {
            result.append(date)
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        return result
    }
    func shifted(_ delta: Int) -> Date {
        calendar.date(byAdding: perspective.component, value: delta, to: start)!
    }
    var title: String {
        switch perspective {
        case .day: return start.formatted(.dateTime.year().month().day().weekday())
        case .week:
            return start.formatted(.dateTime.year().month().day()) + " – " + lastDay.formatted(.dateTime.month().day())
        case .month: return start.formatted(.dateTime.year().month())
        }
    }
}

struct HealthStatisticsDay: Identifiable {
    let id: String
    let date: Date
    let waterML: Int?
    let deskSeconds: Double?
    let longestDeskSeconds: Double?
    let deskSeries: Int
    let breakCount: Int
    let exercises: [HealthExercise]
    let hasRecord: Bool

    var exerciseMinutes: Int { exercises.reduce(0) { $0 + $1.minutes } }
}

struct HealthStatistics {
    let period: HealthStatisticsPeriod
    let days: [HealthStatisticsDay]

    init(document: HealthDocument, period: HealthStatisticsPeriod) {
        self.period = period
        var deskSeries = 0
        days = period.dates.map { date in
            let key = HealthCalendar.key(date, calendar: period.calendar)
            let records = document.days[key] ?? HealthDay()
            let water = records.water.filter { $0.at <= period.reference.timeIntervalSince1970 }
            let exercises = records.exercise.filter {
                $0.at <= period.reference.timeIntervalSince1970 && $0.isCompleted(at: period.reference)
            }
            let hasDesk = records.deskSeconds > 0 || records.longestDeskSeconds > 0
            if !hasDesk { deskSeries += 1 }
            let breaks = records.breaks.filter { $0.startedAt <= period.reference.timeIntervalSince1970 }
            let breakCount = breaks.filter { !$0.crossesDay(at: period.reference, calendar: period.calendar) }.count
            return HealthStatisticsDay(id: key, date: date,
                waterML: water.isEmpty ? nil : water.reduce(0) { $0 + $1.ml },
                deskSeconds: hasDesk ? records.deskSeconds : nil,
                longestDeskSeconds: hasDesk ? records.longestDeskSeconds : nil, deskSeries: deskSeries,
                breakCount: breakCount, exercises: exercises,
                hasRecord: hasDesk || !water.isEmpty || !exercises.isEmpty || !breaks.isEmpty)
        }
    }
    var recordDayCount: Int { days.filter(\.hasRecord).count }
    var waterDayCount: Int { days.filter { $0.waterML != nil }.count }
    var waterML: Int { days.compactMap(\.waterML).reduce(0, +) }
    var waterDailyAverage: Double? {
        waterDayCount == 0 ? nil : Double(waterML) / Double(waterDayCount)
    }
    var deskDayCount: Int { days.filter { $0.deskSeconds != nil }.count }
    var deskSeconds: Double { days.compactMap(\.deskSeconds).reduce(0, +) }
    var deskDailyAverage: Double? {
        deskDayCount == 0 ? nil : deskSeconds / Double(deskDayCount)
    }
    var longestDeskSeconds: Double? { days.compactMap(\.longestDeskSeconds).max() }
    var breakCount: Int { days.reduce(0) { $0 + $1.breakCount } }
    var exercises: [HealthExercise] { days.flatMap(\.exercises) }
    var exerciseCount: Int { exercises.count }
    var exerciseMinutes: Int { days.reduce(0) { $0 + $1.exerciseMinutes } }
    var exerciseAverageMinutes: Double? {
        exerciseCount == 0 ? nil : Double(exerciseMinutes) / Double(exerciseCount)
    }
    var inferredExerciseCount: Int { exercises.filter { $0.endsAt != nil }.count }
}
