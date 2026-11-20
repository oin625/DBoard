import XCTest
import AppKit
import SwiftUI
import WebKit
import Carbon.HIToolbox
@testable import DBoard

final class WebWorkspaceTests: XCTestCase {
    func testMergedShortcutDropsOldBindingsAndDefaultCardPersists() throws {
        let name = "WebWorkspace-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = GlobalShortcut(keyCode: 12, modifiers: UInt32(controlKey), keyLabel: "Q")
        defaults.set(try JSONEncoder().encode(["reqflow": legacy, "apprelease": legacy, "audihome": legacy]), forKey: "shortcuts.bindings")
        let shortcuts = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(shortcuts.binding(for: "webworkspace"), GlobalShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey), keyLabel: "A"))
        for id in ["reqflow", "apprelease", "audihome"] {
            XCTAssertNil(shortcuts.binding(for: id)); XCTAssertNil(shortcuts.overrides[id])
        }
        XCTAssertFalse(shortcuts.set(try XCTUnwrap(shortcuts.binding(for: "webworkspace")), for: "clipboard"))
        XCTAssertTrue(shortcuts.error?.contains("快速打开页面") == true)
        XCTAssertEqual(shortcuts.binding(for: "clipboard")?.title, "⌥V")
        let preferences = WebWorkspacePreferences(defaults: defaults)
        preferences.defaultPage = .audi
        XCTAssertEqual(WebWorkspacePreferences(defaults: defaults).defaultPage, .audi)
        XCTAssertEqual(WebWorkspacePage.audi.moved(1), .appRelease)
        XCTAssertEqual(WebWorkspacePage.appRelease.moved(-1), .audi)
    }
    func testBareControlOverridesMigrateWithoutChangingCustomCombinations() throws {
        for keyCode in [kVK_Control, kVK_RightControl] {
            let name = "WebWorkspaceMigration-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let bareControl = GlobalShortcut(keyCode: UInt32(keyCode), modifiers: 0, keyLabel: "Control")
            let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey), keyLabel: "C")
            defaults.set(try JSONEncoder().encode(["webworkspace": bareControl, "clipboard": custom]), forKey: "shortcuts.bindings")
            let shortcuts = ShortcutPreferences(defaults: defaults)
            XCTAssertEqual(shortcuts.binding(for: "webworkspace")?.title, "⌃A")
            XCTAssertEqual(shortcuts.binding(for: "clipboard"), custom)
            XCTAssertNil(shortcuts.overrides["webworkspace"])
            XCTAssertFalse(shortcuts.set(bareControl, for: "webworkspace"))
            XCTAssertEqual(shortcuts.binding(for: "webworkspace")?.title, "⌃A")
            let reloaded = ShortcutPreferences(defaults: defaults)
            XCTAssertNil(reloaded.overrides["webworkspace"])
            XCTAssertEqual(reloaded.binding(for: "clipboard"), custom)
            XCTAssertFalse(shortcuts.set(custom, for: "webworkspace"))
            shortcuts.setEnabled(false, for: "webworkspace")
            XCTAssertNil(ShortcutPreferences(defaults: defaults).binding(for: "webworkspace"))
        }
        let name = "WebWorkspaceCustom-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let custom = GlobalShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey), keyLabel: "B")
        defaults.set(try JSONEncoder().encode(["webworkspace": custom]), forKey: "shortcuts.bindings")
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).binding(for: "webworkspace"), custom)
    }

    func testRemovedDemandFlowDefaultMigratesToLogs() throws {
        let name = "WebWorkspaceLogs-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("reqflow", forKey: "webworkspace.defaultPage")
        let preferences = WebWorkspacePreferences(defaults: defaults)
        XCTAssertEqual(preferences.defaultPage, .logs)
        XCTAssertEqual(defaults.string(forKey: "webworkspace.defaultPage"), "logs")
        XCTAssertEqual(WebWorkspacePage.allCases, [.appRelease, .logs, .audi])
        XCTAssertEqual(WebWorkspacePage.logs.url.absoluteString, "https://audi.tmallyc.com/logs-hist")
        preferences.defaultPage = .audi
        XCTAssertEqual(WebWorkspacePreferences(defaults: defaults).defaultPage, .audi)
    }

    @MainActor
    func testActualCardsRespectDefaultArrowSelectionEnterAndEscape() throws {
        _ = NSApplication.shared
        let name = "WebWorkspaceUI-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = WebWorkspacePreferences(defaults: defaults)
        preferences.defaultPage = .logs
        var opened: [WebWorkspacePage] = []
        let controller = WebWorkspaceQuickOpenWindowController(preferences: preferences, activates: false) { opened.append($0) }
        controller.show(); settle()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(controller.model.selected, .logs)
        XCTAssertNil(controller.handleKey(key(124, window))); XCTAssertEqual(controller.model.selected, .audi)
        XCTAssertNil(controller.handleKey(key(123, window))); XCTAssertEqual(controller.model.selected, .logs)
        if let folder = ProcessInfo.processInfo.environment["DBOARD_WEB_WORKSPACE_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/cards.png"))
        }
        XCTAssertNil(controller.handleKey(key(36, window))); settle()
        XCTAssertEqual(opened, [.logs]); XCTAssertNil(controller.window)
        preferences.defaultPage = .audi
        controller.show(); settle()
        XCTAssertEqual(controller.model.selected, .audi)
        XCTAssertNil(controller.handleKey(key(53, try XCTUnwrap(controller.window)))); settle()
        XCTAssertNil(controller.window); XCTAssertEqual(opened.count, 1)
    }
    @MainActor
    func testNativePageArrowsPreserveTextInputAndSheets() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = text; window.orderBack(nil)
        defer { window.close() }
        window.makeFirstResponder(nil)
        XCTAssertTrue(WebWorkspaceRouter.canNavigate(window, event: key(124, window)))
        window.makeFirstResponder(text)
        XCTAssertFalse(WebWorkspaceRouter.canNavigate(window, event: key(124, window)))
        XCTAssertFalse(WebWorkspaceRouter.canNavigate(window, event: key(124, window, flags: .command)))
    }
    @MainActor
    func testWebPageArrowsSkipEditableElementsAndTrackSPARoutes() throws {
        _ = NSApplication.shared
        let receiver = ScriptReceiver()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(receiver, name: "dboardWorkspace")
        configuration.userContentController.addUserScript(WKUserScript(source: AppReleaseWindowController.workspaceScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: configuration)
        let ready = expectation(description: "Local fixture loaded")
        receiver.ready = ready; web.navigationDelegate = receiver
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
        defer { window.close(); configuration.userContentController.removeScriptMessageHandler(forName: "dboardWorkspace") }
        web.loadHTMLString("<html><body><input id='input'><div id='editable' contenteditable='true'>Note</div><div id='plain'>Content</div></body></html>",
            baseURL: URL(string: "https://audi.tmallyc.com/"))
        wait(for: [ready], timeout: 8)
        try evaluate(web, "document.querySelector('#plain').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight', bubbles:true, cancelable:true}))")
        settle()
        XCTAssertEqual(receiver.directions, [1])
        for target in ["input", "editable"] {
            try evaluate(web, "document.querySelector('#" + target + "').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft', bubbles:true, cancelable:true}))")
        }
        try evaluate(web, "document.querySelector('#plain').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft', ctrlKey:true, bubbles:true, cancelable:true}))")
        try evaluate(web, "document.querySelector('#plain').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft', isComposing:true, bubbles:true, cancelable:true}))")
        settle()
        XCTAssertEqual(receiver.directions, [1])
        try evaluate(web, "history.pushState({}, '', '/test-console?entry=cdd')")
        settle()
        XCTAssertEqual(receiver.urls.last, "https://audi.tmallyc.com/test-console?entry=cdd")
    }
    @MainActor private func evaluate(_ web: WKWebView, _ script: String) throws {
        let done = expectation(description: "Script evaluated")
        var failure: Error?
        web.evaluateJavaScript(script) { _, error in failure = error; done.fulfill() }
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
    }
    private final class ScriptReceiver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var ready: XCTestExpectation?
        var directions: [Int] = []
        var urls: [String] = []
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready?.fulfill(); ready = nil }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let data = message.body as? [String: Any] else { return }
            if let direction = data["direction"] as? Int { directions.append(direction) }
            if let url = data["url"] as? String { urls.append(url) }
        }
    }
    @MainActor private func key(_ code: UInt16, _ window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code)!
    }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
}
