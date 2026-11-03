import Foundation

/// 新日期使用完整年份；兼容旧 M.d 周期，所有计算以本机自然日为单位。
enum DemandDates {
    private struct Value {
        let year: Int?
        let month: Int
        let day: Int
        var order: Int { month * 100 + day }
    }

    private static func parse(_ text: String?) -> Value? {
        guard let text, !text.trimmed.isEmpty else { return nil }
        let s = text.trimmed
        let full = s.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
        let short = s.range(of: #"^[0-9]{1,2}\.[0-9]{1,2}$"#, options: .regularExpression) != nil
        guard full || short else { return nil }
        let parts = s.split(separator: full ? "-" : ".").compactMap { Int($0) }
        let month = parts[full ? 1 : 0], day = parts[full ? 2 : 1]
        guard (1...12).contains(month), (1...31).contains(day), !full || parts[0] > 0 else { return nil }
        return Value(year: full ? parts[0] : nil, month: month, day: day)
    }

    private static func date(_ value: Value, year: Int, calendar: Calendar) -> Date? {
        guard let result = calendar.date(from: DateComponents(year: year, month: value.month, day: value.day)) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day], from: result)
        guard checked.year == year, checked.month == value.month, checked.day == value.day else { return nil }
        return calendar.startOfDay(for: result)
    }

    static func period(start: String?, deadline: String?, on now: Date = Date(), calendar: Calendar = .current)
        -> (start: Date?, deadline: Date?)? {
        let s = parse(start), e = parse(deadline)
        guard (start?.trimmed.isEmpty != false || s != nil),
              (deadline?.trimmed.isEmpty != false || e != nil) else { return nil }
        let year = calendar.component(.year, from: now)
        let crosses = s != nil && e != nil && e!.order < s!.order
        var startYear = s?.year ?? year
        var endYear = e?.year ?? year
        if let s, let e {
            if s.year != nil { endYear = e.year ?? (startYear + (crosses ? 1 : 0)) }
            else if e.year != nil { startYear = endYear - (crosses ? 1 : 0) }
            else {
                if crosses && calendar.component(.month, from: now) <= e.month { startYear -= 1 }
                endYear = startYear + (crosses ? 1 : 0)
            }
        }
        let startDate = s.flatMap { date($0, year: startYear, calendar: calendar) }
        let endDate = e.flatMap { date($0, year: endYear, calendar: calendar) }
        guard s == nil || startDate != nil, e == nil || endDate != nil else { return nil }
        if let startDate, let endDate, endDate < startDate { return nil }
        return (startDate, endDate)
    }

    static func daysRemaining(start: String?, deadline: String?, on now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let end = period(start: start, deadline: deadline, on: now, calendar: calendar)?.deadline else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: end).day
    }

    static func today(on now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }
}

extension DItemDraft {
    var validationError: String? {
        if name.trimmed.isEmpty { return "请填写需求名称" }
        if [id, name, branch].contains(where: { $0.contains("\n") || $0.contains("\r") }) {
            return "名称和分支请保持为单行"
        }
        if DemandDates.period(start: start, deadline: deadline) == nil {
            return "请填写有效日期（2026-11-19 或 11.19），截止不能早于开始"
        }
        if chatLinks?.isValid == false { return "请检查关联群聊，主要和次要群聊不能重复。" }
        return promptSections.validationError
    }
}
