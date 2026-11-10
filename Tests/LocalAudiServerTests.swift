import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class LocalAudiServerTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixture(status: Int = 200) throws -> (URL, AudiLocalTarget) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardAudi-" + UUID().uuidString)
        let repo = root.appendingPathComponent("audi")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertTrue(ProcessRunner.run("/usr/bin/git", arguments: ["init", "-q", repo.path]).succeeded)
        XCTAssertTrue(ProcessRunner.run("/usr/bin/git", arguments: ["-C", repo.path, "symbolic-ref", "HEAD", "refs/heads/feature/debug"]).succeeded)
        try "{}".write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        for route in ["one", "two"] {
            let page = repo.appendingPathComponent("app/test-console/" + route + "/page.jsx")
            try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "export default function Page() { return null }".write(to: page, atomically: true, encoding: .utf8)
        }
        let next = repo.appendingPathComponent("node_modules/next/dist/bin/next")
        try FileManager.default.createDirectory(at: next.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        const http = require('http');
        const port = Number(process.argv[process.argv.indexOf('--port') + 1]);
        http.createServer((req, res) => { const send = () => { res.writeHead(\(status)); res.end(req.url); }; if(req.url.endsWith('/two')) setTimeout(send, 1500); else send(); }).listen(port, '127.0.0.1');
        """
        try script.write(to: next, atomically: true, encoding: .utf8)
        return (root, try AudiLocalTarget.validate(repository: repo, expectedBranch: "feature/debug", page: "/test-console/one"))
    }

    @MainActor
    private func wait(_ predicate: () -> Bool, seconds: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return predicate()
    }

    @MainActor
    private func cleanup(_ server: LocalAudiServer, _ directory: URL) {
        server.stop()
        XCTAssertTrue(wait { !server.isActive })
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordedWorktreeAndBranchAreUsedAndManualBranchIsAuthoritative() throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("active-worktree")
        XCTAssertTrue(ProcessRunner.run("/usr/bin/git", arguments: ["-C", original.repository.path, "-c", "user.name=Test",
            "-c", "user.email=test@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture"]).succeeded)
        XCTAssertTrue(ProcessRunner.run("/usr/bin/git", arguments: ["-C", original.repository.path, "worktree", "add", "-q",
            "-b", "feature/worktree", worktree.path]).succeeded)
        for path in ["package.json", "app", "node_modules"] {
            try FileManager.default.copyItem(at: original.repository.appendingPathComponent(path),
                                            to: worktree.appendingPathComponent(path))
        }
        let cache = root.appendingPathComponent("cache.md")
        let metadata: [String: Any] = ["repositories": [
            ["path": worktree.path, "branch": "feature/worktree", "name": "audi"]]]
        let meta = try JSONSerialization.data(withJSONObject: metadata).base64EncodedString()
        var text = """
        ## 🟡 重要
        ### D014【ultra】测试需求 #进行中
        - **项目**：ultra；audi
        - **分支**：ultra:feature/backend；audi:feature/worktree
        <!-- dboard-ai-feedback:v1:\(meta) -->
        """
        let execution = DemandExecution(stage: .debugPageReady,
            scopeHash: DemandExecution.scopeHash(Array(text.components(separatedBy: "\n").dropFirst())),
            debugPage: "/test-console/one", debugURL: nil, updatedAt: "2026-11-04")
        text += "\n" + DemandExecution.prefix + (try JSONEncoder().encode(execution)).base64EncodedString() + DemandExecution.suffix
        try text.write(to: cache, atomically: true, encoding: .utf8)
        let loaded = try AudiLocalTarget.load(id: "D014", at: cache)
        XCTAssertEqual(loaded.repository, worktree.resolvingSymlinksInPath())
        XCTAssertEqual(loaded.branch, "feature/worktree")
        try text.replacingOccurrences(of: "audi:feature/worktree", with: "audi:feature/other")
            .write(to: cache, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AudiLocalTarget.load(id: "D014", at: cache))
        try FileManager.default.removeItem(at: worktree)
        try text.write(to: cache, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AudiLocalTarget.load(id: "D014", at: cache), "Must not fall back to another audi directory")
    }

    func testMissingPageWrongBranchAndNonAudiRepositoryAreRejected() throws {
        let (root, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AudiLocalTarget.validate(repository: target.repository, expectedBranch: "feature/other", page: target.page))
        XCTAssertThrowsError(try AudiLocalTarget.validate(repository: target.repository, expectedBranch: target.branch, page: "/test-console/missing"))
        XCTAssertThrowsError(try AudiLocalTarget.validate(repository: target.repository, expectedBranch: nil, page: target.page))
        XCTAssertTrue(ProcessRunner.run("/usr/bin/git", arguments: ["-C", target.repository.path, "remote", "add", "origin", "https://example.invalid/ultra.git"]).succeeded)
        XCTAssertThrowsError(try AudiLocalTarget.validate(repository: target.repository, expectedBranch: target.branch, page: target.page))
    }

    func testHTTPFailureAndLoginRedirectDoNotMeanPageReady() {
        let requested = URL(string: "http://127.0.0.1:4123/test-console/one")!
        for status in [301, 302, 404, 500, 503] {
            XCTAssertFalse(LocalAudiServer.pageReady(response: HTTPURLResponse(url: requested, statusCode: status,
                httpVersion: nil, headerFields: nil), requested: requested))
        }
        XCTAssertFalse(LocalAudiServer.pageReady(response: HTTPURLResponse(url: URL(string: "http://127.0.0.1:4123/login")!,
            statusCode: 200, httpVersion: nil, headerFields: nil), requested: requested))
        XCTAssertTrue(LocalAudiServer.pageReady(response: HTTPURLResponse(url: requested, statusCode: 200,
            httpVersion: nil, headerFields: nil), requested: requested))
    }

    @MainActor
    func testSameDirectorySharesServerAndStoppingReleasesPortBeforeRestart() throws {
        let (root, target) = try fixture()
        let server = LocalAudiServer(loadTarget: { id, _ in
            AudiLocalTarget(repository: target.repository, branch: target.branch,
                            page: id == "D002" ? "/test-console/two" : target.page)
        }, timeout: 3)
        defer { cleanup(server, root) }
        var opened: [URL] = []
        server.openURL = { opened.append($0) }
        server.startAndOpen(id: "D001")
        server.startAndOpen(id: "D001") // Double click while resolving must not spawn another server.
        XCTAssertTrue(wait { server.isRunning }, String(describing: server.state))
        let first = try XCTUnwrap(opened.first)
        XCTAssertEqual(first.path, target.page)
        // An existing server still needs enough time to compile a newly opened page.
        RunLoop.main.run(until: Date().addingTimeInterval(3.1))
        server.startAndOpen(id: "D002")
        XCTAssertTrue(wait { opened.count == 2 })
        XCTAssertEqual(opened[1].port, first.port)
        XCTAssertEqual(opened[1].path, "/test-console/two")
        XCTAssertEqual(server.demandIDs, ["D001", "D002"])
        server.stop()
        XCTAssertEqual(server.state, .stopping)
        server.startAndOpen(id: "D001") // Stopping is not yet stopped.
        XCTAssertTrue(wait { server.state == .stopped })
        let listener = ProcessRunner.run("/usr/sbin/lsof",
            arguments: ["-nP", "-t", "-iTCP:" + String(first.port!), "-sTCP:LISTEN"], timeout: 2)
        XCTAssertTrue(listener.stdout.isEmpty, "Stopped Next workers must not retain the port")
        server.startAndOpen(id: "D001")
        XCTAssertTrue(wait { server.isRunning })
    }

    @MainActor
    func testServerReturning500IsCleanedUpAndNeverOpensBrowser() throws {
        let (root, target) = try fixture(status: 500)
        let server = LocalAudiServer(loadTarget: { _, _ in target })
        defer { cleanup(server, root) }
        var opened = false
        server.openURL = { _ in opened = true }
        server.startAndOpen(id: "D001")
        XCTAssertTrue(wait { if case .failed = server.state { return true }; return false })
        XCTAssertFalse(opened)
        XCTAssertNil(server.activeTarget)
        guard case .failed(let message) = server.state else { return XCTFail("Expected page failure") }
        XCTAssertTrue(message.contains("500"))
    }

    @MainActor
    func testCancelDuringTargetLookupCannotStartLateServer() throws {
        let (root, target) = try fixture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let server = LocalAudiServer(loadTarget: { _, _ in entered.signal(); release.wait(); return target })
        defer { cleanup(server, root) }
        server.startAndOpen(id: "D001")
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        server.stop()
        release.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(server.state, .stopped)
        XCTAssertNil(server.activeTarget)
    }

    @MainActor
    func testWrongDirectoryCannotReplaceRunningServerAndStopControlRemains() throws {
        let (root, target) = try fixture()
        let server = LocalAudiServer(loadTarget: { id, _ in
            id == "D002" ? AudiLocalTarget(repository: root.appendingPathComponent("other"), branch: target.branch, page: target.page) : target
        })
        defer { cleanup(server, root) }
        server.openURL = { _ in }
        server.startAndOpen(id: "D001")
        XCTAssertTrue(wait { server.isRunning })
        server.startAndOpen(id: "D002")
        XCTAssertTrue(wait { server.issue != nil })
        XCTAssertTrue(server.isRunning)
        XCTAssertEqual(server.activeTarget, target)
        _ = NSApplication.shared
        let flow = BizMapViewModel(loadBackgroundData: false,
            projectStore: DevelopmentProjectStore(url: root.appendingPathComponent("projects.json")))
        let vm = DBoardViewModel(loadCache: false, reqFlow: flow)
        var item = DItem(id: "D001", project: "audi", title: "联调", headerTitle: "联调",
            status: .inProgress, priority: .p1, deadline: nil, branch: target.branch, startDate: nil, milestones: [])
        item.execution = DemandExecution(stage: .debugPageReady, scopeHash: String(repeating: "a", count: 64),
            debugPage: target.page, debugURL: nil, updatedAt: "2026-11-04")
        for skipped in [false, true] {
            if !server.isRunning {
                server.startAndOpen(id: "D001")
                XCTAssertTrue(wait { server.isRunning })
            }
            item.executionScope = "new-change"
            item.debugPageNotNeeded = skipped
            let view = NSHostingView(rootView: DemandDebuggingView(audi: server, item: item)
                .environmentObject(vm).frame(width: 520).padding(12)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 240),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(server.isRunning)
            if let directory = ProcessInfo.processInfo.environment["DBOARD_UI_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory + "/local-stop-" + String(skipped) + ".png"))
            }
            let position = view.convert(NSPoint(x: 90, y: view.isFlipped ? view.bounds.height - 30 : 30), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: position, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            XCTAssertTrue(wait { server.state == .stopped }, "The visible stop button must stop after a new change or opting out")
            window.close()
        }
    }

    @MainActor
    func testStartsRealAudiFromLatestDemandAndChecksItsModulePage() throws {
        guard ProcessInfo.processInfo.environment["DBOARD_AUDI_LOCAL_TEST"] == "1" else {
            throw XCTSkip("Explicitly enable the read-only local audi smoke test")
        }
        let server = LocalAudiServer()
        defer { server.stop(); XCTAssertTrue(wait({ !server.isActive }, seconds: 10)) }
        var opened: URL?
        server.openURL = { opened = $0 }
        server.startAndOpen(id: "D014")
        XCTAssertTrue(wait({ server.isRunning || { if case .failed = server.state { return true }; return false }() }, seconds: 120))
        XCTAssertTrue(server.isRunning, String(describing: server.state))
        XCTAssertEqual(opened?.path, "/test-console/cdd-lock")
        XCTAssertEqual(server.activeTarget?.repository.path, "/Users/zz/work/code/audi")
    }
}
