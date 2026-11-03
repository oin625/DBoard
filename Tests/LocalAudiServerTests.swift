import XCTest
@testable import DBoard

final class LocalAudiServerTests: XCTestCase {
    func testPageURLJoinsTheRecordedRouteOntoTheDetectedLocalServer() {
        let base = URL(string: "http://localhost:3001")!
        let url = AudiLocalLaunch.pageURL(base: base, page: "/test-console/cdd-lock")
        XCTAssertEqual(url?.absoluteString, "http://localhost:3001/test-console/cdd-lock")
    }

    func testPageURLOnlyAcceptsAbsoluteValidatedRoutes() {
        let base = URL(string: "http://localhost:3000")!
        XCTAssertNil(AudiLocalLaunch.pageURL(base: base, page: "test-console"))
        XCTAssertNil(AudiLocalLaunch.pageURL(base: base, page: "https://example.com/test-console"))
        XCTAssertNil(AudiLocalLaunch.pageURL(base: base, page: "/test-console//cdd-lock"))
        XCTAssertNil(AudiLocalLaunch.pageURL(base: base, page: "/test-console/cdd lock"))
        XCTAssertNil(AudiLocalLaunch.pageURL(base: base, page: "/test-console\ncdd-lock"))
        XCTAssertNil(AudiLocalLaunch.pageURL(base: URL(string: "file:///tmp")!, page: "/test-console"))
    }

    func testPageURLTrimsOneTrailingSlash() {
        let base = URL(string: "http://localhost:3000")!
        XCTAssertEqual(AudiLocalLaunch.pageURL(base: base, page: "/test-console/")?.path, "/test-console")
    }

    func testLocalBaseURLParsesTheNextDevBannerAndIgnoresNetworkAddresses() {
        let banner = """
           ▲ Next.js 16.2.10 (Turbopack)
           - Local:        \u{001B}[36mhttp://localhost:3001\u{001B}[0m
           - Network:      http://30.194.49.222:3001
        """
        XCTAssertEqual(AudiLocalLaunch.localBaseURL(in: banner)?.absoluteString, "http://localhost:3001")
        XCTAssertEqual(AudiLocalLaunch.localBaseURL(in: "ready at http://127.0.0.1:4123")?.absoluteString,
                       "http://127.0.0.1:4123")
        XCTAssertNil(AudiLocalLaunch.localBaseURL(in: "http://30.194.49.222:3000"))
    }

    func testProbeURLUsesTheConsoleRouteOnTheDefaultPort() {
        XCTAssertEqual(AudiLocalLaunch.probeURL.absoluteString, "http://localhost:3000/test-console")
    }

    func testResolveNodeExecutableFindsAnAbsoluteNodePath() throws {
        let path = try XCTUnwrap(AudiLocalLaunch.resolveNodeExecutable())
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    }

    @MainActor
    func testStartsLocalAudiAndOpensTheRecordedDebugPage() throws {
        guard ProcessInfo.processInfo.environment["DBOARD_AUDI_LOCAL_TEST"] == "1" else {
            throw XCTSkip("设置 DBOARD_AUDI_LOCAL_TEST=1 后实际启动本地 audi 验证")
        }
        let server = LocalAudiServer.shared
        var opened: URL?
        let originalOpen = server.openURL
        server.openURL = { opened = $0 }
        defer {
            server.stop()
            server.openURL = originalOpen
        }

        server.startAndOpen(page: "/test-console/cdd-lock")
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if case .running = server.state { break }
            if case .failed(let message) = server.state {
                XCTFail(message)
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        guard case .running(let base, let external) = server.state else {
            XCTFail("本地 audi 未能在超时时间内启动")
            return
        }
        XCTAssertFalse(external)
        XCTAssertEqual(base.absoluteString, "http://localhost:3000")
        XCTAssertEqual(opened?.absoluteString, "http://localhost:3000/test-console/cdd-lock")
    }

    func testNextExecutableRunsInsideTheAudiRepository() {
        let path = AudiLocalLaunch.nextExecutable.path
        XCTAssertTrue(path.contains("work/code/audi"))
        XCTAssertTrue(path.hasSuffix("node_modules/next/dist/bin/next"))
    }
}