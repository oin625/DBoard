import XCTest
import AppKit
@testable import DBoard

final class WindowPinTests: XCTestCase {
    @MainActor
    func testPagesRememberIndependentPinStates() throws {
        let app = NSApplication.shared
        let controller = AppReleaseWindowController()
        controller.showLogs()
        let window = try XCTUnwrap(app.windows.first { $0.title == "Audi 日志" })
        defer { window.orderOut(nil) }
        let button = try XCTUnwrap(window.contentView?.subviews
            .flatMap(\.subviews).compactMap { $0 as? NSButton }.first)
        XCTAssertTrue(window.hidesOnDeactivate)

        button.performClick(nil)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(button.toolTip, "取消置顶")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        XCTAssertTrue(window.isVisible)

        controller.toggle()
        XCTAssertEqual(window.title, "应用发布台 · audi")
        XCTAssertTrue(window.hidesOnDeactivate)
        XCTAssertEqual(button.toolTip, "置顶窗口（切换应用时保持显示）")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        XCTAssertFalse(window.isVisible)
        controller.show()
        button.performClick(nil)
        XCTAssertFalse(window.hidesOnDeactivate)
        controller.toggleHome()
        XCTAssertEqual(window.title, "Audi 首页")
        XCTAssertTrue(window.hidesOnDeactivate)
        button.performClick(nil)
        XCTAssertFalse(window.hidesOnDeactivate)
        controller.toggleHome()
        XCTAssertFalse(window.isVisible)
        controller.toggleHome()
        XCTAssertFalse(window.hidesOnDeactivate)

        controller.showLogs()
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertEqual(button.toolTip, "取消置顶")
        button.performClick(nil)
        XCTAssertTrue(window.hidesOnDeactivate)
        XCTAssertEqual(button.toolTip, "置顶窗口（切换应用时保持显示）")
        controller.show()
        XCTAssertFalse(window.hidesOnDeactivate)
        controller.toggleHome()
        XCTAssertFalse(window.hidesOnDeactivate)
        controller.showLogs()
        XCTAssertTrue(window.hidesOnDeactivate)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        XCTAssertFalse(window.isVisible)
    }
}
