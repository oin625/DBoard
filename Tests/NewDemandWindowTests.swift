import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class NewDemandWindowTests: XCTestCase {
    @MainActor
    func testOpeningUsesOneWindowWithoutDetachingHomeOrAttachingAnotherSheet() throws {
        try fixture { vm, _ in
            var detachRequests = 0
            let observer = NotificationCenter.default.addObserver(forName: .init("DBoardEditorWillOpen"),
                object: nil, queue: .main) { _ in MainActor.assumeIsolated { detachRequests += 1 } }
            defer { NotificationCenter.default.removeObserver(observer) }
            let home = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 600, height: 600),
                                styleMask: [.titled], backing: .buffered, defer: false)
            home.isReleasedWhenClosed = false
            home.contentView = NSHostingView(rootView: Color.clear.frame(width: 600, height: 600)
                .demandEditorPresentation().environmentObject(vm).environmentObject(ThemeManager.shared))
            home.orderOut(nil)
            defer { home.close() }
            let controller = NewDemandWindowController(activates: false)
            vm.newDemandWindowPresenter = { controller.show($0) }
            defer { controller.close() }
            vm.beginNewItemDraft()
            settle()
            let first = try XCTUnwrap(controller.window)
            let id = vm.newItemDraft?.id
            vm.beginNewItemDraft()
            settle()
            XCTAssertTrue(controller.window === first)
            XCTAssertEqual(vm.newItemDraft?.id, id)
            XCTAssertEqual(detachRequests, 0)
            XCTAssertFalse(home.isVisible)
            XCTAssertNil(home.attachedSheet)
            XCTAssertNil(first.attachedSheet)
            XCTAssertTrue(vm.newItemFormInWindow)
            XCTAssertEqual(vm.workspacePage, .overview)
        }
    }

    @MainActor
    func testTypingAndClosingNativeWindowKeepsDraftAndReopeningRestoresIt() throws {
        try fixture { vm, draftURL in
            let controller = NewDemandWindowController(activates: false)
            vm.newDemandWindowPresenter = { controller.show($0) }
            defer { controller.close() }
            vm.beginNewItemDraft()
            settle()
            let original = try XCTUnwrap(controller.window)
            let field = try XCTUnwrap(descendants(try XCTUnwrap(original.contentView))
                .compactMap { $0 as? NSTextField }
                .first { $0.isEditable && $0.placeholderString == "用一句话说明要做什么" })
            XCTAssertTrue(original.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText("跨工程需求草稿", replacementRange: editor.selectedRange())
            original.makeFirstResponder(nil)
            settle()
            XCTAssertEqual(vm.newItemDraft?.name, "跨工程需求草稿")
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: original.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
            XCTAssertNil(try XCTUnwrap(controller.keyboardNavigation).handleKeyPress(escape))
            settle()
            XCTAssertNil(controller.window)
            XCTAssertFalse(vm.newItemFormOpen)
            XCTAssertFalse(vm.newItemFormInWindow)
            XCTAssertEqual(vm.editingFormCount, 0)
            XCTAssertEqual(NewDemandDraftStore(url: draftURL).draft?.name, "跨工程需求草稿")
            vm.beginNewItemDraft()
            settle()
            XCTAssertFalse(controller.window === original)
            XCTAssertEqual(vm.newItemDraft?.name, "跨工程需求草稿")
            XCTAssertNil(controller.window?.attachedSheet)
        }
    }

    @MainActor
    func testTabMovesBetweenInputsAndRevealsLowerFieldsWhileArrowsKeepTextEditing() throws {
        try fixture { vm, _ in
            var draft = DItemDraft(newID: "D020", priority: .p1)
            draft.name = "键盘录入"
            draft.project = "ultra"
            draft.branch = "feature/keyboard"
            vm.newItemDraft = draft
            let controller = NewDemandWindowController(activates: false)
            vm.newDemandWindowPresenter = { controller.show($0) }
            defer { controller.close() }
            vm.beginNewItemDraft()
            settle()
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: 560, height: 600))
            settle()
            let root = try XCTUnwrap(window.contentView)
            let fields = descendants(root).compactMap { $0 as? NSTextField }
            let title = try XCTUnwrap(fields.first { $0.isEditable && $0.stringValue == draft.name })
            let branch = try XCTUnwrap(fields.first { $0.isEditable && $0.stringValue == draft.branch })
            let repository = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextView }
                .first { !$0.isFieldEditor && $0.string == "ultra" })
            let navigation = try XCTUnwrap(controller.keyboardNavigation)
            @MainActor func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: code == 48 ? "\t" : "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code)!
            }
            XCTAssertTrue(window.makeFirstResponder(title))
            let titleEditor = try XCTUnwrap(title.currentEditor() as? NSTextView)
            XCTAssertNotNil(navigation.handleKeyPress(key(125)), "Typing keeps native arrow behavior")
            titleEditor.insertText("已填写", replacementRange: titleEditor.selectedRange())
            XCTAssertNil(navigation.handleKeyPress(key(48)))
            settle()
            XCTAssertFalse(title.currentEditor() === window.firstResponder)
            var passed: Set<String> = []
            for _ in 0..<40 {
                if window.firstResponder === repository { break }
                XCTAssertNil(navigation.handleKeyPress(key(48)))
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                if let action = window.firstResponder as? DemandKeyboardActionView { passed.insert(action.keyboardIdentifier) }
            }
            XCTAssertTrue(window.firstResponder === repository)
            XCTAssertTrue(passed.contains("demand-engineering-section"))
            XCTAssertTrue(passed.contains { $0.hasPrefix("demand-priority-") })
            XCTAssertNil(navigation.handleKeyPress(key(48)))
            settle()
            XCTAssertTrue(branch.currentEditor() === window.firstResponder)
            XCTAssertFalse(repository.string.contains("\t"), "Tab must navigate rather than insert indentation")
            XCTAssertNil(navigation.handleKeyPress(key(48, flags: .shift)))
            settle()
            XCTAssertTrue(window.firstResponder === repository)
            let outer = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }
                .max { $0.contentView.bounds.height < $1.contentView.bounds.height })
            XCTAssertGreaterThan(outer.contentView.bounds.origin.y, 0, "Tab reveals offscreen inputs")
            window.makeFirstResponder(nil)
            let before = outer.contentView.bounds.origin.y
            XCTAssertNil(navigation.handleKeyPress(key(126)))
            XCTAssertLessThan(outer.contentView.bounds.origin.y, before)
            XCTAssertNotNil(navigation.handleKeyPress(key(48, flags: .command)))
            controller.close()
            settle()
            XCTAssertNil(controller.keyboardNavigation)
            XCTAssertTrue(vm.newItemDraft?.name.contains("已填写") == true)
        }
    }

    @MainActor
    func testIncidentTypeAndNamespaceAreReadyBeforeWindowPresentation() throws {
        try fixture { vm, _ in
            var received: DItemDraft?
            vm.newDemandWindowPresenter = { received = $0.newItemDraft }
            vm.beginNewIncidentDraft()
            let draft = try XCTUnwrap(received)
            XCTAssertTrue(draft.isIncident)
            XCTAssertTrue(draft.id.hasPrefix("P"))
            XCTAssertEqual(draft.priority, .p0)
            XCTAssertEqual(draft.status, .inProgress)
        }
    }

    @MainActor
    func testSwitchingTypeInWindowKeepsInputAndClosingDoesNotClearAnotherEditorsGuard() throws {
        try fixture { vm, _ in
            var draft = DItemDraft(newID: "D020", priority: .p1)
            draft.name = "切换类型仍要保留"
            draft.project = "ultra\naudi"
            vm.newItemDraft = draft
            let controller = NewDemandWindowController(activates: false)
            vm.newDemandWindowPresenter = { controller.show($0) }
            defer { controller.close() }
            vm.beginNewItemDraft()
            settle()
            let window = try XCTUnwrap(controller.window)
            let view = try XCTUnwrap(window.contentView)
            let point = NSPoint(x: 198, y: view.bounds.height - 102)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
            settle()
            XCTAssertTrue(vm.newItemDraft?.isIncident == true)
            XCTAssertTrue(vm.newItemDraft?.id.hasPrefix("P") == true)
            XCTAssertEqual(vm.newItemDraft?.name, draft.name)
            XCTAssertEqual(vm.newItemDraft?.project, draft.project)
            XCTAssertTrue(controller.window === window)
            vm.demandEditorInWindow = true
            vm.demandEditorDismissal = { _ in }
            window.performClose(nil)
            settle()
            XCTAssertNotNil(vm.demandEditorDismissal)
            vm.demandEditorDismissal = nil
        }
    }

    @MainActor
    func testRenderNewAndRestoredFormsInBothAppearances() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_NEW_DEMAND_SNAPSHOTS"] else {
            throw XCTSkip("Enable creation window UI snapshots explicitly")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for (name, appearance, width) in [
            ("new-light", NSAppearance.Name.aqua, CGFloat(660)),
            ("new-dark", .darkAqua, CGFloat(660)),
            ("new-compact", .aqua, CGFloat(560)),
            ("incident", .aqua, CGFloat(660)),
            ("restored", .aqua, CGFloat(660))
        ] {
            try fixture { vm, _ in
                NSApp.appearance = NSAppearance(named: appearance)
                let controller = NewDemandWindowController(activates: false)
                vm.newDemandWindowPresenter = { controller.show($0) }
                defer { controller.close() }
                if name == "restored" {
                    var draft = DItemDraft(newID: "D020", priority: .p1)
                    draft.name = "多工程开发需求"
                    draft.project = "ultra\n/Users/fixture/work space/tesla"
                    draft.branch = "ultra:feature/cdd-lock"
                    draft.desc = "将锁券与照片查询从验券流程中拆出，提供独立接口。"
                    vm.newItemDraft = draft
                }
                if name == "incident" { vm.beginNewIncidentDraft() }
                else { vm.beginNewItemDraft() }
                let window = try XCTUnwrap(controller.window)
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(NSSize(width: width, height: 740))
                settle()
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
                XCTAssertNil(window.attachedSheet)
            }
        }
    }

    @MainActor
    private func fixture(_ body: (DBoardViewModel, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardNewWindow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("draft.json")
        let vm = DBoardViewModel(loadCache: false, newItemDraftStore: NewDemandDraftStore(url: url))
        try body(vm, url)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
}
