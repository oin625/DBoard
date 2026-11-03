import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandCardInteractionTests: XCTestCase {
    @MainActor
    func testHeaderClickExpandsAndCollapsesAcrossTitleAndEmptySpace() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        let item = DItem(id: "D001", project: "工作台", title: "测试详情",
            headerTitle: "点击展开需求", status: .inProgress, priority: .p1,
            deadline: nil, branch: nil, startDate: nil, milestones: [])
        vm.items = [item]
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 520, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:
            ItemCardView(item: item)
                .demandEditorPresentation()
                .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
                .frame(width: 520, height: 500, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)))
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()

        // Title, space between the title and chevron, and the chevron must all toggle.
        for x: CGFloat in [100, 350, 485] {
            vm.expandedIDs = []
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            click(window: window, point: NSPoint(x: x, y: 478))
            XCTAssertTrue(vm.expandedIDs.contains(item.id), "Header click at x=\(x) did not expand")
            click(window: window, point: NSPoint(x: x, y: 478))
            XCTAssertFalse(vm.expandedIDs.contains(item.id), "Header click at x=\(x) did not collapse")
        }
        click(window: window, point: NSPoint(x: 472, y: 453))
        XCTAssertNotNil(window.attachedSheet, "Prompt button should open its editor")
        XCTAssertFalse(vm.expandedIDs.contains(item.id), "Prompt button must not toggle expansion")
        XCTAssertEqual(vm.editingFormCount, 1)
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
    }

    @MainActor
    private func click(window: NSWindow, point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
}
