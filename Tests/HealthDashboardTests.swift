import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class HealthDashboardTests: XCTestCase {
    @MainActor
    func testEntryPeriodSwitchingDrillDownUndoAndReturnKeepOriginalHistory() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HealthDashboard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let old = calendar.date(byAdding: .day, value: -40, to: now)!
        let drink = HealthWater(at: now.addingTimeInterval(-60).timeIntervalSince1970, ml: 700)
        let exercise = HealthExercise(at: yesterday.timeIntervalSince1970, title: "散步", minutes: 30)
        let document = HealthDocument(days: [
            HealthCalendar.key(old): HealthDay(water: [HealthWater(at: old.timeIntervalSince1970, ml: 1800)]),
            HealthCalendar.key(yesterday): HealthDay(deskSeconds: 7200, longestDeskSeconds: 3600,
                water: [HealthWater(at: yesterday.timeIntervalSince1970, ml: 1400)], exercise: [exercise]),
            HealthCalendar.key(now): HealthDay(deskSeconds: 3600, longestDeskSeconds: 1800, water: [drink])
        ], mode: .paused, checkpointAt: now.timeIntervalSince1970)
        let url = folder.appendingPathComponent("health.json")
        try JSONEncoder().encode(document).write(to: url)
        let store = HealthStore(url: url, now: now)
        let controller = HealthWindowController(store: store,
            monitor: HealthDeskMonitor(store: store, lockScreen: { true }), activates: false)
        controller.show(); settle()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        try click("health-dashboard", window)
        XCTAssertTrue(has(window, "health-dashboard-week"))
        XCTAssertFalse(try button(window, "health-dashboard-next").enabled)
        try click("health-dashboard-previous", window)
        XCTAssertTrue(try button(window, "health-dashboard-next").enabled)
        try click("health-dashboard-current", window)
        for scope in ["day", "week", "month"] {
            try click("health-dashboard-" + scope, window)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance); settle()
                try snapshot(window, name: scope + (appearance == .aqua ? "-light" : "-dark"))
            }
        }
        window.setContentSize(NSSize(width: 520, height: 740)); settle()
        try snapshot(window, name: "month-narrow")
        window.setContentSize(NSSize(width: 820, height: 740)); settle()
        try click("health-dashboard-week", window)
        // Click today's area of the first plot through real mouse events.
        let root = try XCTUnwrap(window.contentView)
        let plot = try XCTUnwrap(descendants(root).compactMap { $0 as? HealthDashboardChartTapView }.first)
        let chartPoint = plot.convert(NSPoint(x: plot.bounds.width * 0.95, y: plot.bounds.midY), to: nil)
        sendClick(chartPoint, window); settle()
        XCTAssertTrue(has(window, "health-history-water-undo-" + drink.id), "A plot click opens that day's records.")
        try click("health-dashboard-back", window)
        try click("health-dashboard-days", window)
        try click("health-dashboard-open-" + HealthCalendar.key(now), window)
        XCTAssertTrue(has(window, "health-history-water-undo-" + drink.id))
        try snapshot(window, name: "day-detail")
        try click("health-history-water-undo-" + drink.id, window)
        XCTAssertTrue(store.document.days[HealthCalendar.key(now)]?.water.isEmpty == true)
        XCTAssertEqual(store.document.days[HealthCalendar.key(old)], document.days[HealthCalendar.key(old)])
        XCTAssertEqual(store.document.days[HealthCalendar.key(yesterday)]?.exercise, [exercise])
        try click("health-dashboard-back", window)
        XCTAssertTrue(has(window, "health-dashboard-week"))
        let statistics = HealthStatistics(document: store.document,
            period: HealthStatisticsPeriod(perspective: .month, anchor: now, now: Date()))
        XCTAssertEqual(statistics.waterDailyAverage, 1400)
        try click("health-dashboard-day", window)
        XCTAssertTrue(has(window, "health-dashboard-open-day"))
        try click("health-dashboard-back", window)
        XCTAssertTrue(has(window, "health-dashboard"))
        XCTAssertTrue(has(window, "health-all-history"))
        XCTAssertEqual(HealthStore(url: url, now: now).document.days[HealthCalendar.key(now)]?.water, [])
    }

    @MainActor
    func testEmptyDashboardAndMissingDateDetailRemainNavigable() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmptyDashboard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HealthStore(url: folder.appendingPathComponent("health.json"))
        let view = HealthDashboardView(value: store.document, now: Date(), store: store,
            editExercise: { _ in }, back: {}, initialPerspective: .day)
            .disclosureGroupStyle(TryDisclosureStyle()).demandFloatingCanvas()
            .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
        let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: 520, height: 740))
        let host = NSHostingController(rootView: view); host.sizingOptions = []
        window.setContent(host); window.setContentSize(NSSize(width: 520, height: 740)); window.orderBack(nil)
        defer { window.close() }
        settle()
        try click("health-dashboard-open-day", window)
        XCTAssertTrue(has(window, "health-dashboard-back"))
        try click("health-dashboard-back", window)
        XCTAssertTrue(has(window, "health-dashboard-open-day"))
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func has(_ window: NSWindow, _ id: String) -> Bool {
        descendants(window.contentView!).contains { ($0 as? DemandKeyboardActionView)?.keyboardIdentifier == id }
    }
    @MainActor private func button(_ window: NSWindow, _ id: String) throws -> DemandKeyboardActionView {
        try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
            .first { $0.keyboardIdentifier == id }, id)
    }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    @MainActor private func click(_ id: String, _ window: NSWindow) throws {
        let target = try button(window, id)
        var ancestor = target.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                document.scrollToVisible(target.convert(target.bounds, to: document).insetBy(dx: 0, dy: -8))
            }
            ancestor = view.superview
        }
        settle()
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        sendClick(point, window)
        settle()
    }
    @MainActor private func sendClick(_ point: NSPoint, _ window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
    @MainActor private func snapshot(_ window: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["DBOARD_DASHBOARD_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
    }
}
