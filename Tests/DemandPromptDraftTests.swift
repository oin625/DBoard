import XCTest
import Foundation
import SwiftUI
import AppKit
@testable import DBoard

final class DemandPromptDraftTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBoardPromptDraft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @MainActor
    func testNativeEditorInputRestoresAfterViewDestructionAndStoreReload() throws {
        _ = NSApplication.shared
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let initial = DemandPromptSections(codeEntry: "ultra", materials: "参考资料", intent: "原有要求")
            let item = DItem(id: "D014", project: "ultra", title: "", headerTitle: "原生输入草稿恢复",
                status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil,
                milestones: [], prompt: initial.stored)
            let store = DemandPromptDraftStore(url: file)
            let vm = DBoardViewModel(loadCache: false, promptDraftStore: store)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 640, height: 640),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let controller = NSHostingController(rootView: AnyView(
                DemandPromptEditor(item: item, draftStore: vm.promptDraftStore, cancel: {}).environmentObject(vm)))
            window.contentViewController = controller
            window.orderBack(nil)
            defer { window.close() }
            settle(window)
            let editor = try XCTUnwrap(findCodeEntryEditor(try XCTUnwrap(window.contentView)))
            let updated = "ultra\ntesla\n查询和锁券流程  "
            editor.insertText(updated, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            settle(window)
            XCTAssertEqual(DemandPromptDraftStore(url: file).drafts[item.id]?.sections.codeEntry, updated)
            controller.rootView = AnyView(Color.clear)
            settle(window)
            let relaunched = DBoardViewModel(loadCache: false, promptDraftStore: DemandPromptDraftStore(url: file))
            controller.rootView = AnyView(
                DemandPromptEditor(item: item, draftStore: relaunched.promptDraftStore, cancel: {}).environmentObject(relaunched))
            settle(window)
            let reopened = try XCTUnwrap(findCodeEntryEditor(try XCTUnwrap(window.contentView)))
            XCTAssertEqual(reopened.string, updated)
            XCTAssertEqual(relaunched.promptDraftStore.drafts[item.id]?.sections.materials, initial.materials)
            XCTAssertEqual(relaunched.promptDraftStore.drafts[item.id]?.sections.intent, initial.intent)
            XCTAssertEqual(item.prompt, initial.stored)
        }
    }

    @MainActor
    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func findCodeEntryEditor(_ view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, editor.accessibilityLabel() == "代码入口" { return editor }
        for child in view.subviews { if let editor = findCodeEntryEditor(child) { return editor } }
        return nil
    }

    func testIncompleteFieldsAndWhitespaceSurviveClosingAndRelaunch() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let store = DemandPromptDraftStore(url: file)
            let session = DemandPromptDraftSession(id: "D014", prompt: "", store: store)
            session.sections = DemandPromptSections(codeEntry: "ultra\ntesla\n",
                materials: "https://example.com/资料\n", intent: "",
                reason: "    缩进与空行\n\n", rules: "中文说明  ")
            XCTAssertNotNil(session.sections.validationError)
            let restored = DemandPromptDraftSession(id: "D014", prompt: "",
                store: DemandPromptDraftStore(url: file))
            XCTAssertTrue(restored.restored)
            XCTAssertEqual(restored.sections, session.sections)
            XCTAssertEqual(restored.originalPrompt, "")
        }
    }

    func testDraftsForDifferentDemandsStayIndependentAndSaveDoesNotResurrect() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let store = DemandPromptDraftStore(url: file)
            let first = DemandPromptDraftSession(id: "D014", prompt: "原始咒言", store: store)
            let second = DemandPromptDraftSession(id: "D013", prompt: "", store: store)
            first.sections.intent = "第一张的改动"
            second.sections.intent = "第二张的改动"
            XCTAssertTrue(first.markSaved())
            first.sections.intent = "已关闭表单的迟到回调"
            first.preserve()
            let relaunched = DemandPromptDraftStore(url: file)
            XCTAssertNil(relaunched.drafts["D014"])
            XCTAssertEqual(relaunched.drafts["D013"]?.sections.intent, "第二张的改动")
        }
    }

    func testUnpublishedDraftDoesNotChangeSavedPromptOrAIContext() throws {
        try withDirectory { directory in
            let cache = directory.appendingPathComponent("cache.md")
            try "## 🟡 重要\n".write(to: cache, atomically: true, encoding: .utf8)
            var demand = DItemDraft(newID: "D014", priority: .p1)
            demand.name = "正式咒言和草稿分开"
            demand.promptSections.intent = "已保存的正式要求"
            XCTAssertTrue(DItemStore.create(demand, at: cache))
            let before = try Data(contentsOf: cache)
            let session = DemandPromptDraftSession(id: demand.id, prompt: demand.prompt,
                store: DemandPromptDraftStore(url: directory.appendingPathComponent("drafts.json")))
            session.sections.intent = "还没决定的新要求"
            XCTAssertEqual(try Data(contentsOf: cache), before)
            let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py").path
            let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path, "context", "D014"])
            XCTAssertEqual(result.exitCode, 0)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
            let context = try XCTUnwrap(json["context"] as? String)
            XCTAssertTrue(context.contains("已保存的正式要求"))
            XCTAssertFalse(context.contains("还没决定的新要求"))
            XCTAssertEqual(try Data(contentsOf: cache), before)
        }
    }

    func testRestoredDraftKeepsItsOriginalBaselineAndCannotOverwriteNewPrompt() throws {
        try withDirectory { directory in
            let cache = directory.appendingPathComponent("cache.md")
            let drafts = directory.appendingPathComponent("drafts.json")
            try "## 🟡 重要\n".write(to: cache, atomically: true, encoding: .utf8)
            var demand = DItemDraft(newID: "D014", priority: .p1)
            demand.name = "并发修改保护"
            demand.promptSections.intent = "原始要求"
            XCTAssertTrue(DItemStore.create(demand, at: cache))
            let session = DemandPromptDraftSession(id: demand.id, prompt: demand.prompt,
                store: DemandPromptDraftStore(url: drafts))
            session.sections.intent = "未保存的草稿"
            let newer = DemandPromptSections(intent: "期间另存的新要求").stored
            XCTAssertTrue(DItemStore.savePrompt(id: demand.id, text: newer, expected: demand.prompt, at: cache))
            let restored = DemandPromptDraftSession(id: demand.id, prompt: newer, store: DemandPromptDraftStore(url: drafts))
            XCTAssertEqual(restored.originalPrompt, demand.prompt)
            XCTAssertEqual(restored.sections.intent, "未保存的草稿")
            XCTAssertFalse(DItemStore.savePrompt(id: demand.id, text: restored.sections.stored,
                expected: restored.originalPrompt, at: cache))
            XCTAssertEqual(DemandPromptDraftStore(url: drafts).drafts[demand.id]?.sections, restored.sections)
            XCTAssertEqual(try DItemStore.currentItem(id: demand.id, at: cache).prompt, newer)
        }
    }

    func testSaveInterruptedBeforeCleanupReconcilesWithTheSavedPrompt() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let session = DemandPromptDraftSession(id: "D014", prompt: "旧要求", store: DemandPromptDraftStore(url: file))
            session.sections.intent = "已经成功保存的要求"
            let savedPrompt = session.sections.stored
            let store = DemandPromptDraftStore(url: file)
            let reopened = DemandPromptDraftSession(id: "D014", prompt: savedPrompt, store: store)
            XCTAssertFalse(reopened.restored)
            XCTAssertFalse(reopened.changed)
            XCTAssertEqual(reopened.sections, session.sections)
            XCTAssertNil(DemandPromptDraftStore(url: file).drafts["D014"])
        }
    }

    func testExplicitDiscardClearsOnlyTheDraftAndIgnoresLateCallbacks() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let store = DemandPromptDraftStore(url: file)
            let session = DemandPromptDraftSession(id: "D014", prompt: "保留原咒言", store: store)
            session.sections.intent = "放弃的修改"
            XCTAssertTrue(session.discard())
            session.sections.intent = "迟到的编辑事件"
            session.preserve()
            let reopened = DemandPromptDraftSession(id: "D014", prompt: "保留原咒言",
                store: DemandPromptDraftStore(url: file))
            XCTAssertFalse(reopened.restored)
            XCTAssertEqual(reopened.sections.intent, "保留原咒言")
        }
    }

    func testWriteFailureRetainsDraftForReopeningInTheSameApp() throws {
        try withDirectory { directory in
            let blocked = directory.appendingPathComponent("not-a-directory")
            try Data().write(to: blocked)
            let store = DemandPromptDraftStore(url: blocked.appendingPathComponent("drafts.json"))
            let session = DemandPromptDraftSession(id: "D014", prompt: "", store: store)
            session.sections.intent = "磁盘写入失败也保留输入"
            XCTAssertNotNil(session.error)
            let reopened = DemandPromptDraftSession(id: "D014", prompt: "", store: store)
            XCTAssertEqual(reopened.sections, session.sections)
            XCTAssertFalse(reopened.discard())
            XCTAssertEqual(store.drafts["D014"]?.sections.intent, session.sections.intent)
        }
    }

    func testCorruptDraftFileIsPreservedAndOpeningWithoutEditsCreatesNoDraft() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("drafts.json")
            let initial = DemandPromptDraftSession(id: "D014", prompt: "正式咒言", store: DemandPromptDraftStore(url: file))
            XCTAssertTrue(initial.preserve())
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            let corrupt = Data("无法读取的草稿".utf8)
            try corrupt.write(to: file)
            let store = DemandPromptDraftStore(url: file)
            let session = DemandPromptDraftSession(id: "D014", prompt: "", store: store)
            session.sections.intent = "当前输入"
            XCTAssertNotNil(session.error)
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
            XCTAssertEqual(DemandPromptDraftSession(id: "D014", prompt: "", store: store).sections.intent, "当前输入")
        }
    }
}
