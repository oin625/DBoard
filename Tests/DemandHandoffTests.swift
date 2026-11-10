import XCTest
import Foundation
@testable import DBoard

final class DemandHandoffTests: XCTestCase {
    func testPythonSnapshotAndUserNotesPreserveScopeHistoryAndConcurrentUpdates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardHandoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache.md")
        let source = "## 🟡 重要\n### D014【ultra】交接测试 #进行中\n- **描述**：原背景\n- **进度**：\n    - 11.1: 原记录\n"
        try source.write(to: cache, atomically: true, encoding: .utf8)
        let original = try DItemStore.currentItem(id: "D014", at: cache)
        let overview = try DemandOverview.hash(source)
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py").path
        let read = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path, "show", "D014"])
        let item = try XCTUnwrap((try JSONSerialization.jsonObject(with: read.stdout) as? [String: Any])?["item"] as? [String: Any])
        let handoff = dir.appendingPathComponent("summary.json")
        let value: [String: Any] = ["based_on_records": 1, "sections": ["completed": "接口已完成",
            "pending": "待外部联调，当前无开发待办", "decisions": "锁券前查券", "verification": "真实券码尚未验证"], "references": ["record:1"], "resources": [["topic": "锁券失败", "source": "record:1", "when_to_read": "排查锁券异常时"]]]
        try JSONSerialization.data(withJSONObject: value).write(to: handoff)
        let report = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path, "report", "D014",
            "--expect-title", item["title"] as! String, "--expect-revision", item["revision"] as! String,
            "--handoff-file", handoff.path, "--compression-decision", "compact", "--compression-reason", "首次整理历史", "--no-sync"])
        XCTAssertEqual(report.exitCode, 0, String(decoding: report.stdout, as: UTF8.self))
        var current = try DItemStore.currentItem(id: "D014", at: cache)
        XCTAssertEqual(current.handoff?.sections.pending, "待外部联调，当前无开发待办")
        XCTAssertEqual(current.handoff?.covered_count, 1)
        XCTAssertEqual(current.handoff?.policy, "task-state-v2")
        XCTAssertEqual(current.handoff?.resources?.first?.when_to_read, "排查锁券异常时")
        XCTAssertEqual(current.executionScope, original.executionScope)
        XCTAssertEqual(current.milestones.count, 1)
        XCTAssertEqual(try DemandOverview.hash(String(contentsOf: cache, encoding: .utf8)), overview)
        XCTAssertTrue(DItemStore.saveHandoffNotes(id: "D014", text: "用户纠正：退款未测\n等待真实数据", expected: "", at: cache))
        XCTAssertTrue(DItemStore.appendProgress(id: "D014", text: "另一轮反馈", at: cache))
        current = try DItemStore.currentItem(id: "D014", at: cache)
        XCTAssertEqual(current.handoffNotes, "用户纠正：退款未测\n等待真实数据")
        XCTAssertEqual(current.executionScope, original.executionScope)
        XCTAssertEqual(current.handoff?.covered_count, 1)
        let before = try Data(contentsOf: cache)
        XCTAssertFalse(DItemStore.saveHandoffNotes(id: "D014", text: "过期覆盖", expected: "", at: cache))
        XCTAssertEqual(try Data(contentsOf: cache), before)
        let longCorrection = String(repeating: "必须保留的用户纠正。", count: 600)
        XCTAssertTrue(DItemStore.saveHandoffNotes(id: "D014", text: longCorrection, expected: current.handoffNotes, at: cache))
        XCTAssertEqual(try DItemStore.currentItem(id: "D014", at: cache).handoffNotes, longCorrection)
        XCTAssertTrue(DItemStore.saveHandoffNotes(id: "D014", text: "", expected: longCorrection, at: cache))
        XCTAssertEqual(try DItemStore.currentItem(id: "D014", at: cache).handoffNotes, "")
        var edited = DItemDraft(from: current)
        edited.desc = "只改描述"
        XCTAssertTrue(DItemStore.save(edited, original: current, at: cache))
        XCTAssertEqual(try DItemStore.currentItem(id: "D014", at: cache).handoff?.sections.completed, "接口已完成")
    }

    func testUnsavedCorrectionsCanBeRestoredWithoutChangingTheExpectedSource() throws {
        let suite = "DBoardHandoffDraft-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DemandHandoffDraft.persist(["D014": .init(text: "还没写完的修正\n明天确认", expected: "此前补充")], defaults: defaults)
        let restored = DemandHandoffDraft.load(defaults: defaults)
        XCTAssertEqual(restored["D014"]?.text, "还没写完的修正\n明天确认")
        XCTAssertEqual(restored["D014"]?.expected, "此前补充")
        DemandHandoffDraft.persist([:], defaults: defaults)
        XCTAssertTrue(DemandHandoffDraft.load(defaults: defaults).isEmpty)
    }

    func testCorruptOrDuplicateSnapshotCannotAppearAsValidAndIndentedNotesStayInsidePrompt() throws {
        let block = ["### D014【ultra】测试 #进行中", "- **提示词**：", "    - **交接补充**：咒言内容"]
        XCTAssertEqual(DemandHandoff.notes(block), "")
        XCTAssertThrowsError(try DemandHandoff.read(block + [DemandHandoff.prefix + "broken -->"]))
        let parsed = CacheParser.parse(content: (["## 🟡 重要"] + block + [DemandHandoff.prefix + "broken -->"]).joined(separator: "\n"))
        XCTAssertNotNil(parsed.items.first?.handoffReadError)
    }
}
