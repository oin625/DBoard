import XCTest
import Foundation
import AppKit
@testable import DBoard

final class DemandArchiveTests: XCTestCase {
    private var directory: URL!
    private var cache: URL!
    private let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py").path

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardVersions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = directory.appendingPathComponent("active.md")
        try "## 🟡 重要\n### D050【fixture】其他需求 #进行中\n- **描述**：不要改动\n".write(to: cache, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func archive() throws -> ArchivedDemand {
        var block = ["### D014【ultra】锁券接口 #已完成 📅2026-10-20→🎯2026-10-25 ✅2026-10-30",
                     "- **分支**：feature/original", "- **描述**：旧版业务背景",
                     "- **进度**：", "    - 10.30: 原版已经实现；验收记录已保存",
                     "- 📝 10.30 完成 ✅"]
        DemandPrompt.set(&block, value: DemandPromptSections(codeEntry: "ultra车点点流程",
            materials: "https://example.com/旧版资料", intent: "原版拆出锁券\n\n    保留缩进").stored)
        try DemandChanges.set(&block, changes: [.init(id: "C001", createdAt: Date(), intent: "原版补充照片字段")])
        let metadata: [String: Any] = ["repositories": [["path": "/tmp/original-repo", "branch": "feature/original"]],
                                      "events": ["old-event": String(repeating: "a", count: 64)]]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        block.append("<!-- dboard-ai-feedback:v1:" + data.base64EncodedString() + " -->")
        return try XCTUnwrap(DemandArchive.parse(block.joined(separator: "\n")).first)
    }

    private func response(_ args: [String]) throws -> [String: Any] {
        let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path] + args)
        XCTAssertEqual(result.exitCode, 0, String(data: result.stdout, encoding: .utf8) ?? "")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
    }

    func testLegacyArchivesParseWithoutPriorityAndIgnoreIndentedHeadings() throws {
        let records = try DemandArchive.parse("""
        ### D008【muse】原模块 #已完成 ✅2026-06-24
        - **提示词**：
            ## 业务说明
            ### D999【嵌套】不是需求 #已完成
        - **进度**：
            - 6.24: 已上线

        ### D011【fixture】其他模块 #已完成 ✅2026-07-01
        - **描述**：第二个归档
        """)
        XCTAssertEqual(records.map { $0.item.id }, ["D011", "D008"])
        XCTAssertEqual(records.last?.item.displayTitle, "原模块")
        XCTAssertEqual(records.last?.completedDate, "2026-06-24")
        XCTAssertTrue(records.last?.item.prompt.contains("D999") == true)
        let repeated = try DemandArchive.parse(records[0].block.joined(separator: "\n") + "\n" + records[0].block.joined(separator: "\n"))
        XCTAssertEqual(repeated.count, 1)
    }

    func testNewVersionKeepsBaselineAndCLIReportsOnlyToNewDemand() throws {
        let old = try archive()
        let original = old.block
        let unrelated = try String(contentsOf: cache, encoding: .utf8)
        var draft = try old.newDraft(id: "D051")
        XCTAssertEqual(draft.name, "锁券接口 2.0")
        XCTAssertEqual(draft.promptSections.intent, "")
        XCTAssertEqual(draft.promptSections.codeEntry, "ultra车点点流程")
        XCTAssertNil(draft.reqFlow)
        draft.promptSections.intent = "本次增加超时重试"
        XCTAssertTrue(DItemStore.create(draft, at: cache))
        let saved = try DItemStore.currentItem(id: "D051", at: cache)
        XCTAssertEqual(saved.version?.parentID, "D014")
        XCTAssertEqual(saved.version?.rootID, "D014")
        XCTAssertEqual(saved.version?.number, 2)
        XCTAssertEqual(saved.version?.repositories.first?.path, "/tmp/original-repo")
        XCTAssertTrue(saved.version?.background.contains("原版已经实现") == true)
        XCTAssertTrue(saved.version?.background.contains("原版补充照片字段") == true)
        XCTAssertTrue(saved.milestones.isEmpty)
        XCTAssertTrue(saved.changes.isEmpty)
        XCTAssertFalse(saved.prompt.contains("原版拆出锁券"))
        let json = try response(["context", "D051"])
        let context = try XCTUnwrap(json["context"] as? String)
        XCTAssertTrue(context.contains("## 本轮版本 2.0"))
        XCTAssertTrue(context.contains("D014「锁券接口」"))
        XCTAssertTrue(context.contains("原版拆出锁券"))
        XCTAssertTrue(context.contains("本次增加超时重试"))
        XCTAssertTrue(context.contains("仅将本轮实际改动和验证结果写回 D051"))
        XCTAssertFalse(context.contains("dboard-version:v1:"))
        let item = try XCTUnwrap(json["item"] as? [String: Any])
        let report = try response(["report", "D051", "--expect-title", "锁券接口 2.0",
            "--expect-revision", try XCTUnwrap(item["revision"] as? String),
            "--progress", "2.0 已做：重试；待做：验收", "--event-id", "old-event", "--no-sync"])
        XCTAssertTrue(report["success"] as? Bool == true, "旧版事件不能影响新版本反馈")
        let latest = try DItemStore.currentItem(id: "D051", at: cache)
        XCTAssertEqual(latest.version, saved.version)
        XCTAssertEqual(latest.milestones.count, 1)
        XCTAssertEqual(old.block, original)
        XCTAssertTrue(try String(contentsOf: cache, encoding: .utf8).contains(unrelated.trimmed))
        var duplicate = draft
        duplicate.id = "D052"
        let before = try Data(contentsOf: cache)
        XCTAssertFalse(DItemStore.create(duplicate, at: cache))
        XCTAssertEqual(try Data(contentsOf: cache), before)
    }

    func testThirdVersionLinksToSecondAndRetainsRootBackground() throws {
        let old = try archive()
        var second = try old.newDraft(id: "D051")
        second.promptSections.intent = "第二版重试"
        XCTAssertTrue(DItemStore.create(second, at: cache))
        XCTAssertTrue(DItemStore.appendProgress(id: "D051", text: "第二版完成验收", at: cache))
        let content = try String(contentsOf: cache, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let range = try XCTUnwrap(DItemStore.blockRange(lines, id: "D051"))
        var block = Array(lines[range])
        block[0] = block[0].replacingOccurrences(of: "#进行中", with: "#已完成")
        let archived = try XCTUnwrap(DemandArchive.parse(block.joined(separator: "\n")).first)
        XCTAssertNotNil(DItemStore.delete(id: "D051", at: cache))
        var third = try archived.newDraft(id: "D052")
        third.promptSections.intent = "第三版增加审计"
        XCTAssertEqual(third.name, "锁券接口 3.0")
        XCTAssertEqual(third.version?.parentID, "D051")
        XCTAssertEqual(third.version?.rootID, "D014")
        XCTAssertEqual(third.version?.number, 3)
        XCTAssertTrue(third.version?.background.contains("第二版完成验收") == true)
        XCTAssertTrue(third.version?.background.contains("原版拆出锁券") == true)
        XCTAssertTrue(DItemStore.create(third, at: cache))
    }

    func testUndoArchivePreservesContentResetsCycleAndRejectsDuplicateID() throws {
        let old = try archive()
        let original = old.block
        XCTAssertTrue(DItemStore.reopenArchive(old, at: cache))
        let item = try DItemStore.currentItem(id: "D014", at: cache)
        XCTAssertEqual(item.status, .inProgress)
        XCTAssertEqual(item.startDate, DemandDates.today())
        XCTAssertNil(item.deadline)
        XCTAssertEqual(item.displayTitle, "锁券接口")
        XCTAssertEqual(item.prompt, old.item.prompt)
        XCTAssertEqual(item.changes, old.item.changes)
        XCTAssertEqual(item.branch, old.item.branch)
        XCTAssertEqual(item.milestones.count, old.item.milestones.count + 1)
        XCTAssertTrue(item.milestones.last?.content.contains("撤销归档") == true)
        let json = try response(["context", "D014"])
        XCTAssertTrue((json["context"] as? String)?.contains("原版拆出锁券") == true)
        let before = try Data(contentsOf: cache)
        XCTAssertFalse(DItemStore.reopenArchive(old, at: cache))
        XCTAssertEqual(try Data(contentsOf: cache), before)
        XCTAssertEqual(old.block, original)
    }

    func testRepeatedArchiveAndRestoreMergesHistoricalNotesAndRemainsReadableByCLI() throws {
        let first = try archive()
        XCTAssertTrue(DItemStore.reopenArchive(first, at: cache))
        let lines = try String(contentsOf: cache, encoding: .utf8).components(separatedBy: "\n")
        let range = try XCTUnwrap(DItemStore.blockRange(lines, id: "D014"))
        var block = Array(lines[range])
        block[0] = block[0].replacingOccurrences(of: "#进行中", with: "#已完成") + " ✅2026-10-30"
        block.append("- 📝 10.30 第二次完成 ✅")
        let second = try XCTUnwrap(DemandArchive.parse(block.joined(separator: "\n")).first)
        XCTAssertNotNil(DItemStore.delete(id: "D014", at: cache))
        XCTAssertTrue(DItemStore.reopenArchive(second, at: cache))
        let content = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "- **归档历史**").count, 2)
        let context = try XCTUnwrap(try response(["context", "D014"])["context"] as? String)
        XCTAssertTrue(context.contains("历史归档备注"))
        XCTAssertTrue(context.contains("第二次完成"))
        let nextArchive = try XCTUnwrap(DemandArchive.parse(content.replacingOccurrences(of: "#进行中", with: "#已完成")).first { $0.item.id == "D014" })
        XCTAssertTrue(try nextArchive.newDraft(id: "D051").version?.background.contains("第二次完成") == true)
    }

    func testCorruptVersionIsVisibleAsErrorAndCannotBeCopiedReopenedOrReported() throws {
        var block = (try archive()).block
        block.append("<!-- dboard-version:v1:invalid -->")
        let old = try XCTUnwrap(DemandArchive.parse(block.joined(separator: "\n")).first)
        XCTAssertNotNil(old.item.versionReadError)
        XCTAssertThrowsError(try old.newDraft(id: "D051"))
        XCTAssertFalse(DItemStore.reopenArchive(old, at: cache))
        let stored = "## 🟡 重要\n" + block.joined(separator: "\n")
        try stored.write(to: cache, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DItemStore.currentItem(id: "D014", at: cache))
        let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path, "context", "D014"])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(String(data: result.stdout, encoding: .utf8)?.contains("INVALID_VERSION_DATA") == true)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), stored)
    }

    func testArchiveCacheAndJournalStayAvailableOfflineAndBadResponseIsRejected() throws {
        let old = try archive()
        let journalURL = directory.appendingPathComponent("journal.json")
        let journal = ArchiveJournal(url: journalURL)
        XCTAssertTrue(journal.save(.init(id: old.item.id, original: old.block, archived: old.block,
            state: .removed, createdAt: Date())))
        let archiveCache = directory.appendingPathComponent("archive.md")
        let store = DemandArchiveStore(cache: archiveCache, journalURL: journalURL, allowsRemote: false)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertNotNil(store.records.first?.original)
        try old.block.joined(separator: "\n").write(to: archiveCache, atomically: true, encoding: .utf8)
        store.reloadLocal()
        XCTAssertEqual(store.records.count, 1, "远端与本机同一快照应合并")
        try old.block.joined(separator: "\n").replacingOccurrences(of: "- **进度**：", with: "- **进度**： ")
            .write(to: archiveCache, atomically: true, encoding: .utf8)
        store.reloadLocal()
        XCTAssertEqual(store.records.count, 1, "钉钉 Markdown 的空格变化不能造成重复归档")
        XCTAssertEqual(store.records.first?.id, old.id, "同一次归档优先保留本机无损快照")
        for value in [#"{"success":false,"markdown":"bad"}"#, #"{"success":true}"#, #"{"success":"true","markdown":"bad"}"#] {
            XCTAssertThrowsError(try DemandArchive.decodeResponse(Data(value.utf8)))
        }
        let content = try DemandArchive.decodeResponse(Data(#"{"success":true,"markdown":""}"#.utf8))
        XCTAssertTrue(content.isEmpty)
        store.refresh()
        XCTAssertFalse(store.loading)
    }
}
