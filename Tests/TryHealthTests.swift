import XCTest
import AppKit
import Carbon.HIToolbox
@testable import DBoard

final class TryHealthTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAutomaticLockPausesButExplicitAwayLockResetsOnlyAfterReturn() {
        var clock = HealthClock(document: HealthDocument(checkpointAt: start.timeIntervalSince1970))
        clock.locked(at: start.addingTimeInterval(40 * 60), explicitAway: false)
        XCTAssertEqual(clock.document.continuousSeconds, 40 * 60)
        XCTAssertEqual(clock.document.mode, .locked)
        XCTAssertTrue(clock.document.days.values.flatMap(\.breaks).isEmpty)
        clock.unlocked(at: start.addingTimeInterval(60 * 60))
        clock.advance(to: start.addingTimeInterval(70 * 60))
        XCTAssertEqual(clock.document.continuousSeconds, 50 * 60, "Automatic lock must not fake a standing break")
        clock.locked(at: start.addingTimeInterval(70 * 60), explicitAway: true)
        clock.locked(at: start.addingTimeInterval(71 * 60), explicitAway: false)
        XCTAssertEqual(clock.document.mode, .away)
        XCTAssertEqual(clock.document.days.values.flatMap(\.breaks).count, 1)
        XCTAssertEqual(clock.document.days.values.flatMap(\.breaks).first?.deskSecondsBefore, 50 * 60)
        clock.unlocked(at: start.addingTimeInterval(75 * 60))
        clock.unlocked(at: start.addingTimeInterval(75 * 60))
        XCTAssertEqual(clock.document.continuousSeconds, 0)
        let away = clock.document.days.values.flatMap(\.breaks).first!
        XCTAssertEqual(away.endedAt! - away.startedAt, 5 * 60)
        clock.advance(to: start.addingTimeInterval(80 * 60))
        XCTAssertEqual(clock.document.continuousSeconds, 5 * 60)
        XCTAssertEqual(clock.document.days.values.map(\.deskSeconds).reduce(0, +), 55 * 60)
    }

    func testMidnightSplitsDeskTimeAndPausedTimeDoesNotLeakIntoNextDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14)))
        var clock = HealthClock(document: HealthDocument(checkpointAt: midnight.addingTimeInterval(-600).timeIntervalSince1970),
            calendar: calendar)
        clock.advance(to: midnight.addingTimeInterval(600))
        XCTAssertEqual(clock.document.days["2026-11-13"]?.deskSeconds, 600)
        XCTAssertEqual(clock.document.days["2026-11-14"]?.deskSeconds, 600)
        XCTAssertEqual(clock.document.continuousSeconds, 600)
        clock.locked(at: midnight.addingTimeInterval(600), explicitAway: false)
        clock.unlocked(at: midnight.addingTimeInterval(86400 + 600))
        XCTAssertEqual(clock.document.continuousSeconds, 0)
        clock.advance(to: midnight.addingTimeInterval(86400 + 900))
        XCTAssertEqual(clock.document.days["2026-11-15"]?.deskSeconds, 300)
    }

    func testUnlockedConsoleSessionWithoutLockKeyClearsAStaleAwayState() {
        XCTAssertEqual(HealthDeskMonitor.lockState([
            "kCGSSessionOnConsoleKey": true,
            "kCGSessionLoginDoneKey": true
        ]), false)
        XCTAssertEqual(HealthDeskMonitor.lockState([
            "CGSSessionScreenIsLocked": true,
            "kCGSSessionOnConsoleKey": true
        ]), true)
        XCTAssertNil(HealthDeskMonitor.lockState([
            "kCGSSessionOnConsoleKey": false,
            "kCGSessionLoginDoneKey": true
        ]))
        XCTAssertNil(HealthDeskMonitor.lockState([
            "kCGSSessionOnConsoleKey": true,
            "kCGSessionLoginDoneKey": false
        ]))
    }

    func testRestartDoesNotCountClosedAppTimeAsDeskOrAssumeAStandingDuration() {
        var clock = HealthClock(document: HealthDocument(checkpointAt: start.timeIntervalSince1970))
        clock.advance(to: start.addingTimeInterval(600))
        clock.restart(at: start.addingTimeInterval(3600), screenLocked: false)
        clock.advance(to: start.addingTimeInterval(3900))
        XCTAssertEqual(clock.document.continuousSeconds, 900)
        clock.locked(at: start.addingTimeInterval(3900), explicitAway: true)
        clock.advance(to: start.addingTimeInterval(4000))
        clock.restart(at: start.addingTimeInterval(5000), screenLocked: false)
        XCTAssertEqual(clock.document.continuousSeconds, 0)
        XCTAssertEqual(clock.document.mode, .desk)
        XCTAssertEqual(clock.document.days.values.flatMap(\.breaks).first?.endedAt, start.addingTimeInterval(4000).timeIntervalSince1970)
    }

    @MainActor
    func testLockRequestMustBeConfirmedAndExpiredOrFailedIntentCannotCreateBreak() throws {
        try isolated { store in
            let monitor = HealthDeskMonitor(store: store, lockScreen: { true })
            XCTAssertTrue(monitor.requestAwayLock(at: start))
            XCTAssertTrue(store.document.days.values.flatMap(\.breaks).isEmpty)
            monitor.screenDidLock(at: start.addingTimeInterval(1))
            XCTAssertEqual(store.document.mode, .away)
            monitor.screenDidUnlock(at: start.addingTimeInterval(121))
            XCTAssertEqual(store.document.continuousSeconds, 0)
            XCTAssertEqual(store.document.days.values.flatMap(\.breaks).count, 1)
            XCTAssertTrue(monitor.requestAwayLock(at: start.addingTimeInterval(200)))
            monitor.screenDidLock(at: start.addingTimeInterval(220))
            XCTAssertEqual(store.document.mode, .locked)
            XCTAssertEqual(store.document.days.values.flatMap(\.breaks).count, 1)
            monitor.screenDidUnlock(at: start.addingTimeInterval(230))
            let failed = HealthDeskMonitor(store: store, lockScreen: { false })
            XCTAssertFalse(failed.requestAwayLock(at: start.addingTimeInterval(240)))
            failed.screenDidLock(at: start.addingTimeInterval(241))
            XCTAssertEqual(store.document.mode, .locked)
            XCTAssertEqual(store.document.days.values.flatMap(\.breaks).count, 1)
        }
    }

    func testWaterExerciseSettingsPersistAndCorrectionsRemoveOnlyTheirOwnRecords() throws {
        try isolated { store in
            XCTAssertTrue(store.fillCup(at: start.addingTimeInterval(-2)))
            XCTAssertFalse(store.fillCup(at: start.addingTimeInterval(-1)))
            XCTAssertTrue(store.drinkCup(at: start))
            XCTAssertFalse(store.drinkCup(at: start.addingTimeInterval(1)))
            XCTAssertTrue(store.water(ml: 300, at: start.addingTimeInterval(2)))
            XCTAssertTrue(store.water(ml: 500, at: start.addingTimeInterval(60)))
            XCTAssertTrue(store.exercise(title: "散步", minutes: 20, at: start))
            XCTAssertTrue(store.exercise(title: "力量训练", minutes: 30, at: start.addingTimeInterval(60)))
            let key = HealthCalendar.key(start)
            let water = store.document.days[key]!.water.first!
            let exercise = store.document.days[key]!.exercise.first!
            XCTAssertTrue(store.removeWater(water.id, at: start.addingTimeInterval(120)))
            XCTAssertTrue(store.removeExercise(exercise.id, at: start.addingTimeInterval(120)))
            XCTAssertFalse(store.document.isCupFilled)
            XCTAssertEqual(store.document.days[key]?.water.map(\.ml), [300, 500])
            XCTAssertEqual(store.weekExerciseCount(at: start), 1)
            XCTAssertEqual(store.document.days[key]?.exercise.map(\.title), ["力量训练"])
            var settings = store.document.settings
            settings.cupML = 350; settings.waterGoalML = 1800; settings.weeklyExerciseGoal = 3
            XCTAssertTrue(store.settings(settings))
            let restored = HealthStore(url: storeURL(store))
            XCTAssertEqual(restored.document.settings, settings)
            XCTAssertEqual(restored.document.days[key], store.document.days[key])
        }
    }

    func testAwayShortcutIsConfigurableAndConflictsWithExistingShortcutsAreRejected() throws {
        let name = "DBoardHealthShortcut-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(prefs.binding(for: "awaylock")?.title, "⌃⌥L")
        XCTAssertTrue(ShortcutPreferences.order.contains("awaylock"))
        XCTAssertFalse(prefs.set(try XCTUnwrap(prefs.binding(for: "logs")), for: "awaylock"))
        XCTAssertTrue(prefs.set(GlobalShortcut(keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(controlKey | shiftKey), keyLabel: "L"), for: "awaylock"))
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).binding(for: "awaylock")?.title, "⌃⇧L")
    }

    @MainActor
    func testHealthQuickPageHasNoFakeEntryAndEnterOpensCenteredHealthWindow() throws {
        let storeFolder = FileManager.default.temporaryDirectory.appendingPathComponent("HealthQuick-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: storeFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeFolder) }
        let personal = TryStore(url: storeFolder.appendingPathComponent("try.json"), watching: false)
        let controller = TryQuickOpenWindowController(store: personal, activates: false)
        controller.show()
        defer { controller.close(); controller.healthWindow.close() }
        XCTAssertEqual(controller.model.scope, .health)
        XCTAssertNil(controller.model.selected)
        controller.model.moveScope(1)
        XCTAssertEqual(controller.model.scope, .digestion)
        controller.model.moveScope(1)
        XCTAssertEqual(controller.model.scope, .idea)
        controller.model.moveScope(-1)
        controller.model.moveScope(-1)
        XCTAssertEqual(controller.model.scope, .health)
        let panel = try XCTUnwrap(controller.window)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!
        XCTAssertNil(controller.handleKey(event))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(controller.window)
        XCTAssertNotNil(controller.healthWindow.window)
        XCTAssertTrue(personal.document.entries.isEmpty)
    }

    @MainActor
    func testHealthViewSnapshotsAndWaterUndoUseRealClickTargets() throws {
        _ = NSApplication.shared
        try isolated { store in
            let monitor = HealthDeskMonitor(store: store, lockScreen: { true })
            let controller = HealthWindowController(store: store, monitor: monitor, activates: false)
            controller.show()
            defer { controller.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let window = try XCTUnwrap(controller.window)
            let root = try XCTUnwrap(window.contentView)
            let fill = try XCTUnwrap(descendants(root).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "health-water-fill" })
            if let output = ProcessInfo.processInfo.environment["DBOARD_HEALTH_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output + "/before-click.png"))
            }
            click(window, fill.convert(NSPoint(x: fill.bounds.midX, y: fill.bounds.midY), to: nil))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertTrue(store.document.isCupFilled)
            XCTAssertTrue(store.document.days[HealthCalendar.key(Date())]?.water.isEmpty ?? true)
            let drink = try XCTUnwrap(descendants(root).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "health-water-drink" })
            click(window, drink.convert(NSPoint(x: drink.bounds.midX, y: drink.bounds.midY), to: nil))
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            XCTAssertFalse(store.document.isCupFilled)
            XCTAssertEqual(store.document.days[HealthCalendar.key(Date())]?.water.last?.ml, 350)
            let undo = try XCTUnwrap(descendants(root).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "health-water-undo-last" })
            click(window, undo.convert(NSPoint(x: undo.bounds.midX, y: undo.bounds.midY), to: nil))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertTrue(store.document.days[HealthCalendar.key(Date())]?.water.isEmpty == true)
            if let output = ProcessInfo.processInfo.environment["DBOARD_HEALTH_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                // Keep four-digit totals visible in the existing narrow/wide visual checks.
                XCTAssertTrue(store.water(ml: 1050, at: Date()))
                for width in [CGFloat(820), 520] {
                    window.setContentSize(NSSize(width: width, height: 740))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: output + "/health-\(Int(width)).png"))
                }
            }
        }
    }

    private var currentStoreURL: URL?
    private func storeURL(_ store: HealthStore) -> URL { currentStoreURL! }
    private func isolated(_ action: (HealthStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Health-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); currentStoreURL = nil }
        let url = directory.appendingPathComponent("health.json")
        currentStoreURL = url
        try action(HealthStore(url: url, now: start))
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func click(_ window: NSWindow, _ point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
}
