import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandWorktreesTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardWorktreeTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("demand-center-cache.md")
        try "## 🟡 重要\n### D900【ultra】工作树测试 #已完成\n".write(to: cache, atomically: true, encoding: .utf8)
        try body(directory, cache)
    }

    func testNativePreviewAndSummaryUseTheSameCLIWithoutChangingTheTask() throws {
        try fixture { directory, cache in
            let before = try Data(contentsOf: cache)
            let preview = try DemandWorktreeCLI.run(cache: cache, mode: "preview", id: "D900")
            XCTAssertTrue(preview.success)
            XCTAssertEqual(preview.rows?.count, 0)
            XCTAssertEqual(preview.eligible_count, 0)
            XCTAssertEqual(preview.preview_revision?.count, 64)
            let summary = try DemandWorktreeCLI.run(cache: cache, mode: "summary", id: "D900")
            XCTAssertEqual(summary.summary?.registered, 0)
            XCTAssertEqual(try Data(contentsOf: cache), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dboard-worktrees.json").path))
            XCTAssertThrowsError(try DemandWorktreeCLI.run(cache: cache, mode: "preview", id: "D999")) { error in
                XCTAssertTrue(error.localizedDescription.contains("找不到需求"))
            }
        }
    }

    @MainActor
    func testOpeningCleanupManagerOnlyPreviewsAndLeavesEligibleTreeUntouched() throws {
        try fixture { directory, cache in
            func git(_ arguments: [String]) throws {
                let result = ProcessRunner.run("/usr/bin/git", arguments: arguments)
                guard result.succeeded else { throw NSError(domain: "Fixture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(data: result.stderr, encoding: .utf8) ?? "Git fixture failed"]) }
            }
            let main = directory.appendingPathComponent("ultra")
            let remote = directory.appendingPathComponent("remote.git")
            let tree = directory.appendingPathComponent("worktree")
            try git(["init", "--bare", "-q", remote.path])
            try git(["init", "-q", "-b", "main", main.path])
            try git(["-C", main.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                     "commit", "--allow-empty", "-qm", "初始夹具"])
            try git(["-C", main.path, "remote", "add", "origin", remote.path])
            try git(["-C", main.path, "worktree", "add", "-qb", "feature/fixture", tree.path])
            try git(["-C", tree.path, "push", "-qu", "origin", "HEAD"])
            _ = try DemandWorktreeCLI.run(cache: cache, mode: "register", id: "D900", extra: ["--path", tree.path, "--created"])
            let preview = try DemandWorktreeCLI.run(cache: cache, mode: "preview", id: "D900")
            XCTAssertEqual(preview.eligible_count, 1)
            let item = try DItemStore.currentItem(id: "D900", at: cache)
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 720, height: 580),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DemandWorktreesManager(item: item, cacheURL: cache)
                .frame(width: 720, height: 580).background(Color(nsColor: .windowBackgroundColor)))
            window.orderBack(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path), "Opening the cleanup manager must never remove a worktree")
            XCTAssertEqual(try DemandWorktreeCLI.run(cache: cache, mode: "summary", id: "D900").summary?.removed, 0)
            if let output = ProcessInfo.processInfo.environment["DBOARD_WORKTREE_UI_SNAPSHOT"],
               let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            }
        }
    }
}
