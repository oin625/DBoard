import XCTest
import AppKit
@testable import DBoard

final class HealthExerciseScheduleTests: XCTestCase {
    private let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

    func testPlanCompletesAtEndWithoutTickAndSurvivesClosedApp() throws {
        try isolated { store, url in
            let begin = now.addingTimeInterval(3600)
            let end = begin.addingTimeInterval(3600)
            XCTAssertTrue(store.scheduleExercise(title: "羽毛球", startsAt: begin, endsAt: end, at: now))
            let plan = try XCTUnwrap(store.pendingExercise(at: now).first)
            XCTAssertEqual(plan.status(at: now), "待开始")
            XCTAssertEqual(plan.status(at: begin), "进行中")
            XCTAssertEqual(store.weekExerciseCount(at: end.addingTimeInterval(-1)), 0)
            XCTAssertEqual(store.pendingExercise(at: end).count, 0)
            XCTAssertEqual(store.weekExerciseCount(at: end), 1)
            // No timer, UI, or computer operation is needed to finish the plan.
            let restored = HealthStore(url: url, now: end)
            XCTAssertTrue(restored.restart(at: end, screenLocked: false))
            XCTAssertEqual(restored.weekExerciseCount(at: end), 1)
            XCTAssertEqual(restored.document.days.values.flatMap(\.exercise).count, 1)
            XCTAssertEqual(restored.document.days.values.map(\.deskSeconds).reduce(0, +), 0)
            XCTAssertTrue(restored.tick(at: end))
            XCTAssertEqual(restored.weekExerciseCount(at: end), 1)
            let summary = restored.summary(at: end)
            XCTAssertTrue(summary.contains("按安排计入"))
            XCTAssertTrue(summary.contains("未结束的运动安排：暂无"))
        }
    }

    func testEditMovesPlanAndCancelCannotBecomeCompletedLater() throws {
        try isolated { store, url in
            let begin = now.addingTimeInterval(3600)
            XCTAssertTrue(store.scheduleExercise(title: "羽毛球", startsAt: begin,
                endsAt: begin.addingTimeInterval(3600), at: now))
            let id = try XCTUnwrap(store.pendingExercise(at: now).first?.id)
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: begin)!
            XCTAssertTrue(store.scheduleExercise(id: id, title: "篮球", startsAt: tomorrow,
                endsAt: tomorrow.addingTimeInterval(5400), at: now))
            XCTAssertTrue(store.document.days[HealthCalendar.key(now)]!.exercise.isEmpty)
            XCTAssertEqual(store.document.days.values.flatMap(\.exercise).map(\.id), [id])
            XCTAssertEqual(store.pendingExercise(at: begin.addingTimeInterval(7200)).first?.title, "篮球")
            XCTAssertEqual(store.pendingExercise(at: now).first?.minutes, 90)
            XCTAssertTrue(store.removeExercise(id, at: now))
            let restored = HealthStore(url: url, now: tomorrow.addingTimeInterval(7200))
            XCTAssertTrue(restored.pendingExercise(at: tomorrow.addingTimeInterval(7200)).isEmpty)
            XCTAssertEqual(restored.weekExerciseCount(at: tomorrow.addingTimeInterval(7200)), 0)
        }
    }

    func testCrossMidnightBelongsToStartingDayAndFuturePlansStayOutOfSummaryTotals() throws {
        try isolated { store, _ in
            let midnight = Calendar.current.date(byAdding: .day, value: 1,
                to: Calendar.current.startOfDay(for: now))!
            let begin = midnight.addingTimeInterval(-1800)
            let end = midnight.addingTimeInterval(1800)
            XCTAssertTrue(store.scheduleExercise(title: "夜跑", startsAt: begin, endsAt: end, at: now))
            XCTAssertEqual(store.document.days[HealthCalendar.key(begin)]?.exercise.first?.minutes, 60)
            XCTAssertTrue(store.summary(at: now).contains("本周运动：0 次"))
            XCTAssertTrue(store.summary(at: now).contains("未结束的运动安排：夜跑"))
            XCTAssertEqual(store.weekExerciseCount(at: end.addingTimeInterval(-1)), 0)
            let sameWeek = Calendar.current.dateInterval(of: .weekOfYear, for: end)!.contains(begin)
            XCTAssertEqual(store.weekExerciseCount(at: end), sameWeek ? 1 : 0)
            let range = try XCTUnwrap(store.document.days[HealthCalendar.key(begin)]?.exercise.first).timeRange(relativeTo: now)
            XCTAssertTrue(range.contains("今天 23:30–明天 00:30"))
        }
    }

    func testInvalidScheduleDoesNotChangeRecordsAndLegacyJSONStillLoads() throws {
        try isolated { store, url in
            let end = now.addingTimeInterval(3600)
            XCTAssertFalse(store.scheduleExercise(title: " ", startsAt: now, endsAt: end, at: now))
            XCTAssertFalse(store.scheduleExercise(title: "散步", startsAt: end, endsAt: now, at: now))
            XCTAssertFalse(store.scheduleExercise(title: "散步", startsAt: now,
                endsAt: now.addingTimeInterval(86401), at: now))
            XCTAssertFalse(store.scheduleExercise(id: "missing", title: "散步",
                startsAt: now, endsAt: end, at: now))
            XCTAssertTrue(store.exercise(title: "过去的散步", minutes: 20, at: now))
            // Simulate a real pre-scheduling file: no endsAt field anywhere.
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var days = try XCTUnwrap(object["days"] as? [String: [String: Any]])
            for key in days.keys {
                if var records = days[key]?["exercise"] as? [[String: Any]] {
                    for index in records.indices { records[index].removeValue(forKey: "endsAt") }
                    days[key]?["exercise"] = records
                }
            }
            object["days"] = days
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            let restored = HealthStore(url: url, now: now)
            XCTAssertNil(restored.error)
            XCTAssertEqual(restored.weekExerciseCount(at: now), 1)
            XCTAssertTrue(restored.pendingExercise(at: now).isEmpty)
            XCTAssertEqual(restored.document.days.values.flatMap(\.exercise).first?.title, "过去的散步")
        }
    }

    @MainActor
    func testScheduleEditAndCancelUseRealButtons() throws {
        _ = NSApplication.shared
        try isolated { store, _ in
            let begin = Date().addingTimeInterval(3600)
            XCTAssertTrue(store.scheduleExercise(title: "羽毛球", startsAt: begin,
                endsAt: begin.addingTimeInterval(3600), at: Date()))
            let id = try XCTUnwrap(store.pendingExercise().first?.id)
            let monitor = HealthDeskMonitor(store: store, lockScreen: { true })
            let controller = HealthWindowController(store: store, monitor: monitor, activates: false)
            controller.show()
            defer { controller.close() }
            settle()
            let window = try XCTUnwrap(controller.window)
            let root = try XCTUnwrap(window.contentView)
            let edit = try button(root, "health-exercise-edit-" + id)
            click(window, edit)
            settle()
            let popover = try XCTUnwrap(NSApp.windows.first {
                $0 !== window && $0.contentView.map { descendants($0).contains { ($0 as? DemandKeyboardActionView)?.keyboardIdentifier == "health-exercise-save" } } == true
            })
            let popoverRoot = try XCTUnwrap(popover.contentView)
            XCTAssertTrue(descendants(popoverRoot).contains { ($0 as? NSTextField)?.stringValue == "羽毛球" })
            if let folder = ProcessInfo.processInfo.environment["DBOARD_HEALTH_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try snapshot(popoverRoot, at: folder + "/exercise-form.png")
            }
            let save = try button(popoverRoot, "health-exercise-save")
            XCTAssertTrue(save.enabled)
            click(popover, save)
            settle()
            XCTAssertFalse(popover.isVisible, "Saving must close the editor")
            XCTAssertEqual(store.document.days.values.flatMap(\.exercise).map(\.id), [id])
            if let folder = ProcessInfo.processInfo.environment["DBOARD_HEALTH_SNAPSHOTS"] {
                for width in [CGFloat(820), 520] {
                    window.setContentSize(NSSize(width: width, height: 740)); settle()
                    try snapshot(root, at: folder + "/exercise-\(Int(width)).png")
                }
            }
            window.setContentSize(NSSize(width: 820, height: 740)); settle()
            click(window, try button(root, "health-exercise-delete-" + id))
            settle()
            XCTAssertTrue(store.pendingExercise().isEmpty)

            click(window, try button(root, "health-exercise-add")); settle()
            let addWindow = try XCTUnwrap(NSApp.windows.first {
                $0 !== window && $0.isVisible && $0.contentView.map { descendants($0).contains {
                    ($0 as? DemandKeyboardActionView)?.keyboardIdentifier == "health-exercise-save"
                } } == true
            })
            let addRoot = try XCTUnwrap(addWindow.contentView)
            let field = try XCTUnwrap(descendants(addRoot).compactMap { $0 as? NSTextField }.first {
                $0.isEditable && $0.placeholderString == "例如羽毛球、散步、力量训练"
            })
            XCTAssertTrue(addWindow.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("散步", replacementRange: editor.selectedRange()); settle()
            click(addWindow, try button(addRoot, "health-exercise-save")); settle()
            XCTAssertFalse(addWindow.isVisible)
            XCTAssertEqual(store.pendingExercise().map(\.title), ["散步"])
        }
    }

    private func isolated(_ action: (HealthStore, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HealthSchedule-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("health.json")
        try action(HealthStore(url: url, now: now), url)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func button(_ root: NSView, _ id: String) throws -> DemandKeyboardActionView {
        try XCTUnwrap(descendants(root).compactMap { $0 as? DemandKeyboardActionView }.first { $0.keyboardIdentifier == id })
    }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
    @MainActor private func click(_ window: NSWindow, _ target: NSView) {
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
    @MainActor private func snapshot(_ root: NSView, at path: String) throws {
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
