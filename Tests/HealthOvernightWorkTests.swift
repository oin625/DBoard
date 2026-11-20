import XCTest
import AppKit
@testable import DBoard

final class HealthOvernightWorkTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(day: Int = 16, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testNextDayUnlockSplitsOffWorkAndStartWorkWithoutCountingAnOvernightBreak() throws {
        let start = date(hour: 9)
        let off = date(hour: 21, minute: 30)
        let back = date(day: 17, hour: 9)
        var clock = HealthClock(document: HealthDocument(checkpointAt: start.timeIntervalSince1970), calendar: calendar)
        clock.locked(at: off, explicitAway: true)
        XCTAssertEqual(clock.document.days["2026-11-16"]?.breakCount(at: off, calendar: calendar), 1)
        clock.unlocked(at: back)
        XCTAssertEqual(clock.document.mode, .desk)
        XCTAssertEqual(clock.document.continuousSeconds, 0)
        XCTAssertEqual(clock.document.days["2026-11-16"]?.deskSeconds, 12.5 * 3600)
        XCTAssertEqual(clock.document.days["2026-11-17"]?.deskSeconds, 0)
        XCTAssertEqual(clock.document.days["2026-11-16"]?.breakCount(at: back, calendar: calendar), 0)

        let yesterday = HealthTimeline.events(in: clock.document, on: off, asOf: back, calendar: calendar)
        let today = HealthTimeline.events(in: clock.document, on: back, calendar: calendar)
        XCTAssertEqual(yesterday.map(\.title), ["下班"])
        XCTAssertEqual(yesterday.first?.at, off.timeIntervalSince1970)
        XCTAssertTrue(yesterday.first?.detail?.contains("12 小时 30 分钟") == true)
        XCTAssertEqual(today.map(\.title), ["上班"])
        XCTAssertEqual(today.first?.at, back.timeIntervalSince1970)
        XCTAssertFalse(today.first?.detail?.contains("离开") == true)

        clock.unlocked(at: back)
        XCTAssertEqual(HealthTimeline.events(in: clock.document, on: back, calendar: calendar).count, 1)
        clock.advance(to: back.addingTimeInterval(300))
        XCTAssertEqual(clock.document.days["2026-11-17"]?.deskSeconds, 300)
        XCTAssertEqual(clock.document.continuousSeconds, 300)
    }

    func testCalendarDateChangeIsEnoughEvenForTwoMinutesAcrossMidnight() {
        let off = date(hour: 23, minute: 59)
        let back = date(day: 17, hour: 0, minute: 1)
        var clock = HealthClock(document: HealthDocument(checkpointAt: off.timeIntervalSince1970), calendar: calendar)
        clock.locked(at: off, explicitAway: true)
        clock.unlocked(at: back)
        XCTAssertEqual(clock.document.days["2026-11-16"]?.breakCount(at: back, calendar: calendar), 0)
        XCTAssertEqual(HealthTimeline.events(in: clock.document, on: back, calendar: calendar).map(\.title), ["上班"])
    }

    func testSameDayReturnStaysABreakAndAutomaticLockNeverInventsOne() {
        let start = date(hour: 9)
        let off = date(hour: 12)
        let back = date(hour: 13)
        var clock = HealthClock(document: HealthDocument(checkpointAt: start.timeIntervalSince1970), calendar: calendar)
        clock.locked(at: off, explicitAway: true)
        clock.unlocked(at: back)
        XCTAssertEqual(clock.document.days["2026-11-16"]?.breakCount(at: back, calendar: calendar), 1)
        let events = HealthTimeline.events(in: clock.document, on: back, calendar: calendar)
        XCTAssertEqual(events.map(\.title), ["回到座位", "离座"])
        XCTAssertTrue(events.first?.detail?.contains("离开 1 小时 0 分钟") == true)

        var automatic = HealthClock(document: HealthDocument(checkpointAt: start.timeIntervalSince1970), calendar: calendar)
        automatic.locked(at: off, explicitAway: false)
        automatic.unlocked(at: back)
        XCTAssertEqual(automatic.document.days["2026-11-16"]?.breakCount(at: back, calendar: calendar), 0)
        XCTAssertTrue(HealthTimeline.events(in: automatic.document, on: back, calendar: calendar).isEmpty)
    }

    func testRestartReconcilesNextDayReturnEvenWhenCheckpointAlreadyMovedPastMidnight() {
        let off = date(hour: 21, minute: 30)
        let back = date(day: 18, hour: 9)
        var clock = HealthClock(document: HealthDocument(checkpointAt: off.timeIntervalSince1970), calendar: calendar)
        clock.locked(at: off, explicitAway: true)
        clock.advance(to: date(day: 18, hour: 3))
        clock.restart(at: back, screenLocked: false)
        XCTAssertEqual(clock.document.days["2026-11-16"]?.breaks.first?.endedAt, back.timeIntervalSince1970)
        XCTAssertEqual(clock.document.days["2026-11-18"]?.deskSeconds, 0)
        XCTAssertTrue(HealthTimeline.events(in: clock.document, on: date(day: 17, hour: 12),
            asOf: back, calendar: calendar).isEmpty)
        XCTAssertEqual(HealthTimeline.events(in: clock.document, on: back, calendar: calendar).map(\.title), ["上班"])

        var stillLocked = HealthClock(document: HealthDocument(checkpointAt: off.timeIntervalSince1970), calendar: calendar)
        stillLocked.locked(at: off, explicitAway: true)
        stillLocked.restart(at: back, screenLocked: true)
        XCTAssertNil(stillLocked.document.days["2026-11-16"]?.breaks.first?.endedAt)
        XCTAssertEqual(stillLocked.document.mode, .away)
        stillLocked.unlocked(at: back.addingTimeInterval(60))
        XCTAssertEqual(HealthTimeline.events(in: stillLocked.document, on: back, calendar: calendar).first?.at,
            back.addingTimeInterval(60).timeIntervalSince1970)
    }

    func testExistingOvernightRecordsAreReclassifiedWithoutLosingOtherRecords() throws {
        let off = date(hour: 21, minute: 30)
        let back = date(day: 17, hour: 9)
        let yesterday = HealthDay(water: [HealthWater(at: off.timeIntervalSince1970, ml: 350)],
            breaks: [HealthBreak(startedAt: off.timeIntervalSince1970,
                endedAt: back.timeIntervalSince1970, deskSecondsBefore: 3600)])
        let document = HealthDocument(days: ["2026-11-16": yesterday], checkpointAt: back.timeIntervalSince1970)
        let restored = try JSONDecoder().decode(HealthDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(restored.days["2026-11-16"]?.water.first?.ml, 350)
        XCTAssertEqual(restored.days["2026-11-16"]?.breakCount(at: back, calendar: calendar), 0)
        XCTAssertEqual(HealthTimeline.events(in: restored, on: back, calendar: calendar).map(\.title), ["上班"])
        XCTAssertEqual(HealthTimeline.events(in: restored, on: off, asOf: back, calendar: calendar)
            .filter { $0.title == "下班" }.count, 1)
    }

    @MainActor
    func testHealthWindowShowsTodayHistoryEvenWhenOnlyTheNewDayStartExists() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HealthWorkView-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let back = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1,
            to: Calendar.current.startOfDay(for: back))!
        let start = yesterday.addingTimeInterval(9 * 3600)
        let off = yesterday.addingTimeInterval(21.5 * 3600)
        let store = HealthStore(url: folder.appendingPathComponent("health.json"), now: start)
        XCTAssertTrue(store.locked(at: off, explicitAway: true))
        XCTAssertTrue(store.unlocked(at: back))
        let monitor = HealthDeskMonitor(store: store, lockScreen: { true })
        let controller = HealthWindowController(store: store, monitor: monitor, activates: false)
        controller.show()
        defer { controller.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        let root = try XCTUnwrap(controller.window?.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        XCTAssertTrue(descendants(root).contains {
            ($0 as? DemandKeyboardActionView)?.keyboardIdentifier == "health-today-history"
        }, "The next-day start belongs in today's history even with no other records")
        if let output = ProcessInfo.processInfo.environment["DBOARD_HEALTH_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output + "/next-day-work.png"))
        }
    }

    func testStoreRestartPersistsNewDayStartAndSummaryExcludesOffWorkFromBreakCount() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HealthOvernight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("health.json")
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        let off = start.addingTimeInterval(12.5 * 3600)
        let back = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let store = HealthStore(url: url, now: start)
        XCTAssertTrue(store.locked(at: off, explicitAway: true))
        let reopened = HealthStore(url: url, now: back)
        XCTAssertTrue(reopened.restart(at: back, screenLocked: false))
        XCTAssertEqual(reopened.document.days[HealthCalendar.key(off)]?.breaks.first?.endedAt, back.timeIntervalSince1970)
        XCTAssertTrue(reopened.summary(at: back).contains("今天离座：0 次"))
        XCTAssertTrue(reopened.summary(at: back).contains("上班"))
        XCTAssertTrue(reopened.summary(at: off).contains("下班"))
        let persisted = HealthStore(url: url, now: back)
        XCTAssertEqual(persisted.document, reopened.document)
        XCTAssertTrue(persisted.tick(at: back.addingTimeInterval(600)))
        XCTAssertEqual(persisted.document.days[HealthCalendar.key(back)]?.deskSeconds, 600)
    }
}
