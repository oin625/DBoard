import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandDebuggingSnapshotTests: XCTestCase {
    @MainActor
    func testRenderReadyDebugPageWithLocalLaunch() throws {
        guard let directory = ProcessInfo.processInfo.environment["DBOARD_UI_SNAPSHOTS"] else {
            throw XCTSkip("设置 DBOARD_UI_SNAPSHOTS 导出调试页按钮检查图")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let vm = DBoardViewModel(loadCache: false)
        var item = DItem(id: "D014", project: "audi", title: "车点点锁券链路改造",
                         headerTitle: "车点点锁券链路改造", status: .inProgress, priority: .p1,
                         deadline: nil, branch: "audi:feature/vibe", startDate: nil, milestones: [])
        let execution = DemandExecution(stage: .debugPageReady,
                                        scopeHash: String(repeating: "a", count: 64),
                                        debugPage: "/test-console/cdd-lock",
                                        debugURL: nil,
                                        updatedAt: "2026-11-03T16:00:00+08:00")
        item.execution = execution
        item.executionScope = execution.scopeHash

        let view = DemandDebuggingView(item: item)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
            .environmentObject(vm)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
            .frame(width: 520)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(view, name: "demand-debugging-ready-" + name,
                       appearance: appearance, directory: directory)
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, name: String, appearance: NSAppearance.Name,
                                 directory: String) throws {
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previousAppearance }
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: hosting.fittingSize.height)
        hosting.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        XCTAssertGreaterThan(png.count, 1000)
    }
}