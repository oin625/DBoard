import XCTest
import AppKit
import SwiftUI
@testable import DBoard

final class TryCaptureLifecycleTests: XCTestCase {
    func testUnsubmittedWritingSurvivesReloadAndOnlySubmitAllocatesAnID() throws {
        try isolated { store in
            XCTAssertNil(store.submitCapture(.idea))
            XCTAssertTrue(store.document.entries.isEmpty)
            let generation = store.captureGeneration(.idea)
            store.editCapture(.idea, field: "body", value: "先记一个念头\n再放一张图", generation: generation)
            XCTAssertTrue(store.flush())
            let reopened = TryStore(url: store.url, watching: false)
            XCTAssertEqual(reopened.capture(.idea).body, "先记一个念头\n再放一张图")
            XCTAssertTrue(reopened.document.entries.isEmpty)
            let id = try XCTUnwrap(reopened.submitCapture(.idea))
            XCTAssertEqual(id, "T001")
            XCTAssertEqual(reopened.entry(id)?.displayTitle, "先记一个念头")
            XCTAssertTrue(reopened.capture(.idea).isEmpty)
            XCTAssertNil(reopened.submitCapture(.idea), "Repeated save must not allocate another record")
            reopened.editCapture(.idea, field: "body", value: "旧编辑器的延迟回写", generation: generation)
            XCTAssertTrue(reopened.capture(.idea).isEmpty, "Dismantling the old editor must not resurrect a submitted draft")
            reopened.editCapture(.idea, field: "body", value: "  \n ", generation: reopened.captureGeneration(.idea))
            XCTAssertNil(reopened.submitCapture(.idea))
            XCTAssertEqual(reopened.document.entries.count, 1)
        }
    }

    func testTrashAndRestoreKeepMaterialRelationshipsAndNeverReuseIDs() throws {
        try isolated { store in
            let first = try XCTUnwrap(store.create(.task))
            store.edit(first, field: "body", value: "任务资料")
            let related = try XCTUnwrap(store.create(.digestion, relatedID: first))
            store.edit(related, field: "body", value: "我的理解")
            XCTAssertTrue(store.flush())
            XCTAssertTrue(store.trash(related))
            XCTAssertNil(store.entry(related))
            XCTAssertEqual(store.trashed.first?.body, "我的理解")
            XCTAssertEqual(store.trashed.first?.relatedIDs, [first])
            let next = try XCTUnwrap(store.create(.idea))
            XCTAssertEqual(next, "T003", "Deleted IDs stay reserved for existing AI references")
            XCTAssertTrue(store.restore(related))
            XCTAssertEqual(store.entry(related)?.body, "我的理解")
            XCTAssertEqual(store.entry(related)?.relatedIDs, [first])
            XCTAssertEqual(store.entry(first)?.relatedIDs, [related])
            let empty = try XCTUnwrap(store.create(.idea))
            let protected = try XCTUnwrap(store.create(.idea))
            XCTAssertTrue(store.update(protected) { $0.aiSummary = "已经有 AI 反馈，不能当空草稿清理" })
            XCTAssertEqual(store.trashEmptyEntries(), 2)
            XCTAssertNil(store.entry(empty))
            XCTAssertNotNil(store.entry(protected))
            XCTAssertEqual(store.trashed.count, 2)
            store.prepareCapture(.idea, relatedID: first)
            store.editCapture(.idea, field: "body", value: "还没收好的关联想法", generation: store.captureGeneration(.idea))
            XCTAssertTrue(store.trash(first))
            XCTAssertNil(store.submitCapture(.idea), "Cannot silently drop a deleted source relationship")
            XCTAssertEqual(store.capture(.idea).body, "还没收好的关联想法")
        }
    }

    func testCLIStopsForTrashAndPreservesCaptureSlotsDuringFeedback() throws {
        try isolated { store in
            let id = try XCTUnwrap(store.create(.task))
            store.edit(id, field: "body", value: "保留的正文")
            store.editCapture(.idea, field: "body", value: "还没收好的新想法", generation: 0)
            XCTAssertTrue(store.flush())
            let revision = try XCTUnwrap(store.entry(id)?.revision)
            let report = try cli(store, ["report", id, "--expected-revision", String(revision), "--summary", "完成一个步骤"])
            XCTAssertEqual(report.0, 0)
            store.reload()
            XCTAssertEqual(store.capture(.idea).body, "还没收好的新想法")
            XCTAssertTrue(store.trash(id))
            let before = try Data(contentsOf: store.url)
            let context = try cli(store, ["context", id])
            XCTAssertNotEqual(context.0, 0)
            XCTAssertTrue(String(decoding: context.1, as: UTF8.self).contains("回收站"))
            let feedback = try cli(store, ["report", id, "--expected-revision", String(revision), "--summary", "不能继续"])
            XCTAssertNotEqual(feedback.0, 0)
            XCTAssertEqual(try Data(contentsOf: store.url), before)
            let list = try cli(store, ["list", "--all"])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: list.1) as? [String: Any])
            XCTAssertEqual((json["items"] as? [[String: Any]])?.count, 0)
        }
    }

    @MainActor
    func testRepeatedOpeningDoesNotCreateRecordsAndClosingKeepsNativeText() throws {
        _ = NSApplication.shared
        try isolated { store in
            let writer = TryCaptureWindowController(store: store, activates: false)
            for _ in 0..<3 {
                writer.show(.idea)
                settle()
                writer.close()
                settle()
            }
            XCTAssertTrue(store.document.entries.isEmpty)
            writer.show(.idea)
            settle()
            let window = try XCTUnwrap(writer.window)
            let editor = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? TryNoteTextView }.first)
            window.makeFirstResponder(editor)
            editor.insertText("关掉也不能丢的想法", replacementRange: editor.selectedRange())
            writer.close()
            settle()
            XCTAssertEqual(TryStore(url: store.url, watching: false).capture(.idea).body, "关掉也不能丢的想法")
            XCTAssertTrue(store.document.entries.isEmpty)
            writer.show(.idea)
            settle()
            defer { writer.close() }
            let reopened = try XCTUnwrap(descendants(try XCTUnwrap(writer.window?.contentView)).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertEqual(reopened.string, "关掉也不能丢的想法")
        }
    }

    @MainActor
    func testIdeaWindowKeepsItsControllerAliveUntilClosed() throws {
        _ = NSApplication.shared
        try isolated { store in
            weak var retained: TryCaptureWindowController?
            var window: NSWindow?
            try autoreleasepool {
                var writer: TryCaptureWindowController? = TryCaptureWindowController(store: store, activates: false)
                retained = writer
                writer?.show(.idea); settle()
                let active = try XCTUnwrap(writer?.window)
                window = active
                writer = nil
                XCTAssertNotNil(retained, "Replacing the originating SwiftUI view must not disable close or save")
                let editor = try XCTUnwrap(descendants(active.contentView!).compactMap { $0 as? TryNoteTextView }.first)
                active.makeFirstResponder(editor)
                editor.insertText("窗口独立于首页存在", replacementRange: editor.selectedRange()); settle()
                let save = try XCTUnwrap(descendants(active.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                    .first { $0.keyboardIdentifier == "try-capture-save" })
                save.activate(); settle()
                XCTAssertFalse(active.isVisible)
                XCTAssertEqual(store.document.entries.count, 1)
            }
            settle()
            XCTAssertNil(retained, "The temporary retention must end on close")
            XCTAssertFalse(window?.isVisible ?? true)
        }
    }

    @MainActor
    func testSavingIdeaClosesWindowAndCloseAndEscapeRemainAvailable() throws {
        _ = NSApplication.shared
        try isolated { store in
            let writer = TryCaptureWindowController(store: store, activates: false)
            writer.show(.idea); settle()
            let window = try XCTUnwrap(writer.window)
            let editor = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            window.makeFirstResponder(editor)
            editor.insertText("收好之后应该关掉窗口", replacementRange: editor.selectedRange()); settle()
            let save = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "try-capture-save" })
            save.activate(); settle()
            XCTAssertEqual(store.document.entries.count, 1)
            XCTAssertNil(writer.window)
            XCTAssertFalse(window.isVisible)
            writer.show(.idea); settle()
            let reopened = try XCTUnwrap(writer.window)
            let close = try XCTUnwrap(descendants(reopened.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "try-capture-close" })
            close.activate(); settle()
            XCTAssertNil(writer.window)
            writer.show(.idea); settle()
            let escaped = try XCTUnwrap(writer.window)
            let bridge = try XCTUnwrap(descendants(escaped.contentView!).compactMap { $0 as? TryKeyboardHostView }.first)
            let native = try XCTUnwrap(descendants(escaped.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            escaped.makeFirstResponder(native)
            native.insertText("Esc 保留草稿", replacementRange: native.selectedRange())
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: escaped.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            _ = bridge.navigation?.handleKey(event); settle()
            XCTAssertNil(writer.window)
            XCTAssertEqual(TryStore(url: store.url, watching: false).capture(.idea).body, "Esc 保留草稿")
        }
    }

    @MainActor
    func testCardDeleteDoesNotAlsoOpenCardAndNewHomeRendersWithoutEmptyCards() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try XCTUnwrap(store.create(.idea))
            store.edit(id, field: "body", value: "做一个舒服的随手记录入口")
            XCTAssertTrue(store.flush())
            var opened = 0
            let card = host(TryEntryCard(entry: try XCTUnwrap(store.entry(id)), remove: { _ = store.trash(id) }) { opened += 1 }
                .padding(24).demandFloatingCanvas(), size: NSSize(width: 380, height: 260))
            settle()
            let remove = try XCTUnwrap(descendants(try XCTUnwrap(card.contentView)).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "try-trash-" + id })
            let point = remove.convert(NSPoint(x: 4, y: 4), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                card.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: card.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
            settle()
            XCTAssertNil(store.entry(id))
            XCTAssertEqual(opened, 0)
            card.close()
            XCTAssertTrue(store.restore(id))
            _ = store.create(.idea)
            store.selectedID = nil
            let home = host(TryWorkspaceView(store: store).background { DemandCanvasBackground() }, size: NSSize(width: 620, height: 800))
            settle()
            defer { home.close() }
            XCTAssertEqual(store.document.entries.count, 2)
            let root = try XCTUnwrap(home.contentView)
            XCTAssertTrue(descendants(root).compactMap { $0 as? DemandKeyboardActionView }.isEmpty)
            let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertTrue(editor.isEditable, "The home composer is ready to write without an editing-mode button")
            let output = ProcessInfo.processInfo.environment["DBOARD_TRY_CAPTURE_SNAPSHOTS"]
            if let output {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    home.appearance = NSAppearance(named: appearance); settle()
                    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: output + "/" + (appearance == .aqua ? "home-light.png" : "home-dark.png")))
                }
            }
        }
    }

    func testEmptyTrashOnlyPurgesReviewedRowsAndKeepsUnsubmittedWriting() throws {
        try isolated { store in
            let project = try XCTUnwrap(store.project(name: "保留的项目", context: "共用资料"))
            let source = try XCTUnwrap(store.create(.task, projectID: project))
            let removed = try XCTUnwrap(store.create(.idea, relatedID: source))
            let restored = try XCTUnwrap(store.create(.digestion))
            let later = try XCTUnwrap(store.create(.idea))
            store.edit(removed, field: "body", value: "将被永久删除的资料")
            store.remember(removed, bookmark: TryBookmark(location: 0, length: 0, scrollY: 0))
            store.prepareCapture(.idea, projectID: project, relatedID: removed)
            store.editCapture(.idea, field: "body", value: "还没收好的内容不能丢", generation: 0)
            XCTAssertTrue(store.flush())
            XCTAssertTrue(store.trash(removed))
            XCTAssertTrue(store.trash(restored))
            let reviewed = Set(store.trashed.map(\.id))
            XCTAssertTrue(store.restore(restored), "Restoring while confirmation is open must be respected")
            XCTAssertTrue(store.trash(later), "New trash added after review must not be included")
            let beforeRevision = try XCTUnwrap(store.entry(source)?.revision)
            XCTAssertEqual(store.emptyTrash(reviewed), 1)
            XCTAssertFalse(store.document.entries.contains { $0.id == removed })
            XCTAssertNil(store.bookmarks[removed])
            store.remember(removed, bookmark: TryBookmark(location: 0, length: 0, scrollY: 0))
            XCTAssertNil(store.bookmarks[removed], "Delayed editor callbacks cannot revive purged state")
            XCTAssertEqual(store.entry(source)?.relatedIDs, [])
            XCTAssertEqual(store.entry(source)?.revision, beforeRevision + 1)
            XCTAssertNotNil(store.entry(restored))
            XCTAssertEqual(store.trashed.map(\.id), [later])
            XCTAssertEqual(store.capture(.idea).body, "还没收好的内容不能丢")
            XCTAssertEqual(store.capture(.idea).projectID, project)
            XCTAssertNil(store.capture(.idea).relatedID)
            XCTAssertEqual(store.document.projects.first?.context, "共用资料")
            let saved = try XCTUnwrap(store.submitCapture(.idea))
            XCTAssertEqual(store.entry(saved)?.body, "还没收好的内容不能丢")
            XCTAssertEqual(store.emptyTrash(reviewed), 0, "A repeated confirmation is harmless")
        }
    }

    func testPermanentDeletionReservesIDsForGUIAndCLIEvenForLegacyStores() throws {
        try isolated { store in
            // Existing documents have no high-water field; derive it before deleting their highest ID.
            try TryDisk.change(store.url) { document in
                document.entries = [TryEntry(id: "T080", kind: .task, createdAt: 1, updatedAt: 1)]
                document.lastEntryNumber = nil
            }
            store.reload()
            XCTAssertTrue(store.trash("T080"))
            XCTAssertEqual(store.emptyTrash(["T080"]), 1)
            let context = try cli(store, ["context", "T080"])
            XCTAssertNotEqual(context.0, 0)
            let creation = try cli(store, ["create", "--kind", "task", "--title", "新任务"])
            XCTAssertEqual(creation.0, 0)
            store.reload()
            XCTAssertEqual(store.document.entries.map(\.id), ["T081"])
            XCTAssertTrue(store.trash("T081"))
            XCTAssertEqual(store.emptyTrash(["T081"]), 1)
            let reopened = TryStore(url: store.url, watching: false)
            XCTAssertEqual(reopened.create(.idea), "T082")
            reopened.editCapture(.task, field: "body", value: "通过记录框新增", generation: 0)
            XCTAssertEqual(reopened.submitCapture(.task), "T083")
        }
    }

    @MainActor
    func testTaskDetailsKeepSupportingContentCollapsedAndNextStepOptional() throws {
        _ = NSApplication.shared
        try isolated { store in
            let project = try XCTUnwrap(store.project(name: "D板", context: "共用资料"))
            let id = try XCTUnwrap(store.create(.task, projectID: project))
            store.edit(id, field: "body", value: "只写这次要做的事情")
            store.edit(id, field: "progress", value: "正在验证")
            XCTAssertTrue(store.update(id) {
                $0.aiSummary = String(repeating: "较长的交接摘要。", count: 80)
                $0.aiResult = "可以采纳的最新结果"
                $0.reports = [TryReport(id: "one", at: 1, summary: "一步的概括", details: "反馈明细")]
            })
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id)
            settle()
            defer { detail.close() }
            let window = try XCTUnwrap(detail.window)
            @MainActor func ids() -> Set<String> {
                Set(descendants(window.contentView!).compactMap { ($0 as? DemandKeyboardActionView)?.keyboardIdentifier })
            }
            @MainActor func click(_ id: String) throws {
                let target = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                    .first { $0.keyboardIdentifier == id })
                var ancestor = target.superview
                while let view = ancestor {
                    if let scroll = view as? NSScrollView, let document = scroll.documentView {
                        document.scrollToVisible(target.convert(target.bounds, to: document).insetBy(dx: 0, dy: -8))
                    }
                    ancestor = view.superview
                }
                settle()
                let point = target.convert(NSPoint(x: target.bounds.maxX - 6, y: target.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                }
                settle()
            }
            if let output = ProcessInfo.processInfo.environment["DBOARD_TRY_TASK_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance); settle()
                    let root = try XCTUnwrap(window.contentView)
                    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: output + "/" + (appearance == .aqua ? "task-light.png" : "task-dark.png")))
                }
            }
            XCTAssertTrue(ids().contains("try-references"))
            XCTAssertTrue(ids().contains("try-result"))
            XCTAssertTrue(ids().contains("try-add-next-step"))
            XCTAssertFalse(ids().contains("try-summary"))
            XCTAssertFalse(ids().contains("try-history"))
            XCTAssertFalse(ids().contains("try-adopt-result"))
            try click("try-result")
            XCTAssertTrue(ids().contains("try-adopt-result"))
            XCTAssertEqual(store.entry(id)?.body, "只写这次要做的事情", "Reading AI output never overwrites the body")
            try click("try-result")
            try click("try-references")
            XCTAssertTrue(ids().contains("try-summary"))
            XCTAssertTrue(ids().contains("try-history"))
            XCTAssertFalse(ids().contains("try-adopt-result"))
            try click("try-references")
            try click("try-add-next-step")
            XCTAssertFalse(ids().contains("try-add-next-step"))
            XCTAssertEqual(store.entry(id)?.nextStep, "", "Adding the optional input does not invent an action")
        }
    }

    private func cli(_ store: TryStore, _ arguments: [String]) throws -> (Int32, Data) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [path.path, "try", "--store", store.url.path] + arguments
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
    private func isolated(_ action: (TryStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TryCapture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try action(TryStore(url: folder.appendingPathComponent("personal.json"), watching: false))
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    @MainActor private func host<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.environmentObject(ThemeManager.shared).environmentObject(FontManager.shared))
        window.orderBack(nil)
        return window
    }
}
