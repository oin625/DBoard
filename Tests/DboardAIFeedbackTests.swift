import XCTest
import Foundation
import AppKit
@testable import DBoard

final class DboardAIFeedbackTests: XCTestCase {
    func testCopiedInstructionIsShortAndCarriesOnlyTaskReference() {
        let sections = DemandPromptSections(codeEntry: "ultra 车点点链路",
            materials: "可能有用的接口方案", intent: String(repeating: "很长的需求内容", count: 1000))
        let item = DItem(id: "D014", project: "ultra", title: "原始描述", headerTitle: "锁券接口",
                        status: .inProgress, priority: .p1, deadline: nil, branch: "feature/lock-coupon",
                        startDate: nil, milestones: [], prompt: sections.stored)
        let copied = DboardAITaskContext.readInstruction(item: item, home: "/Users/fixture")
        XCTAssertTrue(copied.contains("D014「锁券接口」"))
        XCTAssertTrue(copied.contains("'/Users/fixture/.local/bin/dboard-ai' context 'D014'"))
        XCTAssertTrue(copied.contains("每轮结束前"))
        XCTAssertEqual(copied.components(separatedBy: "\n").count, 3)
        XCTAssertLessThan(copied.count, 240)
        XCTAssertFalse(copied.contains("很长的需求内容"))
        XCTAssertFalse(copied.contains("feature/lock-coupon"))
        XCTAssertEqual(DemandPromptSections(stored: item.prompt), sections)
    }

    func testInstructionWorksWithoutSpellAndQuotesCacheAndChangeArguments() {
        let item = DItem(id: "D001", project: "", title: "", headerTitle: "新需求",
            status: .pending, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
        let copied = DboardAITaskContext.readInstruction(item: item, changeID: "C002",
            cacheURL: URL(fileURLWithPath: "/tmp/cache with 'quotes'.md"), home: "/Users/home with 'quotes'")
        XCTAssertTrue(copied.contains("D001「新需求」"))
        XCTAssertTrue(copied.contains("--cache"))
        XCTAssertTrue(copied.contains("--change 'C002'"))
        XCTAssertTrue(copied.contains("'\\''"))
        XCTAssertFalse(copied.contains("## 要做什么"))
    }

    @MainActor
    func testCopyReadsLatestSavedProgressAndKeepsClipboardOnMissingDemand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardCopy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.md")
        try "## 🟡 重要\n".write(to: file, atomically: true, encoding: .utf8)
        var draft = DItemDraft(newID: "D014", priority: .p1)
        draft.name = "交接需求"
        XCTAssertTrue(DItemStore.create(draft, at: file))
        let old = try DItemStore.currentItem(id: "D014", at: file)
        let flow = BizMapViewModel(loadBackgroundData: false,
            projectStore: DevelopmentProjectStore(url: directory.appendingPathComponent("projects.json")))
        let vm = DBoardViewModel(loadCache: false, reqFlow: flow)
        vm.items = [old]
        XCTAssertTrue(DItemStore.appendProgress(id: "D014", text: "已做：接口实现；待做：联调", at: file))
        let savedPrompt = DemandPromptSections(intent: "最新已保存咒言").stored
        XCTAssertTrue(DItemStore.savePrompt(id: "D014", text: savedPrompt, expected: old.prompt, at: file))
        let before = try Data(contentsOf: file)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(vm.copyCurrentState("D014", at: file, pasteboard: clipboard))
        let copied = try XCTUnwrap(clipboard.string(forType: .string))
        XCTAssertTrue(copied.contains("context 'D014'"))
        XCTAssertTrue(copied.contains(file.path))
        XCTAssertFalse(copied.contains("待做：联调"))
        XCTAssertFalse(copied.contains("最新已保存咒言"))
        XCTAssertTrue(old.prompt.isEmpty)
        XCTAssertTrue(old.milestones.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before)
        // Execute the exact generated command via a fixture CLI; later progress must be visible.
        let fixtureHome = directory.appendingPathComponent("home with spaces and 'quotes'")
        let bin = fixtureHome.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let sourceCLI = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/dboard_ai.py").path
        let wrapper = bin.appendingPathComponent("dboard-ai")
        let sourceQuote = "'" + sourceCLI.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try ("#!/bin/sh\nexec /usr/bin/env python3 " + sourceQuote + " \"$@\"\n")
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let instruction = DboardAITaskContext.readInstruction(item: old, cacheURL: file, home: fixtureHome.path)
        XCTAssertTrue(DItemStore.appendProgress(id: "D014", text: "复制之后新增的进度", at: file))
        let latestBytes = try Data(contentsOf: file)
        let read = HandoffCLIFixture.run("/bin/sh", arguments: ["-c", instruction.components(separatedBy: "\n")[1]])
        XCTAssertEqual(read.exitCode, 0, String(data: read.stdout, encoding: .utf8) ?? "")
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: read.stdout) as? [String: Any])
        let context = try XCTUnwrap(response["context"] as? String)
        XCTAssertTrue(context.contains("最新已保存咒言"))
        XCTAssertTrue(context.contains("待做：联调"))
        XCTAssertTrue(context.contains("复制之后新增的进度"))
        XCTAssertTrue((response["feedback_instructions"] as? String)?.contains("每完成一轮") == true)
        XCTAssertEqual(try Data(contentsOf: file), latestBytes)
        XCTAssertFalse(vm.copyCurrentState("D999", at: file, pasteboard: clipboard))
        XCTAssertEqual(clipboard.string(forType: .string), copied)
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(vm.copyCurrentState("D014", at: file, pasteboard: clipboard))
        XCTAssertEqual(clipboard.string(forType: .string), copied)
    }

    func testDuplicateDemandIDsCannotProduceAHandoff() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardCopyDuplicates-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.md")
        try "## 🟡 重要\n### D014【fixture】第一张 #进行中\n- **描述**：一\n### D014【fixture】第二张 #进行中\n- **描述**：二\n"
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DItemStore.currentItem(id: "D014", at: file)) { error in
            XCTAssertTrue(error is DItemStore.SnapshotError)
        }
    }

    func testCLIUpdatesAreReadableAndRemainEditableInDBoard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardAI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.md")
        let repository = directory.appendingPathComponent("repo")
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py").path
        var draft = DItemDraft(newID: "D014", priority: .p1)
        draft.name = "锁券接口"
        draft.desc = "原始描述"
        draft.promptSections.codeEntry = "ultra 里的车点点流程"
        draft.promptSections.materials = "https://example.com/方案"
        draft.promptSections.intent = "拆出锁券\n\n保留代码缩进"
        draft.promptSections.supplement = "本次只做上游接口"
        let originalPrompt = draft.prompt
        try "## 🟡 重要\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(DItemStore.create(draft, at: file))
        XCTAssertEqual(HandoffCLIFixture.run("/usr/bin/env", arguments: ["git", "init", "-q", repository.path]).exitCode, 0)
        XCTAssertEqual(HandoffCLIFixture.run("/usr/bin/env", arguments: ["git", "-C", repository.path,
            "symbolic-ref", "HEAD", "refs/heads/feature/lock-coupon"]).exitCode, 0)
        let read = HandoffCLIFixture.run("/usr/bin/env",
            arguments: ["python3", cli, "--cache", file.path, "show", "D014"])
        XCTAssertEqual(read.exitCode, 0)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: read.stdout) as? [String: Any])
        let item = try XCTUnwrap(json["item"] as? [String: Any])
        let revision = try XCTUnwrap(item["revision"] as? String)
        let result = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", cli, "--cache", file.path,
            "report", "D014", "--expect-title", "锁券接口", "--expect-revision", revision,
            "--repo", repository.path, "--progress", "实现完成，测试通过，待验收",
            "--event-id", "swift-interop", "--no-sync"])
        XCTAssertEqual(result.exitCode, 0, String(data: result.stdout, encoding: .utf8) ?? "")
        let parsed = try XCTUnwrap(CacheParser.parse(content: String(contentsOf: file, encoding: .utf8)).items.first)
        XCTAssertEqual(parsed.id, "D014")
        XCTAssertEqual(parsed.branch, "feature/lock-coupon")
        XCTAssertEqual(parsed.prompt, originalPrompt)
        XCTAssertEqual(parsed.title, draft.desc)
        XCTAssertEqual(parsed.milestones.count, 2)
        XCTAssertTrue(parsed.milestones.contains { $0.content == "实现完成，测试通过，待验收" })
        XCTAssertFalse(parsed.milestones.contains { $0.content.contains("dboard-ai-feedback") })
        XCTAssertTrue(DItemStore.appendProgress(id: "D014", text: "用户补充的联调记录", at: file))
        var edited = DItemDraft(from: parsed)
        edited.desc = "用户调整描述"
        XCTAssertTrue(DItemStore.save(edited, original: parsed, at: file))
        let updated = try XCTUnwrap(CacheParser.parse(content: String(contentsOf: file, encoding: .utf8)).items.first)
        XCTAssertEqual(updated.prompt, originalPrompt)
        XCTAssertEqual(updated.branch, "feature/lock-coupon")
        XCTAssertEqual(updated.milestones.count, 3)
        XCTAssertTrue(updated.milestones.contains { $0.content == "用户补充的联调记录" })
        let contextRead = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", cli, "--cache", file.path, "context", "D014"])
        XCTAssertEqual(contextRead.exitCode, 0)
        let contextResponse = try XCTUnwrap(try JSONSerialization.jsonObject(with: contextRead.stdout) as? [String: Any])
        let handoff = try XCTUnwrap(contextResponse["context"] as? String)
        XCTAssertTrue(handoff.contains(DemandPromptSections(stored: originalPrompt).assembled))
        XCTAssertTrue(handoff.contains("feature/lock-coupon"))
        XCTAssertTrue(handoff.contains("实现完成，测试通过，待验收"))
        XCTAssertTrue(handoff.contains("用户补充的联调记录"))
        XCTAssertFalse(handoff.contains("dboard-ai-feedback:v1:"))
    }
}
