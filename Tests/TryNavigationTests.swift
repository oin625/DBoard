import XCTest
import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox
@testable import DBoard

final class TryNavigationTests: XCTestCase {
    func testSwipeRequiresHorizontalIntentAndOnlyMovesOncePerGesture() {
        var tracker = WorkspaceSwipeTracker()
        XCTAssertNil(tracker.update(dx: -20, dy: 2))
        XCTAssertEqual(tracker.update(dx: -36, dy: 3), 1)
        XCTAssertNil(tracker.update(dx: -100, dy: 0))
        tracker.reset()
        XCTAssertNil(tracker.update(dx: 2, dy: 24))
        XCTAssertNil(tracker.update(dx: -80, dy: 0), "A vertical scroll stays vertical for the entire gesture")
        tracker.reset()
        XCTAssertEqual(tracker.update(dx: 60, dy: 1), -1)
    }

    func testCommandZeroIsConfigurableAndCannotConflictWithCommandP() throws {
        let suite = "DBoardTryKeys-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(prefs.binding(for: "tryquickopen")?.title, "⌘0")
        XCTAssertTrue(ShortcutPreferences.order.contains("tryquickopen"))
        XCTAssertFalse(prefs.set(try XCTUnwrap(prefs.binding(for: "quickopen")), for: "tryquickopen"))
        XCTAssertTrue(prefs.set(GlobalShortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey), keyLabel: "9"), for: "tryquickopen"))
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).binding(for: "tryquickopen")?.title, "⌘9")
    }

    @MainActor
    func testHomeRetainsLearningEditorAndHasNoTabNavigationNodes() throws {
        UserDefaults.standard.register(defaults: ["reply.enabled": false])
        _ = NSApplication.shared
        try isolated { store in
            let id = try XCTUnwrap(store.create(.digestion))
            store.edit(id, field: "title", value: "学习焦点")
            store.edit(id, field: "body", value: "正在理解的正文")
            XCTAssertTrue(store.flush())
            store.selectedID = id
            let vm = DBoardViewModel(loadCache: false)
            vm.space = .personal
            let window = host(DBoardRootView(personalStore: store, popoverMode: true)
                .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                size: NSSize(width: 820, height: 780))
            defer { window.close() }
            settle()
            let root = try XCTUnwrap(window.contentView)
            XCTAssertTrue(descendants(root).compactMap { $0 as? DemandKeyboardActionView }.isEmpty)
            XCTAssertTrue(descendants(root).compactMap { $0 as? TryKeyboardHostView }.isEmpty)
            let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? TryNoteTextView }.first)
            var workInvalidations = 0
            let token = vm.objectWillChange.sink { workInvalidations += 1 }
            defer { token.cancel() }
            for _ in 0..<5 {
                vm.space = .main
                settle(0.08)
                vm.space = .personal
                settle(0.08)
            }
            XCTAssertEqual(workInvalidations, 0, "Switching spaces must not redraw every formal demand")
            XCTAssertTrue(descendants(root).contains { $0 === editor }, "Switching retains the existing native editor")
            XCTAssertEqual(store.entry(id)?.body, "正在理解的正文")
            XCTAssertNil(DBoardRootView.handleKey(key(48, window), vm: vm, personalStore: store))
            window.makeFirstResponder(nil)
            XCTAssertNil(DBoardRootView.handleKey(key(123, window), vm: vm, personalStore: store))
            XCTAssertEqual(vm.space, .main)
            XCTAssertNil(DBoardRootView.handleKey(key(124, window), vm: vm, personalStore: store))
            XCTAssertEqual(vm.space, .personal)
            window.makeFirstResponder(editor)
            XCTAssertNotNil(DBoardRootView.handleKey(key(123, window), vm: vm, personalStore: store))
        }
    }

    @MainActor
    func testQuickCardArrowsCopyAndEnterOpenIndependentCenteredDetailWithTab() throws {
        let previousTabNavigation = WorkspacePreferences.shared.tabNavigationEnabled
        WorkspacePreferences.shared.tabNavigationEnabled = true
        defer { WorkspacePreferences.shared.tabNavigationEnabled = previousTabNavigation }
        _ = NSApplication.shared
        try isolated { store in
            let idea = try XCTUnwrap(store.create(.idea))
            store.edit(idea, field: "title", value: "一个念头")
            let task = try XCTUnwrap(store.create(.task))
            store.edit(task, field: "title", value: "要做的事情")
            let learning = try XCTUnwrap(store.create(.digestion))
            store.edit(learning, field: "title", value: "需要理解的资料")
            XCTAssertTrue(store.flush())
            store.selectedID = task
            var copied: String?
            let controller = TryQuickOpenWindowController(store: store, activates: false, copyHandoff: { copied = $0; return true })
            controller.show()
            defer { controller.close(); controller.details.close() }
            settle()
            let panel = try XCTUnwrap(controller.window)
            XCTAssertEqual(controller.model.scope, .digestion)
            XCTAssertTrue(descendants(try XCTUnwrap(panel.contentView)).compactMap { $0 as? DemandKeyboardActionView }.isEmpty)
            XCTAssertNil(controller.handleKey(key(123, panel)))
            XCTAssertEqual(controller.model.scope, .digestion)
            XCTAssertNil(controller.handleKey(key(124, panel)))
            XCTAssertEqual(controller.model.scope, .idea)
            XCTAssertNil(controller.handleKey(key(8, panel, .command, "c")))
            XCTAssertTrue(copied?.contains("context '" + idea + "'") == true)
            XCTAssertNil(controller.handleKey(key(36, panel)))
            settle()
            XCTAssertNil(controller.window)
            let detail = try XCTUnwrap(controller.details.window)
            XCTAssertEqual(controller.details.session?.id, idea)
            XCTAssertEqual(store.selectedID, task, "Quick-open details do not move the homepage selection")
            let root = try XCTUnwrap(detail.contentView)
            XCTAssertFalse(descendants(root).compactMap { $0 as? DemandKeyboardActionView }.isEmpty)
            let bridge = try XCTUnwrap(descendants(root).compactMap { $0 as? TryKeyboardHostView }.first)
            let navigation = try XCTUnwrap(bridge.navigation)
            detail.makeFirstResponder(nil)
            XCTAssertNil(navigation.handleKeyPress(key(48, detail)))
            XCTAssertNotNil(detail.firstResponder as? DemandKeyboardActionView)
            let screen = try XCTUnwrap(NSScreen.main).visibleFrame
            controller.details.show(learning, centerIn: screen)
            settle()
            XCTAssertEqual(detail.frame.midX, screen.midX, accuracy: 1)
            XCTAssertEqual(detail.frame.midY, screen.midY, accuracy: 1)
            XCTAssertEqual(store.selectedID, task)
        }
    }

    @MainActor
    func testPlusRecordsThoughtAndLinkedLearningAppearsInLearningCards() throws {
        _ = NSApplication.shared
        try isolated { store in
            let original = try XCTUnwrap(store.create(.idea))
            store.edit(original, field: "body", value: "原来的想法")
            XCTAssertTrue(store.flush())
            let controller = TryQuickOpenWindowController(store: store, activates: false)
            controller.show()
            defer { controller.close(); controller.details.close() }
            settle()
            let panel = try XCTUnwrap(controller.window)
            XCTAssertNil(controller.handleKey(key(124, panel)))
            XCTAssertEqual(controller.model.scope, .idea)
            XCTAssertEqual(controller.model.selectedID, original)
            XCTAssertNil(controller.handleKey(key(24, panel, .shift, "+")))
            settle()
            XCTAssertEqual(controller.capture.kind, .idea)
            XCTAssertEqual(store.document.entries.count, 1, "Opening + must not create an empty record")
            let writer = try XCTUnwrap(controller.capture.window)
            let editor = try XCTUnwrap(descendants(try XCTUnwrap(writer.contentView)).compactMap { $0 as? TryNoteTextView }.first)
            writer.makeFirstResponder(editor)
            editor.insertText("一个新的想法", replacementRange: editor.selectedRange())
            settle()
            let save = try XCTUnwrap(descendants(try XCTUnwrap(writer.contentView)).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "try-capture-save" })
            let point = save.convert(NSPoint(x: save.bounds.midX, y: save.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                writer.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: writer.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
            settle()
            XCTAssertNil(controller.capture.window)
            let id = try XCTUnwrap(store.document.entries.first { $0.id != original }?.id)
            XCTAssertEqual(store.entry(id)?.kind, .idea)
            XCTAssertEqual(store.selectedID, original)
            controller.show()
            settle()
            XCTAssertEqual(controller.model.scope, .digestion)
            controller.model.moveScope(1)
            XCTAssertEqual(controller.model.selectedID, id)
            let learning = try XCTUnwrap(store.beginLearning(from: id))
            settle()
            XCTAssertEqual(store.entry(id)?.kind, .idea)
            XCTAssertEqual(store.entry(learning)?.relatedIDs, [id])
            controller.model.moveScope(-1)
            XCTAssertEqual(controller.model.selectedID, learning)
        }
    }

    @MainActor
    func testQuickAndDetailsRenderAcrossLightDarkAndSmallHomeWidth() throws {
        UserDefaults.standard.register(defaults: ["reply.enabled": false])
        _ = NSApplication.shared
        try isolated { store in
            let id = try XCTUnwrap(store.create(.digestion))
            store.edit(id, field: "title", value: "把次 Try 做得更顺手")
            store.edit(id, field: "body", value: "首页轻量切换，快捷卡片随时接住自己的想法。")
            store.edit(id, field: "progress", value: "正在检查左右滑动与快捷键")
            XCTAssertTrue(store.flush())
            let controller = TryQuickOpenWindowController(store: store, activates: false)
            controller.show()
            defer { controller.close(); controller.details.close() }
            settle()
            let output = ProcessInfo.processInfo.environment["DBOARD_TRY_NAV_SNAPSHOTS"]
            if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
            let panel = try XCTUnwrap(controller.window)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                panel.appearance = NSAppearance(named: appearance)
                settle()
                try snapshot(panel, output, appearance == .aqua ? "quick-light" : "quick-dark")
            }
            controller.open(id)
            settle()
            let detail = try XCTUnwrap(controller.details.window)
            try snapshot(detail, output, "detail")
            let vm = DBoardViewModel(loadCache: false)
            vm.space = .personal
            let home = host(DBoardRootView(personalStore: store, popoverMode: true)
                .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
                size: NSSize(width: 520, height: 740))
            defer { home.close() }
            settle()
            try snapshot(home, output, "home-narrow")
        }
    }

    private func isolated(_ action: (TryStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TryNavigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try action(TryStore(url: directory.appendingPathComponent("personal.json"), watching: false))
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func settle(_ seconds: TimeInterval = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    @MainActor private func key(_ code: UInt16, _ window: NSWindow, _ flags: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
    }
    @MainActor private func host<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        return window
    }
    @MainActor private func snapshot(_ window: NSWindow, _ output: String?, _ name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 2000)
        if let output { try data.write(to: URL(fileURLWithPath: output + "/" + name + ".png")) }
    }
}
