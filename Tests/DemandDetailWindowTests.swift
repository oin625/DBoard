import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandDetailWindowTests: XCTestCase {
    private func item(_ id: String, title: String) -> DItem {
        DItem(id: id, project: "ultra", title: "单条需求说明", headerTitle: title, status: .pending,
              priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
    }

    @MainActor
    func testMatrixClickOpensOnlyDemandWindowWithoutPresentingHomeSheetOrExpandingHomeCards() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        let selected = item("D881", title: "只显示这条需求")
        vm.items = [selected, item("D882", title: "不应出现在详情窗口的另一条需求")]
        let controller = DemandDetailWindowController(activates: false)
        vm.demandWindowPresenter = { controller.show($0) }
        let home = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 560, height: 520),
                            styleMask: [.titled], backing: .buffered, defer: false)
        home.isReleasedWhenClosed = false
        home.contentView = NSHostingView(rootView: DemandMatrixCard(item: selected)
            .demandEditorPresentation().environmentObject(vm).environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared).padding(12)
            .frame(width: 560, height: 520, alignment: .topLeading))
        home.orderBack(nil)
        settle()
        defer { controller.close(); home.close() }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            home.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 520 - 56),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: home.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        settle()
        let detail = try XCTUnwrap(controller.window)
        XCTAssertTrue(detail.isVisible)
        XCTAssertFalse(detail === home)
        XCTAssertFalse(detail.styleMask.contains(.titled))
        XCTAssertNil(detail.standardWindowButton(.closeButton))
        XCTAssertEqual(detail.contentRect(forFrameRect: detail.frame), detail.frame)
        XCTAssertFalse(detail.hasShadow)
        XCTAssertFalse(detail.hidesOnDeactivate)
        XCTAssertTrue(detail.canBecomeKey)
        XCTAssertNil(home.attachedSheet)
        XCTAssertNil(detail.attachedSheet)
        XCTAssertEqual(vm.demandEditor?.item.id, selected.id)
        XCTAssertTrue(vm.demandEditorInWindow)
        XCTAssertTrue(vm.expandedIDs.isEmpty, "Detail expansion must not change the home list")
        try snapshot(detail, name: "demand-only")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: detail.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        XCTAssertNil(try XCTUnwrap(controller.keyboardNavigation).handleKeyPress(escape))
        settle()
        XCTAssertNil(controller.window)
        XCTAssertNil(vm.demandEditor)
        XCTAssertFalse(vm.demandEditorInWindow)
        XCTAssertTrue(home.isVisible)
    }

    @MainActor
    func testTopDragMovesWindowAndLaterLayoutDoesNotSnapItBack() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        let selected = item("D883", title: "拖动独立需求窗口")
        vm.items = [selected]
        let controller = DemandDetailWindowController(activates: false)
        vm.demandWindowPresenter = { controller.show($0) }
        defer { controller.close() }
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first).visibleFrame
        vm.openDemandEditor(.inspect, item: selected, centerIn: screen)
        settle()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        settle()
        let root = try XCTUnwrap(window.contentView)
        let drag = try XCTUnwrap(descendants(root).compactMap { $0 as? DemandWindowDragView }.first)
        let local = drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: nil)
        let rootPoint = root.superview?.convert(local, from: nil) ?? local
        XCTAssertTrue(root.hitTest(rootPoint) === drag, "The top padding must accept native window dragging")
        let startFrame = window.frame
        @MainActor func mouse(_ type: NSEvent.EventType, at location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let down = mouse(.leftMouseDown, at: local)
        let moved = NSPoint(x: local.x + 100, y: local.y - 60)
        let motion = mouse(.leftMouseDragged, at: moved)
        let up = mouse(.leftMouseUp, at: moved)
        NSApp.postEvent(down, atStart: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { NSApp.postEvent(motion, atStart: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { NSApp.postEvent(up, atStart: false) }
        for _ in 0..<3 {
            let event = try XCTUnwrap(NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                until: Date().addingTimeInterval(1), inMode: .default, dequeue: true))
            NSApp.sendEvent(event)
        }
        settle()
        let frame = window.frame
        XCTAssertGreaterThan(abs(frame.minX - startFrame.minX) + abs(frame.minY - startFrame.minY), 20,
                             "Dragging the top padding must actually move the native window")
        window.setContentSize(NSSize(width: frame.width + 10, height: frame.height + 10))
        settle()
        XCTAssertEqual(window.frame.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, frame.maxY, accuracy: 1)
    }

    @MainActor
    func testRepeatedOpenReusesWindowAndChangingDemandRefreshesItsTitle() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        vm.items = [item("D881", title: "第一个需求"), item("D882", title: "第二个需求")]
        let controller = DemandDetailWindowController(activates: false)
        vm.demandWindowPresenter = { controller.show($0) }
        defer { controller.close() }
        vm.openDemandEditor(.inspect, item: vm.items[0])
        settle()
        let first = try XCTUnwrap(controller.window)
        vm.openDemandEditor(.inspect, item: vm.items[0])
        vm.openDemandEditor(.inspect, item: vm.items[1])
        settle()
        XCTAssertTrue(controller.window === first)
        XCTAssertEqual(first.title, "D882 · 第二个需求")
        XCTAssertEqual(vm.demandEditor?.item.id, "D882")
        XCTAssertTrue(vm.expandedIDs.isEmpty)
    }

    @MainActor
    func testEditorsRemainInDemandWindowAndPromptDraftSurvivesClosingIt() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        let selected = item("D881", title: "编辑后返回本条需求")
        vm.items = [selected]
        let controller = DemandDetailWindowController(activates: false)
        vm.demandWindowPresenter = { controller.show($0) }
        defer { controller.close() }
        vm.openDemandEditor(.inspect, item: selected)
        settle()
        let window = try XCTUnwrap(controller.window)
        vm.openDemandEditor(.details, item: selected)
        settle()
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(vm.demandEditor?.kind, .details)
        XCTAssertNil(window.attachedSheet)
        // No changes: cancel returns to the same demand rather than closing the home workspace.
        try snapshot(window, name: "editor-before-cancel")
        click(window, point: NSPoint(x: try XCTUnwrap(window.contentView).bounds.width - 122, y: 30))
        XCTAssertEqual(vm.demandEditor?.kind, .inspect)
        XCTAssertEqual(vm.demandEditor?.item.id, selected.id)
        var sections = DemandPromptSections(stored: selected.prompt)
        sections.intent = "关闭独立窗口后需要保留的咒言草稿"
        XCTAssertTrue(vm.promptDraftStore.save(.init(originalPrompt: selected.prompt, sections: sections), for: selected.id))
        vm.openDemandEditor(.prompt, item: selected)
        settle()
        XCTAssertEqual(vm.editingFormCount, 1)
        window.performClose(nil)
        settle()
        XCTAssertNil(controller.window)
        XCTAssertEqual(vm.promptDraftStore.drafts[selected.id]?.sections.intent, sections.intent)
        XCTAssertEqual(vm.editingFormCount, 0)
    }

    @MainActor
    func testTabNavigatesMultilineSpellFieldsWithoutAddingTabsOrLosingDrafts() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        var selected = item("D881", title: "多行咒言键盘操作")
        selected.prompt = DemandPromptSections(codeEntry: "ultra 锁券链路", materials: "方案资料",
            intent: String(repeating: "改造接口并保留边界。\n", count: 50), reason: "等待外部确认").stored
        vm.items = [selected]
        let controller = DemandDetailWindowController(activates: false)
        vm.demandWindowPresenter = { controller.show($0) }
        defer { controller.close() }
        vm.openDemandEditor(.inspect, item: selected)
        vm.openDemandEditor(.prompt, item: selected)
        settle()
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let editors = descendants(root).compactMap { $0 as? NSTextView }.filter { !$0.isFieldEditor && $0.isEditable }
        let code = try XCTUnwrap(editors.first { $0.string == "ultra 锁券链路" })
        let materials = try XCTUnwrap(editors.first { $0.string == "方案资料" })
        let intent = try XCTUnwrap(editors.first { $0.string.hasPrefix("改造接口") })
        let supplement = try XCTUnwrap(editors.first { $0.string == "等待外部确认" })
        @MainActor func key(_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        }
        let navigation = try XCTUnwrap(controller.keyboardNavigation)
        XCTAssertTrue(window.makeFirstResponder(code))
        var passedActions = 0
        @MainActor func nextEditor(backwards: Bool = false) {
            for _ in 0..<40 {
                XCTAssertNil(navigation.handleKeyPress(key(backwards ? .shift : [])))
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                if let text = window.firstResponder as? NSTextView, text.isEditable { return }
                if window.firstResponder is DemandKeyboardActionView { passedActions += 1 }
            }
            XCTFail("Tab did not reach another text editor")
        }
        for next in [materials, intent, supplement, code] {
            nextEditor()
            XCTAssertTrue(window.firstResponder === next, "Inputs keep their visual order while buttons also enter the Tab sequence")
        }
        XCTAssertGreaterThan(passedActions, 0, "Image and save actions are keyboard reachable")
        nextEditor(backwards: true)
        XCTAssertTrue(window.firstResponder === supplement)
        supplement.insertText("，已补充", replacementRange: supplement.selectedRange())
        nextEditor()
        XCTAssertTrue(window.firstResponder === code)
        XCTAssertTrue(editors.allSatisfy { !$0.string.contains("\t") })
        code.setMarkedText("未完成输入", selectedRange: NSRange(location: 5, length: 0), replacementRange: code.selectedRange())
        XCTAssertNotNil(navigation.handleKeyPress(key()), "Tab does not interrupt IME composition")
        code.unmarkText()
        controller.close()
        settle()
        XCTAssertTrue(vm.promptDraftStore.drafts[selected.id]?.sections.supplement.contains("已补充") == true)
        XCTAssertNil(controller.keyboardNavigation)
    }

    @MainActor
    func testDirtyDemandEditGuardsNativeCloseAndSwitchingToAnotherDemand() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        vm.items = [item("D881", title: "未保存修改保护"), item("D882", title: "其他需求")]
        let controller = DemandDetailWindowController(activates: false)
        vm.demandWindowPresenter = { controller.show($0) }
        defer {
            vm.demandEditorDismissal = nil
            controller.close()
        }
        vm.openDemandEditor(.inspect, item: vm.items[0])
        vm.openDemandEditor(.details, item: vm.items[0])
        settle()
        let window = try XCTUnwrap(controller.window)
        let field = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSTextField }.first { $0.stringValue == "未保存修改保护" })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("正在编辑的新需求名", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        settle()
        XCTAssertNotNil(vm.demandEditorDismissal)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        XCTAssertNil(try XCTUnwrap(controller.keyboardNavigation).handleKeyPress(escape))
        settle()
        XCTAssertNotNil(controller.window)
        XCTAssertEqual(vm.demandEditor?.kind, .details)
        XCTAssertNotNil(window.attachedSheet, "Closing a dirty editor must ask before discarding")
        if let sheet = window.attachedSheet {
            click(sheet, point: NSPoint(x: 110, y: 28))
        }
        settle()
        // Exercise the same guard without interacting with the confirmation alert coordinates again.
        var requested = false
        var continuation: (() -> Void)?
        vm.demandEditorDismissal = { finish in requested = true; continuation = finish }
        vm.openDemandEditor(.inspect, item: vm.items[1])
        XCTAssertTrue(requested)
        XCTAssertEqual(vm.demandEditor?.item.id, "D881")
        continuation?()
        settle()
        XCTAssertEqual(vm.demandEditor?.item.id, "D882")
        XCTAssertTrue(controller.window === window)
    }

    @MainActor
    func testDeliveryPreviewGivesLongPlanRoomAndScrollsToEnd() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        var selected = item("D881", title: "多工程交付核对")
        let names = ["saleinventory", "ttrade", "aftersalecenter", "orderabilitycenter",
                     "b2ctradecenter", "orderhandlecenter", "nczordercenter", "scfcoord", "tradeextgateway"]
        let projects = names.map { DemandDeliveryProject(name: $0, branch: "feature/q-w-x-sell") }
        let markdown = "# 多工程技术方案\n\n" + (1...40).map { index in
            "## 第\(index)节\n\n" + String(repeating: "保留接口边界、异常处理与验证范围，按照实际开发工程和分支核对。", count: 8)
        }.joined(separator: "\n\n") + "\n\n最后一项：等待人工联调验收。"
        selected.technicalPlan = DemandTechnicalPlan(title: "多工程技术方案", markdown: markdown,
            projects: projects, scopeHash: selected.executionScope, codeRevision: nil,
            updatedAt: "2026-11-09T09:00:00Z", updatedBy: "ai")
        let plan = DemandDeliveryPlan(item: selected, link: ReqFlowLink(id: 42, no: "R42"),
            projects: projects, key: "preview-fixture")
        vm.items = [selected]
        let controller = DemandDetailWindowController(activates: false)
        vm.demandWindowPresenter = { controller.show($0) }
        defer { controller.close() }
        vm.openDemandEditor(.inspect, item: selected)
        settle()
        let original = try XCTUnwrap(controller.window)
        let originalMinimum = original.minSize
        vm.openDemandEditor(.delivery, item: selected, deliveryPlan: plan)
        settle()
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window === original)
        let view = try XCTUnwrap(window.contentView)
        let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }
            .max { $0.contentView.bounds.height < $1.contentView.bounds.height })
        let projectScroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }
            .first { $0 !== scroll })
        XCTAssertLessThanOrEqual(projectScroll.contentView.bounds.height, 112)
        XCTAssertGreaterThan(try XCTUnwrap(projectScroll.documentView).bounds.height, projectScroll.contentView.bounds.height)
        try snapshot(window, name: "delivery-plan")
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.height, 320, "The plan needs a usable reading area with nine repositories")
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height * 2)
        let beforeKeys = scroll.contentView.bounds.origin.y
        window.makeFirstResponder(nil)
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!
        XCTAssertNil(try XCTUnwrap(controller.keyboardNavigation).handleKeyPress(down))
        settle()
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, beforeKeys, "Arrow keys scroll the detail window")
        let before = scroll.contentView.bounds.origin.y
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first).visibleFrame
        DemandWindowPlacement.center(window, in: screen)
        window.makeKeyAndOrderFront(nil)
        settle()
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: -600, wheel2: 0, wheel3: 0))
        let location = window.convertPoint(toScreen: scroll.convert(
            NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil))
        wheel.location = CGPoint(x: location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - location.y)
        wheel.postToPid(ProcessInfo.processInfo.processIdentifier)
        let received = NSApp.nextEvent(matching: .scrollWheel, until: Date().addingTimeInterval(1),
            inMode: .default, dequeue: true)
        XCTAssertNotNil(received, "The test process should receive its own scroll event")
        if let received { window.sendEvent(received) }
        settle()
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, before, "Mouse/trackpad scrolling must move the plan")
        let document = try XCTUnwrap(scroll.documentView)
        document.scroll(NSPoint(x: 0, y: document.bounds.height))
        settle()
        XCTAssertGreaterThan(scroll.contentView.bounds.maxY, document.bounds.maxY - 30)
        try snapshot(window, name: "delivery-plan-bottom")
        window.setContentSize(NSSize(width: 660, height: 700))
        settle()
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.height, 300)
        vm.openDemandEditor(.inspect, item: selected)
        settle()
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(window.minSize, originalMinimum)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    @MainActor
    private func click(_ window: NSWindow, point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        settle()
    }
    @MainActor
    private func snapshot(_ window: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["DBOARD_INTERACTION_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let content = try XCTUnwrap(window.contentView)
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
    }
}
