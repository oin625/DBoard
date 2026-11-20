import XCTest
@testable import DBoard

final class HealthStatisticsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private var now: Date { date(2026, 11, 18) }
    private func period(_ perspective: HealthDashboardPerspective, anchor: Date? = nil) -> HealthStatisticsPeriod {
        HealthStatisticsPeriod(perspective: perspective, anchor: anchor ?? now, now: now, calendar: calendar)
    }

    private var sample: HealthDocument {
        let monday = date(2026, 11, 16)
        let tuesday = date(2026, 11, 17)
        let ended = HealthExercise(at: now.addingTimeInterval(-7200).timeIntervalSince1970,
            title: "散步安排", minutes: 60, endsAt: now.addingTimeInterval(-3600).timeIntervalSince1970)
        let pending = HealthExercise(at: now.addingTimeInterval(7200).timeIntervalSince1970,
            title: "稍后的安排", minutes: 120, endsAt: now.addingTimeInterval(10800).timeIntervalSince1970)
        let futureLegacy = HealthExercise(at: now.addingTimeInterval(3600).timeIntervalSince1970,
            title: "未来的手动记录", minutes: 120)
        return HealthDocument(days: [
            "2026-10-10": HealthDay(deskSeconds: 5000, water: [HealthWater(at: date(2026, 10, 10).timeIntervalSince1970, ml: 2000)]),
            "2026-11-16": HealthDay(deskSeconds: 7200, longestDeskSeconds: 3600,
                water: [HealthWater(at: monday.timeIntervalSince1970, ml: 1050)],
                exercise: [HealthExercise(at: monday.timeIntervalSince1970, title: "手动运动", minutes: 30)],
                breaks: [HealthBreak(startedAt: monday.addingTimeInterval(36000).timeIntervalSince1970,
                    endedAt: tuesday.timeIntervalSince1970)]),
            "2026-11-17": HealthDay(water: [HealthWater(at: tuesday.timeIntervalSince1970, ml: 1400)],
                breaks: [HealthBreak(startedAt: tuesday.addingTimeInterval(-3600).timeIntervalSince1970,
                    endedAt: tuesday.timeIntervalSince1970)]),
            "2026-11-18": HealthDay(deskSeconds: 3600, longestDeskSeconds: 1800,
                water: [HealthWater(at: now.timeIntervalSince1970, ml: 700),
                    HealthWater(at: now.addingTimeInterval(3600).timeIntervalSince1970, ml: 9000)],
                exercise: [ended, pending, futureLegacy]),
            "2026-11-19": HealthDay(deskSeconds: 999999, water: [HealthWater(at: date(2026, 11, 19).timeIntervalSince1970, ml: 9999)])
        ], mode: .paused, checkpointAt: now.timeIntervalSince1970)
    }

    func testNaturalPeriodsMondayWeekAndCurrentPeriodCutoff() {
        let week = period(.week)
        XCTAssertEqual(HealthCalendar.key(week.start, calendar: calendar), "2026-11-16")
        XCTAssertEqual(HealthCalendar.key(week.lastDay, calendar: calendar), "2026-11-22")
        XCTAssertEqual(week.dates.map { HealthCalendar.key($0, calendar: calendar) }, ["2026-11-16", "2026-11-17", "2026-11-18"])
        XCTAssertTrue(week.includesToday)
        XCTAssertFalse(week.canMoveForward)
        XCTAssertEqual(HealthCalendar.key(week.shifted(-1), calendar: calendar), "2026-11-09")
        XCTAssertEqual(period(.month).dates.count, 18)
        XCTAssertEqual(HealthCalendar.key(period(.month).lastDay, calendar: calendar), "2026-11-30")
        XCTAssertEqual(period(.day).dates.count, 1)
        XCTAssertTrue(period(.week, anchor: date(2026, 11, 9)).canMoveForward)
    }

    func testLeapMonthYearBoundaryAndDaylightSavingUseCalendarDates() {
        let leap = HealthStatisticsPeriod(perspective: .month, anchor: date(2024, 2, 29),
            now: date(2024, 3, 1), calendar: calendar)
        XCTAssertEqual(leap.dates.count, 29)
        XCTAssertEqual(HealthCalendar.key(leap.shifted(1), calendar: calendar), "2024-03-01")
        let year = HealthStatisticsPeriod(perspective: .week, anchor: date(2026, 1, 1),
            now: date(2026, 1, 10), calendar: calendar)
        XCTAssertEqual(HealthCalendar.key(year.start, calendar: calendar), "2025-12-29")
        XCTAssertEqual(year.dates.count, 7)
        var eastern = calendar
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        let dst = eastern.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let day = HealthStatisticsPeriod(perspective: .day, anchor: dst, now: dst, calendar: eastern)
        XCTAssertEqual(day.end.timeIntervalSince(day.start), 23 * 3600)
        XCTAssertEqual(day.dates.count, 1)
    }

    func testWeekTotalsUsePerCategoryRecordedDaysAndExcludeUnfinishedOrFutureEvents() throws {
        let document = sample
        let statistics = HealthStatistics(document: document, period: period(.week))
        XCTAssertEqual(statistics.recordDayCount, 3)
        XCTAssertEqual(statistics.waterML, 3150)
        XCTAssertEqual(statistics.waterDailyAverage, 1050)
        XCTAssertEqual(statistics.deskSeconds, 10800)
        XCTAssertEqual(statistics.deskDayCount, 2)
        XCTAssertEqual(statistics.deskDailyAverage, 5400)
        XCTAssertEqual(statistics.longestDeskSeconds, 3600)
        XCTAssertEqual(statistics.breakCount, 1, "Off-work across midnight is not a same-day break.")
        XCTAssertEqual(statistics.exerciseCount, 2)
        XCTAssertEqual(statistics.exerciseMinutes, 90)
        XCTAssertEqual(statistics.exerciseAverageMinutes, 45)
        XCTAssertEqual(statistics.inferredExerciseCount, 1)
        XCTAssertNil(statistics.days[1].deskSeconds)
        XCTAssertNotEqual(statistics.days[0].deskSeries, statistics.days[2].deskSeries,
            "The chart must leave a gap across dates without office records.")
    }

    func testDayAndMonthMetricsRecomputeAfterRecordChanges() throws {
        var document = sample
        let day = HealthStatistics(document: document, period: period(.day))
        XCTAssertEqual(day.waterML, 700)
        XCTAssertEqual(day.deskSeconds, 3600)
        XCTAssertEqual(day.exerciseCount, 1)
        let month = HealthStatistics(document: document, period: period(.month))
        XCTAssertEqual(month.days.count, 18)
        XCTAssertEqual(month.waterML, 3150)
        XCTAssertEqual(month.waterDayCount, 3)
        document.days["2026-11-17"]?.water.removeAll()
        document.days["2026-11-18"]?.exercise.removeAll()
        let updated = HealthStatistics(document: document, period: period(.week))
        XCTAssertEqual(updated.waterML, 1750)
        XCTAssertEqual(updated.waterDayCount, 2)
        XCTAssertEqual(updated.waterDailyAverage, 875)
        XCTAssertEqual(updated.exerciseCount, 1)
        XCTAssertEqual(updated.exerciseAverageMinutes, 30)
    }

    func testEmptyAndFuturePeriodsKeepMissingDataDistinctFromZero() {
        let empty = HealthDocument(checkpointAt: now.timeIntervalSince1970)
        let statistics = HealthStatistics(document: empty, period: period(.week))
        XCTAssertEqual(statistics.recordDayCount, 0)
        XCTAssertEqual(statistics.waterML, 0)
        XCTAssertNil(statistics.waterDailyAverage)
        XCTAssertNil(statistics.deskDailyAverage)
        XCTAssertNil(statistics.exerciseAverageMinutes)
        XCTAssertTrue(statistics.days.allSatisfy { $0.waterML == nil && $0.deskSeconds == nil })
        let future = HealthStatistics(document: sample, period: period(.month, anchor: date(2026, 12, 1)))
        XCTAssertTrue(future.days.isEmpty)
        XCTAssertEqual(future.exerciseCount, 0)
    }
}
