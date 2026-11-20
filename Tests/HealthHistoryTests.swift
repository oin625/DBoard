import XCTest
import AppKit
import SwiftUI
@testable import DBoard

final class HealthHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))! }

    func testHistoryUsesThirtyCalendarDaysAndSeparatesTotalsFromChronologicalDetails() throws {
        let today = calendar.startOfDay(for: now)
        let earlier = calendar.date(byAdding: .day, value: -1, to: today)!
        let off = earlier.addingTimeInterval(21.5 * 3600)
        let back = today.addingTimeInterval(9 * 3600)
        let water = HealthWater(at: today.addingTimeInterval(10 * 3600).timeIntervalSince1970, ml: 350)
        let finished = HealthExercise(at: today.addingTimeInterval(8 * 3600).timeIntervalSince1970,
            title: "散步", minutes: 30, endsAt: today.addingTimeInterval(8.5 * 3600).timeIntervalSince1970)
        let pending = HealthExercise(at: today.addingTimeInterval(20 * 3600).timeIntervalSince1970,
            title: "羽毛球", minutes: 60, endsAt: today.addingTimeInterval(21 * 3600).timeIntervalSince1970)
        let document = HealthDocument(days: [
            "2026-10-18": HealthDay(deskSeconds: 100),
            "2026-10-19": HealthDay(deskSeconds: 100),
            "2026-11-01": HealthDay(deskSeconds: 100),
            "2026-11-10": HealthDay(deskSeconds: 100),
            "2026-11-16": HealthDay(breaks: [HealthBreak(startedAt: off.timeIntervalSince1970,
                endedAt: back.timeIntervalSince1970, deskSecondsBefore: 3600)]),
            "2026-11-17": HealthDay(deskSeconds: 7200, longestDeskSeconds: 3600,
                water: [water], exercise: [finished, pending]),
            "2026-11-18": HealthDay(deskSeconds: 100)
        ], checkpointAt: now.timeIntervalSince1970)
        let days = HealthHistory.days(in: document, at: now, calendar: calendar)
        XCTAssertEqual(days.map { HealthCalendar.key($0.date, calendar: calendar) }, ["2026-11-17", "2026-11-16", "2026-11-10", "2026-11-01", "2026-10-19"])
        let current = try XCTUnwrap(days.first)
        XCTAssertEqual(current.waterML, 350)
        XCTAssertEqual(current.completedExercise.map(\.title), ["散步"])
        XCTAssertEqual(current.pendingExercise.map(\.title), ["羽毛球"])
        XCTAssertEqual(current.exerciseMinutes, 30)
        XCTAssertEqual(current.events(for: .desk).map(\.title), ["上班"])
        XCTAssertEqual(current.events(for: .water).map(\.at), [water.at])
        XCTAssertEqual(current.events(for: .exercise).map(\.title), ["散步"])
        XCTAssertEqual(current.events.map(\.at), current.events.map(\.at).sorted())
        XCTAssertEqual(days.first { $0.id == "2026-11-16" }?.events(for: .desk).map(\.title), ["下班"])
    }

    func testReturnDayIsVisibleEvenWithoutItsOwnStoredDayRecord() throws {
        let today = calendar.startOfDay(for: now)
        let off = today.addingTimeInterval(-2.5 * 3600)
        let document = HealthDocument(days: [
            "2026-11-16": HealthDay(breaks: [HealthBreak(startedAt: off.timeIntervalSince1970,
                endedAt: now.timeIntervalSince1970, deskSecondsBefore: 1800)])
        ], checkpointAt: now.timeIntervalSince1970)
        let days = HealthHistory.days(in: document, at: now, calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first?.events(for: .desk).map(\.title), ["上班"])
        XCTAssertEqual(days.first?.records.deskSeconds, 0)
    }

    func testAllHistoryIncludesOldRecordsAndCrossDayReturnsWithoutAddingMissingDays() {
        let off = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 22))!
        let back = off.addingTimeInterval(11 * 3600)
        let document = HealthDocument(days: [
            "2025-01-01": HealthDay(water: [HealthWater(at: off.timeIntervalSince1970, ml: 350)],
                breaks: [HealthBreak(startedAt: off.timeIntervalSince1970, endedAt: back.timeIntervalSince1970)]),
            "2026-11-17": HealthDay(deskSeconds: 100),
            "2026-11-18": HealthDay(deskSeconds: 100)
        ], checkpointAt: now.timeIntervalSince1970)
        let days = HealthHistory.allDays(in: document, at: now, calendar: calendar)
        XCTAssertEqual(days.map(\.id), ["2026-11-17", "2025-01-02", "2025-01-01"])
        XCTAssertEqual(days.first { $0.id == "2025-01-02" }?.events(for: .desk).map(\.title), ["上班"])
        XCTAssertEqual(days.last?.waterML, 350)
        XCTAssertEqual(document.days.count, 3, "Viewing history must not rewrite or fill missing dates.")
        XCTAssertEqual(HealthHistory.days(in: document, at: now, calendar: calendar).map(\.id), ["2026-11-17"])
    }

    func testWaterRecordUsesAllDatesAndRecalculatesAfterUndoAndNewDrinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HealthWaterRecord-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = calendar.date(byAdding: .day, value: -45, to: now)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let store = HealthStore(url: folder.appendingPathComponent("health.json"), now: old)
        XCTAssertNil(HealthHistory.waterRecord(in: store.document, at: now, calendar: calendar))
        XCTAssertTrue(store.water(ml: 1800, at: old))
        let oldDrink = try XCTUnwrap(store.document.days[HealthCalendar.key(old, calendar: calendar)]?.water.first?.id)
        XCTAssertTrue(store.water(ml: 1400, at: yesterday))
        XCTAssertTrue(store.water(ml: 700, at: now))
        XCTAssertEqual(HealthHistory.waterRecord(in: store.document, at: now, calendar: calendar)?.ml, 1800)
        XCTAssertTrue(store.removeWater(oldDrink, at: now))
        var record = try XCTUnwrap(HealthHistory.waterRecord(in: store.document, at: now, calendar: calendar))
        XCTAssertEqual(record.ml, 1400)
        XCTAssertEqual(HealthCalendar.key(record.date, calendar: calendar), HealthCalendar.key(yesterday, calendar: calendar))
        XCTAssertTrue(store.water(ml: 800, at: now))
        record = try XCTUnwrap(HealthHistory.waterRecord(in: store.document, at: now, calendar: calendar))
        XCTAssertEqual(record.ml, 1500)
        XCTAssertEqual(HealthCalendar.key(record.date, calendar: calendar), HealthCalendar.key(now, calendar: calendar))
        let latestDrink = try XCTUnwrap(store.document.days[HealthCalendar.key(now, calendar: calendar)]?.water.last?.id)
        XCTAssertTrue(store.removeWater(latestDrink, at: now))
        XCTAssertEqual(HealthHistory.waterRecord(in: store.document, at: now, calendar: calendar)?.ml, 1400)
    }

    func testWaterRecordTiesUseEarliestDateAndDoNotIncludeFuturePlans() {
        let document = HealthDocument(days: [
            "2026-11-16": HealthDay(water: [HealthWater(at: now.timeIntervalSince1970, ml: 1400)]),
            "2026-11-17": HealthDay(water: [HealthWater(at: now.timeIntervalSince1970, ml: 1400)]),
            "2026-11-18": HealthDay(water: [HealthWater(at: now.timeIntervalSince1970, ml: 2000)])
        ], checkpointAt: now.timeIntervalSince1970)
        let record = HealthHistory.waterRecord(in: document, at: now, calendar: calendar)
        XCTAssertEqual(record?.ml, 1400)
        XCTAssertEqual(record.map { HealthCalendar.key($0.date, calendar: calendar) }, "2026-11-16")
    }

    @MainActor
    func testAllHistoryEntranceOpensOldDetailsAndReturnsToHealth() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HealthAllHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = Date()
        let old = Calendar.current.date(byAdding: .day, value: -40, to: reference)!
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: reference)!
        let drink = HealthWater(at: old.timeIntervalSince1970, ml: 1800)
        let document = HealthDocument(days: [
            HealthCalendar.key(old): HealthDay(water: [drink]),
            HealthCalendar.key(yesterday): HealthDay(water: [HealthWater(at: yesterday.timeIntervalSince1970, ml: 1400)])
        ], mode: .paused, checkpointAt: reference.timeIntervalSince1970)
        let url = folder.appendingPathComponent("health.json")
        try JSONEncoder().encode(document).write(to: url)
        let store = HealthStore(url: url, now: reference)
        let controller = HealthWindowController(store: store,
            monitor: HealthDeskMonitor(store: store, lockScreen: { true }), activates: false)
        controller.show(); settle()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        try clickAction("health-all-history", window)
        XCTAssertTrue(has(try XCTUnwrap(window.contentView), "health-history-back"))
        try clickAction("health-history-day-" + HealthCalendar.key(old), window)
        XCTAssertTrue(has(try XCTUnwrap(window.contentView), "health-history-water-undo-" + drink.id))
        try snapshot(window, name: "all-history")
        try clickAction("health-history-water-undo-" + drink.id, window)
        XCTAssertTrue(store.document.days[HealthCalendar.key(old)]?.water.isEmpty == true)
        XCTAssertEqual(HealthHistory.waterRecord(in: store.document, at: reference)?.ml, 1400)
        try clickAction("health-history-back", window)
        XCTAssertTrue(has(try XCTUnwrap(window.contentView), "health-month-history"))
        XCTAssertTrue(has(try XCTUnwrap(window.contentView), "health-water-fill"))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance); settle()
            try snapshot(window, name: appearance == .aqua ? "health-record-light" : "health-record-dark")
        }
    }

    @MainActor
    func testDayStartsCollapsedAndClickRevealsSeparateDetailSections() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HealthHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let today = Calendar.current.startOfDay(for: Date())
        let reference = today.addingTimeInterval(22 * 3600)
        let store = HealthStore(url: folder.appendingPathComponent("health.json"), now: today.addingTimeInterval(9 * 3600))
        XCTAssertTrue(store.locked(at: today.addingTimeInterval(10 * 3600), explicitAway: true))
        XCTAssertTrue(store.unlocked(at: today.addingTimeInterval(10.25 * 3600)))
        XCTAssertTrue(store.water(ml: 350, at: today.addingTimeInterval(11 * 3600)))
        XCTAssertTrue(store.scheduleExercise(title: "羽毛球",
            startsAt: today.addingTimeInterval(20 * 3600), endsAt: today.addingTimeInterval(21 * 3600),
            at: today.addingTimeInterval(11 * 3600)))
        let day = try XCTUnwrap(HealthHistory.days(in: store.snapshot(at: reference), at: reference).first)
        let view = HealthHistoryDayView(day: day, store: store, editExercise: { _ in })
            .disclosureGroupStyle(TryDisclosureStyle())
            .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .demandFloatingCanvas().environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
        let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: 820, height: 740))
        let host = NSHostingController(rootView: view); host.sizingOptions = []
        window.setContent(host); window.setContentSize(NSSize(width: 820, height: 740)); window.orderBack(nil)
        defer { window.close() }
        settle()
        let root = try XCTUnwrap(window.contentView)
        let waterID = try XCTUnwrap(day.records.water.first?.id)
        let exerciseID = try XCTUnwrap(day.records.exercise.first?.id)
        XCTAssertFalse(has(root, "health-history-water-undo-" + waterID))
        XCTAssertFalse(has(root, "health-history-exercise-delete-" + exerciseID))
        let toggle = try action(root, "health-history-day-" + day.id)
        let point = toggle.convert(NSPoint(x: toggle.bounds.minX + 70,
            y: toggle.isFlipped ? toggle.bounds.minY + 25 : toggle.bounds.maxY - 25), to: nil)
        click(window, point); settle()
        XCTAssertTrue(has(root, "health-history-water-undo-" + waterID))
        XCTAssertTrue(has(root, "health-history-exercise-delete-" + exerciseID))
        if let output = ProcessInfo.processInfo.environment["DBOARD_HEALTH_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            for width in [CGFloat(820), 520] {
                window.setContentSize(NSSize(width: width, height: 740)); settle()
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output + "/history-\(Int(width)).png"))
            }
        }
    }

    @MainActor private func clickAction(_ id: String, _ window: NSWindow) throws {
        let target = try action(try XCTUnwrap(window.contentView), id)
        var ancestor = target.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                document.scrollToVisible(target.convert(target.bounds, to: document).insetBy(dx: 0, dy: -8))
            }
            ancestor = view.superview
        }
        settle()
        click(window, target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil))
        settle()
    }
    @MainActor private func snapshot(_ window: NSWindow, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_HEALTH_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func has(_ root: NSView, _ id: String) -> Bool {
        descendants(root).contains { ($0 as? DemandKeyboardActionView)?.keyboardIdentifier == id }
    }
    @MainActor private func action(_ root: NSView, _ id: String) throws -> DemandKeyboardActionView {
        try XCTUnwrap(descendants(root).compactMap { $0 as? DemandKeyboardActionView }.first { $0.keyboardIdentifier == id })
    }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
    @MainActor private func click(_ window: NSWindow, _ point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
}
