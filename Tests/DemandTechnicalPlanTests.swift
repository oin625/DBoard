import XCTest
@testable import DBoard

final class DemandTechnicalPlanTests: XCTestCase {
    private func document() -> DemandTechnicalPlan {
        DemandTechnicalPlan(title: "技术方案", markdown: "# 改造目标\n\n保留接口和失败处理。",
            projects: [.init(name: "ultra", branch: "feature/cdd")], scopeHash: String(repeating: "a", count: 64),
            codeRevision: String(repeating: "b", count: 64), updatedAt: "2026-11-09T09:00:00Z", updatedBy: "ai")
    }
    func testCodecIsCompatibleWithCLIAndInvalidRecordsArePreserved() throws {
        var block = ["### D900【ultra】锁券 #进行中", "- **项目**：ultra", "- **分支**：feature/cdd"]
        let value = document()
        try DemandTechnicalPlan.set(&block, value: value)
        XCTAssertEqual(try DemandTechnicalPlan.read(block), value)
        let encoded = try JSONEncoder().encode(block)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let python = "import sys,json;sys.path.insert(0,sys.argv[1]);import dboard_plan;p=dboard_plan.read(json.loads(sys.argv[2]));print(dboard_plan.signature(p))"
        let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", "-c", python, root.appendingPathComponent("Tools").path,
            String(decoding: encoded, as: UTF8.self)], timeout: 5)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self).trimmed, value.revision)
        let broken = [block[0], DemandTechnicalPlan.prefix + "bad -->"]
        XCTAssertThrowsError(try DemandTechnicalPlan.read(broken))
        XCTAssertEqual(broken[1], DemandTechnicalPlan.prefix + "bad -->")
    }

    func testUserEditsPreserveBindingsAndRejectConcurrentOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DboardPlanTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache.md")
        var block = ["### D900【ultra】锁券 #进行中", "- **项目**：ultra", "- **分支**：feature/cdd"]
        try DemandTechnicalPlan.set(&block, value: document())
        try ("## 🟡 重要\n" + block.joined(separator: "\n")).write(to: cache, atomically: true, encoding: .utf8)
        XCTAssertEqual(try DItemStore.currentItem(id: "D900", at: cache).technicalPlan, document())
        XCTAssertTrue(DItemStore.saveTechnicalPlan(id: "D900", markdown: "用户纠正后的方案", expectedRevision: document().revision, at: cache))
        let latest = try DItemStore.currentItem(id: "D900", at: cache).technicalPlan!
        XCTAssertEqual(latest.updatedBy, "user")
        XCTAssertEqual(latest.scopeHash, document().scopeHash)
        XCTAssertEqual(latest.codeRevision, document().codeRevision)
        XCTAssertFalse(DItemStore.saveTechnicalPlan(id: "D900", markdown: "旧稿覆盖", expectedRevision: document().revision, at: cache))
        XCTAssertEqual(try DItemStore.currentItem(id: "D900", at: cache).technicalPlan?.markdown, "用户纠正后的方案")
    }


    func testAppendingProgressKeepsBlankLinesInsideOriginalDetails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DboardProgressTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache.md")
        try "## 🟡 重要\n### D900【ultra】测试 #进行中\n- **进度**：\n    - 11.9: 原记录\n        明细：\n        第一段\n        \n        第二段\n- **分支**：feature/task".write(to: cache, atomically: true, encoding: .utf8)
        XCTAssertTrue(DItemStore.appendProgress(id: "D900", text: "新记录", details: "新明细", at: cache))
        let records = try DItemStore.currentItem(id: "D900", at: cache).milestones
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].details, "第一段\n\n第二段")
        XCTAssertEqual(records[1].details, "新明细")
    }

    func testCodeAndRequirementChangesInvalidatePlan() {
        var item = DItem(id: "D900", project: "ultra", title: "锁券", headerTitle: "锁券", status: .inProgress,
            priority: .p1, deadline: nil, branch: "feature/cdd", startDate: nil, milestones: [])
        item.executionScope = document().scopeHash
        XCTAssertNil(document().reviewReason(item: item, codeRevision: document().codeRevision))
        XCTAssertNotNil(document().reviewReason(item: item, codeRevision: String(repeating: "c", count: 64)))
        item.executionScope = String(repeating: "d", count: 64)
        XCTAssertNotNil(document().reviewReason(item: item, codeRevision: document().codeRevision))
        XCTAssertTrue(DboardAITaskContext.planInstruction(item: item).contains("--task technical-plan"))
    }
}
