import XCTest
import Foundation
import SwiftUI
import AppKit
@testable import DBoard

final class DemandChangeDraftTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBoardChangeDraft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func type(_ text: String, into session: DemandChangeDraftSession) {
        session.updateIntent(text, generation: session.generation)
    }

    @MainActor
    func testNativeInputRestoresAfterEditorDestructionAndAppStoreReload() throws {
        _ = NSApplication.shared
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let item = DItem(id: "D014", project: "ultra", title: "", headerTitle: "追加变更草稿恢复",
                status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil,
                milestones: [], prompt: DemandPromptSections(intent: "原始要求").stored)
            let vm = DBoardViewModel(loadCache: false, changeDraftStore: DemandChangeDraftStore(url: file))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 640, height: 640),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let controller = NSHostingController(rootView: AnyView(
                DemandChangesEditor(item: item, draftStore: vm.changeDraftStore, cancel: {}, refreshOnAppear: false)
                    .environmentObject(vm)))
            window.contentViewController = controller
            window.orderBack(nil)
            defer { window.close() }
            settle(window)
            let editor = try XCTUnwrap(findTextEditor(try XCTUnwrap(window.contentView)))
            let text = "取消再次查券\n\n    保留缩进，返回结果待确认  "
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            settle(window)
            XCTAssertEqual(DemandChangeDraftStore(url: file).drafts[item.id]?.intent, text)
            controller.rootView = AnyView(Color.clear)
            settle(window)
            XCTAssertEqual(vm.editingFormCount, 0)
            let relaunched = DBoardViewModel(loadCache: false, changeDraftStore: DemandChangeDraftStore(url: file))
            controller.rootView = AnyView(
                DemandChangesEditor(item: item, draftStore: relaunched.changeDraftStore, cancel: {}, refreshOnAppear: false)
                    .environmentObject(relaunched))
            settle(window)
            XCTAssertEqual(try XCTUnwrap(findTextEditor(try XCTUnwrap(window.contentView))).string, text)
            XCTAssertTrue(item.changes.isEmpty)
            XCTAssertEqual(item.prompt, DemandPromptSections(intent: "原始要求").stored)
        }
    }

    @MainActor
    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func findTextEditor(_ view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        for child in view.subviews { if let editor = findTextEditor(child) { return editor } }
        return nil
    }

    func testDifferentDemandsKeepIndependentDraftsAndIncompleteWhitespace() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let store = DemandChangeDraftStore(url: file)
            let first = DemandChangeDraftSession(id: "D014", changes: [], store: store)
            let second = DemandChangeDraftSession(id: "D013", changes: [], store: store)
            type("返回结果需要：\n\n    ", into: first)
            type("另一张需求的变更", into: second)
            let reopened = DemandChangeDraftSession(id: "D014", changes: [], store: DemandChangeDraftStore(url: file))
            XCTAssertTrue(reopened.restored)
            XCTAssertEqual(reopened.intent, first.intent)
            XCTAssertEqual(DemandChangeDraftStore(url: file).drafts["D013"]?.intent, second.intent)
        }
    }

    func testSuccessfulAppendClearsOnlyItsDraftAndLateInputCannotResurrectIt() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let cache = directory.appendingPathComponent("cache.md")
            try "## 🟡 重要\n".write(to: cache, atomically: true, encoding: .utf8)
            var demand = DItemDraft(newID: "D014", priority: .p1)
            demand.name = "正式追加后清理草稿"
            XCTAssertTrue(DItemStore.create(demand, at: cache))
            let store = DemandChangeDraftStore(url: file)
            let first = DemandChangeDraftSession(id: demand.id, changes: [], store: store)
            let second = DemandChangeDraftSession(id: "D013", changes: [], store: store)
            type("已确认的接口返回改动", into: first)
            type("其他需求的草稿", into: second)
            let oldGeneration = first.generation
            let change = try XCTUnwrap(DItemStore.appendChange(id: demand.id, intent: first.intent, at: cache))
            XCTAssertTrue(first.markAdded(change))
            first.updateIntent("已提交编辑器的迟到事件", generation: oldGeneration)
            first.preserve()
            XCTAssertEqual(first.intent, "")
            XCTAssertNil(DemandChangeDraftStore(url: file).drafts[demand.id])
            XCTAssertEqual(DemandChangeDraftStore(url: file).drafts["D013"]?.intent, second.intent)
            XCTAssertEqual(try DItemStore.currentItem(id: demand.id, at: cache).changes.map(\.intent), [change.intent])
            type("下一条未提交变更", into: first)
            let reopened = DemandChangeDraftSession(id: demand.id, changes: [change], store: DemandChangeDraftStore(url: file))
            XCTAssertEqual(reopened.intent, "下一条未提交变更")
        }
    }

    func testAppendFailureKeepsDraftAndUnsubmittedTextStaysOutOfAIContext() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let cache = directory.appendingPathComponent("cache.md")
            try "## 🟡 重要\n".write(to: cache, atomically: true, encoding: .utf8)
            var demand = DItemDraft(newID: "D014", priority: .p1)
            demand.name = "未提交变更隔离"
            demand.promptSections.intent = "原有咒言"
            XCTAssertTrue(DItemStore.create(demand, at: cache))
            let formal = try XCTUnwrap(DItemStore.appendChange(id: demand.id, intent: "已经提交的变更", at: cache))
            let before = try Data(contentsOf: cache)
            let session = DemandChangeDraftSession(id: demand.id, changes: [formal], store: DemandChangeDraftStore(url: file))
            type("尚未决定的变更内容", into: session)
            XCTAssertNil(DItemStore.appendChange(id: demand.id, intent: session.intent, at: directory.appendingPathComponent("missing.md")))
            let reopened = DemandChangeDraftSession(id: demand.id, changes: [formal], store: DemandChangeDraftStore(url: file))
            XCTAssertEqual(reopened.intent, session.intent)
            let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tools/dboard_ai.py").path
            let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path, "context", demand.id])
            XCTAssertEqual(result.exitCode, 0)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
            let context = try XCTUnwrap(json["context"] as? String)
            XCTAssertTrue(context.contains("已经提交的变更"))
            XCTAssertFalse(context.contains(session.intent))
            XCTAssertEqual(try Data(contentsOf: cache), before)
        }
    }

    func testQuitAfterFormalAppendBeforeDraftCleanupDoesNotOfferDuplicateChange() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let existing = DemandChange(id: "C001", createdAt: Date(), intent: "以前的变更")
            let session = DemandChangeDraftSession(id: "D014", changes: [existing], store: DemandChangeDraftStore(url: file))
            type("已经正式添加的新变更", into: session)
            let submitted = DemandChange(id: "C002", createdAt: Date(), intent: session.intent)
            let reopened = DemandChangeDraftSession(id: "D014", changes: [existing, submitted], store: DemandChangeDraftStore(url: file))
            XCTAssertEqual(reopened.intent, "")
            XCTAssertFalse(reopened.restored)
            XCTAssertNil(DemandChangeDraftStore(url: file).drafts["D014"])
        }
    }

    func testRefreshPreservesDraftWhenAnotherChangeIsAddedAndAllowsRepeatingOlderIntent() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let existing = DemandChange(id: "C001", createdAt: Date(), intent: "补充超时处理")
            let session = DemandChangeDraftSession(id: "D014", changes: [existing], store: DemandChangeDraftStore(url: file))
            type(existing.intent, into: session)
            let unrelated = DemandChange(id: "C002", createdAt: Date(), intent: "其他人添加的变更")
            session.reconcile(with: [existing, unrelated])
            XCTAssertEqual(session.intent, existing.intent)
            let reopened = DemandChangeDraftSession(id: "D014", changes: [existing, unrelated], store: DemandChangeDraftStore(url: file))
            XCTAssertEqual(reopened.intent, existing.intent)
        }
    }

    func testExplicitDiscardClearsDraftAndIgnoresLateCallbacks() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let session = DemandChangeDraftSession(id: "D014", changes: [], store: DemandChangeDraftStore(url: file))
            type("放弃的变更", into: session)
            let oldGeneration = session.generation
            XCTAssertTrue(session.discard())
            session.updateIntent("旧输入框的迟到回调", generation: oldGeneration)
            session.preserve()
            XCTAssertNil(DemandChangeDraftStore(url: file).drafts["D014"])
        }
    }

    func testDiskFailurePreservesInputWithinAppAndCorruptFileIsNeverOverwritten() throws {
        try withDirectory { directory in
            let blocked = directory.appendingPathComponent("not-a-directory")
            try Data().write(to: blocked)
            let store = DemandChangeDraftStore(url: blocked.appendingPathComponent("drafts.json"))
            let session = DemandChangeDraftSession(id: "D014", changes: [], store: store)
            type("写入失败也要保留", into: session)
            XCTAssertNotNil(session.error)
            XCTAssertEqual(DemandChangeDraftSession(id: "D014", changes: [], store: store).intent, session.intent)
            XCTAssertFalse(session.discard())
            let file = directory.appendingPathComponent("corrupt.json")
            let corrupt = Data("损坏的草稿".utf8)
            try corrupt.write(to: file)
            let unreadable = DemandChangeDraftStore(url: file)
            let another = DemandChangeDraftSession(id: "D013", changes: [], store: unreadable)
            type("新输入留在内存", into: another)
            XCTAssertNotNil(another.error)
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
            XCTAssertEqual(DemandChangeDraftSession(id: "D013", changes: [], store: unreadable).intent, another.intent)
        }
    }

    func testOpeningWithoutInputCreatesNoDraftAndClearingInputRemovesIt() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let session = DemandChangeDraftSession(id: "D014", changes: [], store: DemandChangeDraftStore(url: file))
            XCTAssertTrue(session.preserve())
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            type("暂存内容", into: session)
            type("", into: session)
            XCTAssertNil(DemandChangeDraftStore(url: file).drafts["D014"])
        }
    }
}
