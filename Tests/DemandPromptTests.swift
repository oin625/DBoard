import XCTest
@testable import DBoard

final class DemandPromptTests: XCTestCase {
    private let cache = "## 🔴 紧急\n\n## 🟡 重要\n\n## 🟠 其他\n\n## 🟢 其他\n"
    private let prompt = "\n## 背景\n### D002【示例】不要变成需求 #待开始\n## 🔴 示例标题\n- **描述**：这是提示词中的示例\n---\n\n```swift\n    let value = 1\n```\n目标：保留原文  \n\n"

    private func withFile(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardPromptTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.md")
        try cache.write(to: file, atomically: true, encoding: .utf8)
        try body(file)
    }

    private func items(_ file: URL) throws -> [DItem] {
        CacheParser.parse(content: try String(contentsOf: file, encoding: .utf8)).items
    }

    func testCreateRoundTripsMarkdownWhitespaceAndIndependentItems() throws {
        try withFile { file in
            var draft = DItemDraft(newID: "D001", priority: .p1)
            draft.name = "准备上下文"
            draft.desc = "第一行\n第二行"
            draft.prompt = prompt
            XCTAssertTrue(DItemStore.create(draft, at: file))
            var next = DItemDraft(newID: "D002", priority: .p0)
            next.name = "下一需求"
            XCTAssertTrue(DItemStore.create(next, at: file))
            let parsed = try items(file)
            XCTAssertEqual(parsed.count, 2)
            XCTAssertEqual(parsed.first { $0.id == "D001" }?.prompt, prompt)
            XCTAssertEqual(parsed.first { $0.id == "D001" }?.title, draft.desc)
            XCTAssertEqual(parsed.first { $0.id == "D002" }?.prompt, "")
            XCTAssertEqual(parsed.first { $0.id == "D002" }?.displayTitle, "下一需求")
        }
    }

    func testEditMoveDeleteAndRestorePreserveEntirePrompt() throws {
        try withFile { file in
            var draft = DItemDraft(newID: "D001", priority: .p1)
            draft.name = "上下文"
            draft.prompt = prompt
            XCTAssertTrue(DItemStore.create(draft, at: file))
            let original = try XCTUnwrap(items(file).first)
            var edit = DItemDraft(from: original)
            edit.desc = "更新描述\n保留第二行"
            edit.priority = .p0
            edit.branch = "feature/prompt"
            edit.reqFlow = ReqFlowLink(id: 42, no: "R1001")
            XCTAssertTrue(DItemStore.save(edit, original: original, at: file))
            let moved = try XCTUnwrap(items(file).first)
            XCTAssertEqual(moved.prompt, prompt)
            XCTAssertEqual(moved.title, edit.desc)
            XCTAssertEqual(moved.priority, .p0)
            let removed = try XCTUnwrap(DItemStore.delete(id: moved.id, at: file))
            XCTAssertTrue(try items(file).isEmpty)
            XCTAssertTrue(DItemStore.restore(removed, id: moved.id, priority: moved.priority, at: file))
            XCTAssertEqual(try items(file).first?.prompt, prompt)
            edit = DItemDraft(from: try XCTUnwrap(items(file).first))
            let restored = try XCTUnwrap(items(file).first)
            edit.prompt = "替换的上下文\n\n"
            XCTAssertTrue(DItemStore.save(edit, original: restored, at: file))
            XCTAssertEqual(try items(file).first?.prompt, edit.prompt)
        }
    }

    func testDedicatedSavePreservesOtherEditsAndRejectsConflictingPrompt() throws {
        try withFile { file in
            var draft = DItemDraft(newID: "D001", priority: .p1)
            draft.name = "上下文"
            XCTAssertTrue(DItemStore.create(draft, at: file))
            let original = try XCTUnwrap(items(file).first)
            var otherEdit = DItemDraft(from: original)
            otherEdit.name = "同时更新标题"
            otherEdit.branch = "feature/latest"
            XCTAssertTrue(DItemStore.save(otherEdit, original: original, at: file))
            XCTAssertTrue(DItemStore.savePrompt(id: original.id, text: prompt, expected: "", at: file))
            let updated = try XCTUnwrap(items(file).first)
            XCTAssertEqual(updated.displayTitle, otherEdit.name)
            XCTAssertEqual(updated.branch, otherEdit.branch)
            XCTAssertEqual(updated.prompt, prompt)
            let before = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(DItemStore.savePrompt(id: original.id, text: "旧窗口的修改", expected: "", at: file))
            var staleEdit = DItemDraft(from: original)
            staleEdit.prompt = "旧通用表单"
            XCTAssertFalse(DItemStore.save(staleEdit, original: original, at: file))
            XCTAssertFalse(DItemStore.savePrompt(id: "D404", text: prompt, expected: "", at: file))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
            XCTAssertTrue(DItemStore.savePrompt(id: original.id, text: "", expected: prompt, at: file))
            XCTAssertEqual(try items(file).first?.prompt, "")
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("- **提示词**"))
        }
    }

    func testBlockLookupIgnoresDemandHeadersInsideAnotherPrompt() throws {
        let text = "## 🟡 重要\n### D001【测试】第一条 #待开始\n- **提示词**：\n    ### D002【示例】示例 #待开始\n    ---\n    \n\n### D002【测试】真正的第二条 #待开始\n- **描述**：第二条\n"
        let lines = text.components(separatedBy: "\n")
        let range = try XCTUnwrap(DItemStore.blockRange(lines, id: "D002"))
        XCTAssertEqual(lines[range.lowerBound], "### D002【测试】真正的第二条 #待开始")
        XCTAssertEqual(CacheParser.parse(content: text).items.count, 2)
    }

    func testOldCacheDefaultsToEmptyAndUnavailableFileFails() {
        XCTAssertEqual(CacheParser.parse(content: "## 🟡 重要\n### D001【测试】旧需求 #待开始\n- **描述**：原描述").items.first?.prompt, "")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cache.md")
        XCTAssertFalse(DItemStore.savePrompt(id: "D001", text: "不要丢失输入", expected: "", at: missing))
    }
}
