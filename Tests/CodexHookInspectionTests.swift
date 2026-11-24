import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class CodexHookInspectionTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/DBoard-Hook-Fixture")

    private func hook(_ event: String, script: String = "report-event.js", enabled: Bool = true,
                      trusted: Bool = true, source: String = "user", managed: Bool = false) -> [String: Any] {
        ["key": home.path + "/hooks.json:" + event + ":" + script,
         "eventName": event, "command": "\"/opt/node\" \"" + home.path + "/luban/1.1.6/hooks/" + script + "\"",
         "source": source, "sourcePath": home.path + "/hooks.json", "isManaged": managed,
         "enabled": enabled, "trustStatus": trusted ? "trusted" : "needsApproval",
         "timeoutSec": 5, "async": false, "matcher": NSNull()]
    }
    private func decode(_ hooks: [[String: Any]], errors: [[String: Any]] = []) throws -> CodexHookControl.Inspection {
        let data = try JSONSerialization.data(withJSONObject: ["data": [["hooks": hooks, "errors": errors]]])
        return try CodexHookControl(home: home).decodeInspection(data)
    }

    func testOnlyUserLubanReportingHooksAreInspectedAndTrustIsNotSuccess() throws {
        let value = try decode([
            hook("preToolUse"), hook("postToolUse", enabled: false),
            hook("userPromptSubmit", trusted: false), hook("stop"),
            hook("sessionStart", script: "inject-prompt.js"),
            hook("userPromptSubmit", script: "check-update.js"),
            hook("preToolUse", source: "project"), hook("stop", managed: true)])
        XCTAssertEqual(value.status, .init(total: 4, enabled: 3, awaitingTrust: 1))
        XCTAssertEqual(Set(value.hooks.map(\.eventName)), Set(["preToolUse", "postToolUse", "userPromptSubmit", "stop"]))
        let prompt = try XCTUnwrap(value.hooks.first { $0.eventName == "userPromptSubmit" })
        XCTAssertEqual(prompt.title, "提交提示")
        XCTAssertEqual(prompt.version, "1.1.6")
        XCTAssertEqual(prompt.timeout, 5)
        XCTAssertFalse(prompt.asynchronous)
        XCTAssertFalse(prompt.trusted)
        XCTAssertEqual(prompt.scriptURL?.lastPathComponent, "report-event.js")
    }

    func testOutsideLubanPathAndConfigurationErrorsCannotBePresentedAsValidHooks() throws {
        var unrelated = hook("preToolUse")
        unrelated["command"] = "/opt/node /tmp/another/hooks/report-event.js"
        XCTAssertEqual(try decode([unrelated]).status.total, 0)
        XCTAssertThrowsError(try decode([], errors: [["path": home.path + "/hooks.json"]]))
    }

    @MainActor
    func testExpandedDetailsRenderWithoutRunningOrTogglingAnyHooks() throws {
        _ = NSApplication.shared
        let value = try decode(["preToolUse", "postToolUse", "userPromptSubmit", "stop"].map { hook($0) })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 640, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            CodexHooksSettingsView(inspection: value, expanded: true, loadsOnAppear: false)
                .background { ThemeCanvasBackground(palette: .nova) }
                .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared))
        window.orderBack(nil)
        defer { window.close() }
        let directory = ProcessInfo.processInfo.environment["DBOARD_HOOK_SNAPSHOTS"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            if let directory {
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory + "/hooks-" + name + ".png"))
            }
        }
    }
}
