import XCTest
import Foundation
@testable import DBoard

final class DemandIncidentTests: XCTestCase {
    private func sourceBlock(id: String, at cache: URL) throws -> [String] {
        let lines = try String(contentsOf: cache, encoding: .utf8).components(separatedBy: "\n")
        return Array(lines[try XCTUnwrap(DItemStore.blockRange(lines, id: id))])
    }
    func testIncidentCreationMoveClosureReopenAndLegacyDraftCompatibility() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardIncident-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache.md")
        try "## 🔴 重要且紧急\n\n## 🟡 重要不紧急\n".write(to: cache, atomically: true, encoding: .utf8)
        var draft = DItemDraft(newID: "D014", priority: .p0)
        draft.kind = .incident; draft.name = "照片为空"; draft.desc = "查照片返回空，需核对原始响应"
        draft.status = .inProgress
        XCTAssertTrue(DItemStore.create(draft, at: cache))
        var item = try DItemStore.currentItem(id: "D014", at: cache)
        XCTAssertTrue(item.isIncident)
        XCTAssertEqual(item.priority, .p0)
        XCTAssertNil(item.reqFlow)
        XCTAssertFalse(DemandCompletionGate.needsEmptyChecklistConfirmation(item))
        XCTAssertTrue(DItemStore.setPriority(id: item.id, .p1, at: cache, expectedPriority: .p0))
        item = try DItemStore.currentItem(id: item.id, at: cache)
        XCTAssertTrue(item.isIncident)
        XCTAssertEqual(item.priority, .p1)
        let original = try sourceBlock(id: item.id, at: cache)
        XCTAssertTrue(DItemStore.closeIncident(id: item.id, expected: original, outcome: .handedOff,
                                             summary: "已交给上游核对照片配置", at: cache))
        item = try DItemStore.currentItem(id: item.id, at: cache)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.incidentClosure?.outcome, .handedOff)
        XCTAssertTrue(item.milestones.last?.details.contains("照片配置") == true)
        XCTAssertTrue(DemandMatrix.openItems([item]).isEmpty)
        XCTAssertTrue(DemandFilter.completed.includes(item))
        XCTAssertTrue(DemandFilter.incidents.includes(item))
        let before = try Data(contentsOf: cache)
        XCTAssertFalse(DItemStore.closeIncident(id: item.id, expected: original, outcome: .resolved, summary: "旧页面不应覆盖", at: cache))
        XCTAssertEqual(try Data(contentsOf: cache), before)
        let completed = try sourceBlock(id: item.id, at: cache)
        XCTAssertTrue(DItemStore.reopenIncident(id: item.id, expected: completed, at: cache))
        item = try DItemStore.currentItem(id: item.id, at: cache)
        XCTAssertEqual(item.status, .inProgress)
        XCTAssertEqual(item.milestones.count, 1)
        XCTAssertNotNil(item.incidentClosure)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String: Any]
        json.removeValue(forKey: "kind")
        let legacy = try JSONDecoder().decode(DItemDraft.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.effectiveKind, .development)
    }

    func testOpenReleaseActionsStillBlockIncidentClosureAndInvalidKindsDoNotBecomeNormalTasks() throws {
        var item = DItem(id: "D014", project: "ultra", title: "", headerTitle: "排查", status: .inProgress,
                         priority: .p0, deadline: nil, branch: nil, startDate: nil, milestones: [])
        item.kind = .incident
        item.releaseChecklist = try JSONDecoder().decode(DemandReleaseChecklist.self, from: Data(#"""
        {"items":[{"id":"L001","text":"发布Ultra修复","done":false,"updated_by":"ai","category":"release","details":"","evidence":""}],"next_id":2,"excluded_by_user":[],"reviewed_scope":null}
        """#.utf8))
        XCTAssertNotNil(DemandCompletionGate.localIssue(item))
        XCTAssertThrowsError(try DemandIncident.kind(["### D014【】排查 #进行中", "- **类型**：未知类型"]))
        XCTAssertThrowsError(try DemandIncident.kind(["- **类型**：线上排查", "- **类型**：开发需求"]))
    }

    func testCLIClosureDisplaysAsCompletedAndNativeReopenKeepsConclusion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardIncidentClose-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache.md")
        try "## 🔴 重要且紧急\n### P001【ultra】线上排查测试 #进行中\n- **类型**：线上排查\n- **描述**：接口响应异常\n"
            .write(to: cache, atomically: true, encoding: .utf8)
        let item = try DItemStore.currentItem(id: "P001", at: cache)
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/dboard_ai.py").path
        let shown = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path, "show", item.id])
        XCTAssertEqual(shown.exitCode, 0)
        let response = try JSONSerialization.jsonObject(with: shown.stdout) as! [String: Any]
        let revision = (response["item"] as! [String: Any])["revision"] as! String
        let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path,
            "incident", "close", item.id, "--expect-title", item.displayTitle, "--expect-revision", revision,
            "--outcome", "handed-off", "--summary", "已定位为上游配置缺失，交由上游处理。",
            "--details", "证据：原始响应。"])
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.stdout, as: UTF8.self))
        let closed = try DItemStore.currentItem(id: item.id, at: cache)
        XCTAssertEqual(closed.status, .completed)
        XCTAssertEqual(closed.incidentClosure?.outcome, .handedOff)
        XCTAssertEqual(closed.incidentClosure?.summary, "已定位为上游配置缺失，交由上游处理。")
        XCTAssertEqual(closed.milestones.last?.details, "证据：原始响应。")
        XCTAssertTrue(DemandFilter.completed.includes(closed))
        XCTAssertTrue(DemandMatrix.openItems([closed]).isEmpty)
        XCTAssertTrue(DItemStore.reopenIncident(id: item.id, expected: try sourceBlock(id: item.id, at: cache), at: cache))
        let reopened = try DItemStore.currentItem(id: item.id, at: cache)
        XCTAssertEqual(reopened.status, .inProgress)
        XCTAssertEqual(reopened.incidentClosure, closed.incidentClosure)
        XCTAssertEqual(reopened.milestones.map(\.content), closed.milestones.map(\.content))
        XCTAssertEqual(reopened.milestones.map(\.details), closed.milestones.map(\.details))
    }

    func testPythonExperienceCodecUserCorrectionsAndAtomicConflict() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardKnowledge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache.md")
        try "## 🔴 重要且紧急\n### P001【ultra】线上排查测试 #进行中\n- **类型**：线上排查\n- **描述**：接口响应为HTML\n".write(to: cache, atomically: true, encoding: .utf8)
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py").path
        func run(_ arguments: [String]) throws -> [String: Any] {
            let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path] + arguments)
            XCTAssertEqual(result.exitCode, 0, String(decoding: result.stdout, as: UTF8.self))
            return try JSONSerialization.jsonObject(with: result.stdout) as! [String: Any]
        }
        let item = try run(["show", "P001"])["item"] as! [String: Any]
        let native = try DItemStore.currentItem(id: "P001", at: cache)
        XCTAssertTrue(DboardAITaskContext.readInstruction(item: native).contains("context 'P001'"))
        XCTAssertTrue(try DemandOverview.render(String(contentsOf: cache, encoding: .utf8)).contains("### P001"))
        let handoff = dir.appendingPathComponent("handoff.json")
        try JSONSerialization.data(withJSONObject: ["based_on_records": 0,
            "sections": ["completed": "已核对原始响应", "pending": "凭证尚待核验", "decisions": "先看原始响应",
                         "verification": "仅核对查法"], "references": []]).write(to: handoff)
        let experience = dir.appendingPathComponent("experience.json")
        try JSONSerialization.data(withJSONObject: ["title": "核对登录态", "mechanism": "登录态失效",
            "symptoms": ["响应为HTML"], "scopes": ["Ultra查询"], "procedure": "核对响应类型，再检查请求头",
            "finding": "", "confidence": "method", "boundaries": "根因尚未确认", "evidence": ["原始日志"],
            "related_ids": []]).write(to: experience)
        _ = try run(["report", "P001", "--expect-title", item["title"] as! String, "--expect-revision", item["revision"] as! String,
            "--handoff-file", handoff.path, "--compression-decision", "skip", "--compression-reason", "状态够用",
            "--experience-decision", "create", "--experience-reason", "查法已有依据", "--experience-file", experience.path,
            "--event-id", "cross-language", "--no-sync"])
        var catalog = try DemandKnowledge.read(String(contentsOf: cache, encoding: .utf8).components(separatedBy: "\n"))
        var entry = try XCTUnwrap(catalog.entries.first)
        let python = try run(["knowledge", "read", entry.id])["experience"] as! [String: Any]
        XCTAssertEqual(entry.revision, python["revision"] as? String)
        XCTAssertEqual(entry.sources.first?.id, "P001")
        XCTAssertEqual(entry.sources.first?.scope_hash, try DItemStore.currentItem(id: "P001", at: cache).executionScope)
        let expected = entry.revision
        entry.boundaries = "用户纠正：不能据HTML断定凭证过期"
        entry.evidence.append("")
        XCTAssertTrue(DItemStore.saveKnowledge(entry, expected: expected, at: cache))
        catalog = try DemandKnowledge.read(String(contentsOf: cache, encoding: .utf8).components(separatedBy: "\n"))
        let corrected = try XCTUnwrap(catalog.entries.first)
        XCTAssertEqual(corrected.updated_by, "user")
        XCTAssertEqual(corrected.evidence, ["原始日志"])
        let roundtrip = try run(["knowledge", "read", entry.id])["experience"] as! [String: Any]
        XCTAssertEqual(corrected.revision, roundtrip["revision"] as? String)
        let before = try Data(contentsOf: cache)
        XCTAssertFalse(DItemStore.saveKnowledge(entry, expected: expected, at: cache))
        XCTAssertEqual(try Data(contentsOf: cache), before)
        let block = try sourceBlock(id: "P001", at: cache)
        XCTAssertTrue(DItemStore.closeIncident(id: "P001", expected: block, outcome: .stopped,
                                             summary: "保留已核对查法，等待新证据", at: cache))
        let closed = try run(["context", "P001"])
        XCTAssertEqual((closed["experience_review"] as? [String: Any])?["required"] as? Bool, false)
        XCTAssertEqual(try DemandKnowledge.read(String(contentsOf: cache, encoding: .utf8).components(separatedBy: "\n")).entries, catalog.entries)
        XCTAssertTrue(DemandFilter.completed.includes(try DItemStore.currentItem(id: "P001", at: cache)))
    }
}
