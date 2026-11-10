import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandChatPickerInteractionTests: XCTestCase {
    private let main = DemandChat(id: "cid-main", name: "车点点主要对接群")
    private let other = DemandChat(id: "cid-other", name: "SAAS 联调群")

    @MainActor
    func testPrimarySelectionIsKeptUntilConfirmAndWholeRowIsClickable() throws {
        var saved: DemandChatLinks?
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [self.main, self.other], nextCursor: nil)
        })
        let window = host(DemandChatPicker(links: DemandChatLinks(), directory: directory,
            confirm: { saved = $0 }, cancel: {}), width: 560, height: 620)
        defer { window.close() }
        click(window, at: NSPoint(x: 300, y: 374))
        XCTAssertNil(saved, "Selecting a row must not save before confirmation")
        click(window, at: NSPoint(x: 500, y: 32))
        XCTAssertEqual(saved?.primary, main)
        XCTAssertTrue(saved?.secondary.isEmpty == true)
    }

    @MainActor
    func testAddingSecondaryPreservesMain() throws {
        var saved: DemandChatLinks?
        var cancelled = false
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [self.main, self.other], nextCursor: nil)
        })
        let window = host(DemandChatPicker(links: DemandChatLinks(primary: main), initialRole: .secondary,
            directory: directory, confirm: { saved = $0 }, cancel: { cancelled = true }), width: 560, height: 620)
        defer { window.close() }
        click(window, at: NSPoint(x: 300, y: 324))
        XCTAssertNil(saved)
        click(window, at: NSPoint(x: 500, y: 32))
        XCTAssertEqual(saved, DemandChatLinks(primary: main, secondary: [other]))
        XCTAssertFalse(cancelled)
    }

    @MainActor
    func testKeyboardSelectionAndEscapeStayWithinPicker() throws {
        var saved: DemandChatLinks?
        var cancelled = false
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [self.main, self.other], nextCursor: nil)
        })
        let window = host(DemandChatPicker(links: DemandChatLinks(), directory: directory,
            confirm: { saved = $0 }, cancel: { cancelled = true }), width: 560, height: 620)
        defer { window.close() }
        key(window, code: 125, characters: "")
        key(window, code: 36, characters: "\r")
        XCTAssertNil(saved)
        click(window, at: NSPoint(x: 500, y: 32))
        XCTAssertEqual(saved?.primary, main)
        saved = nil
        key(window, code: 53, characters: "")
        XCTAssertTrue(cancelled)
        XCTAssertNil(saved)
    }

    @MainActor
    func testNewEditorClosesWithoutLosingDraftAndReopensAsSheet() throws {
        let vm = DBoardViewModel(loadCache: false)
        var draft = DItemDraft(newID: "D099", priority: .p1)
        draft.name = "保留正在编辑的需求"
        draft.project = "ultra\ncanary"
        vm.newItemDraft = draft
        vm.workspacePage = .demands
        let window = host(DBoardRootView().environmentObject(vm).environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared), width: 900, height: 740)
        defer { window.close() }
        vm.newItemFormOpen = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(vm.editingFormCount, 1)
        click(sheet, at: NSPoint(x: sheet.contentView!.bounds.width - 130, y: 32))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(vm.newItemDraft?.name, draft.name)
        XCTAssertEqual(vm.newItemDraft?.project, draft.project)
        vm.newItemFormOpen = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil(window.attachedSheet)
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
    }

    @MainActor
    func testDirectoryReusesCompletedLoadAndExplicitRefreshFetchesAgain() async {
        var calls = 0
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            calls += 1
            return DemandChatPage(groups: [self.main], nextCursor: nil)
        })
        await directory.load()
        await directory.load()
        XCTAssertEqual(calls, 1)
        await directory.load(force: true)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testRenderInteractionScreens() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_INTERACTION_SNAPSHOTS"] else {
            throw XCTSkip("设置 DBOARD_INTERACTION_SNAPSHOTS 导出交互检查图")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let vm = DBoardViewModel(loadCache: false)
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [self.main, self.other,
                DemandChat(id: "cid-long", name: "天猫养车和车点点跨团队接口对接与联合验收沟通群"),
                DemandChat(id: "cid-duplicate-a", name: "联调沟通群"),
                DemandChat(id: "cid-duplicate-b", name: "联调沟通群")], nextCursor: nil)
        })
        var draft = DItemDraft(newID: "D099", priority: .p1)
        draft.name = "优化群聊关联和需求编辑"
        draft.project = "DBoard\n多个仓库或路径均可填写"
        draft.chatLinks = DemandChatLinks(primary: main, secondary: [other])
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(DemandChatPicker(links: draft.chatLinks!, directory: directory, confirm: { _ in }, cancel: {}),
                width: 560, height: 620, name: "chat-selected-" + name, appearance: appearance, output: output)
            try render(DemandChatPicker(links: DemandChatLinks(), directory: directory, confirm: { _ in }, cancel: {}),
                width: 480, height: 520, name: "chat-empty-min-" + name, appearance: appearance, output: output)
            try render(DemandItemEditor(draft: draft, close: {}).environmentObject(vm).environmentObject(ThemeManager.shared),
                width: 640, height: 680, name: "new-demand-" + name, appearance: appearance, output: output)
            let item = DItem(id: "D099", project: "DBoard", title: "", headerTitle: draft.name,
                status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
            try render(ItemCardView(item: item).environmentObject(vm).environmentObject(ThemeManager.shared)
                .environmentObject(FontManager.shared).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)),
                width: 520, height: 360, name: "demand-card-" + name, appearance: appearance, output: output)
            var changed = item
            changed.changes = [DemandChange(id: "C001", createdAt: Date(), intent: String(repeating: "原有变更的明细，不应挡住本次输入。", count: 30))]
            try render(DemandChangesEditor(item: changed, draftStore: vm.changeDraftStore, cancel: {}, refreshOnAppear: false)
                .environmentObject(vm), width: 640, height: 600, name: "change-input-first-" + name,
                appearance: appearance, output: output)
        }
    }

    @MainActor
    func testRenderCrossOrganizationGroupNotice() async throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_INTERACTION_SNAPSHOTS"] else {
            throw XCTSkip("Enable interaction snapshots explicitly")
        }
        let group = DemandChat(id: "cid-external", name: "高德-天猫深度合作")
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [], nextCursor: nil)
        }, search: { _, _ in DemandChatPage(groups: [], nextCursor: nil) }, discover: { _ in
            DemandChatDiscovery(groups: [group], restrictedIDs: [group.id])
        })
        await directory.search("高德")
        XCTAssertTrue(directory.groups.contains(group))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(DemandChatPicker(links: DemandChatLinks(primary: group), directory: directory,
                confirm: { _ in }, cancel: {}), width: 560, height: 620,
                name: "chat-cross-org-" + name, appearance: appearance, output: output)
        }
    }

    @MainActor
    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: width, height: height))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
    }

    @MainActor
    private func key(_ window: NSWindow, code: UInt16, characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
        NSApp.postEvent(event, atStart: true)
        if let queued = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.1),
            inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    @MainActor
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String,
        appearance: NSAppearance.Name, output: String) throws {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previous }
        let window = host(view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light), width: width, height: height)
        window.appearance = NSAppearance(named: appearance)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
    }
}
