import Foundation

struct HealthTimelineEvent: Identifiable {
    enum Category { case desk, water, exercise }
    var category: Category {
        switch action {
        case .none: return .desk
        case .undoWater: return .water
        case .deleteExercise: return .exercise
        }
    }
    enum Action { case none, undoWater(String), deleteExercise(String) }
    let id: String
    let at: Double
    let icon: String
    let title: String
    let detail: String?
    let action: Action
}

enum HealthTimeline {
    static func events(in document: HealthDocument, on day: Date, asOf now: Date? = nil,
                       calendar: Calendar = .current) -> [HealthTimelineEvent] {
        let reference = now ?? day
        let records = document.days[HealthCalendar.key(day, calendar: calendar)] ?? HealthDay()
        var events: [HealthTimelineEvent] = []
        for item in document.days.values.flatMap(\.breaks) {
            let overnight = item.crossesDay(at: reference, calendar: calendar)
            let start = Date(timeIntervalSince1970: item.startedAt)
            if calendar.isDate(start, inSameDayAs: day) {
                let detail = item.deskSecondsBefore.map { "结束了 \(duration($0))的连续办公" }
                    ?? (overnight ? "结束当天办公" : "主动离座")
                events.append(HealthTimelineEvent(id: item.id + "-away", at: item.startedAt,
                    icon: overnight ? "moon" : "figure.walk.departure",
                    title: overnight ? "下班" : "离座", detail: detail, action: .none))
            }
            if let endedAt = item.endedAt,
               calendar.isDate(Date(timeIntervalSince1970: endedAt), inSameDayAs: day) {
                events.append(HealthTimelineEvent(id: item.id + "-return", at: endedAt,
                    icon: overnight ? "sun.max" : "figure.walk.arrival",
                    title: overnight ? "上班" : "回到座位",
                    detail: overnight ? "开始新一天的办公" :
                        "离开 \(duration(endedAt - item.startedAt))，开始新一段办公",
                    action: .none))
            }
        }
        events += records.water.map {
            HealthTimelineEvent(id: $0.id, at: $0.at, icon: "drop.fill",
                title: "喝完一杯水", detail: "\($0.ml) ml", action: .undoWater($0.id))
        }
        events += records.exercise.filter { $0.isCompleted(at: reference) }.map {
            HealthTimelineEvent(id: $0.id, at: $0.at, icon: "figure.run",
                title: $0.title, detail: "\($0.timeRange(relativeTo: reference)) · \($0.status(at: reference))",
                action: .deleteExercise($0.id))
        }
        return events.sorted {
            if $0.at != $1.at { return $0.at > $1.at }
            return $0.id > $1.id
        }
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 60 ? "不到 1 分钟" : HealthDuration.text(seconds)
    }
}
