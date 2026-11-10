import XCTest
import AppKit
@testable import DBoard

final class DemandReviewTaskTests: XCTestCase {
    @MainActor
    func testCopyReviewUsesLatestTargetAndPreservesDataAndClipboardOnMissingItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardCR-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache with 'quotes'.md")
        let source = "## 🟡\n### D014【ultra】原标题 #进行中\n- **描述**：原实现\n"
        try source.write(to: cache, atomically: true, encoding: .utf8)
        let vm = DBoardViewModel(loadCache: false)
        vm.items = CacheParser.parse(content: source).items
        try source.replacingOccurrences(of: "原标题", with: "新的已保存标题").write(to: cache, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: cache)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(vm.copyReviewTask("D014", at: cache, pasteboard: clipboard))
        let copied = try XCTUnwrap(clipboard.string(forType: .string))
        let parsed = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", "-c",
            "import shlex,json,sys; print(json.dumps(shlex.split(sys.argv[1])))",
            copied.components(separatedBy: "\n")[1]])
        XCTAssertEqual(parsed.exitCode, 0)
        let command = try XCTUnwrap(try JSONSerialization.jsonObject(with: parsed.stdout) as? [String])
        XCTAssertEqual(command, [NSHomeDirectory() + "/.local/bin/dboard-ai", "--cache", cache.path,
                                 "context", "D014", "--task", "code-review"])
        XCTAssertTrue(copied.contains("新的已保存标题"))
        XCTAssertEqual(try Data(contentsOf: cache), before)
        XCTAssertFalse(vm.copyReviewTask("D999", at: cache, pasteboard: clipboard))
        XCTAssertEqual(clipboard.string(forType: .string), copied)
    }

    @MainActor
    func testCompletedIncidentStillCopiesExplicitReviewMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardCR-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("dboard-archive-cache.md")
        try "## ✅ 已完成\n### P001【ultra】付款消息排查 #已完成\n- **类型**：线上排查\n".write(to: cache, atomically: true, encoding: .utf8)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let vm = DBoardViewModel(loadCache: false)
        XCTAssertTrue(vm.copyReviewTask("P001", at: cache, pasteboard: clipboard))
        XCTAssertTrue(try XCTUnwrap(clipboard.string(forType: .string)).contains("context 'P001' --task code-review"))
    }

    @MainActor
    func testArchivedCLIReviewIsVisibleWithoutChangingVersionIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardCRArchive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("dboard-archive-cache.md")
        let source = "## ✅ 已完成\n### D014【ultra】锁券接口 #已完成 ✅2026-11-06\n- **描述**：锁券链路\n- **进度**：\n    - 11.6: 已完成开发和验收。\n"
        try source.write(to: cache, atomically: true, encoding: .utf8)
        let record = try XCTUnwrap(try DemandArchive.parse(source).first)
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/dboard_ai.py").path
        let show = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path, "show", "D014", "--full"])
        XCTAssertEqual(show.exitCode, 0)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: show.stdout) as? [String: Any])
        let item = try XCTUnwrap(json["item"] as? [String: Any])
        let revision = try XCTUnwrap(item["revision"] as? String)
        XCTAssertEqual(revision, record.id)
        let handoff = root.appendingPathComponent("handoff.json")
        try JSONSerialization.data(withJSONObject: ["based_on_records": 1, "sections": [
            "completed": "原开发和验收已完成；本轮审查未覆盖代码。",
            "pending": "缺少实际开发仓库，需要补充后审查。",
            "decisions": "保留已完成状态和原归档快照。",
            "verification": "本轮仅核对需求记录，未审代码。"], "references": []]).write(to: handoff)
        let review = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path,
            "report", "D014", "--task", "code-review", "--review-result", "limited",
            "--expect-title", "锁券接口", "--expect-revision", revision,
            "--summary", "[CR] 缺少实际仓库，整体代码尚未覆盖。", "--details", "需补充开发仓库和分支，再核对完整提交范围。",
            "--handoff-file", handoff.path, "--compression-decision", "skip", "--compression-reason", "原归档内容明确，只新增审查边界。",
            "--event-id", "archive-cr-swift", "--no-sync"])
        XCTAssertEqual(review.exitCode, 0, String(data: review.stdout, encoding: .utf8) ?? "")
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), source)
        let store = DemandArchiveStore(cache: cache, journalURL: root.appendingPathComponent("journal.json"), allowsRemote: false)
        XCTAssertEqual(store.records.first?.id, record.id)
        XCTAssertEqual(store.reviewNotes.count, 1)
        XCTAssertEqual(store.reviewNotes.first?.sourceRevision, record.id)
        XCTAssertEqual(store.reviewNotes.first?.summary, "[CR] 缺少实际仓库，整体代码尚未覆盖。")
        XCTAssertEqual(store.reviewNotes.first?.details, "需补充开发仓库和分支，再核对完整提交范围。")
    }
}
