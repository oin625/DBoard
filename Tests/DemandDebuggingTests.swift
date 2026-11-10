import XCTest
import Foundation
import AppKit
@testable import DBoard

final class DemandDebuggingTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardDebug-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cache.md")
        try """
        ## 🟡 重要
        ### D014【ultra】锁券测试 #进行中 📅2026-11-01 →🎯11.20
        - **项目**：ultra；audi
        - **描述**：锁券后查询照片
        - **分支**：待定
        - **提示词**：
            ## 要做什么
            拆出锁券
            ## 补充说明
            保留失败信息
        - **进度**：
            - 11.1: 开发完成，待联调。
        """.write(to: file, atomically: true, encoding: .utf8)
        let repository = dir.appendingPathComponent("ultra")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        XCTAssertTrue(HandoffCLIFixture.run("/usr/bin/git", arguments: ["-C", repository.path, "init", "-q", "-b", "feature/fixture"]).succeeded)
        XCTAssertTrue(HandoffCLIFixture.run("/usr/bin/git", arguments: ["-C", repository.path, "-c", "user.name=DBoard Test",
            "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "测试初始提交"]).succeeded)
        let show = try cli(file, ["show", "D014"])
        let item = try XCTUnwrap(show["item"] as? [String: Any])
        _ = try cli(file, ["report", "D014", "--expect-title", try XCTUnwrap(item["title"] as? String),
            "--expect-revision", try XCTUnwrap(item["revision"] as? String), "--repo", repository.path, "--no-sync"])
        try body(file)
    }

    private func cli(_ file: URL, _ arguments: [String]) throws -> [String: Any] {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/dboard_ai.py").path
        let result = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", source, "--cache", file.path] + arguments)
        XCTAssertEqual(result.exitCode, 0, String(data: result.stdout, encoding: .utf8) ?? "")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
    }
    private func report(_ file: URL, stage: String, extra: [String] = []) throws {
        let response = try cli(file, ["show", "D014"])
        let item = try XCTUnwrap(response["item"] as? [String: Any])
        _ = try cli(file, ["report", "D014", "--expect-title", try XCTUnwrap(item["title"] as? String),
                          "--expect-revision", try XCTUnwrap(item["revision"] as? String),
                          "--summary", "本轮核验结果已记录，待用户验收。", "--details", "已核对本需求接口与关键业务步骤。",
                          "--stage", stage, "--no-sync"] + (stage == "developing" ? [] : ["--expect-code", try XCTUnwrap(item["code_revision"] as? String)]) + extra)
    }

    @MainActor
    func testCodeChangesInvalidateCLIAndPanelWithoutChangingDemandScope() throws {
        try fixture { file in
            let code = file.deletingLastPathComponent().appendingPathComponent("ultra/service.swift")
            try "original implementation".write(to: code, atomically: true, encoding: .utf8)
            try report(file, stage: "development-complete")
            try report(file, stage: "debug-page-ready", extra: ["--debug-page", "/test-console/fixture"])
            try report(file, stage: "testing-passed")
            let before = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertFalse(before.executionNeedsReview)
            XCTAssertEqual(before.execution?.code?.count, 1)
            try "later implementation".write(to: code, atomically: true, encoding: .utf8)
            let after = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertEqual(after.executionScope, before.executionScope)
            XCTAssertEqual(after.execution, before.execution)
            XCTAssertTrue(after.executionNeedsReview)
            XCTAssertEqual(after.executionLabel, "代码已变更 · 需重新核验")
            XCTAssertTrue(AudiLocalTarget.canLaunch(after), "The existing page remains available for investigation")
            let vm = DBoardViewModel(loadCache: false)
            vm.items = CacheParser.parse(content: try String(contentsOf: file, encoding: .utf8)).items
            XCTAssertEqual(vm.items[0].executionLabel, "代码版本待核对")
            vm.refreshCodeReviews()
            let deadline = Date().addingTimeInterval(5)
            while vm.items[0].executionCodeReview == nil && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertEqual(vm.items[0].executionLabel, "代码已变更 · 需重新核验")
            try report(file, stage: "developing")
            XCTAssertEqual(try DItemStore.currentItem(id: "D014", at: file).execution?.debugPage, "/test-console/fixture")
        }
    }

    func testPythonReportsParseInSwiftAndScopeInvalidatesOnRequirementChange() throws {
        try fixture { file in
            try report(file, stage: "development-complete")
            var item = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertEqual(item.execution?.stage, .developmentComplete)
            XCTAssertFalse(item.executionNeedsReview, "Swift and Python must hash the same scope")
            XCTAssertEqual(item.title, "锁券后查询照片")
            try report(file, stage: "debug-page-ready", extra: ["--debug-page", "/test-console/lock-coupon"])
            try report(file, stage: "testing-passed", extra: ["--debug-url", "http://localhost:3000/test-console/lock-coupon"])
            item = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertEqual(item.status, .inProgress)
            XCTAssertEqual(item.execution?.stage, .testingPassed)
            XCTAssertEqual(item.execution?.debugPage, "/test-console/lock-coupon")
            XCTAssertFalse(item.executionNeedsReview)
            XCTAssertTrue(DItemStore.appendProgress(id: "D014", text: "补充交接，无需求变化。", at: file))
            XCTAssertFalse(try DItemStore.currentItem(id: "D014", at: file).executionNeedsReview)
            XCTAssertTrue(DItemStore.savePrompt(id: "D014", text: item.prompt + "\n新增查询失败时停止",
                                               expected: item.prompt, at: file))
            item = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertTrue(item.executionNeedsReview)
            XCTAssertEqual(item.executionLabel, "需求已变更 · 需重新核验")
            let show = try cli(file, ["show", "D014"])
            XCTAssertEqual((show["item"] as? [String: Any])?["execution_needs_review"] as? Bool, true)
        }
    }

    @MainActor
    func testCopyDebugInstructionIsShortReadsLatestAndPreservesClipboardOnFailure() throws {
        try fixture { file in
            let flow = BizMapViewModel(loadBackgroundData: false,
                projectStore: DevelopmentProjectStore(url: file.deletingLastPathComponent().appendingPathComponent("projects.json")))
            let vm = DBoardViewModel(loadCache: false, reqFlow: flow)
            let clipboard = NSPasteboard.withUniqueName()
            defer { clipboard.releaseGlobally() }
            XCTAssertTrue(vm.copyDebugTask("D014", at: file, pasteboard: clipboard))
            let copy = try XCTUnwrap(clipboard.string(forType: .string))
            XCTAssertTrue(copy.contains("--task debug-page"))
            XCTAssertTrue(copy.contains("/test-console"))
            XCTAssertLessThan(copy.count, 400)
            XCTAssertFalse(copy.contains("拆出锁券"))
            let old = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertTrue(DItemStore.savePrompt(id: "D014", text: old.prompt + "\n复制后追加的要求",
                                               expected: old.prompt, at: file))
            let response = try cli(file, ["context", "D014", "--task", "debug-page"])
            XCTAssertTrue((response["context"] as? String)?.contains("复制后追加的要求") == true)
            XCTAssertTrue((response["debug_instructions"] as? String)?.contains("CONSOLES") == true)
            XCTAssertFalse(vm.copyDebugTask("D999", at: file, pasteboard: clipboard))
            XCTAssertEqual(clipboard.string(forType: .string), copy)
            var source = try String(contentsOf: file, encoding: .utf8)
            source += "\n" + DemandExecution.prefix + "! -->"
            try source.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertFalse(vm.copyDebugTask("D014", at: file, pasteboard: clipboard))
            XCTAssertEqual(clipboard.string(forType: .string), copy)
        }
    }

    func testExecutionDoesNotLeakIntoRemoteOverviewAndSurvivesUserEdits() throws {
        try fixture { file in
            let original = try String(contentsOf: file, encoding: .utf8)
            let scope = DemandExecution.scopeHash(original.components(separatedBy: "\n"))
            try report(file, stage: "development-complete")
            let updated = try String(contentsOf: file, encoding: .utf8)
            let projection = try DemandOverview.render(updated)
            XCTAssertFalse(projection.contains("dboard-execution"))
            let old = try DItemStore.currentItem(id: "D014", at: file)
            var draft = DItemDraft(from: old)
            draft.desc = "用户修改了描述"
            // Standard editor must preserve execution metadata and mark its scope outdated.
            XCTAssertTrue(DItemStore.save(draft, original: old, at: file))
            let fresh = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertNotNil(fresh.execution)
            XCTAssertTrue(fresh.executionNeedsReview)
            XCTAssertNotEqual(fresh.executionScope, scope)
        }
    }

    func testSkipAndUndoPreserveExecutionEvidenceAndDoNotPublishPreference() throws {
        try fixture { file in
            try report(file, stage: "development-complete")
            try report(file, stage: "debug-page-ready", extra: ["--debug-page", "/test-console/lock-coupon"])
            let before = try DItemStore.currentItem(id: "D014", at: file)
            let oldSource = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(DItemStore.setDebugPageNotNeeded(id: "D014", value: true, expected: false, at: file))
            let skipped = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertTrue(skipped.debugPageNotNeeded)
            XCTAssertEqual(skipped.executionLabel, "无需调试页")
            XCTAssertEqual(skipped.execution, before.execution)
            XCTAssertEqual(skipped.executionScope, before.executionScope)
            XCTAssertFalse(skipped.executionNeedsReview)
            XCTAssertEqual(skipped.title, before.title)
            let newSource = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(try DemandOverview.hash(oldSource), try DemandOverview.hash(newSource))
            let show = try cli(file, ["show", "D014"])
            XCTAssertEqual((show["item"] as? [String: Any])?["debug_page_not_needed"] as? Bool, true)
            XCTAssertTrue(DItemStore.setDebugPageNotNeeded(id: "D014", value: false, expected: true, at: file))
            let restored = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertFalse(restored.debugPageNotNeeded)
            XCTAssertEqual(restored.execution, before.execution)
            XCTAssertEqual(restored.executionLabel, before.executionLabel)
        }
    }

    @MainActor
    func testLatestUserPreferenceOverridesAnEarlierDebugCopyAndSurvivesChanges() throws {
        try fixture { file in
            let flow = BizMapViewModel(loadBackgroundData: false,
                projectStore: DevelopmentProjectStore(url: file.deletingLastPathComponent().appendingPathComponent("projects.json")))
            let vm = DBoardViewModel(loadCache: false, reqFlow: flow)
            let clipboard = NSPasteboard.withUniqueName()
            defer { clipboard.releaseGlobally() }
            XCTAssertTrue(vm.copyDebugTask("D014", at: file, pasteboard: clipboard))
            let earlierCopy = clipboard.string(forType: .string)
            XCTAssertTrue(vm.setDebugPageNotNeeded("D014", value: true, at: file))
            XCTAssertFalse(vm.copyDebugTask("D014", at: file, pasteboard: clipboard))
            XCTAssertEqual(clipboard.string(forType: .string), earlierCopy)
            let context = try cli(file, ["context", "D014", "--task", "debug-page"])
            XCTAssertEqual((context["item"] as? [String: Any])?["debug_page_not_needed"] as? Bool, true)
            XCTAssertTrue((context["context"] as? String)?.contains("不创建或更新调试页") == true)
            XCTAssertFalse((context["debug_instructions"] as? String)?.contains("CONSOLES") == true)
            XCTAssertNotNil(DItemStore.appendChange(id: "D014", intent: "追加新的返回字段", at: file))
            var item = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertTrue(item.debugPageNotNeeded)
            var draft = DItemDraft(from: item)
            draft.desc = "编辑需求描述"
            XCTAssertTrue(DItemStore.save(draft, original: item, at: file))
            item = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertTrue(item.debugPageNotNeeded)
            let ordinary = try cli(file, ["context", "D014"])
            XCTAssertTrue((ordinary["context"] as? String)?.contains("用户调试页设置：无需调试页") == true)
            XCTAssertTrue(vm.setDebugPageNotNeeded("D014", value: false, at: file))
            XCTAssertTrue(vm.copyDebugTask("D014", at: file, pasteboard: clipboard))
            let restored = try cli(file, ["context", "D014", "--task", "debug-page"])
            XCTAssertTrue((restored["debug_instructions"] as? String)?.contains("CONSOLES") == true)
        }
    }

    func testUndoAfterNewChangeStillRequiresReviewAndCorruptPreferenceCannotBeOverwritten() throws {
        try fixture { file in
            try report(file, stage: "development-complete")
            try report(file, stage: "debug-page-ready", extra: ["--debug-page", "/test-console/lock-coupon"])
            XCTAssertTrue(DItemStore.setDebugPageNotNeeded(id: "D014", value: true, expected: false, at: file))
            XCTAssertNotNil(DItemStore.appendChange(id: "D014", intent: "新增锁券参数", at: file))
            XCTAssertTrue(DItemStore.setDebugPageNotNeeded(id: "D014", value: false, expected: true, at: file))
            let restored = try DItemStore.currentItem(id: "D014", at: file)
            XCTAssertTrue(restored.executionNeedsReview)
            XCTAssertEqual(restored.execution?.debugPage, "/test-console/lock-coupon")
            var source = try String(contentsOf: file, encoding: .utf8)
            source += "\n" + DemandDebugPagePolicy.prefix + "broken -->"
            try source.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try DItemStore.currentItem(id: "D014", at: file))
            XCTAssertFalse(DItemStore.setDebugPageNotNeeded(id: "D014", value: true, expected: false, at: file))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
        }
    }
}
