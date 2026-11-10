import XCTest
import AppKit
@testable import DBoard

final class DemandIntegrationHandoffTests: XCTestCase {
    private func item() -> DItem {
        DItem(id: "D014", project: "ultra；audi", title: "接口", headerTitle: "锁券",
            status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
    }

    func testReadyPageAddsOneBottomFillAreaAndOtherCopiesRemainOrdinary() {
        var value = item()
        XCTAssertFalse(DboardAITaskContext.readInstruction(item: value).contains("## 本次联调问题"))
        let execution = DemandExecution(stage: .debugPageReady, scopeHash: String(repeating: "a", count: 64),
            debugPage: "/test-console/coupon", debugURL: nil, updatedAt: "2026-11-04")
        value.execution = execution
        value.executionScope = execution.scopeHash
        let ready = DboardAITaskContext.readInstruction(item: value)
        XCTAssertTrue(ready.hasSuffix("## 本次联调问题\n"), "User can paste all evidence at the bottom")
        XCTAssertEqual(ready.components(separatedBy: "## 本次联调问题").count, 2)
        XCTAssertTrue(ready.components(separatedBy: "\n")[1].contains(" context 'D014'"))
        XCTAssertFalse(ready.contains("--task debug-page"), "Fault handoff must not order a fresh page build")
        XCTAssertFalse(DboardAITaskContext.readInstruction(item: value, changeID: "C001").contains("## 本次联调问题"))
        value.executionScope = "changed"
        XCTAssertFalse(DboardAITaskContext.readInstruction(item: value).contains("## 本次联调问题"))
        value.executionScope = execution.scopeHash
        value.debugPageNotNeeded = true
        XCTAssertFalse(DboardAITaskContext.readInstruction(item: value).contains("## 本次联调问题"))
        value.debugPageNotNeeded = false
        value.status = .completed
        XCTAssertFalse(DboardAITaskContext.readInstruction(item: value).contains("## 本次联调问题"))
    }

    @MainActor
    func testCopyUsesLatestReadyPageThenStopsAppendingTemplateAfterNewChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardIntegration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache.md")
        var text = """
        ## 🟡 重要
        ### D014【ultra】接口联调 #进行中
        - **项目**：ultra；audi
        - **提示词**：
            ## 要做什么
            拆出锁券
        """
        try text.write(to: cache, atomically: true, encoding: .utf8)
        let stale = try DItemStore.currentItem(id: "D014", at: cache)
        let flow = BizMapViewModel(loadBackgroundData: false,
            projectStore: DevelopmentProjectStore(url: directory.appendingPathComponent("projects.json")))
        let vm = DBoardViewModel(loadCache: false, reqFlow: flow)
        vm.items = [stale]
        let execution = DemandExecution(stage: .testingPassed,
            scopeHash: DemandExecution.scopeHash(Array(text.components(separatedBy: "\n").dropFirst())),
            debugPage: "/test-console/coupon", debugURL: nil, updatedAt: "2026-11-04")
        text += "\n" + DemandExecution.prefix + (try JSONEncoder().encode(execution)).base64EncodedString() + DemandExecution.suffix
        try text.write(to: cache, atomically: true, encoding: .utf8)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let unchanged = try Data(contentsOf: cache)
        XCTAssertTrue(vm.copyCurrentState("D014", at: cache, pasteboard: clipboard))
        XCTAssertTrue(clipboard.string(forType: .string)?.hasSuffix("## 本次联调问题\n") == true)
        XCTAssertNil(stale.execution)
        XCTAssertEqual(try Data(contentsOf: cache), unchanged, "Copying must not modify requirement data")
        XCTAssertNotNil(DItemStore.appendChange(id: "D014", intent: "增加新参数", at: cache))
        XCTAssertTrue(vm.copyCurrentState("D014", at: cache, pasteboard: clipboard))
        XCTAssertFalse(clipboard.string(forType: .string)?.contains("## 本次联调问题") == true)
    }
}
