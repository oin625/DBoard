import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandEditorResponsivenessTests: XCTestCase {
    private func item() -> DItem {
        DItem(id: "D016", project: "ultra", title: "", headerTitle: "追加变更响应验证",
            status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
    }

    @MainActor
    func testSlowRecordReadDoesNotBlockShowingOrTypingAndPreservesDraft() throws {
        _ = NSApplication.shared
        let initial = item()
        var current = initial
        current.changes = [DemandChange(id: "C001", createdAt: Date(), intent: "另一处新增的变更")]
        let fresh = current
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        defer { finish.signal() }
        let store = DemandChangeDraftStore(url: nil)
        let vm = DBoardViewModel(loadCache: false, changeDraftStore: store)
        let editorView = DemandChangesEditor(item: initial, draftStore: store, cancel: {}, readRecord: { id in
            XCTAssertEqual(id, initial.id)
            XCTAssertFalse(Thread.isMainThread, "Locked cache reads must run off the UI thread")
            entered.signal()
            _ = finish.wait(timeout: .now() + 5)
            return fresh
        }).environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: editorView); host.sizingOptions = []
        let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: 640, height: 680))
        window.isReleasedWhenClosed = false
        window.setContent(host); window.orderBack(nil)
        defer { window.close() }
        settle(0.15)
        XCTAssertEqual(entered.wait(timeout: .now() + 0.05), .success)
        let root = try XCTUnwrap(window.contentView)
        let input = try XCTUnwrap(descendants(root).compactMap { $0 as? DemandSpellTextView }.first)
        input.insertText("页面读取中也能填写变更", replacementRange: input.selectedRange())
        settle(0.05)
        XCTAssertEqual(store.drafts[initial.id]?.intent, "页面读取中也能填写变更")
        finish.signal()
        settle(0.2)
        XCTAssertEqual(input.string, "页面读取中也能填写变更", "A fresh record must not replace unsaved input")
        XCTAssertEqual(store.drafts[initial.id]?.intent, input.string)
    }

    @MainActor
    func testTabDefaultsOffAndMouseClickWorksWithoutFocusHighlight() throws {
        _ = NSApplication.shared
        let name = "DBoardTabDefaults-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = WorkspacePreferences(defaults: defaults)
        XCTAssertFalse(prefs.tabNavigationEnabled)
        prefs.tabNavigationEnabled = true
        XCTAssertTrue(WorkspacePreferences(defaults: defaults).tabNavigationEnabled)
        prefs.tabNavigationEnabled = false
        XCTAssertFalse(WorkspacePreferences(defaults: defaults).tabNavigationEnabled)

        let old = WorkspacePreferences.shared.tabNavigationEnabled
        WorkspacePreferences.shared.tabNavigationEnabled = false
        defer { WorkspacePreferences.shared.tabNavigationEnabled = old }
        let state = ButtonState()
        let window = makeWindow(state)
        let navigation = DemandWindowKeyboardNavigation(window: window)
        defer { window.close() }
        settle(0.15)
        let root = try XCTUnwrap(window.contentView)
        let first = try action(root, "first")
        XCTAssertFalse(first.tabNavigationEnabled)
        XCTAssertFalse(first.acceptsFirstResponder)
        XCTAssertTrue(navigation.focusableControls().isEmpty)
        let responder = window.firstResponder
        XCTAssertNil(navigation.handleKey(key(48, window)))
        XCTAssertTrue(window.firstResponder === responder)
        click(window, first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil))
        settle(0.1)
        XCTAssertEqual(state.clicks, 1)
        XCTAssertEqual(first.layer?.borderWidth ?? 0, 0)
    }

    @MainActor
    func testToggleAffectsOpenWindowImmediatelyAndEscapeStillWorksWhenOff() throws {
        _ = NSApplication.shared
        let old = WorkspacePreferences.shared.tabNavigationEnabled
        WorkspacePreferences.shared.tabNavigationEnabled = false
        defer { WorkspacePreferences.shared.tabNavigationEnabled = old }
        let state = ButtonState()
        let window = makeWindow(state)
        var escaped = false
        let navigation = DemandWindowKeyboardNavigation(window: window, onEscape: { escaped = true })
        defer { window.close() }
        settle(0.15)
        WorkspacePreferences.shared.tabNavigationEnabled = true
        settle(0.15)
        XCTAssertTrue(navigation.focusControl(identifier: "first"))
        let first = try action(try XCTUnwrap(window.contentView), "first")
        XCTAssertEqual(first.layer?.borderWidth, 2)
        WorkspacePreferences.shared.tabNavigationEnabled = false
        settle(0.15)
        XCTAssertFalse(window.firstResponder is DemandKeyboardActionView)
        XCTAssertEqual(first.layer?.borderWidth ?? 0, 0)
        XCTAssertTrue(navigation.focusableControls().isEmpty)
        XCTAssertNil(navigation.handleKey(key(53, window)))
        XCTAssertTrue(escaped)
        WorkspacePreferences.shared.tabNavigationEnabled = true
        settle(0.15)
        XCTAssertTrue(navigation.focusControl(identifier: "first"))
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        XCTAssertEqual(state.clicks, 1)
    }

    func testLocalD016RecordReadProfile() throws {
        guard ProcessInfo.processInfo.environment["DBOARD_PROFILE_DEMAND"] == "D016" else {
            throw XCTSkip("Local read-only profiling is explicitly opt-in")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let record = try DItemStore.currentRecord(id: "D016")
        let readTime = ProcessInfo.processInfo.systemUptime - start
        let checking = ProcessInfo.processInfo.systemUptime
        _ = DemandCodeReviews.checked(record)
        let checkTime = ProcessInfo.processInfo.systemUptime - checking
        let profile = "D016 record-read: \(String(format: "%.3f", readTime))s; former synchronous code-check: \(String(format: "%.3f", checkTime))s"
        print(profile)
        try profile.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("dboard-D016-open-profile.txt"),
                          atomically: true, encoding: .utf8)
        XCTAssertEqual(record.id, "D016")
    }

    private final class ButtonState: ObservableObject {
        @Published var clicks = 0
    }
    private struct Buttons: View {
        @ObservedObject var state: ButtonState
        var body: some View {
            VStack(spacing: 12) {
                Button("点击") { state.clicks += 1 }.demandButtonStyle(TryControlStyle()).demandKeyboardID("first")
                Button("第二项") { state.clicks += 10 }.demandButtonStyle(TryControlStyle()).demandKeyboardID("second")
            }.padding(24).demandFloatingCanvas().environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
        }
    }
    @MainActor private func makeWindow(_ state: ButtonState) -> DemandWorkspaceWindow {
        let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: 400, height: 300))
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Buttons(state: state)); window.orderBack(nil)
        return window
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func action(_ root: NSView, _ id: String) throws -> DemandKeyboardActionView {
        try XCTUnwrap(descendants(root).compactMap { $0 as? DemandKeyboardActionView }.first { $0.keyboardIdentifier == id })
    }
    @MainActor private func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    @MainActor private func key(_ code: UInt16, _ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: code == 48 ? "\t" : code == 36 ? "\r" : "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code)!
    }
    @MainActor private func click(_ window: NSWindow, _ point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
    }
}
