import Foundation
import Combine

enum TryWorkspaceModule: String, CaseIterable, Identifiable {
    case digestion, idea, health
    var id: String { rawValue }
    var title: String { switch self { case .digestion: return "学习"; case .idea: return "想法"; case .health: return "健康" } }
    var entryKind: TryKind? { switch self { case .digestion: return .digestion; case .idea: return .idea; case .health: return nil } }
}

struct HealthSettings: Codable, Equatable {
    var cupML = 350
    var waterGoalML = 0
    var weeklyExerciseGoal = 0
    var deskReminderMinutes = 50
}
struct HealthWater: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var at: Double
    var ml: Int
}
struct HealthExercise: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var at: Double
    var title: String
    var minutes: Int
    // nil denotes a historical, manually recorded exercise. Plans keep their
    // end time so completion is deterministic across sleep, restart and reads.
    var endsAt: Double?

    func isCompleted(at now: Date) -> Bool {
        endsAt.map { $0 <= now.timeIntervalSince1970 } ?? true
    }
    func status(at now: Date) -> String {
        if isCompleted(at: now) { return endsAt == nil ? "已完成" : "已完成 · 按安排计入" }
        return at <= now.timeIntervalSince1970 ? "进行中" : "待开始"
    }
    func timeRange(relativeTo now: Date = Date()) -> String {
        guard let endsAt else { return HealthDuration.text(Double(minutes * 60)) }
        let start = Date(timeIntervalSince1970: at)
        let end = Date(timeIntervalSince1970: endsAt)
        let calendar = Calendar.current
        func day(_ date: Date) -> String {
            if calendar.isDate(date, inSameDayAs: now) { return "今天" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               calendar.isDate(date, inSameDayAs: tomorrow) { return "明天" }
            return date.formatted(.dateTime.month().day())
        }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let endDay = calendar.isDate(start, inSameDayAs: end) ? "" : day(end) + " "
        return "\(day(start)) \(time.string(from: start))–\(endDay)\(time.string(from: end))"
    }
}
struct HealthBreak: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var startedAt: Double
    var endedAt: Double?
    var deskSecondsBefore: Double?

    func crossesDay(at now: Date, calendar: Calendar = .current) -> Bool {
        !calendar.isDate(Date(timeIntervalSince1970: startedAt),
            inSameDayAs: Date(timeIntervalSince1970: endedAt ?? now.timeIntervalSince1970))
    }
}
struct HealthDay: Codable, Equatable {
    var deskSeconds = 0.0
    var longestDeskSeconds = 0.0
    var water: [HealthWater] = []
    var exercise: [HealthExercise] = []
    var breaks: [HealthBreak] = []

    func breakCount(at now: Date = Date(), calendar: Calendar = .current) -> Int {
        breaks.filter { !$0.crossesDay(at: now, calendar: calendar) }.count
    }
}
enum HealthDeskMode: String, Codable { case desk, away, locked, paused }
struct HealthDocument: Codable, Equatable {
    var version = 1
    var settings = HealthSettings()
    var days: [String: HealthDay] = [:]
    var mode: HealthDeskMode = .desk
    var continuousSeconds = 0.0
    var cupFilled: Bool?
    var checkpointAt: Double

    var isCupFilled: Bool { cupFilled == true }
}

enum HealthDuration {
    static func text(_ seconds: Double) -> String {
        let minutes = seconds.isFinite ? max(0, Int(seconds / 60)) : 0
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}

enum HealthCalendar {
    static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// A lock is a confirmed break only when our explicit away action preceded it.
struct HealthClock {
    var document: HealthDocument
    var calendar = Calendar.current
    mutating func advance(to now: Date) {
        let end = now.timeIntervalSince1970
        guard end >= document.checkpointAt else { document.checkpointAt = end; return }
        if document.mode != .desk && !calendar.isDate(now, inSameDayAs: Date(timeIntervalSince1970: document.checkpointAt)) {
            document.continuousSeconds = 0
        }
        if document.mode == .desk {
            var cursor = Date(timeIntervalSince1970: document.checkpointAt)
            while cursor < now {
                let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
                let stop = min(nextDay, now)
                if cursor == calendar.startOfDay(for: cursor) { document.continuousSeconds = 0 }
                let duration = stop.timeIntervalSince(cursor)
                document.continuousSeconds += duration
                let key = HealthCalendar.key(cursor, calendar: calendar)
                var day = document.days[key] ?? HealthDay()
                day.deskSeconds += duration
                day.longestDeskSeconds = max(day.longestDeskSeconds, document.continuousSeconds)
                document.days[key] = day
                cursor = stop
            }
        }
        document.checkpointAt = end
    }
    mutating func locked(at now: Date, explicitAway: Bool) {
        advance(to: now)
        if document.mode == .away { return }
        if explicitAway {
            let key = HealthCalendar.key(now, calendar: calendar)
            var day = document.days[key] ?? HealthDay()
            day.breaks.append(HealthBreak(startedAt: now.timeIntervalSince1970,
                deskSecondsBefore: document.continuousSeconds))
            document.days[key] = day
            document.mode = .away
        } else if document.mode == .desk {
            document.mode = .locked
        }
    }
    mutating func unlocked(at now: Date) {
        advance(to: now)
        if document.mode == .away {
            finishBreak(at: now)
            document.continuousSeconds = 0
            document.mode = .desk
        } else if document.mode == .locked {
            document.mode = .desk
        }
    }
    mutating func finishBreak(at now: Date, sameDayFallback: Date? = nil) {
        var resumedOnNewDay = false
        for key in Array(document.days.keys) {
            var day = document.days[key]!
            for index in day.breaks.indices where day.breaks[index].endedAt == nil {
                let overnight = day.breaks[index].crossesDay(at: now, calendar: calendar)
                // A next-day return is the start of work, even after an app restart.
                // For same-day restarts keep the existing conservative break duration.
                let end = overnight ? now : (sameDayFallback ?? now)
                day.breaks[index].endedAt = max(day.breaks[index].startedAt, end.timeIntervalSince1970)
                resumedOnNewDay = resumedOnNewDay || overnight
            }
            document.days[key] = day
        }
        if resumedOnNewDay {
            let key = HealthCalendar.key(now, calendar: calendar)
            if document.days[key] == nil { document.days[key] = HealthDay() }
        }
    }
    mutating func pause(at now: Date) {
        advance(to: now)
        if document.mode == .away { finishBreak(at: now); document.continuousSeconds = 0 }
        document.mode = .paused
    }
    mutating func resume(at now: Date) {
        advance(to: now)
        if document.mode == .paused { document.mode = .desk }
    }
    mutating func restart(at now: Date, screenLocked: Bool) {
        // Never count the time while DBoard was stopped as desk time.
        if document.mode == .away && !screenLocked {
            finishBreak(at: now, sameDayFallback: Date(timeIntervalSince1970: document.checkpointAt))
            document.continuousSeconds = 0
            document.mode = .desk
        } else if document.mode == .locked && !screenLocked { document.mode = .desk }
        else if document.mode == .desk && screenLocked { document.mode = .locked }
        if !calendar.isDate(now, inSameDayAs: Date(timeIntervalSince1970: document.checkpointAt)) {
            document.continuousSeconds = 0
        }
        document.checkpointAt = now.timeIntervalSince1970
    }
}

final class HealthStore: ObservableObject {
    static let shared = HealthStore()
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/dboard-health.json")
    @Published private(set) var document: HealthDocument
    @Published private(set) var error: String?
    private let url: URL
    private var unreadable = false
    init(url: URL = HealthStore.defaultURL, now: Date = Date()) {
        self.url = url
        document = HealthDocument(checkpointAt: now.timeIntervalSince1970)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let value = try JSONDecoder().decode(HealthDocument.self, from: Data(contentsOf: url))
                guard value.version == 1, value.checkpointAt.isFinite,
                      value.continuousSeconds.isFinite, value.continuousSeconds >= 0,
                      value.settings.cupML > 0, value.settings.waterGoalML >= 0,
                      value.settings.weeklyExerciseGoal >= 0, value.settings.deskReminderMinutes > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                document = value
            } catch {
                unreadable = true
                self.error = "健康记录无法读取，原文件已保留。"
            }
        }
    }
    func snapshot(at now: Date = Date()) -> HealthDocument {
        var clock = HealthClock(document: document)
        clock.advance(to: now)
        return clock.document
    }
    @discardableResult
    private func update(_ change: (inout HealthDocument) -> Void, at now: Date = Date()) -> Bool {
        guard !unreadable else { return false }
        var clock = HealthClock(document: document)
        clock.advance(to: now)
        change(&clock.document)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(clock.document)
            try data.write(to: url, options: .atomic)
            document = clock.document
            error = nil
            return true
        } catch { self.error = "健康记录保存失败，操作未提交；请重试。"; return false }
    }
    @discardableResult
    private func transition(at now: Date, _ action: (inout HealthClock) -> Void) -> Bool {
        update({ value in
            var clock = HealthClock(document: value)
            action(&clock); value = clock.document
        }, at: now)
    }
    @discardableResult func tick(at now: Date = Date()) -> Bool { update({ _ in }, at: now) }
    @discardableResult func restart(at now: Date = Date(), screenLocked: Bool) -> Bool {
        // Restart must not advance the old checkpoint before reconciling the gap.
        guard !unreadable else { return false }
        var clock = HealthClock(document: document)
        clock.restart(at: now, screenLocked: screenLocked)
        let old = document
        document = clock.document
        if update({ _ in }, at: now) { return true }
        document = old
        return false
    }
    @discardableResult func locked(at now: Date = Date(), explicitAway: Bool) -> Bool {
        transition(at: now) { $0.locked(at: now, explicitAway: explicitAway) }
    }
    @discardableResult func unlocked(at now: Date = Date()) -> Bool {
        transition(at: now) { $0.unlocked(at: now) }
    }
    @discardableResult func pause(at now: Date = Date()) -> Bool { transition(at: now) { $0.pause(at: now) } }
    @discardableResult func resume(at now: Date = Date()) -> Bool { transition(at: now) { $0.resume(at: now) } }
    @discardableResult func fillCup(at now: Date = Date()) -> Bool {
        guard !document.isCupFilled else { return false }
        return update({ $0.cupFilled = true }, at: now)
    }
    @discardableResult func drinkCup(at now: Date = Date()) -> Bool {
        guard document.isCupFilled else { return false }
        let amount = document.settings.cupML
        guard amount > 0, amount <= 5000 else { return false }
        return update({ value in
            guard value.isCupFilled else { return }
            let key = HealthCalendar.key(now)
            var day = value.days[key] ?? HealthDay()
            day.water.append(HealthWater(at: now.timeIntervalSince1970, ml: amount))
            value.days[key] = day
            value.cupFilled = false
        }, at: now)
    }
    @discardableResult func water(ml: Int? = nil, at now: Date = Date()) -> Bool {
        let amount = ml ?? document.settings.cupML
        guard amount > 0, amount <= 5000 else { return false }
        return update({ value in
            let key = HealthCalendar.key(now)
            var day = value.days[key] ?? HealthDay()
            day.water.append(HealthWater(at: now.timeIntervalSince1970, ml: amount))
            value.days[key] = day
        }, at: now)
    }
    @discardableResult func exercise(title: String, minutes: Int, at now: Date = Date()) -> Bool {
        guard minutes > 0, minutes <= 1440 else { return false }
        return update({ value in
            let key = HealthCalendar.key(now)
            var day = value.days[key] ?? HealthDay()
            day.exercise.append(HealthExercise(at: now.timeIntervalSince1970,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "运动" : title, minutes: minutes))
            value.days[key] = day
        }, at: now)
    }
    @discardableResult
    func scheduleExercise(id: String? = nil, title: String, startsAt: Date, endsAt: Date,
                          at now: Date = Date()) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = endsAt.timeIntervalSince(startsAt)
        guard !name.isEmpty, startsAt.timeIntervalSince1970.isFinite,
              endsAt.timeIntervalSince1970.isFinite, duration >= 60, duration <= 86400 else { return false }
        // Editing is a move, never an append of another copy.
        if let id, !document.days.values.flatMap(\.exercise).contains(where: { $0.id == id }) { return false }
        let record = HealthExercise(id: id ?? UUID().uuidString, at: startsAt.timeIntervalSince1970,
            title: name, minutes: Int(duration / 60), endsAt: endsAt.timeIntervalSince1970)
        return update({ value in
            if let id {
                for key in value.days.keys { value.days[key]?.exercise.removeAll { $0.id == id } }
            }
            let key = HealthCalendar.key(startsAt)
            var day = value.days[key] ?? HealthDay()
            day.exercise.append(record)
            value.days[key] = day
        }, at: now)
    }
    func pendingExercise(at now: Date = Date()) -> [HealthExercise] {
        document.days.values.flatMap(\.exercise)
            .filter { !$0.isCompleted(at: now) }
            .sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
    }
    @discardableResult func removeWater(_ id: String, at now: Date = Date()) -> Bool {
        update({ value in
            for key in value.days.keys { value.days[key]?.water.removeAll { $0.id == id } }
        }, at: now)
    }
    @discardableResult func removeExercise(_ id: String, at now: Date = Date()) -> Bool {
        update({ value in
            for key in value.days.keys { value.days[key]?.exercise.removeAll { $0.id == id } }
        }, at: now)
    }
    @discardableResult func settings(_ settings: HealthSettings) -> Bool {
        guard settings.cupML > 0, settings.cupML <= 5000, settings.waterGoalML >= 0,
              settings.waterGoalML <= 10000, settings.weeklyExerciseGoal >= 0,
              settings.weeklyExerciseGoal <= 50, settings.deskReminderMinutes > 0,
              settings.deskReminderMinutes <= 240 else { return false }
        return update { $0.settings = settings }
    }
    func weekExerciseCount(at now: Date = Date()) -> Int {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return document.days.values.flatMap(\.exercise).filter {
            $0.isCompleted(at: now) && week.contains(Date(timeIntervalSince1970: $0.at))
        }.count
    }
    func summary(at now: Date = Date()) -> String {
        let value = snapshot(at: now)
        let today = value.days[HealthCalendar.key(now)] ?? HealthDay()
        let recentExercise = value.days.values.flatMap(\.exercise).filter {
            $0.isCompleted(at: now) && $0.at >= now.addingTimeInterval(-7 * 86400).timeIntervalSince1970
        }.sorted { $0.at < $1.at }.map {
            "\($0.title) · \($0.timeRange(relativeTo: now)) · \($0.status(at: now))"
        }.joined(separator: "；")
        let workBoundaries = HealthTimeline.events(in: value, on: now).filter {
            $0.title == "上班" || $0.title == "下班"
        }.map {
            let time = Date(timeIntervalSince1970: $0.at).formatted(.dateTime.hour().minute())
            return "\(time) \($0.title)"
        }.joined(separator: "；")
        let plans = pendingExercise(at: now).map {
            "\($0.title) · \($0.timeRange(relativeTo: now)) · \($0.status(at: now))"
        }.joined(separator: "；")
        return """
        D板 · 次 Try 健康记录（\(HealthCalendar.key(now))）
        连续办公：\(HealthDuration.text(value.continuousSeconds))；状态：\(value.mode.rawValue)
        今天累计办公：\(HealthDuration.text(today.deskSeconds))；最长连续办公：\(HealthDuration.text(today.longestDeskSeconds))
        今天离座：\(today.breakCount(at: now)) 次；喝水：\(today.water.map(\.ml).reduce(0, +)) ml
        今天上下班：\(workBoundaries.isEmpty ? "暂无记录" : workBoundaries)
        本周运动：\(weekExerciseCount(at: now)) 次
        杯子容量：\(value.settings.cupML) ml；每日喝水目标：\(value.settings.waterGoalML == 0 ? "未设置" : "\(value.settings.waterGoalML) ml")
        最近七天已完成运动：\(recentExercise.isEmpty ? "暂无" : recentExercise)
        未结束的运动安排：\(plans.isEmpty ? "暂无" : plans)
        运动安排到结束时间仍保留就自动计为完成，属于按计划推定，并非实际运动传感器记录；不要把未结束的安排算成已完成。
        请根据实际记录，帮我安排适合上班间隙的活动和运动；先了解我的目标、现有习惯、可用时间与活动限制。缺失记录保持未知，建议清晰、简短、容易执行。
        """
    }
}
