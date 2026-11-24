import XCTest
import AppKit
import Combine
@testable import DBoard

final class DemandCopyResponsivenessTests: XCTestCase {
    func testBlockLookupKeepsExactIDsAndIgnoresIndentedHeadings() {
        let lines = ["### D0220【】别的需求", String(repeating: "payload", count: 1000),
                     "    ### D022 不是顶层需求", "### D022【】目标需求",
                     "- **描述**：内容", "    ## 内部小标题", "### D023【】下一条"]
        XCTAssertEqual(DItemStore.blockRange(lines, id: "D022"), 3..<6)
        XCTAssertNil(DItemStore.blockRange(lines, id: "D02"))
        XCTAssertEqual(DItemStore.blockRange(["### D022"], id: "D022"), 0..<1)
    }

    @MainActor
    func testFocusRefreshOnlyChecksCurrentDemandAndBatchesRepeatedEvents() {
        func item(_ id: String) -> DItem {
            var item = DItem(id: id, project: "fixture", title: "", headerTitle: id,
                status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
            item.execution = DemandExecution(stage: .developmentComplete,
                scopeHash: String(repeating: "a", count: 64), debugPage: nil,
                debugURL: nil, updatedAt: "2026-11-24", code: [
                    DemandCodeSnapshot(path: "/tmp/dboard-absent-" + UUID().uuidString,
                        branch: "feature/test", commit: String(repeating: "a", count: 40),
                        dirtyHash: String(repeating: "b", count: 64))
                ])
            item.executionCodeReview = DemandCodeReview(id: id, needsReview: false, reason: nil)
            return item
        }
        let vm = DBoardViewModel(loadCache: false)
        vm.items = [item("D021"), item("D022")]
        let unrelated = vm.items[0].executionCodeReview
        var notifications = 0
        let subscription = vm.$items.dropFirst().sink { _ in notifications += 1 }
        defer { subscription.cancel() }
        vm.refreshCodeReviews(only: "D022")
        vm.refreshCodeReviews(only: "D022")
        vm.refreshCodeReviews(only: "D022")
        XCTAssertEqual(vm.items[0].executionCodeReview, unrelated)
        XCTAssertNil(vm.items[1].executionCodeReview)
        let deadline = Date().addingTimeInterval(5)
        while vm.items[1].executionCodeReview == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(vm.items[1].executionCodeReview)
        XCTAssertEqual(vm.items[0].executionCodeReview, unrelated)
        XCTAssertEqual(notifications, 2, "Clear and apply each publish once, not once per demand or focus event")
    }

    @MainActor
    func testCopyInstructionsSkipGitWhileExplicitCodeReviewStillChecksIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardCopyGit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.md")
        var block = ["### D022【】七仓库需求 #进行中", "- **描述**：复制最新现状"]
        try DemandChanges.set(&block, changes: [
            DemandChange(id: "C001", createdAt: Date(), intent: "新增参数")
        ])
        let repositories = (0..<7).map {
            DemandVersion.Repository(path: root.appendingPathComponent("repository-\($0)").path, branch: "feature/test")
        }
        let code = repositories.map {
            DemandCodeSnapshot(path: $0.path, branch: $0.branch,
                commit: String(repeating: "a", count: 40), dirtyHash: String(repeating: "b", count: 64))
        }
        let execution = DemandExecution(stage: .debugPageReady,
            scopeHash: DemandExecution.scopeHash(block), debugPage: "/test-console/copy",
            debugURL: nil, updatedAt: "2026-11-24", code: code)
        let feedback = try JSONEncoder().encode(["repositories": repositories])
        block.append("<!-- dboard-ai-feedback:v1:" + feedback.base64EncodedString() + " -->")
        block.append(DemandExecution.prefix + (try JSONEncoder().encode(execution)).base64EncodedString() + DemandExecution.suffix)
        try ("## 🟡 重要\n" + block.joined(separator: "\n")).write(to: cache, atomically: true, encoding: .utf8)

        // Child CPU accounting detects synchronous Python/Git scans without changing
        // global environment variables or depending on a machine-speed threshold.
        func childCPUTime() throws -> Int64 {
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_CHILDREN, &usage), 0)
            return Int64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000 +
                Int64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)
        }
        let item = try DItemStore.currentRecord(id: "D022", at: cache)
        XCTAssertEqual(item.executionRepositories.count, 7)
        let beforeReview = try childCPUTime()
        XCTAssertEqual(DemandCodeReviews.check([item]).first?.needsReview, true)
        XCTAssertGreaterThan(try childCPUTime(), beforeReview, "Explicit code review must still run the code helper")

        let flow = BizMapViewModel(loadBackgroundData: false,
            projectStore: DevelopmentProjectStore(url: root.appendingPathComponent("projects.json")))
        let vm = DBoardViewModel(loadCache: false, reqFlow: flow)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let before = try Data(contentsOf: cache)
        let beforeCopy = try childCPUTime()
        XCTAssertTrue(vm.copyCurrentState("D022", at: cache, pasteboard: clipboard))
        XCTAssertTrue(clipboard.string(forType: .string)?.contains("## 本次联调问题") == true)
        XCTAssertTrue(vm.copyReviewTask("D022", at: cache, pasteboard: clipboard))
        XCTAssertTrue(vm.copyDebugTask("D022", at: cache, pasteboard: clipboard))
        XCTAssertTrue(vm.copyChangeState("D022", changeID: "C001", at: cache, pasteboard: clipboard))
        XCTAssertTrue(clipboard.string(forType: .string)?.contains("--change 'C001'") == true)
        XCTAssertEqual(try childCPUTime(), beforeCopy, "Copying must not run the code helper on the UI thread")
        XCTAssertEqual(try Data(contentsOf: cache), before)
    }
}
