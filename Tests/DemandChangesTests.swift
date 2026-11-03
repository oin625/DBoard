import XCTest
import Foundation
import AppKit
@testable import DBoard

final class DemandChangesTests: XCTestCase {
    private func fixture() throws -> (URL, URL, DItem) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardChanges-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cache.md")
        try "## 🟡 重要\n".write(to: file, atomically: true, encoding: .utf8)
        var draft = DItemDraft(newID: "D014", priority: .p1)
        draft.name = "锁券改造"
        draft.desc = "原始需求说明"
        draft.branch = "feature/lock-coupon"
        draft.promptSections.intent = "拆出锁券接口"
        XCTAssertTrue(DItemStore.create(draft, at: file))
        XCTAssertTrue(DItemStore.appendProgress(id: "D014", text: "开发完成，尚未联调验收", at: file))
        return (directory, file, try DItemStore.currentItem(id: "D014", at: file))
    }

    func testMultipleChangeSpellsPreserveOriginalTaskAndNestedMarkdown() throws {
        let (directory, file, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let intent = "增加照片字段\n\n## 🟢 低优先级\n### D999【其他】不应成为新需求\n    保留缩进"
        let first = try XCTUnwrap(DItemStore.appendChange(id: "D014", intent: intent, at: file))
        let second = try XCTUnwrap(DItemStore.appendChange(id: "D014", intent: "补充重试限制", at: file))
        XCTAssertEqual(first.id, "C001")
        XCTAssertEqual(second.id, "C002")
        let parsed = CacheParser.parse(content: try String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(parsed.items.count, 1)
        let updated = try DItemStore.currentItem(id: "D014", at: file)
        XCTAssertEqual(updated.changes.map(\.intent), [intent, "补充重试限制"])
        XCTAssertEqual(updated.prompt, original.prompt)
        XCTAssertEqual(updated.branch, original.branch)
        XCTAssertEqual(updated.status, original.status)
        XCTAssertEqual(updated.milestones.map(\.content), original.milestones.map(\.content))
        var edit = DItemDraft(from: updated)
        edit.desc = "调整描述"
        XCTAssertTrue(DItemStore.save(edit, original: updated, at: file))
        XCTAssertEqual(try DItemStore.currentItem(id: "D014", at: file).changes, updated.changes)
    }

    @MainActor
    func testCopySelectedChangeIncludesFreshStateAndIdentifiesThisRound() throws {
        let (directory, file, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try XCTUnwrap(DItemStore.appendChange(id: "D014", intent: "增加照片字段", at: file))
        let selected = try XCTUnwrap(DItemStore.appendChange(id: "D014", intent: "本次增加超时重试", at: file))
        let flow = BizMapViewModel(loadBackgroundData: false,
            projectStore: DevelopmentProjectStore(url: directory.appendingPathComponent("projects.json")))
        let vm = DBoardViewModel(loadCache: false, reqFlow: flow)
        vm.items = [original]
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(vm.copyChangeState("D014", changeID: selected.id, at: file, pasteboard: clipboard))
        let copied = try XCTUnwrap(clipboard.string(forType: .string))
        XCTAssertTrue(copied.contains("context 'D014' --change 'C002'"))
        XCTAssertFalse(copied.contains("本次增加超时重试"))
        XCTAssertFalse(copied.contains("增加照片字段"))
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/dboard_ai.py").path
        let read = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", file.path,
            "context", "D014", "--change", selected.id])
        XCTAssertEqual(read.exitCode, 0)
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: read.stdout) as? [String: Any])
        let context = try XCTUnwrap(response["context"] as? String)
        XCTAssertTrue(context.contains("## 本次追加变更 C002"))
        XCTAssertEqual(context.components(separatedBy: "本次增加超时重试").count, 2)
        XCTAssertTrue(context.contains("增加照片字段"))
        XCTAssertTrue(context.contains("feature/lock-coupon"))
        XCTAssertTrue(context.contains("尚未联调验收"))
        XCTAssertTrue(context.contains("每轮写回进度时带上 [C002]"))
        XCTAssertFalse(vm.copyChangeState("D014", changeID: "C999", at: file, pasteboard: clipboard))
        XCTAssertEqual(clipboard.string(forType: .string), copied)
    }

    func testCorruptChangeDataCannotBeOverwrittenOrSilentlyOmittedFromHandoff() throws {
        let (directory, file, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try XCTUnwrap(DItemStore.appendChange(id: "D014", intent: "已保存的变更", at: file))
        let content = try String(contentsOf: file, encoding: .utf8)
        let corrupt = content.replacingOccurrences(of: "    已保存的变更", with: "    外部改过的变更")
        try corrupt.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DItemStore.currentItem(id: "D014", at: file))
        XCTAssertNil(DItemStore.appendChange(id: "D014", intent: "不应覆盖", at: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), corrupt)
    }

    func testLongDemandIDsDoNotAliasAnotherDemandInCopiedState() throws {
        let (directory, file, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try String(contentsOf: file, encoding: .utf8)
        try (original + "\n### D0140【fixture】另一张需求 #进行中\n- **描述**：不能混入\n")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try DItemStore.currentItem(id: "D014", at: file).id, "D014")
        XCTAssertEqual(try DItemStore.currentItem(id: "D0140", at: file).displayTitle, "另一张需求")
    }

    func testCLIReadsAndReportsChangesWithoutRewritingTheirSpells() throws {
        let (directory, file, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try XCTUnwrap(DItemStore.appendChange(id: "D014", intent: "补充照片查询\n保留原有联调待办", at: file))
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/dboard_ai.py").path
        let read = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", file.path, "show", "D014"])
        XCTAssertEqual(read.exitCode, 0)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: read.stdout) as? [String: Any])
        let item = try XCTUnwrap(json["item"] as? [String: Any])
        let changes = try XCTUnwrap(item["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.first?["id"] as? String, "C001")
        XCTAssertEqual(changes.first?["intent"] as? String, "补充照片查询\n保留原有联调待办")
        let revision = try XCTUnwrap(item["revision"] as? String)
        let progress = "[C001] 已做：照片查询；待做：联调；验证：未执行"
        let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", file.path, "report", "D014",
            "--expect-title", "锁券改造", "--expect-revision", revision, "--progress", progress,
            "--event-id", "change-round", "--no-sync"])
        XCTAssertEqual(result.exitCode, 0, String(data: result.stdout, encoding: .utf8) ?? "")
        let updated = try DItemStore.currentItem(id: "D014", at: file)
        XCTAssertEqual(updated.changes.count, 1)
        let contextRead = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", file.path,
            "context", "D014", "--change", "C001"])
        XCTAssertEqual(contextRead.exitCode, 0)
        let contextJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: contextRead.stdout) as? [String: Any])
        XCTAssertTrue((contextJSON["context"] as? String)?.contains(progress) == true)
    }
}
