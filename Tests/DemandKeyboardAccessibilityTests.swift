import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandKeyboardAccessibilityTests: XCTestCase {
    @MainActor
    func testNewWindowKindArrowsTabAndDraftRetention() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = DBoardViewModel(loadCache: false, newItemDraftStore: NewDemandDraftStore(url: url))
        var draft = DItemDraft(newID: "D883", priority: .p1)
        draft.name = "保留输入"
        draft.project = "ultra"
        vm.newItemDraft = draft
        let controller = NewDemandWindowController(activates: false)
        vm.newDemandWindowPresenter = { controller.show($0) }
        defer { controller.close() }
        vm.beginNewItemDraft()
        settle()
        let window = try XCTUnwrap(controller.window)
        let navigation = try XCTUnwrap(controller.keyboardNavigation)
        XCTAssertEqual((window.firstResponder as? DemandKeyboardActionView)?.keyboardIdentifier, "demand-kind-development")
        XCTAssertNil(navigation.handleKeyPress(key(124, window)))
        settle()
        XCTAssertTrue(vm.newItemDraft?.isIncident == true)
        XCTAssertTrue(vm.newItemDraft?.id.hasPrefix("P") == true)
        XCTAssertEqual(vm.newItemDraft?.name, "保留输入")
        XCTAssertEqual((window.firstResponder as? DemandKeyboardActionView)?.keyboardIdentifier, "demand-kind-incident")
        XCTAssertEqual(navigation.focusableControls().compactMap { $0 as? DemandKeyboardActionView }
            .filter { $0.keyboardIdentifier.hasPrefix("demand-kind-") }.count, 1)
        XCTAssertNil(navigation.handleKeyPress(key(123, window)))
        settle()
        XCTAssertFalse(vm.newItemDraft?.isIncident == true)
        XCTAssertNil(navigation.handleKeyPress(key(48, window)))
        settle()
        let name = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(name.isEditable)
        XCTAssertEqual(name.string, "保留输入")
        XCTAssertNotNil(navigation.handleKeyPress(key(124, window)), "An input keeps arrow-key cursor movement")
        XCTAssertFalse(vm.newItemDraft?.isIncident == true)
        name.insertText("继续填写", replacementRange: name.selectedRange())
        XCTAssertNil(navigation.handleKeyPress(key(48, window, .shift)))
        settle()
        XCTAssertEqual((window.firstResponder as? DemandKeyboardActionView)?.keyboardIdentifier, "demand-kind-development")
        controller.close()
        XCTAssertTrue(NewDemandDraftStore(url: url).draft?.name.contains("继续填写") == true)
    }

    @MainActor
    func testDetailTabEntersExpandedReleaseGroupsAndEditingWithoutWritingCache() throws {
        _ = NSApplication.shared
        let before = CacheFile.read()
        let vm = DBoardViewModel(loadCache: false)
        var item = DItem(id: "D883", project: "ultra", title: "测试详情的键盘导航", headerTitle: "键盘导航",
            status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
        item.releaseChecklist.items = [
            .init(id: "L001", text: "发布 ultra 服务", updatedBy: .ai,
                  details: "分支：feature/keyboard。上线前确认配置。", category: .release)]
        item.releaseChecklist.nextID = 2
        vm.items = [item]
        let controller = DemandDetailWindowController(activates: false)
        vm.demandWindowPresenter = { controller.show($0) }
        defer { controller.close() }
        vm.openDemandEditor(.inspect, item: item)
        settle()
        let window = try XCTUnwrap(controller.window)
        let navigation = try XCTUnwrap(controller.keyboardNavigation)
        try tabTo("release-section-D883", navigation, window)
        let section = try XCTUnwrap(window.firstResponder as? DemandKeyboardActionView)
        XCTAssertEqual(section.layer?.borderWidth, 2)
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        XCTAssertFalse(navigation.focusableControls().compactMap { $0 as? DemandKeyboardActionView }
            .contains { $0.keyboardIdentifier == "release-group-release-D883" })
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        try tabTo("release-group-release-D883", navigation, window)
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        XCTAssertFalse(navigation.focusableControls().compactMap { $0 as? DemandKeyboardActionView }
            .contains { $0.keyboardIdentifier == "release-check-D883-L001" })
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        try tabTo("release-check-D883-L001", navigation, window)
        try tabTo("release-details-D883-L001", navigation, window)
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        XCTAssertTrue(vm.releaseDrafts.isEmpty, "Viewing details does not start editing")
        try tabTo("release-edit-D883-L001", navigation, window)
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        XCTAssertEqual(vm.releaseDrafts["D883:L001"]?.text, "发布 ultra 服务")
        try tabTo("release-category-sql-D883:L001", navigation, window)
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        XCTAssertEqual(vm.releaseDrafts["D883:L001"]?.category, .sql)
        try tabTo("release-cancel-D883:L001", navigation, window)
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        XCTAssertTrue(vm.releaseDrafts.isEmpty)
        XCTAssertEqual(CacheFile.read(), before, "Keyboard inspection does not modify actual requirements")
    }

    @MainActor
    func testHeldTabWaitsForArrowsAndEachPressMovesOnce() throws {
        _ = NSApplication.shared
        let state = State()
        let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: 400, height: 300))
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Controls(state: state))
        let navigation = DemandWindowKeyboardNavigation(window: window)
        window.orderBack(nil)
        defer { window.close() }
        settle()
        XCTAssertTrue(navigation.focusControl(identifier: "section"))
        let section = try XCTUnwrap(window.firstResponder as? DemandKeyboardActionView)
        let tab = key(48, window)
        sendRaw(tab)
        XCTAssertTrue(window.firstResponder === section, "Holding Tab does not advance on initial key-down")
        let repeatingTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: tab.timestamp + 0.5, windowNumber: window.windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: true, keyCode: 48)!
        sendRaw(repeatingTab)
        XCTAssertTrue(window.firstResponder === section, "Tab auto-repeat never moves selection")
        sendRaw(key(125, window))
        XCTAssertEqual((window.firstResponder as? DemandKeyboardActionView)?.keyboardIdentifier, "last")
        sendRaw(key(126, window))
        XCTAssertTrue(window.firstResponder === section)
        let repeatingArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: tab.timestamp + 0.6, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: true, keyCode: 125)!
        sendRaw(repeatingArrow)
        XCTAssertTrue(window.firstResponder === section, "A held arrow does not cause uncontrolled repeats")
        sendRaw(DemandKeyboardTestEvents.release(tab, duration: 1))
        XCTAssertTrue(window.firstResponder === section, "Release after a chord does not take another step")
        XCTAssertNotNil(navigation.handleKey(key(125, window)), "Without Tab, arrows keep their original behavior")
        let heldWithoutArrows = key(48, window)
        XCTAssertNil(navigation.handleKey(heldWithoutArrows))
        XCTAssertNil(navigation.handleKey(DemandKeyboardTestEvents.release(heldWithoutArrows, duration: 0.8)))
        XCTAssertTrue(window.firstResponder === section, "A long hold alone never takes a step")
        XCTAssertNil(navigation.handleKeyPress(key(48, window)))
        XCTAssertEqual((window.firstResponder as? DemandKeyboardActionView)?.keyboardIdentifier, "last")
        XCTAssertNil(navigation.handleKeyPress(key(48, window, .shift)))
        XCTAssertTrue(window.firstResponder === section, "Short Tab and Shift+Tab still work")
    }

    @MainActor
    func testHeldTabNavigatesFromTextAndResetsWhenWindowLosesFocus() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = DBoardViewModel(loadCache: false, newItemDraftStore: NewDemandDraftStore(url: url))
        var draft = DItemDraft(newID: "D883", priority: .p1)
        draft.name = "原有名称"
        draft.desc = "原有描述"
        vm.newItemDraft = draft
        let controller = NewDemandWindowController(activates: false)
        vm.newDemandWindowPresenter = { controller.show($0) }
        defer { controller.close() }
        vm.beginNewItemDraft()
        settle()
        let window = try XCTUnwrap(controller.window)
        let navigation = try XCTUnwrap(controller.keyboardNavigation)
        XCTAssertNil(navigation.handleKeyPress(key(48, window)))
        settle()
        let title = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(title.string, draft.name)
        let tab = key(48, window)
        XCTAssertNil(navigation.handleKey(tab))
        XCTAssertTrue(window.firstResponder === title)
        XCTAssertNil(navigation.handleKey(key(125, window)))
        settle()
        XCTAssertEqual((window.firstResponder as? NSTextView)?.string, draft.desc)
        XCTAssertNil(navigation.handleKey(key(126, window)))
        settle()
        XCTAssertEqual((window.firstResponder as? NSTextView)?.string, draft.name)
        XCTAssertNil(navigation.handleKey(DemandKeyboardTestEvents.release(tab)))
        XCTAssertNotNil(navigation.handleKey(key(125, window)))
        XCTAssertFalse(title.string.contains("\t"))
        let interruptedTab = key(48, window)
        XCTAssertNil(navigation.handleKey(interruptedTab))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNotNil(navigation.handleKey(key(125, window)), "Returning to the window does not retain a phantom held Tab")
        XCTAssertNotNil(navigation.handleKey(DemandKeyboardTestEvents.release(interruptedTab)))
        title.setMarkedText("正在输入", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: title.selectedRange())
        XCTAssertNotNil(navigation.handleKey(key(48, window)), "Tab does not interrupt IME candidates")
        title.unmarkText()
    }

    @MainActor
    func testFocusRingExpiresWithoutLosingFocusAndTabRestartsItsTimer() throws {
        _ = NSApplication.shared
        let state = State()
        let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: 400, height: 300))
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Controls(state: state))
        let navigation = DemandWindowKeyboardNavigation(window: window)
        window.orderBack(nil)
        defer { window.close() }
        settle()
        XCTAssertTrue(navigation.focusControl(identifier: "section"))
        let section = try XCTUnwrap(window.firstResponder as? DemandKeyboardActionView)
        XCTAssertEqual(section.layer?.opacity, 1)
        settle(1.4)
        XCTAssertNil(navigation.handleKeyPress(key(48, window)))
        XCTAssertNil(navigation.handleKeyPress(key(48, window, .shift)))
        XCTAssertTrue(window.firstResponder === section)
        settle(1.3)
        XCTAssertEqual(section.layer?.opacity, 1, "Returning with Tab cancels the earlier expiry")
        settle(1.4)
        XCTAssertEqual(section.layer?.opacity, 0)
        XCTAssertTrue(window.firstResponder === section, "Hiding the border must keep the selected control")
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        XCTAssertTrue(state.expanded, "Enter still opens the module after its highlight has faded")
        XCTAssertEqual(section.layer?.opacity, 1)
        XCTAssertNil(navigation.handleKeyPress(key(48, window)))
        let checkbox = try XCTUnwrap(window.firstResponder as? DemandKeyboardActionView)
        XCTAssertEqual(checkbox.keyboardIdentifier, "check")
        XCTAssertEqual(checkbox.layer?.opacity, 1)
        XCTAssertEqual(section.layer?.opacity, 0)
        settle(DemandKeyboardActionView.focusRingIdleDelay + 0.2)
        XCTAssertEqual(checkbox.layer?.opacity, 0)
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        XCTAssertTrue(state.checked, "A faded checkbox stays in the navigation and can still be operated")
    }

    @MainActor
    func testPopupMenuAndNativeSegmentedSelectorAreKeyboardReachable() throws {
        _ = NSApplication.shared
        let state = State()
        let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: 400, height: 300))
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack {
            Menu("选择操作") {
                Button("测试菜单操作") { state.clicks += 1 }
            }.demandMenuStyle(.borderlessButton).demandKeyboardID("menu")
            Picker("分组", selection: Binding(get: { state.checked }, set: { state.checked = $0 })) {
                Text("需求").tag(false)
                Text("排查").tag(true)
            }.pickerStyle(.segmented)
        }.padding(24).demandFloatingCanvas().environmentObject(ThemeManager.shared))
        let navigation = DemandWindowKeyboardNavigation(window: window)
        window.orderBack(nil)
        defer { window.close() }
        settle()
        try tabTo("menu", navigation, window)
        let probe = MenuProbe()
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { note in
                guard let menu = note.object as? NSMenu else { return }
                probe.opened = true
                probe.menu = menu
                DispatchQueue.main.async {
                    guard let menu = probe.menu else { return }
                    if let index = menu.items.firstIndex(where: { $0.title == "测试菜单操作" }) {
                        menu.performActionForItem(at: index)
                    }
                    menu.cancelTracking()
                }
            }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertNil(navigation.handleKeyPress(key(36, window)))
        settle()
        XCTAssertTrue(probe.opened, "Enter opens the actual menu")
        XCTAssertEqual(state.clicks, 1)
        let selector = try XCTUnwrap(navigation.focusableControls().first { $0 is NSSegmentedControl })
        for _ in 0..<12 {
            if window.firstResponder === selector { break }
            XCTAssertNil(navigation.handleKeyPress(key(48, window)))
        }
        XCTAssertTrue(window.firstResponder === selector)
        XCTAssertNotNil(navigation.handleKeyPress(key(124, window)), "Native selectors keep arrow selection")
    }

    // Notification and deferred menu actions both run on the main thread.
    private final class MenuProbe: @unchecked Sendable {
        var opened = false
        var menu: NSMenu?
    }

    private final class State: ObservableObject {
        @Published var expanded = false
        @Published var checked = false
        @Published var clicks = 0
    }
    private struct Controls: View {
        @ObservedObject var state: State
        var body: some View {
            VStack {
                DisclosureGroup(isExpanded: $state.expanded) {
                    Toggle("完成事项", isOn: $state.checked).demandKeyboardID("check")
                    Button("子项") { state.clicks += 1 }.demandButtonStyle(.bordered).demandKeyboardID("child")
                } label: { Text("模块") }
                .demandKeyboardID("section")
                Button("禁用项") { state.clicks += 100 }.disabled(true).demandKeyboardID("disabled")
                Button("最后一项") { state.clicks += 1 }.demandButtonStyle(.plain).demandKeyboardID("last")
            }.padding(24).demandFloatingCanvas().environmentObject(ThemeManager.shared)
        }
    }

    @MainActor
    func testCheckboxEnterSpaceDisabledItemsAndActualEventMonitor() throws {
        _ = NSApplication.shared
        let state = State()
        let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: 400, height: 300))
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Controls(state: state))
        let navigation = DemandWindowKeyboardNavigation(window: window)
        window.orderBack(nil)
        defer { window.close() }
        settle()
        try tabTo("section", navigation, window)
        send(key(36, window))
        settle()
        XCTAssertTrue(state.expanded, "The real event monitor consumes Enter and invokes the selected module")
        try tabTo("check", navigation, window)
        send(key(36, window))
        settle()
        XCTAssertTrue(state.checked)
        send(key(49, window))
        settle()
        XCTAssertFalse(state.checked)
        try tabTo("child", navigation, window)
        send(key(36, window))
        settle()
        XCTAssertEqual(state.clicks, 1)
        XCTAssertFalse(navigation.focusableControls().compactMap { $0 as? DemandKeyboardActionView }
            .contains { $0.keyboardIdentifier == "disabled" })
        send(key(48, window))
        settle()
        XCTAssertEqual((window.firstResponder as? DemandKeyboardActionView)?.keyboardIdentifier, "last")
        send(key(48, window, .shift))
        settle()
        XCTAssertEqual((window.firstResponder as? DemandKeyboardActionView)?.keyboardIdentifier, "child")
        XCTAssertNil(navigation.handleKeyPress(key(48, window)))
        settle()
        let button = try XCTUnwrap(window.firstResponder as? DemandKeyboardActionView)
        XCTAssertEqual(button.layer?.borderWidth, 2)
        // Transparent keyboard targets preserve pointer interaction and Tab follows the clicked action.
        let child = try XCTUnwrap(navigation.focusableControls().compactMap { $0 as? DemandKeyboardActionView }
            .first { $0.keyboardIdentifier == "child" })
        let point = child.convert(NSPoint(x: child.bounds.midX, y: child.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            send(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        settle()
        XCTAssertEqual(state.clicks, 2)
        XCTAssertTrue(window.firstResponder === child)
        send(key(48, window))
        XCTAssertEqual((window.firstResponder as? DemandKeyboardActionView)?.keyboardIdentifier, "last")
    }

    @MainActor
    private func tabTo(_ id: String, _ navigation: DemandWindowKeyboardNavigation, _ window: NSWindow) throws {
        for _ in 0..<100 {
            if (window.firstResponder as? DemandKeyboardActionView)?.keyboardIdentifier == id { return }
            XCTAssertNil(navigation.handleKeyPress(key(48, window)))
            settle(0.025)
        }
        XCTFail("Tab never reached " + id + "; candidates: " + navigation.focusableControls()
            .map { ($0 as? DemandKeyboardActionView)?.keyboardIdentifier ?? String(describing: type(of: $0)) }
            .joined(separator: ", "))
        throw NSError(domain: "KeyboardNavigation", code: 1)
    }

    @MainActor
    private func key(_ code: UInt16, _ window: NSWindow, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: code == 48 ? "\t" : (code == 36 ? "\r" : code == 49 ? " " : ""),
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    @MainActor
    private func send(_ event: NSEvent) {
        sendRaw(event)
        if event.type == .keyDown && event.keyCode == 48 {
            sendRaw(DemandKeyboardTestEvents.release(event))
        }
    }

    @MainActor
    private func sendRaw(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: true)
        let mask: NSEvent.EventTypeMask = event.type == .keyDown ? .keyDown :
            event.type == .keyUp ? .keyUp : [.leftMouseDown, .leftMouseUp]
        if let next = NSApp.nextEvent(matching: mask, until: Date().addingTimeInterval(0.3),
            inMode: .default, dequeue: true) { NSApp.sendEvent(next) }
    }
    @MainActor
    private func settle(_ duration: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
}

enum DemandKeyboardTestEvents {
    static func release(_ event: NSEvent, duration: TimeInterval = 0.05) -> NSEvent {
        NSEvent.keyEvent(with: .keyUp, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp + duration, windowNumber: event.windowNumber, context: nil,
            characters: event.characters ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: false, keyCode: event.keyCode)!
    }
}

extension DemandWindowKeyboardNavigation {
    /// Existing navigation tests represent a complete short key press, including its release.
    @MainActor
    func handleKeyPress(_ event: NSEvent) -> NSEvent? {
        let result = handleKey(event)
        if event.type == .keyDown && event.keyCode == 48 && result == nil {
            return handleKey(DemandKeyboardTestEvents.release(event))
        }
        return result
    }
}
