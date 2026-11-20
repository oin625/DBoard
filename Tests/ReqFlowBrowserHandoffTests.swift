import XCTest
@testable import DBoard

final class ReqFlowBrowserHandoffTests: XCTestCase {
    func testBrowserOpensBeforeRequirementFlowDismisses() {
        let vm = BizMapViewModel(loadBackgroundData: false)
        var events: [String] = []
        XCTAssertTrue(vm.openWebDetail("https://ai.tmallyc.com/prd/index.html#detail/42", open: { url in
            events.append("open")
            XCTAssertTrue(url.contains("detail/42"))
            return true
        }, dismiss: { events.append("dismiss") }))
        XCTAssertEqual(events, ["open", "dismiss"])
    }

    func testFailedBrowserOpenKeepsRequirementFlowVisible() {
        let vm = BizMapViewModel(loadBackgroundData: false)
        var dismissed = false
        XCTAssertFalse(vm.openWebDetail("invalid", open: { _ in false }, dismiss: { dismissed = true }))
        XCTAssertFalse(dismissed)
    }
}
