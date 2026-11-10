import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandHandoffSnapshotTests: XCTestCase {
    @MainActor
    func testRenderCollapsedAndExpandedHandoff() throws {
        guard let directory = ProcessInfo.processInfo.environment["DBOARD_UI_SNAPSHOTS"] else {
            throw XCTSkip("设置 DBOARD_UI_SNAPSHOTS 导出交接摘要检查图")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let vm = DBoardViewModel(loadCache: false)
        var item = DItem(id: "D014", project: "audi", title: "车点点锁券链路改造",
                         headerTitle: "车点点锁券链路改造", status: .inProgress, priority: .p1,
                         deadline: nil, branch: "audi:feature/vibe", startDate: nil, milestones: [])
        item.handoff = try JSONDecoder().decode(DemandHandoff.self, from: Data(#"""
        {"version":1,"sections":{"completed":"锁券接口和调试页已完成，验券阶段不再锁券。","pending":"待上游提供真实券码联调，目前无新开发事项。","decisions":"先重复查券，再锁券，再查照片。旧测试不能覆盖实时代码变更。","verification":"本地回归通过；真实券码与外部联调尚未验证。"},"resources":[{"topic":"锁券异常处理","source":"docs/锁券改造.md；record:12","when_to_read":"排查锁券失败或调整重试逻辑时"}],"references":[],"covered_count":12,"compacted_count":12,"updated_at":"2026-11-05T10:00:00+08:00","compacted_at":"2026-11-05T10:00:00+08:00","last_decision":{"decision":"compact","reason":"首次整理历史，保留关键规则与待办","checked_at":"2026-11-05T10:00:00+08:00"}}
        """#.utf8))
        item.handoffNotes = "退款边界尚未测到，请等我补测试数据。"

        for expanded in [false, true] {
        let view = DemandHandoffView(item: item, initiallyExpanded: expanded)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
            .environmentObject(vm)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
            .frame(width: 520)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(view, name: "demand-handoff-" + (expanded ? "expanded-" : "collapsed-") + name,
                       appearance: appearance, directory: directory)
        }
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