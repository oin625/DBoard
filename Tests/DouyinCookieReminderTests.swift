import XCTest
import AppKit
@testable import DBoard

final class DouyinCookieReminderTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    private func date(_ year: Int = 2026, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func defaults() -> (UserDefaults, String) {
        let name = "DBoardCookieTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testReminderStartsAtSevenDaysAndStaysVisibleEveryDayUntilExpiry() throws {
        let refreshed = date(2026, 10, 22)
        let ordinary = try XCTUnwrap(DouyinCookieExpiry(refreshedAt: refreshed, on: date(2026, 11, 2), calendar: calendar))
        XCTAssertEqual(ordinary.remainingDays, 19)
        XCTAssertEqual(ordinary.expiresAt, date(2026, 11, 21))
        XCTAssertFalse(ordinary.needsReminder)
        XCTAssertFalse(try XCTUnwrap(DouyinCookieExpiry(refreshedAt: refreshed, on: date(2026, 11, 13), calendar: calendar)).needsReminder)
        for day in 14...21 {
            let expiry = try XCTUnwrap(DouyinCookieExpiry(refreshedAt: refreshed, on: date(2026, 11, day, hour: 8), calendar: calendar))
            XCTAssertEqual(expiry.remainingDays, 21 - day)
            XCTAssertTrue(expiry.needsReminder)
        }
        let overdue = try XCTUnwrap(DouyinCookieExpiry(refreshedAt: refreshed, on: date(2026, 11, 23), calendar: calendar))
        XCTAssertTrue(overdue.expired)
        XCTAssertTrue(overdue.needsReminder)
        XCTAssertEqual(overdue.remainingDays, -2)
    }

    func testExpiryDayDistinguishesDueTodayFromExpiredAndUsesCalendarDays() throws {
        let refreshed = date(2026, 1, 31, hour: 17)
        let morning = try XCTUnwrap(DouyinCookieExpiry(refreshedAt: refreshed, on: date(2026, 3, 2, hour: 8), calendar: calendar))
        XCTAssertEqual(morning.remainingDays, 0)
        XCTAssertFalse(morning.expired)
        XCTAssertTrue(try XCTUnwrap(DouyinCookieExpiry(refreshedAt: refreshed, on: date(2026, 3, 2, hour: 18), calendar: calendar)).expired)
        var zone = calendar
        zone.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = zone.date(from: DateComponents(year: 2026, month: 2, day: 20, hour: 12))!
        let now = zone.date(from: DateComponents(year: 2026, month: 3, day: 22, hour: 10))!
        let expiry = try XCTUnwrap(DouyinCookieExpiry(refreshedAt: start, on: now, calendar: zone))
        XCTAssertEqual(zone.component(.hour, from: expiry.expiresAt), 12)
        XCTAssertEqual(expiry.remainingDays, 0)
        XCTAssertFalse(expiry.expired)
        XCTAssertNil(DouyinCookieExpiry(refreshedAt: start, on: start.addingTimeInterval(-1), calendar: zone))
    }

    func testOldSuccessIsMigratedAndSurvivesLaterFailureAndAppRestart() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let previous = date(2026, 10, 22)
        defaults.set(["phase": "success", "at": previous.timeIntervalSince1970], forKey: "ops.last.douyin-cookie")
        let store = DouyinCookieReminderStore(defaults: defaults, on: date(2026, 11, 2), observeCalendar: false)
        XCTAssertEqual(store.lastSuccessfulRefresh, previous)
        store.recordResult(success: false, at: date(2026, 11, 14))
        defaults.set(["phase": "failed", "at": date(2026, 11, 14).timeIntervalSince1970], forKey: "ops.last.douyin-cookie")
        let restored = DouyinCookieReminderStore(defaults: defaults, on: date(2026, 11, 15), observeCalendar: false)
        XCTAssertEqual(restored.lastSuccessfulRefresh, previous)
        XCTAssertTrue(try XCTUnwrap(restored.expiry).needsReminder)
    }

    func testMissingOrFailedHistoryDoesNotInventARefreshDate() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = date(2026, 11, 2)
        let empty = DouyinCookieReminderStore(defaults: defaults, on: now, observeCalendar: false)
        XCTAssertNil(empty.expiry)
        defaults.set(["phase": "failed", "at": now.timeIntervalSince1970], forKey: "ops.last.douyin-cookie")
        let failed = DouyinCookieReminderStore(defaults: defaults, on: now, observeCalendar: false)
        XCTAssertNil(failed.lastSuccessfulRefresh)
    }

    func testCalendarRefreshUpdatesCountdownAndSuccessfulRefreshHidesReminder() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DouyinCookieReminderStore(defaults: defaults, on: date(2026, 11, 14), observeCalendar: false)
        store.recordResult(success: true, at: date(2026, 10, 22))
        store.refresh(on: date(2026, 11, 14))
        XCTAssertEqual(try XCTUnwrap(store.expiry).remainingDays, 7)
        store.refresh(on: date(2026, 11, 15))
        XCTAssertEqual(try XCTUnwrap(store.expiry).remainingDays, 6)
        store.recordResult(success: true, at: date(2026, 11, 15))
        XCTAssertFalse(try XCTUnwrap(store.expiry).needsReminder)
        XCTAssertEqual(try XCTUnwrap(store.expiry).remainingDays, 30)
        XCTAssertEqual(DouyinCookieReminderStore(defaults: defaults, on: date(2026, 11, 15),
                                                observeCalendar: false).lastSuccessfulRefresh, date(2026, 11, 15))
    }

    @MainActor
    func testRunnerRecordsActualSuccessButFailureAndCancellationKeepIt() throws {
        _ = NSApplication.shared
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DouyinCookieReminderStore(defaults: defaults, observeCalendar: false)
        store.recordResult(success: true, at: date(2026, 10, 22))
        let runner = OpsRunner(defaults: defaults, cookieReminder: store, notifyCompletion: false, recordUsage: { _ in })
        func fixture(_ executable: String, arguments: [String] = []) -> OpsAction {
            OpsAction(id: "douyin-cookie", title: "本地测试", detail: "", icon: "checkmark",
                      executable: executable, arguments: arguments, workingDir: "/tmp",
                      confirm: nil, totalSteps: nil, timeout: 5)
        }
        func waitForCompletion(_ action: OpsAction) {
            let deadline = Date().addingTimeInterval(3)
            while runner.state(action).phase == .running && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertFalse(runner.state(action).phase == .running)
        }
        let success = fixture("/usr/bin/true")
        runner.requestRun(success)
        waitForCompletion(success)
        XCTAssertEqual(runner.state(success).phase, .success)
        let recorded = try XCTUnwrap(store.lastSuccessfulRefresh)
        XCTAssertEqual(recorded, runner.state(success).endedAt)
        let failure = fixture("/usr/bin/false")
        runner.requestRun(failure)
        waitForCompletion(failure)
        XCTAssertEqual(runner.state(failure).phase, .failed)
        XCTAssertEqual(store.lastSuccessfulRefresh, recorded)
        let cancelled = fixture("/bin/sleep", arguments: ["2"])
        runner.requestRun(cancelled)
        runner.cancel(cancelled)
        waitForCompletion(cancelled)
        XCTAssertEqual(runner.state(cancelled).phase, .failed)
        XCTAssertEqual(store.lastSuccessfulRefresh, recorded)
        let restored = DouyinCookieReminderStore(defaults: defaults, observeCalendar: false)
        XCTAssertEqual(restored.lastSuccessfulRefresh, recorded)
    }
}
